import XCTest

@testable import CCBuddy

/// The rail's two groups filter the stream. Collapsing one has to take its filter with it, or the
/// stream stays narrowed by a row that is no longer on screen to explain or undo it.
@MainActor
final class ConversationWorkbenchStateTests: XCTestCase {
    private func project(_ cwd: String, sessions: Int, starred: Int = 0) -> HistoryProject {
        let items = (0..<sessions).map { index -> HistorySessionMetadata in
            var session = HistorySessionMetadata(
                id: "\(cwd)-\(index)",
                file: URL(fileURLWithPath: "\(cwd)/\(index).jsonl"),
                source: index.isMultiple(of: 2) ? .claude : .codex,
                dirID: "fixture",
                dirLabel: "Fixture",
                sessionID: "\(cwd)-\(index)",
                cwd: cwd,
                project: (cwd as NSString).lastPathComponent,
                title: "Session \(index)",
                autoTitle: "Session \(index)",
                createdAt: Date(timeIntervalSince1970: 1_770_000_000),
                lastActivity: Date(timeIntervalSince1970: 1_770_000_100),
                sizeBytes: 32
            )
            session.starred = index < starred
            return session
        }
        return HistoryProject(
            cwd: cwd,
            name: (cwd as NSString).lastPathComponent,
            sessions: items,
            lastActivity: Date(timeIntervalSince1970: 1_770_000_100)
        )
    }

    func testCollapsingTheAgentGroupDropsAnAgentScope() {
        let state = ConversationWorkbenchState()
        state.select(agent: .codex)
        XCTAssertEqual(state.selection, .agent(.codex))

        state.setAgentsExpanded(false)

        XCTAssertEqual(
            state.selection,
            .all,
            "an invisible row must not keep filtering the stream"
        )
    }

    func testCollapsingTheProjectGroupDropsAProjectScope() {
        let state = ConversationWorkbenchState()
        state.select(project: "/work/alpha")

        state.setProjectsExpanded(false)

        XCTAssertEqual(state.selection, .all)
    }

    func testCollapsingOneGroupLeavesTheOtherGroupsScopeAlone() {
        let state = ConversationWorkbenchState()
        state.select(project: "/work/alpha")

        state.setAgentsExpanded(false)

        XCTAssertEqual(
            state.selection,
            .project("/work/alpha"),
            "the project row is still on screen, so its filter still has an explanation"
        )
    }

    func testCollapsingLeavesStarredAndAllAlone() {
        let state = ConversationWorkbenchState()
        state.showStarred()

        state.setAgentsExpanded(false)
        state.setProjectsExpanded(false)

        XCTAssertEqual(state.selection, .starred, "Starred is not inside either group")
    }

    func testExpandingAgainChangesNothingButTheGroup() {
        let state = ConversationWorkbenchState()
        state.select(agent: .claude)
        state.setAgentsExpanded(false)

        state.setAgentsExpanded(true)

        XCTAssertTrue(state.agentsExpanded)
        XCTAssertEqual(state.selection, .all, "the scope stays dropped; it is not silently restored")
    }

    func testTheStreamWidensBackWhenAGroupIsCollapsed() {
        let state = ConversationWorkbenchState()
        let projects = [project("/work/alpha", sessions: 2), project("/work/beta", sessions: 3)]
        state.select(project: "/work/beta")
        XCTAssertEqual(state.filteredProjects(projects, historyActive: "all").map(\.cwd), ["/work/beta"])

        state.setProjectsExpanded(false)

        XCTAssertEqual(
            state.filteredProjects(projects, historyActive: "all").map(\.cwd),
            ["/work/alpha", "/work/beta"]
        )
    }
}
