import Foundation
import XCTest
@testable import CCBuddy

final class ConversationReplayMaterializerFocusedTests: XCTestCase {
    @MainActor
    func testCompressedSelectedConversationMaterializesPrivateJSONLForBothReplayDestinations() async throws {
        let temporary = try HistoryTestSupport.temporaryDirectory("replay-materializer-compressed")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let compressed = temporary.appendingPathComponent("session.jsonl.zstd")
        try Data([0x28, 0xb5, 0x2f, 0xfd]).write(to: compressed)
        let original = Self.session(
            source: .dsh,
            file: compressed,
            text: "normalized compressed message"
        )
        let replayRoot = temporary.appendingPathComponent("replay", isDirectory: true)
        var openedURLs: [URL] = []
        let store = ConversationStore(
            repository: ReplayMaterializationRepository(session: original),
            replayPreparer: ConversationReplayMaterializer(root: replayRoot),
            replayURLLauncher: { url in
                openedURLs.append(url)
                return true
            }
        )

        await store.select(original.metadata)
        await store.replaySelected(in: .claude, language: .english)
        await store.replaySelected(in: .chatGPT, language: .english)

        XCTAssertEqual(openedURLs.count, 2)
        let claude = try XCTUnwrap(
            openedURLs.first(where: { $0.scheme == "claude" })
        )
        let claudeItems = try XCTUnwrap(
            URLComponents(url: claude, resolvingAgainstBaseURL: false)?.queryItems
        )
        let attachmentPaths = claudeItems
            .filter { $0.name == "file" }
            .compactMap(\.value)
        XCTAssertEqual(attachmentPaths.count, 1)
        let attachment = URL(fileURLWithPath: try XCTUnwrap(attachmentPaths.first))

        XCTAssertNotEqual(attachment.standardizedFileURL, compressed.standardizedFileURL)
        XCTAssertEqual(attachment.lastPathComponent, "main.jsonl")
        XCTAssertTrue(attachment.path.hasPrefix(replayRoot.path + "/"))
        XCTAssertEqual(try permissions(of: replayRoot), 0o700)
        XCTAssertEqual(try permissions(of: attachment.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(of: attachment), 0o600)
        try assertReadableJSONL(
            attachment,
            expectedText: "normalized compressed message"
        )

        let chatGPT = try XCTUnwrap(
            openedURLs.first(where: { $0.scheme == "codex" })
        )
        let chatGPTItems = try XCTUnwrap(
            URLComponents(url: chatGPT, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(
            chatGPTItems.first(where: { $0.name == "path" })?.value,
            attachment.deletingLastPathComponent().path
        )
        let prompt = try XCTUnwrap(
            chatGPTItems.first(where: { $0.name == "prompt" })?.value
        )
        XCTAssertTrue(prompt.contains(attachment.path))
        XCTAssertFalse(prompt.contains(compressed.path))
    }

    func testVirtualSQLiteSessionMaterializesMainTranscriptAsParseableJSONL() throws {
        let temporary = try HistoryTestSupport.temporaryDirectory("replay-materializer-sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let database = temporary.appendingPathComponent("history.sqlite")
        try Data("sqlite fixture".utf8).write(to: database)
        let virtualFile = WakeHistoryAdapterSupport.virtualSessionURL(
            database: database,
            nativeID: "conversation-1"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: virtualFile.path))

        let original = Self.session(
            source: .copilot,
            file: virtualFile,
            text: "message from sqlite"
        )
        let replayRoot = temporary.appendingPathComponent("replay", isDirectory: true)
        let prepared = try ConversationReplayMaterializer(root: replayRoot).prepare(original)

        XCTAssertNotEqual(prepared.metadata.file, virtualFile)
        XCTAssertEqual(prepared.metadata.file.lastPathComponent, "main.jsonl")
        XCTAssertTrue(prepared.metadata.file.path.hasPrefix(replayRoot.path + "/"))
        XCTAssertEqual(try permissions(of: replayRoot), 0o700)
        XCTAssertEqual(try permissions(of: prepared.metadata.file.deletingLastPathComponent()), 0o700)
        try assertReadableJSONL(
            prepared.metadata.file,
            expectedText: "message from sqlite"
        )
    }

    func testQoderMaterializesEvenWhenOriginalTranscriptIsOrdinaryReadableJSONL() throws {
        let temporary = try HistoryTestSupport.temporaryDirectory("replay-materializer-qoder")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let originalFile = temporary.appendingPathComponent("ordinary.jsonl")
        try Data(#"{"existing":true}"#.utf8).write(to: originalFile)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: originalFile.path))
        XCTAssertTrue(ForeignHistorySupport.isOrdinaryFile(originalFile))

        let original = Self.session(
            source: .qoder,
            file: originalFile,
            text: "normalized qoder message"
        )
        let prepared = try ConversationReplayMaterializer(
            root: temporary.appendingPathComponent("replay", isDirectory: true)
        ).prepare(original)

        XCTAssertNotEqual(prepared.metadata.file, originalFile)
        try assertReadableJSONL(
            prepared.metadata.file,
            expectedText: "normalized qoder message"
        )
    }

    func testSubagentAttachmentMaterializesAsRealReadableJSONLWithMessages() throws {
        let temporary = try HistoryTestSupport.temporaryDirectory("replay-materializer-subagent")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let database = temporary.appendingPathComponent("sessions.db")
        try Data("sqlite fixture".utf8).write(to: database)
        var original = Self.session(
            source: .copilot,
            file: WakeHistoryAdapterSupport.virtualSessionURL(
                database: database,
                nativeID: "main"
            ),
            text: "main message"
        )
        let virtualSubagentFile = WakeHistoryAdapterSupport.virtualSessionURL(
            database: database,
            nativeID: "subagent"
        )
        original.subagents["worker"] = HistorySubagent(
            agentID: "worker/one",
            file: virtualSubagentFile,
            type: "researcher",
            description: "Focused worker",
            messages: [Self.message("subagent message")]
        )

        let prepared = try ConversationReplayMaterializer(
            root: temporary.appendingPathComponent("replay", isDirectory: true)
        ).prepare(original)
        let subagent = try XCTUnwrap(prepared.subagents["worker"])

        XCTAssertNotEqual(subagent.file, virtualSubagentFile)
        XCTAssertEqual(subagent.file.pathExtension, "jsonl")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: subagent.file.path))
        XCTAssertTrue(ForeignHistorySupport.isOrdinaryFile(subagent.file))
        XCTAssertEqual(ConversationReplayLink.transcriptFiles(in: prepared).count, 2)
        try assertReadableJSONL(subagent.file, expectedText: "subagent message")
    }

    func testMaterializationRejectsSymlinkedAppDataParentWithoutEscaping() throws {
        let temporary = try HistoryTestSupport.temporaryDirectory("replay-materializer-parent-link")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let home = temporary.appendingPathComponent("home", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".ccbud", isDirectory: true),
            withDestinationURL: outside
        )

        let session = Self.session(
            source: .qoder,
            file: temporary.appendingPathComponent("qoder.jsonl"),
            text: "must stay contained"
        )
        let materializer = ConversationReplayMaterializer(
            root: home.appendingPathComponent(".ccbud/replay", isDirectory: true)
        )

        XCTAssertThrowsError(try materializer.prepare(session))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("replay").path
        ))
    }

    func testMaterializationRejectsSymlinkedSessionDirectoryWithoutEscaping() throws {
        let temporary = try HistoryTestSupport.temporaryDirectory("replay-materializer-session-link")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("app/replay", isDirectory: true)
        let session = Self.session(
            source: .qoder,
            file: temporary.appendingPathComponent("qoder.jsonl"),
            text: "must stay contained"
        )
        let materializer = ConversationReplayMaterializer(root: root)
        let first = try materializer.prepare(session)
        let sessionDirectory = first.metadata.file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: sessionDirectory)

        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: sessionDirectory,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try materializer.prepare(session))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("main.jsonl").path
        ))
    }

    private func assertReadableJSONL(_ file: URL, expectedText: String) throws {
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: file.path))
        XCTAssertTrue(ForeignHistorySupport.isOrdinaryFile(file))

        let text = try String(contentsOf: file, encoding: .utf8)
        let records = try text.split(whereSeparator: \.isNewline).map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try XCTUnwrap(object as? [String: Any])
        }
        XCTAssertEqual(records.map { $0["type"] as? String }, ["ccbud_session", "message"])

        let message = try XCTUnwrap(records.last?["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, expectedText)
    }

    private func permissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private static func session(
        source: HistorySource,
        file: URL,
        text: String
    ) -> HistorySession {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return HistorySession(
            metadata: HistorySessionMetadata(
                id: "materializer-\(source.rawValue)",
                file: file,
                source: source,
                dirID: "fixture",
                dirLabel: "Fixture",
                sessionID: "session-\(source.rawValue)",
                cwd: "/tmp/project",
                project: "Fixture",
                title: "Replay fixture",
                autoTitle: "Replay fixture",
                createdAt: date,
                lastActivity: date,
                sizeBytes: 1,
                messageCount: 1
            ),
            messages: [message(text)]
        )
    }

    private static func message(_ text: String) -> HistoryMessage {
        HistoryMessage(role: "user", content: [.init(type: "text", text: text)])
    }
}

private struct ReplayMaterializationRepository: ConversationHistoryProviding {
    let session: HistorySession

    func listProjects(limit: Int) throws -> [HistoryProject] { [] }
    func search(query: String, limit: Int) throws -> [HistorySearchHit] { [] }
    func getSession(file: URL) throws -> HistorySession { session }
}
