import Foundation
import XCTest
@testable import CCBuddy

final class IndexedHistoryRepositoryParityTests: XCTestCase {
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
        let expected = try repository.search(query: "系统代理", limit: 9)
        let recorder = SearchProgressRecorder()
        let provider: any ConversationProgressiveHistoryProviding = repository
        let final = try provider.search(query: "系统代理", limit: 9) { recorder.append($0) }
        let events = recorder.snapshot
        XCTAssertEqual(final, expected)
        XCTAssertEqual(final.count, 9)
        XCTAssertEqual(events.first?.phase, .preparingCandidates)
        XCTAssertNil(events.first?.diagnostics)
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(events.last?.hits, final)
        let refined = events.filter { $0.phase == .refiningResults }
        XCTAssertEqual(refined.first?.hits, [])
        XCTAssertEqual(refined.first(where: { !$0.hits.isEmpty })?.hits, Array(expected.prefix(1)))
        var previousCount = 0
        for event in events.dropFirst() {
            XCTAssertEqual(event.hits, Array(expected.prefix(event.hits.count)))
            XCTAssertGreaterThanOrEqual(event.hits.count, previousCount)
            XCTAssertLessThanOrEqual(event.hits.count - previousCount, 8)
            XCTAssertNotNil(event.diagnostics)
            for hit in event.hits {
                XCTAssertGreaterThan(hit.count, 0)
                XCTAssertNotNil(hit.sequence)
                XCTAssertFalse(hit.snippet.isEmpty)
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
            if event.phase == .refiningResults, event.hits.count == 1 {
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

    private final class SearchProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ConversationSearchProgress] = []
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
