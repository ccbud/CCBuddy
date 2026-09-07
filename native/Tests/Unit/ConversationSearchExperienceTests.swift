import XCTest
@testable import CCBuddy

@MainActor
final class ConversationSearchExperienceTests: XCTestCase {
    func testContinuousCatalogRevisionsCannotStarveSlowSearchOrBlankItsTrailingRefresh() async throws {
        let repository = GatedIndexedSearchRepository()
        let ranker = ControlledSemanticRanker()
        let store = ConversationStore(repository: repository, semanticRanker: ranker, searchDelayNanoseconds: 0)
        defer { repository.releaseAll(); store.deactivate() }
        store.activate()
        await waitUntil { store.listState == .loaded }
        store.setSemanticRankingEnabled(true)
        store.updateListQuery("cache")
        await waitUntil { repository.searchCount == 1 }

        // Keep the first exact search in flight longer than the production 1.5 s revision
        // reload spacing. Every revision previously cancelled it and cleared its results.
        for revision in 1...8 {
            repository.emitRevision(Int64(revision))
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertEqual(repository.searchCount, 1, "Automatic revisions cannot cancel/restart an in-flight query")
        repository.release(1)
        await waitUntil { repository.searchCount == 2 && store.contentHits.values.first?.count == 1 }
        XCTAssertTrue(store.isSearchingContent, "New revisions should receive one trailing refresh")
        XCTAssertEqual(store.searchDiagnostics?.engine, "Fixture")
        XCTAssertNotNil(store.searchDurationMilliseconds, "The first full result remains visible while refreshing")
        XCTAssertEqual(repository.maximumConcurrentSearches, 1)

        // Semantic ordering of the visible result must also be allowed to finish while its
        // replacement keyword snapshot is being fetched.
        await ranker.complete()
        await waitUntil { store.semanticDiagnostics?.state == .ready }
        repository.release(2)
        await waitUntil { !store.isSearchingContent && store.contentHits.values.first?.count == 2 }
        try await Task.sleep(nanoseconds: UInt64((ConversationStore.catalogReloadSpacing + 0.1) * 1_000_000_000))
        XCTAssertEqual(repository.searchCount, 2, "A queued list reload must not re-search an already covered revision")
    }

    func testNewQueryCancelsPendingCatalogRefreshAndRejectsOldSearchResults() async throws {
        let repository = GatedIndexedSearchRepository()
        let store = ConversationStore(repository: repository, searchDelayNanoseconds: 0)
        defer { repository.releaseAll(); store.deactivate() }
        store.activate()
        await waitUntil { store.listState == .loaded }
        store.updateListQuery("cache")
        await waitUntil { repository.searchCount == 1 }
        repository.emitRevision(1)
        try await Task.sleep(nanoseconds: 30_000_000)

        store.updateListQuery("replacement")
        await waitUntil { repository.searchCount == 2 }
        XCTAssertTrue(store.contentHits.isEmpty, "User input must still clear the previous query immediately")
        XCTAssertNil(store.searchDiagnostics)
        repository.release(1)
        repository.release(2)
        await waitUntil { !store.isSearchingContent && store.contentHits.values.first?.count == 2 }
        XCTAssertEqual(repository.queries, ["cache", "replacement"])
        XCTAssertEqual(store.listQuery, "replacement")
        XCTAssertTrue(store.contentHits.values.allSatisfy { $0.snippet.hasPrefix("replacement") })
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(repository.searchCount, 2, "The old query's pending refresh must not survive new user input")
    }

    func testLexicalHitsAppearBeforeRankingAndDisablingRestoresOriginalOrder() async throws {
        let ranker = ControlledSemanticRanker()
        let store = ConversationStore(repository: SearchExperienceRepository(), semanticRanker: ranker,
                                      searchDelayNanoseconds: 0)
        await store.reload()
        store.setSemanticRankingEnabled(true)
        store.updateListQuery("cache")
        await waitUntil { store.isRankingSearch }
        XCTAssertFalse(store.isSearchingContent)
        XCTAssertEqual(store.contentHits.count, 2)
        XCTAssertEqual(store.orderedSearchSessions.map(\.id), ["a", "b"])
        await ranker.complete()
        await waitUntil { !store.isRankingSearch }
        XCTAssertEqual(store.orderedSearchSessions.map(\.id), ["b", "a"])
        XCTAssertEqual(store.contentHits.count, 2, "Reranking cannot remove an exact hit")
        XCTAssertNotNil(store.searchDurationMilliseconds)
        store.setSemanticRankingEnabled(false)
        XCTAssertEqual(store.contentHits.count, 2, "Changing sort order must not blank exact results")
        XCTAssertFalse(store.isSearchingContent, "Disabling ranking must not start another disk search")
        await waitUntil { !store.isSearchingContent }
        XCTAssertEqual(store.orderedSearchSessions.map(\.id), ["a", "b"])
        XCTAssertNil(store.semanticDiagnostics)
    }

    func testStaleModelCompletionCannotRepopulateClearedSearch() async throws {
        let ranker = ControlledSemanticRanker()
        let store = ConversationStore(repository: SearchExperienceRepository(), semanticRanker: ranker,
                                      searchDelayNanoseconds: 0)
        await store.reload()
        store.setSemanticRankingEnabled(true)
        store.updateListQuery("cache")
        await waitUntil { store.isRankingSearch }
        store.updateListQuery("")
        await ranker.complete()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(store.listQuery, "")
        XCTAssertTrue(store.contentHits.isEmpty)
        XCTAssertTrue(store.semanticRanks.isEmpty)
        XCTAssertNil(store.semanticDiagnostics)
        XCTAssertFalse(store.isRankingSearch)
    }

    func testSearchFinishingBeforeInitialCatalogLoadRanksWhenRowsArrive() async throws {
        let ranker = ControlledSemanticRanker()
        let store = ConversationStore(repository: SearchExperienceRepository(), semanticRanker: ranker,
                                      searchDelayNanoseconds: 0)
        store.setSemanticRankingEnabled(true)
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.count == 2 && !store.isSearchingContent }
        XCTAssertTrue(store.orderedSearchSessions.isEmpty)
        XCTAssertFalse(store.isRankingSearch, "An empty catalog must not start model preparation")

        await store.reload()
        await waitUntil { store.isRankingSearch }
        await ranker.complete()
        await waitUntil { !store.isRankingSearch }
        XCTAssertEqual(store.orderedSearchSessions.map(\.id), ["b", "a"])
        XCTAssertEqual(store.contentHits.count, 2)
        XCTAssertNotNil(store.semanticDiagnostics)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private final class GatedIndexedSearchRepository: ConversationIndexedHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let gates = [1: DispatchSemaphore(value: 0), 2: DispatchSemaphore(value: 0)]
    private var observer: (@Sendable (ConversationCatalogScanEvent) -> Void)?
    private var recordedQueries: [String] = []
    private var activeSearches = 0
    private var peakSearches = 0

    var indexTopologySignature: String { "gated-search-fixture" }
    var searchDiagnostics: ConversationSearchDiagnostics? { .init(engine: "Fixture", candidateCount: 1) }
    var searchCount: Int { lock.withLock { recordedQueries.count } }
    var queries: [String] { lock.withLock { recordedQueries } }
    var maximumConcurrentSearches: Int { lock.withLock { peakSearches } }

    func listProjects(limit: Int) throws -> [HistoryProject] {
        try SearchExperienceRepository().listProjects(limit: limit)
    }

    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        let call = lock.withLock {
            recordedQueries.append(query)
            activeSearches += 1
            peakSearches = max(peakSearches, activeSearches)
            return recordedQueries.count
        }
        defer { lock.withLock { activeSearches -= 1 } }
        if let gate = gates[call], gate.wait(timeout: .now() + 10) == .timedOut {
            throw GateError.timedOut
        }
        try Task.checkCancellation()
        var hit = try SearchExperienceRepository().search(query: query, limit: 1)[0]
        hit.count = call
        hit.snippet = "\(query) result \(call)"
        return [hit]
    }

    func getSession(file: URL) throws -> HistorySession {
        try SearchExperienceRepository().getSession(file: file)
    }
    func scoped(to active: String) -> any ConversationIndexedHistoryProviding { self }
    func startIndexing(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void) {
        lock.withLock { observer = onEvent }
        onEvent(.started(revision: 0))
    }
    func stopIndexing() { lock.withLock { observer = nil } }
    func reconcileIndex() throws {}
    func refreshIndex(for files: [URL]) throws {}
    func emitRevision(_ revision: Int64) {
        let callback = lock.withLock { observer }
        callback?(.progress(.init(discovered: 1, parsed: 1, generation: revision)))
    }
    func release(_ call: Int) { gates[call]?.signal() }
    func releaseAll() { gates.values.forEach { $0.signal() } }
    private enum GateError: Error { case timedOut }
}

private actor ControlledSemanticRanker: SemanticSearchRanking {
    private var continuation: CheckedContinuation<SemanticSearchResult, Never>?
    private var candidates: [SemanticSearchCandidate] = []
    private var completed = false

    func rank(query: String, candidates: [SemanticSearchCandidate]) async throws -> SemanticSearchResult {
        self.candidates = candidates
        if completed { return result() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete() {
        completed = true
        continuation?.resume(returning: result())
        continuation = nil
    }

    private func result() -> SemanticSearchResult {
        SemanticSearchResult(orderedIDs: candidates.reversed().map(\.id), scores: [:],
                             diagnostics: .init(state: .ready, computePolicy: .cpuOnly))
    }
}

private struct SearchExperienceRepository: ConversationHistoryProviding {
    private var sessions: [HistorySessionMetadata] {
        ["a", "b"].map { id in
            HistorySessionMetadata(
                id: id, file: URL(fileURLWithPath: "/tmp/search-\(id).jsonl"), source: .claude,
                dirID: "fixture", dirLabel: "Fixture", sessionID: id, project: "project",
                title: "Session \(id)", autoTitle: "Session \(id)",
                createdAt: .distantPast, lastActivity: .distantPast, sizeBytes: 1)
        }
    }
    func listProjects(limit: Int) throws -> [HistoryProject] {
        [HistoryProject(cwd: "/tmp", name: "project", sessions: sessions, lastActivity: .distantPast)]
    }
    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        sessions.map { HistorySearchHit(sessionID: $0.id, file: $0.file, source: .claude,
                                       snippet: "cache authentication", count: 1) }
    }
    func getSession(file: URL) throws -> HistorySession {
        throw HistoryError.unreadableFile(file, "Detail loading is outside this search test")
    }
}
