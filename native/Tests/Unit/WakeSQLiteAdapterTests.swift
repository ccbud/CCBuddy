import SQLite3
import XCTest
@testable import CCBuddy

final class WakeSQLiteAdapterTests: XCTestCase {
    func testCanonicalSQLiteFileSymlinkCannotEscapeHome() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-sqlite-file-home")
        let outside = try HistoryTestSupport.temporaryDirectory("wake-sqlite-file-outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let externalDatabase = outside.appendingPathComponent("session-store.db")
        try createDatabase(at: externalDatabase, statements: [
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, cwd TEXT, branch TEXT, summary TEXT,
                created_at TEXT, updated_at TEXT
            )
            """,
            """
            CREATE TABLE turns (
                id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER,
                user_message TEXT, assistant_response TEXT, timestamp TEXT
            )
            """,
            """
            INSERT INTO sessions VALUES (
                'outside-file', '/outside', NULL, 'outside file secret',
                '2026-08-24T00:00:00Z', '2026-08-24T00:00:01Z'
            )
            """,
            """
            INSERT INTO turns VALUES (
                1, 'outside-file', 0, 'outside file secret', 'must not load',
                '2026-08-24T00:00:01Z'
            )
            """,
        ])
        let copilotRoot = home.appendingPathComponent(".copilot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: copilotRoot,
            withIntermediateDirectories: true
        )
        let logicalDatabase = copilotRoot.appendingPathComponent("session-store.db")
        try FileManager.default.createSymbolicLink(
            at: logicalDatabase,
            withDestinationURL: externalDatabase
        )

        let loader = HistorySessionLoader(historyDirs: [], homeDirectory: home)
        XCTAssertFalse(loader.discoverCandidates(activeOnly: false).contains {
            $0.formatHint == .copilot
        })
        let logicalSession = WakeHistoryAdapterSupport.virtualSessionURL(
            database: logicalDatabase,
            nativeID: "outside-file"
        )
        XCTAssertThrowsError(try loader.getSession(file: logicalSession))
    }

    func testCanonicalSQLiteAncestorSymlinkCannotEscapeHome() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-sqlite-path-home")
        let outside = try HistoryTestSupport.temporaryDirectory("wake-sqlite-path-outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let externalRoot = outside.appendingPathComponent(".copilot", isDirectory: true)
        let externalDatabase = externalRoot.appendingPathComponent("session-store.db")
        try createDatabase(at: externalDatabase, statements: [
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, cwd TEXT, branch TEXT, summary TEXT,
                created_at TEXT, updated_at TEXT
            )
            """,
            """
            CREATE TABLE turns (
                id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER,
                user_message TEXT, assistant_response TEXT, timestamp TEXT
            )
            """,
            """
            INSERT INTO sessions VALUES (
                'outside', '/outside', NULL, 'outside secret',
                '2026-08-24T00:00:00Z', '2026-08-24T00:00:01Z'
            )
            """,
            """
            INSERT INTO turns VALUES (
                1, 'outside', 0, 'outside secret', 'must not load',
                '2026-08-24T00:00:01Z'
            )
            """,
        ])
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".copilot"),
            withDestinationURL: externalRoot
        )

        let loader = HistorySessionLoader(historyDirs: [], homeDirectory: home)
        XCTAssertFalse(loader.discoverCandidates(activeOnly: false).contains {
            $0.formatHint == .copilot
        })
        let logicalDatabase = home.appendingPathComponent(".copilot/session-store.db")
        let logicalSession = WakeHistoryAdapterSupport.virtualSessionURL(
            database: logicalDatabase,
            nativeID: "outside"
        )
        XCTAssertThrowsError(try loader.getSession(file: logicalSession))
    }

    func testCanonicalCopilotDiscoveryParsingMutationAndRawExport() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-copilot")
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(".copilot/session-store.db")
        try createDatabase(at: database, statements: [
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, cwd TEXT, branch TEXT, summary TEXT,
                created_at TEXT, updated_at TEXT
            )
            """,
            """
            CREATE TABLE turns (
                id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER,
                user_message TEXT, assistant_response TEXT, timestamp TEXT
            )
            """,
            """
            INSERT INTO sessions VALUES (
                'cp-1', '/tmp/copilot project', 'feature/wake', 'Copilot SQLite',
                '2026-07-12T07:26:05.662Z', '2026-07-12T07:27:15.632Z'
            )
            """,
            """
            INSERT INTO sessions VALUES (
                'empty', '/tmp/empty', NULL, '',
                '2026-07-12 07:26:05', '2026-07-12 07:26:05'
            )
            """,
            """
            INSERT INTO turns VALUES (
                1, 'cp-1', 0, 'copilot sqlite narwhal', 'canonical response',
                '2026-07-12T07:27:15.000Z'
            )
            """,
        ])

        let imports = home.appendingPathComponent(".ccbud/imports", isDirectory: true)
        let loader = HistorySessionLoader(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports
        )
        let candidates = loader.discoverCandidates().filter { $0.formatHint == .copilot }
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1, "Copilot rows without turns must stay hidden")
        XCTAssertEqual(candidate.nativeID, "cp-1")
        XCTAssertEqual(candidate.backingFile, database)
        XCTAssertNotEqual(candidate.file, database)

        let loaded = try loader.load(candidate, consistency: .bestEffort)
        XCTAssertEqual(loaded.session.metadata.id, "copilot:cp-1")
        XCTAssertEqual(loaded.session.metadata.title, "Copilot SQLite")
        XCTAssertEqual(loaded.session.metadata.cwd, "/tmp/copilot project")
        XCTAssertEqual(loaded.session.metadata.gitBranch, "feature/wake")
        XCTAssertEqual(loaded.session.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(loaded.session.messages.first?.content.first?.text, "copilot sqlite narwhal")
        XCTAssertEqual(loaded.session.metadata.sizeBytes, 40)

        let metadataDatabase = try ConversationIndexDatabase(
            file: home.appendingPathComponent(".ccbud/conversation-index-v1.sqlite3")
        )
        let mutations = ConversationMutationService(
            configuration: .init(
                historyDirs: [],
                homeDirectory: home,
                importsRoot: imports
            ),
            metadataDatabase: metadataDatabase
        )
        try mutations.updateMetadata(
            for: loaded.session.metadata,
            patch: .init(title: "Pinned DB row", starred: true, pinned: true)
        )
        let logicalMetadata = try metadataDatabase.userMetadata(for: candidate.file)
        XCTAssertEqual(logicalMetadata.title, "Pinned DB row")
        XCTAssertTrue(logicalMetadata.starred)
        XCTAssertTrue(logicalMetadata.pinned)
        XCTAssertEqual(try metadataDatabase.userMetadata(for: database), .init())
        XCTAssertEqual(
            try mutations.suggestedRawFileExtension(for: loaded.session.metadata),
            "db"
        )

        var liveDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &liveDatabase), SQLITE_OK)
        guard let liveDatabase else { throw fixtureError("sqlite WAL open returned no handle") }
        defer { sqlite3_close(liveDatabase) }
        try execute("PRAGMA journal_mode=WAL", database: liveDatabase)
        try execute("PRAGMA wal_autocheckpoint=0", database: liveDatabase)
        try execute("CREATE TABLE export_probe (value TEXT)", database: liveDatabase)
        try execute("PRAGMA wal_checkpoint(TRUNCATE)", database: liveDatabase)
        try execute("INSERT INTO export_probe VALUES ('committed-in-wal')", database: liveDatabase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path + "-wal"))
        do {
            let liveSnapshot = try XCTUnwrap(HistorySQLiteDatabase(database))
            XCTAssertTrue(liveSnapshot.tableExists("export_probe"))
            XCTAssertEqual(
                liveSnapshot.textValue("SELECT value FROM export_probe"),
                "committed-in-wal"
            )
        }

        let exported = home.appendingPathComponent("copilot-export.db")
        let exportResult = try mutations.exportRaw(loaded.session.metadata, to: exported)
        XCTAssertEqual(exportResult.fileExtension, "db")
        XCTAssertFalse(exportResult.bundled)
        let snapshot = try XCTUnwrap(HistorySQLiteDatabase(exported))
        XCTAssertTrue(snapshot.tableExists("sessions"))
        XCTAssertTrue(snapshot.tableExists("turns"))
        XCTAssertTrue(snapshot.tableExists("export_probe"))
        XCTAssertEqual(snapshot.textValue("SELECT COUNT(*) FROM export_probe"), "1")
        XCTAssertEqual(snapshot.textValue("SELECT value FROM export_probe"), "committed-in-wal")
    }

    func testCanonicalAntigravityDiscoversOnlyRootsAndBuildsEncryptedSummaryDetail() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-antigravity")
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(
            ".gemini/antigravity-cli/conversation_summaries.db"
        )
        try createDatabase(at: database, statements: [
            """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                preview TEXT NOT NULL DEFAULT '', step_count INTEGER NOT NULL DEFAULT 0,
                last_modified_time TEXT NOT NULL, workspace_uris TEXT NOT NULL DEFAULT '[]',
                parent_conversation_id TEXT NOT NULL DEFAULT '',
                nesting_depth INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            INSERT INTO conversation_summaries VALUES (
                'agy-root', '', 'Encrypted summary phoenix', 17,
                '2026-07-05 01:55:34.606032+00:00',
                '[\"file:///tmp/Antigravity%20Project\"]', '', 0
            )
            """,
            """
            INSERT INTO conversation_summaries VALUES (
                'agy-child', 'Child', 'must stay hidden', 2,
                '2026-07-05 01:56:00+00:00', '[]', 'agy-root', 1
            )
            """,
        ])

        let loader = HistorySessionLoader(historyDirs: [], homeDirectory: home)
        let candidates = loader.discoverCandidates().filter { $0.formatHint == .antigravity }
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.nativeID, "agy-root")
        XCTAssertEqual(candidate.backingFile, database)

        let session = try loader.load(candidate, consistency: .bestEffort).session
        XCTAssertEqual(session.metadata.id, "antigravity:agy-root")
        XCTAssertEqual(session.metadata.title, "Encrypted summary phoenix")
        XCTAssertEqual(session.metadata.cwd, "/tmp/Antigravity Project")
        XCTAssertEqual(session.metadata.project, "Antigravity Project")
        XCTAssertEqual(session.metadata.messageCount, 17)
        XCTAssertNotNil(session.metadata.createdAt)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].role, "system")
        XCTAssertTrue(session.messages[0].isMetadata)
        XCTAssertTrue(session.messages[0].content[0].text?.contains("content encrypted") == true)
        XCTAssertTrue(session.messages[0].content[0].text?.contains("Encrypted summary phoenix") == true)
    }

    private func createDatabase(at file: URL, statements: [String]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        guard let database else { throw fixtureError("sqlite open returned no handle") }
        defer { sqlite3_close(database) }
        for statement in statements { try execute(statement, database: database) }
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(errorMessage)
            throw fixtureError(detail)
        }
    }

    private func fixtureError(_ detail: String) -> NSError {
        NSError(domain: "WakeSQLiteAdapterTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: detail,
        ])
    }
}
