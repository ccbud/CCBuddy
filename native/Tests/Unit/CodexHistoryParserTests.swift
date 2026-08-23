import XCTest
@testable import CCBuddy

final class CodexHistoryParserTests: XCTestCase {
    func testCodexRolloutFixtureNormalizesMessagesToolsAndUsage() throws {
        let root = try HistoryTestSupport.temporaryDirectory("codex-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "511a7eed-4f83-46ba-afff-4e08b18c12f5"
        let file = root.appendingPathComponent("sessions/2026/08/22/rollout-\(threadID).jsonl")
        let lines = [
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00.000Z",
                type: "session_meta",
                payload: #"{"id":"\#(threadID)","session_id":"\#(threadID)","cwd":"/tmp/codex-project","cli_version":"0.142.5","git":{"branch":"main"}}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00.100Z",
                type: "turn_context",
                payload: #"{"cwd":"/tmp/codex-project","model":"gpt-5.5"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00.200Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>hidden</environment_context>"}]}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:01.000Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the codex parser"}]}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:02.000Z",
                type: "response_item",
                payload: #"{"type":"reasoning","summary":[{"type":"summary_text","text":"Inspecting records"}]}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:03.000Z",
                type: "response_item",
                payload: #"{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}","call_id":"call-1"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:04.000Z",
                type: "response_item",
                payload: #"{"type":"function_call_output","call_id":"call-1","output":"{\"output\":\"failed output\",\"metadata\":{\"exit_code\":1}}"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:05.000Z",
                type: "response_item",
                payload: #"{"type":"custom_tool_call","name":"apply_patch","call_id":"call-2","input":"*** Begin Patch"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:06.000Z",
                type: "response_item",
                payload: #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:06.100Z",
                type: "event_msg",
                payload: #"{"type":"token_count","info":{"last_token_usage":{"input_tokens":900,"cached_input_tokens":600,"output_tokens":80}}}"#
            ),
        ]
        try HistoryTestSupport.write(lines, to: file)

        let session = try HistoryRepository(historyDirs: [root.path]).getSession(file: file)
        XCTAssertEqual(session.metadata.source, .codex)
        XCTAssertEqual(session.metadata.threadID, threadID)
        XCTAssertEqual(session.metadata.rootSessionID, threadID)
        XCTAssertTrue(session.metadata.canonicalThreadIDValid)
        XCTAssertEqual(session.metadata.cwd, "/tmp/codex-project")
        XCTAssertEqual(session.metadata.project, "codex-project")
        XCTAssertEqual(session.metadata.title, "fix the codex parser")
        XCTAssertEqual(session.metadata.model, "gpt-5.5")
        XCTAssertEqual(session.metadata.gitBranch, "main")
        XCTAssertEqual(session.metadata.version, "0.142.5")

        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant", "assistant", "user", "assistant", "assistant"])
        XCTAssertEqual(session.messages[1].content[0].type, "thinking")
        XCTAssertEqual(session.messages[2].content[0].name, "Bash")
        XCTAssertEqual(session.messages[2].content[0].input?["command"]?.stringValue, "swift test")
        XCTAssertEqual(session.messages[3].content[0].toolUseID, "call-1")
        XCTAssertEqual(session.messages[3].content[0].content, .string("failed output"))
        XCTAssertEqual(session.messages[3].content[0].isError, true)
        XCTAssertEqual(session.messages[4].content[0].name, "ApplyPatch")
        XCTAssertEqual(session.messages[4].content[0].input?["patch"]?.stringValue, "*** Begin Patch")
        XCTAssertEqual(session.messages.last?.usage, .init(inputTokens: 300, outputTokens: 80, cacheRead: 600))
        XCTAssertEqual(session.metadata.totals, .init(inputTokens: 300, outputTokens: 80, cacheRead: 600, turns: 1))
        XCTAssertFalse(session.messages.contains(where: { message in
            message.content.contains(where: { $0.text?.contains("environment_context") == true })
        }))
    }

    func testOldEnvelopeLessCodexRecordsStillParse() throws {
        let root = try HistoryTestSupport.temporaryDirectory("codex-old")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/old.jsonl")
        try HistoryTestSupport.write([
            #"{"id":"old-1","timestamp":"2025-05-01T00:00:00Z","cwd":"/tmp/old"}"#,
            #"{"type":"message","role":"user","content":[{"type":"input_text","text":"hello old codex"}]}"#,
            #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}"#,
        ], to: file)

        let session = try HistoryRepository(historyDirs: [root.path]).getSession(file: file)
        XCTAssertEqual(session.metadata.source, .codex)
        XCTAssertEqual(session.metadata.sessionID, "old-1")
        XCTAssertEqual(session.metadata.cwd, "/tmp/old")
        XCTAssertEqual(session.metadata.title, "hello old codex")
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant"])
    }
}
