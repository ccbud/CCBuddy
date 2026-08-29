import AppKit
import Foundation

/// Reopening a finished session in the terminal that produced it.
///
/// This was the one capability the session library was missing: you could read a transcript in
/// full, but the only way back into it was to remember the agent's flag and retype the session id.
/// The dialects below are the CLIs' own — they are not interchangeable, which is exactly why they
/// belong in one table instead of being guessed at the call site.
enum ConversationResume {
    // MARK: - Terminals

    /// Only hosts that accept a command programmatically. A terminal we cannot inject into would
    /// open an empty window and look like a failure.
    enum TerminalApp: String, CaseIterable, Identifiable {
        case ghostty
        case iTerm
        case warp
        case terminal

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ghostty: "Ghostty"
            case .iTerm: "iTerm"
            case .warp: "Warp"
            case .terminal: "终端"
            }
        }

        fileprivate var bundleName: String {
            switch self {
            case .ghostty: "Ghostty"
            case .iTerm: "iTerm"
            case .warp: "Warp"
            case .terminal: "Terminal"
            }
        }

        fileprivate var candidatePaths: [String] {
            switch self {
            case .ghostty: ["/Applications/Ghostty.app"]
            case .iTerm: ["/Applications/iTerm.app"]
            case .warp: ["/Applications/Warp.app"]
            case .terminal: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"]
            }
        }

        var isInstalled: Bool {
            let manager = FileManager.default
            if candidatePaths.contains(where: { manager.fileExists(atPath: $0) }) { return true }
            let userApplications = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
                .appendingPathComponent("\(bundleName).app")
            return manager.fileExists(atPath: userApplications.path)
        }
    }

    /// Preference order for the default host, most specialized first. Terminal.app is last because
    /// it is always present and would otherwise win on every Mac.
    static var installedTerminals: [TerminalApp] {
        TerminalApp.allCases.filter(\.isInstalled)
    }

    private static let preferredTerminalKey = "ccbud-resume-terminal"

    static var preferredTerminal: TerminalApp {
        get {
            let installed = installedTerminals
            if let raw = UserDefaults.standard.string(forKey: preferredTerminalKey),
               let stored = TerminalApp(rawValue: raw),
               installed.contains(stored) {
                return stored
            }
            return installed.first ?? .terminal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferredTerminalKey) }
    }

    // MARK: - Agent dialects

    /// The executable each agent installs, and how it names an existing session on relaunch.
    /// `requiresWorkingDirectory` marks agents that resolve the session relative to the project, so
    /// launching from the wrong directory would silently start a new conversation instead.
    struct Dialect {
        var binary: String
        var arguments: [String]
        var requiresWorkingDirectory: Bool
    }

    static func dialect(for source: HistorySource, sessionID: String) -> Dialect? {
        switch source {
        case .claude:
            Dialect(binary: "claude", arguments: ["--resume", sessionID], requiresWorkingDirectory: true)
        case .codex:
            Dialect(binary: "codex", arguments: ["resume", sessionID], requiresWorkingDirectory: false)
        case .copilot:
            Dialect(binary: "copilot", arguments: ["--resume=\(sessionID)"], requiresWorkingDirectory: false)
        case .grok:
            Dialect(binary: "grok", arguments: ["--resume", sessionID], requiresWorkingDirectory: false)
        case .antigravity:
            Dialect(binary: "agy", arguments: ["--conversation=\(sessionID)"], requiresWorkingDirectory: false)
        case .qoder:
            // Qoder ships no documented per-session relaunch flag; offering a button that starts a
            // fresh conversation would be worse than offering none.
            nil
        }
    }

    static func isSupported(_ source: HistorySource) -> Bool {
        dialect(for: source, sessionID: "probe") != nil
    }

    // MARK: - Outcome

    struct Outcome {
        var succeeded: Bool
        var command: String
        var message: String
    }

    // MARK: - Resolution

    private static let cacheQueue = DispatchQueue(label: "dev.ccbud.resume-cli-cache")
    nonisolated(unsafe) private static var resolvedBinaries: [String: String?] = [:]

    /// GUI apps do not inherit a login shell's PATH, so a CLI installed by a version manager is
    /// invisible to `Process` unless we go looking for it.
    ///
    /// The obvious places are tried first, because they cost a `stat` and cover every common
    /// installer. Only then is a shell asked — and a *login* shell rather than an interactive one:
    /// an interactive zsh runs the prompt's startup files, which on a configured machine write
    /// terminal escape sequences onto stdout. That is what broke this: `command -v codex` came back
    /// as an OSC-7 sequence with the path glued to the end of it, no line started with a slash, and
    /// "在终端继续" reported that a CLI sitting in ~/.local/bin could not be found.
    static func resolveBinary(_ name: String) -> String? {
        if let cached = cacheQueue.sync(execute: { resolvedBinaries[name] }) { return cached }

        let resolved = knownLocation(of: name) ?? shellLocation(of: name)
        cacheQueue.sync { resolvedBinaries[name] = resolved }
        return resolved
    }

    static func knownLocation(
        of name: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        let directories = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".bun/bin").path,
            homeDirectory.appendingPathComponent(".volta/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func shellLocation(of name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-l` without `-i`: a login shell reads the same PATH exports without starting a prompt.
        process.arguments = ["-lc", "command -v \(name) 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return executablePath(inShellOutput: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    /// Pulls a usable path out of shell output that may still carry escape sequences.
    static func executablePath(
        inShellOutput output: String,
        fileManager: FileManager = .default
    ) -> String? {
        for line in output.components(separatedBy: .newlines).reversed() {
            let cleaned = stripControlSequences(line).trimmingCharacters(in: .whitespaces)
            guard let slash = cleaned.firstIndex(of: "/") else { continue }
            let path = String(cleaned[slash...])
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Removes ANSI/OSC sequences and any other control characters a prompt may have emitted.
    ///
    /// The two families end differently, and treating them alike is what makes a stripper eat the
    /// wrong half: a CSI sequence stops at its first final byte, while an OSC one runs until a BEL
    /// or a string terminator and may contain letters, slashes and a whole URL on the way.
    private static func stripControlSequences(_ value: String) -> String {
        var result = ""
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                if scalar.properties.generalCategory != .control {
                    result.unicodeScalars.append(scalar)
                }
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else { break }
            let introducer = scalars[index]
            index += 1
            switch introducer {
            case "]":
                while index < scalars.count {
                    let next = scalars[index]
                    index += 1
                    if next == "\u{07}" || next == "\u{9C}" { break }
                    // ESC \ — the two-character string terminator.
                    if next == "\u{1B}", index < scalars.count, scalars[index] == "\\" {
                        index += 1
                        break
                    }
                }
            case "[":
                // Parameter and intermediate bytes, then one final byte in 0x40...0x7E.
                while index < scalars.count {
                    let next = scalars[index]
                    index += 1
                    if (0x40...0x7E).contains(next.value) { break }
                }
            default:
                break  // A two-character escape; the introducer was the whole of it.
            }
        }
        return result
    }

    // MARK: - Composition

    static func posixQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func composeCommand(
        binary: String,
        arguments: [String],
        workingDirectory: String?
    ) -> String {
        var parts: [String] = []
        if let workingDirectory, !workingDirectory.isEmpty {
            parts.append("cd \(posixQuote(workingDirectory))")
        }
        parts.append(([binary] + arguments).map(posixQuote).joined(separator: " "))
        return parts.joined(separator: " && ")
    }

    // MARK: - Launching

    @discardableResult
    static func resume(
        metadata: HistorySessionMetadata,
        in terminal: TerminalApp? = nil,
        clipboard: (String) -> Void = copyToClipboard
    ) -> Outcome {
        let host = terminal ?? preferredTerminal
        guard let dialect = dialect(for: metadata.source, sessionID: metadata.sessionID) else {
            return Outcome(
                succeeded: false,
                command: "",
                message: "\(ConversationPresentation.sourceName(rawValue: metadata.source.rawValue)) 还不支持在终端继续"
            )
        }

        let directory = metadata.cwd ?? ""
        var isDirectory: ObjCBool = false
        let directoryUsable = !directory.isEmpty
            && FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
            && isDirectory.boolValue

        if dialect.requiresWorkingDirectory && !directoryUsable {
            let command = composeCommand(
                binary: dialect.binary,
                arguments: dialect.arguments,
                workingDirectory: nil
            )
            clipboard(command)
            return Outcome(
                succeeded: false,
                command: command,
                message: "项目目录已不存在：\(directory)。命令已复制到剪贴板，可手动运行。"
            )
        }

        guard let executable = resolveBinary(dialect.binary) else {
            return Outcome(
                succeeded: false,
                command: "",
                message: "找不到命令 \(dialect.binary)，请确认它已安装并在 PATH 中"
            )
        }

        let command = composeCommand(
            binary: executable,
            arguments: dialect.arguments,
            workingDirectory: directoryUsable ? directory : nil
        )

        do {
            try launch(host, command: command)
            preferredTerminal = host
            return Outcome(succeeded: true, command: command, message: "已在 \(host.displayName) 中继续会话")
        } catch {
            copyToClipboard(command)
            return Outcome(
                succeeded: false,
                command: command,
                message: "无法打开 \(host.displayName)。命令已复制到剪贴板，可手动运行。"
            )
        }
    }

    private enum LaunchError: Error { case failed }

    private static func launch(_ terminal: TerminalApp, command: String) throws {
        switch terminal {
        case .terminal:
            try runOSAScript([
                #"tell application "Terminal" to activate"#,
                #"tell application "Terminal" to do script "\#(appleScriptQuote(command))""#,
            ])
        case .iTerm:
            try runOSAScript([
                #"tell application "iTerm" to activate"#,
                #"tell application "iTerm" to create window with default profile"#,
                #"tell current session of current window of application "iTerm" to write text "\#(appleScriptQuote(command))""#,
            ])
        case .ghostty:
            // Ghostty takes the command as launch arguments; keeping the shell alive afterwards
            // leaves the agent's output on screen instead of closing the window on exit.
            try run(
                "/usr/bin/open",
                arguments: [
                    "-na", "Ghostty", "--args",
                    "-e", "/bin/zsh", "-lic", "\(command); exec /bin/zsh -il",
                ]
            )
        case .warp:
            // Warp has no command-injection CLI; its documented path is a launch configuration
            // file opened through the warp:// scheme.
            let configuration = """
            ---
            name: CC Buddy Resume
            windows:
              - tabs:
                  - layout:
                      cwd: null
                      commands:
                        - exec: |
                            \(command)
            """
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("ccbud-resume-\(UUID().uuidString).yaml")
            try configuration.write(to: file, atomically: true, encoding: .utf8)
            let encoded = file.path.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~/"))
            ) ?? file.path
            guard let url = URL(string: "warp://launch/\(encoded)") else { throw LaunchError.failed }
            NSWorkspace.shared.open(url)
        }
    }

    private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runOSAScript(_ lines: [String]) throws {
        var arguments: [String] = []
        for line in lines { arguments.append(contentsOf: ["-e", line]) }
        try run("/usr/bin/osascript", arguments: arguments)
    }

    private static func run(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LaunchError.failed }
    }

    static func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
