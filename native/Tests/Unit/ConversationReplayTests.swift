import Foundation
import XCTest
@testable import CCBuddy

@MainActor
final class ConversationReplayTests: XCTestCase {
    func testClaudeLinkAttachesMainAndSortedUniqueSubagentTranscripts() throws {
        let session = Self.fixtureSession()

        let url = try XCTUnwrap(
            ConversationReplayLink.makeURL(destination: .claude, session: session)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "claude")
        XCTAssertEqual(components.host, "cowork")
        XCTAssertEqual(components.path, "/new")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "q" })?.value,
            ConversationReplayLink.prompt(for: .claude, language: .simplifiedChinese)
        )
        XCTAssertEqual(
            components.queryItems?.filter { $0.name == "file" }.compactMap(\.value),
            [
                "/tmp/Replay & Review/main session.jsonl",
                "/tmp/Replay & Review/main session/subagents/agent-a.jsonl",
                "/tmp/Replay & Review/main session/subagents/agent-z.jsonl",
            ]
        )
    }

    func testChatGPTLinkUsesTranscriptWorkspaceAndListsEveryFile() throws {
        let session = Self.fixtureSession()

        let url = try XCTUnwrap(
            ConversationReplayLink.makeURL(destination: .chatGPT, session: session)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )

        XCTAssertEqual(components.scheme, "codex")
        XCTAssertEqual(components.host, "new")
        XCTAssertEqual(query["path"], "/tmp/Replay & Review")
        XCTAssertTrue(query["prompt"]?.contains(
            ConversationReplayLink.prompt(for: .chatGPT, language: .simplifiedChinese)
        ) == true)
        for file in ConversationReplayLink.transcriptFiles(in: session) {
            XCTAssertTrue(query["prompt"]?.contains(file.path) == true, "Missing \(file.path)")
        }
    }

    func testReplayPromptsFollowTheConfiguredLanguageAndPreserveFilePaths() throws {
        let session = Self.fixtureSession()
        let claudeURL = try XCTUnwrap(ConversationReplayLink.makeURL(
            destination: .claude,
            session: session,
            language: .english
        ))
        let claudeQuery = try XCTUnwrap(
            URLComponents(url: claudeURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(
            claudeQuery.first(where: { $0.name == "q" })?.value,
            ConversationReplayLink.prompt(for: .claude, language: .english)
        )
        XCTAssertTrue(
            ConversationReplayLink.prompt(for: .claude, language: .english)
                .hasPrefix("Attached are the JSONL transcripts")
        )

        let chatGPTURL = try XCTUnwrap(ConversationReplayLink.makeURL(
            destination: .chatGPT,
            session: session,
            language: .japanese
        ))
        let chatGPTPrompt = try XCTUnwrap(
            URLComponents(url: chatGPTURL, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "prompt" })?.value
        )
        XCTAssertTrue(chatGPTPrompt.contains(
            ConversationReplayLink.prompt(for: .chatGPT, language: .japanese)
        ))
        XCTAssertTrue(chatGPTPrompt.contains("/tmp/Replay & Review/main session.jsonl"))
    }

    func testStoreLaunchesReplayAndReportsSuccessOrFailure() async {
        let session = Self.fixtureSession()
        var opened: [URL] = []
        let successfulStore = ConversationStore(
            repository: ReplayRepository(session: session),
            fileInspector: ReplayFileInspector(date: session.metadata.lastActivity),
            replayURLLauncher: { url in
                opened.append(url)
                return true
            }
        )

        await successfulStore.select(session.metadata)
        await successfulStore.replaySelected(in: .claude)

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.scheme, "claude")
        XCTAssertEqual(successfulStore.actionMessage, "已在 Claude 中打开会话记录")
        XCTAssertFalse(successfulStore.actionIsError)

        let failingStore = ConversationStore(
            repository: ReplayRepository(session: session),
            fileInspector: ReplayFileInspector(date: session.metadata.lastActivity),
            replayURLLauncher: { _ in false }
        )
        await failingStore.select(session.metadata)
        await failingStore.replaySelected(in: .chatGPT)

        XCTAssertEqual(
            failingStore.actionMessage,
            "无法打开 ChatGPT，请确认已安装桌面应用"
        )
        XCTAssertTrue(failingStore.actionIsError)
    }

    private static func fixtureSession() -> HistorySession {
        let main = URL(fileURLWithPath: "/tmp/Replay & Review/main session.jsonl")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var session = HistorySession(
            metadata: HistorySessionMetadata(
                id: "replay",
                file: main,
                source: .claude,
                dirID: "fixture",
                dirLabel: "Fixture",
                sessionID: "replay",
                cwd: "/tmp/Replay & Review",
                project: "Replay",
                title: "Replay",
                autoTitle: "Replay",
                createdAt: date,
                lastActivity: date,
                sizeBytes: 100,
                messageCount: 1
            ),
            messages: [HistoryMessage(role: "user", content: [.init(type: "text", text: "Review")])]
        )
        session.subagents = [
            "z": HistorySubagent(
                agentID: "z",
                file: URL(fileURLWithPath: "/tmp/Replay & Review/main session/subagents/agent-z.jsonl")
            ),
            "a": HistorySubagent(
                agentID: "a",
                file: URL(fileURLWithPath: "/tmp/Replay & Review/main session/subagents/agent-a.jsonl")
            ),
            "duplicate": HistorySubagent(agentID: "duplicate", file: main),
        ]
        return session
    }
}

private struct ReplayRepository: ConversationHistoryProviding {
    let session: HistorySession

    func listProjects(limit: Int) throws -> [HistoryProject] { [] }
    func search(query: String, limit: Int) throws -> [HistorySearchHit] { [] }
    func getSession(file: URL) throws -> HistorySession { session }
}

private struct ReplayFileInspector: ConversationFileInspecting {
    let date: Date?

    func modificationDate(for file: URL) throws -> Date? { date }
}
