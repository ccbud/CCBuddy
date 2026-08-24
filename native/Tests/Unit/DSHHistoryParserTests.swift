import Foundation
import XCTest
@testable import CCBuddy

final class DSHHistoryParserTests: XCTestCase {
    func testCanonicalCompressedParentCoversAdapterNormalizeExportAndReplay() throws {
        let root = try HistoryTestSupport.temporaryDirectory("dsh-contract")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = home.appendingPathComponent(".dsh/sessions", isDirectory: true)
        let project = sessions.appendingPathComponent("scanner", isDirectory: true)
        let parent = project.appendingPathComponent("parent", isDirectory: true)
        let transcript = parent.appendingPathComponent("session.jsonl.zstd")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Self.normalizedCompressedTranscript.write(to: transcript)

        let originSubagent = project
            .appendingPathComponent("origin-subagent", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session","id":"dsh-child-origin","cwd":"/tmp/dsh-project","createdAt":"2026-08-10T01:00:00.000Z","origin":"subagent","delegationDepth":0}"#,
            #"{"type":"user/message","data":{"content":"hidden child"}}"#,
        ], to: originSubagent)
        let delegatedSubagent = project
            .appendingPathComponent("delegated-subagent", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session","id":"dsh-child-depth","cwd":"/tmp/dsh-project","createdAt":"2026-08-10T01:00:00.000Z","origin":"user","delegationDepth":1}"#,
            #"{"type":"user/message","data":{"content":"hidden delegated child"}}"#,
        ], to: delegatedSubagent)

        let imports = home.appendingPathComponent(".ccbud/imports", isDirectory: true)
        let configuration = HistoryConfiguration(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports
        )
        let adapter = DSHConversationSourceAdapter()
        let candidates = adapter.discover(configuration: configuration, activeOnly: true)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1, "DSH subagents must not become top-level sessions")
        XCTAssertEqual(
            candidate.file.resolvingSymlinksInPath(),
            transcript.resolvingSymlinksInPath()
        )
        XCTAssertEqual(candidate.nativeID, "dsh-parent")
        XCTAssertEqual(candidate.projectDirectoryName, "scanner")
        XCTAssertEqual(candidate.directory.id, "__wake_dsh__")
        XCTAssertEqual(adapter.watchRoots(configuration: configuration), [
            sessions.standardizedFileURL,
        ])

        let dependencies = adapter.dependencies(for: candidate, configuration: configuration)
        XCTAssertEqual(Set(dependencies.map(\.role)), [.primaryTranscript, .customMetadata])
        XCTAssertTrue(dependencies.contains {
            $0.file == transcript.standardizedFileURL && $0.role == .primaryTranscript
        })
        XCTAssertTrue(dependencies.contains {
            $0.file == configuration.appDataRoot.appendingPathComponent("agent-meta.json")
                .standardizedFileURL && $0.role == .customMetadata
        })

        let loader = HistorySessionLoader(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports
        )
        let registered = loader.discoverCandidates().filter { $0.formatHint == .dsh }
        XCTAssertEqual(registered, candidates, "The standard registry must expose canonical DSH")
        let loaded = try loader.load(candidate, consistency: .bestEffort)
        let session = loaded.session

        XCTAssertEqual(session.metadata.source, .dsh)
        XCTAssertEqual(session.metadata.id, "dsh:dsh-parent")
        XCTAssertEqual(session.metadata.sessionID, "dsh-parent")
        XCTAssertEqual(session.metadata.cwd, "/tmp/dsh-project")
        XCTAssertEqual(session.metadata.project, "dsh-project")
        XCTAssertEqual(session.metadata.title, "DSH scanner audit")
        XCTAssertEqual(session.metadata.model, "deepseek-v3")
        XCTAssertEqual(session.metadata.messageCount, 2)
        XCTAssertEqual(session.metadata.diagnostics, .init(decodedLines: 5, malformedLines: 0))
        XCTAssertEqual(session.metadata.totals, HistoryTotals(
            inputTokens: 101,
            outputTokens: 27,
            cacheRead: 7,
            cacheCreation: 3,
            turns: 1
        ))
        XCTAssertEqual(session.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(session.messages[0].content.first?.text, "DSH inspect the scanner")
        let assistant = session.messages[1]
        XCTAssertEqual(assistant.modelActual, "deepseek-v3")
        XCTAssertEqual(assistant.usage, HistoryUsage(
            inputTokens: 101,
            outputTokens: 27,
            cacheRead: 7,
            cacheCreation: 3
        ))
        XCTAssertEqual(assistant.content.map(\.type), [
            "thinking", "tool_use", "text", "tool_result",
        ])
        XCTAssertEqual(assistant.content[0].thinking, "Inspect lifecycle")
        XCTAssertEqual(assistant.content[1].id, "dsh-call-1")
        XCTAssertEqual(assistant.content[1].name, "shell")
        XCTAssertEqual(
            assistant.content[1].input?["command"]?.stringValue,
            "rg useEffect src/"
        )
        XCTAssertEqual(assistant.content[2].text, "Checking now")
        XCTAssertEqual(assistant.content[3].toolUseID, "dsh-call-1")
        XCTAssertEqual(assistant.content[3].isError, false)
        XCTAssertEqual(
            HistoryParsingSupport.searchableToolResult(assistant.content[3].content),
            "src/QrScanner.tsx"
        )

        let mutations = ConversationMutationService(configuration: .init(
            historyDirs: [],
            homeDirectory: home,
            importsRoot: imports
        ))
        XCTAssertEqual(
            try mutations.suggestedRawFileExtension(for: session.metadata),
            "jsonl.zstd"
        )
        let rawExport = root.appendingPathComponent("dsh-export.jsonl.zstd")
        let rawResult = try mutations.exportRaw(session.metadata, to: rawExport)
        XCTAssertFalse(rawResult.bundled)
        XCTAssertEqual(rawResult.fileExtension, "jsonl.zstd")
        XCTAssertEqual(try Data(contentsOf: rawExport), Self.normalizedCompressedTranscript)

        let prepared = try ConversationReplayMaterializer(
            root: root.appendingPathComponent("replay", isDirectory: true)
        ).prepare(session)
        XCTAssertNotEqual(prepared.metadata.file, transcript)
        XCTAssertEqual(prepared.metadata.file.pathExtension, "jsonl")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: prepared.metadata.file.path))
        XCTAssertTrue(
            try String(contentsOf: prepared.metadata.file, encoding: .utf8)
                .contains("DSH inspect the scanner")
        )
        let claude = try XCTUnwrap(ConversationReplayLink.makeURL(
            destination: .claude,
            session: prepared,
            language: .english
        ))
        let claudeFiles = URLComponents(url: claude, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "file" }.compactMap(\.value)
        XCTAssertEqual(claudeFiles, [prepared.metadata.file.path])
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
            prepared.metadata.file.deletingLastPathComponent().path
        )
        let prompt = try XCTUnwrap(
            chatGPTItems.first(where: { $0.name == "prompt" })?.value
        )
        XCTAssertTrue(prompt.contains(prepared.metadata.file.path))
        XCTAssertFalse(prompt.contains(transcript.path))
    }

    func testBundledDecoderReadsConcatenatedFramesAndKeepsValidTornPrefix() throws {
        let root = try HistoryTestSupport.temporaryDirectory("dsh-zstd")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl.zstd")

        let complete = Data(Self.concatenatedFrames)
        try complete.write(to: file)
        let header = try XCTUnwrap(DSHZstdDecoder.headerRecord(from: file))
        XCTAssertEqual(header["id"]?.stringValue, "dsh-main")

        let document = try DSHZstdDecoder.document(from: file)
        XCTAssertEqual(document.records.map { $0["type"]?.stringValue }, [
            "session", "user/message", "assistant/message",
        ])
        XCTAssertEqual(document.diagnostics.malformedLines, 0)

        // DSH appends independent frames. Dropping the end of the active frame models a scan that
        // races the writer; the completed header and user record must remain available.
        try Data(complete.dropLast(4)).write(to: file)
        let torn = try DSHZstdDecoder.document(from: file)
        XCTAssertEqual(torn.records.prefix(2).map { $0["type"]?.stringValue }, [
            "session", "user/message",
        ])
        XCTAssertEqual(
            torn.records.dropFirst().first?["data"]?["content"]?.stringValue,
            "dsh valid prefix"
        )
        XCTAssertEqual(torn.diagnostics.malformedLines, 1)
    }

    /// Two zstd frames generated from the header and body independently, matching DSH's append
    /// layout. Keeping the fixture inline makes the test independent of Homebrew or a `zstd` CLI.
    private static let concatenatedFrames: [UInt8] = [
        0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x6e, 0xfd, 0x02, 0x00, 0xa2, 0x05, 0x14,
        0x1a, 0x80, 0xa9, 0x6d, 0xf8, 0x46, 0x94, 0xed, 0x34, 0x6b, 0x0a, 0x05,
        0x79, 0x6a, 0x81, 0xe2, 0x68, 0x23, 0x8a, 0x8c, 0x89, 0xbe, 0x74, 0x83,
        0x1a, 0xf7, 0x04, 0x80, 0xc6, 0x39, 0xab, 0x5d, 0x37, 0x24, 0x4a, 0x6e,
        0x3a, 0x1c, 0x71, 0xb4, 0x59, 0x29, 0x9a, 0x85, 0xac, 0x51, 0x1c, 0xb6,
        0x83, 0x04, 0x84, 0x01, 0x3a, 0x6f, 0x01, 0xbf, 0xe9, 0xcb, 0x91, 0x09,
        0x09, 0x28, 0x45, 0x9f, 0x31, 0x6d, 0xe7, 0x96, 0x27, 0x6c, 0x4e, 0x94,
        0x54, 0xbd, 0xfa, 0xfc, 0xb5, 0x58, 0x33, 0x02, 0x04, 0x00, 0x4e, 0x05,
        0x12, 0x97, 0xcb, 0x4f, 0x5b, 0xda, 0x96, 0x26, 0x1e, 0xc4, 0x1c, 0xa5,
        0x28, 0xb5, 0x2f, 0xfd, 0x24, 0xff, 0x9d, 0x04, 0x00, 0xd2, 0x08, 0x1c,
        0x1c, 0x70, 0xb5, 0xea, 0xc4, 0x9a, 0x74, 0x13, 0xcf, 0x72, 0x4c, 0x28,
        0xab, 0x5b, 0xb4, 0x95, 0x5e, 0x55, 0x4d, 0x2b, 0xb1, 0x1c, 0x51, 0x8d,
        0x17, 0x51, 0x3d, 0xe2, 0x10, 0xc4, 0xee, 0x02, 0xac, 0xef, 0x4a, 0x62,
        0xc3, 0xc4, 0x4b, 0xa5, 0xeb, 0x61, 0xf9, 0xf3, 0xf9, 0xcf, 0xcb, 0xcc,
        0xcf, 0x69, 0x06, 0xda, 0x98, 0x26, 0x66, 0x32, 0x62, 0xd7, 0x12, 0x26,
        0x87, 0x9e, 0xe2, 0x90, 0x61, 0x02, 0x85, 0x92, 0xe7, 0x65, 0x6d, 0xd7,
        0xe6, 0x20, 0x36, 0xd6, 0xd7, 0x70, 0x39, 0x02, 0x45, 0x4e, 0x7a, 0x5a,
        0x66, 0xca, 0xce, 0x86, 0x52, 0x4a, 0x1d, 0x04, 0x43, 0xe1, 0x58, 0x7e,
        0x83, 0x6a, 0xc3, 0x0f, 0x60, 0x99, 0x6f, 0x04, 0xd0, 0x33, 0xf2, 0xf2,
        0x9f, 0x01, 0xf5, 0x14, 0x0c, 0x00, 0xaa, 0x00, 0x54, 0x0b, 0x04, 0x47,
        0x71, 0x11, 0xec, 0xd8, 0x3f, 0x1c, 0x50, 0x8a, 0x00, 0x38, 0x2e, 0x1d,
        0xf6, 0xe8, 0x0d, 0xfd, 0x80, 0x90, 0x44, 0x8b, 0xad, 0xc3, 0x2a, 0x4f,
        0xe6, 0xa9, 0xfe, 0x9e,
    ]

    private static let normalizedCompressedTranscript = Data(base64Encoded:
        "KLUv/QRYzQ4Adt1VJCBPrANQv1rB2xIVTmRDEMfOomukCzoI6FcWAb44VDQIgAFM" +
        "A0kASABMAAlRvtZm4bqrz+Xo7PE1b8qrS6y1AtZiazFmQSxGMVgKQWM1zt4Hblt3" +
        "tq2Qc4GeXs7uLtrVO+5USHHYnd29q0f5mJfPvlBGXwrscJ18JNboqM2PWafJxRe" +
        "5xL5tRpKvKKbPjVEbJ+t00m0hji9ZeEg4U2+M7Qn2jttRtkvs2uqYfV5ffRtl3m" +
        "eZyxHAtNidhjYyJk18kbYOwvTH0iYn3RYCUViOkmb+wf5wUZ9Htj+ks3PHfaJm6" +
        "jqs8eqMAqE2CLUpUMpW0xe2jLaQBxma+KJk3ammOyyUyC5Du+4BANP0fi7SRAD26" +
        "4ViWoYKYZ9yTgV+GNwBD7NhaZMZIFQEKKWjYcQ7FyhlO7bfjChwug7rNG1XA6rR" +
        "6EheMYth57gRCdERFN8lFl1NFNMvAjEgQEKCEOUd9MgAcAfUDGDkZuRq6N2gmlu" +
        "FekkgBkuxA3wUwKJBzBDOumFFC4ZKcAoDjtwiMd6qh6HIuyxOJBcEoHMPTBuVdVk" +
        "ZjvW1T5POYaWd1HMJs1CnWUjdjqZoeynizRsidwhyOERMF3tFxdBDxYIQQ35QGFWR" +
        "dRq25VAyFbry"
    )!
}
