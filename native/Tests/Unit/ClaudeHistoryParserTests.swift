import XCTest
@testable import CCBuddy

final class ClaudeHistoryParserTests: XCTestCase {
    func testTolerantClaudeFixtureNormalizesUserAssistantAndTools() throws {
        let root = try HistoryTestSupport.temporaryDirectory("claude-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-work-demo/session-a.jsonl")
        let lines = [
            "this is malformed JSON",
            HistoryTestSupport.claudeLine(
                type: "user",
                role: "user",
                contentJSON: #""Please fix the parser""#,
                sessionID: "session-a",
                cwd: "/work/demo",
                timestamp: "2026-08-20T10:00:00.000Z",
                extra: ",\"gitBranch\":\"main\",\"version\":\"1.2.3\""
            ),
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"checking"},{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"Sources/A.swift"}},{"type":"text","text":"I found it"}],"model":"claude-test","usage":{"input_tokens":11,"output_tokens":7,"cache_read_input_tokens":3,"cache_creation_input_tokens":2},"stop_reason":"tool_use"},"sessionId":"session-a","cwd":"/work/demo","gitBranch":"main","version":"1.2.3","timestamp":"2026-08-20T10:00:01.000Z"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"file contents"}]},"sessionId":"session-a","cwd":"/work/demo","timestamp":"2026-08-20T10:00:02.000Z"}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"hidden metadata"},"sessionId":"session-a","cwd":"/work/demo","timestamp":"2026-08-20T10:00:03.000Z"}"#,
            #"{"type":"summary","summary":"Parser repair","sessionId":"session-a","timestamp":"2026-08-20T10:00:04.000Z"}"#,
        ]
        try HistoryTestSupport.write(lines, to: file)

        let session = try HistoryRepository(
            historyDirs: [root.path], homeDirectory: root
        ).getSession(file: file)
        XCTAssertEqual(session.metadata.source, .claude)
        XCTAssertEqual(session.metadata.sessionID, "session-a")
        XCTAssertEqual(session.metadata.cwd, "/work/demo")
        XCTAssertEqual(session.metadata.project, "demo")
        XCTAssertEqual(session.metadata.title, "Please fix the parser")
        XCTAssertEqual(session.metadata.model, "claude-test")
        XCTAssertEqual(session.metadata.gitBranch, "main")
        XCTAssertEqual(session.metadata.version, "1.2.3")
        XCTAssertEqual(session.metadata.summary, .string("Parser repair"))
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 5, malformedLines: 1))
        XCTAssertEqual(session.metadata.totals, .init(inputTokens: 11, outputTokens: 7, cacheRead: 3, cacheCreation: 2, turns: 1))

        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(session.messages[1].content.map(\.type), ["thinking", "tool_use", "text"])
        XCTAssertEqual(session.messages[1].content[1].name, "Read")
        XCTAssertEqual(session.messages[1].content[1].input?["file_path"]?.stringValue, "Sources/A.swift")
        XCTAssertEqual(session.messages[2].content[0].toolUseID, "tool-1")
        XCTAssertFalse(session.messages.contains(where: { message in
            message.content.contains(where: { $0.text == "hidden metadata" })
        }))
    }

    func testClaudeCustomMetadataIsReadWithoutMutatingTranscript() throws {
        let root = try HistoryTestSupport.temporaryDirectory("claude-custom")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-x/s.jsonl")
        let original = #"{"type":"user","message":{"role":"user","content":"automatic"},"cwd":"/x","sessionId":"s","timestamp":"2026-01-01T00:00:00Z","__ccbud__":{"title":"Custom","tagList":["one"," ","two"],"delete":true}}"#
        try HistoryTestSupport.write([original], to: file)
        let before = try Data(contentsOf: file)

        let repository = HistoryRepository(
            historyDirs: [root.path], active: "__trash__", homeDirectory: root
        )
        let listed = repository.listSessions()
        XCTAssertEqual(listed.first?.title, "Custom")
        XCTAssertEqual(listed.first?.tags, ["one", "two"])
        XCTAssertEqual(listed.first?.deleted, true)
        _ = try repository.getSession(file: file)
        XCTAssertEqual(try Data(contentsOf: file), before, "history reads must never rewrite the source")
    }
}
