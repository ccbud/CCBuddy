import XCTest
@testable import CCBuddy

final class ForeignHistoryParserTests: XCTestCase {
    func testQoderAtomicWrappersQueuedCommandMetadataAndUsage() throws {
        let home = try HistoryTestSupport.temporaryDirectory("qoder-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".qoder", isDirectory: true)
        let uuid = "11111111-1111-4111-8111-111111111111"
        let file = root.appendingPathComponent("projects/-tmp-qproj/\(uuid).jsonl")
        try HistoryTestSupport.write([
            #"{"type":"agent-setting","agentSetting":"triage","sessionId":"\#(uuid)"}"#,
            #"{"type":"last-prompt","sessionId":"\#(uuid)","lastPrompt":"fallback"}"#,
            #"{"type":"ai-title","sessionId":"\#(uuid)","aiTitle":"Qoder 会话"}"#,
            #"{"type":"workspace-directories","sessionId":"\#(uuid)","directories":["/tmp/qproj"]}"#,
            #"{"type":"runtime-config","sessionId":"\#(uuid)","model":"ultimate"}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-04T09:47:27.966Z","message":{"role":"user","content":"qoder needle axolotl"},"sessionId":"\#(uuid)","version":"1.1.13"}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-06-04T09:47:32.116Z","message":{"id":"msg_1","role":"assistant","model":"wire-model","content":[{"type":"redacted_thinking","data":"opaque"}]},"sessionId":"\#(uuid)"}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-06-04T09:47:32.216Z","message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"considering"}]},"sessionId":"\#(uuid)"}"#,
            #"{"type":"assistant","uuid":"a3","timestamp":"2026-06-04T09:47:32.316Z","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"done"}]},"sessionId":"\#(uuid)"}"#,
            #"{"type":"assistant","uuid":"a4","timestamp":"2026-06-04T09:47:32.416Z","message":{"id":"msg_1","role":"assistant","stop_reason":"end_turn","usage":{"input_tokens":100,"cache_creation_input_tokens":7,"cache_read_input_tokens":50,"output_tokens":30,"credits":1.25,"original_credits":2.5,"context_usage_ratio":0.4},"content":[{"type":"tool_use","id":"tu1","name":"Task","input":{}}]},"sessionId":"\#(uuid)"}"#,
            #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"queued narwhal follow-up"},"timestamp":"2026-06-04T09:47:35.000Z","sessionId":"\#(uuid)"}"#,
            "not valid json",
        ], to: file)
        try HistoryTestSupport.write([
            #"{"qoder:\#(uuid)":{"title":"Custom Qoder","tagList":["foreign","qoder"],"delete":false}}"#,
        ], to: home.appendingPathComponent(".ccbud/agent-meta.json"))

        let repository = HistoryRepository(historyDirs: [root.path], homeDirectory: home)
        let rows = repository.listSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .qoder)
        XCTAssertEqual(rows[0].id, "qoder:\(uuid)")
        XCTAssertEqual(rows[0].title, "Custom Qoder")
        XCTAssertEqual(rows[0].autoTitle, "Qoder 会话")
        XCTAssertEqual(rows[0].tags, ["foreign", "qoder"])
        XCTAssertEqual(rows[0].cwd, "/tmp/qproj")
        XCTAssertEqual(rows[0].model, "ultimate")

        let session = try repository.getSession(file: file)
        XCTAssertEqual(session.metadata.version, "1.1.13")
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 11, malformedLines: 1))
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(session.messages[1].content.map(\.type), ["thinking", "text", "tool_use"])
        XCTAssertFalse(session.messages[1].content.contains { $0.type == "redacted_thinking" })
        XCTAssertEqual(session.messages[1].usage?.inputTokens, 100)
        XCTAssertEqual(session.messages[1].usage?.credits, 1.25)
        XCTAssertEqual(session.messages[1].usage?.originalCredits, 2.5)
        XCTAssertEqual(session.messages[1].usage?.contextUsageRatio, 0.4)
        XCTAssertEqual(session.messages[1].stopReason, "end_turn")
        XCTAssertEqual(session.metadata.totals.credits, 1.25)
        XCTAssertEqual(session.metadata.totals.tokenUsageAvailable, true)
        XCTAssertEqual(session.messages[2].content.first?.text, "queued narwhal follow-up")
        XCTAssertEqual(repository.search(query: "narwhal").first?.source, .qoder)
    }

    func testGrokAndCopilotContainerRoutingNormalizationAndSearch() throws {
        let root = try HistoryTestSupport.temporaryDirectory("foreign-jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        let grokDirectory = root.appendingPathComponent("sessions/%2Ftmp%2Fgproj/0199-grok-uuid")
        let grok = grokDirectory.appendingPathComponent("chat_history.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"system","content":"harness"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_info>hidden</user_info>"}]}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_query>grok needle walrus</user_query>"},{"type":"image","url":"data:image/png;base64,QUJD"}]}"#,
            #"{"type":"reasoning","summary":[{"type":"summary_text","text":"Inspecting"}]}"#,
            #"{"type":"assistant","content":"working","tool_calls":[{"id":"g1","name":"run_terminal_command","arguments":"{\"command\":\"ls\",\"description\":\"List\"}"},{"id":"g2","name":"read_file","arguments":{"target_file":"Sources/A.swift","offset":4}}]}"#,
            #"{"type":"tool_result","tool_call_id":"g1","content":"ok"}"#,
            #"{"type":"tool_result","tool_call_id":"g2","content":"image result","images":[{"url":"data:image/png;base64,REVG"}]}"#,
            "{malformed",
        ], to: grok)
        try HistoryTestSupport.write([
            #"{"info":{"id":"0199-grok-uuid","cwd":"/tmp/gproj"},"generated_title":"Grok 会话","created_at":"2026-06-18T06:27:07.777Z","last_active_at":"2026-06-18T06:57:37.242Z","current_model_id":"grok-build","head_branch":"main"}"#,
        ], to: grokDirectory.appendingPathComponent("summary.json"))
        try HistoryTestSupport.write([
            #"{"type":"mcp_config_resolved","content":"must not become a session"}"#,
        ], to: grokDirectory.appendingPathComponent("events.jsonl"))

        let copilotDirectory = root.appendingPathComponent("session-state/cp-uuid-1")
        let copilot = copilotDirectory.appendingPathComponent("events.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session.start","data":{"sessionId":"cp-uuid-1","copilotVersion":"1.0.70","context":{"cwd":"/fallback","branch":"fallback"}},"timestamp":"2026-07-12T07:26:54.363Z"}"#,
            #"{"type":"session.model_change","data":{"newModel":"gpt-5.6"},"timestamp":"2026-07-12T07:27:00.000Z"}"#,
            #"{"type":"system.message","data":{"content":"harness"},"timestamp":"2026-07-12T07:27:01.000Z"}"#,
            #"{"type":"user.message","data":{"content":"copilot needle pelican"},"timestamp":"2026-07-12T07:27:14.000Z"}"#,
            #"{"type":"assistant.message","data":{"model":"gpt-5.6","content":"searching","toolRequests":[{"toolCallId":"c1","name":"rg","arguments":{"pattern":"needle","paths":["Sources","Tests"],"glob":"*.swift"}},{"toolCallId":"c2","name":"apply_patch","arguments":{"str":"*** patch"}}]},"timestamp":"2026-07-12T07:27:15.000Z"}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":false,"result":{"content":"boom"}},"timestamp":"2026-07-12T07:27:16.000Z"}"#,
        ], to: copilot)
        try HistoryTestSupport.write([
            "id: cp-uuid-1",
            "cwd: /tmp/cproj",
            "name: Copilot 会话",
            "branch: feature/native",
            "created_at: 2026-07-12T07:26:54.368Z",
        ], to: copilotDirectory.appendingPathComponent("workspace.yaml"))

        let repository = HistoryRepository(historyDirs: [root.path], homeDirectory: root)
        let rows = repository.listSessions()
        XCTAssertEqual(rows.count, 2, "Grok sidecar event JSONL must not be swept as Codex")
        let grokRow = try XCTUnwrap(rows.first { $0.source == .grok })
        let copilotRow = try XCTUnwrap(rows.first { $0.source == .copilot })
        XCTAssertEqual(grokRow.sessionID, "0199-grok-uuid")
        XCTAssertEqual(grokRow.cwd, "/tmp/gproj")
        XCTAssertEqual(grokRow.title, "Grok 会话")
        XCTAssertEqual(grokRow.model, "grok-build")
        XCTAssertEqual(grokRow.gitBranch, "main")
        XCTAssertEqual(copilotRow.cwd, "/tmp/cproj")
        XCTAssertEqual(copilotRow.title, "Copilot 会话")
        XCTAssertEqual(copilotRow.gitBranch, "feature/native")

        let grokSession = try repository.getSession(file: grok)
        XCTAssertEqual(grokSession.metadata.diagnostics, .init(decodedLines: 7, malformedLines: 1))
        XCTAssertEqual(grokSession.messages.count, 5)
        XCTAssertEqual(grokSession.messages[0].content.map(\.type), ["text", "image"])
        XCTAssertEqual(grokSession.messages[0].content[0].text, "grok needle walrus")
        XCTAssertEqual(grokSession.messages[1].content[0].type, "thinking")
        XCTAssertEqual(grokSession.messages[2].content[1].name, "Bash")
        XCTAssertEqual(grokSession.messages[2].content[1].input?["command"]?.stringValue, "ls")
        XCTAssertEqual(grokSession.messages[2].content[2].name, "Read")
        XCTAssertEqual(grokSession.messages[2].content[2].input?["offset"]?.integerValue, 4)
        XCTAssertEqual(grokSession.messages[4].content[0].content?.arrayValue?[1]["type"]?.stringValue, "image")

        let copilotSession = try repository.getSession(file: copilot)
        XCTAssertEqual(copilotSession.metadata.version, "1.0.70")
        XCTAssertEqual(copilotSession.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(copilotSession.messages[1].content[1].name, "Grep")
        XCTAssertEqual(copilotSession.messages[1].content[1].input?["path"]?.stringValue, "Sources Tests")
        XCTAssertEqual(copilotSession.messages[1].content[2].name, "ApplyPatch")
        XCTAssertEqual(copilotSession.messages[2].content[0].isError, true)
        XCTAssertEqual(repository.search(query: "WALRUS").first?.source, .grok)
        XCTAssertEqual(repository.search(query: "pelican").first?.source, .copilot)
    }

    func testForeignDiscoveryRejectsNestedSymlinkEscapes() throws {
        let root = try HistoryTestSupport.temporaryDirectory("foreign-safety")
        let outside = try HistoryTestSupport.temporaryDirectory("foreign-safety-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideGrokDirectory = outside.appendingPathComponent("grok-session")
        let outsideGrok = outsideGrokDirectory.appendingPathComponent("chat_history.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"user","content":"outside"}"#,
        ], to: outsideGrok)
        let encoded = root.appendingPathComponent("sessions/%2Foutside")
        try FileManager.default.createDirectory(at: encoded, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: encoded.appendingPathComponent("escaped-session"),
            withDestinationURL: outsideGrokDirectory
        )

        let outsideCopilot = outside.appendingPathComponent("events.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"user.message","data":{"content":"outside"}}"#,
        ], to: outsideCopilot)
        let copilotDirectory = root.appendingPathComponent("session-state/cp")
        try FileManager.default.createDirectory(at: copilotDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: copilotDirectory.appendingPathComponent("events.jsonl"),
            withDestinationURL: outsideCopilot
        )

        let outsideDatabase = outside.appendingPathComponent("outside.db")
        try Data("not sqlite".utf8).write(to: outsideDatabase)
        let conversations = root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: conversations.appendingPathComponent("escaped.db"),
            withDestinationURL: outsideDatabase
        )

        let repository = HistoryRepository(historyDirs: [root.path], homeDirectory: root)
        XCTAssertTrue(repository.listSessions().isEmpty)
        XCTAssertThrowsError(try repository.getSession(
            file: encoded.appendingPathComponent("escaped-session/chat_history.jsonl")
        ))
        XCTAssertEqual(
            Set(repository.pathResolver.watchRoots().map(\.lastPathComponent)),
            ["projects", "sessions", "archived_sessions", "session-state", "conversations"]
        )
    }
}
