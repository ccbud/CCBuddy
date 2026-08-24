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

        let session = try HistoryRepository(
            historyDirs: [root.path], homeDirectory: root
        ).getSession(file: file)
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

        let session = try HistoryRepository(
            historyDirs: [root.path], homeDirectory: root
        ).getSession(file: file)
        XCTAssertEqual(session.metadata.source, .codex)
        XCTAssertEqual(session.metadata.sessionID, "old-1")
        XCTAssertEqual(session.metadata.cwd, "/tmp/old")
        XCTAssertEqual(session.metadata.title, "hello old codex")
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant"])
    }

    func testLargeCodexRolloutStreamsIntoBoundedPresentation() throws {
        let root = try HistoryTestSupport.temporaryDirectory("codex-stream-bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "922b8fee-5f94-47cb-bfff-5f19c29d23f6"
        let file = root.appendingPathComponent(
            "sessions/2026/08/24/rollout-\(threadID).jsonl"
        )
        let largeUser = "synthetic-message-head-"
            + String(repeating: "m", count: 96 * 1_024)
            + "-synthetic-message-tail"
        let largeOutput = "synthetic-result-head-"
            + String(repeating: "r", count: 128 * 1_024)
            + "-synthetic-result-tail"
        var lines = [
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:00.000Z",
                type: "session_meta",
                payload: #"{"id":"\#(threadID)","cwd":"/tmp/synthetic-stream"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:01.000Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(largeUser)"}]}"#
            ),
        ]
        for index in 0..<16 {
            lines.append(HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:02.000Z",
                type: "response_item",
                payload: #"{"type":"custom_tool_call","name":"exec","call_id":"synthetic-\#(index)","input":"bounded-input"}"#
            ))
            lines.append(HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:03.000Z",
                type: "response_item",
                payload: #"{"type":"custom_tool_call_output","call_id":"synthetic-\#(index)","output":"\#(largeOutput)"}"#
            ))
        }
        try HistoryTestSupport.write(lines, to: file)
        let originalSource = try Data(contentsOf: file)

        let streamed = try CodexMessageNormalizer.normalizeStreaming(from: file)
        XCTAssertTrue(streamed.transcript.lines.isEmpty)
        XCTAssertGreaterThan(streamed.metrics.bytesRead, 2 * 1_024 * 1_024)
        XCTAssertLessThan(streamed.metrics.peakBufferedRecordBytes, 160 * 1_024)
        XCTAssertEqual(streamed.metrics.diagnostics.malformedLines, 0)

        let session = try HistoryRepository(
            historyDirs: [root.path], homeDirectory: root
        ).getSession(file: file)
        XCTAssertEqual(session.metadata.file, file.standardizedFileURL)
        XCTAssertGreaterThan(session.metadata.sizeBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(ConversationReplayLink.transcriptFiles(in: session), [file.standardizedFileURL])

        let userText = try XCTUnwrap(session.messages.first?.content.first?.text)
        XCTAssertLessThanOrEqual(
            userText.utf8.count,
            CodexMessageNormalizer.maximumMessageTextBytes
        )
        XCTAssertTrue(userText.hasSuffix("… (truncated)"))
        XCTAssertFalse(userText.contains("synthetic-message-tail"))

        let results = session.messages.flatMap(\.content).filter { $0.type == "tool_result" }
        XCTAssertEqual(results.count, 16)
        for result in results {
            let output = try XCTUnwrap(result.content?.stringValue)
            XCTAssertLessThanOrEqual(
                output.utf8.count,
                CodexMessageNormalizer.maximumToolValueBytes
            )
            XCTAssertTrue(output.hasSuffix("… (truncated)"))
            XCTAssertFalse(output.contains("synthetic-result-tail"))
        }

        let mutation = ConversationMutationService(configuration: .init(
            historyDirs: [root.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        ))
        let rawExport = root.appendingPathComponent("streamed-export.jsonl")
        let rawResult = try mutation.exportRaw(session.metadata, to: rawExport)
        XCTAssertFalse(rawResult.bundled)
        XCTAssertEqual(try Data(contentsOf: rawExport), originalSource)
        XCTAssertEqual(try Data(contentsOf: file), originalSource)

        let html = root.appendingPathComponent("streamed-export.html")
        try ConversationHTMLExporter().export(session, to: html)
        XCTAssertTrue(
            try String(contentsOf: html, encoding: .utf8).hasPrefix("<!doctype html>")
        )
        let markdown = root.appendingPathComponent("streamed-export.md")
        try ConversationMarkdownExporter().export(session, to: markdown)
        XCTAssertTrue(
            try String(contentsOf: markdown, encoding: .utf8).hasPrefix("# ")
        )
        XCTAssertEqual(try Data(contentsOf: file), originalSource)
    }

    func testImportedCodexAlsoUsesStreamingPresentationPath() throws {
        let root = try HistoryTestSupport.temporaryDirectory("codex-stream-imported")
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = root.appendingPathComponent("app/imports")
        let file = imports.appendingPathComponent("projects/synthetic/imported.jsonl")
        let largeText = "imported-head-"
            + String(repeating: "i", count: 96 * 1_024)
            + "-imported-tail"
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:00.000Z",
                type: "session_meta",
                payload: #"{"id":"imported-stream","cwd":"/tmp/imported"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:01.000Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(largeText)"}]}"#
            ),
        ], to: file)
        let loader = HistorySessionLoader(
            historyDirs: [],
            homeDirectory: root,
            importsRoot: imports
        )

        let session = try loader.load(file: file).session

        XCTAssertEqual(session.metadata.source, .codex)
        XCTAssertTrue(session.metadata.imported)
        XCTAssertEqual(session.metadata.file, file.standardizedFileURL)
        let text = try XCTUnwrap(session.messages.first?.content.first?.text)
        XCTAssertLessThanOrEqual(
            text.utf8.count,
            CodexMessageNormalizer.maximumMessageTextBytes
        )
        XCTAssertFalse(text.contains("imported-tail"))
    }

    func testStreamReaderDropsOneOversizedRecordAndContinuesWithinItsBufferLimit() throws {
        let root = try HistoryTestSupport.temporaryDirectory("jsonl-stream-line-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.jsonl")
        let oversized = #"{"type":"ignored","payload":""#
            + String(repeating: "x", count: 256 * 1_024)
            + #""}"#
        let retained = #"{"type":"session_meta","payload":{"id":"bounded-reader"}}"#
        try HistoryTestSupport.write([oversized, retained], to: file)
        var decodedTypes: [String] = []

        let metrics = try HistoryJSONLStreamReader.scan(
            from: file,
            maximumRecordBytes: 64 * 1_024,
            chunkBytes: 4 * 1_024
        ) { record in
            decodedTypes.append(record["type"]?.stringValue ?? "")
            return true
        }

        XCTAssertEqual(decodedTypes, ["session_meta"])
        XCTAssertEqual(metrics.diagnostics.decodedLines, 1)
        XCTAssertEqual(metrics.diagnostics.malformedLines, 1)
        XCTAssertGreaterThan(metrics.bytesRead, 256 * 1_024)
        XCTAssertLessThanOrEqual(metrics.peakBufferedRecordBytes, 64 * 1_024)
    }
}
