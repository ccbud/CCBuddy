import Foundation

struct PluginCommandInvocation: Equatable {
    var executable: URL
    var arguments: [String]
    var currentDirectory: URL?
    var environment: [String: String]?

    init(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.environment = environment
    }

    var displayName: String { executable.lastPathComponent }
}

struct PluginCommandOutput: Equatable {
    var terminationStatus: Int32
    var standardOutput: Data
    var standardError: Data

    init(terminationStatus: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    var succeeded: Bool { terminationStatus == 0 }
    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol PluginCommandRunning {
    func run(_ invocation: PluginCommandInvocation) throws -> PluginCommandOutput
}

/// The sole process-spawning boundary in plugin core. Tests replace it with a recording runner,
/// so no fixture test needs Git, a shell, or a build toolchain.
struct PluginProcessCommandRunner: PluginCommandRunning {
    func run(_ invocation: PluginCommandInvocation) throws -> PluginCommandOutput {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectory
        process.environment = invocation.environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw PluginCoreError.filesystem("launch \(invocation.displayName)", invocation.executable, error.localizedDescription)
        }

        // Drain both pipes while the child is running; waiting first can deadlock on verbose builds.
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "dev.ccbud.plugin-command-output", attributes: .concurrent)
        let capturedOutput = PluginCommandOutputAccumulator()
        drainGroup.enter()
        drainQueue.async {
            capturedOutput.setStandardOutput(standardOutput.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            capturedOutput.setStandardError(standardError.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }
        process.waitUntilExit()
        drainGroup.wait()
        let output = capturedOutput.snapshot()
        return .init(
            terminationStatus: process.terminationStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }
}

private final class PluginCommandOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func setStandardOutput(_ data: Data) {
        lock.lock()
        standardOutput = data
        lock.unlock()
    }

    func setStandardError(_ data: Data) {
        lock.lock()
        standardError = data
        lock.unlock()
    }

    func snapshot() -> (standardOutput: Data, standardError: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (standardOutput, standardError)
    }
}

struct PluginToolchain: Equatable {
    var gitExecutable: URL
    var shellExecutable: URL
    var environment: [String: String]

    init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        shellExecutable: URL = URL(fileURLWithPath: "/bin/sh"),
        environment: [String: String] = PluginToolchain.defaultEnvironment()
    ) {
        self.gitExecutable = gitExecutable
        self.shellExecutable = shellExecutable
        self.environment = environment
    }

    static func defaultEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var result = processEnvironment
        var paths = (result["PATH"] ?? "").split(separator: ":").map(String.init)
        let additions = [
            "/usr/local/bin", "/opt/homebrew/bin", "/usr/local/go/bin",
            homeDirectory.appendingPathComponent("go/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            homeDirectory.appendingPathComponent(".local/bin").path,
        ]
        for path in additions where !paths.contains(path) { paths.append(path) }
        result["PATH"] = paths.joined(separator: ":")
        return result
    }
}
