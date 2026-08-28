import SQLite3
import XCTest
@testable import CCBuddy

final class HistoryAdvancedTests: XCTestCase {
    func testSyntheticImportsRootRespectsActiveScope() throws {
        let home = try HistoryTestSupport.temporaryDirectory("imports-scope")
        defer { try? FileManager.default.removeItem(at: home) }
        let liveRoot = home.appendingPathComponent("live")
        let imports = home.appendingPathComponent("app-data/imports")
        let live = liveRoot.appendingPathComponent("projects/-live/live.jsonl")
        let imported = imports.appendingPathComponent("projects/-imported/imported.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user", contentJSON: #""live""#,
                sessionID: "live", cwd: "/live", timestamp: "2026-08-20T00:00:00Z"
            ),
        ], to: live)
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user", contentJSON: #""imported""#,
                sessionID: "imported", cwd: "/imported", timestamp: "2026-08-21T00:00:00Z"
            ),
        ], to: imported)

        let all = HistoryRepository(
            historyDirs: [liveRoot.path], homeDirectory: home, importsRoot: imports
        ).listSessions()
        XCTAssertEqual(Set(all.map(\.sessionID)), ["live", "imported"])
        XCTAssertEqual(all.first { $0.sessionID == "imported" }?.dirID, "__imported__")
        XCTAssertEqual(all.first { $0.sessionID == "imported" }?.imported, true)

        let onlyImports = HistoryRepository(
            historyDirs: [liveRoot.path], active: "__imported__",
            homeDirectory: home, importsRoot: imports
        ).listSessions()
        XCTAssertEqual(onlyImports.map(\.sessionID), ["imported"])

        let onlyLive = HistoryRepository(
            historyDirs: [liveRoot.path], active: liveRoot.path,
            homeDirectory: home, importsRoot: imports
        ).listSessions()
        XCTAssertEqual(onlyLive.map(\.sessionID), ["live"])
    }

    func testQoderSubagentsNormalizeAtomicWrappersAttributeSkillsAndSearch() throws {
        let home = try HistoryTestSupport.temporaryDirectory("qoder-subagents")
        let outside = try HistoryTestSupport.temporaryDirectory("qoder-subagents-outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let root = home.appendingPathComponent(".qoder")
        let sessionID = "11111111-1111-4111-8111-111111111111"
        let project = root.appendingPathComponent("projects/-tmp-subtree")
        let main = project.appendingPathComponent("\(sessionID).jsonl")
        try HistoryTestSupport.write([
            #"{"type":"ai-title","aiTitle":"Subagent tree"}"#,
            #"{"type":"user","message":{"role":"user","content":"main"},"sessionId":"11111111-1111-4111-8111-111111111111"}"#,
            #"{"type":"assistant","message":{"id":"main-a","role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Skill","input":{"skill":"authoritative-main"}}]},"sessionId":"11111111-1111-4111-8111-111111111111"}"#,
        ], to: main)
        let subagents = project.appendingPathComponent("\(sessionID)/subagents")
        let first = subagents.appendingPathComponent("agent-q1.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"user","message":{"role":"user","content":"Base directory for this skill: /skills/sentinel-main"},"sessionId":"s","agentId":"q1"}"#,
            #"{"type":"assistant","message":{"id":"sub-a","role":"assistant","content":[{"type":"text","text":"sub quetzal done"}]},"sessionId":"s","agentId":"q1"}"#,
            #"{"type":"assistant","message":{"id":"sub-a","role":"assistant","usage":{"input_tokens":4,"output_tokens":2},"content":[{"type":"tool_use","id":"agent:q2","name":"Skill","input":{"skill":"nested-authority"}}]},"sessionId":"s","agentId":"q1"}"#,
        ], to: first)
        try HistoryTestSupport.write([
            #"{"agentType":"explore","description":"first child","toolUseId":"tu1"}"#,
        ], to: subagents.appendingPathComponent("agent-q1.meta.json"))
        try HistoryTestSupport.write([
            #"{"type":"user","message":{"role":"user","content":"Base directory for this skill: C:\\skills\\sentinel-nested"},"sessionId":"s","agentId":"q2"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"nested child"}]},"sessionId":"s","agentId":"q2"}"#,
        ], to: subagents.appendingPathComponent("agent-q2.jsonl"))
        try HistoryTestSupport.write([#"{"toolUseId":"wrong"}"#], to: subagents.appendingPathComponent("almost-agent-q3.jsonl"))

        let outsideTranscript = outside.appendingPathComponent("agent-escape.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"assistant","message":{"role":"assistant","content":"must not load"}}"#,
        ], to: outsideTranscript)
        try FileManager.default.createSymbolicLink(
            at: subagents.appendingPathComponent("agent-escape.jsonl"),
            withDestinationURL: outsideTranscript
        )

        let repository = HistoryRepository(
            historyDirs: [root.path], homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports")
        )
        let session = try repository.getSession(file: main)
        XCTAssertEqual(session.metadata.subagentCount, 2)
        XCTAssertEqual(Set(session.subagents.keys), ["tu1", "agent:q2"])
        let q1 = try XCTUnwrap(session.subagents["tu1"])
        XCTAssertEqual(q1.type, "explore")
        XCTAssertEqual(q1.description, "first child")
        XCTAssertEqual(q1.skill, "authoritative-main")
        XCTAssertEqual(q1.messages.count, 2, "atomic assistant wrappers merge into one turn")
        XCTAssertEqual(q1.messages[1].content.map(\.type), ["text", "tool_use"])
        XCTAssertEqual(q1.totals.inputTokens, 4)
        XCTAssertEqual(session.subagents["agent:q2"]?.skill, "nested-authority")
        XCTAssertNil(session.subagents["agent:escape"])

        let hit = try XCTUnwrap(repository.search(query: "QUETZAL").first)
        XCTAssertEqual(hit.agent, "tu1")
        XCTAssertEqual(hit.agentType, "explore")
    }

    func testCodexCompletedStateDatabaseOverridesJSONLMtimeWhileWALIsLive() throws {
        let home = try HistoryTestSupport.temporaryDirectory("codex-state-wal")
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex")
        let threadID = "511a7eed-4f83-46ba-afff-4e08b18c12f5"
        let old = codexHome.appendingPathComponent("sessions/2026/08/20/rollout-old.jsonl")
        let newer = codexHome.appendingPathComponent("sessions/2026/08/21/rollout-new.jsonl")
        try writeCodex(threadID: threadID, text: "authoritative old", file: old,
                       modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try writeCodex(threadID: threadID, text: "newer duplicate", file: newer,
                       modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let sqliteHome = codexHome.appendingPathComponent("sqlite-state")
        try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
        try HistoryTestSupport.write([
            #"sqlite_home = "sqlite-state""#,
        ], to: codexHome.appendingPathComponent("config.toml"))
        let databaseFile = sqliteHome.appendingPathComponent("state_5.sqlite")
        let writer = try openStateDatabase(databaseFile, threadID: threadID, rollout: old)
        defer { sqlite3_close(writer) }

        let repository = HistoryRepository(
            historyDirs: [codexHome.path], homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports")
        )
        let rows = repository.listSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].file, old.standardizedFileURL)
        XCTAssertEqual(rows[0].title, "authoritative old")
    }

    func testCodexCorruptStateFallsBackToLiveThenMtimeAndArchivedValidationIsSafe() throws {
        let home = try HistoryTestSupport.temporaryDirectory("codex-state-fallback")
        let outside = try HistoryTestSupport.temporaryDirectory("codex-archive-outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let codexHome = home.appendingPathComponent(".codex")
        let threadID = "622b8fee-5f94-47cb-bfff-5f19c29d23f6"
        let live = codexHome.appendingPathComponent("sessions/2026/08/22/rollout-live.jsonl")
        let archived = codexHome.appendingPathComponent("archived_sessions/2026/08/23/rollout-archived.jsonl")
        try writeCodex(threadID: threadID, text: "live", file: live,
                       modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try writeCodex(threadID: threadID, text: "archived newer", file: archived,
                       modifiedAt: Date(timeIntervalSince1970: 1_900_000_000))
        try HistoryTestSupport.write(["not sqlite"], to: codexHome.appendingPathComponent("state_5.sqlite"))

        let repository = HistoryRepository(
            historyDirs: [codexHome.path], homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports")
        )
        XCTAssertEqual(repository.listSessions().map(\.file), [live.standardizedFileURL])
        XCTAssertNoThrow(try repository.getSession(file: archived))

        let outsideFile = outside.appendingPathComponent("escape.jsonl")
        try writeCodex(threadID: threadID, text: "escape", file: outsideFile,
                       modifiedAt: Date())
        let linkDirectory = codexHome.appendingPathComponent("archived_sessions/linked")
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: outside)
        XCTAssertThrowsError(try repository.getSession(
            file: linkDirectory.appendingPathComponent("escape.jsonl")
        ))
    }

    func testCodexLimitIncludesParentOfSelectedSubagent() throws {
        let home = try HistoryTestSupport.temporaryDirectory("codex-ancestor-limit")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex")
        let rootID = "733c9fff-6fa5-48dc-8aaa-6a20d30e34a7"
        let childID = "844da000-70b6-49ed-8bbb-7b31e41f45b8"
        let parent = root.appendingPathComponent("sessions/2026/08/20/rollout-parent.jsonl")
        let child = root.appendingPathComponent("sessions/2026/08/22/rollout-child.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-20T00:00:00Z", type: "session_meta",
                payload: #"{"id":"733c9fff-6fa5-48dc-8aaa-6a20d30e34a7","session_id":"733c9fff-6fa5-48dc-8aaa-6a20d30e34a7","cwd":"/tree"}"#
            ),
        ], to: parent, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00Z", type: "session_meta",
                payload: #"{"id":"844da000-70b6-49ed-8bbb-7b31e41f45b8","session_id":"733c9fff-6fa5-48dc-8aaa-6a20d30e34a7","parent_thread_id":"733c9fff-6fa5-48dc-8aaa-6a20d30e34a7","thread_source":"subagent","cwd":"/tree"}"#
            ),
        ], to: child, modifiedAt: Date(timeIntervalSince1970: 1_900_000_000))

        let rows = HistoryRepository(
            historyDirs: [root.path], homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports")
        ).listSessions(limit: 1)
        // The subagent rollout is folded into the session that spawned it, so the limit sees one
        // row rather than a child that then has to drag its parent in behind it.
        XCTAssertEqual(rows.map(\.threadID), [rootID])
        XCTAssertEqual(rows.first?.subagentRefs.map(\.threadID), [childID])
        XCTAssertEqual(rows.first?.subagentCount, 1)
    }

    func testCodexLiveMetadataUsesAppSidecarWhileImportedSnapshotUsesInlineMetadata() throws {
        let home = try HistoryTestSupport.temporaryDirectory("codex-sidecar-split")
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex")
        let appData = home.appendingPathComponent("custom-app-data")
        let imports = appData.appendingPathComponent("imports")
        let liveID = "955eb111-81c7-4afe-8ccc-8c42f52056c9"
        let importedID = "a66fc222-92d8-4b0f-8ddd-9d53063167da"
        let live = codexHome.appendingPathComponent(
            "sessions/2026/08/22/rollout-live-sidecar.jsonl"
        )
        let imported = imports.appendingPathComponent("projects/-state/\(importedID).jsonl")
        try writeCodex(
            threadID: liveID, text: "live auto", file: live,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            inlineTitle: "must be ignored"
        )
        try writeCodex(
            threadID: importedID, text: "imported auto", file: imported,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            inlineTitle: "Imported inline"
        )
        try HistoryTestSupport.write([
            #"{"rollout-live-sidecar":{"title":"Live sidecar","tagList":["codex"]},"a66fc222-92d8-4b0f-8ddd-9d53063167da":{"title":"wrong imported sidecar"}}"#,
        ], to: appData.appendingPathComponent("codex-meta.json"))

        let rows = HistoryRepository(
            historyDirs: [codexHome.path], homeDirectory: home, importsRoot: imports
        ).listSessions()
        let liveRow = try XCTUnwrap(rows.first { $0.threadID == liveID })
        let importedRow = try XCTUnwrap(rows.first { $0.threadID == importedID })
        XCTAssertEqual(liveRow.title, "Live sidecar")
        XCTAssertEqual(liveRow.tags, ["codex"])
        XCTAssertFalse(liveRow.imported)
        XCTAssertEqual(importedRow.title, "Imported inline")
        XCTAssertTrue(importedRow.imported)
    }

    func testCodexStateDatabaseRejectsSymlinkedSQLiteJournal() throws {
        let home = try HistoryTestSupport.temporaryDirectory("codex-state-sidecar-safety")
        let outside = try HistoryTestSupport.temporaryDirectory("codex-state-sidecar-outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let codexHome = home.appendingPathComponent(".codex")
        let threadID = "b770d333-a3e9-4c10-8eee-ae64174278eb"
        let rollout = codexHome.appendingPathComponent("sessions/rollout.jsonl")
        try writeCodex(
            threadID: threadID, text: "safe", file: rollout, modifiedAt: Date()
        )
        let databaseFile = codexHome.appendingPathComponent("state_5.sqlite")
        let writer = try openStateDatabase(databaseFile, threadID: threadID, rollout: rollout)
        sqlite3_close(writer)
        let outsideJournal = outside.appendingPathComponent("journal")
        try Data("outside".utf8).write(to: outsideJournal)
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: databaseFile.path + "-journal"),
            withDestinationURL: outsideJournal
        )

        XCTAssertNil(CodexStateDatabase.preferredRolloutPath(
            for: rollout,
            threadID: threadID,
            homeDirectory: home,
            environment: [:]
        ))
    }

    private func writeCodex(
        threadID: String,
        text: String,
        file: URL,
        modifiedAt: Date,
        inlineTitle: String? = nil
    ) throws {
        let metadata: HistoryValue = .object([
            "id": .string(threadID),
            "session_id": .string(threadID),
            "cwd": .string("/state"),
        ])
        let message: HistoryValue = .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string(text),
            ])]),
        ])
        var metadataRecord: [String: HistoryValue] = [
            "timestamp": .string("2026-08-20T00:00:00Z"),
            "type": .string("session_meta"),
            "payload": metadata,
        ]
        if let inlineTitle {
            metadataRecord["__ccbud__"] = .object(["title": .string(inlineTitle)])
        }
        try HistoryTestSupport.write([
            HistoryValue.object(metadataRecord).jsonString,
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-20T00:00:01Z",
                type: "response_item",
                payload: message.jsonString
            ),
        ], to: file, modifiedAt: modifiedAt)
    }

    private func openStateDatabase(
        _ file: URL,
        threadID: String,
        rollout: URL
    ) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLite", code: 1)
        }
        do {
            try execute(database, "PRAGMA journal_mode=WAL")
            try execute(database, "PRAGMA wal_autocheckpoint=0")
            try execute(database, "CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT NOT NULL)")
            try execute(database, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, archived INTEGER NOT NULL)")
            try execute(database, "INSERT INTO backfill_state (id, status) VALUES (1, 'complete')")
            var statement: OpaquePointer?
            let sql = "INSERT INTO threads (id, rollout_path, archived) VALUES (?1, ?2, 0)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw NSError(domain: "SQLite", code: 2) }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let first = threadID.withCString {
                sqlite3_bind_text(statement, 1, $0, -1, transient)
            }
            let second = rollout.path.withCString {
                sqlite3_bind_text(statement, 2, $0, -1, transient)
            }
            guard first == SQLITE_OK, second == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "SQLite", code: 3)
            }
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "SQLite", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? sql]
            )
        }
    }
}
