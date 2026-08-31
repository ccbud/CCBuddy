import XCTest

@testable import CCBuddy

/// Codex writes every subagent run as another rollout in the same tree. Listing them as peers turned
/// one piece of work into forty-two rows; these pin the fold that puts them back under their parent.
final class SubagentRolloutNestingTests: XCTestCase {
    private func session(
        _ id: String,
        source: HistorySource = .codex,
        thread: String? = nil,
        parent: String? = nil,
        dirID: String = "codex",
        messages: Int = 3,
        minutes: Int = 0,
        nickname: String? = nil
    ) -> HistorySessionMetadata {
        var metadata = HistorySessionMetadata(
            id: id,
            file: URL(fileURLWithPath: "/tmp/rollout-\(id).jsonl"),
            source: source,
            dirID: dirID,
            dirLabel: "Codex",
            sessionID: thread ?? id,
            cwd: "/work/app",
            project: "app",
            title: "Session \(id)",
            autoTitle: "Session \(id)",
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_770_000_000 + Double(minutes) * 60),
            sizeBytes: 128,
            messageCount: messages
        )
        metadata.threadID = thread ?? id
        metadata.rootSessionID = thread ?? id
        metadata.parentThreadID = parent
        metadata.isSubagent = parent != nil
        metadata.agentNickname = nickname
        return metadata
    }

    func testChildrenFoldIntoTheParentTheyBelongTo() {
        let parent = session("main", thread: "t-main", minutes: 0)
        let first = session("a", thread: "t-a", parent: "t-main", minutes: 5, nickname: "Anscombe")
        let second = session("b", thread: "t-b", parent: "t-main", minutes: 2, nickname: "Rawls")

        let result = HistoryCatalogProjection.nestingSubagentRollouts([parent, first, second])

        XCTAssertEqual(result.map(\.id), ["main"], "only the parent is listed")
        XCTAssertEqual(result[0].subagentCount, 2)
        XCTAssertEqual(
            result[0].subagentRefs.map(\.threadID),
            ["t-b", "t-a"],
            "children are described in the order they ran"
        )
        XCTAssertEqual(result[0].subagentRefs.first?.agentNickname, "Rawls")
        XCTAssertEqual(result[0].subagentRefs.first?.messageCount, 3)
    }

    func testAChildRootedAtItselfStillFindsItsParent() {
        // This is the shape real Codex data has, and the reason the old rootSessionID grouping
        // never folded anything.
        var child = session("a", thread: "t-a", parent: "t-main")
        child.rootSessionID = "t-a"
        let parent = session("main", thread: "t-main")

        let result = HistoryCatalogProjection.nestingSubagentRollouts([parent, child])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subagentRefs.map(\.threadID), ["t-a"])
    }

    func testAnOrphanKeepsItsPlaceInTheList() {
        let orphan = session("a", thread: "t-a", parent: "t-missing")

        let result = HistoryCatalogProjection.nestingSubagentRollouts([orphan])

        XCTAssertEqual(result.map(\.id), ["a"], "a child whose parent is not here must stay visible")
        XCTAssertTrue(result[0].subagentRefs.isEmpty)
    }

    func testAParentInAnotherLocationIsNotAdopted() {
        let parent = session("main", thread: "t-main", dirID: "codex")
        let child = session("a", thread: "t-a", parent: "t-main", dirID: "imported")

        let result = HistoryCatalogProjection.nestingSubagentRollouts([parent, child])

        XCTAssertEqual(result.count, 2, "thread ids are only unique within one location")
    }

    func testASessionThatNamesItselfAsParentIsLeftAlone() {
        var loop = session("a", thread: "t-a")
        loop.parentThreadID = "t-a"

        let result = HistoryCatalogProjection.nestingSubagentRollouts([loop])

        XCTAssertEqual(result.map(\.id), ["a"])
        XCTAssertTrue(result[0].subagentRefs.isEmpty)
    }

    func testAWholeChainCollapsesOntoTheSessionThatStartedIt() {
        let parent = session("main", thread: "t-main")
        let child = session("a", thread: "t-a", parent: "t-main", minutes: 1)
        let grandchild = session("b", thread: "t-b", parent: "t-a", minutes: 2)

        let result = HistoryCatalogProjection.nestingSubagentRollouts([parent, child, grandchild])

        XCTAssertEqual(result.map(\.id), ["main"])
        XCTAssertEqual(
            result[0].subagentRefs.map(\.threadID),
            ["t-a", "t-b"],
            "a grandchild hung off its immediate parent would be attached to a row that is itself "
                + "folded away, and reachable from nothing"
        )
    }

    func testALoopInTheParentChainIsNotFollowedForever() {
        var first = session("a", thread: "t-a")
        first.parentThreadID = "t-b"
        var second = session("b", thread: "t-b")
        second.parentThreadID = "t-a"

        let result = HistoryCatalogProjection.nestingSubagentRollouts([first, second])

        XCTAssertEqual(
            result.map(\.id).sorted(),
            ["a", "b"],
            "folding either member of a cycle into the other would fold both away"
        )
    }

    func testOtherAgentsAreUntouched() {
        var claudeChild = session("a", source: .claude, thread: "t-a", parent: "t-main")
        claudeChild.dirID = "claude"
        var claudeParent = session("main", source: .claude, thread: "t-main")
        claudeParent.dirID = "claude"

        let result = HistoryCatalogProjection.nestingSubagentRollouts([claudeParent, claudeChild])

        XCTAssertEqual(
            result.count,
            2,
            "Claude keeps its children beside the main transcript; the loader finds those itself"
        )
    }

    func testAListWithoutCodexIsReturnedUnchanged() {
        let sessions = [session("x", source: .grok, thread: "t-x")]
        XCTAssertEqual(HistoryCatalogProjection.nestingSubagentRollouts(sessions), sessions)
    }

    // MARK: - Tabs

    @MainActor
    func testTheParentOffersItsChildrenAsTabsWithoutReadingThem() {
        let parent = session("main", thread: "t-main")
        let children = HistoryCatalogProjection.nestingSubagentRollouts([
            parent,
            session("a", thread: "t-a", parent: "t-main", messages: 12, nickname: "Anscombe"),
        ])
        let described = try? XCTUnwrap(children.first)

        let session = HistorySession(
            metadata: parent,
            messages: [],
            subagents: [:]
        )
        let attached = ConversationStore.attachingSubagentRefs(of: described, to: session)

        XCTAssertEqual(attached.subagents.count, 1)
        let child = try? XCTUnwrap(attached.subagents["t-a"])
        XCTAssertEqual(child?.count, 12, "the size comes from the catalog, not from parsing")
        XCTAssertEqual(child?.description, "Anscombe")
        XCTAssertTrue(child?.messages.isEmpty ?? false, "nothing is read until the tab is opened")

        let tabs = ConversationTranscriptPresentation.tabs(in: attached)
        XCTAssertEqual(tabs.map(\.id), [.main, .subagent("t-a")])
    }
}
