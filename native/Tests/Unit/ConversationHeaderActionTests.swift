import Foundation
import XCTest

@testable import CCBuddy

/// Every action the session header offers, exercised end to end through the store.
///
/// The header's three named actions had all stopped working at once, and none of them had a test:
/// each was a button wired to a method nothing ever called outside the app. A silent no-op and a
/// completed action look identical from the outside, so each case here asserts on the notice the
/// user is shown as well as on the effect — an action that succeeds quietly is still a bug.
@MainActor
final class ConversationHeaderActionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Continue in terminal

    func testAnAgentWithNoRelaunchFlagSaysSoRatherThanOfferingTheButton() {
        XCTAssertFalse(ConversationResume.isSupported(.qoder))
        XCTAssertTrue(ConversationResume.isSupported(.claude))
        XCTAssertTrue(ConversationResume.isSupported(.codex))

        let outcome = ConversationResume.resume(metadata: metadata(source: .qoder))

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.message.contains("还不支持"))
    }

    /// Claude resolves `--resume` against the project, so launching from anywhere else silently
    /// starts a new conversation. The command is put on the clipboard rather than run blind.
    func testAMissingProjectDirectoryCopiesTheCommandInsteadOfLaunching() {
        var copied: [String] = []
        let gone = root.appendingPathComponent("deleted-project").path

        let outcome = ConversationResume.resume(
            metadata: metadata(source: .claude, cwd: gone),
            clipboard: { copied.append($0) }
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(copied.first?.contains("--resume") == true)
        XCTAssertTrue(outcome.message.contains(gone))
    }

    func testTheComposedCommandEntersTheProjectBeforeResuming() throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let dialect = try XCTUnwrap(ConversationResume.dialect(for: .claude, sessionID: "abc"))
        let command = ConversationResume.composeCommand(
            binary: "/opt/homebrew/bin/claude",
            arguments: dialect.arguments,
            workingDirectory: project.path
        )

        XCTAssertEqual(
            command,
            "cd '\(project.path)' && '/opt/homebrew/bin/claude' '--resume' 'abc'"
        )
    }

    // MARK: - Analysis

    func testBothAnalysisDestinationsProduceALinkTheInstalledAppsAccept() async {
        var opened: [URL] = []
        let store = makeStore(replayURLLauncher: { opened.append($0); return true })
        await store.select(session().metadata)

        store.replaySelected(in: .claude)
        store.replaySelected(in: .chatGPT)

        XCTAssertEqual(opened.count, 2)
        let claude = try? XCTUnwrap(URLComponents(url: opened[0], resolvingAgainstBaseURL: false))
        XCTAssertEqual(claude?.scheme, "claude")
        XCTAssertEqual(claude?.host, "cowork")
        XCTAssertEqual(claude?.path, "/new")
        XCTAssertEqual(claude?.queryItems?.first(where: { $0.name == "src" })?.value, "external")

        let chatGPT = try? XCTUnwrap(URLComponents(url: opened[1], resolvingAgainstBaseURL: false))
        XCTAssertEqual(chatGPT?.scheme, "codex")
        XCTAssertEqual(chatGPT?.host, "new")
        XCTAssertNotNil(chatGPT?.queryItems?.first(where: { $0.name == "prompt" })?.value)
        XCTAssertEqual(store.actionMessage, "已在 ChatGPT 中打开会话记录")
        XCTAssertFalse(store.actionIsError)
    }

    func testAnAnalysisActionWithNothingSelectedChangesNothing() {
        var opened: [URL] = []
        let store = makeStore(replayURLLauncher: { opened.append($0); return true })

        store.replaySelected(in: .claude)
        store.copyReplayPrompt(for: .claude)

        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(store.actionMessage)
    }

    // MARK: - Star, pin and title

    func testStarringAndPinningWriteThePatchAndReportIt() async {
        let mutations = RecordingMutations()
        let store = makeStore(mutations: mutations)
        await store.select(session().metadata)

        await store.toggleStarSelected()
        XCTAssertEqual(mutations.patches.last?.starred, true)
        XCTAssertEqual(store.actionMessage, "已收藏会话")

        await store.togglePinSelected()
        XCTAssertEqual(mutations.patches.last?.pinned, true)
        XCTAssertEqual(store.actionMessage, "已置顶会话")
        XCTAssertFalse(store.actionIsError)
    }

    func testEditingTheTitleAndTagsReportsFailureRatherThanLosingIt() async {
        let mutations = RecordingMutations()
        mutations.failure = ActionFailure()
        let store = makeStore(mutations: mutations)
        await store.select(session().metadata)

        await store.updateSelectedMetadata(title: "复盘", tags: ["release"])

        XCTAssertTrue(store.actionIsError)
        XCTAssertEqual(store.actionMessage?.hasPrefix("更新失败："), true)
    }

    func testEditingTheTitleAndTagsPassesBothThrough() async {
        let mutations = RecordingMutations()
        let store = makeStore(mutations: mutations)
        await store.select(session().metadata)

        await store.updateSelectedMetadata(title: "复盘", tags: ["release", "codex"])

        XCTAssertEqual(mutations.patches.last?.title, "复盘")
        XCTAssertEqual(mutations.patches.last?.tags, ["release", "codex"])
        XCTAssertEqual(store.actionMessage, "标题与标签已更新")
    }

    // MARK: - The file itself

    func testCopyingThePathCopiesTheTranscriptThatIsOpen() async {
        var copied: [String] = []
        let store = makeStore(pathCopier: { copied.append($0) })
        await store.select(session().metadata)

        store.copySelectedPath()

        XCTAssertEqual(copied, [transcript.path])
        XCTAssertEqual(store.actionMessage, "已复制会话路径")
    }

    func testExportingRawAndHTMLBothReportWhatTheyWrote() async {
        let store = makeStore()
        await store.select(session().metadata)

        await store.exportSelectedRaw(to: root.appendingPathComponent("out.jsonl"))
        XCTAssertEqual(store.actionMessage, "已导出原始会话")
        XCTAssertFalse(store.actionIsError)

        await store.exportSelectedHTML(to: root.appendingPathComponent("out.html"))
        XCTAssertEqual(store.actionMessage, "已导出独立 HTML")
        XCTAssertFalse(store.actionIsError)
    }

    // MARK: - Trash

    func testTrashingRestoringAndPermanentDeletionEachReportTheirOutcome() async {
        let mutations = RecordingMutations()
        let store = makeStore(mutations: mutations)

        await store.select(session().metadata)
        await store.softDeleteSelected()
        XCTAssertEqual(mutations.softDeleted.count, 1)
        XCTAssertEqual(store.actionMessage, "会话已移入回收站")

        await store.select(session().metadata)
        await store.restoreSelected()
        XCTAssertEqual(mutations.restored.count, 1)
        XCTAssertEqual(store.actionMessage, "会话已恢复")

        await store.select(session().metadata)
        await store.permanentlyDeleteSelected()
        XCTAssertEqual(mutations.permanentlyDeleted.count, 1)
        XCTAssertEqual(store.actionMessage, "会话已永久删除")
    }

    func testTheOverflowIsTheOnlyWayToDeletePermanentlyAndItAsksTheServiceFirst() async {
        let mutations = RecordingMutations()
        mutations.allowsPermanentDelete = false
        let store = makeStore(mutations: mutations)
        await store.select(session().metadata)

        XCTAssertFalse(store.canPermanentlyDeleteSelected)
    }

    // MARK: - Fixtures

    private var transcript: URL { root.appendingPathComponent("session.jsonl") }

    private func metadata(
        source: HistorySource = .codex,
        cwd: String? = nil
    ) -> HistorySessionMetadata {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return HistorySessionMetadata(
            id: "actions",
            file: transcript,
            source: source,
            dirID: "fixture",
            dirLabel: "Fixture",
            sessionID: "session-id",
            cwd: cwd ?? root.path,
            project: "Fixture",
            title: "Header actions",
            autoTitle: "Header actions",
            createdAt: date,
            lastActivity: date,
            sizeBytes: 64,
            messageCount: 1
        )
    }

    private func session() -> HistorySession {
        HistorySession(
            metadata: metadata(),
            messages: [HistoryMessage(role: "user", content: [.init(type: "text", text: "hi")])]
        )
    }

    private func makeStore(
        mutations: RecordingMutations = RecordingMutations(),
        pathCopier: @escaping (String) -> Void = { _ in },
        replayURLLauncher: @escaping (URL) -> Bool = { _ in true }
    ) -> ConversationStore {
        ConversationStore(
            repository: ActionRepository(session: session()),
            mutationService: mutations,
            htmlExporter: StubHTMLExporter(),
            fileInspector: ActionFileInspector(),
            pathCopier: pathCopier,
            replayURLLauncher: replayURLLauncher
        )
    }
}

private struct ActionFailure: Error {}

private final class RecordingMutations: ConversationMutating, @unchecked Sendable {
    var patches: [ConversationMetadataPatch] = []
    var softDeleted: [URL] = []
    var restored: [URL] = []
    var permanentlyDeleted: [URL] = []
    var allowsPermanentDelete = true
    var failure: Error?

    func updateMetadata(for metadata: HistorySessionMetadata, patch: ConversationMetadataPatch) throws {
        if let failure { throw failure }
        patches.append(patch)
    }

    func softDelete(_ metadata: HistorySessionMetadata) throws {
        if let failure { throw failure }
        softDeleted.append(metadata.file)
    }

    func restore(_ metadata: HistorySessionMetadata) throws {
        if let failure { throw failure }
        restored.append(metadata.file)
    }

    func canPermanentlyDelete(_ metadata: HistorySessionMetadata) -> Bool { allowsPermanentDelete }

    func permanentlyDelete(_ metadata: HistorySessionMetadata) throws {
        if let failure { throw failure }
        permanentlyDeleted.append(metadata.file)
    }

    func importFile(_ source: URL) -> ConversationImportDisposition { .failed(source, "unused") }

    func exportRaw(
        _ metadata: HistorySessionMetadata,
        to destination: URL
    ) throws -> ConversationRawExportResult {
        if let failure { throw failure }
        try Data("{}".utf8).write(to: destination)
        return ConversationRawExportResult(
            destination: destination,
            bundled: false,
            fileExtension: "jsonl"
        )
    }
}

private struct StubHTMLExporter: ConversationHTMLExporting {
    func export(_ session: HistorySession, to destination: URL) throws {
        try Data("<html></html>".utf8).write(to: destination)
    }

    func suggestedBaseName(for session: HistorySession) -> String { "session" }
}

private struct ActionRepository: ConversationHistoryProviding {
    let session: HistorySession

    /// The catalog has to list the session, because every mutating action reloads and reselects it
    /// afterwards. A repository that forgot it would clear the selection and make the next action
    /// in a test — and in the app — a silent no-op.
    func listProjects(limit: Int) throws -> [HistoryProject] {
        [HistoryProject(
            cwd: session.metadata.cwd ?? "",
            name: session.metadata.project,
            sessions: [session.metadata],
            lastActivity: session.metadata.lastActivity
        )]
    }

    func search(query: String, limit: Int) throws -> [HistorySearchHit] { [] }
    func getSession(file: URL) throws -> HistorySession { session }
}

private struct ActionFileInspector: ConversationFileInspecting {
    func modificationDate(for file: URL) throws -> Date? {
        Date(timeIntervalSince1970: 1_800_000_000)
    }
}
