import Foundation
import XCTest
@testable import CCBuddy

final class IndexedHistoryRepositoryParityTests: XCTestCase {
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

    // MARK: - Fixtures

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
