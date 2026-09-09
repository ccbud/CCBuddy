import Foundation
import XCTest
@testable import CCBuddy

final class IndexedHistoryRepositoryParityTests: XCTestCase {
    func testEqualActivitySearchPrefixesAndLimitFollowPresentationOrderWithoutChangingCatalogOrder() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-search-tie-order")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, sessions) = try makeEqualActivityRepository(home: home, count: 225)
        let expected = sessions.map(\.metadata.file)
        XCTAssertEqual(try repository.listSessions(limit: .max).map(\.file), Array(expected.reversed()),
            "The catalog retains its existing creation-time/producer-ID ordering")
        let recorder = SearchProgressRecorder()
        let final = try repository.search(query: "deepcatalogneedle", limit: 200) { recorder.append($0) }
        XCTAssertEqual(final.map(\.file), Array(expected.prefix(200)),
            "The hit limit must be applied after the same tie-breaker used by the palette")
        let prefixes = recorder.snapshot.filter { !$0.hits.isEmpty }
        XCTAssertGreaterThan(prefixes.count, 2)
        XCTAssertEqual(prefixes.first?.hits.count, 1)
        for event in prefixes {
            XCTAssertEqual(event.hits.map(\.file), Array(expected.prefix(event.hits.count)),
                "A published prefix cannot be reversed by the UI before later batches arrive")
        }
        XCTAssertEqual(try repository.search(query: "deepcatalogneedle", limit: 200), final,
            "Warm/final-only search has the same membership and order")
        XCTAssertEqual(try repository.listSessions(limit: .max).map(\.file), Array(expected.reversed()))
    }

    @MainActor
    func testSearchOrderingBreaksDuplicateProducerIDsBySourcePath() async throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-search-duplicate-id-order")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, sessions) = try makeEqualActivityRepository(home: home, count: 12,
                                                                    duplicateStableIDs: true)
        XCTAssertEqual(Set(sessions.map(\.metadata.id)).count, 1)
        let expected = sessions.map(\.metadata.file)
        let store = ConversationStore(repository: SearchPrefixGatedRepository(repository: repository,
                                                                               thresholds: []))
        await store.reload()
        XCTAssertEqual(store.orderedSearchSessions.map(\.file), expected)
        let recorder = SearchProgressRecorder()
        XCTAssertEqual(try repository.search(query: "deepcatalogneedle", limit: 12) { recorder.append($0) }
            .map(\.file), expected)
        for event in recorder.snapshot {
            XCTAssertEqual(event.hits.map(\.file), Array(expected.prefix(event.hits.count)))
        }
    }

    @MainActor
    func testEqualActivityProgressiveStoreKeepsInitialAndKeyboardHighlightsInPlace() async throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-search-store-tie-order")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, sessions) = try makeEqualActivityRepository(home: home, count: 96)
        let provider = SearchPrefixGatedRepository(repository: repository, thresholds: [1, 49, 96])
        defer { provider.release(through: .max) }
        let store = ConversationStore(repository: provider, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("deepcatalogneedle")
        let expectedFiles = sessions.map { ConversationFilter.fileKey($0.metadata.file) }
        var automaticSelection = ConversationSearchSelection()
        var keyboardSelection = ConversationSearchSelection()

        for step in 1...3 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline,
                  provider.blockedStep != step || store.contentHits.count != provider.blockedCount {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertEqual(provider.blockedStep, step)
            let count = provider.blockedCount
            XCTAssertEqual(store.contentHits.count, count)
            XCTAssertGreaterThan(count, 0)
            let files = store.orderedSearchSessions.map { ConversationFilter.fileKey($0.file) }
            XCTAssertEqual(files, Array(expectedFiles.prefix(count)))
            automaticSelection.reconcile(files: files)
            keyboardSelection.reconcile(files: files)
            XCTAssertEqual(automaticSelection.index, 0,
                "Untouched search must not scroll into the middle of a tied result set")
            XCTAssertEqual(automaticSelection.file, expectedFiles.first)
            if step == 2 { keyboardSelection.move(by: 8, files: files) }
            if step >= 2 {
                XCTAssertEqual(keyboardSelection.index, 8)
                XCTAssertEqual(keyboardSelection.file, expectedFiles[8])
            }
            provider.release(through: step)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.isSearchingContent, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(store.isSearchingContent)
        XCTAssertNil(store.contentSearchError)
        XCTAssertEqual(store.contentHits.count, 96)
        XCTAssertTrue(store.contentHits.values.allSatisfy(\.isCountComplete))
        let finalFiles = store.orderedSearchSessions.map { ConversationFilter.fileKey($0.file) }
        XCTAssertEqual(finalFiles, expectedFiles)
        automaticSelection.reconcile(files: finalFiles)
        keyboardSelection.reconcile(files: finalFiles)
        XCTAssertEqual(automaticSelection.index, 0)
        XCTAssertEqual(keyboardSelection.index, 8)
        store.updateListQuery("")
    }

    func testScopeCountsUseVisibleCodexTreesWithoutCrossScopeOrTrashFolding() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-visible-counts")
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("first")
        let second = home.appendingPathComponent("second")
        let hidden = home.appendingPathComponent("not-configured")
        let database = try ConversationIndexDatabase(file: home.appendingPathComponent("index.sqlite3"))
        for value in [
            indexedCodex(scope: first, id: "parent"),
            indexedCodex(scope: first, id: "child", parent: "parent"),
            indexedCodex(scope: first, id: "grandchild", parent: "child"),
            indexedCodex(scope: first, id: "orphan", parent: "missing"),
            indexedCodex(scope: second, id: "cross-scope-child", parent: "parent"),
            indexedCodex(scope: first, id: "deleted-parent", deleted: true),
            indexedCodex(scope: first, id: "deleted-child", parent: "deleted-parent", deleted: true),
            indexedCodex(scope: first, id: "live-child", parent: "deleted-parent"),
            indexedCodex(scope: hidden, id: "hidden"),
        ] { try database.replace(value) }
        let configuration = HistoryConfiguration(historyDirs: [first.path, second.path],
            homeDirectory: home, importsRoot: home.appendingPathComponent("app/imports"))
        let repository = IndexedHistoryRepository(configuration: configuration, database: database)
        let snapshot = try XCTUnwrap(repository.conversationScopeSnapshot())
        XCTAssertEqual(snapshot.sessionCounts, [first.path: 3, second.path: 1])
        XCTAssertEqual(snapshot.trashCount, 1)
        XCTAssertEqual(try repository.listSessions(limit: .max).count, 4)
        for active in [first.path, second.path, "__trash__"] {
            var scoped = configuration
            scoped.active = active
            let provider = IndexedHistoryRepository(configuration: scoped, database: database)
            XCTAssertEqual(provider.conversationScopeSnapshot(), snapshot,
                "The library tally is authoritative and independent of the active scope")
            XCTAssertEqual(try provider.listSessions(limit: .max).count,
                active == "__trash__" ? snapshot.trashCount : snapshot.sessionCounts[active, default: 0])
        }
    }

    func testFoldedCodexChildAndGrandchildSearchMapToParentAndExactLazyTab() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-child-search")
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("first")
        let second = home.appendingPathComponent("second")
        let database = try ConversationIndexDatabase(file: home.appendingPathComponent("index.sqlite3"))
        let parent = indexedCodex(scope: first, id: "parent", text: "common parent contents")
        let crossScope = indexedCodex(scope: second, id: "cross-scope", parent: "parent", text: "foreign-only needle")
        let deleted = indexedCodex(scope: first, id: "deleted", parent: "parent", text: "trash-only needle", deleted: true)
        for value in [parent, crossScope, deleted,
            indexedCodex(scope: first, id: "child", parent: "parent", text: "common child-only needle child-only needle", sequence: 2),
            indexedCodex(scope: first, id: "grandchild", parent: "child", text: "grandchild-only target", sequence: 3),
            indexedCodex(scope: home.appendingPathComponent("hidden"), id: "hidden", parent: "parent", text: "hidden-only needle"),
        ] { try database.replace(value) }
        let configuration = HistoryConfiguration(historyDirs: [first.path, second.path],
            homeDirectory: home, importsRoot: home.appendingPathComponent("app/imports"))
        let repository = IndexedHistoryRepository(configuration: configuration, database: database)
        let child = try XCTUnwrap(repository.search(query: "child-only needle").first)
        XCTAssertEqual(child.file, parent.metadata.file)
        XCTAssertEqual(child.sessionID, parent.metadata.sessionID)
        XCTAssertEqual(child.agent, "child")
        XCTAssertEqual(child.sequence, 2)
        XCTAssertEqual(child.count, 2)
        let grandchild = try XCTUnwrap(repository.search(query: "grandchild-only").first)
        XCTAssertEqual(grandchild.file, parent.metadata.file)
        XCTAssertEqual(grandchild.agent, "grandchild")
        XCTAssertEqual(grandchild.sequence, 3)
        XCTAssertEqual(try repository.search(query: "common").map(\.agent), ["main"])
        let foreign = try XCTUnwrap(repository.search(query: "foreign-only").first)
        XCTAssertEqual(foreign.file, crossScope.metadata.file)
        XCTAssertEqual(foreign.agent, "main", "A parent ID in another scope cannot absorb this hit")
        XCTAssertTrue(try repository.search(query: "trash-only").isEmpty)
        XCTAssertTrue(try repository.search(query: "hidden-only").isEmpty)
        let scoped = repository.scoped(to: first.path)
        XCTAssertTrue(try scoped.search(query: "foreign-only", limit: 20).isEmpty)
        XCTAssertEqual(try scoped.search(query: "child-only needle", limit: 20).map(\.file), [parent.metadata.file])
        XCTAssertEqual(try repository.scoped(to: "__trash__").search(query: "trash-only", limit: 20).map(\.file), [deleted.metadata.file])
    }

    func testWarmIndexMatchesLegacyListsProjectsQoderAndCanonicalCodex() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-parity-list")
        defer { try? FileManager.default.removeItem(at: home) }
        let qoderRoot = home.appendingPathComponent(".qoder")
        let codexRoot = home.appendingPathComponent(".codex")
        let imports = home.appendingPathComponent("app/imports")

        let qoderID = "11111111-1111-4111-8111-111111111111"
        let qoder = qoderRoot.appendingPathComponent("projects/-work-shared/\(qoderID).jsonl")
        try HistoryTestSupport.write([
            #"{"type":"ai-title","sessionId":"\#(qoderID)","aiTitle":"Qoder parity"}"#,
            #"{"type":"workspace-directories","sessionId":"\#(qoderID)","directories":["/work/shared"]}"#,
            #"{"type":"user","timestamp":"2026-08-20T00:00:00Z","message":{"role":"user","content":"qoder catalog compatibility"},"sessionId":"\#(qoderID)"}"#,
            #"{"type":"assistant","timestamp":"2026-08-20T00:00:01Z","message":{"id":"q-answer","role":"assistant","model":"qoder-model","usage":{"input_tokens":12,"output_tokens":5,"credits":0.75},"content":[{"type":"text","text":"qoder response"}]},"sessionId":"\#(qoderID)"}"#,
        ], to: qoder, modifiedAt: Date(timeIntervalSince1970: 1_800_000_100))

        let threadID = "511a7eed-4f83-46ba-afff-4e08b18c12f5"
        let oldCodex = codexRoot.appendingPathComponent(
            "sessions/2026/08/20/rollout-old.jsonl"
        )
        let newCodex = codexRoot.appendingPathComponent(
            "sessions/2026/08/21/rollout-\(threadID).jsonl"
        )
        let codexMetadata = #"{"id":"\#(threadID)","session_id":"\#(threadID)","cwd":"/work/shared"}"#
        try writeCodex(
            file: oldCodex,
            metadata: codexMetadata,
            text: "obsolete codex duplicate",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try writeCodex(
            file: newCodex,
            metadata: codexMetadata,
            text: "canonical codex compatibility",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )

        let configuration = HistoryConfiguration(
            historyDirs: [qoderRoot.path, codexRoot.path],
            homeDirectory: home,
            importsRoot: imports
        )
        let legacy = HistoryRepository(configuration: configuration)
        let (indexed, _) = try makeWarmRepository(configuration: configuration)

        XCTAssertEqual(try indexed.listSessions(limit: 400), legacy.listSessions(limit: 400))
        XCTAssertEqual(try indexed.listProjects(limit: 600), legacy.listProjects(limit: 600))
        XCTAssertEqual(
            try indexed.listSessions().map { $0.source.rawValue }.sorted(),
            ["codex", "qoder"]
        )
        XCTAssertEqual(
            try indexed.listSessions().first(where: { $0.source == .qoder })?.totals.credits,
            0.75
        )
        XCTAssertEqual(
            try indexed.listSessions().first(where: { $0.source == .codex })?.file,
            newCodex.standardizedFileURL
        )
        XCTAssertTrue(try indexed.search(query: "obsolete", limit: 120).isEmpty)
        XCTAssertEqual(
            try indexed.search(query: "catalog compatibility", limit: 120).map(\.source),
            [.qoder]
        )
    }

    func testIndexedSearchPreservesExactSubstringOrderSnippetAndCount() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-parity-search")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("history")
        let imports = home.appendingPathComponent("app/imports")
        let newer = root.appendingPathComponent("projects/-search/newer.jsonl")
        let older = root.appendingPathComponent("projects/-search/older.jsonl")
        let separated = String(repeating: "leading context ", count: 7)
            + "Needle phrase middle Needle phrase"
            + String(repeating: " trailing context", count: 7)
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user", contentJSON: jsonString(separated),
                sessionID: "newer", cwd: "/search",
                timestamp: "2026-08-22T00:00:00Z"
            ),
            HistoryTestSupport.claudeLine(
                type: "user", role: "user",
                contentJSON: #""<system-reminder>private-index-needle</system-reminder>""#,
                sessionID: "newer", cwd: "/search",
                timestamp: "2026-08-22T00:00:01Z"
            ),
        ], to: newer, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user",
                contentJSON: #""needle is deliberately separated from phrase""#,
                sessionID: "older", cwd: "/search",
                timestamp: "2026-08-21T00:00:00Z"
            ),
        ], to: older, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let configuration = HistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: home,
            importsRoot: imports
        )
        let legacy = HistoryRepository(configuration: configuration)
        let (indexed, _) = try makeWarmRepository(configuration: configuration)

        let legacyBroad = legacy.search(query: "nEeDlE", limit: 120)
        let indexedBroad = try indexed.search(query: "nEeDlE", limit: 120)
        assertLegacySearchFields(indexedBroad, equalTo: legacyBroad)
        XCTAssertEqual(indexedBroad.map(\.sessionID), ["newer", "older"])
        XCTAssertEqual(indexedBroad.map(\.count), [2, 1])
        XCTAssertTrue(indexedBroad[0].snippet.hasPrefix("…"))
        XCTAssertTrue(indexedBroad[0].snippet.hasSuffix("…"))
        XCTAssertEqual(indexedBroad[0].sequence, 0)

        let exactLegacy = legacy.search(query: "needle phrase", limit: 120)
        let exactIndexed = try indexed.search(query: "needle phrase", limit: 120)
        assertLegacySearchFields(exactIndexed, equalTo: exactLegacy)
        XCTAssertEqual(exactIndexed.map(\.sessionID), ["newer"])
        XCTAssertTrue(try indexed.search(query: "private-index-needle", limit: 120).isEmpty)
    }

    func testIndexedQoderSubagentHitCarriesTranscriptAndExactMessageSequence() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-parity-subagent")
        defer { try? FileManager.default.removeItem(at: home) }
        let qoderRoot = home.appendingPathComponent(".qoder")
        let imports = home.appendingPathComponent("app/imports")
        let sessionID = "22222222-2222-4222-8222-222222222222"
        let main = qoderRoot.appendingPathComponent(
            "projects/-work-subagents/\(sessionID).jsonl"
        )
        try HistoryTestSupport.write([
            #"{"type":"user","timestamp":"2026-08-22T00:00:00Z","message":{"role":"user","content":"main thread has no target"},"sessionId":"\#(sessionID)"}"#,
            #"{"type":"assistant","timestamp":"2026-08-22T00:00:01Z","message":{"id":"main-answer","role":"assistant","content":[{"type":"tool_use","id":"tu-sub","name":"Task","input":{"description":"inspect"}}]},"sessionId":"\#(sessionID)"}"#,
        ], to: main)
        let subagents = main.deletingLastPathComponent()
            .appendingPathComponent(sessionID)
            .appendingPathComponent("subagents")
        try HistoryTestSupport.write([
            #"{"type":"user","timestamp":"2026-08-22T00:00:02Z","message":{"role":"user","content":"warmup"},"sessionId":"\#(sessionID)"}"#,
            #"{"type":"assistant","timestamp":"2026-08-22T00:00:03Z","message":{"id":"sub-answer","role":"assistant","content":[{"type":"text","text":"subagent capybara target"}]},"sessionId":"\#(sessionID)"}"#,
        ], to: subagents.appendingPathComponent("agent-child.jsonl"))
        try HistoryTestSupport.write([
            #"{"toolUseId":"tu-sub","agentType":"explore","description":"inspect"}"#,
        ], to: subagents.appendingPathComponent("agent-child.meta.json"))

        let configuration = HistoryConfiguration(
            historyDirs: [qoderRoot.path],
            homeDirectory: home,
            importsRoot: imports
        )
        let legacy = HistoryRepository(configuration: configuration)
        let (indexed, _) = try makeWarmRepository(configuration: configuration)
        let legacyHit = try XCTUnwrap(legacy.search(query: "capybara", limit: 120).first)
        let indexedHit = try XCTUnwrap(indexed.search(query: "capybara", limit: 120).first)

        XCTAssertEqual(indexedHit.agent, legacyHit.agent)
        XCTAssertEqual(indexedHit.agent, "tu-sub")
        XCTAssertEqual(indexedHit.agentType, "explore")
        XCTAssertEqual(indexedHit.sequence, 1)
        XCTAssertEqual(indexedHit.snippet, legacyHit.snippet)
        XCTAssertEqual(indexedHit.count, legacyHit.count)
    }

    func testWarmIndexMatchesAllImportedConfiguredAndTrashScopes() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-parity-scopes")
        defer { try? FileManager.default.removeItem(at: home) }
        let liveRoot = home.appendingPathComponent("live")
        let otherRoot = home.appendingPathComponent("other")
        let imports = home.appendingPathComponent("app/imports")

        try writeClaude(
            file: liveRoot.appendingPathComponent("projects/-scope/live.jsonl"),
            sessionID: "live", cwd: "/scope/live", text: "scope needle live",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let deleted = liveRoot.appendingPathComponent("projects/-scope/deleted.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user", contentJSON: #""scope needle deleted""#,
                sessionID: "deleted", cwd: "/scope/live",
                timestamp: "2026-08-20T00:00:00Z"
            ),
            #"{"__ccbud__":{"delete":true,"tagList":["trash"]}}"#,
        ], to: deleted, modifiedAt: Date(timeIntervalSince1970: 1_800_000_200))
        try writeClaude(
            file: otherRoot.appendingPathComponent("projects/-scope/other.jsonl"),
            sessionID: "other", cwd: "/scope/other", text: "scope needle other",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        try writeClaude(
            file: imports.appendingPathComponent("projects/-scope/imported.jsonl"),
            sessionID: "imported", cwd: "/scope/imported", text: "scope needle imported",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let allConfiguration = HistoryConfiguration(
            historyDirs: [liveRoot.path, otherRoot.path],
            homeDirectory: home,
            importsRoot: imports
        )
        let (_, database) = try makeWarmRepository(configuration: allConfiguration)

        for active in ["all", liveRoot.path, otherRoot.path, "__imported__", "__trash__"] {
            var configuration = allConfiguration
            configuration.active = active
            let legacy = HistoryRepository(configuration: configuration)
            let indexed = IndexedHistoryRepository(
                configuration: configuration,
                database: database,
                loader: HistorySessionLoader(configuration: configuration)
            )
            XCTAssertEqual(
                try indexed.listSessions(limit: 400),
                legacy.listSessions(limit: 400),
                "session parity for scope \(active)"
            )
            XCTAssertEqual(
                try indexed.listProjects(limit: 600),
                legacy.listProjects(limit: 600),
                "project parity for scope \(active)"
            )
            assertLegacySearchFields(
                try indexed.search(query: "scope needle", limit: 120),
                equalTo: legacy.search(query: "scope needle", limit: 120),
                message: "search parity for scope \(active)"
            )
        }

        let legacySnapshot = try XCTUnwrap(
            HistoryRepository(configuration: allConfiguration).conversationScopeSnapshot()
        )
        let indexedSnapshot = try XCTUnwrap(IndexedHistoryRepository(
            configuration: allConfiguration,
            database: database,
            loader: HistorySessionLoader(configuration: allConfiguration)
        ).conversationScopeSnapshot())
        XCTAssertEqual(indexedSnapshot, legacySnapshot)
        XCTAssertEqual(indexedSnapshot.trashCount, 1)
        XCTAssertEqual(indexedSnapshot.importedCount, 1)
    }

    func testProgressiveSearchPublishesExactOrderedPrefixesAndMatchesFinalAPI() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-progressive-prefixes")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, _, _) = try makeProgressiveRepository(home: home, count: 12)
        let recorder = SearchProgressRecorder()
        let provider: any ConversationProgressiveHistoryProviding = repository
        let final = try provider.search(query: "系统代理", limit: 9) { recorder.append($0) }
        let expected = try repository.search(query: "系统代理", limit: 9)
        let events = recorder.snapshot
        XCTAssertEqual(final, expected)
        XCTAssertEqual(final.count, 9)
        XCTAssertEqual(events.first?.phase, .preparingCandidates)
        XCTAssertNil(events.first?.diagnostics)
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(events.last?.hits, final)
        let refined = events.filter { $0.phase == .refiningResults }
        XCTAssertEqual(refined.first?.hits, [])
        XCTAssertEqual(refined.first(where: { !$0.hits.isEmpty })?.hits.map(\.id),
            Array(expected.prefix(1)).map(\.id))
        XCTAssertFalse(try XCTUnwrap(refined.first(where: { !$0.hits.isEmpty })?.hits.first).isCountComplete)
        XCTAssertTrue(events.contains { $0.phase == .countingOccurrences })
        var previousCount = 0
        for event in events.dropFirst() {
            XCTAssertEqual(event.hits.map(\.id), Array(expected.prefix(event.hits.count)).map(\.id))
            XCTAssertGreaterThanOrEqual(event.hits.count, previousCount)
            XCTAssertLessThanOrEqual(event.hits.count - previousCount, 8)
            XCTAssertNotNil(event.diagnostics)
            for (offset, hit) in event.hits.enumerated() {
                XCTAssertGreaterThan(hit.count, 0)
                XCTAssertNotNil(hit.sequence)
                XCTAssertFalse(hit.snippet.isEmpty)
                XCTAssertEqual(hit.sequence, expected[offset].sequence)
                XCTAssertEqual(hit.snippet, expected[offset].snippet)
                XCTAssertLessThanOrEqual(hit.count, expected[offset].count)
                if hit.isCountComplete { XCTAssertEqual(hit, expected[offset]) }
            }
            previousCount = event.hits.count
        }
    }

    func testFirstProgressiveHitArrivesBeforeAnOlderDocumentIsReadAndOutsideDatabaseLock() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-progressive-first")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, database, sessions) = try makeProgressiveRepository(home: home, count: 2)
        var replacement = sessions[1]
        replacement.documents[0].text = "The older transcript no longer matches."
        let updated = replacement
        let recorder = SearchProgressRecorder()
        let final = try repository.search(query: "系统代理", limit: 20) { event in
            recorder.append(event)
            if event.phase == .refiningResults, event.hits.count == 1, recorder.claimMutation() {
                // A callback delivered after full verification would be too late:
                // the older hit would already have been included. Re-entrant catalog
                // access also verifies that callbacks do not hold its reader lock.
                do {
                    _ = try database.generation()
                    try database.replace(updated)
                } catch { XCTFail("Progress callback could not access catalog: \(error)") }
            }
        }
        XCTAssertEqual(final.map(\.file), [sessions[0].metadata.file])
        XCTAssertEqual(recorder.snapshot.last?.hits, final)
        XCTAssertEqual(final, try repository.search(query: "系统代理", limit: 20))
        XCTAssertEqual(Set(recorder.snapshot.compactMap(\.snapshotRevision)).count, 2,
            "A live update must restart the snapshot, never mix generations")
    }

    func testFirstHitPrecedesDenseLongTranscriptCountAndOnlyCompleteAnswerIsCached() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-progressive-dense")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, database, sessions) = try makeProgressiveRepository(home: home, count: 1)
        var session = sessions[0]
        session.documents[0].text = String(repeating: "系统代理 /src/search_index.swift 当前版本\n", count: 30_000)
        try database.replace(session)
        let recorder = SearchProgressRecorder()
        let final = try repository.search(query: "系统代理", limit: 1) { event in
            recorder.append(event)
            if event.phase == .refiningResults, let hit = event.hits.first {
                XCTAssertEqual(hit.count, 1)
                XCTAssertFalse(hit.isCountComplete)
                XCTAssertEqual(database.searchRefinementCache.statistics.stores, 0)
            }
        }
        XCTAssertEqual(final.first?.count, 30_000)
        XCTAssertEqual(final.first?.isCountComplete, true)
        XCTAssertEqual(database.searchRefinementCache.statistics.stores, 1)
        let counts = recorder.snapshot.filter { $0.phase == .countingOccurrences }
        XCTAssertEqual(counts.first?.hits.first?.isCountComplete, false)
        XCTAssertEqual(counts.last?.hits.first?.isCountComplete, true)
        XCTAssertEqual(counts.first?.hits.map(\.id), counts.last?.hits.map(\.id))
    }

    func testReplacementDuringCountingRestartsAnchorsAndCachesOnlyTheNewCompleteCount() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-counting-replacement")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, database, sessions) = try makeProgressiveRepository(home: home, count: 1)
        let query = "系统代理"
        var original = sessions[0]
        original.documents[0].text = "Original prefix 系统代理 outdated 系统代理."
        original.documents[0].messageSpans = [.init(sequence: 101, messageIndex: 0,
            utf16Location: 0, utf16Length: original.documents[0].text.utf16.count, role: "assistant")]
        let oldGeneration = try database.replace(original)
        let oldReference = try XCTUnwrap(database.candidateDocumentReferences(for: query).references.first)
        let oldKey = ConversationSearchRefinementCache.Key(reference: oldReference, query: query)
        var replacement = original
        replacement.documents[0].text = "Replacement prefix 系统代理 changed 系统代理 final 系统代理."
        replacement.documents[0].messageSpans = [.init(sequence: 909, messageIndex: 0,
            utf16Location: 0, utf16Length: replacement.documents[0].text.utf16.count, role: "assistant")]
        let updated = replacement
        let originalSnippet = original.documents[0].text
        let cache = database.searchRefinementCache
        let recorder = SearchProgressRecorder()
        let final = try repository.search(query: query, limit: 1) { event in
            recorder.append(event)
            if event.phase == .countingOccurrences,
               event.hits.first?.isCountComplete == false, recorder.claimMutation() {
                XCTAssertEqual(event.snapshotRevision, oldGeneration)
                XCTAssertEqual(event.hits.first?.sequence, 101)
                XCTAssertEqual(event.hits.first?.snippet, originalSnippet)
                XCTAssertEqual(event.hits.first?.count, 1)
                XCTAssertEqual(cache.statistics.stores, 0,
                    "A verified first occurrence must not be cached as an exact total")
                XCTAssertNil(cache.lookup(oldKey))
                do {
                    let replacementGeneration = try database.replace(updated)
                    XCTAssertGreaterThan(replacementGeneration, oldGeneration)
                } catch { XCTFail("Counting callback could not replace its transcript: \(error)") }
            }
        }
        let newGeneration = try database.generation()
        XCTAssertGreaterThan(newGeneration, oldGeneration)
        let expected = HistorySearchHit(sessionID: updated.metadata.sessionID,
            file: updated.metadata.file, source: updated.metadata.source,
            agent: "main", sequence: 909, snippet: updated.documents[0].text,
            count: 3, isCountComplete: true)
        XCTAssertEqual(final, [expected])
        let events = recorder.snapshot
        XCTAssertEqual(Set(events.compactMap(\.snapshotRevision)), [oldGeneration, newGeneration])
        let oldEvents = events.filter { $0.snapshotRevision == oldGeneration }
        XCTAssertTrue(oldEvents.contains { $0.phase == .countingOccurrences })
        XCTAssertFalse(oldEvents.contains { $0.phase == .completed })
        for hit in oldEvents.flatMap(\.hits) {
            XCTAssertEqual(hit.id, expected.id, "The replaced transcript retains its result identity")
            XCTAssertEqual(hit.sequence, 101)
            XCTAssertEqual(hit.snippet, originalSnippet)
            XCTAssertEqual(hit.count, 1)
            XCTAssertFalse(hit.isCountComplete, "No old-revision callback may receive the replacement's count")
        }
        for hit in events.filter({ $0.snapshotRevision == newGeneration }).flatMap(\.hits) {
            XCTAssertEqual(hit.sequence, expected.sequence)
            XCTAssertEqual(hit.snippet, expected.snippet)
            XCTAssertEqual(hit.count, hit.isCountComplete ? 3 : 1)
        }
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(events.last?.hits, final)
        XCTAssertEqual(cache.statistics.stores, 1)
        XCTAssertEqual(cache.statistics.entries, 1)
        XCTAssertEqual(cache.statistics.validatedHits, 0)
        let newReference = try XCTUnwrap(database.candidateDocumentReferences(for: query).references.first)
        let entry = try XCTUnwrap(cache.lookup(.init(reference: newReference, query: query)))
        XCTAssertEqual(entry.generation, newGeneration)
        XCTAssertEqual(entry.result.hit(for: updated.metadata, agentOverride: nil), expected)
        if let reusedRow = cache.lookup(oldKey) {
            XCTAssertEqual(reusedRow.generation, newGeneration,
                "SQLite row-ID reuse must not preserve the old partial answer")
        }

        let warmRecorder = SearchProgressRecorder()
        XCTAssertEqual(try repository.search(query: query, limit: 1) { warmRecorder.append($0) }, final)
        XCTAssertEqual(cache.statistics.stores, 1)
        XCTAssertEqual(cache.statistics.validatedHits, 1)
        XCTAssertEqual(Set(warmRecorder.snapshot.compactMap(\.snapshotRevision)), [newGeneration])
        XCTAssertFalse(warmRecorder.snapshot.contains { $0.phase == .countingOccurrences })
        XCTAssertTrue(warmRecorder.snapshot.flatMap(\.hits).allSatisfy(\.isCountComplete))
    }

    func testChunkedSearchPreservesBoundaryLongLiteralUnicodeAnchorsAndSnippets() throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-chunk-parity")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, database, sessions) = try makeProgressiveRepository(home: home, count: 1)
        let examples: [(String, String)] = [
            (String(repeating: "x", count: 32_765) + "系统代理_current/v2 系统代理_current/v2", "系统代理_current/v2"),
            (String(repeating: "x", count: 32_766) + "cafe\u{301} CAFÉ café", "café"),
            (String(repeating: "x", count: 32_767) + String(repeating: "跨界Z", count: 200),
                String(repeating: "跨界Z", count: 80)),
            (String(repeating: "a", count: 150_000), String(repeating: "a", count: 40_001)),
            (String(repeating: "x", count: 32_767) + "ﬃ ffi FFI", "ffi"),
        ]
        for (text, query) in examples {
            var session = sessions[0]
            session.documents[0].text = text
            session.documents[0].messageSpans = [.init(sequence: 314, messageIndex: 0,
                utf16Location: 0, utf16Length: text.utf16.count, role: "assistant")]
            try database.replace(session)
            let exact = try XCTUnwrap(ConversationLiteralSearch(query: query).match(in: text))
            let hit = try XCTUnwrap(repository.search(query: query).first)
            XCTAssertEqual(hit.count, exact.count, query)
            XCTAssertEqual(hit.sequence, 314)
            XCTAssertTrue(hit.isCountComplete)
            let start = text.index(exact.range.lowerBound, offsetBy: -56, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(exact.range.upperBound, offsetBy: 56, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = (start > text.startIndex ? "…" : "")
                + text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                + (end < text.endIndex ? "…" : "")
            XCTAssertEqual(hit.snippet, snippet)
        }
    }

    func testProgressiveSearchCancellationAfterFirstHitDoesNotPublishCompletionOrLaterHits() async throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-progressive-cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, _, _) = try makeProgressiveRepository(home: home, count: 3)
        let recorder = SearchProgressRecorder()
        let worker = Task.detached {
            try repository.search(query: "系统代理", limit: 1) { event in
                recorder.append(event)
                if event.phase == .refiningResults, !event.hits.isEmpty {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await worker.value
            XCTFail("Cancellation in the first-hit callback must abort even at the hit limit")
        } catch is CancellationError {}
        let events = recorder.snapshot
        XCTAssertEqual(events.map(\.phase), [.preparingCandidates, .refiningResults, .refiningResults])
        XCTAssertEqual(events.last?.hits.count, 1)
        XCTAssertFalse(events.contains { $0.phase == .completed })
        XCTAssertEqual(try repository.search(query: "系统代理", limit: 20).count, 3)
    }

    func testPrecancelledProgressiveSearchPublishesNothingAndEmptySearchCompletesOnce() async throws {
        let home = try HistoryTestSupport.temporaryDirectory("indexed-progressive-empty")
        defer { try? FileManager.default.removeItem(at: home) }
        let (repository, _, _) = try makeProgressiveRepository(home: home, count: 1)
        let cancelledEvents = SearchProgressRecorder()
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try repository.search(query: "系统代理", limit: 20) { cancelledEvents.append($0) }
        }
        do {
            _ = try await worker.value
            XCTFail("A precancelled search must not publish preparation")
        } catch is CancellationError {}
        XCTAssertTrue(cancelledEvents.snapshot.isEmpty)
        for (query, limit) in [("  ", 20), ("系统代理", 0)] {
            let recorder = SearchProgressRecorder()
            XCTAssertEqual(try repository.search(query: query, limit: limit) { recorder.append($0) }, [])
            XCTAssertEqual(recorder.snapshot, [.init(phase: .completed, hits: [])])
        }
    }

    // MARK: - Fixtures

    /// Pauses the real repository only after a callback has been delivered, never under its DB
    /// lock. Thresholds tolerate an extra time-based publication without relying on test sleeps.
    private final class SearchPrefixGatedRepository: ConversationProgressiveHistoryProviding, @unchecked Sendable {
        private let repository: IndexedHistoryRepository
        private let thresholds: [Int]
        private let condition = NSCondition()
        private var releasedStep = 0
        private var reachedStep = 0
        private var reachedCount = 0
        private var timedOut = false

        init(repository: IndexedHistoryRepository, thresholds: [Int]) {
            self.repository = repository
            self.thresholds = thresholds
        }
        var blockedStep: Int { condition.lock(); defer { condition.unlock() }; return reachedStep }
        var blockedCount: Int { condition.lock(); defer { condition.unlock() }; return reachedCount }
        func release(through step: Int) {
            condition.lock()
            releasedStep = max(releasedStep, step)
            condition.broadcast()
            condition.unlock()
        }
        func listProjects(limit: Int) throws -> [HistoryProject] { try repository.listProjects(limit: limit) }
        func getSession(file: URL) throws -> HistorySession { try repository.getSession(file: file) }
        func search(query: String, limit: Int) throws -> [HistorySearchHit] {
            try repository.search(query: query, limit: limit)
        }
        func search(query: String, limit: Int,
                    onProgress: @Sendable (ConversationSearchProgress) -> Void) throws -> [HistorySearchHit] {
            let result = try repository.search(query: query, limit: limit) { event in
                onProgress(event)
                condition.lock()
                defer { condition.unlock() }
                guard reachedStep < thresholds.count, !timedOut,
                      event.phase != .completed, event.hits.count >= thresholds[reachedStep] else { return }
                reachedStep += 1
                reachedCount = event.hits.count
                let deadline = Date().addingTimeInterval(10)
                while releasedStep < reachedStep, condition.wait(until: deadline) {}
                timedOut = releasedStep < reachedStep
            }
            condition.lock()
            let failed = timedOut
            condition.unlock()
            if failed { throw GateError.timedOut }
            return result
        }
        private enum GateError: Error { case timedOut }
    }

    private func makeEqualActivityRepository(home: URL, count: Int, duplicateStableIDs: Bool = false) throws
        -> (IndexedHistoryRepository, [ConversationIndexedSession]) {
        let scope = home.appendingPathComponent("history")
        let database = try ConversationIndexDatabase(file: home.appendingPathComponent("index.sqlite3"))
        let activity = Date(timeIntervalSince1970: 1_800_000_000)
        var sessions: [ConversationIndexedSession] = []
        for index in 0..<count {
            var value = indexedCodex(scope: scope, id: String(format: "bulk-%03d", index),
                text: "deepcatalogneedle is present in the complete result set.")
            value.metadata.lastActivity = activity
            // Creation time is intentionally opposite to search's stable-ID tie-breaker.
            value.metadata.createdAt = activity.addingTimeInterval(Double(index))
            if duplicateStableIDs {
                value.metadata.id = "disk:shared-producer-id"
                value.metadata.source = .claude
            }
            sessions.append(value)
        }
        for value in sessions.reversed() { try database.replace(value) }
        let configuration = HistoryConfiguration(historyDirs: [scope.path], homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports"))
        return (IndexedHistoryRepository(configuration: configuration, database: database), sessions)
    }

    private final class SearchProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ConversationSearchProgress] = []
        private var didMutate = false
        func claimMutation() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didMutate else { return false }
            didMutate = true
            return true
        }
        var snapshot: [ConversationSearchProgress] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
        func append(_ event: ConversationSearchProgress) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }
    }

    private func makeProgressiveRepository(home: URL, count: Int) throws
        -> (IndexedHistoryRepository, ConversationIndexDatabase, [ConversationIndexedSession]) {
        let scope = home.appendingPathComponent("history")
        let database = try ConversationIndexDatabase(file: home.appendingPathComponent("index.sqlite3"))
        var sessions: [ConversationIndexedSession] = []
        for index in 0..<count {
            var value = indexedCodex(scope: scope, id: "progressive-\(index)",
                text: "Context " + String(repeating: "系统代理 ", count: index % 3 + 1), sequence: 100 + index)
            value.metadata.lastActivity = Date(timeIntervalSince1970: 1_800_000_000 - Double(index))
            sessions.append(value)
            try database.replace(value)
        }
        let configuration = HistoryConfiguration(historyDirs: [scope.path], homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports"))
        return (IndexedHistoryRepository(configuration: configuration, database: database), database, sessions)
    }

    private func indexedCodex(
        scope: URL,
        id: String,
        parent: String? = nil,
        text: String = "fixture contents",
        deleted: Bool = false,
        sequence: Int = 0
    ) -> ConversationIndexedSession {
        let metadata = HistorySessionMetadata(
            id: id, file: scope.appendingPathComponent("rollout-\(id).jsonl"), source: .codex,
            dirID: scope.path, dirLabel: scope.lastPathComponent, sessionID: id,
            threadID: id, parentThreadID: parent, canonicalThreadIDValid: true,
            cwd: "/fixture", project: "Fixture", title: id, autoTitle: id,
            deleted: deleted, createdAt: .now, lastActivity: .now, sizeBytes: UInt64(text.utf8.count),
            messageCount: sequence + 1
        )
        return ConversationIndexedSession(metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: UInt64(text.utf8.count)),
            documents: [.init(transcriptID: "main", sortOrder: 0, text: text, messageSpans: [
                .init(sequence: sequence, messageIndex: sequence, utf16Location: 0,
                    utf16Length: text.utf16.count, role: "assistant"),
            ])])
    }

    private func makeWarmRepository(
        configuration: HistoryConfiguration
    ) throws -> (IndexedHistoryRepository, ConversationIndexDatabase) {
        let database = try ConversationIndexDatabase(
            file: configuration.appDataRoot.appendingPathComponent(
                "parity-index-\(UUID().uuidString).sqlite3"
            )
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates(activeOnly: false)
        loader.prefetch(candidates)
        for candidate in candidates {
            let loaded = try loader.load(candidate)
            try database.replace(ConversationIndexedSession(
                projection: loaded.projection,
                fingerprint: ConversationIndexFingerprint(
                    modificationTime: loaded.session.metadata.lastActivity,
                    sizeBytes: loaded.session.metadata.sizeBytes,
                    dependencyFingerprint: loaded.dependencySnapshot.fingerprint
                )
            ))
        }
        return (
            IndexedHistoryRepository(
                configuration: configuration,
                database: database,
                loader: loader
            ),
            database
        )
    }

    private func assertLegacySearchFields(
        _ indexed: [HistorySearchHit],
        equalTo legacy: [HistorySearchHit],
        message: String = ""
    ) {
        XCTAssertEqual(indexed.count, legacy.count, message)
        for (actual, expected) in zip(indexed, legacy) {
            XCTAssertEqual(actual.sessionID, expected.sessionID, message)
            XCTAssertEqual(actual.file, expected.file, message)
            XCTAssertEqual(actual.source, expected.source, message)
            XCTAssertEqual(actual.agent, expected.agent, message)
            XCTAssertEqual(actual.agentType, expected.agentType, message)
            XCTAssertEqual(actual.snippet, expected.snippet, message)
            XCTAssertEqual(actual.count, expected.count, message)
        }
    }

    private func writeClaude(
        file: URL,
        sessionID: String,
        cwd: String,
        text: String,
        modifiedAt: Date
    ) throws {
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user", contentJSON: jsonString(text),
                sessionID: sessionID, cwd: cwd,
                timestamp: "2026-08-20T00:00:00Z"
            ),
        ], to: file, modifiedAt: modifiedAt)
    }

    private func writeCodex(
        file: URL,
        metadata: String,
        text: String,
        modifiedAt: Date
    ) throws {
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-20T00:00:00Z",
                type: "session_meta",
                payload: metadata
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-20T00:00:01Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":\#(jsonString(text))}]}"#
            ),
        ], to: file, modifiedAt: modifiedAt)
    }

    private func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #""""#
    }
}
