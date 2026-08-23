import Foundation
import XCTest
@testable import CCBuddy

final class ConversationFilterTests: XCTestCase {
    func testProjectTitleTagAndContentHitsShareOneFilter() {
        let projectOne = Self.project(
            cwd: "/code/Orchard",
            name: "Orchard",
            sessions: [
                Self.metadata(id: "a", title: "Fix index", tags: ["backend"], file: "/tmp/a.jsonl"),
                Self.metadata(id: "b", title: "Polish toolbar", tags: ["design"], file: "/tmp/b.jsonl"),
            ]
        )
        let projectTwo = Self.project(
            cwd: "/code/Elsewhere",
            name: "Elsewhere",
            sessions: [Self.metadata(id: "c", title: "Unrelated", tags: [], file: "/tmp/c.jsonl")]
        )

        XCTAssertEqual(
            ConversationFilter.projects([projectOne, projectTwo], matching: "orchard", contentHits: [:])
                .first?.sessions.map(\.id),
            ["a", "b"],
            "A project match keeps all sessions in that project"
        )
        XCTAssertEqual(
            ConversationFilter.projects([projectOne, projectTwo], matching: "DESIGN", contentHits: [:])
                .flatMap(\.sessions).map(\.id),
            ["b"]
        )

        let hit = HistorySearchHit(
            sessionID: "c",
            file: URL(fileURLWithPath: "/tmp/c.jsonl"),
            source: .claude,
            snippet: "needle in tool output",
            count: 1
        )
        XCTAssertEqual(
            ConversationFilter.projects(
                [projectOne, projectTwo],
                matching: "needle",
                contentHits: [ConversationFilter.fileKey(hit.file): hit]
            ).flatMap(\.sessions).map(\.id),
            ["c"]
        )
    }
}

final class ConversationPresentationParityTests: XCTestCase {
    func testListIdentityKeepsDuplicateProducerSessionIDsFromDifferentPathsDistinct() {
        let first = ConversationFilterTests.metadata(
            id: "shared-session",
            title: "First root",
            tags: [],
            file: "/tmp/history-one/./shared-session.jsonl"
        )
        let second = ConversationFilterTests.metadata(
            id: "shared-session",
            title: "Second root",
            tags: [],
            file: "/tmp/history-two/shared-session.jsonl"
        )

        XCTAssertEqual(first.id, second.id, "The regression fixture must reuse the producer ID")
        XCTAssertEqual(Set([first.conversationListIdentity, second.conversationListIdentity]).count, 2)
        XCTAssertEqual(first.conversationListIdentity, "/tmp/history-one/shared-session.jsonl")
        XCTAssertEqual(
            first.conversationRowAccessibilityIdentifier,
            "conversation.session.shared-session"
        )
        XCTAssertEqual(
            second.conversationRowAccessibilityIdentifier,
            first.conversationRowAccessibilityIdentifier,
            "The existing automation identifier contract remains producer-ID based"
        )
    }

    func testIndexAccessibilityAnnouncesPhaseChangesWithoutProgressNoise() {
        let started = ConversationIndexAccessibility.announcement(
            from: .idle,
            to: .scanning(completed: 0, total: 12),
            language: .english
        )
        XCTAssertEqual(started, .init(message: "Updating conversation index", isFailure: false))

        XCTAssertNil(ConversationIndexAccessibility.announcement(
            from: .scanning(completed: 0, total: 12),
            to: .scanning(completed: 1, total: 12),
            language: .english
        ), "Per-file progress must not generate repeated VoiceOver announcements")

        let failure = ConversationIndexAccessibility.announcement(
            from: .scanning(completed: 4, total: 12),
            to: .failed("会话索引失败：catalog unavailable"),
            language: .english
        )
        XCTAssertEqual(
            failure,
            .init(message: "Conversation indexing failed: catalog unavailable", isFailure: true)
        )
        XCTAssertNil(ConversationIndexAccessibility.announcement(
            from: .failed("会话索引失败：catalog unavailable"),
            to: .failed("会话索引失败：catalog unavailable"),
            language: .english
        ))

        let completed = ConversationIndexAccessibility.announcement(
            from: .scanning(completed: 12, total: 12),
            to: .idle,
            language: .english
        )
        XCTAssertEqual(completed, .init(message: "Conversation index updated", isFailure: false))
    }

    func testScopeBarStaysOutOfSingleDirectoryLayoutUntilAChoiceExists() {
        let empty = ConversationScopeSnapshot()
        XCTAssertFalse(ConversationScopePresentation.showsScopeBar(
            directories: ["~/.claude"], snapshot: empty, active: "all"
        ))
        XCTAssertFalse(ConversationScopePresentation.showsScopeBar(
            directories: ["~/.claude", " ~/.claude ", ""], snapshot: empty, active: "all"
        ), "Normalized duplicate roots must not create a fake second scope")

        XCTAssertTrue(ConversationScopePresentation.showsScopeBar(
            directories: ["~/.claude", "~/.codex"], snapshot: empty, active: "all"
        ))
        XCTAssertTrue(ConversationScopePresentation.showsScopeBar(
            directories: ["~/.claude"],
            snapshot: .init(sessionCounts: ["__imported__": 1]),
            active: "all"
        ))
        XCTAssertTrue(ConversationScopePresentation.showsScopeBar(
            directories: ["~/.claude"],
            snapshot: .init(trashCount: 1),
            active: "all"
        ))
        XCTAssertTrue(ConversationScopePresentation.showsScopeBar(
            directories: ["~/.claude"], snapshot: empty, active: "__trash__"
        ), "An emptied active recycle bin must retain a way back to all conversations")
    }

    func testBlockMarkdownParserCoversLegacyGFMShapesWithoutHTMLNodes() {
        let markdown = """
        # Release **notes**

        Intro paragraph.

        - first
        - second

        > quoted
        > continuation

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | :--- | ---: |
        | safe | <script>alert(1)</script> |
        """

        XCTAssertEqual(ConversationMarkdownParser.parse(markdown), [
            .heading(level: 1, text: "Release **notes**"),
            .paragraph("Intro paragraph."),
            .list(ordered: false, start: 1, items: ["first", "second"]),
            .blockquote([.paragraph("quoted\ncontinuation")]),
            .code(language: "swift", value: "let answer = 42"),
            .table(
                header: ["Name", "Value"],
                alignments: [.leading, .trailing],
                rows: [["safe", "<script>alert(1)</script>"]]
            ),
        ])
    }

    func testBlockMarkdownParserPreservesOrderedStartsTasksAndEscapedTablePipes() {
        let markdown = """
        3. third
        4. fourth

        - [x] shipped
        - [ ] verify

        | Key | Value |
        | --- | :---: |
        | a\\|b | c |
        """
        XCTAssertEqual(ConversationMarkdownParser.parse(markdown), [
            .list(ordered: true, start: 3, items: ["third", "fourth"]),
            .list(ordered: false, start: 1, items: ["[x] shipped", "[ ] verify"]),
            .table(
                header: ["Key", "Value"],
                alignments: [.leading, .center],
                rows: [["a|b", "c"]]
            ),
        ])
    }

    func testToolPresentationShapesCommandTargetAndCompactResultSummary() {
        let bash = ConversationToolPresentation.make(
            name: "Bash",
            input: .object([
                "command": .string("ls -la"),
                "description": .string("list"),
            ])
        )
        XCTAssertEqual(bash.icon, "⌘")
        XCTAssertEqual(bash.label, "Bash")
        XCTAssertEqual(bash.target, "list")
        XCTAssertEqual(bash.body, .code("ls -la"))
        XCTAssertEqual(bash.category, .execution)
        XCTAssertEqual(ConversationToolPresentation.resultSummary("total 0"), "7 B")

        let read = ConversationToolPresentation.make(
            name: "Read",
            input: .object(["file_path": .string("/Users/example/work/Sources/App.swift")])
        )
        XCTAssertEqual(read.target, "…/Sources/App.swift")
        XCTAssertEqual(read.body, .none)

        let patch = ConversationToolPresentation.make(
            name: "ApplyPatch",
            input: .object(["patch": .string("*** Update File: Sources/App.swift\n@@")])
        )
        XCTAssertEqual(patch.target, "Sources/App.swift")
    }

    func testTranscriptTabsKeepEveryNestedAgentInStableDepthFirstOrder() {
        let metadata = ConversationFilterTests.metadata(
            id: "nested",
            title: "Nested",
            tags: [],
            file: "/tmp/main.jsonl"
        )
        func calls(_ keys: [String]) -> [HistoryMessage] {
            [HistoryMessage(
                role: "assistant",
                content: keys.map { .init(type: "tool_use", id: $0, name: "Agent") }
            )]
        }
        func subagent(
            _ id: String,
            path: String,
            calls keys: [String] = []
        ) -> HistorySubagent {
            HistorySubagent(
                agentID: id,
                file: URL(fileURLWithPath: path),
                type: "agent",
                description: id,
                count: max(1, keys.count),
                messages: calls(keys)
            )
        }

        let entries: [(String, HistorySubagent)] = [
            ("orphan", subagent("orphan", path: "/tmp/z-orphan.jsonl")),
            ("child-one", subagent("child-one", path: "/tmp/d-child-one.jsonl")),
            ("root-a", subagent("root-a", path: "/tmp/b-root-a.jsonl")),
            ("leaf", subagent("leaf", path: "/tmp/e-leaf.jsonl")),
            ("root-b", subagent(
                "root-b",
                path: "/tmp/a-root-b.jsonl",
                calls: ["child-two", "child-one"]
            )),
            ("child-two", subagent(
                "child-two",
                path: "/tmp/c-child-two.jsonl",
                calls: ["leaf"]
            )),
        ]
        let expectedIDs: [ConversationTranscriptID] = [
            .main,
            .subagent("root-b"),
            .subagent("child-two"),
            .subagent("leaf"),
            .subagent("child-one"),
            .subagent("root-a"),
            .subagent("orphan"),
        ]

        for orderedEntries in [entries, Array(entries.reversed())] {
            let session = HistorySession(
                metadata: metadata,
                messages: calls(["root-b", "root-a"]),
                subagents: Dictionary(uniqueKeysWithValues: orderedEntries)
            )
            let tabs = ConversationTranscriptPresentation.tabs(in: session)

            XCTAssertEqual(tabs.map(\.id), expectedIDs)
            XCTAssertEqual(tabs.map(\.depth), [0, 1, 2, 3, 2, 1, 1])
            XCTAssertEqual(tabs[2].parentID, .subagent("root-b"))
            XCTAssertEqual(tabs[3].parentID, .subagent("child-two"))
            XCTAssertNil(tabs.last?.parentID, "Unresolved agents must remain selectable")
        }
    }

    func testExportResultOpeningPolicySuppressesAutomationAndSelfCheckProcesses() {
        XCTAssertTrue(ConversationWorkspaceExportResultOpener.allowsOpening(
            environment: [:],
            xctestLoaded: false
        ))
        XCTAssertFalse(ConversationWorkspaceExportResultOpener.allowsOpening(
            environment: [SelfCheckEnvironmentGate.enabledKey: "1"],
            xctestLoaded: false
        ))
#if DEBUG
        XCTAssertFalse(ConversationWorkspaceExportResultOpener.allowsOpening(
            environment: ["CCBUD_UI_TESTING": "1"],
            xctestLoaded: false
        ))
#endif
        XCTAssertFalse(ConversationWorkspaceExportResultOpener.allowsOpening(
            environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
            xctestLoaded: false
        ))
        XCTAssertFalse(ConversationWorkspaceExportResultOpener.allowsOpening(
            environment: [:],
            xctestLoaded: true
        ))
    }
}

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testWarmCatalogReloadsImmediatelyAndIndexerSurvivesViewDeactivation() async throws {
        let warm = Self.metadata(
            id: "warm",
            title: "Warm catalog row",
            tags: [],
            file: "/tmp/warm.jsonl"
        )
        let refreshed = Self.metadata(
            id: "refreshed",
            title: "Indexed while hidden",
            tags: [],
            file: "/tmp/refreshed.jsonl"
        )
        let provider = FakeIndexedConversationRepository(
            topologySignature: "fixture",
            projectsByScope: [
                "all": [Self.project(cwd: "/tmp", name: "tmp", sessions: [warm])],
            ]
        )
        let store = ConversationStore(
            repository: provider,
            fileInspector: FakeConversationFileInspector(date: warm.lastActivity),
            searchDelayNanoseconds: 0
        )

        store.activate()
        await waitUntil { store.listState == .loaded }
        XCTAssertEqual(store.projects.first?.sessions.map(\.id), ["warm"])
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertEqual(provider.stopCount, 0)

        store.deactivate()
        provider.setProjects(
            [Self.project(cwd: "/tmp", name: "tmp", sessions: [refreshed])],
            for: "all"
        )
        provider.emit(.progress(ConversationIndexScanResult(
            discovered: 1,
            parsed: 1,
            generation: 1
        )))
        await Task.yield()
        XCTAssertEqual(store.projects.first?.sessions.map(\.id), ["warm"])
        XCTAssertEqual(provider.stopCount, 0, "Leaving the page must not stop app-lifetime indexing")

        store.activate()
        await waitUntil {
            store.projects.first?.sessions.first?.id == "refreshed"
                && store.listState == .loaded
        }
        XCTAssertEqual(provider.startCount, 2, "Activation reattaches to the running coordinator")
        XCTAssertEqual(provider.stopCount, 0)

        provider.emit(.finished(ConversationIndexScanResult(
            discovered: 1,
            unchanged: 1,
            generation: 1
        )))
        await waitUntil { store.indexingState == .idle }
        store.deactivate()
    }

    func testScopeChangeReusesTheIndexedEngineWithoutRestartingIt() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("store-index-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let importsRoot = root.appendingPathComponent("imports", isDirectory: true)
        let scope = root.appendingPathComponent("history", isDirectory: true).path
        let all = Self.metadata(id: "all", title: "All", tags: [], file: "/tmp/all.jsonl")
        var scoped = Self.metadata(
            id: "scoped",
            title: "Scoped",
            tags: [],
            file: "/tmp/scoped.jsonl"
        )
        scoped.dirID = scope
        let signature = IndexedHistoryRepository.topologySignature(
            historyDirs: [scope],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            importsRoot: importsRoot
        )
        let provider = FakeIndexedConversationRepository(
            topologySignature: signature,
            projectsByScope: [
                "all": [Self.project(cwd: "/tmp", name: "tmp", sessions: [all])],
                scope: [Self.project(cwd: "/tmp", name: "tmp", sessions: [scoped])],
            ]
        )
        let store = ConversationStore(repository: provider, historyActive: "all")
        store.activate()
        await waitUntil { store.listState == .loaded }

        var config = AppConfig.fixture
        config.historyDirs = [scope]
        config.historyActive = scope
        store.configure(config: config, importsRoot: importsRoot)
        await waitUntil {
            store.projects.first?.sessions.first?.id == "scoped"
                && store.listState == .loaded
        }

        XCTAssertEqual(store.historyActive, scope)
        XCTAssertEqual(provider.scopedCount, 1)
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertEqual(provider.stopCount, 0)
        store.deactivate()
    }

    func testScopeChangeHidesStaleRowsAndClearsASelectionThatRacesReload() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("store-index-scope-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let importsRoot = root.appendingPathComponent("imports", isDirectory: true)
        let scope = root.appendingPathComponent("history", isDirectory: true).path
        let old = Self.metadata(
            id: "old-scope",
            title: "Old scope",
            tags: [],
            file: "/tmp/old-scope.jsonl"
        )
        var scoped = Self.metadata(
            id: "new-scope",
            title: "New scope",
            tags: [],
            file: "/tmp/new-scope.jsonl"
        )
        scoped.dirID = scope
        let signature = IndexedHistoryRepository.topologySignature(
            historyDirs: [scope],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            importsRoot: importsRoot
        )
        let provider = FakeIndexedConversationRepository(
            topologySignature: signature,
            projectsByScope: [
                "all": [Self.project(cwd: "/tmp", name: "tmp", sessions: [old])],
                scope: [Self.project(cwd: "/tmp", name: "tmp", sessions: [scoped])],
            ]
        )
        let store = ConversationStore(repository: provider, historyActive: "all")
        store.activate()
        await waitUntil { store.listState == .loaded }

        let releaseScopedRead = DispatchSemaphore(value: 0)
        provider.blockNextList(until: releaseScopedRead)
        var config = AppConfig.fixture
        config.historyDirs = [scope]
        config.historyActive = scope
        store.configure(config: config, importsRoot: importsRoot)

        XCTAssertTrue(store.projects.isEmpty, "Rows from the previous scope must disappear at once")
        XCTAssertEqual(store.listState, .loading)

        // Simulate an already-dispatched row action from the old scope. The completed scoped read
        // is the final authority and must clear this stale detail/action target.
        await store.select(old)
        XCTAssertEqual(store.selectedFile?.standardizedFileURL, old.file.standardizedFileURL)
        releaseScopedRead.signal()
        await waitUntil {
            store.listState == .loaded
                && store.projects.first?.sessions.first?.id == "new-scope"
        }

        XCTAssertNil(store.selectedFile)
        XCTAssertNil(store.selectedSession)
        XCTAssertEqual(store.detailState, .idle)
        store.deactivate()
    }

    func testScopeChangeRestartsContentSearchAgainstTheScopedRepository() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("store-index-scope-search")
        defer { try? FileManager.default.removeItem(at: root) }
        let importsRoot = root.appendingPathComponent("imports", isDirectory: true)
        let scope = root.appendingPathComponent("history", isDirectory: true).path
        let old = Self.metadata(
            id: "old-content-hit",
            title: "Old title",
            tags: [],
            file: "/tmp/old-content-hit.jsonl"
        )
        var scoped = Self.metadata(
            id: "new-content-hit",
            title: "New title",
            tags: [],
            file: "/tmp/new-content-hit.jsonl"
        )
        scoped.dirID = scope
        let oldHit = HistorySearchHit(
            sessionID: old.sessionID,
            file: old.file,
            source: old.source,
            snippet: "needle in old body",
            count: 1
        )
        let scopedHit = HistorySearchHit(
            sessionID: scoped.sessionID,
            file: scoped.file,
            source: scoped.source,
            snippet: "needle in scoped body",
            count: 1
        )
        let signature = IndexedHistoryRepository.topologySignature(
            historyDirs: [scope],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            importsRoot: importsRoot
        )
        let provider = FakeIndexedConversationRepository(
            topologySignature: signature,
            projectsByScope: [
                "all": [Self.project(cwd: "/tmp", name: "tmp", sessions: [old])],
                scope: [Self.project(cwd: "/tmp", name: "tmp", sessions: [scoped])],
            ],
            searchHitsByScope: ["all": [oldHit], scope: [scopedHit]]
        )
        let store = ConversationStore(
            repository: provider,
            historyActive: "all",
            searchDelayNanoseconds: 0
        )
        store.activate()
        await waitUntil { store.listState == .loaded }
        store.updateListQuery("needle")
        await waitUntil {
            !store.isSearchingContent
                && store.filteredProjects.flatMap(\.sessions).map(\.id) == ["old-content-hit"]
        }

        var config = AppConfig.fixture
        config.historyDirs = [scope]
        config.historyActive = scope
        store.configure(config: config, importsRoot: importsRoot)
        await waitUntil {
            store.listState == .loaded
                && !store.isSearchingContent
                && store.filteredProjects.flatMap(\.sessions).map(\.id) == ["new-content-hit"]
        }

        XCTAssertNil(store.contentHit(for: old))
        XCTAssertEqual(store.contentHit(for: scoped), scopedHit)
        store.deactivate()
    }

    func testScopeChangeStartsIndexerAfterRawFallbackRecovers() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("store-index-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let appDataRoot = root.appendingPathComponent("app", isDirectory: true)
        let importsRoot = appDataRoot.appendingPathComponent("imports", isDirectory: true)
        let historyRoot = root.appendingPathComponent("history", isDirectory: true)
        let project = historyRoot.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("recovered.jsonl")
        let line = #"{"type":"user","uuid":"recovered-user","timestamp":"2026-01-01T00:00:00.000Z","sessionId":"recovered","cwd":"/tmp/recovered","message":{"role":"user","content":"hello"}}"#
        try Data((line + "\n").utf8).write(to: transcript)

        // An unsafe directory at the catalog path deterministically forces the initial raw-file
        // fallback without touching any producer data or the user's real application index.
        let blockedCatalog = appDataRoot.appendingPathComponent("conversation-index-v1.sqlite3")
        try FileManager.default.createDirectory(
            at: blockedCatalog,
            withIntermediateDirectories: true
        )
        var config = AppConfig.fixture
        config.historyDirs = [historyRoot.path]
        config.historyActive = "all"
        try await { () async throws in
            let store = ConversationStore(
                config: config,
                importsRoot: importsRoot,
                pollIntervalNanoseconds: 60_000_000_000,
                searchDelayNanoseconds: 0
            )
            store.activate()
            await waitUntil(timeoutNanoseconds: 5_000_000_000) {
                store.listState == .loaded
                    && store.projects.flatMap(\.sessions).contains {
                        $0.sessionID == "recovered"
                    }
            }

            try FileManager.default.removeItem(at: blockedCatalog)
            config.historyActive = historyRoot.path
            store.configure(config: config, importsRoot: importsRoot)
            await waitUntil(timeoutNanoseconds: 5_000_000_000) {
                store.listState == .loaded
                    && store.projects.flatMap(\.sessions).contains {
                        $0.sessionID == "recovered"
                    }
                    && store.indexingState == .idle
            }

            XCTAssertEqual(store.historyActive, historyRoot.path)
            store.deactivate()
        }()
    }

    func testTerminalIndexFailureIsVisibleWithoutDiscardingWarmRows() async throws {
        let metadata = Self.metadata(
            id: "warm-error",
            title: "Warm error",
            tags: [],
            file: "/tmp/warm-error.jsonl"
        )
        let provider = FakeIndexedConversationRepository(
            topologySignature: "fixture",
            projectsByScope: [
                "all": [Self.project(cwd: "/tmp", name: "tmp", sessions: [metadata])],
            ]
        )
        let store = ConversationStore(repository: provider)
        store.activate()
        await waitUntil { store.listState == .loaded }

        provider.emit(.finished(
            ConversationIndexScanResult(generation: 0),
            errorDescription: "catalog unavailable"
        ))
        await waitUntil {
            store.indexingState == .failed("会话索引失败：catalog unavailable")
        }

        XCTAssertEqual(store.projects.first?.sessions.first?.id, metadata.id)
        XCTAssertEqual(store.actionMessage, "会话索引失败：catalog unavailable")
        XCTAssertTrue(store.actionIsError)
        store.deactivate()
    }

    func testLoadAndLatestSelectionWinWhenEarlierReadIsCancelled() async throws {
        let a = Self.metadata(id: "a", title: "Slow", tags: [], file: "/tmp/a.jsonl")
        let b = Self.metadata(id: "b", title: "Fast", tags: [], file: "/tmp/b.jsonl")
        let provider = FakeConversationRepository(
            projects: [Self.project(cwd: "/tmp", name: "tmp", sessions: [a, b])],
            sessions: [
                ConversationFilter.fileKey(a.file): Self.session(a, text: "slow body"),
                ConversationFilter.fileKey(b.file): Self.session(b, text: "fast body"),
            ]
        )
        provider.setDelay(0.18, for: a.file)
        let inspector = FakeConversationFileInspector(date: Date(timeIntervalSince1970: 1_800_000_000))
        let store = ConversationStore(
            repository: provider,
            fileInspector: inspector,
            searchDelayNanoseconds: 0,
            now: { Date(timeIntervalSince1970: 1_800_000_010) }
        )

        await store.reload()
        XCTAssertEqual(store.listState, .loaded)
        XCTAssertEqual(store.projects.first?.sessions.map(\.id), ["a", "b"])

        let slow = Task { await store.select(a) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.select(b)
        await slow.value

        XCTAssertEqual(store.selectedSession?.metadata.id, "b")
        XCTAssertEqual(store.selectedSession?.messages.first?.content.first?.text, "fast body")
        XCTAssertEqual(store.detailState, .loaded)
    }

    func testMtimeRefreshReloadsOnlyOnChangeAndFollowsLiveSession() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var metadata = Self.metadata(id: "live", title: "Live", tags: [], file: "/tmp/live.jsonl")
        metadata.lastActivity = base
        let provider = FakeConversationRepository(
            projects: [Self.project(cwd: "/tmp", name: "tmp", sessions: [metadata])],
            sessions: [ConversationFilter.fileKey(metadata.file): Self.session(metadata, text: "one")]
        )
        let inspector = FakeConversationFileInspector(date: base)
        let store = ConversationStore(
            repository: provider,
            fileInspector: inspector,
            pollIntervalNanoseconds: 1_000_000,
            searchDelayNanoseconds: 0,
            now: { base.addingTimeInterval(10) }
        )

        await store.reload()
        await store.select(metadata)
        XCTAssertEqual(provider.readCount(for: metadata.file), 1)
        let initialFollowRevision = store.followLatestRevision

        await store.refreshSelectedFileIfChanged()
        XCTAssertEqual(provider.readCount(for: metadata.file), 1, "An unchanged mtime must not reparse JSONL")

        var updated = metadata
        updated.lastActivity = base.addingTimeInterval(2)
        provider.setSession(Self.session(updated, texts: ["one", "two"]), for: metadata.file)
        inspector.setDate(base.addingTimeInterval(2))
        await store.refreshSelectedFileIfChanged()

        XCTAssertEqual(provider.readCount(for: metadata.file), 2)
        XCTAssertEqual(store.selectedSession?.messages.count, 2)
        XCTAssertTrue(store.isSelectedSessionLive)
        XCTAssertGreaterThan(store.followLatestRevision, initialFollowRevision)
    }

    func testDetailSearchIndexesTextThinkingToolInputAndPairedResult() async {
        let metadata = Self.metadata(id: "search", title: "Search", tags: [], file: "/tmp/search.jsonl")
        let messages = [
            HistoryMessage(role: "user", content: [.init(type: "text", text: "needle user")]),
            HistoryMessage(role: "assistant", content: [
                .init(type: "thinking", thinking: "needle plan"),
                .init(type: "tool_use", id: "t1", name: "Read", input: .object(["path": .string("needle.swift")]))
            ]),
            HistoryMessage(role: "user", content: [
                .init(type: "tool_result", toolUseID: "t1", content: .string("needle result needle"))
            ]),
        ]
        let session = HistorySession(metadata: metadata, messages: messages)
        let provider = FakeConversationRepository(
            projects: [Self.project(cwd: "/tmp", name: "tmp", sessions: [metadata])],
            sessions: [ConversationFilter.fileKey(metadata.file): session]
        )
        let inspector = FakeConversationFileInspector(date: metadata.lastActivity)
        let store = ConversationStore(repository: provider, fileInspector: inspector)

        await store.select(metadata)
        store.updateDetailQuery("needle")

        XCTAssertEqual(store.detailMatches.map(\.messageIndex), [0, 1])
        XCTAssertEqual(store.totalDetailOccurrences, 5)
        store.nextDetailMatch()
        XCTAssertEqual(store.jumpRequest?.messageIndex, 1)
        store.nextDetailMatch()
        XCTAssertEqual(store.jumpRequest?.messageIndex, 0, "Search navigation wraps")
    }

    func testActiveSubagentDrivesSearchCopyAndReplayWhileExportsStayRooted() async throws {
        var metadata = Self.metadata(
            id: "active-subagent",
            title: "Active subagent",
            tags: [],
            file: "/tmp/active-main.jsonl"
        )
        metadata.subagentCount = 1
        let childFile = URL(fileURLWithPath: "/tmp/active-main/subagents/agent-child.jsonl")
        let child = HistorySubagent(
            agentID: "child",
            file: childFile,
            type: "research",
            description: "Investigate",
            skill: "audit",
            count: 1,
            messages: [HistoryMessage(
                role: "assistant",
                content: [.init(type: "text", text: "child needle child needle")]
            )]
        )
        let session = HistorySession(
            metadata: metadata,
            messages: [
                HistoryMessage(
                    role: "assistant",
                    content: [
                        .init(type: "text", text: "root only"),
                        .init(type: "tool_use", id: "spawn-child", name: "Agent"),
                    ]
                ),
            ],
            subagents: ["spawn-child": child]
        )
        let provider = FakeConversationRepository(
            projects: [Self.project(cwd: "/tmp", name: "tmp", sessions: [metadata])],
            sessions: [ConversationFilter.fileKey(metadata.file): session]
        )
        let mutation = RecordingConversationMutation()
        let htmlExporter = RecordingConversationHTMLExporter()
        let exportResultOpener = RecordingConversationExportResultOpener()
        var copiedPaths: [String] = []
        var replayURLs: [URL] = []
        let store = ConversationStore(
            repository: provider,
            mutationService: mutation,
            htmlExporter: htmlExporter,
            exportResultOpener: exportResultOpener,
            fileInspector: FakeConversationFileInspector(date: metadata.lastActivity),
            pathCopier: { copiedPaths.append($0) },
            replayURLLauncher: { url in
                replayURLs.append(url)
                return true
            }
        )

        await store.select(metadata)
        store.updateDetailQuery("root only")
        XCTAssertEqual(store.detailMatches.map(\.messageIndex), [0])

        store.selectTranscript(.subagent("spawn-child"))
        XCTAssertEqual(store.detailQuery, "", "A user-driven tab switch starts a fresh search")
        XCTAssertEqual(store.activeTranscriptFile, childFile.standardizedFileURL)
        XCTAssertEqual(store.activeTranscript?.messages, child.messages)
        store.updateDetailQuery("root only")
        XCTAssertTrue(store.detailMatches.isEmpty, "The root transcript must not leak into subagent search")
        store.updateDetailQuery("child needle")
        XCTAssertEqual(store.detailMatches.map(\.messageIndex), [0])
        XCTAssertEqual(store.totalDetailOccurrences, 2)

        store.copySelectedPath()
        XCTAssertEqual(copiedPaths, [childFile.path])
        store.replaySelected(in: .claude, language: .english)
        let replay = try XCTUnwrap(replayURLs.first)
        let replayFiles = URLComponents(url: replay, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "file" }.compactMap(\.value)
        XCTAssertEqual(replayFiles, [childFile.path], "Replay must attach only the active transcript")

        XCTAssertEqual(store.selectedRawExportExtension, "zip")
        let rawDestination = URL(fileURLWithPath: "/tmp/active-export.zip")
        let htmlDestination = URL(fileURLWithPath: "/tmp/active-export.html")
        await store.exportSelectedRaw(to: rawDestination)
        await store.exportSelectedHTML(to: htmlDestination)
        XCTAssertEqual(mutation.exportedMetadata?.file, metadata.file)
        XCTAssertEqual(htmlExporter.exportedSession?.metadata.file, metadata.file)
        XCTAssertEqual(htmlExporter.exportedSession?.subagents.keys.sorted(), ["spawn-child"])
        XCTAssertEqual(exportResultOpener.openedFiles, [htmlDestination.standardizedFileURL])
    }

    func testIndexedSearchHitSelectsSubagentAndJumpsToExactSequence() async {
        var metadata = Self.metadata(
            id: "indexed-hit",
            title: "Indexed hit",
            tags: [],
            file: "/tmp/indexed-hit.jsonl"
        )
        metadata.subagentCount = 1
        let child = HistorySubagent(
            agentID: "child",
            file: URL(fileURLWithPath: "/tmp/indexed-hit/subagents/child.jsonl"),
            type: "explore",
            count: 3,
            messages: ["before", "exact indexed target", "after"].map {
                HistoryMessage(role: "assistant", content: [.init(type: "text", text: $0)])
            }
        )
        let session = HistorySession(
            metadata: metadata,
            messages: [HistoryMessage(role: "user", content: [.init(type: "text", text: "root")])],
            subagents: ["spawn-child": child]
        )
        let provider = FakeConversationRepository(
            projects: [Self.project(cwd: "/tmp", name: "tmp", sessions: [metadata])],
            sessions: [ConversationFilter.fileKey(metadata.file): session]
        )
        let store = ConversationStore(
            repository: provider,
            fileInspector: FakeConversationFileInspector(date: metadata.lastActivity)
        )
        let hit = HistorySearchHit(
            sessionID: metadata.sessionID,
            file: metadata.file,
            source: metadata.source,
            agent: "spawn-child",
            agentType: "explore",
            sequence: 1,
            snippet: "exact indexed target",
            count: 1
        )

        await store.select(metadata, searchHit: hit)

        XCTAssertEqual(store.activeTranscriptID, .subagent("spawn-child"))
        XCTAssertEqual(store.activeTranscript?.messages, child.messages)
        XCTAssertEqual(store.jumpRequest?.messageIndex, 1)
    }

    func testFailedHTMLExportDoesNotOpenResultAndKeepsLocalizedErrorSource() async {
        let metadata = Self.metadata(
            id: "failed-html",
            title: "Failed HTML",
            tags: [],
            file: "/tmp/failed-html.jsonl"
        )
        let session = Self.session(metadata, text: "body")
        let provider = FakeConversationRepository(
            projects: [Self.project(cwd: "/tmp", name: "tmp", sessions: [metadata])],
            sessions: [ConversationFilter.fileKey(metadata.file): session]
        )
        let destination = URL(fileURLWithPath: "/tmp/failed-export.html")
        let opener = RecordingConversationExportResultOpener()
        let store = ConversationStore(
            repository: provider,
            htmlExporter: FailingConversationHTMLExporter(
                error: .writeFailed(destination, "disk full")
            ),
            exportResultOpener: opener,
            fileInspector: FakeConversationFileInspector(date: metadata.lastActivity)
        )

        await store.select(metadata)
        await store.exportSelectedHTML(to: destination)

        XCTAssertTrue(opener.openedFiles.isEmpty)
        XCTAssertEqual(store.actionMessage, "HTML 导出失败：无法写入 failed-export.html：disk full")
        XCTAssertTrue(store.actionIsError)
    }

    private static func metadata(
        id: String,
        title: String,
        tags: [String],
        file: String
    ) -> HistorySessionMetadata {
        ConversationFilterTests.metadata(id: id, title: title, tags: tags, file: file)
    }

    private static func project(cwd: String, name: String, sessions: [HistorySessionMetadata]) -> HistoryProject {
        ConversationFilterTests.project(cwd: cwd, name: name, sessions: sessions)
    }

    private static func session(_ metadata: HistorySessionMetadata, text: String) -> HistorySession {
        session(metadata, texts: [text])
    }

    private static func session(_ metadata: HistorySessionMetadata, texts: [String]) -> HistorySession {
        HistorySession(
            metadata: metadata,
            messages: texts.map { HistoryMessage(role: "user", content: [.init(type: "text", text: $0)]) }
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private extension ConversationFilterTests {
    static func metadata(
        id: String,
        title: String,
        tags: [String],
        file: String
    ) -> HistorySessionMetadata {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return HistorySessionMetadata(
            id: id,
            file: URL(fileURLWithPath: file),
            source: .claude,
            dirID: "fixture",
            dirLabel: "Fixture",
            sessionID: id,
            cwd: "/tmp",
            project: "tmp",
            title: title,
            autoTitle: title,
            tags: tags,
            createdAt: date,
            lastActivity: date,
            sizeBytes: 128,
            messageCount: 1
        )
    }

    static func project(cwd: String, name: String, sessions: [HistorySessionMetadata]) -> HistoryProject {
        HistoryProject(
            cwd: cwd,
            name: name,
            sessions: sessions,
            lastActivity: sessions.map(\.lastActivity).max() ?? .distantPast
        )
    }
}

private final class FakeConversationRepository: ConversationHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedProjects: [HistoryProject]
    private var storedSessions: [String: HistorySession]
    private var delays: [String: TimeInterval] = [:]
    private var reads: [String: Int] = [:]

    init(projects: [HistoryProject], sessions: [String: HistorySession]) {
        storedProjects = projects
        storedSessions = sessions
    }

    func listProjects(limit: Int) throws -> [HistoryProject] {
        lock.withLock { Array(storedProjects.prefix(limit)) }
    }

    func search(query: String, limit: Int) throws -> [HistorySearchHit] { [] }

    func getSession(file: URL) throws -> HistorySession {
        let key = ConversationFilter.fileKey(file)
        let delay = lock.withLock { () -> TimeInterval in
            reads[key, default: 0] += 1
            return delays[key] ?? 0
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return try lock.withLock {
            guard let session = storedSessions[key] else {
                throw HistoryError.unreadableFile(file, "fixture missing")
            }
            return session
        }
    }

    func setDelay(_ delay: TimeInterval, for file: URL) {
        lock.withLock { delays[ConversationFilter.fileKey(file)] = delay }
    }

    func setSession(_ session: HistorySession, for file: URL) {
        lock.withLock { storedSessions[ConversationFilter.fileKey(file)] = session }
    }

    func readCount(for file: URL) -> Int {
        lock.withLock { reads[ConversationFilter.fileKey(file), default: 0] }
    }
}

private final class FakeIndexedConversationRepository: ConversationIndexedHistoryProviding,
    @unchecked Sendable {
    private final class Engine: @unchecked Sendable {
        let lock = NSLock()
        let topologySignature: String
        var projectsByScope: [String: [HistoryProject]]
        var searchHitsByScope: [String: [HistorySearchHit]]
        var observer: (@Sendable (ConversationCatalogScanEvent) -> Void)?
        var currentEvent = ConversationCatalogScanEvent.started(revision: 0)
        var starts = 0
        var stops = 0
        var scopes = 0
        var nextListGate: DispatchSemaphore?

        init(
            topologySignature: String,
            projectsByScope: [String: [HistoryProject]],
            searchHitsByScope: [String: [HistorySearchHit]]
        ) {
            self.topologySignature = topologySignature
            self.projectsByScope = projectsByScope
            self.searchHitsByScope = searchHitsByScope
        }
    }

    private let engine: Engine
    private let active: String

    init(
        topologySignature: String,
        projectsByScope: [String: [HistoryProject]],
        searchHitsByScope: [String: [HistorySearchHit]] = [:],
        active: String = "all"
    ) {
        engine = Engine(
            topologySignature: topologySignature,
            projectsByScope: projectsByScope,
            searchHitsByScope: searchHitsByScope
        )
        self.active = active
    }

    private init(engine: Engine, active: String) {
        self.engine = engine
        self.active = active
    }

    var indexTopologySignature: String { engine.topologySignature }
    var startCount: Int { engine.lock.withLock { engine.starts } }
    var stopCount: Int { engine.lock.withLock { engine.stops } }
    var scopedCount: Int { engine.lock.withLock { engine.scopes } }

    func listProjects(limit: Int) throws -> [HistoryProject] {
        let gate = engine.lock.withLock { () -> DispatchSemaphore? in
            defer { engine.nextListGate = nil }
            return engine.nextListGate
        }
        gate?.wait()
        return engine.lock.withLock {
            Array(engine.projectsByScope[active, default: []].prefix(limit))
        }
    }

    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        engine.lock.withLock {
            Array(engine.searchHitsByScope[active, default: []].prefix(limit))
        }
    }

    func getSession(file: URL) throws -> HistorySession {
        throw HistoryError.unreadableFile(file, "fixture has metadata only")
    }

    func scoped(to active: String) -> any ConversationIndexedHistoryProviding {
        engine.lock.withLock { engine.scopes += 1 }
        return FakeIndexedConversationRepository(engine: engine, active: active)
    }

    func startIndexing(
        onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void
    ) {
        let event = engine.lock.withLock { () -> ConversationCatalogScanEvent in
            engine.starts += 1
            engine.observer = onEvent
            return engine.currentEvent
        }
        onEvent(event)
    }

    func stopIndexing() {
        engine.lock.withLock {
            engine.stops += 1
            engine.observer = nil
        }
    }

    func reconcileIndex() throws {}
    func refreshIndex(for files: [URL]) throws {}

    func setProjects(_ projects: [HistoryProject], for scope: String) {
        engine.lock.withLock { engine.projectsByScope[scope] = projects }
    }

    func blockNextList(until gate: DispatchSemaphore) {
        engine.lock.withLock { engine.nextListGate = gate }
    }

    func emit(_ event: ConversationCatalogScanEvent) {
        let observer = engine.lock.withLock {
            engine.currentEvent = event
            return engine.observer
        }
        observer?(event)
    }
}

private final class FakeConversationFileInspector: ConversationFileInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    init(date: Date?) { self.date = date }

    func modificationDate(for file: URL) throws -> Date? {
        lock.withLock { date }
    }

    func setDate(_ date: Date?) {
        lock.withLock { self.date = date }
    }
}

private final class RecordingConversationMutation: ConversationMutating, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMetadata: HistorySessionMetadata?

    var exportedMetadata: HistorySessionMetadata? { lock.withLock { recordedMetadata } }

    func updateMetadata(
        for metadata: HistorySessionMetadata,
        patch: ConversationMetadataPatch
    ) throws {}
    func softDelete(_ metadata: HistorySessionMetadata) throws {}
    func restore(_ metadata: HistorySessionMetadata) throws {}
    func canPermanentlyDelete(_ metadata: HistorySessionMetadata) -> Bool { false }
    func permanentlyDelete(_ metadata: HistorySessionMetadata) throws {}
    func importFile(_ source: URL) -> ConversationImportDisposition { .skipped(source) }

    func exportRaw(
        _ metadata: HistorySessionMetadata,
        to destination: URL
    ) throws -> ConversationRawExportResult {
        lock.withLock { recordedMetadata = metadata }
        return ConversationRawExportResult(
            destination: destination,
            bundled: true,
            fileExtension: "zip"
        )
    }
}

private final class RecordingConversationHTMLExporter: ConversationHTMLExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSession: HistorySession?

    var exportedSession: HistorySession? { lock.withLock { recordedSession } }

    func export(_ session: HistorySession, to destination: URL) throws {
        lock.withLock { recordedSession = session }
    }

    func suggestedBaseName(for session: HistorySession) -> String { "conversation" }
}

private struct FailingConversationHTMLExporter: ConversationHTMLExporting {
    let error: ConversationHTMLExportError

    func export(_ session: HistorySession, to destination: URL) throws { throw error }
    func suggestedBaseName(for session: HistorySession) -> String { "conversation" }
}

@MainActor
private final class RecordingConversationExportResultOpener: ConversationExportResultOpening, @unchecked Sendable {
    private(set) var openedFiles: [URL] = []

    func openExportedHTML(_ file: URL) {
        openedFiles.append(file.standardizedFileURL)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
