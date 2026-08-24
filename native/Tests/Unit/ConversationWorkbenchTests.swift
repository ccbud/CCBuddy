import XCTest
@testable import CCBuddy

@MainActor
final class ConversationWorkbenchTests: XCTestCase {
    func testStarredSelectionFiltersAcrossProjectsWithoutChangingDiscoveryScope() {
        let state = ConversationWorkbenchState()
        let starred = metadata(id: "starred", project: "one", starred: true)
        let ordinary = metadata(id: "ordinary", project: "two")

        state.showStarred()
        let filtered = state.filteredProjects([
            project("one", sessions: [starred]),
            project("two", sessions: [ordinary]),
        ], historyActive: "all")

        XCTAssertEqual(filtered.map(\.name), ["one"])
        XCTAssertEqual(filtered.flatMap(\.sessions).map(\.id), ["starred"])
    }

    func testPinnedSessionsStayFirstForEverySortDirection() {
        let state = ConversationWorkbenchState()
        let olderPinned = metadata(
            id: "pinned",
            project: "p",
            pinned: true,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            messageCount: 1
        )
        let newer = metadata(
            id: "newer",
            project: "p",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40),
            messageCount: 50
        )

        for field in ConversationWorkbenchState.SortField.allCases {
            state.sortField = field
            state.sortAscending = false
            XCTAssertEqual(state.sorted([newer, olderPinned]).first?.id, "pinned")
            state.sortAscending = true
            XCTAssertEqual(state.sorted([newer, olderPinned]).first?.id, "pinned")
        }
    }

    func testEveryWakeAndQoderSourceHasAPresentationName() {
        for source in ConversationPresentation.sourceOrder {
            let name = ConversationPresentation.sourceName(rawValue: source.rawValue)
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(name, source.rawValue, source.rawValue)
        }
        XCTAssertEqual(ConversationPresentation.sourceName(rawValue: "grok"), "Grok Build")
        XCTAssertEqual(ConversationPresentation.sourceName(rawValue: "copilot"), "Copilot CLI")
        XCTAssertEqual(ConversationPresentation.sourceName(rawValue: "omp"), "Oh My Pi")
        XCTAssertEqual(ConversationPresentation.sourceName(rawValue: "kimi"), "Kimi Code")
        XCTAssertEqual(
            ConversationPresentation.sourceName(rawValue: "antigravity"),
            "Antigravity CLI"
        )
        XCTAssertNil(ConversationPresentation.sourceBrandResource(.qoder, dark: false))
        XCTAssertEqual(
            ConversationPresentation.sourceBrandResource(.grok, dark: false),
            "session-brand-grok-light"
        )
    }

    func testMissingAgentAndProjectSelectionsReturnToAllSessions() {
        let state = ConversationWorkbenchState()
        let codex = metadata(id: "codex", project: "available", source: .codex)
        let projects = [HistoryProject(
            cwd: "/workspace/available",
            name: "available",
            sessions: [codex],
            lastActivity: codex.lastActivity
        )]

        state.select(agent: .qoder)
        state.reconcileSelection(projects: projects, historyActive: "all")
        XCTAssertEqual(state.selection, .all)

        state.select(project: "/workspace/missing")
        state.reconcileSelection(projects: projects, historyActive: "all")
        XCTAssertEqual(state.selection, .all)

        state.select(agent: .codex)
        state.reconcileSelection(projects: projects, historyActive: "all")
        XCTAssertEqual(state.selection, .agent(.codex))
    }

    func testTimelineProjectsSessionWideToolStateIntoOnlyTheReferencingRow() {
        let firstCall = HistoryMessage(
            role: "assistant",
            content: [.init(type: "tool_use", id: "call-one", name: "Read")]
        )
        let secondCall = HistoryMessage(
            role: "assistant",
            content: [.init(type: "tool_use", id: "call-two", name: "Bash")]
        )
        let firstResult = HistoryContentBlock(
            type: "tool_result",
            toolUseID: "call-one",
            content: .string("first output")
        )
        let secondResult = HistoryContentBlock(
            type: "tool_result",
            toolUseID: "call-two",
            content: .string("second output")
        )
        let resultRow = HistoryMessage(
            role: "user",
            content: [firstResult, secondResult]
        )
        let messages = [firstCall, secondCall, resultRow]
        let allResults = ConversationVisibleText.resultMap(in: messages)
        let allPairedIDs = ConversationVisibleText.pairedToolResultIDs(in: messages)

        XCTAssertEqual(
            ConversationVisibleText.resultMap(for: firstCall, from: allResults),
            ["call-one": firstResult]
        )
        XCTAssertEqual(
            ConversationVisibleText.resultMap(for: secondCall, from: allResults),
            ["call-two": secondResult]
        )
        XCTAssertTrue(
            ConversationVisibleText.resultMap(for: resultRow, from: allResults).isEmpty
        )
        XCTAssertEqual(
            ConversationVisibleText.pairedToolResultIDs(
                for: resultRow,
                from: allPairedIDs
            ),
            ["call-one", "call-two"]
        )
    }

    func testTimelineBoundsLargePayloadsWithoutMutatingTheExportSession() throws {
        let largeText = String(repeating: "界", count: 20_000)
        let largeOutput = String(repeating: "tool-output-", count: 4_000)
        let raw: HistoryValue = .object(["producer": .string(largeOutput)])
        let original = HistoryMessage(
            role: "assistant",
            content: [
                .init(type: "text", text: largeText, raw: raw),
                .init(
                    type: "tool_use",
                    id: "large-call",
                    name: "Write",
                    input: .object([
                        "file_path": .string("/tmp/large.txt"),
                        "content": .string(largeOutput),
                    ]),
                    raw: raw
                ),
                .init(
                    type: "tool_result",
                    toolUseID: "large-call",
                    content: .string(largeOutput),
                    raw: raw
                ),
            ]
        )

        let timeline = ConversationVisibleText.timelineMessage(original)

        XCTAssertEqual(original.content[0].text, largeText)
        XCTAssertEqual(original.content[0].raw, raw)
        XCTAssertEqual(original.content[1].input?["content"]?.stringValue, largeOutput)
        XCTAssertEqual(original.content[2].content?.stringValue, largeOutput)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(timeline.content[0].text).utf8.count,
            ConversationVisibleText.maximumTimelineMessageTextBytes
        )
        XCTAssertTrue(try XCTUnwrap(timeline.content[0].text).hasSuffix("… (truncated)"))
        XCTAssertNil(timeline.content[0].raw)
        XCTAssertNil(timeline.content[1].raw)
        XCTAssertNil(timeline.content[2].raw)
        XCTAssertEqual(timeline.content[1].input?["file_path"]?.stringValue, "/tmp/large.txt")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(timeline.content[1].input?["content"]?.stringValue).utf8.count,
            ConversationVisibleText.maximumTimelineToolValueBytes
        )
        XCTAssertTrue(try XCTUnwrap(timeline.content[1].input?["content"]?.stringValue)
            .hasSuffix("… (truncated)"))
        let result = try XCTUnwrap(timeline.content[2].content?.stringValue)
        XCTAssertLessThanOrEqual(
            result.utf8.count,
            ConversationVisibleText.maximumTimelineToolValueBytes
        )
        XCTAssertTrue(result.hasPrefix("tool-output-"), "Plain output must not become a quoted JSON literal")
        XCTAssertTrue(result.hasSuffix("… (truncated)"))
    }

    func testTimelineBoundsRawOnlyBlocksWhilePreservingVisibleSkillMetadata() throws {
        let largeSnapshot = String(repeating: "skill-body\n", count: 4_000)
        let largeImageData = String(repeating: "a", count: 80_000)
        let skillRaw: HistoryValue = .object([
            "type": .string("skill_load"),
            "name": .string("review"),
            "path": .string("/tmp/SKILL.md"),
            "snapshot": .string(largeSnapshot),
        ])
        let imageRaw: HistoryValue = .object([
            "type": .string("image"),
            "source": .object([
                "type": .string("base64"),
                "media_type": .string("image/png"),
                "data": .string(largeImageData),
            ]),
        ])
        let original = HistoryMessage(
            role: "user",
            content: [
                .init(type: "skill_load", name: "review", raw: skillRaw),
                .init(type: "image", raw: imageRaw),
            ]
        )

        let timeline = ConversationVisibleText.timelineMessage(original)

        XCTAssertEqual(original.content[0].raw?["snapshot"]?.stringValue, largeSnapshot)
        XCTAssertEqual(original.content[1].raw?["source"]?["data"]?.stringValue, largeImageData)
        XCTAssertEqual(timeline.content[0].raw?["path"]?.stringValue, "/tmp/SKILL.md")
        XCTAssertTrue(try XCTUnwrap(timeline.content[0].raw?["snapshot"]?.stringValue)
            .hasSuffix("… (truncated)"))
        for block in timeline.content {
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(block.raw).jsonString.utf8.count,
                ConversationVisibleText.maximumTimelineToolValueBytes
            )
        }
    }

    private func project(_ name: String, sessions: [HistorySessionMetadata]) -> HistoryProject {
        HistoryProject(
            cwd: "/workspace/\(name)",
            name: name,
            sessions: sessions,
            lastActivity: sessions.map(\.lastActivity).max() ?? .distantPast
        )
    }

    private func metadata(
        id: String,
        project: String,
        source: HistorySource = .claude,
        starred: Bool = false,
        pinned: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 10),
        updatedAt: Date = Date(timeIntervalSince1970: 20),
        messageCount: Int = 1
    ) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: id,
            file: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            source: source,
            dirID: "~/.claude",
            dirLabel: "~/.claude",
            sessionID: id,
            project: project,
            title: id,
            autoTitle: id,
            starred: starred,
            pinned: pinned,
            createdAt: createdAt,
            lastActivity: updatedAt,
            sizeBytes: 1,
            messageCount: messageCount
        )
    }
}
