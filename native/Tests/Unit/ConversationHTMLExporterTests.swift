import Foundation
import XCTest
@testable import CCBuddy

final class ConversationHTMLExporterTests: XCTestCase {
    func testStandaloneHTMLUsesNonceEscapingVendorAssetsAndCaps() throws {
        let oversized = String(repeating: "x", count: 24_100)
        let attack = "</script><img src=x onerror=alert(1)> [x](javascript:alert(1))"
        let session = makeSession(messages: [
            HistoryMessage(role: "user", content: [
                .init(type: "text", text: attack + oversized),
            ]),
            HistoryMessage(role: "assistant", content: [
                .init(
                    type: "tool_use",
                    id: "tool-a",
                    name: "Agent",
                    input: .object(["prompt": .string(String(repeating: "p", count: 9_100))])
                ),
            ]),
        ])
        let exporter = ConversationHTMLExporter()
        let html = try exporter.html(for: session)

        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("object-src 'none'"))
        XCTAssertTrue(html.contains("\\u003c/script>"))
        XCTAssertFalse(html.contains("</script><img src=x onerror"))
        XCTAssertTrue(html.contains("[truncated \(attack.count + 100) chars]"))
        XCTAssertTrue(html.contains("[truncated 100 chars]"))
        XCTAssertTrue(html.contains("window.marked") || html.contains("marked="))
        XCTAssertTrue(html.contains("window.hljs") || html.contains("hljs="))
        XCTAssertTrue(html.contains("子代理"), "the embedded runtime must include subagent UI")

        let expression = try NSRegularExpression(pattern: #"<script nonce="([^"]+)">"#)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = expression.matches(in: html, range: range)
        XCTAssertEqual(matches.count, 4)
        let nonces = Set(matches.compactMap { match -> String? in
            guard let value = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[value])
        })
        XCTAssertEqual(nonces.count, 1)
        let nonce = try XCTUnwrap(nonces.first)
        XCTAssertTrue(html.contains("script-src 'nonce-\(nonce)'"))
    }

    func testSuggestedNameUsesProjectConversationStartAndExportTime() {
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let exporter = ConversationHTMLExporter(now: { exportedAt })
        let session = makeSession(messages: [])
        let name = exporter.suggestedBaseName(for: session)
        XCTAssertTrue(name.hasPrefix("my_project-"))
        XCTAssertEqual(name.split(separator: "-").count, 3)
    }

    private func makeSession(messages: [HistoryMessage]) -> HistorySession {
        let metadata = HistorySessionMetadata(
            id: "disk:test",
            file: URL(fileURLWithPath: "/tmp/test.jsonl"),
            source: .claude,
            dirID: "~/.claude",
            dirLabel: "~/.claude",
            sessionID: "test",
            cwd: "/tmp/my project",
            project: "my project",
            title: "A <private> title",
            autoTitle: "Auto",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_700_000_100),
            sizeBytes: 100,
            totals: HistoryTotals(
                inputTokens: 10,
                outputTokens: 20,
                cacheRead: 2,
                cacheCreation: 1,
                turns: 1,
                credits: nil,
                tokenUsageAvailable: true
            ),
            messageCount: messages.count
        )
        let subagent = HistorySubagent(
            agentID: "a",
            file: URL(fileURLWithPath: "/tmp/agent-a.jsonl"),
            type: "Explore",
            description: "inspect",
            count: 1,
            messages: [HistoryMessage(role: "assistant", content: [
                .init(type: "text", text: "child"),
            ])]
        )
        return HistorySession(metadata: metadata, messages: messages, subagents: ["tool-a": subagent])
    }
}
