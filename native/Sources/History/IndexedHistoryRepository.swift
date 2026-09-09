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

    func hit(for metadata: HistorySessionMetadata, agentOverride: String?,
             isCountComplete: Bool = true) -> HistorySearchHit? {
        guard case let .hit(transcriptID, agentType, sequence, snippet, count) = self else { return nil }
        return HistorySearchHit(sessionID: metadata.sessionID, file: metadata.file, source: metadata.source,
            agent: agentOverride ?? transcriptID, agentType: agentType, sequence: sequence,
            snippet: snippet, count: count, isCountComplete: isCountComplete)
    }
}

/// One small cache per file catalog, shared by scoped repository facades. The generation is intentionally
/// catalog-wide: metadata-only and live revisions invalidate it too. This accelerates repeated queries
/// in an unchanged catalog, not first-time queries or repeated revision refreshes.
final class ConversationSearchRefinementCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var catalogIdentity: String?
        var documentID: Int64
        var sessionPath: String
        var transcriptID: String
        // Byte identity avoids silently treating canonically equivalent query spellings as one key.
        var queryUTF8: Data
        var options: UInt
        var localeIdentifier: String?
        /// Present only for raw-source answers. Full dependency identity includes replacement-
        /// sensitive file stamps and subagent sidecars, not just mtime/size or a catalog revision.
        var sourceFingerprint: String? = nil
        var algorithmVersion: Int = 1

        init(reference: ConversationIndexDocumentReference, query: String,
             options: String.CompareOptions = .caseInsensitive, localeIdentifier: String? = nil) {
            catalogIdentity = reference.catalogIdentity
            documentID = reference.documentID
            sessionPath = reference.sessionPath
            transcriptID = reference.transcriptID
            queryUTF8 = Data(query.utf8)
            self.options = options.rawValue
            self.localeIdentifier = localeIdentifier
        }

        init(source: ConversationSourceSearchCoverage.Source, catalogIdentity: String?, query: String) {
            self.catalogIdentity = catalogIdentity
            // Allocated catalog document IDs are strictly positive. Reserve zero for an answer
            // spanning an authoritative source's first matching main/embedded transcript.
            documentID = 0
            sessionPath = ConversationFileCatalog.normalizedPath(source.candidate.file)
            transcriptID = "source"
            queryUTF8 = Data(query.utf8)
            options = String.CompareOptions.caseInsensitive.rawValue
            localeIdentifier = nil
            sourceFingerprint = source.dependencySnapshot.fingerprint
        }

        var retainedBytes: Int {
            (catalogIdentity?.utf8.count ?? 0) + sessionPath.utf8.count + transcriptID.utf8.count + queryUTF8.count
                + (localeIdentifier?.utf8.count ?? 0) + (sourceFingerprint?.utf8.count ?? 0)
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

/// Metadata and content-search facade backed by immutable, file-based catalog packs.
///
/// Detail reads deliberately bypass the derived catalog and use `HistorySessionLoader`, so replay, analysis,
/// raw/ZIP export, and standalone HTML export always see the current producer-owned transcript.
struct IndexedHistoryRepository: ConversationIndexedHistoryProviding, ConversationProgressiveHistoryProviding, Sendable {
    let configuration: HistoryConfiguration
    let database: ConversationFileCatalog
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
        database: ConversationFileCatalog,
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
            .appendingPathComponent("conversation-catalog-v1", isDirectory: true)
        self.init(
            configuration: configuration,
            database: try ConversationFileCatalog(file: file)
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
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !query.isEmpty, limit > 0 else {
            onProgress?(.init(phase: .completed, hits: []))
            try Task.checkCancellation()
            return []
        }
        let matcher = ConversationLiteralSearch(query: query)
        // Each attempt is one catalog generation. Live writes can invalidate an in-flight
        // count, but never authorize merging old anchors with a new transcript's contents.
        for attempt in 0..<3 {
            do {
                return try searchSnapshot(query: query, matcher: matcher, limit: limit,
                    onProgress: onProgress)
            } catch ConversationCatalogError.staleRevision where attempt < 2 {
                try Task.checkCancellation()
            } catch HistorySessionLoadError.dependenciesChanged where attempt < 2 {
                try Task.checkCancellation()
            }
        }
        throw ConversationCatalogError.staleRevision
    }

    private func searchSnapshot(
        query: String, matcher: ConversationLiteralSearch, limit: Int,
        onProgress: (@Sendable (ConversationSearchProgress) -> Void)?
    ) throws -> [HistorySearchHit] {
        var diagnostics: ConversationSearchDiagnostics?
        // Source rewrites can invalidate an attempt without a catalog mutation. This token is
        // stable for its entire prefix and changes only when performSearch actually retries.
        let snapshotAttempt = UUID()
        let revision = try database.searchIndexRevision()
        let catalogIdentity = revision.identity
        let generation = revision.generation
        func validateSource(_ source: ConversationSourceSearchCoverage.Source) throws {
            try Task.checkCancellation()
            guard source.manifest.snapshot() == source.dependencySnapshot,
                  try database.generation() == generation,
                  try database.catalogIdentity() == catalogIdentity else {
                throw ConversationCatalogError.staleRevision
            }
        }
        func publish(_ phase: ConversationSearchProgress.Phase, hits: [HistorySearchHit]) throws {
            try Task.checkCancellation()
            guard let onProgress else { return }
            onProgress(ConversationSearchProgress(phase: phase, hits: hits,
                diagnostics: diagnostics, snapshotRevision: generation, snapshotIdentity: catalogIdentity,
                snapshotAttempt: snapshotAttempt))
            try Task.checkCancellation()
        }
        try publish(.preparingCandidates, hits: [])

        // Scan activity-ordered canonical sessions and return the first matching transcript per
        // session. The scan window matches the stream's window so search can never claim fewer
        // results than the list is already showing.
        //
        // Candidates are located by identity and their transcripts are read one at a time. Asking
        // the catalog for the matching documents themselves made a single keystroke materialize
        // every transcript that matched — the whole indexed corpus for a common word — first
        // as Swift strings. Cold candidate lookup never waits for a tgrep rebuild.
        let filter = activeFilter
        let coverage = try ConversationSourceSearchCoverage.snapshot(loader: loader,
            entries: database.listEntries(deleted: nil, limit: .max),
            scope: filter.scope, deleted: filter.deleted)
        let canonical = HistoryCatalogProjection.canonicalizedCodexSessions(coverage.metadata,
            homeDirectory: configuration.homeDirectory)
        let nested = HistoryCatalogProjection.nestingSubagentRollouts(canonical)
        let sessions = HistoryCatalogProjection.limitedKeepingCodexAncestors(
            HistoryCatalogProjection.activityOrdered(nested), limit: ConversationCatalogLimits.searchScan)
            .sorted(by: HistoryCatalogProjection.searchResultComesFirst)
        let batch = try database.candidateDocumentReferences(
            for: query,
            scope: filter.scope,
            deleted: filter.deleted
        )
        // Preparation is independent of this foreground worker. Its cancellation/lifecycle is
        // owned by the catalog, and a missing checkpoint never delays this query's exact scan.
        database.scheduleSearchIndexPreparation()
        guard try database.generation() == generation,
              try database.catalogIdentity() == catalogIdentity else {
            throw ConversationCatalogError.staleRevision
        }
        var referencesByPath: [String: [ConversationIndexDocumentReference]] = [:]
        for reference in batch.references {
            referencesByPath[reference.sessionPath, default: []].append(reference)
        }
        if onProgress != nil {
            diagnostics = searchDiagnostics
            if !coverage.sourcesByPath.isEmpty {
                diagnostics?.usedFallback = true
                diagnostics?.fallbackReason = "sourceVerification"
            }
        }
        try publish(.refiningResults, hits: [])

        var hits: [HistorySearchHit] = []
        var pending: [(index: Int, transcript: SearchTranscript)] = []
        var lastPublishedCount = 0
        var lastPublication = ContinuousClock.now
        for metadata in sessions {
            try Task.checkCancellation()
            let path = ConversationFileCatalog.normalizedPath(metadata.file)
            // The visible Codex row owns separately indexed child rollouts.
            // Search them after its main/embedded transcripts and attribute a
            // child hit to the parent row, using the same key as its lazy tab.
            // These refs come from the already scope/trash-filtered projection;
            // never resolve a parent relationship across directory boundaries.
            var transcripts: [SearchTranscript] = []
            func appendTranscripts(path: String, agent: String? = nil, mainOnly: Bool = false) {
                if let source = coverage.sourcesByPath[path] {
                    // The source replaces this session's old packs; adding it to their counts
                    // would double-count the prefix and retain removed/replaced source text.
                    transcripts.append(.source(source, agent: agent))
                } else {
                    transcripts.append(contentsOf: (referencesByPath[path] ?? [])
                        .filter { !mainOnly || $0.transcriptID == "main" }
                        .sorted(by: ConversationFileCatalog.referenceComesFirst)
                        .map { .catalog($0, agent: agent) })
                }
            }
            appendTranscripts(path: path)
            if metadata.source == .codex {
                for child in metadata.subagentRefs {
                    let childPath = ConversationFileCatalog.normalizedPath(child.file)
                    appendTranscripts(path: childPath, agent: child.threadID, mainOnly: true)
                }
            }
            for transcript in transcripts {
                if case let .source(source, agent) = transcript {
                    let validate = { try validateSource(source) }
                    let cache = database.searchRefinementCache
                    let key = ConversationSearchRefinementCache.Key(source: source,
                        catalogIdentity: catalogIdentity, query: query)
                    try validate()
                    let refinement: ConversationSearchRefinement
                    let isComplete: Bool
                    if let cached = cache.lookup(key), cached.generation == generation {
                        try validate()
                        refinement = cached.result
                        cache.recordValidatedHit()
                        isComplete = true
                    } else {
                        refinement = try ConversationSourceSearch.refine(candidate: source.candidate,
                            metadata: source.metadata, loader: loader, query: query,
                            countingOccurrences: onProgress == nil, validate: validate)
                        try validate()
                        isComplete = onProgress == nil || refinement == .noMatch
                        if isComplete { try cache.store(refinement, for: key, generation: generation) }
                    }
                    try validate()
                    guard var hit = refinement.hit(for: metadata, agentOverride: agent,
                                                   isCountComplete: isComplete) else { continue }
                    hit.sourceMetadata = metadata
                    if !isComplete { pending.append((hits.count, transcript)) }
                    hits.append(hit)
                    try publish(.refiningResults, hits: hits)
                    lastPublishedCount = hits.count
                    lastPublication = .now
                    break
                }
                guard case let .catalog(reference, agent) = transcript else { continue }
                try Task.checkCancellation()
                let cache = database.searchRefinementCache
                let key = ConversationSearchRefinementCache.Key(reference: reference, query: query)
                let cached = cache.lookup(key)
                guard let currentGeneration = try database.refinementGeneration(reference: reference),
                      currentGeneration == generation else {
                    throw ConversationCatalogError.staleRevision
                }
                let refinement: ConversationSearchRefinement
                let isComplete: Bool
                if let cached, cached.generation == generation {
                    // Only the generation/identity check can authorize reuse. The local value
                    // remains valid even if another search concurrently evicts its cache entry.
                    refinement = cached.result
                    cache.recordValidatedHit()
                    isComplete = true
                } else {
                    // The first pass only verifies one occurrence. Counting is a separate,
                    // cancellable pass over candidate blocks, after usable results are visible.
                    refinement = try refine(reference: reference, query: query, matcher: matcher,
                        countingOccurrences: onProgress == nil)
                    try Task.checkCancellation()
                    isComplete = onProgress == nil || refinement == .noMatch
                    if isComplete { try cache.store(refinement, for: key, generation: generation) }
                }
                try Task.checkCancellation()
                guard let hit = refinement.hit(for: metadata, agentOverride: agent,
                    isCountComplete: isComplete) else { continue }
                if !isComplete { pending.append((hits.count, transcript)) }
                hits.append(hit)
                // Callbacks are outside the database lock. First-hit publication is immediate;
                // subsequent identities are batched without delaying the first usable result.
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
        if !pending.isEmpty {
            try publish(.countingOccurrences, hits: hits)
            lastPublication = .now
            for (ordinal, item) in pending.enumerated() {
                let refinement: ConversationSearchRefinement
                let key: ConversationSearchRefinementCache.Key
                switch item.transcript {
                case let .catalog(reference, _):
                    refinement = try refine(reference: reference, query: query,
                        matcher: matcher, countingOccurrences: true)
                    key = .init(reference: reference, query: query)
                case let .source(source, _):
                    refinement = try ConversationSourceSearch.refine(candidate: source.candidate,
                        metadata: source.metadata, loader: loader, query: query,
                        validate: { try validateSource(source) })
                    key = .init(source: source, catalogIdentity: catalogIdentity, query: query)
                }
                guard case let .hit(_, _, sequence, snippet, count) = refinement,
                      sequence == hits[item.index].sequence, snippet == hits[item.index].snippet else {
                    throw ConversationCatalogError.staleRevision
                }
                try database.searchRefinementCache.store(refinement,
                    for: key, generation: generation)
                hits[item.index].count = count
                hits[item.index].isCountComplete = true
                if ordinal == 0 || ordinal == pending.count - 1
                    || lastPublication.duration(to: .now) >= .milliseconds(50) {
                    try publish(.countingOccurrences, hits: hits)
                    lastPublication = .now
                }
            }
        }
        guard try database.generation() == generation,
              try database.catalogIdentity() == catalogIdentity else {
            throw ConversationCatalogError.staleRevision
        }
        for source in coverage.validationSources {
            try Task.checkCancellation()
            guard source.manifest.snapshot() == source.dependencySnapshot else {
                throw ConversationCatalogError.staleRevision
            }
        }
        try publish(.completed, hits: hits)
        return hits
    }

    private enum SearchTranscript {
        case catalog(ConversationIndexDocumentReference, agent: String?)
        case source(ConversationSourceSearchCoverage.Source, agent: String?)
    }

    private func refine(reference: ConversationIndexDocumentReference, query: String,
                        matcher: ConversationLiteralSearch, countingOccurrences: Bool) throws
        -> ConversationSearchRefinement {
        var cursor: ConversationIndexSearchCursor?
        var resumeUTF16 = 0
        var count = 0
        var first: (sequence: Int?, snippet: String)?
        repeat {
            try Task.checkCancellation()
            let batch = try database.searchChunkWindows(reference: reference, query: query,
                cursor: cursor, limit: countingOccurrences || cursor != nil ? 8 : 1)
            for window in batch.windows {
                // Foundation matching/snippet bridging may autorelease temporary strings.
                // This worker has no run-loop drain between thousands of archive blocks.
                let foundFirst = try autoreleasepool { () throws -> Bool in
                    try Task.checkCancellation()
                    guard let match = matcher.match(in: window.text,
                        countingOccurrences: countingOccurrences,
                        startingAtUTF16: max(0, resumeUTF16 - window.globalUTF16Start),
                        ownedUTF16Length: window.ownedUTF16Length) else {
                        try Task.checkCancellation()
                        return false
                    }
                    if first == nil {
                        let offset = window.globalUTF16Start
                            + match.range.lowerBound.utf16Offset(in: window.text)
                        let matchLength = match.range.upperBound.utf16Offset(in: window.text)
                            - match.range.lowerBound.utf16Offset(in: window.text)
                        guard let snippet = try database.searchChunkSnippet(reference: reference,
                            offsetUTF16: offset, matchLengthUTF16: matchLength, context: 56) else {
                            throw ConversationCatalogError.staleRevision
                        }
                        first = (Self.span(at: offset, in: window.messageSpans)?.sequence, snippet)
                    }
                    count += match.count
                    resumeUTF16 = window.globalUTF16Start + match.lastUTF16End
                    return !countingOccurrences
                }
                if foundFirst { break }
            }
            cursor = batch.nextCursor
        } while cursor != nil && (countingOccurrences || first == nil)
        try Task.checkCancellation()
        guard let first else { return .noMatch }
        return .hit(transcriptID: reference.transcriptID, agentType: reference.agentType,
            sequence: first.sequence, snippet: first.snippet, count: count)
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

}
