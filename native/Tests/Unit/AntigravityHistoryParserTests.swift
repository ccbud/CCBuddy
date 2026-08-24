import SQLite3
import XCTest
@testable import CCBuddy

final class AntigravityHistoryParserTests: XCTestCase {
    func testSQLiteProtobufFixtureNormalizesMessagesMetadataToolsAndUsage() throws {
        let root = try HistoryTestSupport.temporaryDirectory("antigravity")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversation = root.appendingPathComponent("conversations/agy-uuid-1.db")
        try createConversationDatabase(
            at: conversation,
            payloads: [
                userStep("agy needle capybara"),
                toolStep(),
                generationStep("已完成。"),
                Data([0xff, 0x00, 0x13, 0x37]),
            ]
        )
        try createSummaryDatabase(at: root.appendingPathComponent("conversation_summaries.db"))

        let repository = HistoryRepository(historyDirs: [root.path], homeDirectory: root)
        let rows = repository.listSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .antigravity)
        XCTAssertEqual(rows[0].id, "antigravity:agy-uuid-1")
        XCTAssertEqual(rows[0].title, "Agy 会话")
        XCTAssertEqual(rows[0].cwd, "/tmp/aproj")
        XCTAssertEqual(rows[0].project, "aproj")

        let session = try repository.getSession(file: conversation)
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant", "assistant"])
        XCTAssertEqual(session.messages[0].content[0].text, "agy needle capybara")
        XCTAssertEqual(session.messages[0].content[1].type, "image")
        XCTAssertEqual(session.messages[0].content[1].raw?["source"]?["data"]?.stringValue, "QUJD")
        XCTAssertEqual(session.messages[1].content[0].name, "Bash")
        XCTAssertEqual(session.messages[1].content[0].id, "call-9")
        XCTAssertEqual(session.messages[1].content[0].input?["command"]?.stringValue, "ls -la")
        XCTAssertEqual(session.messages[1].content[0].input?["description"]?.stringValue, "/tmp")
        XCTAssertEqual(session.messages[2].content[0].text, "已完成。")
        XCTAssertEqual(session.messages[2].usage, .init(inputTokens: 20_245, outputTokens: 346))
        XCTAssertEqual(
            session.metadata.totals,
            .init(inputTokens: 20_245, outputTokens: 346, turns: 1)
        )
        XCTAssertNotNil(session.messages.first?.timestamp)
        XCTAssertEqual(repository.search(query: "CAPYBARA").first?.source, .antigravity)
    }

    func testMalformedConversationDatabaseDegradesToEmptySession() throws {
        let root = try HistoryTestSupport.temporaryDirectory("antigravity-malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversations/broken.db")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a sqlite database".utf8).write(to: file)

        let repository = HistoryRepository(historyDirs: [root.path], homeDirectory: root)
        let session = try repository.getSession(file: file)
        XCTAssertEqual(session.metadata.source, .antigravity)
        XCTAssertEqual(session.metadata.sessionID, "broken")
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.metadata.totals, .init())
    }

    private func createConversationDatabase(at file: URL, payloads: [Data]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        try requireSQLite(sqlite3_open(file.path, &database), database: database)
        guard let database else { throw fixtureError("sqlite open returned no handle") }
        defer { sqlite3_close(database) }
        try execute(
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL DEFAULT 0, status INTEGER NOT NULL DEFAULT 0, step_payload BLOB)",
            database: database
        )
        for (index, payload) in payloads.enumerated() {
            var statement: OpaquePointer?
            let sql = "INSERT INTO steps (idx, step_type, status, step_payload) VALUES (?1, 0, 3, ?2)"
            try requireSQLite(sqlite3_prepare_v2(database, sql, -1, &statement, nil), database: database)
            guard let statement else { throw fixtureError("sqlite prepare returned no statement") }
            defer { sqlite3_finalize(statement) }
            try requireSQLite(sqlite3_bind_int64(statement, 1, Int64(index)), database: database)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bindResult = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
            }
            try requireSQLite(bindResult, database: database)
            try requireSQLite(sqlite3_step(statement), database: database, accepted: SQLITE_DONE)
        }
    }

    private func createSummaryDatabase(at file: URL) throws {
        var database: OpaquePointer?
        try requireSQLite(sqlite3_open(file.path, &database), database: database)
        guard let database else { throw fixtureError("sqlite open returned no handle") }
        defer { sqlite3_close(database) }
        try execute(
            "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', preview TEXT NOT NULL DEFAULT '', step_count INTEGER NOT NULL DEFAULT 0, last_modified_time DATETIME, workspace_uris TEXT NOT NULL DEFAULT '[]')",
            database: database
        )
        try execute(
            "INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, workspace_uris) VALUES ('agy-uuid-1', 'Agy 会话', 'preview', 4, '[\"file:///tmp/aproj\"]')",
            database: database
        )
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(errorMessage)
            throw fixtureError(detail)
        }
    }

    private func requireSQLite(
        _ result: Int32,
        database: OpaquePointer?,
        accepted: Int32 = SQLITE_OK
    ) throws {
        guard result == accepted else {
            let detail = database.flatMap(sqlite3_errmsg).map { String(cString: $0) }
                ?? "sqlite error \(result)"
            throw fixtureError(detail)
        }
    }

    private func fixtureError(_ detail: String) -> NSError {
        NSError(domain: "AntigravityHistoryParserTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: detail,
        ])
    }

    private func userStep(_ text: String) -> Data {
        var metadata: [UInt8] = []
        putBytes(field: 1, data: timestamp(seconds: 1_783_811_237), into: &metadata)
        var user: [UInt8] = []
        putString(field: 2, value: text, into: &user)
        var attachment: [UInt8] = []
        putString(field: 1, value: "image/png", into: &attachment)
        putBytes(field: 2, data: [65, 66, 67], into: &attachment)
        putString(field: 5, value: "/tmp/x.png", into: &attachment)
        putBytes(field: 9, data: attachment, into: &user)
        var step: [UInt8] = []
        putVarint(field: 1, value: 14, into: &step)
        putVarint(field: 4, value: 3, into: &step)
        putBytes(field: 5, data: metadata, into: &step)
        putBytes(field: 19, data: user, into: &step)
        return Data(step)
    }

    private func toolStep() -> Data {
        var call: [UInt8] = []
        putString(field: 1, value: "call-9", into: &call)
        putString(field: 2, value: "run_command", into: &call)
        putString(
            field: 3,
            value: #"{"CommandLine":"ls -la","Cwd":"/tmp","toolSummary":"Run"}"#,
            into: &call
        )
        var metadata: [UInt8] = []
        putBytes(field: 1, data: timestamp(seconds: 1_783_811_240), into: &metadata)
        putBytes(field: 4, data: call, into: &metadata)
        var step: [UInt8] = []
        putVarint(field: 1, value: 21, into: &step)
        putVarint(field: 4, value: 3, into: &step)
        putBytes(field: 5, data: metadata, into: &step)
        return Data(step)
    }

    private func generationStep(_ text: String) -> Data {
        var stats: [UInt8] = []
        putVarint(field: 1, value: 1_132, into: &stats)
        putVarint(field: 2, value: 20_245, into: &stats)
        putVarint(field: 3, value: 346, into: &stats)
        var metadata: [UInt8] = []
        putBytes(field: 1, data: timestamp(seconds: 1_783_811_242), into: &metadata)
        putBytes(field: 9, data: stats, into: &metadata)
        var turn: [UInt8] = []
        putString(field: 1, value: text, into: &turn)
        var step: [UInt8] = []
        putVarint(field: 1, value: 15, into: &step)
        putVarint(field: 4, value: 3, into: &step)
        putBytes(field: 5, data: metadata, into: &step)
        putBytes(field: 20, data: turn, into: &step)
        return Data(step)
    }

    private func timestamp(seconds: UInt64) -> [UInt8] {
        var value: [UInt8] = []
        putVarint(field: 1, value: seconds, into: &value)
        putVarint(field: 2, value: 500_000_000, into: &value)
        return value
    }

    private func putString(field: UInt32, value: String, into output: inout [UInt8]) {
        putBytes(field: field, data: Array(value.utf8), into: &output)
    }

    private func putBytes(field: UInt32, data: [UInt8], into output: inout [UInt8]) {
        encodeVarint(UInt64(field) << 3 | 2, into: &output)
        encodeVarint(UInt64(data.count), into: &output)
        output.append(contentsOf: data)
    }

    private func putVarint(field: UInt32, value: UInt64, into output: inout [UInt8]) {
        encodeVarint(UInt64(field) << 3, into: &output)
        encodeVarint(value, into: &output)
    }

    private func encodeVarint(_ source: UInt64, into output: inout [UInt8]) {
        var value = source
        while true {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            if value == 0 {
                output.append(byte)
                return
            }
            output.append(byte | 0x80)
        }
    }
}
