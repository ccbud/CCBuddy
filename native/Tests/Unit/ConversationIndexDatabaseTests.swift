import SQLite3
import XCTest
@testable import CCBuddy

final class ConversationIndexDatabaseTests: XCTestCase {
    func testMetadataDocumentsAndFingerprintRoundTripAcrossReopen() throws {
        let fixture = try Fixture()
        let metadata = makeMetadata(file: fixture.source, id: "qoder-full", source: .qoder)
        let fingerprint = ConversationIndexFingerprint(
            modificationTime: Date(timeIntervalSince1970: 1_800_000_111.25),
            sizeBytes: 4_096,
            dependencyFingerprint: "sha256:dependencies"
        )
        let document = makeDocument(
            transcriptID: "tool-child",
            type: "Explore",
            order: 1,
            text: "请实现二维码搜索"
        )

        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        XCTAssertEqual(try database?.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: fingerprint,
            documents: [document]
        )), 1)
        XCTAssertEqual(try database?.loadAllMetadata(), [metadata])
        XCTAssertEqual(try database?.documents(for: fixture.source), [document])
        XCTAssertEqual(
            try database?.storedFingerprints(),
            [ConversationIndexDatabase.normalizedPath(fixture.source): fingerprint]
        )
        database = nil

        let reopened = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertEqual(try reopened.loadAllMetadata(), [metadata])
        XCTAssertEqual(try reopened.documents(for: fixture.source), [document])
        XCTAssertEqual(try reopened.generation(), 1)
        XCTAssertTrue(try reopened.hasRows())

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.database.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testTrigramAndShortQueryFallbackReturnMainAndSubagentCandidates() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        let main = makeDocument(
            transcriptID: "main",
            type: nil,
            order: 0,
            text: "请实现二维码搜索，并保留 useEffect( 代码。"
        )
        let child = makeDocument(
            transcriptID: "agent-1",
            type: "Explore",
            order: 1,
            text: "子代理也找到了二维码。"
        )
        _ = try database.replace(ConversationIndexedSession(
            metadata: makeMetadata(file: fixture.source, id: "search"),
            fingerprint: .init(modificationTime: .now, sizeBytes: 100),
            documents: [child, main]
        ))

        let chinese = try database.candidateDocuments(for: "二维码")
        XCTAssertFalse(chinese.usedFallback)
        XCTAssertEqual(chinese.documents.map(\.document.transcriptID), ["main", "agent-1"])
        XCTAssertEqual(chinese.documents.last?.document.messageSpans.first?.messageIndex, 0)

        let code = try database.candidateDocuments(for: "useEffect(")
        XCTAssertFalse(code.usedFallback)
        XCTAssertEqual(code.documents.map(\.document.transcriptID), ["main"])

        let short = try database.candidateDocuments(for: "实现")
        XCTAssertTrue(short.usedFallback)
        XCTAssertEqual(short.documents.map(\.document.transcriptID), ["main"])
    }

    func testReplacementIsAtomicAndRemovesStaleSearchRows() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        let metadata = makeMetadata(file: fixture.source, id: "replace")
        _ = try database.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: 1),
            documents: [makeDocument(text: "obsolete phrase")]
        ))

        let invalid = ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: 2),
            documents: [makeDocument(text: "new phrase"), makeDocument(text: "duplicate")]
        )
        XCTAssertThrowsError(try database.replace(invalid))
        XCTAssertEqual(try database.candidateDocuments(for: "obsolete").documents.count, 1)
        XCTAssertEqual(try database.generation(), 1)

        _ = try database.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: 3),
            documents: [makeDocument(text: "replacement phrase")]
        ))
        XCTAssertTrue(try database.candidateDocuments(for: "obsolete").documents.isEmpty)
        XCTAssertEqual(try database.candidateDocuments(for: "replacement").documents.count, 1)
        XCTAssertEqual(try database.generation(), 2)
    }

    func testReconciliationIsScopedAndRejectsAccidentalEmptyDiscovery() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        let first = fixture.directory.appendingPathComponent("first.jsonl")
        let second = fixture.directory.appendingPathComponent("second.jsonl")
        _ = try database.replace(indexed(file: first, id: "first", scope: "one"))
        _ = try database.replace(indexed(file: second, id: "second", scope: "two"))

        XCTAssertThrowsError(try database.reconcile(scope: "one", seenPaths: [])) { error in
            guard case ConversationIndexDatabaseError.unsafeEmptyReconciliation("one") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let result = try database.reconcile(scope: "one", seenPaths: [], allowEmpty: true)
        XCTAssertEqual(result.removedPaths, [ConversationIndexDatabase.normalizedPath(first)])
        XCTAssertEqual(try database.loadAllMetadata().map(\.id), ["disk:second"])
        XCTAssertEqual(try database.scopeSummaries().map(\.scope), ["two"])
    }

    func testSchemaVersionMismatchRebuildsDerivedRows() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "old", scope: "scope"))
        database = nil

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let rebuilt = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertFalse(try rebuilt.hasRows())
        XCTAssertEqual(try rebuilt.generation(), 0)
    }

    private func indexed(file: URL, id: String, scope: String) -> ConversationIndexedSession {
        ConversationIndexedSession(
            metadata: makeMetadata(file: file, id: id),
            scope: scope,
            fingerprint: .init(modificationTime: .now, sizeBytes: 10),
            documents: [makeDocument(text: id)]
        )
    }

    private func makeDocument(
        transcriptID: String = "main",
        type: String? = nil,
        order: Int = 0,
        text: String
    ) -> ConversationIndexDocument {
        ConversationIndexDocument(
            transcriptID: transcriptID,
            agentType: type,
            sortOrder: order,
            text: text,
            messageSpans: [.init(
                sequence: 0,
                messageIndex: 0,
                utf16Location: 0,
                utf16Length: text.utf16.count,
                role: "user",
                timestamp: Date(timeIntervalSince1970: 1_800_000_001)
            )]
        )
    }

    private func makeMetadata(
        file: URL,
        id: String,
        source: HistorySource = .claude
    ) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "\(source.rawValue):\(id)",
            file: file,
            source: source,
            dirID: "scope",
            dirLabel: "Scope",
            sessionID: id,
            threadID: "thread-\(id)",
            rootSessionID: "root-\(id)",
            parentThreadID: "parent",
            forkedFromID: "fork",
            canonicalThreadIDValid: true,
            cwd: "/tmp/Project",
            project: "Project",
            gitBranch: "main",
            version: "1.2.3",
            title: "Full metadata",
            autoTitle: "Automatic",
            tags: ["one", "二"],
            summary: .object(["nested": .array([.number(2), .bool(true)])]),
            model: "model",
            isSubagent: true,
            skill: "review",
            agentPath: "/tmp/agent.jsonl",
            agentNickname: "Scout",
            agentRole: "explorer",
            agentDepth: 2,
            subagentCount: 3,
            imported: true,
            deleted: false,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100.75),
            sizeBytes: 9_999,
            totals: HistoryTotals(
                inputTokens: 10,
                outputTokens: 20,
                cacheRead: 30,
                cacheCreation: 40,
                turns: 2,
                credits: 1.25,
                tokenUsageAvailable: true
            ),
            messageCount: 4,
            diagnostics: .init(decodedLines: 11, malformedLines: 2)
        )
    }
}

private final class Fixture {
    let directory: URL
    let database: URL
    let source: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-conversation-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("catalog.sqlite")
        source = directory.appendingPathComponent("session.jsonl")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
