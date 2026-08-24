import Foundation
import XCTest
@testable import CCBuddy

final class ConversationResumeServiceTests: XCTestCase {
    func testWakeResumeCommandsIncludeQoderAndOpenCodeV2() {
        XCTAssertEqual(
            ConversationResumeInvocation.make(for: Self.metadata(source: .claude))?.arguments,
            ["--resume", "session-id"]
        )
        XCTAssertEqual(
            ConversationResumeInvocation.make(for: Self.metadata(source: .codex))?.arguments,
            ["resume", "session-id"]
        )
        XCTAssertEqual(
            ConversationResumeInvocation.make(for: Self.metadata(source: .qoder))?.binary,
            "qodercli"
        )
        XCTAssertEqual(
            ConversationResumeInvocation.make(for: Self.metadata(source: .qoder))?.arguments,
            ["--resume", "session-id"]
        )
        var openCode = Self.metadata(source: .opencode)
        openCode.version = "opencode2:2.0.0-beta"
        XCTAssertEqual(ConversationResumeInvocation.make(for: openCode)?.binary, "opencode2")
        XCTAssertEqual(
            ConversationResumeInvocation.make(for: Self.metadata(source: .dsh))?.arguments,
            ["@deepseek-ai/dsh", "web"]
        )
        XCTAssertNil(ConversationResumeInvocation.make(for: Self.metadata(source: .gemini)))

        var imported = Self.metadata(source: .claude)
        imported.imported = true
        XCTAssertNil(ConversationResumeInvocation.make(for: imported))
    }

    func testLatestWakeTerminalRosterAndKookyAvailabilityRules() throws {
        let home = try HistoryTestSupport.temporaryDirectory("resume-terminal-roster")
        defer { try? FileManager.default.removeItem(at: home) }
        for application in ["Terminal", "iTerm", "Warp", "Ghostty", "Kooky"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Applications/\(application).app", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let service = SystemConversationResumeService(homeDirectory: home)

        XCTAssertEqual(
            service.availableTerminals(for: Self.metadata(source: .claude)),
            [.terminal, .kooky, .iTerm, .warp, .ghostty]
        )
        XCTAssertEqual(
            service.availableTerminals(for: Self.metadata(source: .kiro)),
            [.kooky],
            "Kiro has no shell resume command but Kooky owns its deep link"
        )
        XCTAssertEqual(
            service.availableTerminals(for: Self.metadata(source: .gemini)),
            [.kooky]
        )
        XCTAssertEqual(
            service.availableTerminals(for: Self.metadata(source: .qoder)),
            [.terminal, .iTerm, .warp, .ghostty],
            "Qoder is not in Kooky's deep-link roster"
        )

        let kookyCLI = home.appendingPathComponent(
            "Library/Application Support/kooky/bin/kooky-cli"
        )
        try FileManager.default.createDirectory(
            at: kookyCLI.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: kookyCLI)
        XCTAssertEqual(
            service.availableTerminals(for: Self.metadata(source: .qoder)),
            [.terminal, .kooky, .iTerm, .warp, .ghostty],
            "kooky-cli command injection preserves CCBuddy's Qoder advantage"
        )

        var imported = Self.metadata(source: .claude)
        imported.imported = true
        XCTAssertTrue(service.availableTerminals(for: imported).isEmpty)
    }

    func testKookyDeepLinkMapsClaudeCodeAndValidatesNativeSessionID() throws {
        let cwd = "/tmp/My Project"
        let claude = try XCTUnwrap(ConversationTerminalLaunchSupport.kookyDeepLink(
            for: Self.metadata(source: .claude),
            workingDirectory: cwd
        ))
        let items = try XCTUnwrap(
            URLComponents(url: claude, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(claude.scheme, "kooky")
        XCTAssertEqual(claude.host, "resume")
        XCTAssertEqual(items.first { $0.name == "agent" }?.value, "claude-code")
        XCTAssertEqual(items.first { $0.name == "id" }?.value, "session-id")
        XCTAssertEqual(items.first { $0.name == "cwd" }?.value, cwd)

        var invalid = Self.metadata(source: .kiro)
        invalid.sessionID = "bad/session"
        XCTAssertNil(ConversationTerminalLaunchSupport.kookyDeepLink(
            for: invalid,
            workingDirectory: nil
        ))
        XCTAssertNil(ConversationTerminalLaunchSupport.kookyDeepLink(
            for: Self.metadata(source: .qoder),
            workingDirectory: nil
        ))
    }

    func testWarpAndGhosttyLaunchPayloadsMatchWake() throws {
        let command = "cd '/tmp/My Project' && qodercli --resume session-id"
        let warp = try XCTUnwrap(
            ConversationTerminalLaunchSupport.warpConfiguration(command: command)
        )
        XCTAssertTrue(warp.contains("name: CC Buddy Resume"))
        XCTAssertTrue(warp.contains("- exec: |-\n                \(command)"))
        XCTAssertNil(ConversationTerminalLaunchSupport.warpConfiguration(
            command: "first\nsecond"
        ))
        XCTAssertEqual(
            ConversationTerminalLaunchSupport.ghosttyArguments(command: command),
            [
                "-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lic",
                "\(command); exec /bin/zsh -il",
            ]
        )
    }

    func testResumeCommandUsesSafePOSIXQuoting() {
        let invocation = ConversationResumeInvocation(
            binary: "qodercli",
            arguments: ["--resume", "id with ' quote"],
            requiresWorkingDirectory: false
        )

        XCTAssertEqual(
            invocation.command(workingDirectory: "/tmp/My Project"),
            "cd '/tmp/My Project' && qodercli --resume 'id with '\\'' quote'"
        )
    }

    func testMissingCLIFallbackOmitsStaleWorkingDirectoryForCodexAndQoder() throws {
        let home = try HistoryTestSupport.temporaryDirectory("resume-stale-cwd")
        defer { try? FileManager.default.removeItem(at: home) }
        let staleDirectory = home.appendingPathComponent("project-that-no-longer-exists")
        let service = SystemConversationResumeService(
            homeDirectory: home,
            cliResolver: { _ in nil }
        )

        for (source, expected) in [
            (HistorySource.codex, "codex resume session-id"),
            (HistorySource.qoder, "qodercli --resume session-id"),
        ] {
            var metadata = Self.metadata(source: source)
            metadata.cwd = staleDirectory.path

            let outcome = service.resume(metadata, in: .terminal)

            XCTAssertFalse(outcome.opened)
            XCTAssertEqual(outcome.command, expected)
            XCTAssertFalse(outcome.command.contains(staleDirectory.path))
            XCTAssertTrue(outcome.error?.contains("未找到命令") == true)
        }
    }

    func testRequiredWorkingDirectoryStillReportsMissingProjectExplicitly() throws {
        let home = try HistoryTestSupport.temporaryDirectory("resume-required-cwd")
        defer { try? FileManager.default.removeItem(at: home) }
        let staleDirectory = home.appendingPathComponent("project-that-no-longer-exists")
        let service = SystemConversationResumeService(
            homeDirectory: home,
            cliResolver: { _ in nil }
        )

        for source in [HistorySource.claude, .dsh] {
            var metadata = Self.metadata(source: source)
            metadata.cwd = staleDirectory.path

            let outcome = service.resume(metadata, in: .terminal)

            XCTAssertFalse(outcome.opened)
            XCTAssertTrue(outcome.error?.contains("项目目录已不存在") == true)
            XCTAssertFalse(outcome.command.contains(staleDirectory.path))
        }
    }

    @MainActor
    func testLaunchFailureCopiesRunnableCommand() async {
        let metadata = Self.metadata(source: .qoder)
        let session = HistorySession(
            metadata: metadata,
            messages: [HistoryMessage(
                role: "user",
                content: [.init(type: "text", text: "hello")]
            )]
        )
        let copier = RecordingStringCopier()
        let store = ConversationStore(
            repository: ResumeHistoryProvider(session: session),
            resumeService: FailingConversationResumeService(),
            commandCopier: copier.copy,
            pollIntervalNanoseconds: UInt64.max
        )
        await store.select(metadata)

        await store.resumeSelected(in: .terminal)

        XCTAssertEqual(copier.values, ["qodercli --resume session-id"])
        XCTAssertEqual(
            store.actionMessage,
            "automation denied；命令已复制，可粘贴到终端运行"
        )
        XCTAssertTrue(store.actionIsError)
    }

    @MainActor
    func testLaunchFailureShowsCommandWhenClipboardWriteFails() async {
        let metadata = Self.metadata(source: .qoder)
        let session = HistorySession(
            metadata: metadata,
            messages: [HistoryMessage(
                role: "user",
                content: [.init(type: "text", text: "hello")]
            )]
        )
        let copier = RecordingStringCopier(succeeds: false)
        let store = ConversationStore(
            repository: ResumeHistoryProvider(session: session),
            resumeService: FailingConversationResumeService(),
            commandCopier: copier.copy,
            pollIntervalNanoseconds: UInt64.max
        )
        await store.select(metadata)

        await store.resumeSelected(in: .terminal)

        XCTAssertEqual(copier.values, ["qodercli --resume session-id"])
        XCTAssertEqual(
            store.actionMessage,
            "automation denied；请手动运行：qodercli --resume session-id"
        )
        XCTAssertTrue(store.actionIsError)
    }

    @MainActor
    func testKiroCanResumeThroughKookyWithoutShellInvocation() async throws {
        let home = try HistoryTestSupport.temporaryDirectory("resume-kiro-kooky")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Applications/Kooky.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        let metadata = Self.metadata(source: .kiro)
        let session = HistorySession(metadata: metadata, messages: [])
        let store = ConversationStore(
            repository: ResumeHistoryProvider(session: session),
            resumeService: SystemConversationResumeService(homeDirectory: home),
            pollIntervalNanoseconds: UInt64.max
        )

        await store.select(metadata)

        XCTAssertTrue(store.canResumeSelected)
        XCTAssertEqual(store.availableResumeTerminals, [.kooky])
    }

    private static func metadata(source: HistorySource) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "\(source.rawValue):session-id",
            file: URL(fileURLWithPath: "/tmp/session.jsonl"),
            source: source,
            dirID: "all",
            dirLabel: "Local",
            sessionID: "session-id",
            cwd: nil,
            project: "Project",
            title: "Resume",
            autoTitle: "Resume",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
            sizeBytes: 1,
            messageCount: 1
        )
    }
}

private struct ResumeHistoryProvider: ConversationHistoryProviding {
    let session: HistorySession

    func listProjects(limit: Int) throws -> [HistoryProject] { [] }
    func search(query: String, limit: Int) throws -> [HistorySearchHit] { [] }
    func getSession(file: URL) throws -> HistorySession { session }
}

private struct FailingConversationResumeService: ConversationResuming {
    func availableTerminals(for metadata: HistorySessionMetadata) -> [ConversationTerminal] {
        [.terminal]
    }

    func resume(
        _ metadata: HistorySessionMetadata,
        in terminal: ConversationTerminal
    ) -> ConversationResumeOutcome {
        .init(
            opened: false,
            command: "qodercli --resume \(metadata.sessionID)",
            error: "automation denied"
        )
    }
}

private final class RecordingStringCopier: @unchecked Sendable {
    private let lock = NSLock()
    private let succeeds: Bool
    private var storage: [String] = []

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func copy(_ value: String) -> Bool {
        lock.lock()
        storage.append(value)
        lock.unlock()
        return succeeds
    }
}
