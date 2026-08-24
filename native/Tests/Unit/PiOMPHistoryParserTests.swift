import Foundation
import XCTest
@testable import CCBuddy

final class PiOMPHistoryParserTests: XCTestCase {
    func testCanonicalPiAndOMPAdaptersSupportDiscoveryDependenciesExportAndReplay() throws {
        let root = try HistoryTestSupport.temporaryDirectory("pi-omp-contract")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let imports = home.appendingPathComponent(".ccbud/imports", isDirectory: true)
        let piRoot = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        let pi = piRoot
            .appendingPathComponent("--tmp-pi-project--", isDirectory: true)
            .appendingPathComponent("2026-08-11T01-00-00-000Z_pi-contract.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session","version":3,"id":"pi-contract","timestamp":"2026-08-11T01:00:00.000Z","cwd":"/tmp/pi-project"}"#,
            #"{"type":"message","id":"pi-u1","timestamp":"2026-08-11T01:00:01.000Z","message":{"role":"user","content":"Pi canonical message"}}"#,
            #"{"type":"message","id":"pi-a1","timestamp":"2026-08-11T01:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"pi-call","name":"read","arguments":{"path":"src/pi.ts"}}],"model":"gpt-5.5","usage":{"input":12,"output":4,"cacheRead":2,"cacheWrite":1}}}"#,
            #"{"type":"message","id":"pi-r1","timestamp":"2026-08-11T01:00:03.000Z","message":{"role":"toolResult","toolCallId":"pi-call","content":[{"type":"text","text":"pi result"}],"isError":false}}"#,
        ], to: pi)

        let ompRoot = home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        let omp = ompRoot
            .appendingPathComponent("--tmp-omp-project--", isDirectory: true)
            .appendingPathComponent("2026-08-12T01-00-00-000Z_omp-contract.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session","version":4,"id":"omp-contract","timestamp":"2026-08-12T01:00:00.000Z","cwd":"/tmp/omp-project"}"#,
            #"{"type":"message","id":"omp-u1","timestamp":"2026-08-12T01:00:01.000Z","message":{"role":"user","content":"OMP canonical message"}}"#,
            #"{"type":"message","id":"omp-a1","timestamp":"2026-08-12T01:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"OMP canonical response"}],"model":"claude-opus-4-1","usage":{"input_tokens":21,"output_tokens":8,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}}"#,
        ], to: omp)

        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports
        )
        let loader = HistorySessionLoader(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports
        )
        let discovered = loader.discoverCandidates()
        let piCandidates = discovered.filter { $0.formatHint == .pi }
        let ompCandidates = discovered.filter { $0.formatHint == .omp }
        XCTAssertEqual(piCandidates.count, 1)
        XCTAssertEqual(ompCandidates.count, 1)

        try assertCanonicalAdapter(
            PiConversationSourceAdapter(),
            candidate: try XCTUnwrap(piCandidates.first),
            configuration: configuration,
            expectedSource: .pi,
            expectedFormat: .pi,
            expectedDirectoryID: "__wake_pi__",
            expectedWatchRoot: piRoot,
            expectedSessionID: "pi-contract",
            expectedUserText: "Pi canonical message",
            expectedInputTokens: 12,
            expectedOutputTokens: 4,
            exportRoot: root
        )
        try assertCanonicalAdapter(
            OMPConversationSourceAdapter(),
            candidate: try XCTUnwrap(ompCandidates.first),
            configuration: configuration,
            expectedSource: .omp,
            expectedFormat: .omp,
            expectedDirectoryID: "__wake_omp__",
            expectedWatchRoot: ompRoot,
            expectedSessionID: "omp-contract",
            expectedUserText: "OMP canonical message",
            expectedInputTokens: 21,
            expectedOutputTokens: 8,
            exportRoot: root
        )
    }

    func testPiNormalizesWakeContractThinkingToolsUsageAndMetadata() throws {
        let context = makeContext(
            fileName: "2026-08-06T10-00-00-000Z_fallback-id.jsonl",
            lines: [
                #"{"type":"session","version":3,"id":"66666666-aaaa-bbbb-cccc-000000000006","timestamp":"2026-08-06T10:00:00.000Z","cwd":"/Users/tester/Github/wakefx"}"#,
                #"{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-06T10:00:01.000Z","provider":"openai-codex","modelId":"gpt-5.5"}"#,
                #"{"type":"thinking_level_change","id":"t1","parentId":"m1","timestamp":"2026-08-06T10:00:01.100Z","thinkingLevel":"medium"}"#,
                #"{"type":"message","id":"meta","parentId":"t1","timestamp":"2026-08-06T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"<environment_context>injected</environment_context>"}]}}"#,
                #"{"type":"message","id":"u1","parentId":"meta","timestamp":"2026-08-06T10:00:05.000Z","message":{"role":"user","content":[{"type":"text","text":"Pi 查一下二维码组件的 useEffect() 清理"},{"type":"image","data":"QUJD","mimeType":"image/png"}],"timestamp":1786010405000}}"#,
                #"{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-06T10:00:08.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"先定位副作用"},{"type":"toolCall","id":"call_pi_1","name":"bash","arguments":{"command":"rg useEffect src/"}}],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-5.5","usage":{"input":100,"output":20,"cacheRead":7,"cacheWrite":3,"totalTokens":4242},"stopReason":"toolUse"}}"#,
                #"{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-08-06T10:00:09.000Z","message":{"role":"toolResult","toolCallId":"call_pi_1","toolName":"bash","content":[{"type":"text","text":"src/QrScanner.tsx: useEffect(() => watch())"}],"isError":false}}"#,
                #"{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-08-06T10:00:12.000Z","message":{"role":"assistant","content":[{"type":"text","text":"找到泄漏点,已补清理回调。"}],"model":"gpt-5.5","usage":{"input":200,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":4300},"stopReason":"stop"}}"#,
                "not valid json",
            ]
        )

        let session = PiHistoryParser.parse(context)

        XCTAssertEqual(session.metadata.source.rawValue, "pi")
        XCTAssertEqual(session.metadata.id, "pi:66666666-aaaa-bbbb-cccc-000000000006")
        XCTAssertEqual(session.metadata.sessionID, "66666666-aaaa-bbbb-cccc-000000000006")
        XCTAssertEqual(session.metadata.cwd, "/Users/tester/Github/wakefx")
        XCTAssertEqual(session.metadata.project, "wakefx")
        XCTAssertEqual(session.metadata.version, "3")
        XCTAssertEqual(session.metadata.title, "Pi 查一下二维码组件的 useEffect() 清理")
        XCTAssertEqual(session.metadata.model, "gpt-5.5")
        XCTAssertEqual(session.metadata.messageCount, 2, "Injected metadata is not a visible turn")
        XCTAssertEqual(session.metadata.totals.inputTokens, 300)
        XCTAssertEqual(session.metadata.totals.outputTokens, 50)
        XCTAssertEqual(session.metadata.totals.cacheRead, 7)
        XCTAssertEqual(session.metadata.totals.cacheCreation, 3)
        XCTAssertEqual(session.metadata.totals.turns, 2)
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 8, malformedLines: 1))
        XCTAssertEqual(
            session.metadata.createdAt,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-06T10:00:00.000Z"))
        )
        XCTAssertEqual(
            session.metadata.lastActivity,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-06T10:00:12.000Z"))
        )

        XCTAssertEqual(session.messages.map(\.role), ["user", "user", "assistant"])
        XCTAssertTrue(session.messages[0].isMetadata)
        XCTAssertEqual(session.messages[1].content.map(\.type), ["text", "image"])
        let assistant = session.messages[2]
        XCTAssertEqual(assistant.content.map(\.type), ["thinking", "tool_use", "tool_result", "text"])
        XCTAssertEqual(assistant.content[0].thinking, "先定位副作用")
        XCTAssertEqual(assistant.content[1].id, "call_pi_1")
        XCTAssertEqual(assistant.content[1].name, "bash")
        XCTAssertEqual(assistant.content[1].input?["command"]?.stringValue, "rg useEffect src/")
        XCTAssertEqual(assistant.content[2].toolUseID, "call_pi_1")
        XCTAssertEqual(
            HistoryParsingSupport.searchableToolResult(assistant.content[2].content),
            "src/QrScanner.tsx: useEffect(() => watch())"
        )
        XCTAssertEqual(assistant.content[2].isError, false)
        XCTAssertEqual(assistant.content[3].text, "找到泄漏点,已补清理回调。")
        XCTAssertEqual(assistant.modelActual, "gpt-5.5")
        XCTAssertEqual(assistant.stopReason, "stop")
        XCTAssertEqual(
            assistant.timestamp,
            try XCTUnwrap(HistoryDateParser.parse("2026-08-06T10:00:08.000Z")),
            "A merged assistant turn keeps its first event timestamp"
        )
    }

    func testOMPReusesPiCoreAndPreservesProducerTitleNumericTimestampsAndSidechains() throws {
        let context = makeContext(
            fileName: "2026-08-07T11-00-00-000Z_omp-session-id.jsonl",
            lines: [
                #"{"type":"title","v":1,"title":"Initial OMP title","source":"auto","updatedAt":"2026-08-07T11:00:00.000Z","pad":""}"#,
                #"{"type":"session","version":3,"timestamp":"2026-08-07T11:00:00.000Z","cwd":"/Users/tester/Github/ompfx","title":"Header title"}"#,
                #"{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-07T11:00:00.500Z","model":"anthropic/claude-opus-4-1"}"#,
                #"{"type":"message","id":"u1","parentId":"m1","message":{"role":"user","content":"OMP inspect the scanner","timestamp":1786100401000}}"#,
                #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Inspecting"}],"model":"claude-opus-4-1","timestamp":1786100402000}}"#,
                #"{"type":"message","id":"u2","parentId":"a1","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"side investigation"}],"timestamp":1786100403000}}"#,
                #"{"type":"message","id":"a2","parentId":"u2","isSidechain":true,"message":{"role":"assistant","content":[{"type":"toolCall","id":"omp-tool-1","name":"read","arguments":{"path":"src/scan.ts"}}],"model":"claude-opus-4-1","timestamp":1786100404000}}"#,
                #"{"type":"message","id":"r2","parentId":"a2","message":{"role":"toolResult","toolCallId":"omp-tool-1","content":[{"type":"text","text":"permission denied"},{"type":"image","data":"REVG","mimeType":"image/png"}],"isError":true,"timestamp":1786100405000}}"#,
                #"{"type":"title_change","id":"n1","parentId":"r2","timestamp":"2026-08-07T11:01:00.000Z","title":"OMP scanner audit","source":"user"}"#,
            ]
        )

        let session = OMPHistoryParser.parse(context)

        XCTAssertEqual(session.metadata.source.rawValue, "omp")
        XCTAssertEqual(session.metadata.id, "omp:omp-session-id")
        XCTAssertEqual(session.metadata.sessionID, "omp-session-id")
        XCTAssertEqual(session.metadata.title, "OMP scanner audit")
        XCTAssertEqual(session.metadata.autoTitle, "OMP scanner audit")
        XCTAssertEqual(session.metadata.cwd, "/Users/tester/Github/ompfx")
        XCTAssertEqual(session.metadata.project, "ompfx")
        XCTAssertEqual(session.metadata.model, "claude-opus-4-1")
        XCTAssertEqual(session.metadata.messageCount, 4)
        XCTAssertEqual(session.metadata.lastActivity.timeIntervalSince1970, 1_786_100_405, accuracy: 0.001)
        XCTAssertEqual(session.messages.map(\.isSidechain), [false, false, true, true])
        XCTAssertEqual(session.messages[1].content.first?.thinking, "Inspecting")
        XCTAssertEqual(session.messages[3].content.map(\.type), ["tool_use", "tool_result"])
        XCTAssertEqual(session.messages[3].content[0].input?["path"]?.stringValue, "src/scan.ts")
        XCTAssertEqual(session.messages[3].content[1].isError, true)
        XCTAssertEqual(
            session.messages[3].content[1].content?.arrayValue?[1]["type"]?.stringValue,
            "image"
        )
    }

    private func makeContext(
        fileName: String,
        lines: [String]
    ) -> HistoryParseContext {
        let root = URL(fileURLWithPath: "/tmp/ccbuddy-pi-parser-tests", isDirectory: true)
        let directory = HistoryDirectory(
            id: "~/.pi",
            label: "~/.pi",
            baseURL: root,
            projectsURL: root.appendingPathComponent("projects", isDirectory: true),
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true)
        )
        let file = directory.sessionsURL
            .appendingPathComponent("--Users-tester-Github-project--", isDirectory: true)
            .appendingPathComponent(fileName)
        return HistoryParseContext(
            candidate: HistoryFileCandidate(
                file: file,
                projectDirectoryName: nil,
                directory: directory
            ),
            document: HistoryJSONLDocument.parse(lines.joined(separator: "\n")),
            facts: HistoryFileFacts(
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2),
                sizeBytes: 4_096
            ),
            homeDirectory: root,
            appDataRoot: root.appendingPathComponent(".ccbud", isDirectory: true)
        )
    }

    private func assertCanonicalAdapter(
        _ adapter: any ConversationSourceAdapter,
        candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration,
        expectedSource: HistorySource,
        expectedFormat: HistoryTranscriptFormat,
        expectedDirectoryID: String,
        expectedWatchRoot: URL,
        expectedSessionID: String,
        expectedUserText: String,
        expectedInputTokens: Int,
        expectedOutputTokens: Int,
        exportRoot: URL
    ) throws {
        XCTAssertEqual(adapter.source, expectedSource)
        XCTAssertEqual(adapter.format, expectedFormat)
        XCTAssertEqual(candidate.formatHint, expectedFormat)
        XCTAssertEqual(candidate.nativeID, expectedSessionID)
        XCTAssertEqual(candidate.directory.id, expectedDirectoryID)
        XCTAssertEqual(
            adapter.discover(configuration: configuration, activeOnly: true),
            [candidate]
        )
        XCTAssertEqual(
            adapter.candidate(for: candidate.file, configuration: configuration),
            candidate
        )
        XCTAssertEqual(adapter.watchRoots(configuration: configuration), [
            expectedWatchRoot.standardizedFileURL,
        ])

        let dependencies = adapter.dependencies(for: candidate, configuration: configuration)
        XCTAssertEqual(Set(dependencies.map(\.role)), [.primaryTranscript, .customMetadata])
        XCTAssertTrue(dependencies.contains {
            $0.file == candidate.file.standardizedFileURL && $0.role == .primaryTranscript
        })
        XCTAssertTrue(dependencies.contains {
            $0.file == configuration.appDataRoot.appendingPathComponent("agent-meta.json")
                .standardizedFileURL && $0.role == .customMetadata
        })

        let document = try XCTUnwrap(try adapter.document(
            for: candidate,
            qoderReader: .shared
        ))
        let facts = try HistoryFileFacts.read(candidate.file, records: document.records)
        let session = try adapter.parse(ConversationSourceParseInput(
            candidate: candidate,
            document: document,
            facts: facts,
            configuration: configuration
        ))
        XCTAssertEqual(session.metadata.source, expectedSource)
        XCTAssertEqual(session.metadata.id, "\(expectedSource.rawValue):\(expectedSessionID)")
        XCTAssertEqual(session.metadata.sessionID, expectedSessionID)
        XCTAssertEqual(session.messages.first?.content.first?.text, expectedUserText)
        XCTAssertEqual(session.metadata.totals.inputTokens, expectedInputTokens)
        XCTAssertEqual(session.metadata.totals.outputTokens, expectedOutputTokens)
        XCTAssertEqual(session.metadata.totals.turns, 1)

        let mutations = ConversationMutationService(configuration: .init(
            historyDirs: [],
            homeDirectory: configuration.homeDirectory,
            importsRoot: configuration.importsRoot
        ))
        XCTAssertEqual(try mutations.suggestedRawFileExtension(for: session.metadata), "jsonl")
        let exported = exportRoot.appendingPathComponent("\(expectedSource.rawValue)-raw.jsonl")
        let exportResult = try mutations.exportRaw(session.metadata, to: exported)
        XCTAssertFalse(exportResult.bundled)
        XCTAssertEqual(exportResult.fileExtension, "jsonl")
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: candidate.file))

        let prepared = try ConversationReplayMaterializer(
            root: exportRoot.appendingPathComponent(
                "\(expectedSource.rawValue)-replay",
                isDirectory: true
            )
        ).prepare(session)
        XCTAssertEqual(
            prepared.metadata.file.resolvingSymlinksInPath(),
            candidate.file.resolvingSymlinksInPath(),
            "Readable Pi-family JSONL should remain directly attachable"
        )
        let replayFile = try XCTUnwrap(ConversationReplayLink.transcriptFiles(in: prepared).first)
        XCTAssertEqual(
            replayFile.resolvingSymlinksInPath(),
            candidate.file.resolvingSymlinksInPath()
        )

        let claude = try XCTUnwrap(ConversationReplayLink.makeURL(
            destination: .claude,
            session: prepared,
            language: .english
        ))
        let claudeFiles = URLComponents(url: claude, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "file" }.compactMap(\.value)
        XCTAssertEqual(claudeFiles, [replayFile.path])
        let chatGPT = try XCTUnwrap(ConversationReplayLink.makeURL(
            destination: .chatGPT,
            session: prepared,
            language: .english
        ))
        let chatGPTItems = try XCTUnwrap(
            URLComponents(url: chatGPT, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(
            chatGPTItems.first(where: { $0.name == "path" })?.value,
            replayFile.deletingLastPathComponent().path
        )
        XCTAssertTrue(
            try XCTUnwrap(chatGPTItems.first(where: { $0.name == "prompt" })?.value)
                .contains(replayFile.path)
        )
    }
}
