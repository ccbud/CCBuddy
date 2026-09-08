import Foundation

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
                guard let document = try database.document(
                    id: reference.documentID,
                    expectedSessionPath: reference.sessionPath,
                    expectedTranscriptID: reference.transcriptID
                ),
                      let hit = Self.hit(for: metadata, in: document, matcher: matcher,
                        agentOverride: transcript.agent) else { continue }
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

    private static func hit(
        for metadata: HistorySessionMetadata,
        in document: ConversationIndexDocument,
        matcher: ConversationLiteralSearch,
        agentOverride: String? = nil
    ) -> HistorySearchHit? {
        // FTS and the short-query fallback are candidate generators; only this literal match
        // decides whether the transcript is really a result.
        guard let match = matcher.match(in: document.text) else {
            return nil
        }
        let range = match.range
        let offset = range.lowerBound.utf16Offset(in: document.text)
        let span = Self.span(at: offset, in: document.messageSpans)
        return HistorySearchHit(
            sessionID: metadata.sessionID,
            file: metadata.file,
            source: metadata.source,
            agent: agentOverride ?? document.transcriptID,
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
