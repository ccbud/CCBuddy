import CryptoKit
import Foundation

/// One user-managed producer root, persisted beside the conversation index.
///
/// `path` is the form entered in the Session locations editor. An adapter may derive more than
/// one data root from it (Codex, for example, owns both active and archived rollouts).
struct ConversationSessionLocation: Codable, Equatable, Hashable, Identifiable, Sendable {
    var source: HistorySource
    var path: String

    var id: String { source.rawValue + "\u{0}" + path }

    init(source: HistorySource, path: String) {
        self.source = source
        self.path = path
    }
}

struct ConversationSessionLocationOverrides: Equatable, Sendable {
    var custom: [ConversationSessionLocation] = []
    var removedDefaults: Set<HistorySource> = []

    var isEmpty: Bool { custom.isEmpty && removedDefaults.isEmpty }
}

struct ConversationSessionLocationRow: Equatable, Identifiable, Sendable {
    var source: HistorySource
    var dataRoot: URL
    var storedCustomRoot: URL?
    var sessionCount: Int
    var exists: Bool

    var isCustom: Bool { storedCustomRoot != nil }
    var id: String {
        source.rawValue + "\u{0}" + dataRoot.standardizedFileURL.path
    }
}

/// Wake's form-level location rules, kept separate from persistence so the UI can reject an
/// overlapping producer root before rebuilding the index. Different producers may intentionally
/// live inside one another; only roots owned by the same producer are mutually exclusive.
enum ConversationSessionLocationValidator {
    static func normalizedLocation(
        source: HistorySource,
        path rawPath: String,
        homeDirectory: URL
    ) -> ConversationSessionLocation? {
        let raw = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == "~" || raw.hasPrefix("~/") || raw.hasPrefix("/") else {
            return nil
        }
        let expanded = HistoryPathResolver.expandTilde(raw, homeDirectory: homeDirectory)
        guard expanded.isFileURL else { return nil }
        let normalized = ConversationSessionLocationLayout.normalizedCustomRoot(
            source: source,
            selected: expanded
        )
        return ConversationSessionLocation(source: source, path: normalized.path)
    }

    static func editingRoot(for row: ConversationSessionLocationRow) -> URL {
        if let custom = row.storedCustomRoot {
            return custom.standardizedFileURL
        }

        let root = row.dataRoot.standardizedFileURL
        let isRegularFile = (try? root.resourceValues(
            forKeys: [.isRegularFileKey]
        ).isRegularFile) == true
        let sourceOwnsDatabase = [
            HistorySource.copilot,
            .opencode,
            .antigravity,
        ].contains(row.source)
        if isRegularFile || (sourceOwnsDatabase && !root.pathExtension.isEmpty) {
            return root.deletingLastPathComponent().standardizedFileURL
        }
        return root
    }

    static func isUnchanged(
        _ candidate: ConversationSessionLocation,
        editing row: ConversationSessionLocationRow
    ) -> Bool {
        guard candidate.source == row.source else { return false }
        let original = ConversationSessionLocationLayout.normalizedCustomRoot(
            source: row.source,
            selected: editingRoot(for: row)
        )
        return standardizedPath(candidate.path) == original.standardizedFileURL.path
    }

    static func overlapsExisting(
        _ candidate: ConversationSessionLocation,
        rows: [ConversationSessionLocationRow],
        editing original: ConversationSessionLocationRow? = nil
    ) -> Bool {
        let candidatePath = standardizedPath(candidate.path)
        return rows.contains { row in
            guard row.source == candidate.source else { return false }
            if let original, excludes(row, whileEditing: original, as: candidate.source) {
                return false
            }
            let existingPath = row.dataRoot.standardizedFileURL.path
            return ConversationSessionLocationLayout.pathOwns(
                root: candidatePath,
                path: existingPath
            ) || ConversationSessionLocationLayout.pathOwns(
                root: existingPath,
                path: candidatePath
            )
        }
    }

    private static func excludes(
        _ row: ConversationSessionLocationRow,
        whileEditing original: ConversationSessionLocationRow,
        as candidateSource: HistorySource
    ) -> Bool {
        guard original.source == candidateSource else { return false }
        if let customRoot = original.storedCustomRoot {
            // One stored custom root can derive multiple displayed data roots (Codex is the
            // canonical example). Editing any one of those rows replaces the whole unit.
            return ConversationSessionLocationLayout.pathOwns(
                root: customRoot.standardizedFileURL.path,
                path: row.dataRoot.standardizedFileURL.path
            )
        }
        // Likewise, all non-custom rows for one producer belong to its single default instance.
        return row.storedCustomRoot == nil
    }

    private static func standardizedPath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }
}

/// The concrete path layout used by both indexing and the Session locations UI.
///
/// This mirrors Wake's `data_roots` / `with_custom_root` contract: the persisted selection is
/// flexible, while every producer turns it into the exact directory or SQLite file it owns.
struct ConversationSessionLocationLayout: Equatable, Sendable {
    var source: HistorySource
    var ownerRoot: URL
    var dataRoots: [URL]
    var companionFiles: [String: URL] = [:]

    var scopeID: String {
        let digest = SHA256.hash(data: Data(ownerRoot.standardizedFileURL.path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "__wake_\(source.rawValue)_\(digest)__"
    }

    func owns(_ file: URL) -> Bool {
        let path = ConversationFileInspector.storageFile(for: file).standardizedFileURL.path
        return dataRoots.contains { Self.pathOwns(root: $0.path, path: path) }
    }

    static func pathOwns(root: String, path: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        guard path.hasPrefix(root) else { return false }
        let suffix = path.dropFirst(root.count)
        return suffix.isEmpty || suffix.first == "/" || suffix.first == "#"
    }

    static func normalizedCustomRoot(
        source: HistorySource,
        selected: URL
    ) -> URL {
        let directory = selected.standardizedFileURL
        guard source == .codex else { return directory }

        let name = directory.lastPathComponent
        let looksLikeDataRoot = name == "sessions"
            || name == "archived_sessions"
            || isCodexRolloutStore(directory)
        guard looksLikeDataRoot else { return directory }
        let parent = directory.deletingLastPathComponent()
        let siblingExists: Bool
        if name == "sessions" {
            siblingExists = isDirectory(parent.appendingPathComponent("archived_sessions"))
        } else if name == "archived_sessions" {
            siblingExists = isDirectory(parent.appendingPathComponent("sessions"))
        } else {
            siblingExists = isDirectory(parent.appendingPathComponent("sessions"))
                || isDirectory(parent.appendingPathComponent("archived_sessions"))
        }
        if isFile(parent.appendingPathComponent("state_5.sqlite")) || siblingExists {
            return parent.standardizedFileURL
        }
        return directory
    }

    static func custom(
        source: HistorySource,
        selected: URL
    ) -> ConversationSessionLocationLayout {
        let root = normalizedCustomRoot(source: source, selected: selected)
        let dataRoots: [URL]
        var companions: [String: URL] = [:]

        switch source {
        case .claude, .qoder:
            dataRoots = [isDirectory(root.appendingPathComponent("projects"))
                ? root.appendingPathComponent("projects") : root]

        case .codex:
            let name = root.lastPathComponent
            if name == "archived_sessions" {
                dataRoots = [root.appendingPathComponent("sessions"), root]
            } else if name == "sessions" || isCodexRolloutStore(root) {
                dataRoots = [root, root.appendingPathComponent("archived_sessions")]
            } else {
                dataRoots = [
                    root.appendingPathComponent("sessions"),
                    root.appendingPathComponent("archived_sessions"),
                ]
            }
            companions["state"] = root.appendingPathComponent("state_5.sqlite")
            companions["config"] = root.appendingPathComponent("config.toml")

        case .copilot:
            let database = isFile(root) ? root : root.appendingPathComponent("session-store.db")
            dataRoots = [database]

        case .cursor:
            dataRoots = [isDirectory(root.appendingPathComponent("projects"))
                ? root.appendingPathComponent("projects") : root]

        case .opencode:
            let nested = root.appendingPathComponent("opencode/opencode.db")
            let database = isFile(root) ? root : (isFile(nested)
                ? nested : root.appendingPathComponent("opencode.db"))
            dataRoots = [database]

        case .kiro:
            if isDirectory(root.appendingPathComponent("sessions/cli")) {
                dataRoots = [root.appendingPathComponent("sessions/cli")]
            } else if isDirectory(root.appendingPathComponent("cli")) {
                dataRoots = [root.appendingPathComponent("cli")]
            } else {
                dataRoots = [root]
            }

        case .gemini:
            if isDirectory(root.appendingPathComponent("tmp")) {
                dataRoots = [root.appendingPathComponent("tmp")]
                companions["projects"] = root.appendingPathComponent("projects.json")
            } else {
                dataRoots = [root]
                companions["projects"] = root.deletingLastPathComponent()
                    .appendingPathComponent("projects.json")
            }

        case .pi, .omp:
            let nested = root.appendingPathComponent("agent/sessions")
            dataRoots = [isDirectory(nested) ? nested : root]

        case .grok:
            dataRoots = [isDirectory(root.appendingPathComponent("sessions"))
                ? root.appendingPathComponent("sessions") : root]

        case .kimi:
            if isDirectory(root.appendingPathComponent("sessions")) {
                dataRoots = [root.appendingPathComponent("sessions")]
                companions["index"] = root.appendingPathComponent("session_index.jsonl")
            } else {
                dataRoots = [root]
                companions["index"] = root.deletingLastPathComponent()
                    .appendingPathComponent("session_index.jsonl")
            }

        case .antigravity:
            let nested = root.appendingPathComponent(
                "antigravity-cli/conversation_summaries.db"
            )
            let database = isFile(root) ? root : (isFile(nested)
                ? nested : root.appendingPathComponent("conversation_summaries.db"))
            dataRoots = [database]

        case .dsh:
            dataRoots = [isDirectory(root.appendingPathComponent("sessions"))
                ? root.appendingPathComponent("sessions") : root]
        }

        return ConversationSessionLocationLayout(
            source: source,
            ownerRoot: root,
            dataRoots: dataRoots.map(\.standardizedFileURL),
            companionFiles: companions.mapValues(\.standardizedFileURL)
        )
    }

    static func defaults(
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openCodeDatabase: URL? = nil
    ) -> [ConversationSessionLocationLayout] {
        let home = homeDirectory.standardizedFileURL
        let codexFallback = home.appendingPathComponent(".codex")
        let codexRoot = environment["CODEX_HOME"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { value -> URL? in
                guard !value.isEmpty else { return nil }
                let candidate = URL(fileURLWithPath: value).standardizedFileURL
                guard isDirectory(candidate.appendingPathComponent("sessions"))
                        || isDirectory(candidate.appendingPathComponent("archived_sessions"))
                else { return nil }
                return candidate
            } ?? codexFallback

        let openCodeDatabase = openCodeDatabase?.standardizedFileURL
            ?? defaultOpenCodeDatabase(homeDirectory: home, environment: environment)

        func layout(
            _ source: HistorySource,
            owner: URL,
            roots: [URL],
            companions: [String: URL] = [:]
        ) -> ConversationSessionLocationLayout {
            ConversationSessionLocationLayout(
                source: source,
                ownerRoot: owner.standardizedFileURL,
                dataRoots: roots.map(\.standardizedFileURL),
                companionFiles: companions.mapValues(\.standardizedFileURL)
            )
        }

        let geminiHome = home.appendingPathComponent(".gemini")
        let kimiHome = home.appendingPathComponent(".kimi-code")
        return [
            layout(.claude, owner: home.appendingPathComponent(".claude"), roots: [
                home.appendingPathComponent(".claude/projects"),
            ]),
            layout(.codex, owner: codexRoot, roots: [
                codexRoot.appendingPathComponent("sessions"),
                codexRoot.appendingPathComponent("archived_sessions"),
            ], companions: [
                "state": codexRoot.appendingPathComponent("state_5.sqlite"),
                "config": codexRoot.appendingPathComponent("config.toml"),
            ]),
            layout(.qoder, owner: home.appendingPathComponent(".qoder"), roots: [
                home.appendingPathComponent(".qoder/projects"),
                home.appendingPathComponent(".qoderwork/projects"),
            ]),
            layout(.copilot, owner: home.appendingPathComponent(".copilot"), roots: [
                home.appendingPathComponent(".copilot/session-store.db"),
            ]),
            layout(.cursor, owner: home.appendingPathComponent(".cursor"), roots: [
                home.appendingPathComponent(".cursor/projects"),
            ]),
            layout(.opencode, owner: openCodeDatabase.deletingLastPathComponent(), roots: [
                openCodeDatabase,
            ]),
            layout(.kiro, owner: home.appendingPathComponent(".kiro"), roots: [
                home.appendingPathComponent(".kiro/sessions/cli"),
            ]),
            layout(.gemini, owner: geminiHome, roots: [
                geminiHome.appendingPathComponent("tmp"),
            ], companions: ["projects": geminiHome.appendingPathComponent("projects.json")]),
            layout(.pi, owner: home.appendingPathComponent(".pi"), roots: [
                home.appendingPathComponent(".pi/agent/sessions"),
            ]),
            layout(.omp, owner: home.appendingPathComponent(".omp"), roots: [
                home.appendingPathComponent(".omp/agent/sessions"),
            ]),
            layout(.grok, owner: home.appendingPathComponent(".grok"), roots: [
                home.appendingPathComponent(".grok/sessions"),
            ]),
            layout(.kimi, owner: kimiHome, roots: [
                kimiHome.appendingPathComponent("sessions"),
            ], companions: ["index": kimiHome.appendingPathComponent("session_index.jsonl")]),
            layout(.antigravity, owner: geminiHome.appendingPathComponent("antigravity-cli"), roots: [
                geminiHome.appendingPathComponent("antigravity-cli/conversation_summaries.db"),
            ]),
            layout(.dsh, owner: home.appendingPathComponent(".dsh"), roots: [
                home.appendingPathComponent(".dsh/sessions"),
            ]),
        ]
    }

    /// OpenCode follows `XDG_DATA_HOME`, but Wake only adopts that candidate when the database
    /// already exists; otherwise it keeps the conventional `~/.local/share` root. Callers retain
    /// this resolved URL in their history configuration so UI, discovery, purge, and watching all
    /// operate on one startup snapshot.
    static func defaultOpenCodeDatabase(
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = homeDirectory.standardizedFileURL
        let fallback = home.appendingPathComponent(".local/share/opencode/opencode.db")
        return environment["XDG_DATA_HOME"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { value -> URL? in
                guard !value.isEmpty else { return nil }
                let candidate = URL(fileURLWithPath: value)
                    .appendingPathComponent("opencode/opencode.db")
                    .standardizedFileURL
                return isFile(candidate) ? candidate : nil
            } ?? fallback
    }

    private static func isCodexRolloutStore(_ directory: URL) -> Bool {
        guard isDirectory(directory),
              !isDirectory(directory.appendingPathComponent("sessions")),
              !isDirectory(directory.appendingPathComponent("archived_sessions")) else {
            return false
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.contains { entry in
            let name = entry.lastPathComponent
            let isYear = name.count == 4 && name.allSatisfy(\.isNumber) && isDirectory(entry)
            return isYear || (name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
                && isFile(entry))
        }
    }

    private static func isDirectory(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isFile(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
