import AppKit
import Combine
import Foundation

protocol ConversationHistoryProviding: Sendable {
    func listProjects(limit: Int) throws -> [HistoryProject]
    func search(query: String, limit: Int) throws -> [HistorySearchHit]
    func getSession(file: URL) throws -> HistorySession
    func conversationScopeSnapshot() -> ConversationScopeSnapshot?
}

extension ConversationHistoryProviding {
    /// Lightweight fakes and embedders can omit scope statistics. The store then derives the
    /// currently visible counts, while the production repository supplies an authoritative view.
    func conversationScopeSnapshot() -> ConversationScopeSnapshot? { nil }
}

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

struct ConversationScopeSnapshot: Equatable, Sendable {
    var sessionCounts: [String: Int] = [:]
    var trashCount = 0
    var isAuthoritative = false

    var importedCount: Int { sessionCounts["__imported__", default: 0] }
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
        contentHits: [String: HistorySearchHit]
    ) -> [HistoryProject] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }

        return projects.compactMap { project in
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
        Set(messages.flatMap(\.content).compactMap { block in
            block.type == "tool_use" ? block.id : nil
        })
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

    static func stripInjected(_ text: String) -> String {
        var value = text
        for pattern in [
            #"(?s)<system-reminder>.*?</system-reminder>"#,
            #"(?s)<command-[a-z-]+>.*?</command-[a-z-]+>"#,
            #"(?s)<local-command-[a-z]+>.*?</local-command-[a-z]+>"#,
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: ""
            )
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func occurrenceCount(of query: String, in text: String) -> Int {
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<text.endIndex,
                  locale: .current
              ) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    static let liveWindow: TimeInterval = 90

    @Published private(set) var projects: [HistoryProject] = []
    @Published private(set) var listState: ConversationLoadState = .idle
    @Published private(set) var listQuery = ""
    @Published private(set) var contentHits: [String: HistorySearchHit] = [:]
    @Published private(set) var isSearchingContent = false
    @Published private(set) var contentSearchError: String?

    @Published private(set) var selectedMetadata: HistorySessionMetadata?
    @Published private(set) var selectedSession: HistorySession?
    @Published private(set) var activeTranscriptID: ConversationTranscriptID = .main
    @Published private(set) var detailState: ConversationLoadState = .idle
    @Published private(set) var isSelectedSessionLive = false
    @Published private(set) var detailRevision = 0
    @Published private(set) var followLatestRevision = 0

    @Published private(set) var detailQuery = ""
    @Published private(set) var detailMatches: [ConversationDetailSearchMatch] = []
    @Published private(set) var detailMatchIndex = -1
    @Published private(set) var jumpRequest: ConversationJumpRequest?

    @Published private(set) var actionMessage: String?
    @Published private(set) var actionIsError = false
    @Published private(set) var isMutating = false
    @Published private(set) var importProgress: ConversationImportProgress?
    @Published private(set) var historyActive = "all"
    @Published private(set) var scopeSnapshot = ConversationScopeSnapshot()
    private(set) var configuredHistoryDirectories: [String] = []

    private var repository: any ConversationHistoryProviding
    private var mutationService: (any ConversationMutating)?
    private var htmlExporter: any ConversationHTMLExporting
    private let exportResultOpener: any ConversationExportResultOpening
    private let fileInspector: any ConversationFileInspecting
    private let pathCopier: (String) -> Void
    private let replayURLLauncher: (URL) -> Bool
    private let pollIntervalNanoseconds: UInt64
    private let searchDelayNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var configurationSignature: String?
    private var isActive = false
    private var observedModificationDate: Date?

    private var listGeneration = UUID()
    private var searchGeneration = UUID()
    private var detailGeneration = UUID()
    private var listTask: Task<Void, Never>?
    private var listWorker: Task<ConversationListSnapshot, Error>?
    private var searchTask: Task<Void, Never>?
    private var searchWorker: Task<[HistorySearchHit], Error>?
    private var detailWorker: Task<HistorySession, Error>?
    private var pollingTask: Task<Void, Never>?

    /// AppModel owns persisted history scope. Imports request `__imported__` through this hook,
    /// while ordinary mutations can stay entirely inside the store.
    var requestHistoryScope: ((String) -> Void)?

    /// Explicit disk mutations invalidate the shared usage cache immediately. External CLI writes
    /// are covered by UsageHistoryWatcher's recursive FSEvents stream.
    var usageHistoryDidChange: (@MainActor @Sendable () -> Void)?

    var filteredProjects: [HistoryProject] {
        ConversationFilter.projects(projects, matching: listQuery, contentHits: contentHits)
    }

    var filteredSessionCount: Int {
        filteredProjects.reduce(0) { $0 + $1.sessions.count }
    }

    var selectedFile: URL? { selectedMetadata?.file }

    var transcriptTabs: [ConversationTranscriptTab] {
        selectedSession.map { ConversationTranscriptPresentation.tabs(in: $0) } ?? []
    }

    var activeTranscript: HistorySession? {
        guard let selectedSession else { return nil }
        return ConversationTranscriptPresentation.transcript(
            activeTranscriptID,
            in: selectedSession
        ) ?? selectedSession
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
        searchDelayNanoseconds: UInt64 = 220_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.mutationService = mutationService
        self.htmlExporter = htmlExporter
        self.exportResultOpener = exportResultOpener
        self.historyActive = historyActive
        self.fileInspector = fileInspector
        self.pathCopier = pathCopier
        self.replayURLLauncher = replayURLLauncher
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.searchDelayNanoseconds = searchDelayNanoseconds
        self.now = now
    }

    convenience init(
        config: AppConfig,
        importsRoot: URL? = nil,
        fileInspector: any ConversationFileInspecting = ConversationFileInspector(),
        pollIntervalNanoseconds: UInt64 = 4_000_000_000,
        searchDelayNanoseconds: UInt64 = 220_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let mutationConfiguration = ConversationMutationConfiguration(
            historyDirs: config.historyDirs,
            importsRoot: importsRoot
        )
        self.init(
            repository: HistoryRepository(
                historyDirs: config.historyDirs,
                active: config.historyActive,
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
        listTask?.cancel()
        listWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
        detailWorker?.cancel()
        pollingTask?.cancel()
    }

    func configure(config: AppConfig, importsRoot: URL? = nil) {
        configuredHistoryDirectories = config.historyDirs
        let mutationConfiguration = ConversationMutationConfiguration(
            historyDirs: config.historyDirs,
            importsRoot: importsRoot
        )
        let signature = Self.signature(
            for: config,
            importsRoot: mutationConfiguration.importsRoot
        )
        guard signature != configurationSignature else { return }
        configurationSignature = signature
        cancelTransientWork()
        repository = HistoryRepository(
            historyDirs: config.historyDirs,
            active: config.historyActive,
            importsRoot: mutationConfiguration.importsRoot
        )
        mutationService = ConversationMutationService(configuration: mutationConfiguration)
        historyActive = config.historyActive
        projects = []
        scopeSnapshot = ConversationScopeSnapshot()
        listState = .idle
        clearSelection()
        if isActive { requestReload() }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        if listState == .idle { requestReload() }
        startPolling()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        pollingTask?.cancel()
        pollingTask = nil
        listTask?.cancel()
        listWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
        detailWorker?.cancel()
        isSearchingContent = false
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

    func reload() async {
        listTask?.cancel()
        let generation = beginListLoad()
        await performListLoad(generation: generation)
    }

    func updateListQuery(_ query: String) {
        listQuery = query
        searchTask?.cancel()
        searchWorker?.cancel()
        searchGeneration = UUID()
        contentHits = [:]
        contentSearchError = nil
        isSearchingContent = false

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchingContent = true
        let generation = searchGeneration
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.searchDelayNanoseconds)
            } catch {
                return
            }
            await self.performContentSearch(query: trimmed, generation: generation)
        }
    }

    func select(_ metadata: HistorySessionMetadata) async {
        let file = metadata.file.standardizedFileURL
        detailWorker?.cancel()
        detailGeneration = UUID()
        let generation = detailGeneration
        selectedMetadata = metadata
        selectedSession = nil
        activeTranscriptID = .main
        observedModificationDate = nil
        isSelectedSessionLive = Self.isLive(lastActivity: metadata.lastActivity, now: now())
        detailState = .loading
        detailQuery = ""
        detailMatches = []
        detailMatchIndex = -1
        jumpRequest = nil
        await loadDetail(
            file: file,
            generation: generation,
            initialSelection: true,
            followLatest: isSelectedSessionLive
        )
    }

    func retrySelectedSession() async {
        guard let metadata = selectedMetadata else { return }
        await select(metadata)
    }

    func clearSelection() {
        detailGeneration = UUID()
        detailWorker?.cancel()
        detailWorker = nil
        selectedMetadata = nil
        selectedSession = nil
        activeTranscriptID = .main
        observedModificationDate = nil
        isSelectedSessionLive = false
        detailState = .idle
        detailQuery = ""
        detailMatches = []
        detailMatchIndex = -1
        jumpRequest = nil
    }

    func refreshSelectedFileIfChanged() async {
        guard let file = selectedFile?.standardizedFileURL else { return }
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
            guard selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
            let message = "无法检查会话文件：\(error.localizedDescription)"
            detailState = .failed(message)
            actionMessage = message
            actionIsError = true
            return
        }

        guard selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
        guard let current else {
            detailState = .failed("会话文件已不存在")
            selectedSession = nil
            isSelectedSessionLive = false
            return
        }

        isSelectedSessionLive = Self.isLive(lastActivity: current, now: now())
        guard let previous = observedModificationDate else {
            observedModificationDate = current
            return
        }
        guard current != previous else { return }
        observedModificationDate = current

        detailWorker?.cancel()
        detailGeneration = UUID()
        let generation = detailGeneration
        await loadDetail(
            file: file,
            generation: generation,
            initialSelection: false,
            followLatest: isSelectedSessionLive
        )
    }

    func updateDetailQuery(_ query: String) {
        detailQuery = query
        rebuildDetailSearch(preservingMessageIndex: nil, jumpToFirst: true)
    }

    func selectTranscript(_ id: ConversationTranscriptID) {
        guard id != activeTranscriptID,
              transcriptTabs.contains(where: { $0.id == id }) else { return }
        activeTranscriptID = id
        detailQuery = ""
        detailMatches = []
        detailMatchIndex = -1
        jumpRequest = nil
        detailRevision += 1
        jumpToFirstVisibleMessage()
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
        jumpRequest = ConversationJumpRequest(id: UUID(), messageIndex: messageIndex)
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

    func updateSelectedMetadata(title: String, tags: [String]) async {
        guard !isMutating, let metadata = selectedMetadata, let mutationService else { return }
        isMutating = true
        defer { isMutating = false }
        let file = metadata.file
        do {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try mutationService.updateMetadata(
                    for: metadata,
                    patch: .init(title: title, tags: tags)
                )
                try Task.checkCancellation()
            }.value
            await reloadAndReselect(file)
            actionMessage = "标题与标签已更新"
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
            usageHistoryDidChange?()
            clearSelection()
            await reload()
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
            usageHistoryDidChange?()
            clearSelection()
            await reload()
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
            usageHistoryDidChange?()
            clearSelection()
            await reload()
            actionMessage = "会话已永久删除"
            actionIsError = false
        } catch is CancellationError {
            return
        } catch {
            actionMessage = "永久删除失败：\(error.localizedDescription)"
            actionIsError = true
        }
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

    func clearActionMessage() {
        actionMessage = nil
        actionIsError = false
    }

    func reportActionError(_ message: String) {
        actionMessage = message
        actionIsError = true
    }

    private func reloadAndReselect(_ file: URL) async {
        await reload()
        guard let refreshed = projects.lazy.flatMap(\.sessions).first(where: {
            ConversationFilter.fileKey($0.file) == ConversationFilter.fileKey(file)
        }) else {
            clearSelection()
            return
        }
        await select(refreshed)
    }

    static func isLive(lastActivity: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(lastActivity)
        return age >= 0 && age < liveWindow
    }

    private static func signature(for config: AppConfig, importsRoot: URL) -> String {
        ([config.historyActive, importsRoot.standardizedFileURL.path] + config.historyDirs)
            .joined(separator: "\u{0}")
    }

    private func beginListLoad() -> UUID {
        listWorker?.cancel()
        listGeneration = UUID()
        listState = .loading
        return listGeneration
    }

    private func performListLoad(generation: UUID) async {
        let provider = repository
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let projects = try provider.listProjects(limit: 600)
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
            projects = value
            scopeSnapshot = snapshot.scopes
            listState = .loaded
            if let selectedFile,
               let refreshed = value.lazy.flatMap(\.sessions).first(where: {
                   ConversationFilter.fileKey($0.file) == ConversationFilter.fileKey(selectedFile)
               }) {
                selectedMetadata = refreshed
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
        let provider = repository
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try provider.search(query: query, limit: 120)
            try Task.checkCancellation()
            return value
        }
        searchWorker = worker
        defer {
            if searchGeneration == generation {
                searchWorker = nil
                searchTask = nil
                isSearchingContent = false
            }
        }

        do {
            let hits = try await worker.value
            guard !Task.isCancelled, searchGeneration == generation, listQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            var mapped: [String: HistorySearchHit] = [:]
            for hit in hits { mapped[ConversationFilter.fileKey(hit.file)] = hit }
            contentHits = mapped
        } catch is CancellationError {
            return
        } catch {
            guard searchGeneration == generation else { return }
            contentSearchError = error.localizedDescription
        }
    }

    private func loadDetail(
        file: URL,
        generation: UUID,
        initialSelection: Bool,
        followLatest: Bool
    ) async {
        let provider = repository
        let inspector = fileInspector
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try provider.getSession(file: file)
            try Task.checkCancellation()
            return value
        }
        detailWorker = worker

        do {
            let value = try await worker.value
            guard !Task.isCancelled,
                  detailGeneration == generation,
                  selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }

            let previousMatch = detailMatchIndex >= 0 && detailMatchIndex < detailMatches.count
                ? detailMatches[detailMatchIndex].messageIndex
                : nil
            selectedSession = value
            if !ConversationTranscriptPresentation.tabs(in: value).contains(where: {
                $0.id == activeTranscriptID
            }) {
                activeTranscriptID = .main
            }
            selectedMetadata = value.metadata
            detailState = .loaded
            detailRevision += 1

            let mtimeWorker = Task.detached(priority: .utility) {
                try? inspector.modificationDate(for: file)
            }
            observedModificationDate = await mtimeWorker.value ?? value.metadata.lastActivity
            let activity = observedModificationDate ?? value.metadata.lastActivity
            isSelectedSessionLive = Self.isLive(lastActivity: activity, now: now())
            rebuildDetailSearch(preservingMessageIndex: previousMatch, jumpToFirst: false)

            if followLatest && isSelectedSessionLive {
                followLatestRevision += 1
            } else if initialSelection {
                jumpToFirstVisibleMessage()
            }
            replaceMetadata(value.metadata)
        } catch is CancellationError {
            return
        } catch {
            guard detailGeneration == generation,
                  selectedFile.map(ConversationFilter.fileKey) == ConversationFilter.fileKey(file) else { return }
            detailState = .failed(error.localizedDescription)
            if initialSelection { selectedSession = nil }
        }
        if detailGeneration == generation { detailWorker = nil }
    }

    private func rebuildDetailSearch(preservingMessageIndex: Int?, jumpToFirst: Bool) {
        guard let activeTranscript else {
            detailMatches = []
            detailMatchIndex = -1
            return
        }
        detailMatches = ConversationVisibleText.detailMatches(
            in: activeTranscript.messages,
            query: detailQuery
        )
        guard !detailMatches.isEmpty else {
            detailMatchIndex = -1
            return
        }
        if let preservingMessageIndex,
           let index = detailMatches.firstIndex(where: { $0.messageIndex == preservingMessageIndex }) {
            detailMatchIndex = index
        } else {
            detailMatchIndex = 0
        }
        if jumpToFirst { selectDetailMatch(at: detailMatchIndex) }
    }

    private func jumpToFirstVisibleMessage() {
        guard let messages = activeTranscript?.messages else { return }
        let results = ConversationVisibleText.resultMap(in: messages)
        let pairedIDs = ConversationVisibleText.pairedToolResultIDs(in: messages)
        let firstVisible = messages.firstIndex(where: {
            !ConversationVisibleText.searchableText(
                for: $0,
                results: results,
                pairedToolResultIDs: pairedIDs
            ).isEmpty
        }) ?? 0
        jump(to: firstVisible)
    }

    private func selectDetailMatch(at index: Int) {
        guard detailMatches.indices.contains(index) else { return }
        detailMatchIndex = index
        jump(to: detailMatches[index].messageIndex)
    }

    private func replaceMetadata(_ metadata: HistorySessionMetadata) {
        let key = ConversationFilter.fileKey(metadata.file)
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
                await self.refreshSelectedFileIfChanged()
            }
        }
    }

    private func cancelTransientWork() {
        listGeneration = UUID()
        searchGeneration = UUID()
        detailGeneration = UUID()
        listTask?.cancel()
        listWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
        detailWorker?.cancel()
        listTask = nil
        listWorker = nil
        searchTask = nil
        searchWorker = nil
        detailWorker = nil
        contentHits = [:]
        isSearchingContent = false
        contentSearchError = nil
    }
}
