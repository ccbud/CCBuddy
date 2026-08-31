import CryptoKit
import Foundation

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

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency]
    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession
}

extension ConversationSourceAdapter {
    var attachesSubagents: Bool { false }
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
        GrokHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct CopilotConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.copilot
    let format = HistoryTranscriptFormat.copilot

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        var result = ConversationAdapterDependencies.jsonl(candidate)
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
        CopilotHistoryParser.parse(try ConversationAdapterDependencies.context(input))
    }
}

private struct AntigravityConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.antigravity
    let format = HistoryTranscriptFormat.antigravity

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
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
            AntigravityConversationSourceAdapter(),
        ]
    }

    func adapter(for format: HistoryTranscriptFormat) -> (any ConversationSourceAdapter)? {
        adapters.first { $0.format == format }
    }

    func adapter(
        for candidate: HistoryFileCandidate,
        document: HistoryJSONLDocument?
    ) throws -> any ConversationSourceAdapter {
        let format = candidate.formatHint
            ?? document.flatMap { HistoryTranscriptFormat.detect($0.records) }
        guard let format, let adapter = adapter(for: format) else {
            throw HistoryError.unsupportedTranscript(candidate.file)
        }
        return adapter
    }

    func manifest(
        for candidate: HistoryFileCandidate,
        format: HistoryTranscriptFormat,
        configuration: HistoryConfiguration
    ) throws -> ConversationDependencyManifest {
        guard let adapter = adapter(for: format) else {
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
        HistoryPathResolver(configuration: configuration)
            .discoverSessionFiles(activeOnly: activeOnly)
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
        var candidates: [HistoryFileCandidate] = []
        var seen = Set<String>()
        for manifest in knownManifests where events.contains(where: manifest.ownsEvent) {
            if seen.insert(manifest.candidate.file.standardizedFileURL.path).inserted {
                candidates.append(manifest.candidate)
            }
        }

        let resolver = HistoryPathResolver(configuration: configuration)
        for event in events {
            guard let candidate = try? resolver.validatedCandidate(for: event) else { continue }
            if seen.insert(candidate.file.standardizedFileURL.path).inserted {
                candidates.append(candidate)
            }
        }

        let roots = resolver.watchRoots().map { $0.standardizedFileURL }
        let requiresDiscovery = events.contains { event in
            roots.contains { root in
                event.path == root.path
                    || Self.isDescendant(event, of: root)
                    || Self.isDescendant(root, of: event)
            }
        }
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
