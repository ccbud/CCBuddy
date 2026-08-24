import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Why a path participates in one normalized conversation.
///
/// The distinction is useful to diagnostics and lets event-only SQLite files be observed without
/// making transient lock activity invalidate otherwise identical catalog rows.
enum ConversationDependencyRole: String, Codable, Hashable, Sendable {
    case primaryTranscript
    case primaryDatabase
    case subagentContainer
    case subagentTranscript
    case subagentMetadata
    case providerMetadata
    case customMetadata
    case sqliteWriteAheadLog
    case sqliteSharedMemory
}

enum ConversationDependencyEventScope: String, Codable, Hashable, Sendable {
    /// The path itself is owned. An event for an ancestor still matches so directory deletion and
    /// rename events invalidate children whose individual events may never arrive.
    case exact
    /// The path and every descendant are owned. Used for a subagent directory, including before
    /// that directory or a newly-created child exists.
    case descendants
}

struct ConversationSourceDependency: Codable, Hashable, Sendable {
    var file: URL
    var role: ConversationDependencyRole
    var eventScope: ConversationDependencyEventScope
    var contributesToFingerprint: Bool
    var requiresProjectionRefresh: Bool

    init(
        file: URL,
        role: ConversationDependencyRole,
        eventScope: ConversationDependencyEventScope = .exact,
        contributesToFingerprint: Bool = true,
        requiresProjectionRefresh: Bool = false
    ) {
        self.file = file.standardizedFileURL
        self.role = role
        self.eventScope = eventScope
        self.contributesToFingerprint = contributesToFingerprint
        self.requiresProjectionRefresh = requiresProjectionRefresh
    }

    func ownsEvent(at eventFile: URL) -> Bool {
        let event = eventFile.standardizedFileURL
        let owned = file.standardizedFileURL
        switch eventScope {
        case .exact:
            return event.path == owned.path || Self.isDescendant(owned, of: event)
        case .descendants:
            return event.path == owned.path
                || Self.isDescendant(event, of: owned)
                || Self.isDescendant(owned, of: event)
        }
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}

enum ConversationDependencyEntryKind: String, Codable, Hashable, Sendable {
    case missing
    case regularFile
    case directory
    case symbolicLink
    case other
    case inaccessible
}

/// A replacement-sensitive file stamp. mtime and size catch ordinary appends, while fileNumber
/// catches an atomic replacement that deliberately preserves both values.
struct ConversationDependencyStamp: Codable, Hashable, Sendable {
    var file: URL
    var role: ConversationDependencyRole
    var kind: ConversationDependencyEntryKind
    var modifiedAtNanoseconds: Int64?
    var sizeBytes: UInt64?
    var fileNumber: UInt64?

    static func read(
        _ dependency: ConversationSourceDependency,
        fileManager: FileManager = .default
    ) -> ConversationDependencyStamp {
        let file = dependency.file.standardizedFileURL
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: file.path)
        } catch {
            return ConversationDependencyStamp(
                file: file,
                role: dependency.role,
                kind: fileManager.fileExists(atPath: file.path) ? .inaccessible : .missing,
                modifiedAtNanoseconds: nil,
                sizeBytes: nil,
                fileNumber: nil
            )
        }

        let kind: ConversationDependencyEntryKind
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: kind = .regularFile
        case .typeDirectory: kind = .directory
        case .typeSymbolicLink: kind = .symbolicLink
        default: kind = .other
        }
        let modifiedAtNanoseconds = (attributes[.modificationDate] as? Date).flatMap {
            nanosecondsSinceEpoch($0)
        }
        return ConversationDependencyStamp(
            file: file,
            role: dependency.role,
            kind: kind,
            modifiedAtNanoseconds: modifiedAtNanoseconds,
            sizeBytes: unsignedInteger(attributes[.size]),
            fileNumber: unsignedInteger(attributes[.systemFileNumber])
        )
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    private static func nanosecondsSinceEpoch(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000_000_000
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else {
            return nil
        }
        return Int64(value.rounded())
    }
}

/// Codable so the index can persist it verbatim. `fingerprint` is a stable SHA-256 of canonical
/// JSON rather than Swift's process-randomized `Hasher` output.
struct ConversationDependencySnapshot: Codable, Hashable, Sendable {
    var stamps: [ConversationDependencyStamp]

    init(stamps: [ConversationDependencyStamp]) {
        self.stamps = stamps.sorted(by: Self.stampComesFirst)
    }

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(stamps)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func stamp(for file: URL, role: ConversationDependencyRole? = nil) -> ConversationDependencyStamp? {
        let path = file.standardizedFileURL.path
        return stamps.first { stamp in
            stamp.file.path == path && (role == nil || stamp.role == role)
        }
    }

    private static func stampComesFirst(
        _ lhs: ConversationDependencyStamp,
        _ rhs: ConversationDependencyStamp
    ) -> Bool {
        if lhs.file.path != rhs.file.path { return lhs.file.path < rhs.file.path }
        return lhs.role.rawValue < rhs.role.rawValue
    }
}

/// The complete file/event ownership of one candidate at a point in time.
struct ConversationDependencyManifest: Sendable {
    var candidate: HistoryFileCandidate
    var source: HistorySource
    var dependencies: [ConversationSourceDependency]

    init(
        candidate: HistoryFileCandidate,
        source: HistorySource,
        dependencies: [ConversationSourceDependency]
    ) {
        self.candidate = candidate
        self.source = source
        var seen = Set<String>()
        self.dependencies = dependencies
            .map {
                ConversationSourceDependency(
                    file: $0.file,
                    role: $0.role,
                    eventScope: $0.eventScope,
                    contributesToFingerprint: $0.contributesToFingerprint,
                    requiresProjectionRefresh: $0.requiresProjectionRefresh
                )
            }
            .filter {
                seen.insert($0.file.path + "\u{0}" + $0.role.rawValue).inserted
            }
            .sorted {
                if $0.file.path != $1.file.path { return $0.file.path < $1.file.path }
                return $0.role.rawValue < $1.role.rawValue
            }
    }

    var primary: ConversationSourceDependency? {
        dependencies.first {
            $0.role == .primaryTranscript || $0.role == .primaryDatabase
        }
    }

    func snapshot(fileManager: FileManager = .default) -> ConversationDependencySnapshot {
        ConversationDependencySnapshot(stamps: dependencies.compactMap { dependency in
            dependency.contributesToFingerprint
                ? ConversationDependencyStamp.read(dependency, fileManager: fileManager)
                : nil
        })
    }

    func ownsEvent(at eventFile: URL) -> Bool {
        dependencies.contains { $0.ownsEvent(at: eventFile) }
    }
}

struct ConversationSourceParseInput: Sendable {
    var candidate: HistoryFileCandidate
    var document: HistoryJSONLDocument?
    var facts: HistoryFileFacts
    var configuration: HistoryConfiguration
}

/// A deliberately small adapter contract. Discovery stays in `HistoryPathResolver`; provider
/// knowledge needed by parsing, dependency tracking, and watcher ownership stays here.
protocol ConversationSourceAdapter: Sendable {
    var source: HistorySource { get }
    var format: HistoryTranscriptFormat { get }
    var attachesSubagents: Bool { get }
    /// Non-nil for a user-added instance. The registry uses it for longest-prefix routing and
    /// stable per-location reconciliation scopes.
    var sessionLocation: ConversationSessionLocationLayout? { get }

    /// Enumerates this producer's canonical storage independently of the legacy configured-root
    /// resolver. A producer owns its own layout; adding an adapter must not require teaching the
    /// global path walker another directory convention.
    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate]
    /// Resolves detail/watcher paths which belong to this producer, including virtual SQLite
    /// session URLs. The default implementation matches against the adapter's discovery result.
    func candidate(
        for file: URL,
        configuration: HistoryConfiguration
    ) -> HistoryFileCandidate?
    /// Reads the producer transcript. SQLite and other non-JSONL adapters return nil; compressed
    /// adapters can transparently decode into a normal HistoryJSONLDocument here.
    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument?
    /// Roots owned by the producer for FSEvents discovery invalidation.
    func watchRoots(configuration: HistoryConfiguration) -> [URL]

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency]
    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession
}

extension ConversationSourceAdapter {
    var attachesSubagents: Bool { false }
    var sessionLocation: ConversationSessionLocationLayout? { nil }

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        []
    }

    func candidate(
        for file: URL,
        configuration: HistoryConfiguration
    ) -> HistoryFileCandidate? {
        let path = file.standardizedFileURL.path
        return discover(configuration: configuration, activeOnly: false).first {
            $0.file.standardizedFileURL.path == path
        }
    }

    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument? {
        try HistoryJSONLDocument.read(from: candidate.file, qoderReader: qoderReader)
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] { [] }
}

/// A second instance of an existing producer adapter rooted at a user-selected location.
/// Producer parsing remains single-sourced: this wrapper only activates the concrete path layout,
/// rewrites the catalog scope, and supplies the three legacy file-tree enumerators which predate
/// Wake's adapter-owned discovery contract.
private struct LocatedConversationSourceAdapter: ConversationSourceAdapter {
    let base: any ConversationSourceAdapter
    let sessionLocation: ConversationSessionLocationLayout?

    init(base: any ConversationSourceAdapter, location: ConversationSessionLocationLayout) {
        self.base = base
        sessionLocation = location
    }

    var source: HistorySource { base.source }
    var format: HistoryTranscriptFormat { base.format }
    var attachesSubagents: Bool { base.attachesSubagents }

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        guard let location = sessionLocation else { return [] }
        let directory = self.directory(location)
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }

        let candidates: [HistoryFileCandidate]
        switch source {
        case .claude, .qoder:
            candidates = discoverProjectTranscripts(location: location, directory: directory)
        case .codex:
            candidates = discoverCodexTranscripts(location: location, directory: directory)
        default:
            candidates = base.discover(
                configuration: configuration.activating(location),
                activeOnly: false
            )
        }
        return candidates.map { candidate in
            var value = candidate
            value.directory = directory
            value.formatHint = format
            return value
        }
    }

    func candidate(
        for file: URL,
        configuration: HistoryConfiguration
    ) -> HistoryFileCandidate? {
        let requested = file.standardizedFileURL.path
        return discover(configuration: configuration, activeOnly: false).first {
            $0.file.standardizedFileURL.path == requested
        }
    }

    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument? {
        try base.document(for: candidate, qoderReader: qoderReader)
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        guard let location = sessionLocation else { return [] }
        let delegated = base.watchRoots(configuration: configuration.activating(location))
        if !delegated.isEmpty { return delegated }
        return location.dataRoots.compactMap { root in
            if WakeHistoryAdapterSupport.ordinaryDirectory(root) { return root }
            let parent = root.deletingLastPathComponent()
            return WakeHistoryAdapterSupport.ordinaryDirectory(parent) ? parent : nil
        }
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        guard let location = sessionLocation else { return [] }
        return base.dependencies(
            for: candidate,
            configuration: configuration.activating(location)
        )
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        guard let location = sessionLocation else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        var rooted = input
        rooted.configuration = input.configuration.activating(location)
        return try base.parse(rooted)
    }

    private func directory(_ location: ConversationSessionLocationLayout) -> HistoryDirectory {
        let label: String
        switch source {
        case .claude: label = "Claude Code"
        case .codex: label = "Codex"
        case .qoder: label = "Qoder"
        case .grok: label = "Grok"
        case .copilot: label = "GitHub Copilot"
        case .cursor: label = "Cursor"
        case .opencode: label = "OpenCode"
        case .kiro: label = "Kiro"
        case .gemini: label = "Gemini CLI"
        case .pi: label = "Pi"
        case .omp: label = "Oh My Pi"
        case .kimi: label = "Kimi Code"
        case .antigravity: label = "Antigravity"
        case .dsh: label = "DeepSeek Harness"
        }
        let primary = location.dataRoots.first ?? location.ownerRoot
        let sqliteBacked = [HistorySource.copilot, .opencode, .antigravity].contains(source)
        let base = sqliteBacked ? primary.deletingLastPathComponent() : location.ownerRoot
        return HistoryDirectory(
            id: location.scopeID,
            label: label,
            baseURL: base,
            projectsURL: source == .claude || source == .qoder
                ? primary : base.appendingPathComponent(".ccbuddy-no-projects"),
            sessionsURL: primary
        )
    }

    private func discoverProjectTranscripts(
        location: ConversationSessionLocationLayout,
        directory: HistoryDirectory
    ) -> [HistoryFileCandidate] {
        guard let root = location.dataRoots.first,
              WakeHistoryAdapterSupport.ordinaryDirectory(root) else { return [] }
        var result: [HistoryFileCandidate] = []
        for project in WakeHistoryAdapterSupport.contents(of: root)
            where WakeHistoryAdapterSupport.ordinaryDirectory(project) {
            for file in WakeHistoryAdapterSupport.contents(of: project)
                where file.pathExtension.lowercased() == "jsonl"
                    && WakeHistoryAdapterSupport.ordinaryFile(file) {
                result.append(HistoryFileCandidate(
                    file: file,
                    projectDirectoryName: project.lastPathComponent,
                    directory: directory,
                    formatHint: format
                ))
            }
        }
        return result
    }

    private func discoverCodexTranscripts(
        location: ConversationSessionLocationLayout,
        directory: HistoryDirectory
    ) -> [HistoryFileCandidate] {
        var result: [HistoryFileCandidate] = []
        for root in location.dataRoots {
            func walk(_ folder: URL, depth: Int) {
                guard depth <= 6 else { return }
                for entry in WakeHistoryAdapterSupport.contents(of: folder) {
                    if WakeHistoryAdapterSupport.ordinaryDirectory(entry) {
                        walk(entry, depth: depth + 1)
                    } else if entry.pathExtension.lowercased() == "jsonl",
                              WakeHistoryAdapterSupport.ordinaryFile(entry) {
                        result.append(HistoryFileCandidate(
                            file: entry,
                            projectDirectoryName: nil,
                            directory: directory,
                            formatHint: format
                        ))
                    }
                }
            }
            walk(root, depth: 0)
        }
        return result
    }
}

private struct ClaudeConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.claude
    let format = HistoryTranscriptFormat.claude
    let attachesSubagents = true

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        ConversationAdapterDependencies.jsonl(candidate)
            + ConversationAdapterDependencies.subagents(candidate.file)
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        ClaudeHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct CodexConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.codex
    let format = HistoryTranscriptFormat.codex

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        var result = ConversationAdapterDependencies.jsonl(candidate)
        if candidate.directory.id != "__imported__" {
            result.append(.init(
                file: configuration.appDataRoot.appendingPathComponent("codex-meta.json"),
                role: .customMetadata
            ))
        }
        result.append(contentsOf: ConversationCodexDependencies.files(
            for: candidate.file,
            homeDirectory: configuration.homeDirectory
        ))
        return result
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        CodexHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct QoderConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.qoder
    let format = HistoryTranscriptFormat.qoder
    let attachesSubagents = true

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        var result = ConversationAdapterDependencies.jsonl(candidate)
            + ConversationAdapterDependencies.subagents(candidate.file)
        if candidate.directory.id != "__imported__" {
            result.append(.init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ))
        }
        return result
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        QoderHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct GrokConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.grok
    let format = HistoryTranscriptFormat.grok

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        WakeGrokConversationSourceAdapter().discover(
            configuration: configuration,
            activeOnly: activeOnly
        )
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        WakeGrokConversationSourceAdapter().watchRoots(configuration: configuration)
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        ConversationAdapterDependencies.jsonl(candidate) + [
            .init(
                file: candidate.file.deletingLastPathComponent()
                    .appendingPathComponent("summary.json"),
                role: .providerMetadata
            ),
            .init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        if input.candidate.file.lastPathComponent == "updates.jsonl" {
            return WakeGrokHistoryParser.parse(try ConversationAdapterDependencies.context(input))
        }
        return GrokHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct CopilotConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.copilot
    let format = HistoryTranscriptFormat.copilot

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let databaseFile = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory
                .appendingPathComponent(".copilot/session-store.db")
        )
        guard WakeHistoryAdapterSupport.ordinaryFile(databaseFile),
              (configuration.activeSessionLocation?.source == source
                || WakeHistoryAdapterSupport.isContainedInHome(
                    databaseFile,
                    homeDirectory: configuration.homeDirectory
                )),
              let database = HistorySQLiteDatabase(databaseFile) else { return [] }
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "GitHub Copilot",
            baseURL: databaseFile.deletingLastPathComponent()
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        return CopilotHistoryParser.sqliteSessionRows(database: database).compactMap { row in
            guard row.turnCount > 0 else { return nil }
            return HistoryFileCandidate(
                file: WakeHistoryAdapterSupport.virtualSessionURL(
                    database: databaseFile,
                    nativeID: row.id
                ),
                projectDirectoryName: nil,
                directory: directory,
                formatHint: format,
                nativeID: row.id,
                backingFile: databaseFile
            )
        }
    }

    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument? {
        guard candidate.backingFile == nil else { return nil }
        return try HistoryJSONLDocument.read(from: candidate.file, qoderReader: qoderReader)
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let database = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory
                .appendingPathComponent(".copilot/session-store.db")
        )
        let root = database.deletingLastPathComponent()
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        var result = candidate.backingFile == nil
            ? ConversationAdapterDependencies.jsonl(candidate)
            : ConversationAdapterDependencies.sqlite(candidate.primaryStorageFile, primary: true)
        if candidate.file.lastPathComponent == "events.jsonl" {
            result.append(.init(
                file: candidate.file.deletingLastPathComponent()
                    .appendingPathComponent("workspace.yaml"),
                role: .providerMetadata
            ))
        }
        result.append(.init(
            file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
            role: .customMetadata
        ))
        return result
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        if input.candidate.backingFile != nil {
            return try CopilotHistoryParser.parseSQLite(input)
        }
        return CopilotHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct AntigravityConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.antigravity
    let format = HistoryTranscriptFormat.antigravity

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let databaseFile = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory
                .appendingPathComponent(
                    ".gemini/antigravity-cli/conversation_summaries.db"
                )
        )
        guard WakeHistoryAdapterSupport.ordinaryFile(databaseFile),
              (configuration.activeSessionLocation?.source == source
                || WakeHistoryAdapterSupport.isContainedInHome(
                    databaseFile,
                    homeDirectory: configuration.homeDirectory
                )),
              let database = HistorySQLiteDatabase(databaseFile) else { return [] }
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "Antigravity",
            baseURL: databaseFile.deletingLastPathComponent()
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        return AntigravityHistoryParser.sqliteSummaryRows(database: database).map { row in
            HistoryFileCandidate(
                file: WakeHistoryAdapterSupport.virtualSessionURL(
                    database: databaseFile,
                    nativeID: row.id
                ),
                projectDirectoryName: nil,
                directory: directory,
                formatHint: format,
                nativeID: row.id,
                backingFile: databaseFile
            )
        }
    }

    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument? {
        nil
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(
                ".gemini/antigravity-cli/conversation_summaries.db"
            )
        ).deletingLastPathComponent()
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        if candidate.backingFile != nil {
            return ConversationAdapterDependencies.sqlite(
                candidate.primaryStorageFile,
                primary: true
            ) + [
                .init(
                    file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                    role: .customMetadata
                ),
            ]
        }
        let summary = candidate.file.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conversation_summaries.db")
        return ConversationAdapterDependencies.sqlite(candidate.file, primary: true)
            + ConversationAdapterDependencies.sqlite(summary, primary: false)
            + [
                .init(
                    file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                    role: .customMetadata
                ),
            ]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        AntigravityHistoryParser.parse(
            candidate: input.candidate,
            facts: input.facts,
            appDataRoot: input.configuration.appDataRoot
        )
    }
}

private enum ConversationAdapterDependencies {
    static func jsonl(_ candidate: HistoryFileCandidate) -> [ConversationSourceDependency] {
        [.init(file: candidate.file, role: .primaryTranscript)]
    }

    static func sqlite(
        _ file: URL,
        primary: Bool,
        contributesToFingerprint: Bool = true,
        requiresProjectionRefresh: Bool = false
    ) -> [ConversationSourceDependency] {
        [
            .init(
                file: file,
                role: primary ? .primaryDatabase : .providerMetadata,
                contributesToFingerprint: contributesToFingerprint,
                requiresProjectionRefresh: requiresProjectionRefresh
            ),
            .init(
                file: URL(fileURLWithPath: file.path + "-wal"),
                role: .sqliteWriteAheadLog,
                contributesToFingerprint: contributesToFingerprint,
                requiresProjectionRefresh: requiresProjectionRefresh
            ),
            // The SHM contains locks/index state, not durable conversation content. It owns events
            // but is excluded from the content fingerprint to avoid read-lock update loops.
            .init(
                file: URL(fileURLWithPath: file.path + "-shm"),
                role: .sqliteSharedMemory,
                contributesToFingerprint: false
            ),
        ]
    }

    static func subagents(_ mainFile: URL) -> [ConversationSourceDependency] {
        let stem = mainFile.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }
        let directory = mainFile.deletingLastPathComponent()
            .appendingPathComponent(stem, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        var result: [ConversationSourceDependency] = [
            .init(file: directory, role: .subagentContainer, eventScope: .descendants),
        ]
        for file in HistorySubagentReader.qoderPrefetchFiles(mainFile: mainFile) {
            result.append(.init(
                file: file,
                role: file.lastPathComponent.hasSuffix(".meta.json")
                    ? .subagentMetadata
                    : .subagentTranscript
            ))
        }
        return result
    }

    static func context(_ input: ConversationSourceParseInput) throws -> HistoryParseContext {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        )
    }
}

/// Dependencies consulted by canonical Codex duplicate selection. This mirrors
/// `CodexStateDatabase`'s config/environment/default precedence so a WAL-only state update can
/// re-run projection even when no rollout JSONL changed.
private enum ConversationCodexDependencies {
    static func files(for rollout: URL, homeDirectory: URL) -> [ConversationSourceDependency] {
        guard let codexHome = CodexStateDatabase.codexHome(for: rollout) else { return [] }
        let config = codexHome.appendingPathComponent("config.toml")
        var result: [ConversationSourceDependency] = [
            .init(
                file: config,
                role: .providerMetadata,
                contributesToFingerprint: false,
                requiresProjectionRefresh: true
            ),
        ]
        let sqliteHome = ForeignHistorySupport.textFile(at: config)
            .flatMap(topLevelSQLiteHome)
            .flatMap { resolve($0, codexHome: codexHome, homeDirectory: homeDirectory) }
            ?? ProcessInfo.processInfo.environment["CODEX_SQLITE_HOME"].flatMap {
                resolve($0, codexHome: codexHome, homeDirectory: homeDirectory)
            }
            ?? codexHome
        result.append(contentsOf: ConversationAdapterDependencies.sqlite(
            sqliteHome.appendingPathComponent("state_5.sqlite"),
            primary: false,
            contributesToFingerprint: false,
            requiresProjectionRefresh: true
        ))
        return result
    }

    private static func resolve(
        _ rawValue: String,
        codexHome: URL,
        homeDirectory: URL
    ) -> URL? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw == "~" { return homeDirectory.standardizedFileURL }
        if raw.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).standardizedFileURL
        }
        if (raw as NSString).isAbsolutePath {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        return codexHome.appendingPathComponent(raw).standardizedFileURL
    }

    private static func topLevelSQLiteHome(_ text: String) -> String? {
        var insideTable = false
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                insideTable = true
                continue
            }
            guard !insideTable, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "sqlite_home" else { continue }
            let encoded = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard encoded.count >= 2 else { return nil }
            if encoded.first == "'", encoded.last == "'" {
                return String(encoded.dropFirst().dropLast())
            }
            if encoded.first == "\"", encoded.last == "\"",
               let data = encoded.data(using: .utf8),
               let value = try? JSONDecoder().decode(String.self, from: data) {
                return value
            }
            return nil
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
                continue
            }
            if character == "#", quote == nil { return String(line[..<index]) }
        }
        return line
    }
}

struct ConversationSourceEventImpact: Sendable {
    var candidates: [HistoryFileCandidate]
    var requiresDiscovery: Bool
    var requiresProjectionRefresh: Bool = false
}

/// One coherent discovery pass. `completeScopeIDs` is deliberately separate from the candidate
/// list: an empty list can mean either "the producer has no sessions" or "the producer could not
/// be read right now", and only the former is authoritative enough to delete indexed rows.
struct ConversationSourceDiscovery: Sendable {
    var candidates: [HistoryFileCandidate]
    var completeScopeIDs: Set<String>
    /// Lower-priority copies of one producer-native conversation, keyed by the selected winner's
    /// logical path. The full scanner retries these in order when the newest copy cannot be parsed.
    var fallbackCandidatesByWinnerPath: [String: [HistoryFileCandidate]] = [:]
}

/// Registry and watcher-facing ownership helper. Adapters themselves remain value types and have
/// no caches, so the registry is safe to pass into detached indexing tasks.
struct ConversationSourceAdapterRegistry: Sendable {
    private let adapters: [any ConversationSourceAdapter]

    init(adapters: [any ConversationSourceAdapter] = Self.standardAdapters) {
        self.adapters = adapters
    }

    private static var standardAdapters: [any ConversationSourceAdapter] {
        [
            ClaudeConversationSourceAdapter(),
            CodexConversationSourceAdapter(),
            QoderConversationSourceAdapter(),
            GrokConversationSourceAdapter(),
            CopilotConversationSourceAdapter(),
            CursorConversationSourceAdapter(),
            OpenCodeConversationSourceAdapter(),
            KiroConversationSourceAdapter(),
            GeminiConversationSourceAdapter(),
            PiConversationSourceAdapter(),
            OMPConversationSourceAdapter(),
            KimiConversationSourceAdapter(),
            AntigravityConversationSourceAdapter(),
            DSHConversationSourceAdapter(),
        ]
    }

    private func activeAdapters(
        configuration: HistoryConfiguration
    ) -> [any ConversationSourceAdapter] {
        let removed = configuration.sessionLocationOverrides.removedDefaults
        var result = adapters.filter { !removed.contains($0.source) }
        for custom in configuration.sessionLocationOverrides.custom {
            guard let template = adapters.first(where: { $0.source == custom.source }) else {
                continue
            }
            let selected = URL(fileURLWithPath: custom.path).standardizedFileURL
            let layout = ConversationSessionLocationLayout.custom(
                source: custom.source,
                selected: selected
            )
            result.append(LocatedConversationSourceAdapter(base: template, location: layout))
        }
        return result
    }

    func adapter(for format: HistoryTranscriptFormat) -> (any ConversationSourceAdapter)? {
        adapters.first { $0.format == format }
    }

    func adapter(
        for format: HistoryTranscriptFormat,
        candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> (any ConversationSourceAdapter)? {
        let file = candidate.primaryStorageFile.standardizedFileURL
        let custom = activeAdapters(configuration: configuration)
            .filter { $0.format == format && $0.sessionLocation?.owns(file) == true }
            .max { lhs, rhs in
                let left = lhs.sessionLocation?.dataRoots
                    .filter { ConversationSessionLocationLayout.pathOwns(
                        root: $0.path,
                        path: file.path
                    ) }
                    .map { $0.path.count }.max() ?? 0
                let right = rhs.sessionLocation?.dataRoots
                    .filter { ConversationSessionLocationLayout.pathOwns(
                        root: $0.path,
                        path: file.path
                    ) }
                    .map { $0.path.count }.max() ?? 0
                return left < right
            }
        // Suppressing a default removes it from discovery, not from parsing imported sessions.
        return custom ?? adapters.first { $0.format == format }
    }

    func adapter(
        for candidate: HistoryFileCandidate,
        document: HistoryJSONLDocument?,
        configuration: HistoryConfiguration
    ) throws -> any ConversationSourceAdapter {
        let format = candidate.formatHint
            ?? document.flatMap { HistoryTranscriptFormat.detect($0.records) }
        guard let format,
              let adapter = adapter(
                for: format,
                candidate: candidate,
                configuration: configuration
              ) else {
            throw HistoryError.unsupportedTranscript(candidate.file)
        }
        return adapter
    }

    func manifest(
        for candidate: HistoryFileCandidate,
        format: HistoryTranscriptFormat,
        configuration: HistoryConfiguration
    ) throws -> ConversationDependencyManifest {
        guard let adapter = adapter(
            for: format,
            candidate: candidate,
            configuration: configuration
        ) else {
            throw HistoryError.unsupportedTranscript(candidate.file)
        }
        return ConversationDependencyManifest(
            candidate: candidate,
            source: adapter.source,
            dependencies: adapter.dependencies(for: candidate, configuration: configuration)
        )
    }

    func discoverCandidates(
        configuration: HistoryConfiguration,
        activeOnly: Bool = true
    ) -> [HistoryFileCandidate] {
        discover(configuration: configuration, activeOnly: activeOnly).candidates
    }

    /// Runs each adapter exactly once and records which scopes produced an authoritative result.
    /// SQLite adapters are bracketed by checked ID queries on independent read-only connections;
    /// candidate discovery is complete only when both snapshots agree with the adapter output.
    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool = true
    ) -> ConversationSourceDiscovery {
        let resolver = HistoryPathResolver(configuration: configuration)
        let legacyDirectories = resolver.directories(activeOnly: activeOnly)
        let legacy = resolver.discoverSessionFiles(activeOnly: activeOnly)
        let activeAdapters = activeAdapters(configuration: configuration)
        let ownerRoots = Self.ownerRoots(
            for: activeAdapters,
            configuration: configuration
        )
        var canonical: [HistoryFileCandidate] = []
        var completeScopeIDs = Set(legacyDirectories.map(\.id))

        for (adapterIndex, adapter) in activeAdapters.enumerated() {
            guard Self.hasSafeCanonicalRoot(adapter, configuration: configuration) else {
                continue
            }
            let directory = Self.canonicalDirectory(
                for: adapter,
                configuration: configuration
            )
            let adapterConfiguration = adapter.sessionLocation.map {
                configuration.activating($0)
            } ?? configuration
            let before = ConversationSQLiteDiscoveryProbe.snapshot(
                for: adapter.source,
                configuration: adapterConfiguration
            )
            let rawDiscovered = adapter.discover(
                configuration: configuration,
                activeOnly: activeOnly
            )
            // Wake assigns a path to the adapter instance with the longest owning data root. This
            // matters when different producers intentionally use nested roots: broad recursive
            // enumerators must not steal a transcript from the more specific location.
            let discovered = rawDiscovered.filter { candidate in
                Self.ownerIndex(
                    for: candidate.primaryStorageFile,
                    roots: ownerRoots
                ).map { $0 == adapterIndex } ?? true
            }
            let after = ConversationSQLiteDiscoveryProbe.snapshot(
                for: adapter.source,
                configuration: adapterConfiguration
            )
            canonical.append(contentsOf: discovered)

            guard let directory,
                  WakeHistoryAdapterSupport.isActive(
                    directory,
                    configuration: configuration,
                    activeOnly: activeOnly
                  ) else { continue }
            guard before != nil || after != nil else {
                // Directory-backed adapters are protected by the scanner's stable filesystem
                // availability proof and its per-primary-path existence check.
                completeScopeIDs.insert(directory.id)
                continue
            }
            guard before == after, let after else { continue }
            switch after {
            case .available(let expectedIDs):
                // Ownership filtering is intentional and may make this instance's published set
                // empty. Completeness is proven against the unfiltered database enumeration.
                guard Self.nativeIDs(in: rawDiscovered, scope: directory.id) == expectedIDs else {
                    continue
                }
            case .absent:
                guard !rawDiscovered.contains(where: { $0.directory.id == directory.id }) else {
                    continue
                }
            case .unavailable:
                continue
            }
            completeScopeIDs.insert(directory.id)
        }

        let canonicalPaths = Set(canonical.map { $0.file.standardizedFileURL.path })
        let routedLegacy = legacy.filter { candidate in
            guard candidate.directory.id != "__imported__",
                  !canonicalPaths.contains(candidate.file.standardizedFileURL.path),
                  let owner = Self.ownerIndex(
                      for: candidate.primaryStorageFile,
                      roots: ownerRoots
                  ) else { return true }
            guard let source = candidate.formatHint.flatMap(Self.source) else { return true }
            let adapter = activeAdapters[owner]
            // Custom adapters enumerate their own layouts canonically. If that enumeration did not
            // return this path, do not let the legacy broad walker reintroduce it under another
            // scope. Default Claude/Codex/Qoder still legitimately enter through the legacy path.
            return adapter.source == source && adapter.sessionLocation == nil
        }

        var physicallyUnique: [HistoryFileCandidate] = []
        var positions: [String: Int] = [:]
        for discoveredCandidate in canonical + routedLegacy {
            let candidate = Self.normalizingProducerNativeID(discoveredCandidate)
            let path = candidate.file.standardizedFileURL.path
            if let position = positions[path] {
                if physicallyUnique[position].formatHint == nil, candidate.formatHint != nil {
                    physicallyUnique[position] = candidate
                }
            } else {
                positions[path] = physicallyUnique.count
                physicallyUnique.append(candidate)
            }
        }

        // One producer-native conversation can exist in the default root and one or more custom
        // roots. Match Wake's arbitration: newest primary mtime wins; a tie uses lexical path order;
        // remaining copies are retained only as ordered parse fallbacks.
        var groups: [String: [HistoryFileCandidate]] = [:]
        for candidate in physicallyUnique {
            guard let key = Self.nativeConversationKey(candidate) else { continue }
            groups[key, default: []].append(candidate)
        }
        var emittedGroups = Set<String>()
        var result: [HistoryFileCandidate] = []
        var fallbacks: [String: [HistoryFileCandidate]] = [:]
        for candidate in physicallyUnique {
            guard let key = Self.nativeConversationKey(candidate) else {
                result.append(candidate)
                continue
            }
            guard emittedGroups.insert(key).inserted else { continue }
            let ordered = (groups[key] ?? [candidate]).sorted(by: Self.copyComesFirst)
            guard let winner = ordered.first else { continue }
            result.append(winner)
            if ordered.count > 1 {
                fallbacks[winner.file.standardizedFileURL.path] = Array(ordered.dropFirst())
            }
        }
        return ConversationSourceDiscovery(
            candidates: result,
            completeScopeIDs: completeScopeIDs,
            fallbackCandidatesByWinnerPath: fallbacks
        )
    }

    private struct OwnerRoot {
        var path: String
        var adapterIndex: Int
    }

    private static func ownerRoots(
        for adapters: [any ConversationSourceAdapter],
        configuration: HistoryConfiguration
    ) -> [OwnerRoot] {
        let defaults = Dictionary(uniqueKeysWithValues: ConversationSessionLocationLayout.defaults(
            homeDirectory: configuration.homeDirectory,
            openCodeDatabase: configuration.openCodeDefaultDatabase
        ).map { ($0.source, $0) })
        return adapters.enumerated().flatMap { index, adapter in
            let roots = adapter.sessionLocation?.dataRoots
                ?? defaults[adapter.source]?.dataRoots
                ?? []
            return roots.map {
                OwnerRoot(path: $0.standardizedFileURL.path, adapterIndex: index)
            }
        }
    }

    private static func ownerIndex(for file: URL, roots: [OwnerRoot]) -> Int? {
        let path = file.standardizedFileURL.path
        return roots.filter {
            ConversationSessionLocationLayout.pathOwns(root: $0.path, path: path)
        }.max { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            // Rust Iterator::max_by_key keeps the later equal element. Preserve that deterministic
            // tie-break for intentionally identical cross-producer roots.
            return lhs.adapterIndex < rhs.adapterIndex
        }?.adapterIndex
    }

    private static func nativeConversationKey(_ candidate: HistoryFileCandidate) -> String? {
        // Imports are deliberate library snapshots, not physical replicas of a live producer
        // session. Keep them independently addressable even when their source-native ID matches
        // a live/default/custom-root conversation.
        guard candidate.directory.id != "__imported__" else { return nil }
        guard let format = candidate.formatHint, let source = source(format) else { return nil }
        let explicit = candidate.nativeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeID: String
        if let explicit, !explicit.isEmpty {
            nativeID = explicit
        } else {
            var name = candidate.file.lastPathComponent
            for suffix in [".jsonl.zstd", ".jsonl"] where name.lowercased().hasSuffix(suffix) {
                name.removeLast(suffix.count)
                break
            }
            guard !name.isEmpty else { return nil }
            nativeID = name
        }
        let normalizedID = source == .codex
            ? CodexHistoryParser.rolloutNativeID(fromStem: nativeID)
            : nativeID
        return source.rawValue + "\u{0}" + normalizedID
    }

    private static func normalizingProducerNativeID(
        _ candidate: HistoryFileCandidate
    ) -> HistoryFileCandidate {
        guard candidate.formatHint == .codex else { return candidate }
        var normalized = candidate
        let explicit = candidate.nativeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawID: String
        if let explicit, !explicit.isEmpty {
            rawID = explicit
        } else {
            var stem = candidate.file.lastPathComponent
            for suffix in [".jsonl.zstd", ".jsonl"] where stem.lowercased().hasSuffix(suffix) {
                stem.removeLast(suffix.count)
                break
            }
            guard !stem.isEmpty else { return candidate }
            rawID = stem
        }
        normalized.nativeID = CodexHistoryParser.rolloutNativeID(fromStem: rawID)
        return normalized
    }

    private static func copyComesFirst(
        _ lhs: HistoryFileCandidate,
        _ rhs: HistoryFileCandidate
    ) -> Bool {
        let leftDate = primaryModificationDate(lhs)
        let rightDate = primaryModificationDate(rhs)
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.file.standardizedFileURL.path < rhs.file.standardizedFileURL.path
    }

    private static func primaryModificationDate(_ candidate: HistoryFileCandidate) -> Date {
        (try? candidate.primaryStorageFile.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .distantPast
    }

    private static func source(_ format: HistoryTranscriptFormat) -> HistorySource? {
        switch format {
        case .claude: .claude
        case .codex: .codex
        case .qoder: .qoder
        case .grok: .grok
        case .copilot: .copilot
        case .cursor: .cursor
        case .opencode: .opencode
        case .kiro: .kiro
        case .gemini: .gemini
        case .pi: .pi
        case .omp: .omp
        case .kimi: .kimi
        case .antigravity: .antigravity
        case .dsh: .dsh
        }
    }

    func discoveryDirectories(configuration: HistoryConfiguration) -> [HistoryDirectory] {
        let legacy = HistoryPathResolver(configuration: configuration).directories(activeOnly: false)
        // Canonical scopes come from adapter identity and configured home, never from successful
        // candidates. A temporarily busy database must therefore remain configured during purge.
        let canonical = activeAdapters(configuration: configuration).filter {
            Self.hasSafeCanonicalRoot($0, configuration: configuration)
        }.compactMap {
            Self.canonicalDirectory(for: $0, configuration: configuration)
        }
        var result: [HistoryDirectory] = []
        var seen = Set<String>()
        for directory in legacy + canonical where seen.insert(directory.id).inserted {
            result.append(directory)
        }
        return result
    }

    private static func nativeIDs(
        in candidates: [HistoryFileCandidate],
        scope: String
    ) -> Set<String>? {
        let scoped = candidates.filter { $0.directory.id == scope }
        let ids = scoped.compactMap(\.nativeID)
        guard ids.count == scoped.count else { return nil }
        return Set(ids)
    }

    private static func canonicalDirectory(
        for adapter: any ConversationSourceAdapter,
        configuration: HistoryConfiguration
    ) -> HistoryDirectory? {
        let source = adapter.source
        if let location = adapter.sessionLocation {
            let primary = location.dataRoots.first ?? location.ownerRoot
            let sqliteBacked = [HistorySource.copilot, .opencode, .antigravity]
                .contains(source)
            let base = sqliteBacked ? primary.deletingLastPathComponent() : location.ownerRoot
            return HistoryDirectory(
                id: location.scopeID,
                label: source.rawValue,
                baseURL: base,
                projectsURL: source == .claude || source == .qoder
                    ? primary : base.appendingPathComponent(
                        ".ccbuddy-no-projects",
                        isDirectory: true
                    ),
                sessionsURL: primary
            )
        }
        let home = configuration.homeDirectory
        let label: String
        let base: URL
        let root: URL?
        switch source {
        case .grok:
            label = "Grok"
            base = home.appendingPathComponent(".grok", isDirectory: true)
            root = base.appendingPathComponent("sessions", isDirectory: true)
        case .copilot:
            label = "GitHub Copilot"
            base = home.appendingPathComponent(".copilot", isDirectory: true)
            root = nil
        case .cursor:
            label = "Cursor"
            base = home.appendingPathComponent(".cursor", isDirectory: true)
            root = base.appendingPathComponent("projects", isDirectory: true)
        case .opencode:
            label = "OpenCode"
            base = configuration.openCodeDefaultDatabase.deletingLastPathComponent()
            root = nil
        case .kiro:
            label = "Kiro"
            base = home.appendingPathComponent(".kiro", isDirectory: true)
            root = base.appendingPathComponent("sessions/cli", isDirectory: true)
        case .gemini:
            label = "Gemini CLI"
            base = home.appendingPathComponent(".gemini", isDirectory: true)
            root = base.appendingPathComponent("tmp", isDirectory: true)
        case .pi:
            label = "Pi"
            base = home.appendingPathComponent(".pi", isDirectory: true)
            root = base.appendingPathComponent("agent/sessions", isDirectory: true)
        case .omp:
            label = "Oh My Pi"
            base = home.appendingPathComponent(".omp", isDirectory: true)
            root = base.appendingPathComponent("agent/sessions", isDirectory: true)
        case .kimi:
            label = "Kimi Code"
            base = home.appendingPathComponent(".kimi-code", isDirectory: true)
            root = base.appendingPathComponent("sessions", isDirectory: true)
        case .antigravity:
            label = "Antigravity"
            base = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
            root = nil
        case .dsh:
            label = "DeepSeek Harness"
            base = home.appendingPathComponent(".dsh", isDirectory: true)
            root = base.appendingPathComponent("sessions", isDirectory: true)
        case .claude, .codex, .qoder:
            return nil
        }
        return WakeHistoryAdapterSupport.directory(
            source: source,
            label: label,
            baseURL: base,
            discoveryRoot: root
        )
    }

    private static func hasSafeCanonicalRoot(
        _ adapter: any ConversationSourceAdapter,
        configuration: HistoryConfiguration
    ) -> Bool {
        guard let directory = canonicalDirectory(
            for: adapter,
            configuration: configuration
        ) else {
            // Claude, Codex, and Qoder remain governed by HistoryPathResolver's configured-root
            // validation instead of an implicit Wake producer root.
            return true
        }
        if adapter.sessionLocation != nil { return true }
        if adapter.source == .opencode,
           directory.baseURL.standardizedFileURL
            == configuration.openCodeDefaultDatabase
                .deletingLastPathComponent().standardizedFileURL {
            return true
        }
        return WakeHistoryAdapterSupport.isContainedInHome(
            directory.baseURL,
            homeDirectory: configuration.homeDirectory
        )
    }

    /// Physical roots trusted by adapter-owned discovery. Mutation code uses the same authority as
    /// indexing instead of maintaining a second producer-directory list.
    func ownedRoots(configuration: HistoryConfiguration) -> [URL] {
        let resolver = HistoryPathResolver(configuration: configuration)
        let roots = resolver.watchRoots() + activeAdapters(configuration: configuration).filter {
            Self.hasSafeCanonicalRoot($0, configuration: configuration)
        }.flatMap {
            $0.watchRoots(configuration: configuration)
        }
        var result: [URL] = []
        var seen = Set<String>()
        for root in roots.map({ $0.standardizedFileURL }) where seen.insert(root.path).inserted {
            result.append(root)
        }
        return result
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        ownedRoots(configuration: configuration)
    }

    func candidate(
        for file: URL,
        configuration: HistoryConfiguration
    ) throws -> HistoryFileCandidate {
        let ordered = activeAdapters(configuration: configuration).sorted { lhs, rhs in
            let left = lhs.sessionLocation?.dataRoots.map { $0.path.count }.max() ?? 0
            let right = rhs.sessionLocation?.dataRoots.map { $0.path.count }.max() ?? 0
            return left > right
        }
        for adapter in ordered where Self.hasSafeCanonicalRoot(
            adapter,
            configuration: configuration
        ) {
            if let candidate = adapter.candidate(for: file, configuration: configuration) {
                return candidate
            }
        }
        return try HistoryPathResolver(configuration: configuration).validatedCandidate(for: file)
    }

    /// Qoder's helper has meaningful fixed process overhead, so preserve the repository's batch
    /// prefetch contract for both main files and exact, security-validated subagent sidecars.
    func prefetch(
        candidates: [HistoryFileCandidate],
        qoderReader: QoderFileReader = .shared
    ) {
        let qoderCandidates = candidates.filter {
            $0.formatHint == .qoder || QoderFileReader.isQoderDataPath($0.file)
        }
        qoderReader.prefetch(
            qoderCandidates.map(\.file)
                + qoderCandidates.flatMap {
                    HistorySubagentReader.qoderPrefetchFiles(mainFile: $0.file)
                }
        )
    }

    /// Maps an FSEvents batch onto already-known candidates and also reports whether discovery is
    /// needed for additions/deletions. `knownManifests` is the reverse-map authority for deleted
    /// paths and sidecars that `validatedCandidate` intentionally cannot classify on its own.
    func eventImpact(
        _ eventFiles: [URL],
        knownManifests: [ConversationDependencyManifest],
        configuration: HistoryConfiguration
    ) -> ConversationSourceEventImpact {
        let events = eventFiles.map { $0.standardizedFileURL }
        let roots = ownedRoots(configuration: configuration)
        func touchesOwnedRoot(_ event: URL) -> Bool {
            roots.contains { root in
                event.path == root.path
                    || Self.isDescendant(event, of: root)
                    || Self.isDescendant(root, of: event)
            }
        }

        var candidates: [HistoryFileCandidate] = []
        var seen = Set<String>()
        var manifestOwnedEvents = Set<String>()
        for manifest in knownManifests where events.contains(where: manifest.ownsEvent) {
            if seen.insert(manifest.candidate.file.standardizedFileURL.path).inserted {
                candidates.append(manifest.candidate)
            }
            for event in events where manifest.ownsEvent(at: event) {
                manifestOwnedEvents.insert(event.path)
            }
        }

        let resolver = HistoryPathResolver(configuration: configuration)
        for event in events {
            guard !manifestOwnedEvents.contains(event.path) else { continue }
            // Every event under a watched producer root already forces one coherent discovery
            // pass below. Never call an adapter's default `candidate` from the watcher path: its
            // implementation may perform complete producer discovery, turning a batch into
            // O(events × sessions). Known transcripts and sidecars were mapped through manifests
            // above; configured-root transcripts resolve directly here, while canonical additions
            // and deletions are mapped by the one discovery pass.
            guard let candidate = try? resolver.validatedCandidate(for: event) else { continue }
            if seen.insert(candidate.file.standardizedFileURL.path).inserted {
                candidates.append(candidate)
            }
        }

        let requiresDiscovery = events.contains(where: touchesOwnedRoot)
        let requiresProjectionRefresh = knownManifests.contains { manifest in
            manifest.dependencies.contains { dependency in
                dependency.requiresProjectionRefresh
                    && events.contains(where: dependency.ownsEvent)
            }
        }
        return ConversationSourceEventImpact(
            candidates: candidates,
            requiresDiscovery: requiresDiscovery,
            requiresProjectionRefresh: requiresProjectionRefresh
        )
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}

private enum ConversationSQLiteDiscoveryState: Equatable, Sendable {
    case absent
    case unavailable
    case available(Set<String>)
}

/// Checked, read-only snapshots for virtual-session producers. The higher-level SQLite helper is
/// intentionally forgiving for detail fallbacks and maps prepare/step errors to `[]`; discovery
/// cannot use that ambiguity because an empty result authorizes deletion. These probes preserve
/// SQLite's exact completion status and return the native IDs which should become candidates.
private enum ConversationSQLiteDiscoveryProbe {
    static func snapshot(
        for source: HistorySource,
        configuration: HistoryConfiguration
    ) -> ConversationSQLiteDiscoveryState? {
        let database: URL
        switch source {
        case .copilot:
            database = configuration.primaryDataRoot(
                for: source,
                default: configuration.homeDirectory
                    .appendingPathComponent(".copilot/session-store.db")
            )
        case .opencode:
            database = configuration.primaryDataRoot(
                for: source,
                default: configuration.openCodeDefaultDatabase
            )
        case .antigravity:
            database = configuration.primaryDataRoot(
                for: source,
                default: configuration.homeDirectory.appendingPathComponent(
                    ".gemini/antigravity-cli/conversation_summaries.db"
                )
            )
        default:
            return nil
        }

        var metadata = stat()
        let fileStatus = database.path.withCString { Darwin.lstat($0, &metadata) }
        guard fileStatus == 0 else {
            return errno == ENOENT ? .absent : .unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return .unavailable }
        guard databaseAndSidecarsAreSafe(database) else { return .unavailable }

        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            database.standardizedFileURL.path,
            &connection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            return .unavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 25)

        let ids: Set<String>?
        switch source {
        case .copilot:
            ids = strings(
                connection,
                sql: """
                SELECT s.id
                FROM sessions s LEFT JOIN turns t ON t.session_id = s.id
                GROUP BY s.id
                HAVING COUNT(t.id) > 0
                """
            )
        case .opencode:
            ids = openCodeIDs(connection)
        case .antigravity:
            ids = strings(
                connection,
                sql: """
                SELECT conversation_id
                FROM conversation_summaries
                WHERE parent_conversation_id = '' AND nesting_depth = 0
                """
            )
        default:
            ids = nil
        }
        return ids.map(ConversationSQLiteDiscoveryState.available) ?? .unavailable
    }

    private static func databaseAndSidecarsAreSafe(_ database: URL) -> Bool {
        guard ForeignHistorySupport.isOrdinaryFile(database) else { return false }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            guard ForeignHistorySupport.isOrdinaryFile(sidecar) else { return false }
        }
        return true
    }

    private static func openCodeIDs(_ database: OpaquePointer) -> Set<String>? {
        guard let tables = strings(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
        ) else { return nil }
        let supported = ["session_v2", "session"].filter(tables.contains)
        guard !supported.isEmpty else { return nil }

        var result = Set<String>()
        for table in supported {
            guard let columns = strings(database, sql: "PRAGMA table_info(\(table))", column: 1),
                  columns.contains("id") else { return nil }
            let contentTable = table == "session_v2" ? "session_message" : "part"
            guard tables.contains(contentTable) else { continue }
            let parentPredicate = columns.contains("parent_id") ? "s.parent_id IS NULL AND " : ""
            guard let ids = strings(
                database,
                sql: """
                SELECT s.id
                FROM \(table) s
                WHERE \(parentPredicate)(
                    SELECT COALESCE(SUM(LENGTH(c.data)), 0)
                    FROM \(contentTable) c WHERE c.session_id = s.id
                ) > 0
                """
            ) else { return nil }
            result.formUnion(ids)
        }
        return result
    }

    private static func strings(
        _ database: OpaquePointer,
        sql: String,
        column: Int32 = 0
    ) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        var result = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return result
            case SQLITE_ROW:
                guard column >= 0, column < sqlite3_column_count(statement) else { return nil }
                if let text = sqlite3_column_text(statement, column) {
                    let value = String(cString: text)
                    if !value.isEmpty { result.insert(value) }
                }
            default:
                return nil
            }
        }
    }
}
