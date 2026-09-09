import XCTest
@testable import CCBuddy

@MainActor
final class ConversationSearchExperienceTests: XCTestCase {
    func testFirstMatchCountCanCompleteInPlaceWhileSearchAndSelectionStayActive() async throws {
        let provider = ScriptedCountSearchRepository()
        defer { provider.releaseAll() }
        let ranker = ControlledSemanticRanker()
        let store = ConversationStore(repository: provider, semanticRanker: ranker, searchDelayNanoseconds: 0)
        await store.reload()
        store.setSemanticRankingEnabled(true)
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.count == 1 }
        let first = try XCTUnwrap(store.contentHits.values.first)
        XCTAssertFalse(first.isCountComplete)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(store.isSearchingContent)
        XCTAssertFalse(store.isRankingSearch)
        XCTAssertNil(store.searchDurationMilliseconds)
        let selected = try XCTUnwrap(store.orderedSearchSessions.first)
        await store.select(selected, searchHit: first)
        let initialJump = store.jumpRequest

        provider.release(to: 1)
        await waitUntil { store.contentHits.values.first?.isCountComplete == true }
        XCTAssertEqual(store.contentHits.count, 1, "A same-length publication must update the existing result")
        XCTAssertEqual(store.contentHits.values.first?.count, 5)
        XCTAssertEqual(store.contentHits.values.first?.id, first.id)
        XCTAssertEqual(store.selectedFile, selected.file)
        XCTAssertEqual(store.jumpRequest, initialJump, "Counting cannot navigate the open transcript again")
        XCTAssertTrue(store.isSearchingContent, "A finished count is not a finished repository search")
        XCTAssertEqual(store.contentSearchPhase, .countingOccurrences)
        XCTAssertFalse(store.isRankingSearch, "Partial publications must not trigger semantic reordering")
        provider.releaseAll()
        await waitUntil { !store.isSearchingContent && store.isRankingSearch }
        XCTAssertEqual(store.contentSearchPhase, .completed)
        XCTAssertEqual(store.contentHits.values.first?.count, 5)
        await ranker.complete()
    }

    func testIncompleteFinalValueNeverClaimsSearchCompletionOrStartsRanking() async {
        let provider = ScriptedCountSearchRepository(incompleteFinal: true)
        defer { provider.releaseAll() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.setSemanticRankingEnabled(true)
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.count == 1 }
        provider.releaseAll()
        await waitUntil { !store.isSearchingContent }
        XCTAssertFalse(store.contentHits.values.first?.isCountComplete ?? true)
        XCTAssertNotEqual(store.contentSearchPhase, .completed)
        XCTAssertNil(store.searchDurationMilliseconds)
        XCTAssertNotNil(store.contentSearchError)
        XCTAssertFalse(store.isRankingSearch)
    }

    func testSnapshotRestartReplacesOldResultInsteadOfMixingCounts() async throws {
        let provider = ScriptedCountSearchRepository(restartsSnapshot: true)
        defer { provider.releaseAll() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.values.first?.sessionID == "a" }
        provider.release(to: 1)
        await waitUntil { store.contentSearchPhase == .preparingCandidates }
        XCTAssertEqual(store.contentHits.values.first?.sessionID, "a", "Old visuals remain until a new prefix is ready")
        provider.release(to: 2)
        await waitUntil { store.contentHits.values.first?.sessionID == "b" }
        XCTAssertEqual(store.contentHits.count, 1)
        XCTAssertFalse(store.contentHits.values.contains { $0.sessionID == "a" })
        XCTAssertFalse(try XCTUnwrap(store.contentHits.values.first).isCountComplete)
        provider.releaseAll()
        await waitUntil { !store.isSearchingContent }
        XCTAssertEqual(store.contentHits.values.first?.sessionID, "b")
        XCTAssertEqual(store.contentHits.values.first?.count, 5)
        XCTAssertTrue(store.contentHits.values.allSatisfy(\.isCountComplete))
    }

    func testLateOccurrenceCountCannotRepopulateANewQueryOrClearedSearch() async {
        for query in ["replacement", ""] {
            let provider = ScriptedCountSearchRepository()
            defer { provider.releaseAll() }
            let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
            await store.reload()
            store.updateListQuery("cache")
            await waitUntil { store.contentHits.count == 1 }
            store.updateListQuery(query)
            provider.releaseAll()
            await waitUntil { provider.didFinish && !store.isSearchingContent }
            XCTAssertEqual(store.listQuery, query)
            if query.isEmpty {
                XCTAssertTrue(store.contentHits.isEmpty)
                XCTAssertNil(store.contentSearchPhase)
            } else {
                XCTAssertTrue(store.contentHits.values.allSatisfy { $0.snippet == query && $0.isCountComplete })
            }
        }
    }

    func testProgressiveFailureRetainsVerifiedHitsButNeverLooksComplete() async {
        let provider = GatedProgressiveSearchRepository(failsAfterPrefix: true)
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.count == 1 }
        provider.release()
        await waitUntil { !store.isSearchingContent }
        XCTAssertEqual(store.contentHits.count, 1)
        XCTAssertEqual(store.contentHits.values.first?.count, 3)
        XCTAssertNotNil(store.contentSearchError)
        XCTAssertNotEqual(store.contentSearchPhase, .completed)
        XCTAssertNil(store.searchDurationMilliseconds)
        XCTAssertNotNil(store.searchFirstResultMilliseconds)
    }

    func testDeactivatedProgressiveWorkerCannotPublishALateFailure() async throws {
        let provider = GatedProgressiveSearchRepository(failsAfterPrefix: true)
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        store.activate()
        await waitUntil { store.listState == .loaded }
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.count == 1 }
        store.deactivate()
        provider.release()
        await waitUntil { provider.finishedOldCall }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(store.contentSearchError)
        XCTAssertNil(store.searchDurationMilliseconds)
        XCTAssertNil(store.contentSearchPhase)
        XCTAssertFalse(store.isSearchingContent)
    }

    func testFirstExactResultIsVisibleBeforeProgressiveSearchCompletes() async throws {
        let provider = GatedProgressiveSearchRepository()
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("cache")
        await waitUntil { store.contentHits.count == 1 }
        XCTAssertTrue(store.isSearchingContent)
        XCTAssertEqual(store.contentSearchPhase, .refiningResults)
        XCTAssertEqual(store.searchDiagnostics?.engine, "Progress fixture")
        XCTAssertNotNil(store.searchFirstResultMilliseconds)
        XCTAssertNil(store.searchDurationMilliseconds, "First delivery is not whole-query completion")
        XCTAssertEqual(store.contentHits.values.first?.count, 3, "Partial publication still carries an exact count")
        provider.release()
        await waitUntil { !store.isSearchingContent && store.contentHits.count == 2 }
        XCTAssertEqual(store.contentSearchPhase, .completed)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.searchDurationMilliseconds),
                                   try XCTUnwrap(store.searchFirstResultMilliseconds))
    }

    func testLateProgressCannotReplaceANewerQueryOrRepopulateAClear() async throws {
        for replacement in ["replacement", ""] {
            let provider = GatedProgressiveSearchRepository()
            defer { provider.release() }
            let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
            await store.reload()
            store.updateListQuery("cache")
            await waitUntil { store.contentHits.count == 1 }
            store.updateListQuery(replacement)
            provider.release()
            await waitUntil { provider.finishedOldCall && !store.isSearchingContent }
            // Let deliberately late callback deliveries reach the main actor; run IDs/generations
            // must reject them even if a provider cannot interrupt its own work immediately.
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(store.listQuery, replacement)
            if replacement.isEmpty {
                XCTAssertTrue(store.contentHits.isEmpty)
                XCTAssertNil(store.searchFirstResultMilliseconds)
                XCTAssertNil(store.contentSearchPhase)
            } else {
                XCTAssertEqual(store.contentHits.count, 2)
                XCTAssertTrue(store.contentHits.values.allSatisfy { $0.snippet == replacement })
            }
        }
    }

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
        XCTAssertLessThanOrEqual(try XCTUnwrap(store.searchFirstResultMilliseconds),
                                 try XCTUnwrap(store.searchDurationMilliseconds),
                                 "A warm refresh must not pair its final time with the cold query's first-result time")
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

/// Deterministic repository-side gates make the UI contract test independent of machine speed.
/// No production delay or special search path is introduced for these tests.
private final class ScriptedCountSearchRepository: ConversationProgressiveHistoryProviding, @unchecked Sendable {
    private let condition = NSCondition()
    private var permittedStep = 0
    private var finished = false
    private let incompleteFinal: Bool
    private let restartsSnapshot: Bool

    init(incompleteFinal: Bool = false, restartsSnapshot: Bool = false) {
        self.incompleteFinal = incompleteFinal
        self.restartsSnapshot = restartsSnapshot
    }

    var didFinish: Bool {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    func release(to step: Int) {
        condition.lock()
        permittedStep = max(permittedStep, step)
        condition.broadcast()
        condition.unlock()
    }
    func releaseAll() { release(to: .max) }

    private func wait(for step: Int) throws {
        condition.lock()
        let deadline = Date().addingTimeInterval(10)
        while permittedStep < step, condition.wait(until: deadline) {}
        let allowed = permittedStep >= step
        condition.unlock()
        if !allowed { throw FixtureError.timedOut }
    }

    func listProjects(limit: Int) throws -> [HistoryProject] {
        try SearchExperienceRepository().listProjects(limit: limit)
    }

    func getSession(file: URL) throws -> HistorySession {
        let metadata = try listProjects(limit: 1)[0].sessions.first { $0.file == file }!
        return HistorySession(metadata: metadata, messages: [])
    }

    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        try SearchExperienceRepository().search(query: query, limit: limit).map {
            var value = $0; value.snippet = query; return value
        }
    }

    func search(query: String, limit: Int,
                onProgress: @Sendable (ConversationSearchProgress) -> Void) throws -> [HistorySearchHit] {
        guard query == "cache" else { return try search(query: query, limit: limit) }
        defer {
            condition.lock(); finished = true; condition.unlock()
        }
        let available = try search(query: query, limit: limit)
        var first = available[0]
        first.isCountComplete = false
        onProgress(.init(phase: .refiningResults, hits: [first], snapshotRevision: 1))
        try wait(for: 1)
        var final = restartsSnapshot ? available[1] : first
        let revision: Int64 = restartsSnapshot ? 2 : 1
        if restartsSnapshot {
            onProgress(.init(phase: .preparingCandidates, hits: [], snapshotRevision: revision))
            try wait(for: 2)
            final.isCountComplete = false
            onProgress(.init(phase: .refiningResults, hits: [final], snapshotRevision: revision))
            try wait(for: 3)
        }
        final.count = incompleteFinal ? 1 : 5
        final.isCountComplete = !incompleteFinal
        onProgress(.init(phase: .countingOccurrences, hits: [final], snapshotRevision: revision))
        onProgress(.init(phase: .completed, hits: [final], snapshotRevision: revision))
        try wait(for: restartsSnapshot ? 4 : 2)
        return [final]
    }

    private enum FixtureError: Error { case timedOut }
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

private final class GatedProgressiveSearchRepository: ConversationProgressiveHistoryProviding, @unchecked Sendable {
    private let condition = NSCondition()
    private let failsAfterPrefix: Bool
    private var released = false
    private var finished = false
    init(failsAfterPrefix: Bool = false) { self.failsAfterPrefix = failsAfterPrefix }
    var finishedOldCall: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func listProjects(limit: Int) throws -> [HistoryProject] {
        try SearchExperienceRepository().listProjects(limit: limit)
    }
    func getSession(file: URL) throws -> HistorySession {
        try SearchExperienceRepository().getSession(file: file)
    }
    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        try SearchExperienceRepository().search(query: query, limit: limit)
    }
    func search(query: String, limit: Int,
                onProgress: @Sendable (ConversationSearchProgress) -> Void) throws -> [HistorySearchHit] {
        let diagnostics = ConversationSearchDiagnostics(engine: "Progress fixture")
        var hits = try search(query: query, limit: limit)
        for index in hits.indices { hits[index].snippet = query; hits[index].count = 3 }
        onProgress(.init(phase: .preparingCandidates, hits: []))
        onProgress(.init(phase: .refiningResults, hits: Array(hits.prefix(1)), diagnostics: diagnostics))
        if query == "cache" {
            condition.lock()
            let deadline = Date().addingTimeInterval(5)
            while !released, condition.wait(until: deadline) {}
            let wasReleased = released
            condition.unlock()
            guard wasReleased else { throw FixtureError.timedOut }
            if failsAfterPrefix {
                condition.lock()
                finished = true
                condition.unlock()
                throw FixtureError.interruptedRead
            }
            // Intentionally deliver after cancellation to exercise the store's stale-result guard.
            onProgress(.init(phase: .refiningResults, hits: hits, diagnostics: diagnostics))
            condition.lock()
            finished = true
            condition.unlock()
        }
        onProgress(.init(phase: .completed, hits: hits, diagnostics: diagnostics))
        return hits
    }
    private enum FixtureError: Error { case timedOut, interruptedRead }
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
