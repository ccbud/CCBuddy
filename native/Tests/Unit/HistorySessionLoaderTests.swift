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

    func testCodexSharedStateRefreshesProjectionWithoutChangingRolloutFingerprint() throws {
        let root = try HistoryTestSupport.temporaryDirectory("codex-shared-dependencies")
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent(
            "sessions/2026/08/23/rollout-shared-state.jsonl"
        )
        let config = root.appendingPathComponent("config.toml")
        let state = root.appendingPathComponent("state_5.sqlite")
        let wal = URL(fileURLWithPath: state.path + "-wal")
        let shm = URL(fileURLWithPath: state.path + "-shm")
        try HistoryTestSupport.write([#"{"type":"fixture"}"#], to: rollout)
        try HistoryTestSupport.write(["# default sqlite_home"], to: config)
        try HistoryTestSupport.write(["state-one"], to: state)
        try HistoryTestSupport.write(["wal-one"], to: wal)
        try HistoryTestSupport.write(["locks-one"], to: shm)

        let directory = HistoryDirectory(
            id: root.path,
            label: root.path,
            baseURL: root,
            projectsURL: root.appendingPathComponent("projects"),
            sessionsURL: root.appendingPathComponent("sessions")
        )
        let candidate = HistoryFileCandidate(
            file: rollout,
            directory: directory,
            formatHint: .codex
        )
        let configuration = HistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let registry = ConversationSourceAdapterRegistry()
        let manifest = try registry.manifest(
            for: candidate,
            format: .codex,
            configuration: configuration
        )
        let initialFingerprint = manifest.snapshot().fingerprint

        try HistoryTestSupport.write(["# changed shared config"], to: config)
        try HistoryTestSupport.write(["state-two-is-longer"], to: state)
        try HistoryTestSupport.write(["wal-two-is-longer"], to: wal)
        XCTAssertEqual(manifest.snapshot().fingerprint, initialFingerprint)

        for sharedFile in [config, state, wal] {
            let dependency = try XCTUnwrap(manifest.dependencies.first {
                $0.file.standardizedFileURL == sharedFile.standardizedFileURL
            })
            XCTAssertFalse(dependency.contributesToFingerprint)
            XCTAssertTrue(dependency.requiresProjectionRefresh)
            let impact = registry.eventImpact(
                [sharedFile],
                knownManifests: [manifest],
                configuration: configuration
            )
            XCTAssertEqual(impact.candidates.map(\.file), [rollout.standardizedFileURL])
            XCTAssertTrue(impact.requiresProjectionRefresh)
        }

        let shmDependency = try XCTUnwrap(manifest.dependencies.first {
            $0.file.standardizedFileURL == shm.standardizedFileURL
        })
        XCTAssertFalse(shmDependency.contributesToFingerprint)
        XCTAssertFalse(shmDependency.requiresProjectionRefresh)
        XCTAssertFalse(registry.eventImpact(
            [shm],
            knownManifests: [manifest],
            configuration: configuration
        ).requiresProjectionRefresh)
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
