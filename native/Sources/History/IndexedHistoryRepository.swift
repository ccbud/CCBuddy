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

    func scoped(to active: String) -> any ConversationIndexedHistoryProviding
    func startIndexing(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void)
    func stopIndexing()
    func reconcileIndex() throws
    func refreshIndex(for files: [URL]) throws
}

extension ConversationIndexedHistoryProviding {
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
struct IndexedHistoryRepository: ConversationIndexedHistoryProviding, Sendable {
    let configuration: HistoryConfiguration
    let database: ConversationIndexDatabase
    let loader: HistorySessionLoader
    let coordinator: ConversationCatalogCoordinator

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
        let ordered = HistoryCatalogProjection.activityOrdered(canonical)
        return HistoryCatalogProjection.limitedKeepingCodexAncestors(ordered, limit: limit)
    }

    func listProjects(limit: Int = 600) throws -> [HistoryProject] {
        HistoryCatalogProjection.projects(from: try listSessions(limit: limit))
    }

    func search(query rawQuery: String, limit: Int = 120) throws -> [HistorySearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        // Scan activity-ordered canonical sessions and return the first matching transcript per
        // session. The scan window matches the stream's window so search can never claim fewer
        // results than the list is already showing.
        let sessions = try listSessions(limit: ConversationCatalogLimits.searchScan)
        let filter = activeFilter
        let batch = try database.candidateDocuments(
            for: query,
            scope: filter.scope,
            deleted: filter.deleted,
            limit: nil
        )
        var documentsByPath: [String: [ConversationIndexDocument]] = [:]
        for candidate in batch.documents {
            documentsByPath[candidate.entry.sourcePath, default: []].append(candidate.document)
        }

        var hits: [HistorySearchHit] = []
        for metadata in sessions {
            let path = ConversationIndexDatabase.normalizedPath(metadata.file)
            let documents = documentsByPath[path, default: []].sorted(by: Self.documentComesFirst)
            guard let match = documents.lazy.compactMap({ document -> HistorySearchHit? in
                guard let range = document.text.range(of: query, options: [.caseInsensitive]) else {
                    return nil
                }
                let offset = range.lowerBound.utf16Offset(in: document.text)
                let span = Self.span(at: offset, in: document.messageSpans)
                return HistorySearchHit(
                    sessionID: metadata.sessionID,
                    file: metadata.file,
                    source: metadata.source,
                    agent: document.transcriptID,
                    agentType: document.agentType,
                    sequence: span?.sequence,
                    snippet: Self.snippet(in: document.text, around: range, context: 56),
                    count: Self.occurrenceCount(of: query, in: document.text)
                )
            }).first else { continue }
            hits.append(match)
            if hits.count == limit { break }
        }
        return hits
    }

    func getSession(file: URL) throws -> HistorySession {
        try loader.getSession(file: file)
    }

    func conversationScopeSnapshot() -> ConversationScopeSnapshot? {
        do {
            let live = HistoryCatalogProjection.canonicalizedCodexSessions(
                try database.listEntries(deleted: false, limit: .max)
                    .map(\.metadata)
                    .filter { allowedScopeIDs.contains($0.dirID) },
                homeDirectory: configuration.homeDirectory
            )
            let trash = HistoryCatalogProjection.canonicalizedCodexSessions(
                try database.listEntries(deleted: true, limit: .max)
                    .map(\.metadata)
                    .filter { allowedScopeIDs.contains($0.dirID) },
                homeDirectory: configuration.homeDirectory
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

    private static func documentComesFirst(
        _ lhs: ConversationIndexDocument,
        _ rhs: ConversationIndexDocument
    ) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.transcriptID < rhs.transcriptID
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

    private static func occurrenceCount(of query: String, in text: String) -> Int {
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(
                  of: query,
                  options: [.caseInsensitive],
                  range: cursor..<text.endIndex
              ) {
            count += 1
            cursor = range.upperBound
        }
        return count
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
