import Foundation

/// Optional production capabilities layered on top of the read-only history provider.
///
/// Tests and embedders may continue supplying a plain `ConversationHistoryProviding`. The live
/// store uses these hooks to keep the rebuildable catalog current after FSEvents and explicit
/// mutations without making the producer files anything other than authoritative.
protocol ConversationIndexedHistoryProviding: ConversationHistoryProviding {
    var indexTopologySignature: String { get }
    var locationHistoryConfiguration: HistoryConfiguration { get }

    func scoped(to active: String) -> any ConversationIndexedHistoryProviding
    func startIndexing(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void)
    func stopIndexing()
    func reconcileIndex() throws
    func refreshIndex(for files: [URL]) throws
    func sessionLocationOverrides() throws -> ConversationSessionLocationOverrides
    func sessionLocationRows() throws -> [ConversationSessionLocationRow]
    func addSessionLocation(_ location: ConversationSessionLocation) throws
    func replaceSessionLocation(
        oldSource: HistorySource,
        oldCustomPath: String?,
        with replacement: ConversationSessionLocation
    ) throws
    func removeSessionLocation(source: HistorySource, customPath: String?) throws
    func restoreDefaultSessionLocations() throws
    func replaceSessionLocationOverrides(
        _ overrides: ConversationSessionLocationOverrides
    ) throws
    func reloadedForSessionLocations() throws -> any ConversationIndexedHistoryProviding
}

extension ConversationIndexedHistoryProviding {
    func startIndexing(onRevision: @escaping @Sendable (Int64) -> Void) {
        startIndexing { event in
            guard event.phase != .started else { return }
            onRevision(event.revision)
        }
    }

    var locationHistoryConfiguration: HistoryConfiguration {
        HistoryConfiguration(historyDirs: [])
    }

    func sessionLocationOverrides() throws -> ConversationSessionLocationOverrides { .init() }
    func sessionLocationRows() throws -> [ConversationSessionLocationRow] { [] }

    func addSessionLocation(_ location: ConversationSessionLocation) throws {
        throw ConversationIndexDatabaseError.invalidRecord("session locations are unavailable")
    }

    func replaceSessionLocation(
        oldSource: HistorySource,
        oldCustomPath: String?,
        with replacement: ConversationSessionLocation
    ) throws {
        throw ConversationIndexDatabaseError.invalidRecord("session locations are unavailable")
    }

    func removeSessionLocation(source: HistorySource, customPath: String?) throws {
        throw ConversationIndexDatabaseError.invalidRecord("session locations are unavailable")
    }

    func restoreDefaultSessionLocations() throws {
        throw ConversationIndexDatabaseError.invalidRecord("session locations are unavailable")
    }

    func replaceSessionLocationOverrides(
        _ overrides: ConversationSessionLocationOverrides
    ) throws {
        throw ConversationIndexDatabaseError.invalidRecord("session locations are unavailable")
    }

    func reloadedForSessionLocations() throws -> any ConversationIndexedHistoryProviding {
        self
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

    var locationHistoryConfiguration: HistoryConfiguration { configuration }

    var indexTopologySignature: String {
        Self.topologySignature(
            historyDirs: configuration.historyDirs,
            homeDirectory: configuration.homeDirectory,
            importsRoot: configuration.importsRoot,
            overrides: configuration.sessionLocationOverrides
        )
    }

    init(
        configuration: HistoryConfiguration,
        database: ConversationIndexDatabase,
        loader: HistorySessionLoader? = nil,
        coordinator: ConversationCatalogCoordinator? = nil
    ) {
        self.database = database
        var resolvedConfiguration = configuration
        if let stored = try? database.sessionLocationOverrides() {
            resolvedConfiguration.sessionLocationOverrides = stored
        }
        self.configuration = resolvedConfiguration
        let resolvedLoader = loader ?? HistorySessionLoader(configuration: resolvedConfiguration)
        self.loader = resolvedLoader
        self.coordinator = coordinator ?? ConversationCatalogCoordinator(
            configuration: resolvedConfiguration,
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
        try Task.checkCancellation()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        // Search the complete canonical catalog. The result limit bounds presentation, not which
        // sessions are eligible, so an older project can never disappear merely because a user
        // has more than 600 recent conversations.
        let sessions = try listSessions(limit: .max)
        let filter = activeFilter
        let batch = try database.candidateDocuments(
            for: query,
            scope: filter.scope,
            deleted: filter.deleted,
            limit: nil,
            isCancelled: { Task.isCancelled }
        )
        try Task.checkCancellation()
        var documentsByPath: [String: [ConversationIndexDocument]] = [:]
        for candidate in batch.documents {
            try Task.checkCancellation()
            documentsByPath[candidate.entry.sourcePath, default: []].append(candidate.document)
        }

        var hits: [HistorySearchHit] = []
        for metadata in sessions {
            try Task.checkCancellation()
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
        var session = try loader.getSession(file: file)
        session.metadata = try database.userMetadata(for: file).applying(to: session.metadata)
        return session
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

    func sessionLocationOverrides() throws -> ConversationSessionLocationOverrides {
        try database.sessionLocationOverrides()
    }

    func sessionLocationRows() throws -> [ConversationSessionLocationRow] {
        let overrides = try database.sessionLocationOverrides()
        let defaults = ConversationSessionLocationLayout.defaults(
            homeDirectory: configuration.homeDirectory,
            openCodeDatabase: configuration.openCodeDefaultDatabase
        ).filter { !overrides.removedDefaults.contains($0.source) }
        let custom = overrides.custom.map { location in
            let stored = URL(fileURLWithPath: location.path).standardizedFileURL
            return (layout: ConversationSessionLocationLayout.custom(
                source: location.source,
                selected: stored
            ), stored: stored)
        }
        var flattened: [(layout: ConversationSessionLocationLayout, root: URL, custom: URL?)] = []
        for layout in defaults {
            for root in layout.dataRoots {
                flattened.append((layout, root, nil))
            }
        }
        for value in custom {
            for root in value.layout.dataRoots {
                flattened.append((value.layout, root, value.stored))
            }
        }
        flattened.sort { lhs, rhs in
            let left = Self.sourceOrder(lhs.layout.source)
            let right = Self.sourceOrder(rhs.layout.source)
            if left != right { return left < right }
            // Defaults were appended before custom layouts; retain that stable order per source.
            if (lhs.custom == nil) != (rhs.custom == nil) { return lhs.custom == nil }
            return lhs.root.path < rhs.root.path
        }
        // Count nested roots first so one custom child cannot be swallowed by a broader default.
        let countOrder = flattened.indices.sorted {
            flattened[$0].root.path.count > flattened[$1].root.path.count
        }
        let countInputs = countOrder.map {
            (source: flattened[$0].layout.source, root: flattened[$0].root)
        }
        let orderedCounts = try database.sessionCounts(for: countInputs)
        var counts = Array(repeating: 0, count: flattened.count)
        for (position, originalIndex) in countOrder.enumerated() {
            counts[originalIndex] = orderedCounts[position]
        }
        return flattened.enumerated().map { index, value in
            ConversationSessionLocationRow(
                source: value.layout.source,
                dataRoot: value.root,
                storedCustomRoot: value.custom,
                sessionCount: counts[index],
                exists: FileManager.default.fileExists(atPath: value.root.path)
            )
        }
    }

    func addSessionLocation(_ location: ConversationSessionLocation) throws {
        try database.addCustomSessionLocation(location)
    }

    func replaceSessionLocation(
        oldSource: HistorySource,
        oldCustomPath: String?,
        with replacement: ConversationSessionLocation
    ) throws {
        try database.replaceSessionLocation(
            oldSource: oldSource,
            oldCustomPath: oldCustomPath,
            with: replacement
        )
    }

    func removeSessionLocation(source: HistorySource, customPath: String?) throws {
        if let customPath {
            try database.removeCustomSessionLocation(source: source, path: customPath)
        } else {
            try database.removeDefaultSessionLocation(source: source)
        }
    }

    func restoreDefaultSessionLocations() throws {
        try database.restoreDefaultSessionLocations()
    }

    func replaceSessionLocationOverrides(
        _ overrides: ConversationSessionLocationOverrides
    ) throws {
        try database.replaceSessionLocationOverrides(overrides)
    }

    func reloadedForSessionLocations() throws -> any ConversationIndexedHistoryProviding {
        var refreshed = configuration
        refreshed.sessionLocationOverrides = try database.sessionLocationOverrides()
        return IndexedHistoryRepository(configuration: refreshed, database: database)
    }

    static func topologySignature(
        historyDirs: [String],
        homeDirectory: URL,
        importsRoot: URL,
        overrides: ConversationSessionLocationOverrides = .init()
    ) -> String {
        let custom = overrides.custom.map { $0.source.rawValue + ":" + $0.path }
        let removed = overrides.removedDefaults.map(\.rawValue).sorted()
        return ([
            homeDirectory.standardizedFileURL.path,
            importsRoot.standardizedFileURL.path,
        ] + historyDirs + custom + removed).joined(separator: "\u{0}")
    }

    private static func sourceOrder(_ source: HistorySource) -> Int {
        [
            HistorySource.claude, .codex, .qoder, .grok, .dsh, .cursor, .opencode,
            .pi, .omp, .kiro, .kimi, .gemini, .copilot, .antigravity,
        ].firstIndex(of: source) ?? Int.max
    }

    private var activeFilter: (scope: String?, deleted: Bool) {
        switch configuration.active {
        case "all": (nil, false)
        case "__trash__": (nil, true)
        default: (configuration.active, false)
        }
    }

    private var allowedScopeIDs: Set<String> {
        Set(loader.adapters.discoveryDirectories(configuration: configuration).map(\.id))
            .union(["__imported__"])
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
