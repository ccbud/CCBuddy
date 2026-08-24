import Foundation
import XCTest
@testable import CCBuddy

final class ConversationMarkdownExporterTests: XCTestCase {
    func testMarkdownKeepsReadableMessagesToolsThinkingAndSubagents() {
        var metadata = Self.metadata()
        metadata.totals.inputTokens = 1_200
        metadata.totals.outputTokens = 34
        let main = [
            HistoryMessage(
                role: "user",
                content: [.init(type: "text", text: "Explain the build")],
                timestamp: Date(timeIntervalSince1970: 1_800_000_001)
            ),
            HistoryMessage(
                role: "assistant",
                content: [
                    .init(type: "thinking", thinking: "Check the logs"),
                    .init(
                        type: "tool_use",
                        id: "call-1",
                        name: "Shell <safe>",
                        input: .object(["command": .string("printf '```'")])
                    ),
                    .init(type: "text", text: "The build is fixed."),
                ]
            ),
        ]
        let child = HistorySubagent(
            agentID: "worker",
            file: URL(fileURLWithPath: "/tmp/worker.jsonl"),
            type: "explore",
            description: "Inspect adapters",
            messages: [HistoryMessage(
                role: "assistant",
                content: [.init(type: "text", text: "Adapter ready")]
            )]
        )
        let session = HistorySession(
            metadata: metadata,
            messages: main,
            subagents: ["call-1": child]
        )

        let markdown = ConversationMarkdownExporter().markdown(for: session)

        XCTAssertTrue(markdown.hasPrefix("# Wake parity\n"))
        XCTAssertTrue(markdown.contains("**Agent**: Qoder"))
        XCTAssertTrue(markdown.contains("**Tokens**: 1.2K"))
        XCTAssertTrue(markdown.contains("### 👤 User"))
        XCTAssertTrue(markdown.contains("<details><summary>🧠 Thinking</summary>"))
        XCTAssertTrue(markdown.contains("<summary>🔧 Shell &lt;safe&gt;</summary>"))
        XCTAssertTrue(markdown.contains("````json"), "nested Markdown fences must stay balanced")
        XCTAssertTrue(markdown.contains("## ⑂ Subagent: explore: Inspect adapters"))
        XCTAssertTrue(markdown.contains("Adapter ready"))
    }

    func testMarkdownExportWritesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("conversation.md")
        let session = HistorySession(
            metadata: Self.metadata(),
            messages: [HistoryMessage(
                role: "user",
                content: [.init(type: "text", text: "hello")]
            )]
        )

        try ConversationMarkdownExporter().export(session, to: destination)

        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).contains("hello"))
    }

    private static func metadata() -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "qoder:session",
            file: URL(fileURLWithPath: "/tmp/session.jsonl"),
            source: .qoder,
            dirID: "all",
            dirLabel: "Qoder",
            sessionID: "session",
            cwd: "/tmp/Wake",
            project: "Wake",
            gitBranch: "main",
            title: "Wake parity",
            autoTitle: "Wake parity",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100),
            sizeBytes: 42,
            messageCount: 2
        )
    }
}
