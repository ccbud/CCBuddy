import Foundation
import XCTest
@testable import CCBuddy

final class HistorySessionLoaderTests: XCTestCase {
    func testLoaderReusesClaudeParserAndBuildsStableProjection() throws {
        let root = try HistoryTestSupport.temporaryDirectory("session-loader")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-loader/session.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user",
                contentJSON: #""visible<system-reminder>private</system-reminder>""#,
                sessionID: "loader", cwd: "/loader",
                timestamp: "2026-08-23T00:00:00Z"
            ),
            HistoryTestSupport.claudeLine(
                type: "assistant", role: "assistant",
                contentJSON: #"[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"proof.swift"}}]"#,
                sessionID: "loader", cwd: "/loader",
                timestamp: "2026-08-23T00:00:01Z"
            ),
        ], to: file)

        let configuration = HistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidate = try loader.pathResolver.validatedCandidate(for: file)
        let loaded = try loader.load(candidate)

        XCTAssertEqual(loaded.session.metadata.sessionID, "loader")
        XCTAssertEqual(loaded.projection.threads.map(\.transcriptID), ["main"])
        XCTAssertEqual(loaded.projection.threads[0].messageSpans.map(\.messageIndex), [0, 1])
        XCTAssertTrue(loaded.projection.threads[0].searchText.contains("proof.swift"))
        XCTAssertFalse(loaded.projection.threads[0].searchText.contains("private"))
        XCTAssertEqual(loaded.manifest.primary?.file, file.standardizedFileURL)
        XCTAssertEqual(loaded.dependencySnapshot.fingerprint.count, 64)
    }

    func testProjectionKeepsRawMessageIndicesAndSortsSubagentsByFilename() {
        let root = URL(fileURLWithPath: "/tmp/catalog-projection")
        let metadata = makeMetadata(file: root.appendingPathComponent("main.jsonl"))
        let messages = [
            HistoryMessage(role: "user", content: [.init(type: "text", text: "first")]),
            HistoryMessage(
                role: "system",
                content: [.init(type: "text", text: "hidden")],
                isMetadata: true
            ),
            HistoryMessage(role: "assistant", content: [.init(type: "text", text: "third")]),
        ]
        let session = HistorySession(
            metadata: metadata,
            messages: messages,
            subagents: [
                "later": HistorySubagent(
                    agentID: "b", file: root.appendingPathComponent("agent-b.jsonl"),
                    messages: [.init(role: "assistant", content: [.init(type: "text", text: "b")])]
                ),
                "earlier": HistorySubagent(
                    agentID: "a", file: root.appendingPathComponent("agent-a.jsonl"),
                    messages: [.init(role: "assistant", content: [.init(type: "text", text: "a")])]
                ),
            ]
        )

        let projection = HistoryCatalogProjection(session: session)
        XCTAssertEqual(projection.threads.map(\.transcriptID), ["main", "earlier", "later"])
        XCTAssertEqual(projection.threads[0].searchText, "first\nthird")
        XCTAssertEqual(projection.threads[0].messageSpans.map(\.sequence), [0, 2])
        XCTAssertEqual(projection.threads[0].messageSpans[1].utf16Location, 6)
    }

    func testSidecarAndWALDependenciesOwnEventsBeforeFilesExist() throws {
        let root = try HistoryTestSupport.temporaryDirectory("dependency-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = HistoryDirectory(
            id: root.path,
            label: root.path,
            baseURL: root,
            projectsURL: root.appendingPathComponent("projects"),
            sessionsURL: root.appendingPathComponent("sessions")
        )
        let db = root.appendingPathComponent("conversations/conversation.db")
        let candidate = HistoryFileCandidate(
            file: db,
            directory: directory,
            formatHint: .antigravity
        )
        let configuration = HistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let manifest = try ConversationSourceAdapterRegistry().manifest(
            for: candidate,
            format: .antigravity,
            configuration: configuration
        )

        let wal = URL(fileURLWithPath: db.path + "-wal")
        let summaryWAL = URL(fileURLWithPath: root.appendingPathComponent(
            "conversation_summaries.db"
        ).path + "-wal")
        XCTAssertTrue(manifest.ownsEvent(at: wal))
        XCTAssertTrue(manifest.ownsEvent(at: summaryWAL))
        XCTAssertTrue(manifest.dependencies.contains {
            $0.role == .sqliteSharedMemory && !$0.contributesToFingerprint
        })
    }

    private func makeMetadata(file: URL) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "disk:projection",
            file: file,
            source: .claude,
            dirID: "test",
            dirLabel: "test",
            sessionID: "projection",
            project: "projection",
            title: "projection",
            autoTitle: "projection",
            createdAt: .distantPast,
            lastActivity: .distantPast,
            sizeBytes: 0
        )
    }
}
