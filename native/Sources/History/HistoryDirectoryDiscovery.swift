import Foundation

/// The result of applying the one-time coding-CLI history-directory migrations to a config.
/// `didChange` describes migration work only: it becomes true when at least one detected install
/// completes its flag, including the flag-only case where its directory was already configured.
struct HistoryDirectoryDiscoveryResult: Equatable {
    let config: AppConfig
    let didChange: Bool
    let addedDirectories: [String]
}

/// Detects history roots written by supported coding CLIs without reading or writing CC Buddy's
/// config file. Callers can run this off the main actor, persist `result.config` when
/// `result.didChange` is true, then refresh history/watchers themselves.
///
/// Environment paths intentionally follow the legacy CLI contract: a non-blank override is used
/// verbatim (without trimming, tilde expansion, canonicalization, or environment expansion).
struct HistoryDirectoryDiscovery {
    static let migrationFlags = [
        "codexDirAutoAdded",
        "xdgClaudeDirAutoAdded",
        "grokDirAutoAdded",
        "copilotDirAutoAdded",
        "antigravityDirAutoAdded",
        "qoderDirAutoAdded",
        "qoderworkDirAutoAdded",
    ]

    private struct Candidate {
        let flag: String
        let label: String
        let isDetected: () -> Bool
    }

    private let environment: [String: String]
    private let homePath: String
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        homePath = homeDirectory?.path ?? environment["HOME"] ?? "."
        self.fileManager = fileManager
    }

    func discover(in input: AppConfig) -> HistoryDirectoryDiscoveryResult {
        var config = input
        config.historyDirs = normalizedHistoryDirectories(config.historyDirs)
        let originalDirectories = config.historyDirs
        var didChange = false

        for candidate in candidates() {
            guard config.additionalProperties[candidate.flag] != .bool(true) else { continue }
            guard candidate.isDetected() else { continue }

            if !config.historyDirs.contains(candidate.label) {
                config.historyDirs.append(candidate.label)
            }
            config.additionalProperties[candidate.flag] = .bool(true)
            didChange = true
        }

        // Legacy persistence normalizes after every successful migration. A single final pass is
        // equivalent for these append-only candidates and also folds XDG's absolute HOME label.
        config.historyDirs = normalizedHistoryDirectories(config.historyDirs)
        if config.historyActive == "__codex__" {
            let codexLabel = collapseHome(codexRoot())
            config.historyActive = config.historyDirs.contains(codexLabel) ? codexLabel : "all"
            didChange = true
        }
        let addedDirectories = config.historyDirs.filter { !originalDirectories.contains($0) }
        return HistoryDirectoryDiscoveryResult(
            config: config,
            didChange: didChange,
            addedDirectories: addedDirectories
        )
    }

    private func candidates() -> [Candidate] {
        let codexRoot = codexRoot()
        let xdgBase = environmentRoot("XDG_CONFIG_HOME") ?? join(homePath, ".config")
        let xdgClaudeRoot = join(xdgBase, "claude")
        let grokRoot = environmentRoot("GROK_HOME") ?? join(homePath, ".grok")
        let copilotRoot = join(homePath, ".copilot")
        let antigravityRoot = join(join(homePath, ".gemini"), "antigravity-cli")
        let qoderRoot = join(homePath, ".qoder")
        let qoderWorkRoot = join(homePath, ".qoderwork")

        return [
            Candidate(
                flag: "codexDirAutoAdded",
                label: collapseHome(codexRoot),
                isDetected: { isDirectory(join(codexRoot, "sessions")) }
            ),
            Candidate(
                flag: "xdgClaudeDirAutoAdded",
                // The legacy probe compares this raw value, then write-time normalization folds a
                // HOME prefix to `~/…`. `discover` performs the same normalization before return.
                label: xdgClaudeRoot,
                isDetected: { isDirectory(join(xdgClaudeRoot, "projects")) }
            ),
            Candidate(
                flag: "grokDirAutoAdded",
                label: collapseHome(grokRoot),
                isDetected: { grokRootExists(grokRoot) }
            ),
            Candidate(
                flag: "copilotDirAutoAdded",
                label: collapseHome(copilotRoot),
                isDetected: { isDirectory(join(copilotRoot, "session-state")) }
            ),
            Candidate(
                flag: "antigravityDirAutoAdded",
                label: collapseHome(antigravityRoot),
                isDetected: { isDirectory(join(antigravityRoot, "conversations")) }
            ),
            Candidate(
                flag: "qoderDirAutoAdded",
                label: collapseHome(qoderRoot),
                isDetected: { isDirectory(join(qoderRoot, "projects")) }
            ),
            Candidate(
                flag: "qoderworkDirAutoAdded",
                label: collapseHome(qoderWorkRoot),
                isDetected: { isDirectory(join(qoderWorkRoot, "projects")) }
            ),
        ]
    }

    private func codexRoot() -> String {
        environmentRoot("CODEX_HOME") ?? join(homePath, ".codex")
    }

    private func environmentRoot(_ key: String) -> String? {
        guard let value = environment[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private func grokRootExists(_ root: String) -> Bool {
        let sessions = join(root, "sessions")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: sessions) else {
            return false
        }
        return entries.contains { name in
            let lowercase = name.lowercased()
            guard lowercase.hasPrefix("%2f") || lowercase.hasPrefix("%3a%5c") else {
                return false
            }
            return isDirectory(join(sessions, name))
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue
    }

    private func normalizedHistoryDirectories(_ input: [String]) -> [String] {
        var result: [String] = []
        for raw in input {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while value.hasSuffix("/") || value.hasSuffix("\\") {
                value.removeLast()
            }
            value = collapseHome(value)
            if !value.isEmpty, !result.contains(value) {
                result.append(value)
            }
        }
        if !result.contains("~/.claude") {
            result.insert("~/.claude", at: 0)
        }
        return result
    }

    private func collapseHome(_ path: String) -> String {
        guard !homePath.isEmpty else { return path }
        var home = homePath
        while home.hasSuffix("/") { home.removeLast() }
        if path == home { return "~" }
        let prefix = home + "/"
        if path.hasPrefix(prefix) {
            return "~/" + path.dropFirst(prefix.count)
        }
        return path
    }

    private func join(_ base: String, _ component: String) -> String {
        (base as NSString).appendingPathComponent(component)
    }
}
