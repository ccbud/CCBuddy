import Foundation

/// Only the exact, document-local answer is retained: never transcript text, spans or String.Index.
/// Current metadata, scope visibility, ordering and parent/subagent ownership are rebound per search.
enum ConversationSearchRefinement: Equatable, Sendable {
    case noMatch
    case hit(transcriptID: String, agentType: String?, sequence: Int?, snippet: String, count: Int)

    var retainedBytes: Int {
        switch self {
        case .noMatch: return 0
        case let .hit(transcriptID, agentType, _, snippet, _):
            return transcriptID.utf8.count + (agentType?.utf8.count ?? 0) + snippet.utf8.count
        }
    }

    func hit(for metadata: HistorySessionMetadata, agentOverride: String?) -> HistorySearchHit? {
        guard case let .hit(transcriptID, agentType, sequence, snippet, count) = self else { return nil }
        return HistorySearchHit(sessionID: metadata.sessionID, file: metadata.file, source: metadata.source,
            agent: agentOverride ?? transcriptID, agentType: agentType, sequence: sequence,
            snippet: snippet, count: count)
    }
}

/// One small cache per database, shared by scoped repository facades. The generation is intentionally
/// catalog-wide: metadata-only and live revisions invalidate it too. This accelerates repeated queries
/// in an unchanged catalog, not first-time queries or repeated revision refreshes.
final class ConversationSearchRefinementCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var documentID: Int64
        var sessionPath: String
        var transcriptID: String
        // Byte identity avoids silently treating canonically equivalent query spellings as one key.
        var queryUTF8: Data
        var options: UInt
        var localeIdentifier: String?
        var algorithmVersion: Int = 1

        init(reference: ConversationIndexDocumentReference, query: String,
             options: String.CompareOptions = .caseInsensitive, localeIdentifier: String? = nil) {
            documentID = reference.documentID
            sessionPath = reference.sessionPath
            transcriptID = reference.transcriptID
            queryUTF8 = Data(query.utf8)
            self.options = options.rawValue
            self.localeIdentifier = localeIdentifier
        }

        var retainedBytes: Int {
            sessionPath.utf8.count + transcriptID.utf8.count + queryUTF8.count
                + (localeIdentifier?.utf8.count ?? 0)
        }
    }

    struct Entry: Sendable {
        var generation: Int64
        var result: ConversationSearchRefinement
        fileprivate var cost: Int
        fileprivate var access: UInt64
    }

    struct Statistics: Sendable {
        var entries: Int
        var retainedBytes: Int
        var validatedHits: Int
        var stores: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var retainedBytes = 0
    private var clock: UInt64 = 0
    private var validatedHits = 0
    private var stores = 0
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let maximumEntryBytes: Int

    init(maximumBytes: Int = 2 * 1_024 * 1_024, maximumEntries: Int = 2_048,
         maximumEntryBytes: Int = 64 * 1_024) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.maximumEntryBytes = max(0, maximumEntryBytes)
    }

    func lookup(_ key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard var value = entries[key] else { return nil }
        clock &+= 1
        value.access = clock
        entries[key] = value
        return value
    }

    func recordValidatedHit() {
        lock.lock()
        validatedHits += 1
        lock.unlock()
    }

    /// Cancellation is not a negative match. Check after preparation and again before publishing
    /// into the cache, including callers whose matcher represents cancellation by returning nil.
    func store(_ result: ConversationSearchRefinement, for key: Key, generation: Int64) throws {
        try Task.checkCancellation()
        // Include conservative fixed entry/dictionary overhead as well as every retained byte.
        let cost = 256 + key.retainedBytes + result.retainedBytes
        guard maximumEntries > 0, cost <= maximumBytes, cost <= maximumEntryBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        if let old = entries.removeValue(forKey: key) { retainedBytes -= old.cost }
        while entries.count >= maximumEntries || retainedBytes > maximumBytes - cost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            retainedBytes -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        clock &+= 1
        entries[key] = Entry(generation: generation, result: result, cost: cost, access: clock)
        retainedBytes += cost
        stores += 1
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(entries: entries.count, retainedBytes: retainedBytes,
                          validatedHits: validatedHits, stores: stores)
    }
}

/// Catalog-wide caps.
///
/// The session stream used to stop at 600 entries, which silently hid everything older on machines
/// with a deep archive: the sidebar badge reported 600 while the index knew about far more, and the
/// hidden tail was unreachable by scrolling *or* search. The index already materializes every entry
/// before truncating, so a generous cap costs nothing and only guards pathological libraries.
enum ConversationCatalogLimits {
    static let sessionList = 5_000
    static let searchScan = 5_000
    static let searchHits = 200
}

/// Optional production capabilities layered on top of the read-only history provider.
///
/// Tests and embedders may continue supplying a plain `ConversationHistoryProviding`. The live
/// store uses these hooks to keep the rebuildable catalog current after FSEvents and explicit
/// mutations without making the producer files anything other than authoritative.
protocol ConversationIndexedHistoryProviding: ConversationHistoryProviding {
    var indexTopologySignature: String { get }
    var searchDiagnostics: ConversationSearchDiagnostics? { get }

    func scoped(to active: String) -> any ConversationIndexedHistoryProviding
    func startIndexing(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void)
    func stopIndexing()
    func reconcileIndex() throws
    func refreshIndex(for files: [URL]) throws
}

extension ConversationIndexedHistoryProviding {
    var searchDiagnostics: ConversationSearchDiagnostics? { nil }

    func startIndexing(onRevision: @escaping @Sendable (Int64) -> Void) {
        startIndexing { event in
            guard event.phase != .started else { return }
            onRevision(event.revision)
        }
    }
}

/// Metadata and content-search facade backed by the app-owned SQLite catalog.
///
/// Detail reads deliberately bypass SQLite and use `HistorySessionLoader`, so replay, analysis,
/// raw/ZIP export, and standalone HTML export always see the current producer-owned transcript.
struct IndexedHistoryRepository: ConversationIndexedHistoryProviding, ConversationProgressiveHistoryProviding, Sendable {
    let configuration: HistoryConfiguration
    let database: ConversationIndexDatabase
    let loader: HistorySessionLoader
    let coordinator: ConversationCatalogCoordinator

    var searchDiagnostics: ConversationSearchDiagnostics? { database.searchDiagnostics }

    var indexTopologySignature: String {
        Self.topologySignature(
            historyDirs: configuration.historyDirs,
            homeDirectory: configuration.homeDirectory,
            importsRoot: configuration.importsRoot
        )
    }

    init(
        configuration: HistoryConfiguration,
        database: ConversationIndexDatabase,
        loader: HistorySessionLoader? = nil,
        coordinator: ConversationCatalogCoordinator? = nil
    ) {
        self.configuration = configuration
        self.database = database
        let resolvedLoader = loader ?? HistorySessionLoader(configuration: configuration)
        self.loader = resolvedLoader
        self.coordinator = coordinator ?? ConversationCatalogCoordinator(
            configuration: configuration,
            database: database,
            loader: resolvedLoader
        )
    }

    init(
        historyDirs: [String],
        active: String = "all",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        importsRoot: URL? = nil,
        databaseFile: URL? = nil
    ) throws {
        let configuration = HistoryConfiguration(
            historyDirs: historyDirs,
            active: active,
            homeDirectory: homeDirectory,
            importsRoot: importsRoot
        )
        let file = databaseFile ?? configuration.appDataRoot
            .appendingPathComponent("conversation-index-v1.sqlite3")
        self.init(
            configuration: configuration,
            database: try ConversationIndexDatabase(file: file)
        )
    }

    func listSessions(limit: Int = 400) throws -> [HistorySessionMetadata] {
        guard limit > 0 else { return [] }
        let filter = activeFilter
        let indexed = try database.listEntries(
            scope: filter.scope,
            deleted: filter.deleted,
            limit: .max
        ).map(\.metadata).filter { allowedScopeIDs.contains($0.dirID) }
        let canonical = HistoryCatalogProjection.canonicalizedCodexSessions(
            indexed,
            homeDirectory: configuration.homeDirectory
        )
        let nested = HistoryCatalogProjection.nestingSubagentRollouts(canonical)
        let ordered = HistoryCatalogProjection.activityOrdered(nested)
        return HistoryCatalogProjection.limitedKeepingCodexAncestors(ordered, limit: limit)
    }

    func listProjects(limit: Int = 600) throws -> [HistoryProject] {
        HistoryCatalogProjection.projects(from: try listSessions(limit: limit))
    }

    func search(query rawQuery: String, limit: Int = 120) throws -> [HistorySearchHit] {
        try performSearch(query: rawQuery, limit: limit, onProgress: nil)
    }

    func search(
        query rawQuery: String,
        limit: Int = 120,
        onProgress: @Sendable (ConversationSearchProgress) -> Void
    ) throws -> [HistorySearchHit] {
        // The optional internal sink lets the existing final-only API avoid
        // retaining cumulative arrays. This callback never actually escapes.
        try withoutActuallyEscaping(onProgress) { callback in
            try performSearch(query: rawQuery, limit: limit, onProgress: callback)
        }
    }

    private func performSearch(
        query rawQuery: String,
        limit: Int,
        onProgress: (@Sendable (ConversationSearchProgress) -> Void)?
    ) throws -> [HistorySearchHit] {
        var diagnostics: ConversationSearchDiagnostics?
        func publish(_ phase: ConversationSearchProgress.Phase, hits: [HistorySearchHit]) throws {
            try Task.checkCancellation()
            guard let onProgress else { return }
            onProgress(ConversationSearchProgress(phase: phase, hits: hits, diagnostics: diagnostics))
            try Task.checkCancellation()
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else {
            try publish(.completed, hits: [])
            return []
        }
        try publish(.preparingCandidates, hits: [])
        let matcher = ConversationLiteralSearch(query: query)

        // Scan activity-ordered canonical sessions and return the first matching transcript per
        // session. The scan window matches the stream's window so search can never claim fewer
        // results than the list is already showing.
        //
        // Candidates are located by identity and their transcripts are read one at a time. Asking
        // the catalog for the matching documents themselves made a single keystroke materialize
        // every transcript that matched — the whole indexed corpus for a common word — first
        // inside SQLite and then again as Swift strings.
        let sessions = try listSessions(limit: ConversationCatalogLimits.searchScan)
        let filter = activeFilter
        let batch = try database.candidateDocumentReferences(
            for: query,
            scope: filter.scope,
            deleted: filter.deleted
        )
        var referencesByPath: [String: [ConversationIndexDocumentReference]] = [:]
        for reference in batch.references {
            referencesByPath[reference.sessionPath, default: []].append(reference)
        }
        if onProgress != nil { diagnostics = searchDiagnostics }
        try publish(.refiningResults, hits: [])

        var hits: [HistorySearchHit] = []
        var lastPublishedCount = 0
        var lastPublication = ContinuousClock.now
        for metadata in sessions {
            try Task.checkCancellation()
            let path = ConversationIndexDatabase.normalizedPath(metadata.file)
            // The visible Codex row owns separately indexed child rollouts.
            // Search them after its main/embedded transcripts and attribute a
            // child hit to the parent row, using the same key as its lazy tab.
            // These refs come from the already scope/trash-filtered projection;
            // never resolve a parent relationship across directory boundaries.
            var transcripts: [(reference: ConversationIndexDocumentReference, agent: String?)] =
                (referencesByPath[path] ?? [])
                    .sorted(by: ConversationIndexDatabase.referenceComesFirst)
                    .map { ($0, nil) }
            if metadata.source == .codex {
                for child in metadata.subagentRefs {
                    let childPath = ConversationIndexDatabase.normalizedPath(child.file)
                    for reference in referencesByPath[childPath] ?? [] where reference.transcriptID == "main" {
                        transcripts.append((reference, child.threadID))
                    }
                }
            }
            for transcript in transcripts {
                let reference = transcript.reference
                try Task.checkCancellation()
                let cache = database.searchRefinementCache
                let key = ConversationSearchRefinementCache.Key(reference: reference, query: query)
                let cached = cache.lookup(key)
                guard let read = try database.refinementDocument(
                    reference: reference, cachedGeneration: cached?.generation
                ) else { continue }
                let refinement: ConversationSearchRefinement
                switch read {
                case .unchanged:
                    // Only the generation/identity check can authorize reuse. The local value
                    // remains valid even if another search concurrently evicts its cache entry.
                    guard let cached else { continue }
                    refinement = cached.result
                    cache.recordValidatedHit()
                case let .document(generation, document):
                    refinement = Self.refine(document, matcher: matcher)
                    try Task.checkCancellation()
                    try cache.store(refinement, for: key, generation: generation)
                }
                try Task.checkCancellation()
                guard let hit = refinement.hit(for: metadata, agentOverride: transcript.agent) else { continue }
                hits.append(hit)
                // Publish only after exact verification has produced the full
                // count and source anchor, and after database.document released
                // its read lock. A slow older transcript cannot hide this hit.
                if onProgress != nil,
                   hits.count == 1 || hits.count - lastPublishedCount >= 8
                    || lastPublication.duration(to: .now) >= .milliseconds(50) {
                    try publish(.refiningResults, hits: hits)
                    lastPublishedCount = hits.count
                    lastPublication = .now
                }
                break
            }
            if hits.count == limit { break }
        }
        try publish(.completed, hits: hits)
        return hits
    }

    private static func refine(
        _ document: ConversationIndexDocument,
        matcher: ConversationLiteralSearch
    ) -> ConversationSearchRefinement {
        // FTS and the short-query fallback are candidate generators; only this literal match
        // decides whether the transcript is really a result.
        guard let match = matcher.match(in: document.text) else {
            return .noMatch
        }
        let range = match.range
        let offset = range.lowerBound.utf16Offset(in: document.text)
        let span = Self.span(at: offset, in: document.messageSpans)
        return .hit(
            transcriptID: document.transcriptID,
            agentType: document.agentType,
            sequence: span?.sequence,
            snippet: Self.snippet(in: document.text, around: range, context: 56),
            count: match.count
        )
    }

    func getSession(file: URL) throws -> HistorySession {
        try loader.getSession(file: file)
    }

    func conversationScopeSnapshot() -> ConversationScopeSnapshot? {
        do {
            let live = HistoryCatalogProjection.nestingSubagentRollouts(
                HistoryCatalogProjection.canonicalizedCodexSessions(
                    try database.listEntries(deleted: false, limit: .max)
                        .map(\.metadata)
                        .filter { allowedScopeIDs.contains($0.dirID) },
                    homeDirectory: configuration.homeDirectory
                )
            )
            let trash = HistoryCatalogProjection.nestingSubagentRollouts(
                HistoryCatalogProjection.canonicalizedCodexSessions(
                    try database.listEntries(deleted: true, limit: .max)
                        .map(\.metadata)
                        .filter { allowedScopeIDs.contains($0.dirID) },
                    homeDirectory: configuration.homeDirectory
                )
            )
            return ConversationScopeSnapshot(
                sessionCounts: Dictionary(grouping: live, by: \.dirID).mapValues(\.count),
                trashCount: trash.count,
                isAuthoritative: true
            )
        } catch {
            return nil
        }
    }

    func scoped(to active: String) -> any ConversationIndexedHistoryProviding {
        var scopedConfiguration = configuration
        scopedConfiguration.active = active
        return IndexedHistoryRepository(
            configuration: scopedConfiguration,
            database: database,
            loader: loader,
            coordinator: coordinator
        )
    }

    func startIndexing(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void) {
        coordinator.start(onEvent: onEvent)
    }

    func stopIndexing() {
        coordinator.stop()
    }

    func reconcileIndex() throws {
        try coordinator.reconcileNow()
    }

    func refreshIndex(for files: [URL]) throws {
        try coordinator.refreshNow(files: files)
    }

    static func topologySignature(
        historyDirs: [String],
        homeDirectory: URL,
        importsRoot: URL
    ) -> String {
        ([
            homeDirectory.standardizedFileURL.path,
            importsRoot.standardizedFileURL.path,
        ] + historyDirs).joined(separator: "\u{0}")
    }

    private var activeFilter: (scope: String?, deleted: Bool) {
        switch configuration.active {
        case "all": (nil, false)
        case "__trash__": (nil, true)
        default: (configuration.active, false)
        }
    }

    private var allowedScopeIDs: Set<String> {
        Set(configuration.historyDirs + ["__imported__"])
    }

    private static func span(
        at utf16Offset: Int,
        in spans: [ConversationIndexMessageSpan]
    ) -> ConversationIndexMessageSpan? {
        if let containing = spans.first(where: {
            utf16Offset >= $0.utf16Location
                && utf16Offset < $0.utf16Location + max(1, $0.utf16Length)
        }) {
            return containing
        }
        return spans.first(where: { $0.utf16Location >= utf16Offset }) ?? spans.last
    }

    private static func snippet(
        in text: String,
        around match: Range<String.Index>,
        context: Int
    ) -> String {
        let start = text.index(
            match.lowerBound,
            offsetBy: -context,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            match.upperBound,
            offsetBy: context,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let body = text[start..<end]
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return (start > text.startIndex ? "…" : "")
            + body
            + (end < text.endIndex ? "…" : "")
    }
}
