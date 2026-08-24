import SQLite3
import XCTest
@testable import CCBuddy

final class WakeForeignAdapterContractTests: XCTestCase {
    func testOpenCodeCanonicalDiscoveryParseDependenciesAndRawExport() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-opencode-contract")
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try createDatabase(at: database, statements: [
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
                time_created INTEGER, time_updated INTEGER, model TEXT,
                tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
                time_archived INTEGER, version TEXT
            )
            """,
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER
            )
            """,
            """
            CREATE TABLE part (
                id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, data TEXT
            )
            """,
            """
            INSERT INTO session VALUES (
                'oc-v1', NULL, '/Users/tester/Projects/Wake Contract', 'OpenCode v1 contract',
                1786000000000, 1786000600000,
                '{"providerID":"anthropic","id":"claude-sonnet-4-5"}',
                100, 50, 25, NULL, '1.14.50'
            )
            """,
            """
            INSERT INTO message VALUES
                ('v1-user', 'oc-v1',
                 '{"role":"user","time":{"created":1786000050000}}', 1786000050000),
                ('v1-assistant', 'oc-v1',
                 '{"role":"assistant","model":{"id":"claude-sonnet-4-5"},"time":{"created":1786000100000}}',
                 1786000100000)
            """,
            """
            INSERT INTO part VALUES
                ('v1-p1', 'oc-v1', 'v1-user',
                 '{"type":"text","text":"OpenCode v1 user message"}'),
                ('v1-p2', 'oc-v1', 'v1-assistant',
                 '{"type":"text","text":"OpenCode v1 assistant message"}')
            """,
            """
            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
                time_created INTEGER, time_updated INTEGER, model TEXT,
                tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
                time_archived INTEGER, version TEXT
            )
            """,
            """
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT
            )
            """,
            """
            INSERT INTO session_v2 VALUES
                ('oc-v2', NULL, '/Users/tester/Projects/Wake Contract', 'OpenCode v2 contract',
                 1786100000000, 1786100300000,
                 '{"id":"nemotron-3.5-lightning-free","providerID":"opencode"}',
                 11, 7, 3, NULL, '0.0.0-beta-17639'),
                ('oc-v2-child', 'oc-v2', '/Users/tester/Projects/Wake Contract', 'Child',
                 1786100010000, 1786100020000, NULL, 0, 0, 0, NULL, NULL)
            """,
            """
            INSERT INTO session_message VALUES
                ('v2-0', 'oc-v2', 'user', 0, 1786100000000, 1786100000000,
                 '{"text":"OpenCode inspect the scanner","time":{"created":1786100000000}}'),
                ('v2-1', 'oc-v2', 'synthetic', 1, 1786100001000, 1786100001000,
                 '{"text":"QrScanner.tsx is open","time":{"created":1786100001000}}'),
                ('v2-2', 'oc-v2', 'assistant', 2, 1786100002000, 1786100002000,
                 '{"model":{"id":"nemotron-3.5-lightning-free"},"time":{"created":1786100002000},"tokens":{"input":11,"output":7,"reasoning":3,"cache":{"read":5,"write":2}},"finish":"stop","content":[{"type":"reasoning","text":"Inspect the cleanup path"},{"type":"tool","callID":"oc-call-1","tool":"grep","state":{"status":"completed","input":{"pattern":"useEffect"},"output":"Sources/QrScanner.tsx:42"}},{"type":"text","text":"The cleanup is present."}]}'),
                ('v2-3', 'oc-v2', 'unknown-event', 3, 1786100003000, 1786100003000, '{}'),
                ('v2-child-0', 'oc-v2-child', 'user', 0, 1786100010000, 1786100010000,
                 '{"text":"A child session must not be discovered"}')
            """,
        ])

        let configuration = makeConfiguration(home: home)
        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates().filter { $0.formatHint == .opencode }
        XCTAssertEqual(Set(candidates.compactMap(\.nativeID)), ["oc-v1", "oc-v2"])
        XCTAssertTrue(candidates.allSatisfy {
            $0.backingFile.map(resolvedPath) == resolvedPath(database)
        })
        XCTAssertTrue(candidates.allSatisfy { resolvedPath($0.file) != resolvedPath(database) })

        let v1 = try loader.load(try candidate("oc-v1", in: candidates))
        XCTAssertEqual(v1.session.metadata.version, "1.14.50")
        XCTAssertEqual(v1.session.messages.map(\.role), ["user", "assistant"])

        let v2Candidate = try candidate("oc-v2", in: candidates)
        let loaded = try loader.load(v2Candidate)
        let session = loaded.session
        XCTAssertEqual(session.metadata.id, "opencode:oc-v2")
        XCTAssertEqual(session.metadata.source, .opencode)
        XCTAssertEqual(session.metadata.title, "OpenCode v2 contract")
        XCTAssertEqual(session.metadata.cwd, "/Users/tester/Projects/Wake Contract")
        XCTAssertEqual(session.metadata.project, "Wake Contract")
        XCTAssertEqual(session.metadata.version, "opencode2:0.0.0-beta-17639")
        XCTAssertEqual(session.metadata.model, "nemotron-3.5-lightning-free")
        XCTAssertEqual(session.metadata.messageCount, 2)
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 4, malformedLines: 1))
        XCTAssertEqual(session.metadata.totals.inputTokens, 11)
        XCTAssertEqual(session.metadata.totals.outputTokens, 10)
        XCTAssertEqual(session.metadata.totals.cacheRead, 5)
        XCTAssertEqual(session.metadata.totals.cacheCreation, 2)
        XCTAssertEqual(
            try XCTUnwrap(session.metadata.createdAt).timeIntervalSince1970,
            1_786_100_000,
            accuracy: 0.001
        )
        XCTAssertEqual(session.messages.map(\.role), ["user", "user", "assistant"])
        XCTAssertTrue(session.messages[1].isMetadata)
        XCTAssertEqual(
            session.messages[2].content.map(\.type),
            ["thinking", "tool_use", "tool_result", "text"]
        )
        XCTAssertEqual(session.messages[2].modelActual, "nemotron-3.5-lightning-free")
        XCTAssertEqual(session.messages[2].stopReason, "stop")
        XCTAssertEqual(session.messages[2].content[1].id, "oc-call-1")
        XCTAssertEqual(session.messages[2].content[1].name, "grep")
        XCTAssertEqual(
            session.messages[2].content[1].input?["pattern"]?.stringValue,
            "useEffect"
        )
        XCTAssertEqual(session.messages[2].content[2].toolUseID, "oc-call-1")
        XCTAssertEqual(
            session.messages[2].content[2].content?.stringValue,
            "Sources/QrScanner.tsx:42"
        )
        XCTAssertEqual(session.messages[2].content[2].isError, false)

        let wal = URL(fileURLWithPath: database.path + "-wal")
        let shm = URL(fileURLWithPath: database.path + "-shm")
        XCTAssertEqual(
            resolvedPaths(OpenCodeConversationSourceAdapter().watchRoots(
                configuration: configuration
            )),
            [resolvedPath(database.deletingLastPathComponent())]
        )
        XCTAssertNotNil(dependency(in: loaded.manifest, file: database, role: .primaryDatabase))
        XCTAssertNotNil(dependency(in: loaded.manifest, file: wal, role: .sqliteWriteAheadLog))
        XCTAssertEqual(
            dependency(in: loaded.manifest, file: shm, role: .sqliteSharedMemory)?
                .contributesToFingerprint,
            false
        )
        XCTAssertNotNil(dependency(
            in: loaded.manifest,
            file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
            role: .customMetadata
        ))
        let impact = loader.adapters.eventImpact(
            [wal],
            knownManifests: [loaded.manifest],
            configuration: configuration
        )
        XCTAssertEqual(resolvedPaths(impact.candidates.map(\.file)), [resolvedPath(v2Candidate.file)])
        XCTAssertTrue(impact.requiresDiscovery)

        let destination = home.appendingPathComponent("opencode-contract-export.db")
        let mutations = ConversationMutationService(configuration: mutationConfiguration(
            from: configuration
        ))
        XCTAssertEqual(try mutations.suggestedRawFileExtension(for: session.metadata), "db")
        let exported = try mutations.exportRaw(session.metadata, to: destination)
        XCTAssertEqual(exported.fileExtension, "db")
        XCTAssertFalse(exported.bundled)
        let snapshot = try XCTUnwrap(HistorySQLiteDatabase(destination))
        XCTAssertEqual(
            snapshot.textValue("SELECT title FROM session_v2 WHERE id = 'oc-v2'"),
            "OpenCode v2 contract"
        )
        XCTAssertEqual(
            snapshot.textValue("SELECT COUNT(*) FROM session_message WHERE session_id = 'oc-v2'"),
            "4"
        )
    }

    func testOpenCodeXDGDatabaseDrivesDiscoveryWatchingAndCanonicalScope() throws {
        let root = try HistoryTestSupport.temporaryDirectory("wake-opencode-xdg")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let fallback = home.appendingPathComponent(".local/share/opencode/opencode.db")
        let xdg = root.appendingPathComponent("xdg-data")
        let selected = xdg.appendingPathComponent("opencode/opencode.db")
        try createDatabase(
            at: fallback,
            statements: openCodeFixtureStatements(id: "fallback-session")
        )
        try createDatabase(
            at: selected,
            statements: openCodeFixtureStatements(id: "xdg-session")
        )
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: home.appendingPathComponent(".ccbud/imports", isDirectory: true),
            environment: ["XDG_DATA_HOME": xdg.path]
        )
        XCTAssertEqual(configuration.openCodeDefaultDatabase, selected.standardizedFileURL)

        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates().filter { $0.formatHint == .opencode }
        XCTAssertEqual(candidates.compactMap(\.nativeID), ["xdg-session"])
        XCTAssertTrue(candidates.allSatisfy {
            $0.backingFile?.standardizedFileURL == selected.standardizedFileURL
        })
        XCTAssertEqual(
            OpenCodeConversationSourceAdapter().watchRoots(configuration: configuration),
            [selected.deletingLastPathComponent().standardizedFileURL]
        )
        let canonical = loader.adapters.discoveryDirectories(
            configuration: configuration
        ).first { $0.label == "OpenCode" }
        XCTAssertEqual(
            canonical?.baseURL.standardizedFileURL,
            selected.deletingLastPathComponent().standardizedFileURL
        )
    }

    func testGeminiCanonicalDiscoveryParseDependenciesAndRawExport() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-gemini-contract")
        defer { try? FileManager.default.removeItem(at: home) }
        let slug = "wake-contract-gemini"
        let transcript = home.appendingPathComponent(
            ".gemini/tmp/\(slug)/chats/session-2026-08-04T12-00-00.jsonl"
        )
        try HistoryTestSupport.write([
            #"{"sessionId":"gemini-contract-id","projectHash":"wake-contract-gemini","startTime":"2026-08-04T12:00:00.000Z","lastUpdated":"2026-08-04T12:20:00.000Z"}"#,
            #"{"$set":{"messages":[{"id":"old","type":"user","content":[{"text":"superseded snapshot"}],"timestamp":"2026-08-04T12:00:30.000Z"}]}}"#,
            #"{"$set":{"messages":[{"id":"u1","type":"user","content":[{"text":"Gemini inspect the scanner"}],"timestamp":"2026-08-04T12:01:00.000Z"},{"id":"a1","type":"gemini","model":"gemini-2.5-pro","content":[{"thought":true,"text":"Check the effect lifecycle"},{"text":"I will inspect the source."},{"functionCall":{"id":"gem-call-1","name":"read_file","args":{"path":"Sources/QrScanner.tsx"}}},{"functionResponse":{"id":"gem-call-1","name":"read_file","response":{"output":"cleanup found"}}}],"timestamp":"2026-08-04T12:02:00.000Z"}]}}"#,
            #"{"checkpoint":"producer noise"}"#,
        ], to: transcript)
        let originalSource = try Data(contentsOf: transcript)
        let projects = home.appendingPathComponent(".gemini/projects.json")
        try HistoryTestSupport.write([
            #"{"projects":{"/Users/tester/Projects/Wake Contract":"wake-contract-gemini"}}"#,
        ], to: projects)
        let configuration = makeConfiguration(home: home)
        let customMetadata = configuration.appDataRoot.appendingPathComponent("agent-meta.json")
        try HistoryTestSupport.write([
            #"{"gemini:gemini-contract-id":{"title":"Pinned Gemini contract","tagList":["wake","gemini"],"delete":false}}"#,
        ], to: customMetadata)

        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates().filter { $0.formatHint == .gemini }
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(resolvedPath(candidate.file), resolvedPath(transcript))
        XCTAssertEqual(candidate.nativeID, "session-2026-08-04T12-00-00")
        XCTAssertEqual(candidate.projectDirectoryName, slug)

        let loaded = try loader.load(candidate)
        let session = loaded.session
        XCTAssertEqual(session.metadata.id, "gemini:gemini-contract-id")
        XCTAssertEqual(session.metadata.source, .gemini)
        XCTAssertEqual(session.metadata.cwd, "/Users/tester/Projects/Wake Contract")
        XCTAssertEqual(session.metadata.project, "Wake Contract")
        XCTAssertEqual(session.metadata.title, "Pinned Gemini contract")
        XCTAssertEqual(session.metadata.autoTitle, "Gemini inspect the scanner")
        XCTAssertEqual(session.metadata.tags, ["wake", "gemini"])
        XCTAssertEqual(session.metadata.model, "gemini-2.5-pro")
        XCTAssertEqual(session.metadata.messageCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(session.metadata.createdAt).timeIntervalSince1970,
            1_785_844_800,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(session.metadata.lastActivity).timeIntervalSince1970,
            1_785_846_000,
            accuracy: 0.001
        )
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant"])
        XCTAssertFalse(session.messages.flatMap(\.content).contains {
            $0.text == "superseded snapshot"
        })
        XCTAssertEqual(
            session.messages[1].content.map(\.type),
            ["thinking", "text", "tool_use", "tool_result"]
        )
        XCTAssertEqual(session.messages[1].modelActual, "gemini-2.5-pro")
        XCTAssertEqual(session.messages[1].content[0].thinking, "Check the effect lifecycle")
        XCTAssertEqual(session.messages[1].content[2].id, "gem-call-1")
        XCTAssertEqual(session.messages[1].content[2].name, "read_file")
        XCTAssertEqual(
            session.messages[1].content[2].input?["path"]?.stringValue,
            "Sources/QrScanner.tsx"
        )
        XCTAssertEqual(session.messages[1].content[3].toolUseID, "gem-call-1")
        XCTAssertEqual(
            session.messages[1].content[3].content?["output"]?.stringValue,
            "cleanup found"
        )

        XCTAssertEqual(
            resolvedPaths(GeminiConversationSourceAdapter().watchRoots(
                configuration: configuration
            )),
            [resolvedPath(home.appendingPathComponent(".gemini/tmp"))]
        )
        XCTAssertNotNil(dependency(in: loaded.manifest, file: transcript, role: .primaryTranscript))
        XCTAssertNotNil(dependency(in: loaded.manifest, file: projects, role: .providerMetadata))
        XCTAssertNotNil(dependency(
            in: loaded.manifest,
            file: customMetadata,
            role: .customMetadata
        ))
        let metadataImpact = loader.adapters.eventImpact(
            [projects],
            knownManifests: [loaded.manifest],
            configuration: configuration
        )
        XCTAssertEqual(
            resolvedPaths(metadataImpact.candidates.map(\.file)),
            [resolvedPath(transcript)]
        )
        XCTAssertFalse(metadataImpact.requiresDiscovery)
        let transcriptImpact = loader.adapters.eventImpact(
            [transcript],
            knownManifests: [loaded.manifest],
            configuration: configuration
        )
        XCTAssertEqual(
            resolvedPaths(transcriptImpact.candidates.map(\.file)),
            [resolvedPath(transcript)]
        )
        XCTAssertTrue(transcriptImpact.requiresDiscovery)

        let destination = home.appendingPathComponent("gemini-contract-export.jsonl")
        let mutations = ConversationMutationService(configuration: mutationConfiguration(
            from: configuration
        ))
        XCTAssertEqual(try mutations.suggestedRawFileExtension(for: session.metadata), "jsonl")
        let exported = try mutations.exportRaw(session.metadata, to: destination)
        XCTAssertEqual(exported.fileExtension, "jsonl")
        XCTAssertFalse(exported.bundled)
        XCTAssertEqual(try Data(contentsOf: destination), originalSource)
    }

    func testKimiCanonicalDiscoveryParseDependenciesAndRawExport() throws {
        let home = try HistoryTestSupport.temporaryDirectory("wake-kimi-contract")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "session_88888888-aaaa-bbbb-cccc-000000000008"
        let sessionDirectory = home.appendingPathComponent(
            ".kimi-code/sessions/wd_wake_contract_abc123/\(sessionID)"
        )
        let transcript = sessionDirectory.appendingPathComponent("agents/main/wire.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"metadata","protocol_version":"1.3","created_at":1786200000000}"#,
            #"{"type":"turn.prompt","timestamp":"2026-08-06T12:01:00.000Z","input":[{"type":"text","text":"Kimi inspect the scanner"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_message","timestamp":"2026-08-06T12:02:00.000Z","message":{"role":"assistant","model":"kimi-k2.5","content":[{"type":"reasoning","text":"Inspect the cleanup path"},{"type":"tool-call","id":"kimi-call-1","name":"Read","arguments":{"path":"Sources/QrScanner.tsx"}},{"type":"text","text":"The cleanup is present."},{"type":"tool-result","toolCallId":"kimi-call-1","content":{"output":"cleanup found"},"isError":false}]}}"#,
            #"{"type":"turn.ended","turnId":1,"reason":"completed"}"#,
        ], to: transcript)
        let originalSource = try Data(contentsOf: transcript)
        let state = sessionDirectory.appendingPathComponent("state.json")
        try HistoryTestSupport.write([
            #"{"createdAt":"2026-08-06T12:00:00.000Z","updatedAt":"2026-08-06T12:30:00.000Z","title":"Kimi scanner contract","isCustomTitle":true}"#,
        ], to: state)
        let index = home.appendingPathComponent(".kimi-code/session_index.jsonl")
        try HistoryTestSupport.write([
            #"{"sessionId":"session_other","sessionDir":"/other","workDir":"/tmp/other"}"#,
            #"{"sessionId":"session_88888888-aaaa-bbbb-cccc-000000000008","sessionDir":"/fixture","workDir":"/Users/tester/Projects/Wake Contract"}"#,
        ], to: index)
        let configuration = makeConfiguration(home: home)
        let customMetadata = configuration.appDataRoot.appendingPathComponent("agent-meta.json")
        try HistoryTestSupport.write([
            #"{"kimi:session_88888888-aaaa-bbbb-cccc-000000000008":{"title":"Pinned Kimi contract","tagList":["wake","kimi"],"delete":false}}"#,
        ], to: customMetadata)

        let loader = HistorySessionLoader(configuration: configuration)
        let candidates = loader.discoverCandidates().filter { $0.formatHint == .kimi }
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(resolvedPath(candidate.file), resolvedPath(transcript))
        XCTAssertEqual(candidate.nativeID, sessionID)
        XCTAssertEqual(candidate.projectDirectoryName, "wd_wake_contract_abc123")

        let loaded = try loader.load(candidate)
        let session = loaded.session
        XCTAssertEqual(session.metadata.id, "kimi:\(sessionID)")
        XCTAssertEqual(session.metadata.source, .kimi)
        XCTAssertEqual(session.metadata.cwd, "/Users/tester/Projects/Wake Contract")
        XCTAssertEqual(session.metadata.project, "Wake Contract")
        XCTAssertEqual(session.metadata.title, "Pinned Kimi contract")
        XCTAssertEqual(session.metadata.autoTitle, "Kimi scanner contract")
        XCTAssertEqual(session.metadata.tags, ["wake", "kimi"])
        XCTAssertEqual(session.metadata.messageCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(session.metadata.createdAt).timeIntervalSince1970,
            1_786_017_600,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(session.metadata.lastActivity).timeIntervalSince1970,
            1_786_019_400,
            accuracy: 0.001
        )
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(
            session.messages[1].content.map(\.type),
            ["thinking", "tool_use", "text", "tool_result"]
        )
        XCTAssertEqual(session.messages[1].modelActual, "kimi-k2.5")
        XCTAssertEqual(session.messages[1].content[1].id, "kimi-call-1")
        XCTAssertEqual(session.messages[1].content[1].name, "Read")
        XCTAssertEqual(
            session.messages[1].content[1].input?["path"]?.stringValue,
            "Sources/QrScanner.tsx"
        )
        XCTAssertEqual(session.messages[1].content[3].toolUseID, "kimi-call-1")
        XCTAssertEqual(
            session.messages[1].content[3].content?["output"]?.stringValue,
            "cleanup found"
        )
        XCTAssertEqual(session.messages[1].content[3].isError, false)

        XCTAssertEqual(
            resolvedPaths(KimiConversationSourceAdapter().watchRoots(
                configuration: configuration
            )),
            [resolvedPath(home.appendingPathComponent(".kimi-code/sessions"))]
        )
        XCTAssertNotNil(dependency(in: loaded.manifest, file: transcript, role: .primaryTranscript))
        XCTAssertNotNil(dependency(in: loaded.manifest, file: state, role: .providerMetadata))
        XCTAssertNotNil(dependency(in: loaded.manifest, file: index, role: .providerMetadata))
        XCTAssertNotNil(dependency(
            in: loaded.manifest,
            file: customMetadata,
            role: .customMetadata
        ))
        let stateImpact = loader.adapters.eventImpact(
            [state],
            knownManifests: [loaded.manifest],
            configuration: configuration
        )
        XCTAssertEqual(
            resolvedPaths(stateImpact.candidates.map(\.file)),
            [resolvedPath(transcript)]
        )
        XCTAssertTrue(stateImpact.requiresDiscovery)
        let indexImpact = loader.adapters.eventImpact(
            [index],
            knownManifests: [loaded.manifest],
            configuration: configuration
        )
        XCTAssertEqual(
            resolvedPaths(indexImpact.candidates.map(\.file)),
            [resolvedPath(transcript)]
        )
        XCTAssertFalse(indexImpact.requiresDiscovery)

        let destination = home.appendingPathComponent("kimi-contract-export.jsonl")
        let mutations = ConversationMutationService(configuration: mutationConfiguration(
            from: configuration
        ))
        XCTAssertEqual(try mutations.suggestedRawFileExtension(for: session.metadata), "jsonl")
        let exported = try mutations.exportRaw(session.metadata, to: destination)
        XCTAssertEqual(exported.fileExtension, "jsonl")
        XCTAssertFalse(exported.bundled)
        XCTAssertEqual(try Data(contentsOf: destination), originalSource)
    }

    private func makeConfiguration(home: URL) -> HistoryConfiguration {
        HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: home.appendingPathComponent(".ccbud/imports", isDirectory: true),
            environment: [:]
        )
    }

    private func openCodeFixtureStatements(id: String) -> [String] {
        [
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
                time_created INTEGER, time_updated INTEGER, model TEXT,
                tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
                time_archived INTEGER, version TEXT
            )
            """,
            """
            CREATE TABLE part (
                id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, data TEXT
            )
            """,
            """
            INSERT INTO session VALUES (
                '\(id)', NULL, '/work/\(id)', '\(id)',
                1786000000000, 1786000600000, NULL,
                1, 1, 0, NULL, '1.0.0'
            )
            """,
            """
            INSERT INTO part VALUES (
                '\(id)-part', '\(id)', '\(id)-message',
                '{"type":"text","text":"\(id) content"}'
            )
            """,
        ]
    }

    private func mutationConfiguration(
        from configuration: HistoryConfiguration
    ) -> ConversationMutationConfiguration {
        ConversationMutationConfiguration(
            historyDirs: configuration.historyDirs,
            homeDirectory: configuration.homeDirectory,
            importsRoot: configuration.importsRoot
        )
    }

    private func candidate(
        _ nativeID: String,
        in candidates: [HistoryFileCandidate]
    ) throws -> HistoryFileCandidate {
        try XCTUnwrap(candidates.first { $0.nativeID == nativeID })
    }

    private func dependency(
        in manifest: ConversationDependencyManifest,
        file: URL,
        role: ConversationDependencyRole
    ) -> ConversationSourceDependency? {
        manifest.dependencies.first {
            resolvedPath($0.file) == resolvedPath(file) && $0.role == role
        }
    }

    private func resolvedPaths(_ files: [URL]) -> [String] {
        files.map(resolvedPath)
    }

    private func resolvedPath(_ file: URL) -> String {
        file.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func createDatabase(at file: URL, statements: [String]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let status = sqlite3_open(file.path, &database)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw fixtureError("sqlite open failed with status \(status)")
        }
        defer { sqlite3_close(database) }
        for statement in statements { try execute(statement, database: database) }
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(errorMessage)
            throw fixtureError(detail)
        }
    }

    private func fixtureError(_ detail: String) -> NSError {
        NSError(domain: "WakeForeignAdapterContractTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: detail,
        ])
    }
}
