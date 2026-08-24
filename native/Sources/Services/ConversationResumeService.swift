import Foundation

enum ConversationTerminal: String, CaseIterable, Codable, Identifiable, Sendable {
    case terminal
    case iTerm
    case warp
    case ghostty
    case kooky

    static let wakeDisplayOrder: [ConversationTerminal] = [
        .terminal, .kooky, .iTerm, .warp, .ghostty,
    ]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .kooky: "Kooky"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .iTerm: "rectangle.3.group"
        case .warp: "waveform.path"
        case .ghostty: "terminal.fill"
        case .kooky: "app.fill"
        }
    }
}

struct ConversationResumeOutcome: Equatable, Sendable {
    var opened: Bool
    var command: String
    var error: String?
}

protocol ConversationResuming: Sendable {
    func availableTerminals(for metadata: HistorySessionMetadata) -> [ConversationTerminal]
    func resume(
        _ metadata: HistorySessionMetadata,
        in terminal: ConversationTerminal
    ) -> ConversationResumeOutcome
}

enum ConversationTerminalLaunchSupport {
    static let kookyDeepLinkSources: [HistorySource: String] = [
        .claude: "claude-code",
        .codex: "codex",
        .copilot: "copilot",
        .cursor: "cursor",
        .opencode: "opencode",
        .kiro: "kiro",
        .gemini: "gemini",
        .pi: "pi",
        .omp: "omp",
        .grok: "grok",
        .kimi: "kimi",
    ]

    static func kookyDeepLink(
        for metadata: HistorySessionMetadata,
        workingDirectory: String?
    ) -> URL? {
        guard let agent = kookyDeepLinkSources[metadata.source],
              isValidKookySessionID(metadata.sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "kooky"
        components.host = "resume"
        components.queryItems = [
            URLQueryItem(name: "agent", value: agent),
            URLQueryItem(name: "id", value: metadata.sessionID),
        ]
        if let workingDirectory { components.queryItems?.append(
            URLQueryItem(name: "cwd", value: workingDirectory)
        ) }
        return components.url
    }

    static func isValidKookySessionID(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 200,
              let first = scalars.first, isASCIIAlphaNumeric(first) else { return false }
        return scalars.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    static func ghosttyArguments(command: String) -> [String] {
        [
            "-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lic",
            "\(command); exec /bin/zsh -il",
        ]
    }

    static func warpConfiguration(command: String) -> String? {
        guard !command.contains("\n"), !command.contains("\r") else { return nil }
        return """
        name: CC Buddy Resume
        windows:
          - tabs:
              - layout:
                  commands:
                    - exec: |-
                        \(command)

        """
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: true
        default: false
        }
    }
}

struct ConversationResumeInvocation: Equatable, Sendable {
    var binary: String
    var arguments: [String]
    var requiresWorkingDirectory: Bool

    static func make(for metadata: HistorySessionMetadata) -> ConversationResumeInvocation? {
        guard !metadata.imported else { return nil }
        let sessionID = metadata.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        switch metadata.source {
        case .claude:
            return .init(binary: "claude", arguments: ["--resume", sessionID], requiresWorkingDirectory: true)
        case .codex:
            return .init(binary: "codex", arguments: ["resume", sessionID], requiresWorkingDirectory: false)
        case .qoder:
            return .init(binary: "qodercli", arguments: ["--resume", sessionID], requiresWorkingDirectory: false)
        case .grok:
            return .init(binary: "grok", arguments: ["--resume", sessionID], requiresWorkingDirectory: false)
        case .copilot:
            return .init(binary: "copilot", arguments: ["--resume=\(sessionID)"], requiresWorkingDirectory: false)
        case .cursor:
            return .init(binary: "cursor-agent", arguments: ["--resume", sessionID], requiresWorkingDirectory: false)
        case .opencode:
            let binary = metadata.version?.hasPrefix("opencode2") == true
                ? "opencode2"
                : "opencode"
            return .init(binary: binary, arguments: ["--session", sessionID], requiresWorkingDirectory: false)
        case .pi:
            return .init(binary: "pi", arguments: ["--session", sessionID], requiresWorkingDirectory: false)
        case .omp:
            return .init(binary: "omp", arguments: ["--resume", sessionID], requiresWorkingDirectory: false)
        case .kimi:
            return .init(binary: "kimi", arguments: ["--session", sessionID], requiresWorkingDirectory: false)
        case .antigravity:
            return .init(binary: "agy", arguments: ["--conversation=\(sessionID)"], requiresWorkingDirectory: false)
        case .dsh:
            return .init(
                binary: "npx",
                arguments: ["@deepseek-ai/dsh", "web"],
                requiresWorkingDirectory: true
            )
        case .kiro, .gemini:
            return nil
        }
    }

    func command(executable: String? = nil, workingDirectory: String?) -> String {
        let core = ([executable ?? binary] + arguments)
            .map(Self.posixQuote)
            .joined(separator: " ")
        guard let workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return core
        }
        return "cd \(Self.posixQuote(workingDirectory)) && \(core)"
    }

    static func posixQuote(_ value: String) -> String {
        if !value.isEmpty,
           value.unicodeScalars.allSatisfy({ scalar in
               CharacterSet.alphanumerics.contains(scalar)
                   || "_-./:=".unicodeScalars.contains(scalar)
           }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Launches the same producer-specific resume commands as Wake in a real macOS terminal. The
/// caller owns the clipboard fallback so this service can stay off the main actor while AppleScript
/// or login-shell discovery is running.
struct SystemConversationResumeService: @unchecked Sendable, ConversationResuming {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let cliResolver: @Sendable (String) -> String?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliResolver: (@Sendable (String) -> String?)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.cliResolver = cliResolver ?? { Self.resolveCLI($0) }
    }

    func availableTerminals(for metadata: HistorySessionMetadata) -> [ConversationTerminal] {
        guard !metadata.imported else { return [] }
        return ConversationTerminal.wakeDisplayOrder.filter { terminal in
            guard isInstalled(terminal) else { return false }
            if terminal == .kooky {
                return ConversationTerminalLaunchSupport.kookyDeepLinkSources[metadata.source] != nil
                    || (kookyCLIPath() != nil
                        && ConversationResumeInvocation.make(for: metadata) != nil)
            }
            return ConversationResumeInvocation.make(for: metadata) != nil
        }
    }

    func resume(
        _ metadata: HistorySessionMetadata,
        in terminal: ConversationTerminal
    ) -> ConversationResumeOutcome {
        if terminal == .kooky { return resumeInKooky(metadata) }
        guard let invocation = ConversationResumeInvocation.make(for: metadata) else {
            return .init(
                opened: false,
                command: "",
                error: "\(ConversationPresentation.sourceName(rawValue: metadata.source.rawValue)) 暂不支持从终端继续"
            )
        }
        let cwd = validWorkingDirectory(metadata.cwd)
        let fallback = invocation.command(workingDirectory: cwd)
        if invocation.requiresWorkingDirectory, cwd == nil {
            return .init(
                opened: false,
                command: fallback,
                error: "项目目录已不存在：\(metadata.cwd ?? "(unknown)")"
            )
        }
        guard let executable = cliResolver(invocation.binary) else {
            return .init(
                opened: false,
                command: fallback,
                error: "未找到命令 \(invocation.binary)，请确认已安装并可从登录 shell 访问"
            )
        }
        let command = invocation.command(executable: executable, workingDirectory: cwd)
        do {
            try launch(command, in: terminal)
            return .init(opened: true, command: command, error: nil)
        } catch {
            return .init(
                opened: false,
                command: command,
                error: "无法打开 \(terminal.displayName)：\(error.localizedDescription)"
            )
        }
    }

    private func isInstalled(_ terminal: ConversationTerminal) -> Bool {
        applicationCandidates(for: terminal).contains {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private func applicationCandidates(for terminal: ConversationTerminal) -> [URL] {
        let homeApplication = homeDirectory.appendingPathComponent(
            "Applications/\(terminal.displayName).app",
            isDirectory: true
        )
        switch terminal {
        case .terminal:
            return [
                URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                URL(fileURLWithPath: "/Applications/Utilities/Terminal.app"),
                homeApplication,
            ]
        case .iTerm:
            return [
                URL(fileURLWithPath: "/Applications/iTerm.app"),
                homeApplication,
            ]
        case .warp:
            return [URL(fileURLWithPath: "/Applications/Warp.app"), homeApplication]
        case .ghostty:
            return [URL(fileURLWithPath: "/Applications/Ghostty.app"), homeApplication]
        case .kooky:
            return [URL(fileURLWithPath: "/Applications/Kooky.app"), homeApplication]
        }
    }

    private func kookyCLIPath() -> URL? {
        let file = homeDirectory.appendingPathComponent(
            "Library/Application Support/kooky/bin/kooky-cli",
            isDirectory: false
        )
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return file
    }

    private func validWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rawValue, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return rawValue
    }

    private static func resolveCLI(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v -- \(ConversationResumeInvocation.posixQuote(binary))"]
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 16_384,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              output.hasPrefix("/") else { return nil }
        let executable = URL(fileURLWithPath: output).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable.path
    }

    private func launch(_ command: String, in terminal: ConversationTerminal) throws {
        if terminal == .ghostty {
            try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ConversationTerminalLaunchSupport.ghosttyArguments(command: command)
            )
            return
        }
        if terminal == .warp {
            guard let configuration = ConversationTerminalLaunchSupport.warpConfiguration(
                command: command
            ) else {
                throw launchError("Warp 不支持多行恢复命令")
            }
            let file = fileManager.temporaryDirectory.appendingPathComponent(
                "ccbud-warp-resume.yaml"
            )
            try SecureAtomicFile.write(
                Data(configuration.utf8),
                to: file,
                fileManager: fileManager
            )
            try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["warp://launch/\(file.path)"]
            )
            return
        }
        if terminal == .kooky { throw launchError("Kooky 必须使用深链恢复") }

        let escaped = Self.applescriptQuote(command)
        let lines: [String]
        switch terminal {
        case .terminal:
            lines = [
                "tell application \"Terminal\" to activate",
                "tell application \"Terminal\" to do script \"\(escaped)\"",
            ]
        case .iTerm:
            lines = [
                "tell application \"iTerm\" to activate",
                "tell application \"iTerm\" to create window with default profile",
                "tell current session of current window of application \"iTerm\" to write text \"\(escaped)\"",
            ]
        case .warp, .ghostty, .kooky:
            preconditionFailure("Non-AppleScript terminal handled above")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        let standardError = Pipe()
        process.standardOutput = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data.prefix(8_192), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ConversationResume",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "AppleScript failed"]
            )
        }
    }

    private func resumeInKooky(
        _ metadata: HistorySessionMetadata
    ) -> ConversationResumeOutcome {
        guard !metadata.imported else {
            return .init(opened: false, command: "", error: "导入的会话不能直接继续")
        }
        let cwd = validWorkingDirectory(metadata.cwd)
        if ConversationTerminalLaunchSupport.kookyDeepLinkSources[metadata.source] != nil {
            if let link = ConversationTerminalLaunchSupport.kookyDeepLink(
                for: metadata,
                workingDirectory: cwd
            ), (try? runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: [link.absoluteString]
            )) != nil {
                return .init(opened: true, command: link.absoluteString, error: nil)
            }
            do {
                try runProcess(
                    executable: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: ["-a", "Kooky"]
                )
                return .init(
                    opened: true,
                    command: "open -a Kooky (deep link unavailable)",
                    error: nil
                )
            } catch {
                return .init(
                    opened: false,
                    command: "",
                    error: "无法打开 Kooky：\(error.localizedDescription)"
                )
            }
        }
        return resumeThroughKookyCLI(metadata, workingDirectory: cwd)
    }

    private func resumeThroughKookyCLI(
        _ metadata: HistorySessionMetadata,
        workingDirectory: String?
    ) -> ConversationResumeOutcome {
        guard let kookyCLI = kookyCLIPath() else {
            return .init(
                opened: false,
                command: "",
                error: "未找到 kooky-cli，请将 Kooky 更新到 0.51 或更高版本"
            )
        }
        guard let invocation = ConversationResumeInvocation.make(for: metadata) else {
            return .init(
                opened: false,
                command: "",
                error: "\(ConversationPresentation.sourceName(rawValue: metadata.source.rawValue)) 暂不支持继续会话"
            )
        }
        let fallbackExecutable = cliResolver(invocation.binary)
        let directCommand = invocation.command(
            executable: fallbackExecutable,
            workingDirectory: workingDirectory
        )
        guard let workingDirectory else {
            return .init(
                opened: false,
                command: invocation.command(executable: fallbackExecutable, workingDirectory: nil),
                error: "项目目录已不存在：\(metadata.cwd ?? "(unknown)")"
            )
        }
        guard let executable = fallbackExecutable else {
            return .init(
                opened: false,
                command: invocation.command(workingDirectory: workingDirectory),
                error: "未找到命令 \(invocation.binary)，请确认已安装并可从登录 shell 访问"
            )
        }
        let agentCommand = invocation.command(executable: executable, workingDirectory: nil)
        do {
            try runProcess(
                executable: kookyCLI,
                arguments: ["open", "--cwd", workingDirectory, "-e", agentCommand]
            )
            let shown = "\(ConversationResumeInvocation.posixQuote(kookyCLI.path)) open --cwd "
                + "\(ConversationResumeInvocation.posixQuote(workingDirectory)) -e "
                + ConversationResumeInvocation.posixQuote(agentCommand)
            return .init(opened: true, command: shown, error: nil)
        } catch {
            return .init(
                opened: false,
                command: directCommand,
                error: "无法通过 Kooky 继续会话：\(error.localizedDescription)"
            )
        }
    }

    private func runProcess(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data.prefix(8_192), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw launchError(detail?.isEmpty == false ? detail! : "process failed")
        }
    }

    private func launchError(_ message: String) -> NSError {
        NSError(
            domain: "ConversationResume",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func applescriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
