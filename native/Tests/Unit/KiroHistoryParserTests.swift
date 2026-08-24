import XCTest
@testable import CCBuddy

final class KiroHistoryParserTests: XCTestCase {
    func testKiroCombinesSidecarMetadataWithJSONLMessagesAndDiscovery() throws {
        let root = try HistoryTestSupport.temporaryDirectory("kiro-adapter")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessionID = "44444444-aaaa-bbbb-cccc-000000000004"
        let cli = home.appendingPathComponent(".kiro/sessions/cli", isDirectory: true)
        let transcript = cli.appendingPathComponent("\(sessionID).jsonl")
        try HistoryTestSupport.write([
            #"{"kind":"Prompt","data":{"content":[{"kind":"text","data":"<workspace>injected tabs</workspace>"}],"meta":{"timestamp":1785744200}}}"#,
            #"{"kind":"Prompt","data":{"content":[{"kind":"text","data":" 用 Kiro 重构二维码扫描 "},{"kind":"text","data":"注意 useEffect() 清理"}],"meta":{"timestamp":1785744300}}}"#,
            #"{"kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"已拆分扫描组件"},{"kind":"text","data":"并补上清理逻辑。"}],"meta":{"timestamp":1785744360}}}"#,
            #"{"kind":"ToolLog","data":{"note":"unknown kind"}}"#,
            "not valid json",
        ], to: transcript)
        let sidecar = cli.appendingPathComponent("\(sessionID).json")
        try HistoryTestSupport.write([
            #"{"session_id":"ignored-sidecar-id","cwd":"/Users/tester/Github/wakefx","title":"<system-reminder>hidden</system-reminder> Kiro QR session","created_at":"2026-08-03T08:00:00Z","updated_at":"2026-08-03T08:30:00Z","session_state":{"rts_model_state":{"model_info":{"model_id":" ","model_name":"claude-sonnet-4"}}}}"#,
        ], to: sidecar)
        let history = cli.appendingPathComponent("\(sessionID).history")
        try HistoryTestSupport.write(["ignored"], to: history)

        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: home.appendingPathComponent(".ccbud/imports", isDirectory: true)
        )
        let adapter = KiroConversationSourceAdapter()
        let candidate = try XCTUnwrap(
            adapter.discover(configuration: configuration, activeOnly: true).only
        )
        XCTAssertEqual(candidate.nativeID, sessionID)
        XCTAssertEqual(candidate.directory.id, "__wake_kiro__")
        XCTAssertEqual(adapter.watchRoots(configuration: configuration), [cli.standardizedFileURL])

        let document = try XCTUnwrap(try adapter.document(
            for: candidate,
            qoderReader: .shared
        ))
        let facts = try HistoryFileFacts.read(candidate.file, records: document.records)
        let session = try adapter.parse(ConversationSourceParseInput(
            candidate: candidate,
            document: document,
            facts: facts,
            configuration: configuration
        ))

        XCTAssertEqual(session.metadata.source, .kiro)
        XCTAssertEqual(session.metadata.id, "kiro:\(sessionID)")
        XCTAssertEqual(session.metadata.sessionID, sessionID)
        XCTAssertEqual(session.metadata.title, "Kiro QR session")
        XCTAssertEqual(session.metadata.cwd, "/Users/tester/Github/wakefx")
        XCTAssertEqual(session.metadata.project, "wakefx")
        XCTAssertEqual(session.metadata.model, "claude-sonnet-4")
        XCTAssertEqual(session.metadata.messageCount, 2)
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 4, malformedLines: 2))
        XCTAssertEqual(
            session.metadata.createdAt,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-03T08:00:00Z"))
        )
        XCTAssertEqual(
            session.metadata.lastActivity,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-03T08:30:00Z"))
        )

        XCTAssertEqual(session.messages.map(\.role), ["user", "user", "assistant"])
        XCTAssertTrue(session.messages[0].isMetadata)
        XCTAssertEqual(
            session.messages[1].content.first?.text,
            "用 Kiro 重构二维码扫描\n\n注意 useEffect() 清理"
        )
        XCTAssertEqual(
            try XCTUnwrap(session.messages[1].timestamp).timeIntervalSince1970,
            1_785_744_300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            session.messages[2].content.first?.text,
            "已拆分扫描组件\n\n并补上清理逻辑。"
        )
        XCTAssertEqual(
            try XCTUnwrap(session.messages[2].timestamp).timeIntervalSince1970,
            1_785_744_360,
            accuracy: 0.001
        )

        let dependencies = adapter.dependencies(for: candidate, configuration: configuration)
        XCTAssertEqual(Set(dependencies.map(\.role)), [
            .primaryTranscript,
            .providerMetadata,
            .customMetadata,
        ])
        XCTAssertTrue(dependencies.contains {
            $0.file == sidecar.standardizedFileURL && $0.role == .providerMetadata
        })
        XCTAssertFalse(dependencies.contains { $0.file == history.standardizedFileURL })
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
