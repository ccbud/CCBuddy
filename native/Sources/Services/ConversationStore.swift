import AppKit
import Combine
import Foundation

extension HistoryRepository: ConversationHistoryProviding {
    func conversationScopeSnapshot() -> ConversationScopeSnapshot? {
        var allConfiguration = configuration
        allConfiguration.active = "all"
        let live = HistoryRepository(configuration: allConfiguration).listSessions(limit: Int.max)

        var trashConfiguration = configuration
        trashConfiguration.active = "__trash__"
        let trash = HistoryRepository(configuration: trashConfiguration).listSessions(limit: Int.max)

        return ConversationScopeSnapshot(
            sessionCounts: Dictionary(grouping: live, by: \.dirID).mapValues { $0.count },
            trashCount: trash.count,
            isAuthoritative: true
        )
    }
}

protocol ConversationMutating: Sendable {
    func updateMetadata(
        for metadata: HistorySessionMetadata,
        patch: ConversationMetadataPatch
    ) throws
    func softDelete(_ metadata: HistorySessionMetadata) throws
    func restore(_ metadata: HistorySessionMetadata) throws
    func canPermanentlyDelete(_ metadata: HistorySessionMetadata) -> Bool
    func permanentlyDelete(_ metadata: HistorySessionMetadata) throws
    func importFile(_ source: URL) -> ConversationImportDisposition
    func exportRaw(
        _ metadata: HistorySessionMetadata,
        to destination: URL
    ) throws -> ConversationRawExportResult
}

extension ConversationMutationService: ConversationMutating {}

protocol ConversationHTMLExporting: Sendable {
    func export(_ session: HistorySession, to destination: URL) throws
    func suggestedBaseName(for session: HistorySession) -> String
}

extension ConversationHTMLExporter: ConversationHTMLExporting {}

protocol ConversationExportResultOpening: Sendable {
    @MainActor func openExportedHTML(_ file: URL)
}

/// Opens a completed standalone viewer with the user's default macOS handler, matching the legacy
/// `open <file>` behavior. If Launch Services cannot open it, Finder reveals the file instead.
/// Automated and packaged self-check processes suppress both operations so verification never
/// launches a browser or steals focus.
struct ConversationWorkspaceExportResultOpener: ConversationExportResultOpening {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    @MainActor
    func openExportedHTML(_ file: URL) {
        guard Self.allowsOpening(environment: environment) else { return }
        let target = file.standardizedFileURL
        if !NSWorkspace.shared.open(target) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    static func allowsOpening(
        environment: [String: String],
        xctestLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        guard environment[SelfCheckEnvironmentGate.enabledKey] != "1" else { return false }
#if DEBUG
        guard environment["CCBUD_UI_TESTING"] != "1" else { return false }
#endif
        guard !xctestLoaded else { return false }
        let xctestHostKeys = [
            "XCTestBundlePath",
            "XCTestConfigurationFilePath",
            "XCTestSessionIdentifier",
        ]
        return !xctestHostKeys.contains(where: { !(environment[$0] ?? "").isEmpty })
    }
}

protocol ConversationFileInspecting: Sendable {
    func modificationDate(for file: URL) throws -> Date?
}

struct ConversationFileInspector: ConversationFileInspecting {
    func modificationDate(for file: URL) throws -> Date? {
        try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

enum ConversationLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum ConversationIndexingState: Equatable, Sendable {
    case idle
    case scanning(completed: Int, total: Int)
    /// The scan completed but some files could not be read. The rest of the library is usable, so
    /// this is an aside, not an alarm — one unreadable transcript out of a thousand used to paint
    /// the column header red and raise an error toast.
    case incomplete(String)
    case failed(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

struct ConversationDetailSearchMatch: Equatable, Identifiable, Sendable {
    let messageIndex: Int
    let occurrences: Int

    var id: Int { messageIndex }
}

struct ConversationJumpRequest: Equatable, Sendable {
    let id: UUID
    let messageIndex: Int
}

struct ConversationImportProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
}

enum ConversationTranscriptID: Hashable, Equatable, Sendable {
    case main
    case subagent(String)

    var accessibilityComponent: String {
        switch self {
        case .main: "main"
        case .subagent(let key): "subagent.\(key)"
        }
    }
}

struct ConversationTranscriptTab: Equatable, Identifiable, Sendable {
    let id: ConversationTranscriptID
    let parentID: ConversationTranscriptID?
    let depth: Int
    let title: String
    let description: String
    let messageCount: Int
    let file: URL
}

/// Builds the selectable transcript surface from the parsed subagent map.
///
/// A subagent key is the tool-use id that spawned it. Walking those call sites preserves the
/// actual conversation hierarchy instead of flattening dictionary values. Main-thread children
/// come first in call order, descendants immediately follow their parent, and agents without a
/// resolvable call site remain reachable at the end in a deterministic file/id/key order.
enum ConversationTranscriptPresentation {
    static func tabs(in session: HistorySession) -> [ConversationTranscriptTab] {
        let subagents = session.subagents
        var result = [ConversationTranscriptTab(
            id: .main,
            parentID: nil,
            depth: 0,
            title: "主会话",
            description: "",
            messageCount: session.messages.count,
            file: session.metadata.file.standardizedFileURL
        )]
        guard !subagents.isEmpty else { return result }

        let fallbackOrder = subagents.keys.sorted { left, right in
            guard let lhs = subagents[left], let rhs = subagents[right] else { return left < right }
            let leftPath = lhs.file.standardizedFileURL.path
            let rightPath = rhs.file.standardizedFileURL.path
            if leftPath != rightPath { return leftPath < rightPath }
            if lhs.agentID != rhs.agentID { return lhs.agentID < rhs.agentID }
            return left < right
        }
        let knownKeys = Set(fallbackOrder)
        var parentByChild: [String: ConversationTranscriptID] = [:]
        var children: [ConversationTranscriptID: [String]] = [:]

        func scan(_ messages: [HistoryMessage], parent: ConversationTranscriptID) {
            for message in messages {
                for block in message.content where block.type == "tool_use" {
                    guard let key = block.id, knownKeys.contains(key), parentByChild[key] == nil
                    else { continue }
                    parentByChild[key] = parent
                    children[parent, default: []].append(key)
                }
            }
        }

        scan(session.messages, parent: .main)
        for key in fallbackOrder {
            if let subagent = subagents[key] {
                scan(subagent.messages, parent: .subagent(key))
            }
        }

        var visited = Set<String>()
        func append(_ key: String, parent: ConversationTranscriptID?, depth: Int) {
            guard visited.insert(key).inserted, let subagent = subagents[key] else { return }
            result.append(ConversationTranscriptTab(
                id: .subagent(key),
                parentID: parent,
                depth: depth,
                title: displayName(for: subagent),
                description: subagent.description,
                messageCount: subagent.count,
                file: subagent.file.standardizedFileURL
            ))
            for child in children[.subagent(key)] ?? [] {
                append(child, parent: .subagent(key), depth: depth + 1)
            }
        }

        for key in children[.main] ?? [] {
            append(key, parent: .main, depth: 1)
        }
        // Preserve true orphan roots before breaking any malformed cycles deterministically.
        for key in fallbackOrder where !visited.contains(key) && parentByChild[key] == nil {
            append(key, parent: nil, depth: 1)
        }
        for key in fallbackOrder where !visited.contains(key) {
            append(key, parent: nil, depth: 1)
        }
        return result
    }

    static func transcript(
        _ id: ConversationTranscriptID,
        in session: HistorySession
    ) -> HistorySession? {
        switch id {
        case .main:
            return session
        case .subagent(let key):
            guard let subagent = session.subagents[key] else { return nil }
            var metadata = session.metadata
            let name = displayName(for: subagent)
            metadata.id = "\(metadata.id):subagent:\(key)"
            metadata.file = subagent.file.standardizedFileURL
            metadata.title = subagent.description.isEmpty ? name : subagent.description
            metadata.autoTitle = metadata.title
            metadata.skill = subagent.skill
            metadata.isSubagent = true
            metadata.agentPath = subagent.agentID
            metadata.agentNickname = name
            metadata.agentRole = subagent.type
            metadata.subagentCount = 0
            metadata.totals = subagent.totals
            metadata.messageCount = subagent.count
            if let first = subagent.messages.compactMap(\.timestamp).first {
                metadata.createdAt = first
            }
            if let last = subagent.messages.compactMap(\.timestamp).last {
                metadata.lastActivity = last
            }
            return HistorySession(metadata: metadata, messages: subagent.messages)
        }
    }

    static func displayName(for subagent: HistorySubagent) -> String {
        let type = subagent.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = type.isEmpty ? "agent" : type
        guard let skill = subagent.skill?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skill.isEmpty else { return base }
        return "\(base):\(skill)"
    }
}

enum ConversationScopePresentation {
    static func normalizedDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// Mirrors the legacy renderer: an empty imported bucket does not create a selector, while a
    /// populated recycle bin always does. A synthetic active bucket remains visible so the user
    /// can navigate back out even if its last item was just removed.
    static func showsScopeBar(
        directories: [String],
        snapshot: ConversationScopeSnapshot,
        active: String
    ) -> Bool {
        let configuredCount = normalizedDirectories(directories).count
        let importedIsSelectable = snapshot.importedCount > 0 || active == "__imported__"
        let selectableDirectoryCount = configuredCount + (importedIsSelectable ? 1 : 0)
        let trashIsSelectable = snapshot.trashCount > 0 || active == "__trash__"
        return selectableDirectoryCount > 1 || trashIsSelectable
    }
}

private struct ConversationListSnapshot: Sendable {
    var projects: [HistoryProject]
    var scopes: ConversationScopeSnapshot
}

enum ConversationFilter {
    static func projects(
        _ projects: [HistoryProject],
        matching rawQuery: String,
        contentHits: [String: HistorySearchHit],
        active: String = "all"
    ) -> [HistoryProject] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }

        return includingSourceHits(projects, hits: contentHits, active: active).compactMap { project in
            let projectMatches = contains(project.name, query) || contains(project.cwd, query)
            let sessions = project.sessions.filter { session in
                projectMatches
                    || contains(session.title, query)
                    || contains(session.autoTitle, query)
                    || contains(session.model ?? "", query)
                    || contains(session.source.rawValue, query)
                    || session.tags.contains(where: { contains($0, query) })
                    || contentHits[fileKey(session.file)] != nil
            }
            guard !sessions.isEmpty else { return nil }
            return HistoryProject(
                cwd: project.cwd,
                name: project.name,
                sessions: sessions,
                lastActivity: project.lastActivity
            )
        }
    }

    static func fileKey(_ file: URL) -> String {
        file.standardizedFileURL.path
    }

    static func sourceMetadata(for hit: HistorySearchHit, active: String) -> HistorySessionMetadata? {
        guard hit.count > 0, let metadata = hit.sourceMetadata,
              fileKey(metadata.file) == fileKey(hit.file), metadata.sessionID == hit.sessionID,
              metadata.source == hit.source, metadata.deleted == (active == "__trash__"),
              active == "all" || active == "__trash__" || metadata.dirID == active else { return nil }
        return metadata
    }

    static func mergingSourceNavigation(
        into metadata: HistorySessionMetadata, hit: HistorySearchHit?, active: String
    ) -> HistorySessionMetadata {
        guard let hit, fileKey(hit.file) == fileKey(metadata.file),
              let source = sourceMetadata(for: hit, active: active) else { return metadata }
        // A file reused by a different producer/session is no longer the old catalog identity.
        guard metadata.source == source.source, metadata.sessionID == source.sessionID else { return source }
        var merged = metadata
        // A newly discovered child must be loadable from an already-cataloged parent. These
        // references come from the repository's complete scoped ownership snapshot, not raw text.
        merged.subagentRefs = source.subagentRefs
        merged.subagentCount = source.subagentCount
        return merged
    }

    private static func includingSourceHits(
        _ projects: [HistoryProject], hits: [String: HistorySearchHit], active: String
    ) -> [HistoryProject] {
        guard hits.values.contains(where: { $0.sourceMetadata != nil }) else { return projects }
        var merged = projects.map { project in
            var result = project
            result.sessions = project.sessions.map {
                mergingSourceNavigation(into: $0, hit: hits[fileKey($0.file)], active: active)
            }
            return result
        }
        var knownFiles = Set(merged.flatMap(\.sessions).map { fileKey($0.file) })
        let additions = hits.compactMap { key, hit -> HistorySessionMetadata? in
            guard key == fileKey(hit.file), let metadata = sourceMetadata(for: hit, active: active),
                  knownFiles.insert(key).inserted else { return nil }
            return metadata
        }
        guard !additions.isEmpty else { return merged }
        // Catalog annotations win; only fresh source identity/navigation is overlaid above.
        // Extra rows exist only for this query and disappear when its verified hits are replaced.
        for extra in HistoryCatalogProjection.projects(from: additions) {
            if let index = merged.firstIndex(where: { $0.cwd == extra.cwd }) {
                merged[index].sessions += extra.sessions
                merged[index].sessions.sort(by: HistoryCatalogProjection.searchResultComesFirst)
                merged[index].lastActivity = max(merged[index].lastActivity, extra.lastActivity)
            } else {
                merged.append(extra)
            }
        }
        return merged.sorted {
            $0.lastActivity == $1.lastActivity ? $0.cwd < $1.cwd : $0.lastActivity > $1.lastActivity
        }
    }

    private static func contains(_ value: String, _ query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }
}

/// Rules shared by the timeline and its data-driven search index. Keeping the index on parsed
/// messages means a long transcript never has to be fully materialized just to find a phrase.
enum ConversationVisibleText {
    static func isVisible(_ message: HistoryMessage, pairedToolResultIDs: Set<String>) -> Bool {
        message.content.contains { block in
            if block.type == "tool_result", let id = block.toolUseID,
               pairedToolResultIDs.contains(id) { return false }
            switch block.type {
            case "text":
                let value = message.role == "user" ? stripInjected(block.text ?? "") : (block.text ?? "")
                return !value.isEmpty
            case "thinking": return !(block.thinking ?? "").isEmpty
            case "tool_use", "skill_load", "image": return true
            case "tool_result": return block.content != nil
            default: return block.raw != nil || block.text != nil || block.thinking != nil
            }
        }
    }

    static func resultMap(in messages: [HistoryMessage]) -> [String: HistoryContentBlock] {
        var result: [String: HistoryContentBlock] = [:]
        for message in messages {
            for block in message.content where block.type == "tool_result" {
                guard let id = block.toolUseID, !id.isEmpty else { continue }
                result[id] = block
            }
        }
        return result
    }

    static func pairedToolResultIDs(in messages: [HistoryMessage]) -> Set<String> {
        // Walked rather than flattened: `flatMap(\.content)` copies every content block in the
        // transcript into a throwaway array to read a handful of identifiers out of it.
        var result: Set<String> = []
        for message in messages {
            for block in message.content where block.type == "tool_use" {
                if let id = block.id, !id.isEmpty { result.insert(id) }
            }
        }
        return result
    }

    static func searchableText(
        for message: HistoryMessage,
        results: [String: HistoryContentBlock],
        pairedToolResultIDs: Set<String> = []
    ) -> String {
        var parts: [String] = []
        for block in message.content {
            switch block.type {
            case "text":
                let value = message.role == "user" ? stripInjected(block.text ?? "") : (block.text ?? "")
                if !value.isEmpty { parts.append(value) }
            case "thinking":
                if let value = block.thinking, !value.isEmpty { parts.append(value) }
            case "tool_use":
                if let name = block.name, !name.isEmpty { parts.append(name) }
                if let input = block.input { parts.append(input.jsonString) }
                if let id = block.id, let result = results[id], let value = toolResultText(result.content) {
                    parts.append(value)
                }
            case "tool_result":
                // Results with an id render inside their corresponding tool card. An orphan result
                // remains a standalone timeline event and therefore stays independently searchable.
                if block.toolUseID.map({ !pairedToolResultIDs.contains($0) }) ?? true,
                   let value = toolResultText(block.content) {
                    parts.append(value)
                }
            case "skill_load":
                for value in [block.name, block.raw?["path"]?.stringValue, block.raw?["snapshot"]?.stringValue] {
                    if let value, !value.isEmpty { parts.append(value) }
                }
            default:
                if let value = block.text ?? block.thinking, !value.isEmpty { parts.append(value) }
                else if let raw = block.raw { parts.append(raw.jsonString) }
            }
        }
        return parts.joined(separator: "\n")
    }

    static func detailMatches(
        in messages: [HistoryMessage],
        query rawQuery: String
    ) -> [ConversationDetailSearchMatch] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let results = resultMap(in: messages)
        let pairedIDs = pairedToolResultIDs(in: messages)
        return messages.enumerated().compactMap { index, message in
            let count = occurrenceCount(
                of: query,
                in: searchableText(for: message, results: results, pairedToolResultIDs: pairedIDs)
            )
            return count > 0 ? ConversationDetailSearchMatch(messageIndex: index, occurrences: count) : nil
        }
    }

    static func detailMatches(
        in session: HistorySession,
        query: String
    ) -> [ConversationDetailSearchMatch] {
        detailMatches(in: session.messages, query: query)
    }

    static func visibleUserText(_ message: HistoryMessage) -> String {
        message.content.compactMap { block -> String? in
            guard block.type == "text", let text = block.text else { return nil }
            let value = stripInjected(text)
            return value.isEmpty ? nil : value
        }.joined(separator: " ")
    }

    static func toolResultText(_ content: HistoryValue?) -> String? {
        guard let content else { return nil }
        if let value = content.stringValue { return value }
        if let values = content.arrayValue {
            let text = values.compactMap { item in
                item["text"]?.stringValue ?? item.stringValue
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        let value = content.jsonString
        return value.isEmpty ? nil : value
    }

    private static let injectedTransportExpressions: [NSRegularExpression] = [
        #"(?s)<system-reminder>.*?</system-reminder>"#,
        #"(?s)<command-[a-z-]+>.*?</command-[a-z-]+>"#,
        #"(?s)<local-command-[a-z]+>.*?</local-command-[a-z]+>"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func stripInjected(_ text: String) -> String {
        var value = text
        for expression in injectedTransportExpressions {
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: ""
            )
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func occurrenceCount(of query: String, in text: String, locale: Locale = .current) -> Int {
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              !Task.isCancelled,
              let range = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<text.endIndex,
                  locale: locale
              ) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }
}

struct ConversationTOCEntry: Sendable {
    let index: Int
    let title: String
    let fullText: String
}

/// Keeps expensive JSON/text preparation off the input path without retaining another complete
/// copy of an arbitrarily large transcript. The immutable source uses Array/String copy-on-write;
/// only small prepared messages are cached, with a hard eight-megabyte total budget.
final class ConversationDetailSearchIndex: @unchecked Sendable {
    private struct Entry {
        let text: String
        let needsDiacriticFallback: Bool
    }
    private let messages: [HistoryMessage]
    private let results: [String: HistoryContentBlock]
    private let pairedIDs: Set<String>
    private let lock = NSLock()
    private var cache: [Int: Entry] = [:]
    private var cacheBytes = 0
    private let maximumCacheBytes: Int
    private let maximumEntryBytes = 256 * 1_024
    private let locale: Locale

    init(messages: [HistoryMessage], results: [String: HistoryContentBlock], pairedIDs: Set<String>,
         maximumCacheBytes: Int = 8 * 1_024 * 1_024, locale: Locale = .current) {
        self.messages = messages
        self.results = results
        self.pairedIDs = pairedIDs
        self.maximumCacheBytes = max(0, maximumCacheBytes)
        self.locale = locale
    }

    var retainedTextBytes: Int { lock.withLock { cacheBytes } }

    func matches(query rawQuery: String) throws -> [ConversationDetailSearchMatch] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matcher = ConversationLiteralSearch(query: query)
        let queryNeedsFallback = query.folding(options: .diacriticInsensitive, locale: locale) != query
            || ["tr", "az", "lt"].contains(locale.language.languageCode?.identifier ?? "")
        var matches: [ConversationDetailSearchMatch] = []
        for index in messages.indices {
            try Task.checkCancellation()
            let entry = preparedText(at: index)
            try Task.checkCancellation()
            // The existing detail search ignores accents. Keep its exact Foundation behavior
            // where folding changes text; the verified literal scanner handles the common path.
            let count = queryNeedsFallback || entry.needsDiacriticFallback
                ? ConversationVisibleText.occurrenceCount(of: query, in: entry.text, locale: locale)
                : matcher.match(in: entry.text)?.count ?? 0
            try Task.checkCancellation()
            if count > 0 { matches.append(.init(messageIndex: index, occurrences: count)) }
        }
        return matches
    }

    private func preparedText(at index: Int) -> Entry {
        if let existing = lock.withLock({ cache[index] }) { return existing }
        let text = ConversationVisibleText.searchableText(
            for: messages[index], results: results, pairedToolResultIDs: pairedIDs
        )
        let entry = Entry(text: text,
            needsDiacriticFallback: text.folding(options: .diacriticInsensitive, locale: locale) != text)
        let bytes = text.utf8.count
        if bytes <= maximumEntryBytes {
            lock.withLock {
                if cache[index] == nil, bytes <= maximumCacheBytes - cacheBytes {
                    cache[index] = entry
                    cacheBytes += bytes
                }
            }
        }
        return entry
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    static let liveWindow: TimeInterval = 90

    @Published private(set) var projects: [HistoryProject] = []
    @Published private(set) var listState: ConversationLoadState = .idle
    @Published private(set) var indexingState: ConversationIndexingState = .idle
    @Published private(set) var catalogWatcherState: ConversationCatalogWatcherState = .unknown
    @Published private(set) var listQuery = ""
    @Published private(set) var contentHits: [String: HistorySearchHit] = [:]
    @Published private(set) var isSearchingContent = false
    @Published private(set) var contentSearchError: String?
    @Published private(set) var searchDiagnostics: ConversationSearchDiagnostics?
    @Published private(set) var searchDurationMilliseconds: Double?
    @Published private(set) var searchFirstResultMilliseconds: Double?
    @Published private(set) var contentSearchPhase: ConversationSearchProgress.Phase?
    private var activeSearchRunID: UUID?
    private var activeSearchProgress = ConversationSearchProgressState()
    private var activeSearchFirstResultMilliseconds: Double?
    @Published private(set) var semanticRankingEnabled = false
    @Published private(set) var semanticDiagnostics: SemanticSearchDiagnostics?
    @Published private(set) var isRankingSearch = false
    @Published private(set) var semanticRanks: [String: Int] = [:]

    @Published private(set) var selectedMetadata: HistorySessionMetadata?
    @Published private(set) var selectedSession: HistorySession?
    @Published private(set) var activeTranscriptID: ConversationTranscriptID = .main
    @Published private(set) var detailState: ConversationLoadState = .idle
    @Published private(set) var isSelectedSessionLive = false
    /// Activity is a file property; following is the reader's intent. A search or explicit jump
    /// keeps receiving live content without letting the next refresh move its reading position.
    @Published private(set) var isFollowingLatest = false
    @Published private(set) var detailRevision = 0
    @Published private(set) var followLatestRevision = 0

    @Published private(set) var detailQuery = ""
    @Published private(set) var isSearchingDetail = false
    @Published private(set) var detailMatches: [ConversationDetailSearchMatch] = []
    @Published private(set) var detailMatchIndex = -1
    @Published private(set) var jumpRequest: ConversationJumpRequest?
    /// A historical jump remains useful to pending search work. Only this separately revocable
    /// intent may correct lazy layout or replay when the timeline view is reconstructed.
    @Published private(set) var jumpLayoutRequest: ConversationScrollLayoutRequest?

    var scrollLayoutRequest: ConversationScrollLayoutRequest? {
        guard let file = activeTranscriptFile else { return nil }
        if isFollowingLatest {
            return .init(file: file, transcriptID: activeTranscriptID,
                         target: .latest(revision: followLatestRevision))
        }
        guard let request = jumpLayoutRequest, request.file == file,
              request.transcriptID == activeTranscriptID,
              case .message(let jump) = request.target, jump == jumpRequest,
              transcriptProjection.visibleMessageIndex(for: jump.messageIndex) == jump.messageIndex
        else { return nil }
        return request
    }

    /// A notice reports something that already happened; it is not a dialog, so it withdraws on its
    /// own. Failures stay longer than confirmations, because missing one costs more.
    /// What the transcript view needs about the *whole* transcript, computed once when the
    /// transcript changes.
    ///
    /// These two were being rebuilt inside the view body: every redraw walked all the messages to
    /// collect tool results and flattened every content block into a fresh array just to read ids.
    /// On a session with seventeen thousand messages that is hundreds of megabytes allocated per
    /// keystroke, which is how the process reached ten gigabytes and more.
    /// A reference type on purpose. Passed into every message row by value, the dictionary and the
    /// set were deep-compared by SwiftUI on each transaction — block by block, string by string —
    /// which is where the interface spent most of its main thread on a long transcript. One object
    /// per transcript means those comparisons are a pointer check.
    final class TranscriptProjection: Equatable, Sendable {
        struct NavigationTarget: Sendable {
            let message: HistoryMessage
            /// Only the result block retained by resultMap has a rendered owner.
            let ownerByBlock: [Int: Int]
            let unambiguousOwner: Int?
        }

        let toolResults: [String: HistoryContentBlock]
        let pairedToolResultIDs: Set<String>
        let visibleMessageIndices: [Int]
        let tableOfContents: [ConversationTOCEntry]
        let searchIndex: ConversationDetailSearchIndex
        private let navigationTargets: [Int: NavigationTarget]

        nonisolated init(
            toolResults: [String: HistoryContentBlock] = [:],
            pairedToolResultIDs: Set<String> = [],
            messages: [HistoryMessage] = [],
            visibleMessageIndices: [Int] = [],
            tableOfContents: [ConversationTOCEntry] = [],
            navigationTargets: [Int: NavigationTarget] = [:]
        ) {
            self.toolResults = toolResults
            self.pairedToolResultIDs = pairedToolResultIDs
            self.visibleMessageIndices = visibleMessageIndices
            self.tableOfContents = tableOfContents
            self.navigationTargets = navigationTargets
            searchIndex = ConversationDetailSearchIndex(messages: messages, results: toolResults,
                                                        pairedIDs: pairedToolResultIDs)
        }

        nonisolated static func == (lhs: TranscriptProjection, rhs: TranscriptProjection) -> Bool {
            lhs === rhs
        }

        nonisolated static func make(messages: [HistoryMessage]) throws -> TranscriptProjection {
            let results = ConversationVisibleText.resultMap(in: messages)
            let pairedIDs = ConversationVisibleText.pairedToolResultIDs(in: messages)
            var owners: [String: Int] = [:]
            var retainedResults: [String: (message: Int, block: Int)] = [:]
            var visible: [Int] = []
            var contents: [ConversationTOCEntry] = []
            for index in messages.indices {
                try Task.checkCancellation()
                let message = messages[index]
                for (blockIndex, block) in message.content.enumerated() {
                    if block.type == "tool_use", let id = block.id, !id.isEmpty,
                       owners[id] == nil { owners[id] = index }
                    if block.type == "tool_result", let id = block.toolUseID, !id.isEmpty {
                        retainedResults[id] = (index, blockIndex)
                    }
                }
                if ConversationVisibleText.isVisible(message, pairedToolResultIDs: pairedIDs) {
                    visible.append(index)
                }
                if message.role == "user", !message.isMetadata {
                    let value = ConversationVisibleText.visibleUserText(message)
                        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    if !value.isEmpty {
                        contents.append(.init(index: index, title: String(value.prefix(32)),
                                              fullText: String(value.prefix(200))))
                    }
                }
            }
            var navigationTargets: [Int: NavigationTarget] = [:]
            for index in messages.indices {
                try Task.checkCancellation()
                let message = messages[index]
                var blockOwners: [Int: Int] = [:]
                var hasHiddenResult = false
                var hasUnrenderedResult = false
                for (blockIndex, block) in message.content.enumerated() where block.type == "tool_result" {
                    guard let id = block.toolUseID, pairedIDs.contains(id) else { continue }
                    hasHiddenResult = true
                    guard let retained = retainedResults[id], retained.message == index,
                          retained.block == blockIndex, let owner = owners[id] else {
                        hasUnrenderedResult = true
                        continue
                    }
                    blockOwners[blockIndex] = owner
                }
                guard hasHiddenResult else { continue }
                let uniqueOwners = Set(blockOwners.values)
                navigationTargets[index] = NavigationTarget(message: message, ownerByBlock: blockOwners,
                    unambiguousOwner: !hasUnrenderedResult && uniqueOwners.count == 1 ? uniqueOwners.first : nil)
            }
            return TranscriptProjection(toolResults: results, pairedToolResultIDs: pairedIDs,
                                        messages: messages, visibleMessageIndices: visible,
                                        tableOfContents: contents, navigationTargets: navigationTargets)
        }

        /// Normal TOC/detail navigation keeps visible rows unchanged. A hidden result only
        /// redirects through a proven tool ID, never to an arbitrary neighboring message.
        nonisolated func visibleMessageIndex(for sequence: Int) -> Int? {
            if isVisible(sequence) { return sequence }
            return navigationTargets[sequence]?.unambiguousOwner
        }

        nonisolated func needsSearchResolution(for sequence: Int, query: String?) -> Bool {
            guard let query, !query.isEmpty, let target = navigationTargets[sequence] else { return false }
            return isVisible(sequence) || target.unambiguousOwner == nil
        }

        /// Runs only for an ambiguous or mixed source message, on the selection worker. Match
        /// the catalog's normalized block order, including cross-block phrases, before mapping
        /// the first hit's block to the card which actually renders it. Old duplicate results
        /// overwritten by resultMap have no such card and must not point at different content.
        nonisolated func searchMessageIndex(for sequence: Int, query: String?) throws -> Int? {
            try Task.checkCancellation()
            guard let query, !query.isEmpty, let target = navigationTargets[sequence] else {
                return visibleMessageIndex(for: sequence)
            }
            if !isVisible(sequence), let owner = target.unambiguousOwner { return owner }
            var text = ""
            var starts: [(location: Int, owner: Int?)] = []
            var utf16Count = 0
            for (index, block) in target.message.content.enumerated() {
                try Task.checkCancellation()
                guard var part = HistoryParsingSupport.plainText(block) ?? block.raw?.jsonString,
                      !part.isEmpty else { continue }
                if target.message.role == "user" { part = ConversationVisibleText.stripInjected(part) }
                guard !part.isEmpty else { continue }
                if !text.isEmpty { text.append("\n"); utf16Count += 1 }
                let isPaired = block.type == "tool_result"
                    && block.toolUseID.map { pairedToolResultIDs.contains($0) } == true
                let owner = isPaired ? target.ownerByBlock[index] : (isVisible(sequence) ? sequence : nil)
                starts.append((utf16Count, owner))
                text.append(part)
                utf16Count += part.utf16.count
            }
            try Task.checkCancellation()
            guard let match = ConversationLiteralSearch(query: query).match(in: text, countingOccurrences: false)
            else { return nil }
            let offset = match.range.lowerBound.utf16Offset(in: text)
            return starts.last { $0.location <= offset }?.owner
        }

        nonisolated private func isVisible(_ sequence: Int) -> Bool {
            var lower = 0
            var upper = visibleMessageIndices.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if visibleMessageIndices[middle] < sequence { lower = middle + 1 } else { upper = middle }
            }
            return lower < visibleMessageIndices.count && visibleMessageIndices[lower] == sequence
        }
    }

    @Published private(set) var transcriptProjection = TranscriptProjection()
    private struct PreparedTranscripts: Sendable {
        let tabs: [ConversationTranscriptTab]
        let transcripts: [ConversationTranscriptID: HistorySession]
        let projections: [ConversationTranscriptID: TranscriptProjection]

        nonisolated static func make(_ session: HistorySession) throws -> Self {
            let tabs = ConversationTranscriptPresentation.tabs(in: session)
            var transcripts: [ConversationTranscriptID: HistorySession] = [.main: session]
            var projections: [ConversationTranscriptID: TranscriptProjection] = [:]
            for tab in tabs {
                try Task.checkCancellation()
                guard let transcript = ConversationTranscriptPresentation.transcript(tab.id, in: session) else { continue }
                transcripts[tab.id] = transcript
                projections[tab.id] = try TranscriptProjection.make(messages: transcript.messages)
            }
            return Self(tabs: tabs, transcripts: transcripts, projections: projections)
        }
    }
    private var preparedTranscripts: PreparedTranscripts?
    private var preparedTranscriptsRevision = 0
    private var projectionWorker: Task<PreparedTranscripts, Error>?
    private var projectionWorkerID = UUID()
    private var detailSearchTask: Task<Void, Never>?
    private var detailSearchWorker: Task<[ConversationDetailSearchMatch], Error>?
    private var detailSearchGeneration = UUID()
    private var detailSearchNeedsResume = false
    private struct DetailSearchNavigationIntent {
        let query: String
        let transcriptID: ConversationTranscriptID
        let originalJump: ConversationJumpRequest?
    }
    private var detailSearchNavigationIntent: DetailSearchNavigationIntent?
    private var readerNavigationRevision: UInt64 = 0
    private var searchNavigationWorker: Task<Int?, Error>?
    private var searchNavigationWorkerID = UUID()
#if DEBUG
    var searchNavigationDidStartForTesting: (@Sendable () throws -> Void)?
#endif

    @Published private(set) var actionMessage: String? {
        didSet {
            guard actionMessage != nil else { return }
            scheduleActionMessageDismissal()
        }
    }
    @Published private(set) var actionIsError = false
    @Published private(set) var isMutating = false
    @Published private(set) var importProgress: ConversationImportProgress?
    @Published private(set) var historyActive = "all"
    @Published private(set) var scopeSnapshot = ConversationScopeSnapshot()
    private(set) var configuredHistoryDirectories: [String] = []

    private var repository: any ConversationHistoryProviding
    private let semanticRanker: any SemanticSearchRanking
    private var mutationService: (any ConversationMutating)?
    private var htmlExporter: any ConversationHTMLExporting
    private let exportResultOpener: any ConversationExportResultOpening
    private let fileInspector: any ConversationFileInspecting
    private let pathCopier: (String) -> Void
    private let replayURLLauncher: (URL) -> Bool
    private let noticeLifetime: (Bool) -> TimeInterval
    /// Live follow spends at most one part in `1 + ratio` of a core on re-reading a transcript.
    static let liveFollowLoadBudgetRatio: TimeInterval = 5
    private var lastDetailLoadDuration: TimeInterval = 0
    private var lastDetailLoadFinishedAt: Date?

    private var actionMessageDismissal: Task<Void, Never>?
    private var deferredTranscriptWorker: Task<Void, Never>?
    /// Survives a parent-only reload, but not a newer navigation choice by the reader.
    private struct DeferredTranscriptJump {
        let parentFileKey: String
        let transcriptID: ConversationTranscriptID
        let childFileKey: String
        let messageIndex: Int
        let searchQuery: String?
    }
    private var deferredTranscriptJump: DeferredTranscriptJump?
    private var actionMessageGeneration: UInt64 = 0
    private let pollIntervalNanoseconds: UInt64
    private let searchDelayNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var configurationSignature: String?
    private var isActive = false
    private var observedModificationDate: Date?
    private var observedIndexRevision: Int64?
    private var indexObservationGeneration = UUID()

    private var listGeneration = UUID()
    private var searchGeneration = UUID()
    private var detailGeneration = UUID()
    private var listTask: Task<Void, Never>?
    private var listWorker: Task<ConversationListSnapshot, Error>?
    private var searchTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?
    private var semanticGeneration = UUID()
    private var searchWorker: Task<[HistorySearchHit], Error>?
    private var contentSearchNeedsRefresh = false
    private var lastSearchStartedRevision: Int64?
    private struct DetailSnapshot: Sendable {
        let session: HistorySession
        let modificationDateBeforeRead: Date?
        let modificationDateAfterRead: Date?
    }

    private var detailWorker: Task<DetailSnapshot, Error>?
    private var pollingTask: Task<Void, Never>?
    private var indexRetryTask: Task<Void, Never>?
    private var revisionReloadTask: Task<Void, Never>?
    private var lastRevisionReloadAt: Date?

    /// AppModel owns persisted history scope. Imports request `__imported__` through this hook,
    /// while ordinary mutations can stay entirely inside the store.
    var requestHistoryScope: ((String) -> Void)?

    /// Explicit disk mutations invalidate the shared usage cache immediately. External CLI writes
    /// are covered by UsageHistoryWatcher's recursive FSEvents stream.
    var usageHistoryDidChange: (@MainActor @Sendable () -> Void)?

    var filteredProjects: [HistoryProject] {
        ConversationFilter.projects(projects, matching: listQuery, contentHits: contentHits, active: historyActive)
    }

    var filteredSessionCount: Int {
        filteredProjects.reduce(0) { $0 + $1.sessions.count }
    }

    /// The palette shares membership with the library. Semantic inference only reorders the
    /// bounded leading results; it never hides a literal hit or invents a transcript location.
    var orderedSearchSessions: [HistorySessionMetadata] {
        let sessions = filteredProjects.flatMap(\.sessions)
        guard !semanticRanks.isEmpty else {
            return sessions.sorted(by: HistoryCatalogProjection.searchResultComesFirst)
        }
        // Normalizing a file URL inside the comparator multiplies its cost by O(n log n).
        // Compute ranks once per row, and leave the ordinary recency path free of URL work.
        return sessions.map { session in
            (session: session, rank: semanticRanks[ConversationFilter.fileKey(session.file)] ?? Int.max)
        }.sorted {
            $0.rank == $1.rank
                ? HistoryCatalogProjection.searchResultComesFirst($0.session, $1.session)
                : $0.rank < $1.rank
        }.map(\.session)
    }

    func setSemanticRankingEnabled(_ enabled: Bool) {
        guard enabled != semanticRankingEnabled else { return }
        semanticRankingEnabled = enabled
        cancelSemanticRanking()
        // Changing ordering never clears already verified keyword hits or starts another scan.
        // An in-flight lexical search will schedule inference when its results arrive.
        if enabled && !isSearchingContent { scheduleSemanticRanking() }
    }

    private func cancelSemanticRanking() {
        semanticGeneration = UUID()
        semanticTask?.cancel()
        semanticTask = nil
        semanticRanks = [:]
        semanticDiagnostics = nil
        isRankingSearch = false
    }

    private func scheduleSemanticRanking() {
        cancelSemanticRanking()
        let query = listQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard semanticRankingEnabled, !query.isEmpty, contentSearchError == nil,
              searchDurationMilliseconds != nil,
              contentHits.values.allSatisfy(\.isCountComplete) else { return }
        let search = searchGeneration
        let ranking = semanticGeneration
        let ranker = semanticRanker
        let candidates = orderedSearchSessions.prefix(LocalSemanticSearch.candidateLimit).map { session in
            SemanticSearchCandidate(
                id: ConversationFilter.fileKey(session.file),
                text: "\(session.title)\n\(session.project)\n\(contentHit(for: session)?.snippet ?? "")"
            )
        }
        guard !candidates.isEmpty else { return }
        isRankingSearch = true
        semanticTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.semanticGeneration == ranking {
                    self.isRankingSearch = false
                    self.semanticTask = nil
                }
            }
            do {
                let result = try await ranker.rank(query: query, candidates: candidates)
                guard let self, !Task.isCancelled, self.searchGeneration == search,
                      self.semanticGeneration == ranking, self.semanticRankingEnabled else { return }
                self.semanticDiagnostics = result.diagnostics
                self.semanticRanks = Dictionary(result.orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            } catch {
                // Production ranking reports model failures as diagnostics; cancellation should
                // quietly leave exact search results and the newer generation alone.
            }
        }
    }

    var selectedFile: URL? { selectedMetadata?.file }

    var transcriptTabs: [ConversationTranscriptTab] {
        selectedSession == nil ? [] : preparedTranscripts?.tabs ?? []
    }

    var activeTranscript: HistorySession? {
        guard selectedSession != nil else { return nil }
        return preparedTranscripts?.transcripts[activeTranscriptID] ?? selectedSession
    }

    var activeTranscriptFile: URL? { activeTranscript?.metadata.file }

    var isTrash: Bool { historyActive == "__trash__" }

    var canPermanentlyDeleteSelected: Bool {
        guard let metadata = selectedMetadata, let mutationService else { return false }
        return mutationService.canPermanentlyDelete(metadata)
    }

    var selectedRawExportExtension: String {
        guard let metadata = selectedMetadata else { return "jsonl" }
        if metadata.source == .antigravity { return "db" }
        return metadata.subagentCount > 0 ? "zip" : "jsonl"
    }

    var totalDetailOccurrences: Int {
        detailMatches.reduce(0) { $0 + $1.occurrences }
    }

    var detailSearchPositionText: String {
        guard !detailQuery.isEmpty else { return "" }
        guard !detailMatches.isEmpty else { return "0/0" }
        let position = detailMatchIndex >= 0 ? String(detailMatchIndex + 1) : "–"
        let messages = "\(position)/\(detailMatches.count)"
        return totalDetailOccurrences > detailMatches.count
            ? "\(messages) · \(totalDetailOccurrences)"
            : messages
    }

    init(
        repository: any ConversationHistoryProviding,
        semanticRanker: any SemanticSearchRanking = LocalSemanticSearch.shared,
        mutationService: (any ConversationMutating)? = nil,
        htmlExporter: any ConversationHTMLExporting = ConversationHTMLExporter(),
        exportResultOpener: any ConversationExportResultOpening = ConversationWorkspaceExportResultOpener(),
        historyActive: String = "all",
        fileInspector: any ConversationFileInspecting = ConversationFileInspector(),
        pathCopier: @escaping (String) -> Void = { path in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        },
        replayURLLauncher: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        pollIntervalNanoseconds: UInt64 = 4_000_000_000,
        searchDelayNanoseconds: UInt64 = 90_000_000,
        noticeLifetime: @escaping (Bool) -> TimeInterval = { $0 ? 6 : 3.2 },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.semanticRanker = semanticRanker
        self.mutationService = mutationService
        self.htmlExporter = htmlExporter
        self.exportResultOpener = exportResultOpener
        self.historyActive = historyActive
        self.fileInspector = fileInspector
        self.pathCopier = pathCopier
        self.replayURLLauncher = replayURLLauncher
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.searchDelayNanoseconds = searchDelayNanoseconds
        self.noticeLifetime = noticeLifetime
        self.now = now
    }

    convenience init(
        config: AppConfig,
        importsRoot: URL? = nil,
        fileInspector: any ConversationFileInspecting = ConversationFileInspector(),
        pollIntervalNanoseconds: UInt64 = 4_000_000_000,
        searchDelayNanoseconds: UInt64 = 90_000_000,
        noticeLifetime: @escaping (Bool) -> TimeInterval = { $0 ? 6 : 3.2 },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let mutationConfiguration = ConversationMutationConfiguration(
            historyDirs: config.historyDirs,
            importsRoot: importsRoot
        )
        self.init(
            repository: Self.productionHistoryProvider(
                config: config,
                importsRoot: mutationConfiguration.importsRoot
            ),
            mutationService: ConversationMutationService(configuration: mutationConfiguration),
            historyActive: config.historyActive,
            fileInspector: fileInspector,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            searchDelayNanoseconds: searchDelayNanoseconds,
            now: now
        )
        configurationSignature = Self.signature(
            for: config,
            importsRoot: mutationConfiguration.importsRoot
        )
        configuredHistoryDirectories = config.historyDirs
    }

    deinit {
        (repository as? any ConversationIndexedHistoryProviding)?.stopIndexing()
        listTask?.cancel()
        listWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
        semanticTask?.cancel()
        detailWorker?.cancel()
        projectionWorker?.cancel()
        detailSearchTask?.cancel()
        detailSearchWorker?.cancel()
        searchNavigationWorker?.cancel()
        pollingTask?.cancel()
        indexRetryTask?.cancel()
        revisionReloadTask?.cancel()
        revisionReloadTask = nil
    }

    func configure(config: AppConfig, importsRoot: URL? = nil) {
        configuredHistoryDirectories = config.enabledHistoryDirs
        let mutationConfiguration = ConversationMutationConfiguration(
            historyDirs: config.enabledHistoryDirs,
            importsRoot: importsRoot
        )
        let signature = Self.signature(
            for: config,
            importsRoot: mutationConfiguration.importsRoot
        )
        let indexed = repository as? any ConversationIndexedHistoryProviding
        let topologyUnchanged = signature == configurationSignature
            || indexed?.indexTopologySignature == signature
        let activeChanged = historyActive != config.historyActive
        guard !topologyUnchanged || activeChanged else { return }

        configurationSignature = signature
        cancelTransientWork()

        if topologyUnchanged, activeChanged {
            if let indexed {
                repository = indexed.scoped(to: config.historyActive)
            } else {
                repository = Self.productionHistoryProvider(
                    config: config,
                    importsRoot: mutationConfiguration.importsRoot
                )
            }
            let recoveredIndexedRepository = indexed == nil
                && (repository as? any ConversationIndexedHistoryProviding) != nil
            historyActive = config.historyActive
            // Never leave rows from the previous scope interactive while the scoped warm-catalog
            // read is in flight. The shared index remains alive and makes this reload inexpensive.
            projects = []
            listState = .idle
            clearSelection()
            if isActive {
                requestReload()
                restartContentSearchIfNeeded()
                // A previous catalog-open failure may have left this store on the raw fallback.
                // If the retry above recovered an indexed repository, start its empty/warm
                // catalog now instead of waiting for the user to leave and reopen this view.
                if recoveredIndexedRepository { startIndexing() }
            }
            return
        }

        stopIndexing()
        repository = Self.productionHistoryProvider(
            config: config,
            importsRoot: mutationConfiguration.importsRoot
        )
        observedIndexRevision = nil
        mutationService = ConversationMutationService(configuration: mutationConfiguration)
        historyActive = config.historyActive
        indexingState = .idle
        catalogWatcherState = .unknown
        projects = []
        scopeSnapshot = ConversationScopeSnapshot()
        listState = .idle
        clearSelection()
        if isActive {
            requestReload()
            restartContentSearchIfNeeded()
            startIndexing()
        }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        if detailSearchNeedsResume {
            detailSearchNeedsResume = false
            rebuildDetailSearch(preservingMessageIndex: currentDetailMatchMessageIndex, jumpToFirst: false)
        }
        // Always re-read the warm catalog. Indexing remains app-lifetime work while this view is
        // inactive, so a revision may have advanced while its UI observer was detached.
        requestReload()
        restartContentSearchIfNeeded()
        startIndexing()
        startPolling()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        cancelSemanticRanking()
        searchDiagnostics = nil
        searchDurationMilliseconds = nil
        searchFirstResultMilliseconds = nil
        contentSearchPhase = nil
        activeSearchRunID = nil
        indexObservationGeneration = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        listTask?.cancel()
        listWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
        contentSearchNeedsRefresh = false
        lastSearchStartedRevision = nil
        detailWorker?.cancel()
        cancelProjectionPreparation()
        detailSearchNeedsResume = isSearchingDetail
        cancelDetailSearch()
        indexRetryTask?.cancel()
        revisionReloadTask?.cancel()
        revisionReloadTask = nil
        indexRetryTask = nil
        isSearchingContent = false
        indexingState = .idle
        if listState == .loading { listState = projects.isEmpty ? .idle : .loaded }
        if detailState == .loading { detailState = selectedSession == nil ? .idle : .loaded }
    }

    func requestReload() {
        listTask?.cancel()
        let generation = beginListLoad()
        listTask = Task { @MainActor [weak self] in
            await self?.performListLoad(generation: generation)
        }
    }

    /// A list retry must repair the derived catalog, not merely read the same empty/failed rows
    /// again. The coordinator serializes this full reconciliation behind any in-flight scan and
    /// also uses its completion to retry an unavailable watcher.
    func retryIndexing() {
        guard isActive else { return }
        guard let indexed = repository as? any ConversationIndexedHistoryProviding else {
            requestReload()
            return
        }

        indexRetryTask?.cancel()
        revisionReloadTask?.cancel()
        revisionReloadTask = nil
        let observation = indexObservationGeneration
        if projects.isEmpty { listState = .loading }
        indexingState = .scanning(completed: 0, total: 0)
        indexRetryTask = Task { @MainActor [weak self] in
            defer {
                if self?.indexObservationGeneration == observation {
                    self?.indexRetryTask = nil
                }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    try indexed.reconcileIndex()
                    try Task.checkCancellation()
                }.value
                guard let self, self.isActive,
                      self.indexObservationGeneration == observation else { return }
                self.indexingState = .idle
                self.requestReload()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isActive,
                      self.indexObservationGeneration == observation else { return }
                self.publishIndexFailure("会话索引失败：\(error.localizedDescription)")
            }
        }
    }

    func reload() async {
        listTask?.cancel()
        let generation = beginListLoad()
        await performListLoad(generation: generation)
    }

    func updateListQuery(_ query: String) {
        if query != listQuery {
            cancelSearchNavigation()
            jumpLayoutRequest = nil
        }
        listQuery = query
        searchTask?.cancel()
        searchWorker?.cancel()
        searchTask = nil
        searchWorker = nil
        contentSearchNeedsRefresh = false
        lastSearchStartedRevision = nil
        searchGeneration = UUID()
        contentHits = [:]
        contentSearchError = nil
        searchDiagnostics = nil
        searchDurationMilliseconds = nil
        searchFirstResultMilliseconds = nil
        contentSearchPhase = nil
        activeSearchRunID = nil
        cancelSemanticRanking()
        isSearchingContent = false

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueueContentSearch(query: trimmed)
    }

    private func enqueueContentSearch(query: String) {
        isSearchingContent = true
        let generation = searchGeneration
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.searchDelayNanoseconds)
            } catch {
                return
            }
            await self.performContentSearch(query: query, generation: generation)
        }
    }

    /// Automatic index updates must not starve a slower exact search. Keep the current query
    /// generation and its visible results, then coalesce revisions into one trailing refresh.
    /// User query/scope changes still use updateListQuery/cancelTransientWork to cancel eagerly.
    private func refreshContentSearchForCatalogRevision() {
        let query = listQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, lastSearchStartedRevision != observedIndexRevision else { return }
        if isSearchingContent {
            contentSearchNeedsRefresh = true
            return
        }
        contentSearchNeedsRefresh = false
        contentSearchError = nil
        enqueueContentSearch(query: query)
    }

    func select(
        _ metadata: HistorySessionMetadata,
        searchHit: HistorySearchHit? = nil
    ) async {
        let searchQuery = listQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        let file = metadata.file.standardizedFileURL
        deferredTranscriptJump = nil
        detailWorker?.cancel()
        cancelProjectionPreparation()
        cancelDetailSearch()
        detailSearchNeedsResume = false
        detailGeneration = UUID()
        let generation = detailGeneration
        selectedMetadata = metadata
        selectedSession = nil
        preparedTranscripts = nil
        preparedTranscriptsRevision += 1
        transcriptProjection = TranscriptProjection()
        activeTranscriptID = .main
        observedModificationDate = nil
        isSelectedSessionLive = Self.isLive(lastActivity: metadata.lastActivity, now: now())
        isFollowingLatest = searchHit == nil && isSelectedSessionLive
        detailState = .loading
        detailQuery = ""
        detailMatches = []
        detailMatchIndex = -1
        jumpRequest = nil
        await loadDetail(
            file: file,
            generation: generation,
            initialSelection: true
        )
        guard detailGeneration == generation, detailState == .loaded,
              let searchHit else { return }
        let transcriptID: ConversationTranscriptID = searchHit.agent == "main"
            ? .main
            : .subagent(searchHit.agent)
        if transcriptTabs.contains(where: { $0.id == transcriptID }) {
            activeTranscriptID = transcriptID
            refreshTranscriptProjection()
            loadDeferredTranscriptIfNeeded(transcriptID, jumpToSequence: searchHit.sequence,
                                           searchQuery: searchQuery, forceRead: true)
            detailRevision += 1
        }
        if let sequence = searchHit.sequence,
           activeTranscript?.messages.indices.contains(sequence) == true {
            await jumpToSearchSequence(sequence, query: searchQuery)
        }
    }

    func retrySelectedSession() async {
        guard let metadata = selectedMetadata else { return }
        await select(metadata)
    }

    func clearSelection() {
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        deferredTranscriptJump = nil
        detailGeneration = UUID()
        detailWorker?.cancel()
        detailWorker = nil
        cancelProjectionPreparation()
        cancelDetailSearch()
        detailSearchNeedsResume = false
        selectedMetadata = nil
        selectedSession = nil
        preparedTranscripts = nil
        preparedTranscriptsRevision += 1
        transcriptProjection = TranscriptProjection()
        activeTranscriptID = .main
        observedModificationDate = nil
        isSelectedSessionLive = false
        isFollowingLatest = false
        detailState = .idle
        detailQuery = ""
        detailMatches = []
        detailMatchIndex = -1
        jumpRequest = nil
    }

    func refreshSelectedFileIfChanged(respectingLoadBudget: Bool = false) async {
        guard let file = selectedFile?.standardizedFileURL else { return }
        let inspectedGeneration = detailGeneration
        let inspector = fileInspector
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let value = try inspector.modificationDate(for: file)
            try Task.checkCancellation()
            return value
        }

        let current: Date?
        do {
            current = try await worker.value
        } catch is CancellationError {
            return
        } catch {
            guard detailGeneration == inspectedGeneration,
                  selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
            let message = "无法检查会话文件：\(error.localizedDescription)"
            detailState = .failed(message)
            cancelDetailSearch()
            actionMessage = message
            actionIsError = true
            return
        }

        guard detailGeneration == inspectedGeneration,
              selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
        guard let current else {
            // Keep the missing selection/title for the failure explanation, but revoke every
            // asynchronous snapshot/search that could otherwise resurrect its old transcript.
            let metadata = selectedMetadata
            clearSelection()
            selectedMetadata = metadata
            detailState = .failed("会话文件已不存在")
            return
        }

        isSelectedSessionLive = Self.isLive(lastActivity: current, now: now())
        guard let previous = observedModificationDate else {
            observedModificationDate = current
            return
        }
        guard current != previous else { return }
        if respectingLoadBudget {
            // Polling a live session means re-reading and re-parsing the whole transcript, and a
            // long one costs seconds of CPU and hundreds of megabytes of short-lived objects.
            // Bound background follow by what the last read cost. Explicit refreshes remain
            // immediate; `observed` stays behind here so the next poll retries.
            guard Date().timeIntervalSince(lastDetailLoadFinishedAt ?? .distantPast)
                >= lastDetailLoadDuration * Self.liveFollowLoadBudgetRatio else { return }
        }
        observedModificationDate = current

        detailWorker?.cancel()
        cancelProjectionPreparation()
        detailGeneration = UUID()
        let generation = detailGeneration
        await loadDetail(
            file: file,
            generation: generation,
            initialSelection: false
        )
    }

    func updateDetailQuery(_ query: String) {
        guard query != detailQuery else { return }
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        detailQuery = query
        detailMatches = []
        detailMatchIndex = -1
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isFollowingLatest = false
        }
        rebuildDetailSearch(preservingMessageIndex: nil, jumpToFirst: true)
    }

    func selectTranscript(_ id: ConversationTranscriptID) {
        guard id != activeTranscriptID,
              transcriptTabs.contains(where: { $0.id == id }) else { return }
        cancelSearchNavigation()
        deferredTranscriptJump = nil
        cancelDetailSearch()
        jumpLayoutRequest = nil
        activeTranscriptID = id
        refreshTranscriptProjection()
        loadDeferredTranscriptIfNeeded(id, forceRead: true)
        detailQuery = ""
        detailMatches = []
        detailMatchIndex = -1
        jumpRequest = nil
        detailRevision += 1
        jumpToFirstVisibleMessage()
    }

    /// A child that lives in its own file is described by the catalog but only read when its tab is
    /// opened. Opening a session that delegated forty tasks would otherwise parse forty transcripts
    /// nobody asked for.
    private func loadDeferredTranscriptIfNeeded(
        _ id: ConversationTranscriptID,
        jumpToSequence: Int? = nil,
        searchQuery: String? = nil,
        forceRead: Bool = false
    ) {
        guard case .subagent(let agentID) = id,
              let subagent = selectedSession?.subagents[agentID],
              subagent.messages.isEmpty,
              subagent.count > 0 || forceRead || deferredTranscriptJump?.transcriptID == id
        else { return }

        // A quick-metadata count of zero is not proof that the child body is empty. Explicit
        // selection/search must read its authorized source; a pending jump survives parent reload.

        let file = subagent.file
        let childFileKey = ConversationFilter.fileKey(file)
        let parentFileKey = selectedFile.map(ConversationFilter.fileKey)
        if let jumpToSequence, let parentFileKey {
            deferredTranscriptJump = DeferredTranscriptJump(
                parentFileKey: parentFileKey, transcriptID: id,
                childFileKey: childFileKey, messageIndex: jumpToSequence, searchQuery: searchQuery
            )
        } else if let pending = deferredTranscriptJump,
                  pending.parentFileKey != parentFileKey
                    || pending.transcriptID != id || pending.childFileKey != childFileKey {
            deferredTranscriptJump = nil
        }
        let generation = detailGeneration
        let provider = repository
        deferredTranscriptWorker?.cancel()
        deferredTranscriptWorker = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> HistorySession? in
                try? provider.getSession(file: file)
            }.value
            guard let self, !Task.isCancelled, let loaded else { return }
            while true {
                guard !Task.isCancelled, self.detailGeneration == generation,
                      self.activeTranscriptID == id,
                      var session = self.selectedSession,
                      var child = session.subagents[agentID],
                      child.file.standardizedFileURL == file.standardizedFileURL else { return }
                let revision = self.preparedTranscriptsRevision
                child.messages = loaded.messages
                child.count = loaded.messages.count
                child.totals = loaded.metadata.totals
                session.subagents[agentID] = child
                let updatedSession = session
                let preparation = Task.detached(priority: .userInitiated) {
                    try PreparedTranscripts.make(updatedSession)
                }
                let prepared = try? await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                guard let prepared, !Task.isCancelled, self.detailGeneration == generation,
                      self.activeTranscriptID == id else { return }
                // A parent refresh can publish while the worker prepares this child. Reattach
                // to that newer parent instead of rolling its messages back to our old snapshot.
                guard self.preparedTranscriptsRevision == revision else { continue }
                self.preparedTranscripts = prepared
                self.preparedTranscriptsRevision += 1
                self.selectedSession = updatedSession
                break
            }
            self.refreshTranscriptProjection()
            self.rebuildDetailSearch(preservingMessageIndex: nil, jumpToFirst: false)
            self.detailRevision += 1
            if let pending = self.deferredTranscriptJump,
               pending.parentFileKey == self.selectedFile.map(ConversationFilter.fileKey),
               pending.transcriptID == id, pending.childFileKey == childFileKey {
                self.deferredTranscriptJump = nil
                if loaded.messages.indices.contains(pending.messageIndex) {
                    await self.jumpToSearchSequence(pending.messageIndex, query: pending.searchQuery)
                }
            } else if self.isFollowingLatest {
                // Latest may have been chosen while the child was still empty. Apply that
                // current intent now that its bottom anchor has actual content to follow.
                self.followLatestRevision += 1
            }
        }
    }

    /// Describes the catalog's separate-file children on the session that was just read, so its tabs
    /// appear immediately with their titles and sizes.
    nonisolated static func attachingSubagentRefs(
        of metadata: HistorySessionMetadata?,
        to session: HistorySession,
        preserving previousSession: HistorySession? = nil
    ) -> HistorySession {
        guard let refs = metadata?.subagentRefs, !refs.isEmpty else { return session }
        var result = session
        let previous = previousSession.flatMap {
            ConversationFilter.fileKey($0.metadata.file) == ConversationFilter.fileKey(session.metadata.file)
                ? $0 : nil
        }
        for ref in refs where !ref.threadID.isEmpty {
            guard result.subagents[ref.threadID] == nil else { continue }
            var child = HistorySubagent(
                agentID: ref.threadID,
                file: ref.file,
                type: "agent",
                description: ref.agentNickname ?? ref.title,
                count: ref.messageCount,
                totals: ref.totals,
                messages: []
            )
            // A parent-only refresh does not reread these separate files. Retain a child's
            // already-loaded snapshot only while both its thread and physical file still match.
            if let loaded = previous?.subagents[ref.threadID],
               !loaded.messages.isEmpty,
               ConversationFilter.fileKey(loaded.file) == ConversationFilter.fileKey(ref.file) {
                child.messages = loaded.messages
                child.count = loaded.count
                child.totals = loaded.totals
            }
            result.subagents[ref.threadID] = child
        }
        result.metadata.subagentRefs = refs
        result.metadata.subagentCount = result.subagents.count
        return result
    }

    func nextDetailMatch() {
        guard !detailMatches.isEmpty else { return }
        let next = detailMatchIndex < 0 ? 0 : (detailMatchIndex + 1) % detailMatches.count
        selectDetailMatch(at: next)
    }

    func previousDetailMatch() {
        guard !detailMatches.isEmpty else { return }
        let previous = detailMatchIndex < 0
            ? detailMatches.count - 1
            : (detailMatchIndex - 1 + detailMatches.count) % detailMatches.count
        selectDetailMatch(at: previous)
    }

    func jump(to messageIndex: Int) {
        cancelSearchNavigation()
        guard let visibleIndex = transcriptProjection.visibleMessageIndex(for: messageIndex) else { return }
        deferredTranscriptJump = nil
        isFollowingLatest = false
        readerNavigationRevision &+= 1
        let request = ConversationJumpRequest(id: UUID(), messageIndex: visibleIndex)
        jumpRequest = request
        jumpLayoutRequest = activeTranscriptFile.map {
            .init(file: $0, transcriptID: activeTranscriptID, target: .message(request))
        }
    }

    private func jumpToSearchSequence(_ sequence: Int, query: String?) async {
        let projection = transcriptProjection
        guard projection.needsSearchResolution(for: sequence, query: query) else {
            jump(to: sequence)
            return
        }
        let generation = detailGeneration
        let transcriptID = activeTranscriptID
        let navigationRevision = readerNavigationRevision
        let searchGeneration = detailSearchGeneration
        cancelSearchNavigation()
        let workerID = searchNavigationWorkerID
#if DEBUG
        let didStart = searchNavigationDidStartForTesting
#endif
        let worker = Task.detached(priority: .userInitiated) { () throws -> Int? in
#if DEBUG
            try didStart?()
#endif
            try Task.checkCancellation()
            return try projection.searchMessageIndex(for: sequence, query: query)
        }
        searchNavigationWorker = worker
        defer {
            if searchNavigationWorkerID == workerID { searchNavigationWorker = nil }
        }
        let resolved = try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, searchNavigationWorkerID == workerID, detailGeneration == generation,
              activeTranscriptID == transcriptID, transcriptProjection === projection,
              readerNavigationRevision == navigationRevision, detailSearchGeneration == searchGeneration,
              !isFollowingLatest, let resolved else { return }
        jump(to: resolved)
    }

    private func cancelSearchNavigation() {
        searchNavigationWorkerID = UUID()
        searchNavigationWorker?.cancel()
        searchNavigationWorker = nil
    }

    func jumpToLatest() {
        guard selectedSession != nil else { return }
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        readerNavigationRevision &+= 1
        deferredTranscriptJump = nil
        jumpRequest = nil
        isFollowingLatest = true
        followLatestRevision += 1
    }

    func pauseFollowingLatestFromUserScroll() {
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        readerNavigationRevision &+= 1
        deferredTranscriptJump = nil
        detailSearchNavigationIntent = nil
        if isFollowingLatest { isFollowingLatest = false }
    }

    func contentHit(for metadata: HistorySessionMetadata) -> HistorySearchHit? {
        contentHits[ConversationFilter.fileKey(metadata.file)]
    }

    func copySelectedPath() {
        guard let path = activeTranscriptFile?.path else { return }
        pathCopier(path)
        actionMessage = "已复制会话路径"
        actionIsError = false
    }

    func revealSelectedInFinder() {
        guard let file = selectedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        actionMessage = "已在 Finder 中显示"
        actionIsError = false
    }

    func replaySelected(
        in destination: ConversationReplayDestination,
        language: AppLanguage = .simplifiedChinese
    ) {
        guard let session = activeTranscript else { return }
        guard let url = ConversationReplayLink.makeURL(
            destination: destination,
            session: session,
            language: language
        ) else {
            actionMessage = "无法生成 \(destination.displayName) 复盘链接"
            actionIsError = true
            return
        }
        guard replayURLLauncher(url) else {
            actionMessage = "无法打开 \(destination.displayName)，请确认已安装桌面应用"
            actionIsError = true
            return
        }
        actionMessage = "已在 \(destination.displayName) 中打开会话记录"
        actionIsError = false
    }

    /// Puts the review request on the clipboard instead of handing it to an app.
    ///
    /// Only two desktop apps register a scheme we can address; this is how the same request reaches
    /// a third, or the web client, or a terminal the user already has open.
    func copyReplayPrompt(
        for destination: ConversationReplayDestination,
        language: AppLanguage = .simplifiedChinese
    ) {
        guard let session = activeTranscript else { return }
        pathCopier(ConversationReplayLink.clipboardText(
            for: destination,
            session: session,
            language: language
        ))
        actionMessage = "已复制复盘提示词与文件清单"
        actionIsError = false
    }

    func updateSelectedMetadata(title: String, tags: [String]) async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        let file = metadata.file
        let selectionGeneration = detailGeneration
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.updateMetadata(
                    for: metadata,
                    patch: .init(title: title, tags: tags)
                )
                try Task.checkCancellation()
            }.value
            await reconcileMetadataMutation(file, selectionGeneration: selectionGeneration)
            actionMessage = "标题与标签已更新"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "更新失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    /// Toggles Wake's star on the selected session.
    ///
    /// The flag lives in CC Buddy's own metadata — inline for imports, in a sidecar for every
    /// foreign tree — so starring never writes into a transcript an agent owns.
    func toggleStarSelected() async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        let file = metadata.file
        let selectionGeneration = detailGeneration
        let starred = !metadata.starred
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.updateMetadata(for: metadata, patch: .init(starred: starred))
                try Task.checkCancellation()
            }.value
            await reconcileMetadataMutation(file, selectionGeneration: selectionGeneration)
            actionMessage = starred ? "已收藏会话" : "已取消收藏"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "更新失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    /// Holds the selected session at the top of the stream.
    func togglePinSelected() async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        let file = metadata.file
        let selectionGeneration = detailGeneration
        let pinned = !metadata.pinned
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.updateMetadata(for: metadata, patch: .init(pinned: pinned))
                try Task.checkCancellation()
            }.value
            await reconcileMetadataMutation(file, selectionGeneration: selectionGeneration)
            actionMessage = pinned ? "已置顶会话" : "已取消置顶"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "更新失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    func softDeleteSelected() async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.softDelete(metadata)
            }.value
            let mutationSearchGeneration = revokeSearchAfterSourceMutation(metadata.file)
            await synchronizeIndex(files: [metadata.file])
            usageHistoryDidChange?()
            clearSelection()
            await reload()
            restartSearchAfterSourceMutation(generation: mutationSearchGeneration)
            actionMessage = "会话已移入回收站"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "删除失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    func restoreSelected() async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.restore(metadata)
            }.value
            let mutationSearchGeneration = revokeSearchAfterSourceMutation(metadata.file)
            await synchronizeIndex(files: [metadata.file])
            usageHistoryDidChange?()
            clearSelection()
            await reload()
            restartSearchAfterSourceMutation(generation: mutationSearchGeneration)
            actionMessage = "会话已恢复"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "恢复失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    func permanentlyDeleteSelected() async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.permanentlyDelete(metadata)
            }.value
            let mutationSearchGeneration = revokeSearchAfterSourceMutation(metadata.file)
            await synchronizeIndex()
            usageHistoryDidChange?()
            clearSelection()
            await reload()
            restartSearchAfterSourceMutation(generation: mutationSearchGeneration)
            actionMessage = "会话已永久删除"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "永久删除失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    /// A successful source mutation invalidates the old search authorization immediately, before
    /// any catalog/reload await. Otherwise query-local source metadata can resurrect the removed
    /// row, including through a progressive callback that was already queued on the main actor.
    /// Keep unrelated verified results visible while their replacement search runs.
    private func revokeSearchAfterSourceMutation(_ file: URL, keepingVerifiedHit: Bool = false) -> UUID? {
        guard !listQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        searchTask?.cancel()
        searchWorker?.cancel()
        searchTask = nil
        searchWorker = nil
        searchGeneration = UUID()
        activeSearchRunID = nil
        contentSearchNeedsRefresh = false
        lastSearchStartedRevision = nil
        let key = ConversationFilter.fileKey(file)
        if !keepingVerifiedHit, contentHits[key] != nil { contentHits.removeValue(forKey: key) }
        cancelSemanticRanking()
        isSearchingContent = false
        contentSearchPhase = nil
        contentSearchError = nil
        searchDiagnostics = nil
        searchDurationMilliseconds = nil
        searchFirstResultMilliseconds = nil
        return searchGeneration
    }

    private func restartSearchAfterSourceMutation(generation: UUID?) {
        guard let generation, searchGeneration == generation, !Task.isCancelled, !isSearchingContent else { return }
        let query = listQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        // A user query/scope change during catalog reconciliation already owns its new search;
        // this completion must not cancel or restart that newer intent. A catalog revision may
        // also have already started the replacement run while reconciliation was awaited.
        enqueueContentSearch(query: query)
    }

    func importFiles(_ files: [URL]) async {
        guard !isMutating, !files.isEmpty, let mutationService else { return }
        isMutating = true
        importProgress = .init(completed: 0, total: files.count)
        defer {
            importProgress = nil
            isMutating = false
        }

        var summary = ConversationImportSummary()
        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            let result = await Task.detached(priority: .userInitiated) {
                mutationService.importFile(file)
            }.value
            summary.append(result)
            importProgress = .init(completed: index + 1, total: files.count)
        }
        guard !Task.isCancelled else { return }
        let parts = [
            summary.imported > 0 ? "导入 \(summary.imported)" : nil,
            summary.skipped > 0 ? "跳过 \(summary.skipped)" : nil,
            summary.failed > 0 ? "失败 \(summary.failed)" : nil,
        ].compactMap { $0 }
        actionMessage = parts.isEmpty ? "没有可导入的会话" : parts.joined(separator: " · ")
        actionIsError = summary.failed > 0 && summary.imported == 0
        if summary.imported > 0 {
            let importedFiles = summary.results.compactMap { disposition -> URL? in
                guard case .imported(let file) = disposition else { return nil }
                return file
            }
            await synchronizeIndex(files: importedFiles)
            usageHistoryDidChange?()
            if let requestHistoryScope { requestHistoryScope("__imported__") }
        } else {
            await reload()
        }
    }

    func exportSelectedRaw(to destination: URL) async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try mutationService.exportRaw(metadata, to: destination)
            }.value
            actionMessage = result.bundled ? "已导出含子代理的 ZIP" : "已导出原始会话"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "导出失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    /// Kept for the phase-one timeline call site; raw export now selects DB/ZIP/JSONL correctly.
    func exportSelectedRawJSONL(to destination: URL) async {
        await exportSelectedRaw(to: destination)
    }

    func exportSelectedHTML(to destination: URL) async {
        guard !isMutating, let session = selectedSession else { return }
        let exporter = htmlExporter
        isMutating = true
        defer { isMutating = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try exporter.export(session, to: destination)
            }.value
            exportResultOpener.openExportedHTML(destination)
            actionMessage = "已导出独立 HTML"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "HTML 导出失败：\(error.localizedDescription)"
            actionIsError = true
        }
    }

    var selectedExportBaseName: String {
        guard let session = selectedSession else { return "conversation" }
        return htmlExporter.suggestedBaseName(for: session)
    }

    private func refreshTranscriptProjection() {
        cancelSearchNavigation()
        transcriptProjection = preparedTranscripts?.projections[activeTranscriptID] ?? TranscriptProjection()
    }

    func clearActionMessage() {
        actionMessageDismissal?.cancel()
        actionMessageDismissal = nil
        actionMessage = nil
        actionIsError = false
    }

    /// Every message is posted before its `actionIsError` flag is, so the lifetime is read one turn
    /// later; the generation guard keeps a retiring notice from taking a newer one with it.
    private func scheduleActionMessageDismissal() {
        actionMessageDismissal?.cancel()
        actionMessageGeneration &+= 1
        let generation = actionMessageGeneration
        actionMessageDismissal = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.actionMessageGeneration == generation else {
                return
            }
            let seconds = self.noticeLifetime(self.actionIsError)
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, self.actionMessageGeneration == generation else { return }
            self.actionMessage = nil
            self.actionIsError = false
        }
    }

    func reportActionError(_ message: String) {
        actionMessage = message
        actionIsError = true
    }

    func reportActionSuccess(_ message: String) {
        actionMessage = message
        actionIsError = false
    }

    /// Reopens the selected session in a terminal using the producing agent's own resume dialect.
    func resumeSelected(in terminal: ConversationResume.TerminalApp? = nil) {
        guard let metadata = selectedMetadata else { return }
        let outcome = ConversationResume.resume(metadata: metadata, in: terminal)
        actionMessage = outcome.message
        actionIsError = !outcome.succeeded
    }

    private func reconcileMetadataMutation(_ file: URL, selectionGeneration: UUID) async {
        // Annotation edits cannot invalidate a verified body match, but callbacks captured
        // before the write must not restore the old title/star/pin on a query-local row.
        let generation = revokeSearchAfterSourceMutation(file, keepingVerifiedHit: true)
        await synchronizeIndex(files: [file])
        await reloadAndReselect(file, selectionGeneration: selectionGeneration)
        restartSearchAfterSourceMutation(generation: generation)
    }

    private func reloadAndReselect(_ file: URL, selectionGeneration: UUID) async {
        await reload()
        guard detailGeneration == selectionGeneration,
              selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
        let catalog = projects.lazy.flatMap(\.sessions).first(where: {
            ConversationFilter.fileKey($0.file) == ConversationFilter.fileKey(file)
        })
        let source = contentHits[ConversationFilter.fileKey(file)].flatMap {
            ConversationFilter.sourceMetadata(for: $0, active: historyActive)
        }
        guard let refreshed = catalog ?? source else {
            clearSelection()
            return
        }
        await select(refreshed)
    }

    static func isLive(lastActivity: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(lastActivity)
        return age >= 0 && age < liveWindow
    }

    private static func productionHistoryProvider(
        config: AppConfig,
        importsRoot: URL
    ) -> any ConversationHistoryProviding {
        do {
            return try IndexedHistoryRepository(
                historyDirs: config.historyDirs,
                active: config.historyActive,
                importsRoot: importsRoot
            )
        } catch {
            // The catalog is disposable. If it cannot be opened, retain the raw-file repository
            // so conversation browsing and every export path remain available.
            return HistoryRepository(
                historyDirs: config.historyDirs,
                active: config.historyActive,
                importsRoot: importsRoot
            )
        }
    }

    private func startIndexing() {
        guard let indexed = repository as? any ConversationIndexedHistoryProviding else { return }
        indexObservationGeneration = UUID()
        let generation = indexObservationGeneration
        indexed.startIndexing { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receiveIndexEvent(event, generation: generation)
            }
        }
    }

    private func stopIndexing() {
        indexObservationGeneration = UUID()
        indexRetryTask?.cancel()
        revisionReloadTask?.cancel()
        revisionReloadTask = nil
        indexRetryTask = nil
        (repository as? any ConversationIndexedHistoryProviding)?.stopIndexing()
    }

    /// Scope/configuration transitions cancel the previous repository's search worker but retain
    /// the user's query. Restart content search against the newly selected repository so matches
    /// that exist only inside transcript bodies do not silently disappear.
    private func restartContentSearchIfNeeded() {
        let query = listQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateListQuery(query)
    }

    private func receiveIndexEvent(
        _ event: ConversationCatalogScanEvent,
        generation: UUID
    ) {
        guard isActive, indexObservationGeneration == generation else { return }
        if catalogWatcherState != event.watcherState {
            catalogWatcherState = event.watcherState
        }

        switch event.phase {
        case .started:
            setIndexingState(.scanning(completed: event.completed, total: event.total))
            if observedIndexRevision == nil { observedIndexRevision = event.revision }
            if projects.isEmpty, case .failed = listState { listState = .loading }

        case .progress:
            setIndexingState(.scanning(completed: event.completed, total: event.total))
            receiveIndexRevision(event.revision)

        case .finished:
            receiveIndexRevision(event.revision)
            if let error = event.errorDescription {
                publishIndexFailure("会话索引失败：\(error)")
            } else if event.failed > 0 {
                publishIndexIncomplete("\(event.failed) 个会话无法读取，已跳过")
            } else {
                setIndexingState(.idle)
            }
        }
    }

    /// While an agent is writing, every appended turn advances the catalog revision. Reloading per
    /// revision meant re-reading and re-publishing the whole session list — and re-running any
    /// active content search — several times a second, indefinitely; the interface spent its time
    /// re-rendering an essentially unchanged list. The first revision still reloads immediately so
    /// a single change feels instant; a burst coalesces into one trailing reload.
    static let catalogReloadSpacing: TimeInterval = 1.5

    private func setIndexingState(_ value: ConversationIndexingState) {
        guard indexingState != value else { return }
        indexingState = value
    }

    private func receiveIndexRevision(_ revision: Int64) {
        guard isActive, observedIndexRevision != revision else { return }
        observedIndexRevision = revision
        guard revisionReloadTask == nil else { return }
        let elapsed = lastRevisionReloadAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.catalogReloadSpacing {
            performRevisionReload()
            return
        }
        let wait = Self.catalogReloadSpacing - elapsed
        revisionReloadTask = Task { @MainActor [weak self] in
            defer { self?.revisionReloadTask = nil }
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            catch { return }
            guard let self, self.isActive, !Task.isCancelled else { return }
            self.performRevisionReload()
        }
    }

    private func performRevisionReload() {
        lastRevisionReloadAt = Date()
        requestReload()
        refreshContentSearchForCatalogRevision()
    }

    /// A partial scan keeps the catalog usable, so it is reported in place and never interrupts.
    /// If nothing at all could be indexed there is no library to browse, and it becomes a failure.
    private func publishIndexIncomplete(_ message: String) {
        if projects.isEmpty {
            publishIndexFailure(message)
        } else {
            indexingState = .incomplete(message)
        }
    }

    private func publishIndexFailure(_ message: String) {
        indexingState = .failed(message)
        if projects.isEmpty {
            listState = .failed(message)
        } else if actionMessage == nil {
            actionMessage = message
            actionIsError = true
        }
    }

    /// Brings the derived catalog up to date before an explicit mutation reloads the UI. A cache
    /// failure never turns a successful producer-file mutation into a user-visible failure.
    private func synchronizeIndex(files: [URL]? = nil) async {
        guard let indexed = repository as? any ConversationIndexedHistoryProviding else { return }
        do {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                if let files {
                    try indexed.refreshIndex(for: files)
                } else {
                    try indexed.reconcileIndex()
                }
                try Task.checkCancellation()
            }.value
        } catch {
            // FSEvents and the next full reconciliation get another chance; raw reads still work.
        }
    }

    private static func signature(for config: AppConfig, importsRoot: URL) -> String {
        IndexedHistoryRepository.topologySignature(
            historyDirs: config.enabledHistoryDirs,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            importsRoot: importsRoot
        )
    }

    private func beginListLoad() -> UUID {
        listWorker?.cancel()
        listGeneration = UUID()
        // A background refresh over a populated list is not a loading transition the user should
        // see (or pay two renders for); only an empty surface earns the spinner state.
        if projects.isEmpty { listState = .loading }
        return listGeneration
    }

    private func performListLoad(generation: UUID) async {
        let provider = repository
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let projects = try provider.listProjects(limit: ConversationCatalogLimits.sessionList)
            try Task.checkCancellation()
            let explicitScopes = provider.conversationScopeSnapshot()
            try Task.checkCancellation()
            let visible = projects.flatMap(\.sessions)
            let inferredScopes = ConversationScopeSnapshot(
                sessionCounts: Dictionary(grouping: visible, by: \.dirID).mapValues { $0.count },
                trashCount: visible.filter(\.deleted).count,
                isAuthoritative: false
            )
            return ConversationListSnapshot(
                projects: projects,
                scopes: explicitScopes ?? inferredScopes
            )
        }
        listWorker = worker
        defer {
            if listGeneration == generation {
                listWorker = nil
                listTask = nil
            }
        }

        do {
            let snapshot = try await worker.value
            guard !Task.isCancelled, listGeneration == generation else { return }
            let value = snapshot.projects
            // Each publish re-renders every observer of this store. Under a live agent most
            // refreshes carry an identical list, so equality is checked before publishing.
            if projects != value {
                projects = value
                // Search can finish before an initial list load. Rank the newly visible result
                // snapshot without rescanning, while the query-generation guard rejects old work.
                if semanticRankingEnabled && !isSearchingContent { scheduleSemanticRanking() }
            }
            if scopeSnapshot != snapshot.scopes { scopeSnapshot = snapshot.scopes }
            if listState != .loaded { listState = .loaded }
            if let selectedFile {
                if let catalogMetadata = value.lazy.flatMap(\.sessions).first(where: {
                    ConversationFilter.fileKey($0.file)
                        == ConversationFilter.fileKey(selectedFile)
                }) {
                    let refreshed = ConversationFilter.mergingSourceNavigation(into: catalogMetadata,
                        hit: listQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil : contentHits[ConversationFilter.fileKey(selectedFile)],
                        active: historyActive)
                    if selectedMetadata != refreshed {
                        selectedMetadata = refreshed
                        // Child references can change without the parent JSONL changing. A
                        // preparation already in flight must merge this newer catalog snapshot.
                        preparedTranscriptsRevision += 1
                    }
                } else if !listQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let hit = contentHits[ConversationFilter.fileKey(selectedFile)],
                          ConversationFilter.sourceMetadata(for: hit, active: historyActive) != nil {
                    // An exact source result can be opened before its catalog row exists. A
                    // concurrent metadata-only reload must not dismiss that valid selection.
                } else {
                    // A selection can race a scope switch or disappear during reconciliation.
                    // Do not retain actions for a file which is no longer part of this view.
                    clearSelection()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard listGeneration == generation else { return }
            listState = .failed(error.localizedDescription)
        }
    }

    private func performContentSearch(query: String, generation: UUID) async {
        guard searchGeneration == generation else { return }
        lastSearchStartedRevision = observedIndexRevision
        let startedAt = ContinuousClock.now
        let provider = repository
        let runID = UUID()
        activeSearchRunID = runID
        activeSearchProgress = ConversationSearchProgressState()
        activeSearchFirstResultMilliseconds = nil
        contentSearchPhase = .preparingCandidates
        // A background revision refresh preserves the already visible complete result set.
        // User edits clear it before starting this run and can receive progressive prefixes.
        let preservesExistingResults = !contentHits.isEmpty
        let progressSequence = ConversationSearchProgressSequencer()
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            let value: [HistorySearchHit]
            if let progressive = provider as? any ConversationProgressiveHistoryProviding {
                value = try progressive.search(query: query, limit: ConversationCatalogLimits.searchHits) { [weak self] progress in
                    // The repository never waits for the UI actor or calls back under a DB lock.
                    // Cumulative snapshots make skipped/coalesced intermediate updates harmless.
                    let ordinal = progressSequence.next(diagnostics: progress.diagnostics)
                    Task { @MainActor [weak self] in
                        self?.receiveSearchProgress(progress, query: query, generation: generation,
                            runID: runID, ordinal: ordinal, startedAt: startedAt,
                            preservesExistingResults: preservesExistingResults)
                    }
                }
            } else {
                value = try provider.search(query: query, limit: ConversationCatalogLimits.searchHits)
            }
            try Task.checkCancellation()
            return value
        }
        searchWorker = worker
        defer {
            if searchGeneration == generation, activeSearchRunID == runID {
                activeSearchRunID = nil
                searchWorker = nil
                searchTask = nil
                isSearchingContent = false
                let needsRefresh = contentSearchNeedsRefresh
                contentSearchNeedsRefresh = false
                if needsRefresh, isActive, !Task.isCancelled {
                    refreshContentSearchForCatalogRevision()
                }
            }
        }

        do {
            let hits = try await worker.value
            guard !Task.isCancelled, searchGeneration == generation, activeSearchRunID == runID,
                  listQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            guard hits.allSatisfy({ $0.isCountComplete && $0.count > 0 }) else {
                contentSearchError = "搜索次数统计尚未完成，请重试。"
                return
            }
            var mapped: [String: HistorySearchHit] = [:]
            for hit in hits { mapped[ConversationFilter.fileKey(hit.file)] = hit }
            contentHits = mapped
            searchDiagnostics = progressSequence.latestDiagnostics
                ?? (provider as? any ConversationIndexedHistoryProviding)?.searchDiagnostics ?? searchDiagnostics
            let duration = startedAt.duration(to: .now).components
            searchDurationMilliseconds = Double(duration.seconds) * 1_000
                + Double(duration.attoseconds) / 1_000_000_000_000_000
            // These two timings must describe the same completed run. A trailing catalog
            // refresh keeps the old visible snapshot until its full replacement arrives;
            // its first newly published result is therefore its completion, not the original
            // query's potentially much slower cold-index first result.
            searchFirstResultMilliseconds = hits.isEmpty ? nil
                : activeSearchFirstResultMilliseconds ?? searchDurationMilliseconds
            contentSearchPhase = .completed
            // Publish exact matches before the first model load, which can take substantially
            // longer than a warm lexical query. A new keystroke cancels this generation.
            isSearchingContent = false
            if semanticRankingEnabled { scheduleSemanticRanking() }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, searchGeneration == generation, activeSearchRunID == runID,
                  listQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            switch error {
            case ConversationCatalogError.staleRevision, HistorySessionLoadError.dependenciesChanged:
                // These failures disprove the published source snapshot, unlike an unrelated
                // interrupted read. Clear synchronously: a repository withdrawal callback may
                // still be queued when this worker finishes and its run ID is retired below.
                contentHits = [:]
                activeSearchProgress = .init()
                activeSearchFirstResultMilliseconds = nil
                contentSearchPhase = nil
                searchFirstResultMilliseconds = nil
                searchDurationMilliseconds = nil
                cancelSemanticRanking()
            default:
                break
            }
            contentSearchError = error.localizedDescription
        }
    }

    private func receiveSearchProgress(
        _ progress: ConversationSearchProgress, query: String, generation: UUID, runID: UUID, ordinal: UInt64,
        startedAt: ContinuousClock.Instant, preservesExistingResults: Bool
    ) {
        guard searchGeneration == generation, activeSearchRunID == runID, isSearchingContent,
              listQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query,
              progress.phase != .completed else { return }
        let previousAttempt = activeSearchProgress.snapshotAttempt
        guard activeSearchProgress.receive(progress, ordinal: ordinal) else { return }
        let restartedSourceSnapshot = previousAttempt != nil
            && activeSearchProgress.snapshotAttempt != previousAttempt
        contentSearchPhase = activeSearchProgress.phase
        guard activeSearchProgress.canPublish(preservingExistingResults: preservesExistingResults) else { return }
        if let diagnostics = progress.diagnostics { searchDiagnostics = diagnostics }
        // Same-sized prefixes can now finish occurrence counts. A restarted catalog snapshot
        // replaces the visible prefix at its first hit; it never unions old-revision answers.
        guard !activeSearchProgress.hits.isEmpty else {
            if restartedSourceSnapshot { contentHits = [:] }
            return
        }
        let mapped = Dictionary(activeSearchProgress.hits.map { (ConversationFilter.fileKey($0.file), $0) },
                                uniquingKeysWith: { _, newer in newer })
        if mapped != contentHits { contentHits = mapped }
        if activeSearchFirstResultMilliseconds == nil {
            let duration = startedAt.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1_000
                + Double(duration.attoseconds) / 1_000_000_000_000_000
            activeSearchFirstResultMilliseconds = milliseconds
            searchFirstResultMilliseconds = milliseconds
        }
    }

    private func loadDetail(
        file: URL,
        generation: UUID,
        initialSelection: Bool
    ) async {
        let provider = repository
        let inspector = fileInspector
        let startedAt = Date()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let beforeRead = try? inspector.modificationDate(for: file)
            try Task.checkCancellation()
            let value = try provider.getSession(file: file)
            try Task.checkCancellation()
            let afterRead = try? inspector.modificationDate(for: file)
            try Task.checkCancellation()
            return DetailSnapshot(
                session: value,
                modificationDateBeforeRead: beforeRead,
                modificationDateAfterRead: afterRead
            )
        }
        detailWorker = worker

        do {
            let snapshot = try await worker.value
            guard !Task.isCancelled,
                  detailGeneration == generation,
                  selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
            lastDetailLoadDuration = Date().timeIntervalSince(startedAt)
            lastDetailLoadFinishedAt = Date()
            let value = snapshot.session

            // Prepare derived rows, child tabs and navigation on a worker. A separate child read
            // may finish while this is running: merge again in that case instead of replacing
            // its newly loaded messages with an older empty child snapshot.
            var attached: HistorySession
            var prepared: PreparedTranscripts
            while true {
                let revision = preparedTranscriptsRevision
                attached = Self.attachingSubagentRefs(
                    of: selectedMetadata, to: value, preserving: selectedSession
                )
                prepared = try await prepareTranscripts(attached)
                guard !Task.isCancelled, detailGeneration == generation,
                      selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
                if revision == preparedTranscriptsRevision { break }
            }
            let previousMatch = currentDetailMatchMessageIndex
            preparedTranscripts = prepared
            preparedTranscriptsRevision += 1
            selectedSession = attached
            if !prepared.tabs.contains(where: {
                $0.id == activeTranscriptID
            }) {
                deferredTranscriptJump = nil
                activeTranscriptID = .main
            }
            refreshTranscriptProjection()
            loadDeferredTranscriptIfNeeded(activeTranscriptID)
            selectedMetadata = attached.metadata
            detailState = .loaded
            detailRevision += 1

            // Only the version seen before parsing is known to be included. A final append
            // during the read must remain visible to the next poll even if the writer stops.
            // Both inspections finish before publishing .loaded, so initial search navigation
            // cannot arrive after an already-visible Latest action.
            observedModificationDate = snapshot.modificationDateBeforeRead ?? .distantPast
            let activity = snapshot.modificationDateAfterRead ?? value.metadata.lastActivity
            isSelectedSessionLive = Self.isLive(lastActivity: activity, now: now())
            rebuildDetailSearch(preservingMessageIndex: previousMatch, jumpToFirst: false)

            // Read current intent after the asynchronous load: a jump made while parsing must
            // not be overwritten by the following state captured before that read began.
            if isFollowingLatest && isSelectedSessionLive {
                followLatestRevision += 1
            } else if initialSelection && jumpRequest == nil {
                jumpToFirstVisibleMessage()
            }
            replaceMetadata(attached.metadata)
        } catch is CancellationError {
            return
        } catch {
            guard detailGeneration == generation,
                  selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
            detailState = .failed(error.localizedDescription)
            cancelDetailSearch()
            if initialSelection { selectedSession = nil }
        }
        if detailGeneration == generation { detailWorker = nil }
    }

    private func rebuildDetailSearch(preservingMessageIndex: Int?, jumpToFirst: Bool) {
        // A live snapshot can replace the projection while a new query is still debouncing.
        // Restart the worker without losing that query's first-hit navigation intent.
        cancelDetailSearch(preservingNavigationIntent: !jumpToFirst)
        let query = detailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard detailState == .loaded, activeTranscript != nil, !query.isEmpty else {
            detailMatches = []
            detailMatchIndex = -1
            detailSearchNavigationIntent = nil
            return
        }
        if jumpToFirst {
            detailSearchNavigationIntent = .init(query: query, transcriptID: activeTranscriptID,
                                                originalJump: jumpRequest)
        }
        if let intent = detailSearchNavigationIntent,
           intent.query != query || intent.transcriptID != activeTranscriptID
            || intent.originalJump != jumpRequest || isFollowingLatest {
            detailSearchNavigationIntent = nil
        }
        let generation = detailSearchGeneration
        let transcriptID = activeTranscriptID
        let projection = transcriptProjection
        let navigationIntent = detailSearchNavigationIntent
        let delay = searchDelayNanoseconds
        isSearchingDetail = true
        detailSearchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try projection.searchIndex.matches(query: query)
                }
                guard let self else { worker.cancel(); return }
                self.detailSearchWorker = worker
                let matches = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, self.detailSearchGeneration == generation,
                      self.detailState == .loaded,
                      self.activeTranscriptID == transcriptID,
                      self.transcriptProjection === projection else { return }
                self.detailMatches = matches
                if let preservingMessageIndex,
                   let index = matches.firstIndex(where: { $0.messageIndex == preservingMessageIndex }) {
                    self.detailMatchIndex = index
                } else {
                    self.detailMatchIndex = matches.isEmpty ? -1 : 0
                }
                self.isSearchingDetail = false
                self.detailSearchTask = nil
                self.detailSearchWorker = nil
                let retainsNavigationIntent = self.detailSearchNavigationIntent != nil
                self.detailSearchNavigationIntent = nil
                if let navigationIntent, retainsNavigationIntent, !matches.isEmpty, !self.isFollowingLatest,
                   self.jumpRequest == navigationIntent.originalJump {
                    self.selectDetailMatch(at: self.detailMatchIndex)
                }
            } catch {
                guard let self, self.detailSearchGeneration == generation else { return }
                self.isSearchingDetail = false
                self.detailSearchTask = nil
                self.detailSearchWorker = nil
                self.detailSearchNavigationIntent = nil
            }
        }
    }

    private var currentDetailMatchMessageIndex: Int? {
        detailMatches.indices.contains(detailMatchIndex) ? detailMatches[detailMatchIndex].messageIndex : nil
    }

    private func prepareTranscripts(_ session: HistorySession) async throws -> PreparedTranscripts {
        let workerID = UUID()
        projectionWorkerID = workerID
        let worker = Task.detached(priority: .userInitiated) { try PreparedTranscripts.make(session) }
        projectionWorker = worker
        defer {
            if projectionWorkerID == workerID { projectionWorker = nil }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private func cancelProjectionPreparation() {
        projectionWorkerID = UUID()
        projectionWorker?.cancel()
        projectionWorker = nil
    }

    private func cancelDetailSearch(preservingNavigationIntent: Bool = false) {
        detailSearchGeneration = UUID()
        detailSearchTask?.cancel()
        detailSearchWorker?.cancel()
        detailSearchTask = nil
        detailSearchWorker = nil
        isSearchingDetail = false
        if !preservingNavigationIntent { detailSearchNavigationIntent = nil }
    }

    private func jumpToFirstVisibleMessage() {
        guard activeTranscript != nil else { return }
        jump(to: transcriptProjection.visibleMessageIndices.first ?? 0)
    }

    private func selectDetailMatch(at index: Int) {
        guard detailMatches.indices.contains(index) else { return }
        detailMatchIndex = index
        jump(to: detailMatches[index].messageIndex)
    }

    private func replaceMetadata(_ metadata: HistorySessionMetadata) {
        let key = ConversationFilter.fileKey(metadata.file)
        if var hit = contentHits[key], hit.sourceMetadata != nil,
           hit.sessionID == metadata.sessionID, hit.source == metadata.source {
            hit.sourceMetadata = metadata
            contentHits[key] = hit
        }
        for projectIndex in projects.indices {
            guard let sessionIndex = projects[projectIndex].sessions.firstIndex(where: {
                ConversationFilter.fileKey($0.file) == key
            }) else { continue }
            projects[projectIndex].sessions[sessionIndex] = metadata
            projects[projectIndex].lastActivity = projects[projectIndex].sessions
                .map(\.lastActivity).max() ?? projects[projectIndex].lastActivity
            break
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isActive {
                do {
                    try await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled, self.isActive else { break }
                await self.refreshSelectedFileIfChanged(respectingLoadBudget: true)
            }
        }
    }

    private func cancelTransientWork() {
        cancelSearchNavigation()
        jumpLayoutRequest = nil
        deferredTranscriptJump = nil
        deferredTranscriptWorker?.cancel()
        cancelProjectionPreparation()
        cancelDetailSearch()
        contentSearchNeedsRefresh = false
        lastSearchStartedRevision = nil
        cancelSemanticRanking()
        searchDiagnostics = nil
        searchDurationMilliseconds = nil
        searchFirstResultMilliseconds = nil
        contentSearchPhase = nil
        activeSearchRunID = nil
        listGeneration = UUID()
        searchGeneration = UUID()
        detailGeneration = UUID()
        listTask?.cancel()
        listWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
        detailWorker?.cancel()
        indexRetryTask?.cancel()
        revisionReloadTask?.cancel()
        revisionReloadTask = nil
        listTask = nil
        listWorker = nil
        searchTask = nil
        searchWorker = nil
        detailWorker = nil
        projectionWorker = nil
        indexRetryTask = nil
        contentHits = [:]
        isSearchingContent = false
        contentSearchError = nil
    }
}
