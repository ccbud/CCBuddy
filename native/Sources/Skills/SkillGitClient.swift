import Darwin
import Foundation

struct SkillCommandInvocation: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL?
    var timeout: TimeInterval
}

struct SkillCommandResult: Sendable {
    var terminationStatus: Int32
    var output: Data
    var errorOutput: Data

    init(terminationStatus: Int32, output: Data, errorOutput: Data = Data()) {
        self.terminationStatus = terminationStatus
        self.output = output
        self.errorOutput = errorOutput
    }
}

protocol SkillCommandRunning: Sendable {
    func run(_ invocation: SkillCommandInvocation) throws -> SkillCommandResult
}

struct SkillProcessCommandRunner: SkillCommandRunning {
    func run(_ invocation: SkillCommandInvocation) throws -> SkillCommandResult {
        let identifier = UUID().uuidString
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-skills-command-\(identifier).stdout")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-skills-command-\(identifier).stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        else {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            throw SkillPathSafety.failure("Cannot create command output file")
        }
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: errorURL.path)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, new in new }
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            throw SkillPathSafety.failure("Cannot start Git: \(error.localizedDescription)")
        }
        if completed.wait(timeout: .now() + invocation.timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
            throw SkillPathSafety.failure("Git command timed out")
        }
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let output = try Data(contentsOf: outputURL)
        let errorOutput = try Data(contentsOf: errorURL)
        return SkillCommandResult(
            terminationStatus: process.terminationStatus,
            output: output,
            errorOutput: errorOutput
        )
    }
}

struct SkillGitCheckout: Sendable {
    var directory: URL
    var revision: String
}

struct SkillGitClient {
    private let fileManager: FileManager
    private let runner: any SkillCommandRunning
    private let executable: URL
    private let makeUUID: () -> UUID

    init(
        fileManager: FileManager,
        runner: any SkillCommandRunning,
        executable: URL,
        makeUUID: @escaping () -> UUID
    ) {
        self.fileManager = fileManager
        self.runner = runner
        self.executable = executable
        self.makeUUID = makeUUID
    }

    func validateURL(_ value: String) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              (8...2_048).contains(value.utf8.count),
              !value.hasPrefix("-"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw SkillPathSafety.failure("Invalid Git URL")
        }
        let repositoryPath: Substring
        if value.hasPrefix("https://") {
            let rest = value.dropFirst("https://".count)
            guard let slash = rest.firstIndex(of: "/") else {
                throw SkillPathSafety.failure("Git URL must include a repository path")
            }
            let host = rest[..<slash]
            guard !host.isEmpty, !host.contains("@"), host != "localhost" else {
                throw SkillPathSafety.failure("Git URL host is not allowed")
            }
            repositoryPath = rest[rest.index(after: slash)...]
        } else if value.hasPrefix("ssh://") {
            let rest = value.dropFirst("ssh://".count)
            guard let slash = rest.firstIndex(of: "/") else {
                throw SkillPathSafety.failure("Git URL must include a repository path")
            }
            repositoryPath = rest[rest.index(after: slash)...]
        } else if value.hasPrefix("git@") {
            let rest = value.dropFirst("git@".count)
            guard let colon = rest.firstIndex(of: ":") else {
                throw SkillPathSafety.failure("Invalid SSH Git URL")
            }
            repositoryPath = rest[rest.index(after: colon)...]
        } else {
            throw SkillPathSafety.failure("Only HTTPS and SSH Git URLs are supported")
        }
        let pieces = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !repositoryPath.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
            throw SkillPathSafety.failure("Invalid Git repository path")
        }
        return value
    }

    func cloneShallow(root: URL, source: String) throws -> SkillGitCheckout {
        let source = try validateURL(source)
        let directory = try SkillPathSafety.uniqueHidden(root: root, kind: "git", makeUUID: makeUUID)
        do {
            let clone = try run(["clone", "--depth", "1", "--no-tags", "--", source, directory.path])
            guard clone.terminationStatus == 0 else {
                throw SkillPathSafety.failure("Git clone failed: \(diagnosticText(clone))")
            }
            let revisionResult = try run(["-C", directory.path, "rev-parse", "HEAD"])
            guard revisionResult.terminationStatus == 0 else {
                throw SkillPathSafety.failure("Git command failed: \(diagnosticText(revisionResult))")
            }
            let revision = outputText(revisionResult.output).trimmingCharacters(in: .whitespacesAndNewlines)
            guard revision.count >= 7, revision.allSatisfy(\.isHexDigit) else {
                throw SkillPathSafety.failure("Git did not return a valid revision")
            }
            return SkillGitCheckout(directory: directory, revision: revision)
        } catch {
            try? SkillPathSafety.removeDirectChild(root: root, child: directory, fileManager: fileManager)
            throw error
        }
    }

    func remoteHead(source: String) throws -> String {
        let source = try validateURL(source)
        let result = try run(["ls-remote", "--", source, "HEAD"])
        guard result.terminationStatus == 0 else {
            throw SkillPathSafety.failure("Git refresh failed: \(diagnosticText(result))")
        }
        guard let revision = outputText(result.output).split(whereSeparator: \.isWhitespace).first,
              revision.count >= 7,
              revision.allSatisfy(\.isHexDigit)
        else {
            throw SkillPathSafety.failure("Git remote did not return HEAD")
        }
        return String(revision)
    }

    private func run(_ arguments: [String]) throws -> SkillCommandResult {
        try runner.run(SkillCommandInvocation(
            executable: executable,
            arguments: arguments,
            environment: [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_SSH_COMMAND": "ssh -oBatchMode=yes -oConnectTimeout=15",
            ],
            workingDirectory: nil,
            timeout: 120
        ))
    }

    private func outputText(_ data: Data) -> String {
        String(decoding: data.prefix(800), as: UTF8.self)
    }

    private func diagnosticText(_ result: SkillCommandResult) -> String {
        let data = result.errorOutput.isEmpty ? result.output : result.errorOutput
        return outputText(data)
    }
}
