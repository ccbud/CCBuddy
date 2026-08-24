import Foundation
import SQLite3
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

    func testOversizedMessagesToolsAndRawBlocksProduceBoundedIndexButFullDetail() throws {
        let root = try HistoryTestSupport.temporaryDirectory("bounded-catalog-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-large/session.jsonl")
        let messageText = "message-head-"
            + String(repeating: "message🙂", count: 12_000)
            + "-message-tail"
        let toolText = "tool-head-"
            + String(repeating: "tool界", count: 12_000)
            + "-tool-tail"
        let toolResultText = "result-head-"
            + String(repeating: "result📦", count: 12_000)
            + "-result-tail"
        let rawText = "raw-head-"
            + String(repeating: "raw🧩", count: 12_000)
            + "-raw-tail"
        let toolContent = HistoryValue.array([
            .object([
                "type": .string("tool_use"),
                "id": .string("oversized-tool"),
                "name": .string("Read"),
                "input": .object(["payload": .string(toolText)]),
            ]),
        ]).jsonString
        let toolResultContent = HistoryValue.array([
            .object([
                "type": .string("tool_result"),
                "tool_use_id": .string("oversized-tool"),
                "content": .string(toolResultText),
            ]),
        ]).jsonString
        let rawContent = HistoryValue.array([
            .object([
                "type": .string("producer_blob"),
                "payload": .string(rawText),
            ]),
        ]).jsonString
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user", role: "user",
                contentJSON: HistoryValue.string(messageText).jsonString,
                sessionID: "large", cwd: "/large",
                timestamp: "2026-08-24T00:00:00Z"
            ),
            HistoryTestSupport.claudeLine(
                type: "assistant", role: "assistant",
                contentJSON: toolContent,
                sessionID: "large", cwd: "/large",
                timestamp: "2026-08-24T00:00:01Z"
            ),
            HistoryTestSupport.claudeLine(
                type: "user", role: "user",
                contentJSON: toolResultContent,
                sessionID: "large", cwd: "/large",
                timestamp: "2026-08-24T00:00:02Z"
            ),
            HistoryTestSupport.claudeLine(
                type: "assistant", role: "assistant",
                contentJSON: rawContent,
                sessionID: "large", cwd: "/large",
                timestamp: "2026-08-24T00:00:03Z"
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
        let thread = try XCTUnwrap(loaded.projection.threads.first)
        let indexedSegments = thread.messageSpans.map {
            (thread.searchText as NSString).substring(with: $0.utf16Range)
        }

        XCTAssertEqual(indexedSegments.count, 4)
        XCTAssertLessThanOrEqual(
            indexedSegments[0].utf8.count,
            HistoryCatalogProjection.maximumMessageSearchTextBytes
        )
        XCTAssertLessThanOrEqual(
            indexedSegments[1].utf8.count,
            HistoryCatalogProjection.maximumToolSearchTextBytes
        )
        XCTAssertLessThanOrEqual(
            indexedSegments[2].utf8.count,
            HistoryCatalogProjection.maximumToolSearchTextBytes
        )
        XCTAssertLessThanOrEqual(
            indexedSegments[3].utf8.count,
            HistoryCatalogProjection.maximumRawSearchTextBytes
        )
        XCTAssertTrue(thread.searchText.contains("message-head"))
        XCTAssertTrue(thread.searchText.contains("tool-head"))
        XCTAssertTrue(thread.searchText.contains("result-head"))
        XCTAssertTrue(thread.searchText.contains("raw-head"))
        XCTAssertFalse(thread.searchText.contains("message-tail"))
        XCTAssertFalse(thread.searchText.contains("tool-tail"))
        XCTAssertFalse(thread.searchText.contains("result-tail"))
        XCTAssertFalse(thread.searchText.contains("raw-tail"))

        let database = try ConversationIndexDatabase(
            file: root.appendingPathComponent("app/catalog.sqlite3")
        )
        _ = try database.replace(ConversationIndexedSession(
            projection: loaded.projection,
            fingerprint: ConversationIndexFingerprint(
                modificationTime: loaded.session.metadata.lastActivity,
                sizeBytes: loaded.session.metadata.sizeBytes
            )
        ))
        let stored = try XCTUnwrap(try database.documents(for: file).first)
        XCTAssertEqual(stored.text, thread.searchText)
        XCTAssertLessThanOrEqual(
            stored.text.utf8.count,
            HistoryCatalogProjection.maximumMessageSearchTextBytes
                + (2 * HistoryCatalogProjection.maximumToolSearchTextBytes)
                + HistoryCatalogProjection.maximumRawSearchTextBytes
                + 3
        )

        // Detail, replay, and export callers all reload this normalized raw session rather than
        // reading the bounded SQLite projection.
        let detail = try loader.getSession(file: file)
        XCTAssertEqual(detail.messages[0].content[0].text, messageText)
        XCTAssertEqual(detail.messages[1].content[0].input?["payload"]?.stringValue, toolText)
        XCTAssertEqual(detail.messages[2].content[0].content?.stringValue, toolResultText)
        XCTAssertEqual(detail.messages[3].content[0].raw?["payload"]?.stringValue, rawText)
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

    func testEventImpactDoesNotRediscoverEveryAdapterForEachWatchedPath() throws {
        let root = try HistoryTestSupport.temporaryDirectory("event-impact-batch-discovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("sessions/known.jsonl")
        try HistoryTestSupport.write(["{}"], to: transcript)
        let auxiliaryEvents = (0..<128).map {
            root.appendingPathComponent("sessions/new-\($0)/terminal/output.log")
        }

        let directory = HistoryDirectory(
            id: root.path,
            label: root.path,
            baseURL: root,
            projectsURL: root.appendingPathComponent("projects"),
            sessionsURL: root.appendingPathComponent("sessions")
        )
        let candidate = HistoryFileCandidate(
            file: transcript,
            directory: directory,
            formatHint: .claude
        )
        let manifest = ConversationDependencyManifest(
            candidate: candidate,
            source: .claude,
            dependencies: [.init(file: transcript, role: .primaryTranscript)]
        )
        let adapter = EventImpactCountingAdapter(watchRoot: root)
        let registry = ConversationSourceAdapterRegistry(adapters: [adapter])
        let configuration = HistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )

        let impact = registry.eventImpact(
            [transcript] + auxiliaryEvents,
            knownManifests: [manifest],
            configuration: configuration
        )

        XCTAssertEqual(impact.candidates.map(\.file), [transcript.standardizedFileURL])
        XCTAssertTrue(impact.requiresDiscovery)
        XCTAssertEqual(
            adapter.candidateCallCount,
            0,
            "A large watched batch must use manifests plus one later discovery pass, not rediscover per event"
        )
    }

    func testQuickMetadataUsesBoundedCompleteLinesDetectsFormatsAndIsolatesFailures() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-metadata-prefix")
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("projects/-claude/claude.jsonl")
        let qoder = root.appendingPathComponent("projects/-qoder/qoder.jsonl")
        let partial = root.appendingPathComponent("projects/-partial/partial.jsonl")
        let invalid = root.appendingPathComponent("projects/-invalid/invalid.jsonl")
        let claudeLine = HistoryTestSupport.claudeLine(
            type: "user", role: "user", contentJSON: #""bounded title""#,
            sessionID: "bounded", cwd: "/bounded", timestamp: "2026-08-24T00:00:00Z"
        )
        try HistoryTestSupport.write([claudeLine], to: claude)
        let handle = try FileHandle(forWritingTo: claude)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(
            repeating: "this tail is deliberately not JSON and has no newline ",
            count: 9_000
        ).utf8))
        try handle.close()

        try HistoryTestSupport.write([
            #"{"type":"runtime-config","sessionId":"qoder-detected","model":"qoder-model"}"#,
            #"{"type":"user","sessionId":"qoder-detected","timestamp":"2026-08-24T00:00:00Z","message":{"role":"user","content":"qoder title"}}"#,
        ], to: qoder)
        try HistoryTestSupport.write([claudeLine], to: partial)
        let partialHandle = try FileHandle(forWritingTo: partial)
        try partialHandle.seekToEnd()
        try partialHandle.write(contentsOf: Data(#"{"unfinished":""#.utf8) + Data([0xF0, 0x9F]))
        try partialHandle.close()
        try HistoryTestSupport.write([#"{"unknown":"producer"}"#], to: invalid)

        let configuration = HistoryConfiguration(
            historyDirs: [root.path], homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = [claude, qoder, partial, invalid].map {
            try! loader.pathResolver.validatedCandidate(for: $0)
        }
        let quick = loader.loadQuickMetadata(candidates)
        let byFile = Dictionary(uniqueKeysWithValues: quick.map {
            ($0.candidate.file.standardizedFileURL.path, $0)
        })

        XCTAssertEqual(quick.count, 3)
        XCTAssertEqual(byFile[claude.standardizedFileURL.path]?.metadata.title, "bounded title")
        XCTAssertEqual(byFile[claude.standardizedFileURL.path]?.metadata.diagnostics.malformedLines, 0)
        XCTAssertEqual(byFile[qoder.standardizedFileURL.path]?.metadata.source, .qoder)
        XCTAssertEqual(byFile[partial.standardizedFileURL.path]?.metadata.sessionID, "bounded")
        XCTAssertNil(byFile[invalid.standardizedFileURL.path])
        for value in quick {
            XCTAssertNotNil(value.manifest.primary)
            XCTAssertEqual(value.dependencySnapshot.fingerprint.count, 64)
        }
    }

    func testQuickMetadataAcceptsCompleteEOFRecordWithoutTrailingNewline() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-metadata-no-newline")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-claude/single.jsonl")
        let line = HistoryTestSupport.claudeLine(
            type: "user", role: "user", contentJSON: #""single line title""#,
            sessionID: "single-line", cwd: "/single-line",
            timestamp: "2026-08-24T00:00:00Z"
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(line.utf8).write(to: file)
        let loader = HistorySessionLoader(historyDirs: [root.path], homeDirectory: root)
        let candidate = try loader.pathResolver.validatedCandidate(for: file)

        let quick = try XCTUnwrap(loader.loadQuickMetadata([candidate]).first)

        XCTAssertEqual(quick.metadata.source, .claude)
        XCTAssertEqual(quick.metadata.sessionID, "single-line")
        XCTAssertEqual(quick.metadata.title, "single line title")
    }

    func testQuickQoderReadUsesInjectedPermissionAwareReader() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-qoder-reader")
        defer { try? FileManager.default.removeItem(at: root) }
        let qoderRoot = root.appendingPathComponent(".qoder", isDirectory: true)
        let file = qoderRoot.appendingPathComponent("projects/-project/session.jsonl")
        try HistoryTestSupport.write([#"{"not":"a qoder transcript"}"#], to: file)
        let supplied = Data(([
            #"{"type":"runtime-config","sessionId":"reader-session","model":"reader-model"}"#,
            #"{"type":"user","sessionId":"reader-session","timestamp":"2026-08-24T00:00:00Z","message":{"role":"user","content":"reader title"}}"#,
        ].joined(separator: "\n") + "\n").utf8)
        let access = QuickMetadataQoderAccess(data: supplied)
        let reader = QoderFileReader(
            fileAccess: access,
            helperResolver: QuickMetadataQoderResolver(),
            helperRunner: QuickMetadataQoderRunner()
        )
        let loader = HistorySessionLoader(
            historyDirs: [qoderRoot.path], homeDirectory: root, qoderReader: reader
        )
        let candidate = try loader.pathResolver.validatedCandidate(for: file)
        let quick = try XCTUnwrap(loader.loadQuickMetadata([candidate]).first)

        XCTAssertEqual(access.readCount, 1)
        XCTAssertEqual(quick.metadata.source, .qoder)
        XCTAssertEqual(quick.metadata.sessionID, "reader-session")
        XCTAssertEqual(quick.metadata.title, "reader title")
    }

    func testCodexQuickMetadataMergesCompletedStateAndFullLoadKeepsManualName() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-codex-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixID = "511a7eed-4f83-46ba-afff-4e08b18c12f5"
        let stateID = "622b8fee-5f94-47cb-bfff-5f19c29d23f6"
        let rollout = root.appendingPathComponent(
            "sessions/2026/08/24/rollout-\(prefixID).jsonl"
        )
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:00Z", type: "session_meta",
                payload: #"{"id":"\#(prefixID)","cwd":"/prefix-project","git":{"branch":"prefix"}}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:01Z", type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"prefix title"}]}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-24T00:00:02Z", type: "response_item",
                payload: #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"full tail"}]}"#
            ),
        ], to: rollout)
        try HistoryTestSupport.write(["sqlite_home = '.'"], to: root.appendingPathComponent("config.toml"))
        try createSQLite(
            root.appendingPathComponent("state_5.sqlite"),
            sql: """
            CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT);
            INSERT INTO backfill_state VALUES (1, 'complete');
            CREATE TABLE threads (
              id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, name TEXT,
              tokens_used INTEGER, archived INTEGER, git_branch TEXT, model TEXT,
              source TEXT, created_at_ms INTEGER, updated_at_ms INTEGER
            );
            INSERT INTO threads VALUES (
              '\(stateID)', '\(sqlEscaped(rollout.standardizedFileURL.path))',
              '/state-project', 'state title', 'manual name', 1234, 0,
              'state-branch', 'state-model', 'cli', 1787529600000, 1787529660000
            );
            """
        )

        let loader = HistorySessionLoader(
            historyDirs: [root.path], homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let candidate = try loader.pathResolver.validatedCandidate(for: rollout)
        let quick = try XCTUnwrap(loader.loadQuickMetadata([candidate]).first)
        XCTAssertEqual(quick.metadata.title, "manual name")
        XCTAssertEqual(quick.metadata.sessionID, stateID)
        XCTAssertEqual(quick.metadata.threadID, stateID)
        XCTAssertEqual(quick.metadata.cwd, "/state-project")
        XCTAssertEqual(quick.metadata.project, "state-project")
        XCTAssertEqual(quick.metadata.gitBranch, "state-branch")
        XCTAssertEqual(quick.metadata.model, "state-model")
        XCTAssertEqual(quick.metadata.totals.inputTokens, 1234)
        XCTAssertEqual(quick.metadata.createdAt.timeIntervalSince1970, 1_787_529_600, accuracy: 0.1)
        XCTAssertEqual(quick.metadata.lastActivity.timeIntervalSince1970, 1_787_529_660, accuracy: 0.1)

        let full = try loader.load(candidate)
        XCTAssertEqual(full.session.metadata.title, "manual name")
        XCTAssertEqual(full.session.metadata.sessionID, stateID)
        XCTAssertEqual(full.session.messages.last?.content.first?.text, "full tail")
    }

    func testCodexStatePublishesQuickMetadataWhenFirstRecordExceedsPrefixBudget() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-codex-large-first-line")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixID = "711a7eed-4f83-46ba-afff-4e08b18c12f5"
        let stateID = "822b8fee-5f94-47cb-bfff-5f19c29d23f6"
        let rollout = root.appendingPathComponent(
            "sessions/2026/08/24/rollout-\(prefixID).jsonl"
        )
        let padding = String(
            repeating: "x",
            count: HistorySessionLoader.maximumQuickReadBytes + 4_096
        )
        let oversized = HistoryTestSupport.codexLine(
            timestamp: "2026-08-24T00:00:00Z",
            type: "session_meta",
            payload: #"{"id":"\#(prefixID)","cwd":"/prefix","padding":"\#(padding)"}"#
        )
        try HistoryTestSupport.write([oversized], to: rollout)
        try HistoryTestSupport.write(
            ["sqlite_home = '.'"],
            to: root.appendingPathComponent("config.toml")
        )
        try createSQLite(
            root.appendingPathComponent("state_5.sqlite"),
            sql: """
            CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT);
            INSERT INTO backfill_state VALUES (1, 'complete');
            CREATE TABLE threads (
              id TEXT, rollout_path TEXT, cwd TEXT, name TEXT,
              tokens_used INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER
            );
            INSERT INTO threads VALUES (
              '\(stateID)', '\(sqlEscaped(rollout.standardizedFileURL.path))',
              '/state-only', 'state-only title', 4321, 1787529600000, 1787529660000
            );
            """
        )
        let configuration = HistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidate = try loader.pathResolver.validatedCandidate(for: rollout)

        let quick = try XCTUnwrap(loader.loadQuickMetadata([candidate]).first)

        XCTAssertEqual(quick.metadata.source, .codex)
        XCTAssertEqual(quick.metadata.sessionID, stateID)
        XCTAssertEqual(quick.metadata.title, "state-only title")
        XCTAssertEqual(quick.metadata.cwd, "/state-only")
        XCTAssertEqual(quick.metadata.totals.inputTokens, 4321)

        let index = try ConversationIndexDatabase(
            file: root.appendingPathComponent("app/scanner.sqlite")
        )
        let scanner = ConversationIndexScanner(configuration: configuration, database: index)
        let progress = QuickMetadataScanProgressProbe()
        let result = try scanner.scanAll { value in progress.append(value) }

        XCTAssertEqual(result.metadataPublished, 1)
        XCTAssertEqual(result.parsed, 1)
        XCTAssertTrue(progress.results.contains {
            $0.metadataPublished == 1 && $0.parsed == 0
        })
        XCTAssertEqual(try index.entry(for: rollout)?.metadata.title, "state-only title")
    }

    func testCodexStateSchemaDegradesAndIncompleteBackfillFallsBackToPrefix() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-codex-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("sessions/2026/08/24/rollout-schema.jsonl")
        try HistoryTestSupport.write(["{}"], to: rollout)
        try HistoryTestSupport.write(["sqlite_home = '.'"], to: root.appendingPathComponent("config.toml"))
        let database = root.appendingPathComponent("state_5.sqlite")
        try createSQLite(database, sql: """
            CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT);
            INSERT INTO backfill_state VALUES (1, 'complete');
            CREATE TABLE threads (rollout_path TEXT, title TEXT);
            INSERT INTO threads VALUES ('\(sqlEscaped(rollout.standardizedFileURL.path))', 'schema title');
            """)
        let degraded = CodexStateDatabase.quickMetadata(
            for: [rollout], homeDirectory: root, environment: [:]
        )
        XCTAssertEqual(degraded[rollout.standardizedFileURL.path]?.title, "schema title")
        XCTAssertNil(degraded[rollout.standardizedFileURL.path]?.model)

        try executeSQLite(database, sql: "DELETE FROM backfill_state")
        XCTAssertTrue(CodexStateDatabase.quickMetadata(
            for: [rollout], homeDirectory: root, environment: [:]
        ).isEmpty)
    }

    func testCanonicalWakeGrokStreamsLargeUpdatesWithBoundedPresentationAndRawExport() throws {
        let root = try HistoryTestSupport.temporaryDirectory("wake-grok-stream")
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = "77777777-aaaa-bbbb-cccc-000000000007"
        let file = root.appendingPathComponent(
            ".grok/sessions/%2Ftmp%2Fgrok-stream/\(nativeID)/updates.jsonl"
        )

        func row(timestamp: Double, update: [String: HistoryValue]) -> String {
            HistoryValue.object([
                "timestamp": .number(timestamp),
                "method": .string("session/update"),
                "params": .object([
                    "sessionId": .string(nativeID),
                    "update": .object(update),
                ]),
            ]).jsonString
        }

        let largeChunk = String(repeating: "chunk-data-", count: 12_000)
        let largeToolInput = "tool-input-head-"
            + String(repeating: "i", count: 96 * 1_024)
            + "-tool-input-tail"
        let largeToolOutput = "tool-output-head-"
            + String(repeating: "o", count: 96 * 1_024)
            + "-tool-output-tail"
        let largeRawOutput = "raw-output-head-"
            + String(repeating: "r", count: 96 * 1_024)
            + "-raw-output-tail"
        var lines: [String] = []
        for index in 0..<20 {
            let text = (index == 0 ? "grok-stream-head-" : "")
                + largeChunk
                + (index == 19 ? "-grok-stream-tail" : "")
            lines.append(row(timestamp: 1_786_014_300 + Double(index), update: [
                "sessionUpdate": .string("user_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)]),
            ]))
        }
        lines.append(row(timestamp: 1_786_014_321, update: [
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("thinking-head-" + largeChunk + "-thinking-tail"),
            ]),
        ]))
        lines.append(row(timestamp: 1_786_014_322, update: [
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("stream-tool"),
            "title": .string("Grep"),
        ]))
        lines.append(row(timestamp: 1_786_014_323, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("stream-tool"),
            "status": .string("running"),
            "rawInput": .object(["query": .string(largeToolInput)]),
            "content": .array([
                .object(["content": .object([
                    "type": .string("text"), "text": .string("initial output"),
                ])]),
            ]),
        ]))
        for index in 0..<1_024 {
            lines.append(row(timestamp: 1_786_014_324 + Double(index) / 10_000, update: [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("stream-tool"),
                "status": .string("running"),
                "content": .array([
                    .object(["content": .object([
                        "type": .string("text"), "text": .string("pending update \(index)"),
                    ])]),
                ]),
            ]))
        }
        lines.append(row(timestamp: 1_786_014_325, update: [
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"), "text": .string("assistant answer"),
            ]),
        ]))
        lines.append(row(timestamp: 1_786_014_326, update: [
            "sessionUpdate": .string("user_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("follow-up")]),
        ]))
        for index in 0..<1_024 {
            lines.append(row(timestamp: 1_786_014_327 + Double(index) / 10_000, update: [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("stream-tool"),
                "status": .string("running"),
                "content": .array([
                    .object(["content": .object([
                        "type": .string("text"), "text": .string("flushed update \(index)"),
                    ])]),
                ]),
            ]))
        }
        lines.append(row(timestamp: 1_786_014_328, update: [
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("stream-tool"),
            "status": .string("completed"),
            "content": .array([
                .object(["content": .object([
                    "type": .string("text"), "text": .string(largeToolOutput),
                ])]),
            ]),
            "rawOutput": .object(["stdout": .string(largeRawOutput)]),
        ]))
        lines.append("not valid json")
        lines.append(row(timestamp: 1_786_014_329, update: [
            "sessionUpdate": .string("user_message_chunk"),
            "content": .object([
                "type": .string("text"), "text": .string(" after malformed"),
            ]),
        ]))
        try HistoryTestSupport.write(lines, to: file)
        try HistoryTestSupport.write([
            HistoryValue.object([
                "info": .object(["cwd": .string("/tmp/grok-stream")]),
                "generated_title": .string("Canonical Grok stream"),
                "created_at": .string("2026-08-06T11:00:00Z"),
                "updated_at": .string("2026-08-06T11:20:00Z"),
                "head_branch": .string("feature/stream"),
                "current_model_id": .string("grok-stream-model"),
            ]).jsonString,
        ], to: file.deletingLastPathComponent().appendingPathComponent("summary.json"))
        let originalSource = try Data(contentsOf: file)

        let streamed = try WakeGrokHistoryParser.normalizeStreaming(from: file)
        XCTAssertEqual(streamed.metrics.bytesRead, originalSource.count)
        XCTAssertGreaterThan(streamed.metrics.bytesRead, 2 * 1_024 * 1_024)
        XCTAssertLessThan(streamed.metrics.peakBufferedRecordBytes, 256 * 1_024)
        XCTAssertEqual(streamed.metrics.diagnostics.decodedLines, lines.count - 1)
        XCTAssertEqual(streamed.metrics.diagnostics.malformedLines, 1)
        XCTAssertEqual(streamed.messages.map(\.role), ["user", "assistant", "user"])

        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let loader = HistorySessionLoader(configuration: configuration)
        let candidate = try XCTUnwrap(loader.discoverCandidates(activeOnly: false).first {
            $0.file.standardizedFileURL == file.standardizedFileURL
        })
        let session = try loader.load(candidate).session

        XCTAssertEqual(session.metadata.source, .grok)
        XCTAssertEqual(session.metadata.sessionID, nativeID)
        XCTAssertEqual(session.metadata.title, "Canonical Grok stream")
        XCTAssertEqual(session.metadata.cwd, "/tmp/grok-stream")
        XCTAssertEqual(session.metadata.gitBranch, "feature/stream")
        XCTAssertEqual(session.metadata.model, "grok-stream-model")
        XCTAssertEqual(session.metadata.diagnostics, streamed.metrics.diagnostics)
        XCTAssertEqual(session.metadata.messageCount, 3)
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(session.messages.last?.content.first?.text, "follow-up after malformed")

        let userText = try XCTUnwrap(session.messages[0].content.first?.text)
        XCTAssertLessThanOrEqual(userText.utf8.count, WakeGrokHistoryParser.maximumMessageTextBytes)
        XCTAssertTrue(userText.hasPrefix("grok-stream-head-"))
        XCTAssertTrue(userText.hasSuffix("… (truncated)"))
        XCTAssertFalse(userText.contains("grok-stream-tail"))

        let assistant = session.messages[1]
        let thinking = try XCTUnwrap(assistant.content.first { $0.type == "thinking" }?.thinking)
        XCTAssertLessThanOrEqual(thinking.utf8.count, WakeGrokHistoryParser.maximumToolValueBytes)
        XCTAssertFalse(thinking.contains("thinking-tail"))
        let toolUse = try XCTUnwrap(assistant.content.first { $0.type == "tool_use" })
        let toolResult = try XCTUnwrap(assistant.content.first { $0.type == "tool_result" })
        XCTAssertEqual(assistant.content.filter { $0.type == "tool_result" }.count, 1)
        XCTAssertEqual(toolUse.id, "stream-tool")
        XCTAssertLessThanOrEqual(
            toolUse.input?.jsonString.utf8.count ?? .max,
            WakeGrokHistoryParser.maximumToolValueBytes
        )
        XCTAssertFalse(toolUse.input?.jsonString.contains("tool-input-tail") ?? true)
        XCTAssertLessThanOrEqual(
            toolUse.raw?.jsonString.utf8.count ?? .max,
            WakeGrokHistoryParser.maximumToolValueBytes
        )
        XCTAssertLessThanOrEqual(
            toolResult.content?.jsonString.utf8.count ?? .max,
            WakeGrokHistoryParser.maximumToolValueBytes
        )
        XCTAssertTrue(toolResult.content?.jsonString.contains("tool-output-head") ?? false)
        XCTAssertFalse(toolResult.content?.jsonString.contains("tool-output-tail") ?? true)
        XCTAssertLessThanOrEqual(
            toolResult.raw?.jsonString.utf8.count ?? .max,
            WakeGrokHistoryParser.maximumToolValueBytes
        )
        XCTAssertFalse(toolResult.raw?.jsonString.contains("raw-output-tail") ?? true)
        XCTAssertEqual(ConversationReplayLink.transcriptFiles(in: session), [file.standardizedFileURL])

        let export = root.appendingPathComponent("grok-stream-export.jsonl")
        let exported = try ConversationMutationService(configuration: .init(
            historyDirs: [],
            homeDirectory: root,
            importsRoot: configuration.importsRoot
        )).exportRaw(session.metadata, to: export)
        XCTAssertFalse(exported.bundled)
        XCTAssertEqual(try Data(contentsOf: export), originalSource)
        XCTAssertEqual(try Data(contentsOf: file), originalSource)
    }

    func testAntigravityQuickMetadataDoesNotOpenConversationSteps() throws {
        let root = try HistoryTestSupport.temporaryDirectory("quick-antigravity")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversations/antigravity-id.db")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a sqlite database and intentionally unreadable as steps".utf8)
            .write(to: file)
        let loader = HistorySessionLoader(historyDirs: [root.path], homeDirectory: root)
        let candidate = try loader.pathResolver.validatedCandidate(for: file)
        let quick = try XCTUnwrap(loader.loadQuickMetadata([candidate]).first)

        XCTAssertEqual(quick.metadata.source, .antigravity)
        XCTAssertEqual(quick.metadata.sessionID, "antigravity-id")
        XCTAssertEqual(quick.metadata.title, "antigravity-id")
        XCTAssertEqual(quick.manifest.primary?.role, .primaryDatabase)
    }

    private func createSQLite(_ file: URL, sql: String) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &connection), SQLITE_OK)
        guard let connection else { throw NSError(domain: "SQLiteTest", code: 1) }
        defer { sqlite3_close(connection) }
        try executeSQLite(connection, sql: sql)
    }

    private func executeSQLite(_ file: URL, sql: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &connection), SQLITE_OK)
        guard let connection else { throw NSError(domain: "SQLiteTest", code: 2) }
        defer { sqlite3_close(connection) }
        try executeSQLite(connection, sql: sql)
    }

    private func executeSQLite(_ connection: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(connection, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw NSError(
                domain: "SQLiteTest", code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "SQLite error",
                ]
            )
        }
    }

    private func sqlEscaped(_ value: String) -> String {
        return value.replacingOccurrences(of: "'", with: "''")
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

private final class QuickMetadataScanProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversationIndexScanResult] = []

    var results: [ConversationIndexScanResult] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ result: ConversationIndexScanResult) {
        lock.lock()
        storage.append(result)
        lock.unlock()
    }
}

private final class EventImpactCountingAdapter: ConversationSourceAdapter, @unchecked Sendable {
    let source = HistorySource.claude
    let format = HistoryTranscriptFormat.claude

    private let watchRoot: URL
    private let lock = NSLock()
    private var candidateCalls = 0

    init(watchRoot: URL) {
        self.watchRoot = watchRoot
    }

    var candidateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return candidateCalls
    }

    func candidate(
        for file: URL,
        configuration: HistoryConfiguration
    ) -> HistoryFileCandidate? {
        lock.lock()
        candidateCalls += 1
        lock.unlock()
        return nil
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        [watchRoot]
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        [.init(file: candidate.file, role: .primaryTranscript)]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        throw HistoryError.unsupportedTranscript(input.candidate.file)
    }
}

private final class QuickMetadataQoderAccess: QoderFileAccessing, @unchecked Sendable {
    private let system = SystemQoderFileAccess()
    private let data: Data
    private let lock = NSLock()
    private var reads = 0

    init(data: Data) {
        self.data = data
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func readData(at file: URL) throws -> Data {
        lock.lock()
        reads += 1
        lock.unlock()
        return data
    }

    func probeReadable(at file: URL) throws {
        try system.probeReadable(at: file)
    }

    func stamp(of file: URL) throws -> QoderFileStamp {
        return try system.stamp(of: file)
    }
}

private struct QuickMetadataQoderResolver: QoderHelperResolving {
    func trustedHelper(for dataRoot: URL) throws -> URL {
        return dataRoot.appendingPathComponent("unused-helper")
    }
}

private struct QuickMetadataQoderRunner: QoderHelperRunning {
    func read(
        helper: URL,
        target: URL,
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> Data {
        throw QoderFileReadError.helperFailed("unexpected helper read")
    }

    func readBatch(
        helper: URL,
        targets: [URL],
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> [URL: Data] {
        throw QoderFileReadError.helperFailed("unexpected helper batch")
    }
}
