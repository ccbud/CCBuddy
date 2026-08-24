import XCTest
@testable import CCBuddy

final class CursorHistoryParserTests: XCTestCase {
    func testCursorPreservesWakeTurnsEmbeddedMetadataToolsAndSubagents() throws {
        let root = try HistoryTestSupport.temporaryDirectory("cursor-adapter")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspaces/team-alpha/qr-app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let slug = String(workspace.path.dropFirst()).replacingOccurrences(of: "/", with: "-")
        let sessionID = "33333333-aaaa-bbbb-cccc-000000000003"
        let sessionDirectory = home
            .appendingPathComponent(".cursor/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let transcript = sessionDirectory.appendingPathComponent("\(sessionID).jsonl")
        try HistoryTestSupport.write([
            #"{"role":"user","message":{"content":[{"type":"text","text":"<workspace>open tabs: src/QrScanner.tsx</workspace>"}]}}"#,
            #"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Saturday, Aug 01, 2026, 9:30 AM (UTC+8)</timestamp>\n<user_query>把二维码扫描组件抽出来,注意 useEffect() 的清理</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"先看现有组件结构,再抽公共 hook。"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"read_file","input":{"path":"src/QrScanner.tsx"}}]}}"#,
            #"{"type":"turn_ended"}"#,
            #"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Saturday, Aug 01, 2026, 9:40 AM (UTC+8)</timestamp>\n<user_query>好的,按这个方案继续</user_query>"}]}}"#,
            #"{"type":"session_started","meta":{"note":"unknown"}}"#,
            "not valid json",
        ], to: transcript)

        let subagent = sessionDirectory
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("researcher.jsonl")
        try HistoryTestSupport.write([
            #"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>检查扫码清理分支</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"子线程确认 cleanup 已覆盖。"}]}}"#,
        ], to: subagent)

        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: home.appendingPathComponent(".ccbud/imports", isDirectory: true)
        )
        let adapter = CursorConversationSourceAdapter()
        let candidate = try XCTUnwrap(
            adapter.discover(configuration: configuration, activeOnly: true).only
        )
        XCTAssertEqual(candidate.nativeID, sessionID)
        XCTAssertEqual(candidate.projectDirectoryName, slug)
        XCTAssertEqual(
            adapter.candidate(for: transcript, configuration: configuration)?.file,
            transcript.standardizedFileURL
        )
        XCTAssertEqual(adapter.watchRoots(configuration: configuration), [
            home.appendingPathComponent(".cursor/projects").standardizedFileURL,
        ])

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

        XCTAssertEqual(session.metadata.source, .cursor)
        XCTAssertEqual(session.metadata.id, "cursor:\(sessionID)")
        XCTAssertEqual(session.metadata.cwd, workspace.path)
        XCTAssertEqual(session.metadata.project, "qr-app")
        XCTAssertEqual(session.metadata.title, "把二维码扫描组件抽出来,注意 useEffect() 的清理")
        XCTAssertEqual(session.metadata.messageCount, 3)
        XCTAssertEqual(session.metadata.subagentCount, 1)
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 7, malformedLines: 2))
        XCTAssertEqual(
            session.metadata.createdAt,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-01T01:30:00.000Z"))
        )
        XCTAssertEqual(
            session.metadata.lastActivity,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-01T01:40:00.000Z"))
        )

        XCTAssertEqual(session.messages.map(\.role), ["user", "user", "assistant", "user"])
        XCTAssertTrue(session.messages[0].isMetadata)
        XCTAssertEqual(session.messages[1].content.first?.text, "把二维码扫描组件抽出来,注意 useEffect() 的清理")
        XCTAssertEqual(
            session.messages[1].timestampText,
            "Saturday, Aug 01, 2026, 9:30 AM (UTC+8)"
        )
        let assistant = session.messages[2]
        XCTAssertEqual(assistant.content.map(\.type), ["text", "tool_use"])
        XCTAssertEqual(assistant.content[0].text, "先看现有组件结构,再抽公共 hook。")
        XCTAssertEqual(assistant.content[1].id, "")
        XCTAssertEqual(assistant.content[1].name, "read_file")
        XCTAssertEqual(assistant.content[1].input?["path"]?.stringValue, "src/QrScanner.tsx")

        XCTAssertEqual(Set(session.subagents.keys), ["agent:researcher"])
        let child = try XCTUnwrap(session.subagents["agent:researcher"])
        XCTAssertEqual(child.agentID, "researcher")
        XCTAssertEqual(child.count, 2)
        XCTAssertEqual(child.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(child.messages[1].content.first?.text, "子线程确认 cleanup 已覆盖。")

        let dependencies = adapter.dependencies(for: candidate, configuration: configuration)
        XCTAssertEqual(Set(dependencies.map(\.role)), [
            .primaryTranscript,
            .subagentContainer,
            .subagentTranscript,
            .customMetadata,
        ])
        XCTAssertTrue(dependencies.contains {
            $0.file == subagent.standardizedFileURL && $0.role == .subagentTranscript
        })
        XCTAssertFalse(
            adapter.discover(configuration: configuration, activeOnly: true)
                .contains { $0.file == subagent.standardizedFileURL },
            "Cursor subagents are sidechains, not top-level sessions"
        )

        let mutations = ConversationMutationService(configuration: .init(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: configuration.importsRoot
        ))
        XCTAssertEqual(try mutations.suggestedRawFileExtension(for: session.metadata), "zip")
        let exported = root.appendingPathComponent("cursor-session.zip")
        let exportResult = try mutations.exportRaw(session.metadata, to: exported)
        XCTAssertTrue(exportResult.bundled)
        XCTAssertEqual(exportResult.fileExtension, "zip")
        let bytes = try Data(contentsOf: exported)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        let bundle = try ConversationArchive.splitBundle(ConversationArchive.read(bytes))
        XCTAssertEqual(bundle.main.name, transcript.lastPathComponent)
        XCTAssertEqual(bundle.subagents.map(\.name), ["researcher.jsonl"])
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
