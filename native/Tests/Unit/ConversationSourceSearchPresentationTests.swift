import Foundation
import XCTest
@testable import CCBuddy

@MainActor
final class ConversationSourceSearchPresentationTests: XCTestCase {
    func testMountedSearchRowInputsChangeForFinalCountsWithoutChangingIdentityOrMetadata() throws {
        let sessions = (0..<4).map { index in
            var metadata = Self.metadata()
            metadata.file = URL(fileURLWithPath: "/tmp/source-row-\(index).jsonl")
            metadata.id = "source-row-\(index)"
            metadata.sessionID = metadata.id
            return metadata
        }
        let initialHits = sessions.map { metadata in
            var hit = Self.hit(metadata)
            hit.isCountComplete = false
            return hit
        }
        let completedHits = initialHits.enumerated().map { index, previous in
            var hit = previous
            hit.count = [3, 4, 7, 2][index]
            hit.isCountComplete = true
            return hit
        }
        func snapshots(_ hits: [HistorySearchHit]) -> [ConversationSearchRowSnapshot] {
            ConversationSearchRowSnapshot.make(sessions: sessions,
                hits: Dictionary(uniqueKeysWithValues: hits.map { (ConversationFilter.fileKey($0.file), $0) }),
                query: "needle", selectedID: sessions[1].conversationListIdentity, language: .english)
        }
        let initial = snapshots(initialHits)
        let completed = snapshots(completedHits)
        XCTAssertEqual(initial.map(\.id), completed.map(\.id), "Counting must not remount the lazy rows")
        XCTAssertEqual(initial.map(\.metadata), completed.map(\.metadata))
        XCTAssertEqual(initial.map(\.selected), completed.map(\.selected))
        for index in initial.indices {
            XCTAssertNotEqual(initial[index], completed[index], "ForEach input must carry the changed hit")
            let lowerBound = try XCTUnwrap(initial[index].hit)
            let final = try XCTUnwrap(completed[index].hit)
            XCTAssertEqual(ConversationSearchCountPresentation.label(for: lowerBound, language: .english), "At least 1 match")
            XCTAssertEqual(ConversationSearchCountPresentation.label(for: final, language: .english),
                "\([3, 4, 7, 2][index]) matches")
            XCTAssertEqual(final.snippet, lowerBound.snippet)
        }
    }

    func testRowSnapshotsIncludeQuerySelectionLanguageAndSnippetAsValuesNotIdentity() throws {
        let metadata = Self.metadata()
        let hit = Self.hit(metadata)
        func snapshot(query: String = "needle", selected: Bool = false,
                      language: AppLanguage = .english, value: HistorySearchHit? = nil) throws -> ConversationSearchRowSnapshot {
            try XCTUnwrap(ConversationSearchRowSnapshot.make(sessions: [metadata],
                hits: [metadata.conversationListIdentity: value ?? hit], query: query,
                selectedID: selected ? metadata.conversationListIdentity : nil, language: language).first)
        }
        let initial = try snapshot()
        var changedSnippet = hit
        changedSnippet.snippet = "needle from a refreshed query snapshot"
        let alternatives = try [snapshot(query: "NEEDLE"), snapshot(selected: true),
            snapshot(language: AppLanguage.allCases.first { $0 != .english } ?? .english),
            snapshot(value: changedSnippet)]
        for changed in alternatives {
            XCTAssertEqual(changed.id, initial.id)
            XCTAssertNotEqual(changed, initial)
        }
    }

    func testSourceHitBecomesAVisibleRowBeforeTheCatalogContainsIt() {
        let metadata = Self.metadata()
        let hit = Self.hit(metadata)
        let rows = ConversationFilter.projects([], matching: "needle", contentHits: [hit.file.path: hit])
        XCTAssertEqual(rows.flatMap(\.sessions), [metadata])
        XCTAssertEqual(rows.first?.name, "source-project")
    }

    func testCatalogMetadataWinsWithoutDuplicatingTheSourceHit() {
        var catalog = Self.metadata()
        catalog.title = "Renamed by user"
        catalog.starred = true
        let original = HistoryCatalogProjection.projects(from: [catalog])
        let hit = Self.hit(Self.metadata())
        let rows = ConversationFilter.projects(original, matching: "needle", contentHits: [hit.file.path: hit])
        XCTAssertEqual(rows.flatMap(\.sessions), [catalog])
        XCTAssertEqual(original.flatMap(\.sessions), [catalog])
    }

    func testSourceRowsAreQueryLocalAndScopeAndTrashFiltered() {
        let live = Self.metadata()
        let hit = Self.hit(live)
        let hits = [hit.file.path: hit]
        XCTAssertTrue(ConversationFilter.projects([], matching: "", contentHits: hits).isEmpty)
        XCTAssertTrue(ConversationFilter.projects([], matching: "needle", contentHits: [:]).isEmpty)
        XCTAssertTrue(ConversationFilter.projects([], matching: "needle", contentHits: hits, active: "other").isEmpty)
        XCTAssertTrue(ConversationFilter.projects([], matching: "needle", contentHits: hits, active: "__trash__").isEmpty)
        XCTAssertEqual(ConversationFilter.projects([], matching: "needle", contentHits: hits, active: "fixture")
            .flatMap(\.sessions), [live])
        var deleted = live
        deleted.deleted = true
        let trashHit = Self.hit(deleted)
        XCTAssertTrue(ConversationFilter.projects([], matching: "needle", contentHits: [trashHit.file.path: trashHit]).isEmpty)
        XCTAssertEqual(ConversationFilter.projects([], matching: "needle", contentHits: [trashHit.file.path: trashHit],
            active: "__trash__").flatMap(\.sessions), [deleted])
    }

    func testFreshSourceIdentityReplacesAReusedCatalogPath() {
        let catalog = Self.metadata()
        var source = catalog
        source.source = .codex
        source.sessionID = "replacement-thread"
        source.id = "replacement-thread"
        let hit = Self.hit(source)
        let rows = ConversationFilter.projects(HistoryCatalogProjection.projects(from: [catalog]),
            matching: "needle", contentHits: [hit.file.path: hit])
        XCTAssertEqual(rows.flatMap(\.sessions), [source])
    }

    func testNewChildOfCatalogedParentOpensBeforeBackgroundCatalogRefresh() async throws {
        var catalog = Self.metadata()
        catalog.source = .codex
        catalog.threadID = "parent-thread"
        catalog.title = "Preserve the user title"
        catalog.starred = true
        var child = Self.metadata()
        child.source = .codex
        child.file = URL(fileURLWithPath: "/tmp/source-child.jsonl")
        child.id = "child-thread"
        child.sessionID = "child-thread"
        child.threadID = "child-thread"
        child.parentThreadID = catalog.threadID
        child.isSubagent = true
        var source = catalog
        source.title = "Older quick title"
        source.starred = false
        source.subagentRefs = [.init(file: child.file, threadID: "child-thread", title: "Fresh child",
            messageCount: 0, lastActivity: .distantPast)]
        source.subagentCount = 1
        let provider = SourcePresentationRepository(metadata: source, catalogMetadata: catalog, child: child)
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("needle")
        await waitUntil { store.contentHits.count == 1 }
        let row = try XCTUnwrap(store.orderedSearchSessions.first)
        XCTAssertEqual(row.title, catalog.title)
        XCTAssertTrue(row.starred)
        XCTAssertEqual(row.subagentRefs, source.subagentRefs)
        await store.select(row, searchHit: store.contentHit(for: row))
        await waitUntil { store.activeTranscriptFile == child.file && store.activeTranscript?.messages.count == 1 }
        XCTAssertEqual(store.activeTranscriptID, .subagent("child-thread"))
        XCTAssertEqual(store.jumpRequest?.messageIndex, 0)
        await store.reload()
        XCTAssertEqual(store.selectedMetadata?.subagentRefs, source.subagentRefs)
        XCTAssertEqual(store.activeTranscriptFile, child.file)
    }

    func testMismatchedSourceIdentityCannotInjectAnotherLibraryRow() {
        let original = Self.hit(Self.metadata())
        let mutations: [(inout HistorySearchHit) -> Void] = [
            { $0.file = URL(fileURLWithPath: "/tmp/different-source.jsonl") },
            { $0.sessionID = "different-session" },
            { $0.source = .codex },
            { $0.count = 0 },
            { $0.sourceMetadata = nil },
        ]
        for mutate in mutations {
            var hit = original
            mutate(&hit)
            XCTAssertTrue(ConversationFilter.projects([], matching: "needle", contentHits: [hit.file.path: hit]).isEmpty)
        }
        XCTAssertTrue(ConversationFilter.projects([], matching: "needle", contentHits: ["wrong-key": original]).isEmpty)
    }

    func testSourceMetadataRoundTripsAndOlderHitsRemainDecodable() throws {
        let hit = Self.hit(Self.metadata())
        let data = try JSONEncoder().encode(hit)
        XCTAssertEqual(try JSONDecoder().decode(HistorySearchHit.self, from: data), hit)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sourceMetadata")
        let legacy = try JSONDecoder().decode(HistorySearchHit.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.sourceMetadata)
        XCTAssertEqual(legacy.file, hit.file)
    }

    func testUncatalogedProgressiveResultIsImmediatelyOpenableAndSurvivesListReload() async throws {
        let provider = SourcePresentationRepository(metadata: Self.metadata())
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("needle")
        await waitUntil { store.orderedSearchSessions.count == 1 }
        XCTAssertTrue(store.projects.isEmpty, "Query-local rows must not mutate the persisted library snapshot")
        XCTAssertEqual(store.filteredSessionCount, 1)
        XCTAssertTrue(store.isSearchingContent)
        let row = try XCTUnwrap(store.orderedSearchSessions.first)
        let hit = try XCTUnwrap(store.contentHit(for: row))
        await store.select(row, searchHit: hit)
        XCTAssertEqual(store.detailState, .loaded)
        XCTAssertEqual(store.jumpRequest?.messageIndex, 0)
        await store.reload()
        XCTAssertEqual(store.selectedFile, row.file, "An empty quick catalog must not dismiss the source result")
        provider.release()
        await waitUntil { !store.isSearchingContent }
        XCTAssertEqual(store.orderedSearchSessions.count, 1)
        store.updateListQuery("")
        XCTAssertTrue(store.orderedSearchSessions.isEmpty)
        XCTAssertTrue(store.projects.isEmpty)
    }

    func testInvalidatedRawAttemptClearsItsOldVisiblePrefixBeforeFinalReturn() async {
        let provider = SourcePresentationRepository(metadata: Self.metadata(), retriesToEmpty: true)
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("needle")
        await waitUntil { store.orderedSearchSessions.count == 1 }
        provider.advanceRetry()
        await waitUntil { store.contentHits.isEmpty }
        XCTAssertTrue(store.orderedSearchSessions.isEmpty)
        XCTAssertTrue(store.isSearchingContent, "An invalidated prefix is not successful query completion")
        provider.release()
        await waitUntil { !store.isSearchingContent }
        XCTAssertTrue(store.contentHits.isEmpty)
        XCTAssertEqual(store.contentSearchPhase, .completed)
    }

    func testCompletedRunKeepsSourceVerificationDiagnosticsInsteadOfSharedTgrepState() async {
        let provider = SourcePresentationRepository(metadata: Self.metadata())
        defer { provider.release() }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("needle")
        await waitUntil { store.contentHits.count == 1 }
        provider.release()
        await waitUntil { !store.isSearchingContent }
        XCTAssertEqual(provider.searchDiagnostics?.engine, "Stale shared tgrep")
        XCTAssertEqual(store.searchDiagnostics?.engine, "Source verifier fixture")
        XCTAssertEqual(store.searchDiagnostics?.fallbackReason, "sourceVerification")
    }

    func testRetriedBackgroundRunKeepsPublishingAfterItsOldSnapshotWasRevoked() {
        let hit = Self.hit(Self.metadata())
        let old = UUID(), retry = UUID()
        var state = ConversationSearchProgressState()
        XCTAssertTrue(state.receive(.init(phase: .refiningResults, hits: [hit], snapshotAttempt: old), ordinal: 1))
        XCTAssertFalse(state.canPublish(preservingExistingResults: true))
        XCTAssertTrue(state.receive(.init(phase: .preparingCandidates, hits: [], snapshotAttempt: retry), ordinal: 2))
        XCTAssertTrue(state.hits.isEmpty)
        XCTAssertTrue(state.canPublish(preservingExistingResults: true))
        XCTAssertTrue(state.receive(.init(phase: .refiningResults, hits: [hit], snapshotAttempt: retry), ordinal: 3))
        XCTAssertEqual(state.hits, [hit])
        XCTAssertTrue(state.canPublish(preservingExistingResults: true),
                      "Subsequent same-attempt prefixes must not stay hidden until final return")
        XCTAssertFalse(state.receive(.init(phase: .refiningResults, hits: [hit], snapshotAttempt: old), ordinal: 4))
        XCTAssertEqual(state.snapshotAttempt, retry)
    }

    private static func metadata() -> HistorySessionMetadata {
        .init(id: "source-row", file: URL(fileURLWithPath: "/tmp/source-row.jsonl"), source: .claude,
              dirID: "fixture", dirLabel: "Fixture", sessionID: "source-row", cwd: "/tmp/source-project",
              project: "source-project", title: "Uncataloged conversation", autoTitle: "Uncataloged conversation",
              createdAt: .distantPast, lastActivity: .distantPast, sizeBytes: 100)
    }

    private static func hit(_ metadata: HistorySessionMetadata) -> HistorySearchHit {
        .init(sessionID: metadata.sessionID, file: metadata.file, source: metadata.source,
              sequence: 0, snippet: "needle", count: 1, sourceMetadata: metadata)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(predicate(), "Expected source result state was not published", file: file, line: line)
    }
}

private final class SourcePresentationRepository: ConversationProgressiveHistoryProviding,
    ConversationIndexedHistoryProviding, @unchecked Sendable {
    let metadata: HistorySessionMetadata
    let retriesToEmpty: Bool
    let catalogMetadata: HistorySessionMetadata?
    let child: HistorySessionMetadata?
    var indexTopologySignature: String { "source-presentation-fixture" }
    var searchDiagnostics: ConversationSearchDiagnostics? { .init(engine: "Stale shared tgrep") }
    private let condition = NSCondition()
    private var stage = 0

    init(metadata: HistorySessionMetadata, retriesToEmpty: Bool = false,
         catalogMetadata: HistorySessionMetadata? = nil, child: HistorySessionMetadata? = nil) {
        self.metadata = metadata
        self.retriesToEmpty = retriesToEmpty
        self.catalogMetadata = catalogMetadata
        self.child = child
    }

    func listProjects(limit: Int) throws -> [HistoryProject] {
        HistoryCatalogProjection.projects(from: catalogMetadata.map { [$0] } ?? [])
    }
    func scoped(to active: String) -> any ConversationIndexedHistoryProviding { self }
    func startIndexing(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void) {}
    func stopIndexing() {}
    func reconcileIndex() throws {}
    func refreshIndex(for files: [URL]) throws {}
    func getSession(file: URL) throws -> HistorySession {
        if let child, file == child.file {
            return .init(metadata: child, messages: [.init(role: "assistant", content: [.init(type: "text", text: "needle")])])
        }
        guard file == metadata.file else { throw HistoryError.invalidPath(file) }
        var rawMetadata = metadata
        rawMetadata.subagentRefs = []
        rawMetadata.subagentCount = 0
        return .init(metadata: rawMetadata, messages: [.init(role: "assistant", content: [.init(type: "text", text: "needle")])])
    }
    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        [.init(sessionID: metadata.sessionID, file: metadata.file, source: metadata.source,
               agent: child?.threadID ?? "main", sequence: 0, snippet: "needle", count: 1, sourceMetadata: metadata)]
    }
    func search(query: String, limit: Int,
                onProgress: @Sendable (ConversationSearchProgress) -> Void) throws -> [HistorySearchHit] {
        let hits = try search(query: query, limit: limit)
        let attempt = UUID()
        var diagnostics = ConversationSearchDiagnostics(engine: "Source verifier fixture")
        diagnostics.usedFallback = true
        diagnostics.fallbackReason = "sourceVerification"
        onProgress(.init(phase: .refiningResults, hits: hits, diagnostics: diagnostics, snapshotRevision: 1,
                         snapshotIdentity: "fixture-catalog", snapshotAttempt: attempt))
        try wait(for: retriesToEmpty ? 1 : 2)
        if retriesToEmpty {
            let retry = UUID()
            onProgress(.init(phase: .preparingCandidates, hits: [], snapshotRevision: 1,
                             snapshotIdentity: "fixture-catalog", snapshotAttempt: retry))
            try wait(for: 2)
            onProgress(.init(phase: .completed, hits: [], snapshotRevision: 1,
                             snapshotIdentity: "fixture-catalog", snapshotAttempt: retry))
            return []
        }
        return hits
    }

    func advanceRetry() { setStage(1) }
    func release() { setStage(2) }
    private func setStage(_ value: Int) {
        condition.lock()
        stage = max(stage, value)
        condition.broadcast()
        condition.unlock()
    }
    private func wait(for value: Int) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while stage < value, condition.wait(until: deadline) {}
        guard stage >= value else { throw HistoryError.unreadableFile(metadata.file, "Fixture barrier timed out") }
    }
}
