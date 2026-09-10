import Foundation
import XCTest
@testable import CCBuddy

final class ConversationTimelineReaderTests: XCTestCase {
    func testSingleSearchEditorNeverRequiresASecondToolbarRow() {
        XCTAssertFalse(ConversationToolbarLayout.wraps(availableWidth: 180, idealWidths: [340], spacing: 8))
        XCTAssertFalse(ConversationToolbarLayout.wraps(availableWidth: 600, idealWidths: [340], spacing: 8))
    }

    func testTranscriptTabsWrapOnlyWhenTheirCombinedIdealWidthDoesNotFit() {
        XCTAssertFalse(ConversationToolbarLayout.wraps(availableWidth: 528, idealWidths: [180, 340], spacing: 8))
        XCTAssertTrue(ConversationToolbarLayout.wraps(availableWidth: 527, idealWidths: [180, 340], spacing: 8))
        XCTAssertTrue(ConversationToolbarLayout.wraps(availableWidth: 320, idealWidths: [180, 340], spacing: 8))
    }

    func testToolbarWrapDecisionTracksAvailableWidthWithoutChangingItsControlCount() {
        let widths: [CGFloat] = [180, 340]
        XCTAssertEqual([800.0, 300.0, 800.0].map {
            ConversationToolbarLayout.wraps(availableWidth: $0, idealWidths: widths, spacing: 8)
        }, [false, true, false])
    }

    func testEquivalentSnapshotsShareTheSameImmutableContentRevision() {
        let projection = ConversationStore.TranscriptProjection()
        let first = inputs(projection: projection)
        let next = inputs(projection: projection)
        XCTAssertEqual(first, next,
                       "Rebuilding the shell snapshot alone must not invalidate the reader")
    }

    func testNewProjectionInvalidatesEvenWhenVisibleRowsAreUnchanged() throws {
        let messages = [HistoryMessage(role: "assistant", content: [
            HistoryContentBlock(type: "text", text: "Public fixture content"),
        ])]
        let first = try ConversationStore.TranscriptProjection.make(messages: messages)
        let next = try ConversationStore.TranscriptProjection.make(messages: messages)
        XCTAssertEqual(first.visibleMessageIndices, next.visibleMessageIndices)
        XCTAssertNotEqual(inputs(projection: first), inputs(projection: next),
                          "A refreshed immutable projection is a new revision, even at the same row count")
    }

    func testFileTranscriptAndSourceChangesInvalidateTheReader() {
        assertChangesInvalidate([
            { $0.scope = .init(file: URL(fileURLWithPath: "/tmp/reader-b.jsonl"), transcriptID: .main) },
            { $0.scope = .init(file: $0.scope.file, transcriptID: .subagent("fixture-child")) },
            { $0.sourceRawValue = "codex" },
        ])
    }

    func testQueryMatchAndFontChangesInvalidateVisibleContent() {
        assertChangesInvalidate([
            { $0.query = "系统代理" },
            { $0.currentMatch = 1200 },
            { $0.fontSize = 15 },
        ])
        var first = inputs()
        first.currentMatch = 1200
        var next = first
        next.currentMatch = nil
        XCTAssertNotEqual(first, next, "Clearing the active match removes the row highlight")
    }

    func testEffectiveLayoutCancellationAndNewJumpIntentInvalidateTheReader() {
        var first = inputs()
        let request = jumpRequest()
        first.layoutRequest = request
        var cancelled = first
        cancelled.layoutRequest = nil
        XCTAssertNotEqual(first, cancelled, "Canceling navigation must detach its layout correction")
        var repeatedDestination = first
        repeatedDestination.layoutRequest = jumpRequest()
        XCTAssertNotEqual(first, repeatedDestination,
                          "A new explicit jump UUID remains observable even at the same message")
        var latest = first
        latest.layoutRequest = .init(file: request.file, transcriptID: .main, target: .latest(revision: 1))
        XCTAssertNotEqual(first, latest)
    }

    func testLatestAndPendingJumpTransitionsPreserveExistingOnChangeInputs() {
        assertChangesInvalidate([
            { $0.isFollowingLatest = true },
            { $0.followLatestRevision = 1 },
            { $0.jumpLayoutRequest = self.jumpRequest() },
        ])
        var first = inputs()
        first.jumpLayoutRequest = jumpRequest()
        var cancelled = first
        cancelled.jumpLayoutRequest = nil
        XCTAssertNotEqual(first, cancelled, "Pending jump cancellation is not unrelated shell state")
    }

    private func inputs(
        projection: ConversationStore.TranscriptProjection = .init()
    ) -> ConversationTimelineReaderInputs {
        .init(projection: projection,
              scope: .init(file: URL(fileURLWithPath: "/tmp/reader-a.jsonl"), transcriptID: .main),
              sourceRawValue: "claude", query: "", currentMatch: nil, fontSize: 13,
              layoutRequest: nil, jumpLayoutRequest: nil,
              isFollowingLatest: false, followLatestRevision: 0)
    }

    private func jumpRequest() -> ConversationScrollLayoutRequest {
        .init(file: URL(fileURLWithPath: "/tmp/reader-a.jsonl"), transcriptID: .main,
              target: .message(.init(id: UUID(), messageIndex: 1200)))
    }

    private func assertChangesInvalidate(
        _ changes: [(inout ConversationTimelineReaderInputs) -> Void],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let original = inputs()
        for (index, change) in changes.enumerated() {
            var changed = original
            change(&changed)
            XCTAssertNotEqual(original, changed, "Relevant input change \(index) must not be suppressed",
                              file: file, line: line)
        }
    }
}
