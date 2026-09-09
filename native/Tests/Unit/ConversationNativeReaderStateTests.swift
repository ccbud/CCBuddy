import Foundation
import XCTest
@testable import CCBuddy

final class ConversationNativeReaderStateTests: XCTestCase {
    func testAppendInsertsOnlyNewSourceRowsAndKeepsExistingFooterIdentity() {
        var rows = ConversationNativeReaderRowMap()
        _ = rows.replace(with: [0, 2, 4])
        let change = rows.replace(with: [0, 2, 4, 6, 7])
        XCTAssertEqual(change.removed, [])
        XCTAssertEqual(change.inserted, IndexSet([3, 4]))
        XCTAssertEqual(rows.rowBySource[4], 2)
        XCTAssertEqual(rows.rowBySource[7], 4)
    }

    func testPairingRemovesOnlyTheHiddenResultNotItsVisibleOwner() {
        var rows = ConversationNativeReaderRowMap()
        _ = rows.replace(with: [0, 1, 2, 3])
        let change = rows.replace(with: [0, 1, 3])
        XCTAssertEqual(change.removed, IndexSet(integer: 2))
        XCTAssertTrue(change.inserted.isEmpty)
        XCTAssertEqual(rows.rowBySource[1], 1)
        XCTAssertEqual(rows.rowBySource[3], 2)
        XCTAssertNil(rows.rowBySource[2])
    }

    func testMixedProjectionChangesUseOldRemovalAndNewInsertionPositions() {
        var rows = ConversationNativeReaderRowMap()
        _ = rows.replace(with: [1, 3, 4, 7])
        let change = rows.replace(with: [0, 3, 5, 7, 9])
        XCTAssertEqual(change.removed, IndexSet([0, 2]))
        XCTAssertEqual(change.inserted, IndexSet([0, 2, 4]))
        XCTAssertEqual(rows.sourceIndices, [0, 3, 5, 7, 9])
        XCTAssertTrue(rows.replace(with: rows.sourceIndices).isEmpty)
    }

    func testTwelveThousandRowsDoNotRequireContentComparisonForTailMapping() {
        var rows = ConversationNativeReaderRowMap()
        _ = rows.replace(with: Array(0..<12_000))
        let change = rows.replace(with: Array(0..<12_002))
        XCTAssertEqual(change.inserted, IndexSet([12_000, 12_001]))
        XCTAssertTrue(change.removed.isEmpty)
        XCTAssertEqual(rows.rowBySource[11_999], 11_999)
    }

    func testRemovedReadingAnchorFallsBackToPrecedingVisibleOwner() {
        var rows = ConversationNativeReaderRowMap()
        _ = rows.replace(with: [3, 5, 9])
        XCTAssertEqual(rows.row(nearestTo: 5), 1)
        XCTAssertEqual(rows.row(nearestTo: 7), 1)
        XCTAssertEqual(rows.row(nearestTo: 1), 0)
        XCTAssertEqual(rows.row(nearestTo: 99), 2)
        _ = rows.replace(with: [])
        XCTAssertNil(rows.row(nearestTo: 5))
    }

    func testReadingAnchorRetainsItsPixelOffsetAcrossEarlierRowGrowth() {
        let anchor = ConversationNativeReaderAnchor(sourceIndex: 1200, offsetWithinRow: 37)
        XCTAssertEqual(anchor.origin(rowOrigin: 400, rowHeight: 200, maximumOrigin: 10_000), 437)
        XCTAssertEqual(anchor.origin(rowOrigin: 900, rowHeight: 200, maximumOrigin: 10_000), 937)
    }

    func testReadingAnchorClampsCollapsedRowsAndShortTranscriptsWithoutNegativeScroll() {
        let anchor = ConversationNativeReaderAnchor(sourceIndex: 1200, offsetWithinRow: 370)
        XCTAssertEqual(anchor.origin(rowOrigin: 900, rowHeight: 20, maximumOrigin: 10_000), 919)
        XCTAssertEqual(anchor.origin(rowOrigin: 900, rowHeight: 20, maximumOrigin: 905), 905)
        XCTAssertEqual(anchor.origin(rowOrigin: 0, rowHeight: 20, maximumOrigin: -300), 0)
    }

    func testWidthAndFontRemeasurementNeverReplaceALongRowsReadingOffsetWithTheDefaultEstimate() {
        var heights = ConversationNativeReaderHeights()
        heights.record(1200, for: 3)
        let anchor = ConversationNativeReaderAnchor(sourceIndex: 3, offsetWithinRow: 900)
        heights.retainSources([3: 0, 4: 1], resetting: false)
        XCTAssertEqual(heights.estimate(for: 4), 96, "Only unmeasured rows use the default")
        XCTAssertEqual(anchor.origin(rowOrigin: 0, rowHeight: heights.estimate(for: 3), maximumOrigin: 2000), 900)
        XCTAssertFalse(heights.record(1200, for: 3))
        XCTAssertEqual(anchor.origin(rowOrigin: 0, rowHeight: heights.estimate(for: 3), maximumOrigin: 2000), 900)
        heights.record(600, for: 3)
        XCTAssertEqual(anchor.origin(rowOrigin: 0, rowHeight: heights.estimate(for: 3), maximumOrigin: 2000), 599,
                       "Clamping applies only to the actual newly measured height")
        heights.retainSources([3: 0], resetting: true)
        XCTAssertEqual(heights.estimate(for: 3), 96, "A different transcript must not inherit geometry")
    }

    func testNestedDiscreteWheelForwardsOnlyVerticalIntentAndHonorsShift() {
        var routing = ConversationNestedScrollRouting()
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 4, phase: [], momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
        XCTAssertFalse(routing.forwards(deltaX: 4, deltaY: 0, phase: [], momentumPhase: [], shift: false,
                                        overHorizontalContent: true))
        XCTAssertFalse(routing.forwards(deltaX: 0, deltaY: 4, phase: [], momentumPhase: [], shift: true,
                                        overHorizontalContent: true))
        XCTAssertFalse(routing.forwards(deltaX: 0, deltaY: 4, phase: [], momentumPhase: [], shift: false,
                                        overHorizontalContent: false))
    }

    func testNestedVerticalGestureKeepsItsNativeMomentumAndTerminalEvents() {
        var routing = ConversationNestedScrollRouting()
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 4, phase: .began, momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
        XCTAssertTrue(routing.forwards(deltaX: 7, deltaY: 1, phase: .changed, momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 3, phase: [], momentumPhase: .began, shift: false,
                                       overHorizontalContent: false))
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 0, phase: [], momentumPhase: .ended, shift: false,
                                       overHorizontalContent: false))
        XCTAssertFalse(routing.hasForwardedGesture)
    }

    func testNestedHorizontalGestureDoesNotSwitchAxesMidFlightButANewGestureCan() {
        var routing = ConversationNestedScrollRouting()
        XCTAssertFalse(routing.forwards(deltaX: 4, deltaY: 0, phase: .began, momentumPhase: [], shift: false,
                                        overHorizontalContent: true))
        XCTAssertFalse(routing.forwards(deltaX: 1, deltaY: 8, phase: .changed, momentumPhase: [], shift: false,
                                        overHorizontalContent: true))
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 4, phase: .began, momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
    }

    func testNestedCancellationAndReaderDetachmentClearGestureOwnership() {
        var routing = ConversationNestedScrollRouting()
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 4, phase: .began, momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
        XCTAssertTrue(routing.forwards(deltaX: 0, deltaY: 0, phase: .cancelled, momentumPhase: [], shift: false,
                                       overHorizontalContent: true))
        XCTAssertFalse(routing.hasForwardedGesture)
        _ = routing.forwards(deltaX: 0, deltaY: 4, phase: .began, momentumPhase: [], shift: false,
                             overHorizontalContent: true)
        routing.reset()
        XCTAssertFalse(routing.hasForwardedGesture)
    }

    func testSameSourceAppendRetainsDisclosuresWithoutAllocatingStateForEveryRow() {
        let store = ConversationNativeReaderInteractionStore()
        XCTAssertTrue(store.update(scope: scope(), sourceIndices: Array(0..<12_000)))
        XCTAssertEqual(store.retainedRowCount, 0)
        let state = store.state(for: 1199)
        state.setExpanded(true, for: key())
        XCTAssertFalse(store.update(scope: scope(), sourceIndices: Array(0..<12_002)))
        XCTAssertTrue(store.state(for: 1199) === state)
        XCTAssertTrue(store.state(for: 1199).isExpanded(key()))
        XCTAssertEqual(store.retainedRowCount, 1)
    }

    func testSourceAndTranscriptChangesCannotLeakAnotherSessionsChoices() {
        for replacement in [scope(file: "b"), scope(transcriptID: .subagent("child"))] {
            let store = ConversationNativeReaderInteractionStore()
            store.update(scope: scope(), sourceIndices: [0])
            let old = store.state(for: 0)
            old.setExpanded(true, for: key())
            XCTAssertTrue(store.update(scope: replacement, sourceIndices: [0]))
            XCTAssertFalse(store.state(for: 0) === old)
            XCTAssertFalse(store.state(for: 0).isExpanded(key()))
        }
    }

    func testRemovedSourceRowsReleaseTheirInteractionObjects() {
        let store = ConversationNativeReaderInteractionStore()
        store.update(scope: scope(), sourceIndices: [0, 1, 2])
        let removed = WeakState(store.state(for: 1))
        _ = store.state(for: 2)
        store.update(scope: scope(), sourceIndices: [0, 2])
        XCTAssertNil(removed.value)
        XCTAssertEqual(store.retainedRowCount, 1)
    }

    func testErrorDefaultsAndExplicitCollapsedChoiceSurviveRecreatedBindings() {
        let state = ConversationMessageInteractionState()
        let block = HistoryContentBlock(type: "tool_use", id: "tool-a")
        let first = state.binding(blockIndex: 3, block: block, initiallyExpanded: true)
        XCTAssertTrue(first.wrappedValue)
        first.wrappedValue = false
        XCTAssertFalse(state.binding(blockIndex: 3, block: block, initiallyExpanded: true).wrappedValue)
        XCTAssertEqual(state.choices.count, 1)
    }

    func testOriginalBlockIndexTypeAndToolIdentityKeepDisclosureChoicesSeparate() {
        let state = ConversationMessageInteractionState()
        let tool = HistoryContentBlock(type: "tool_use", id: "tool-a")
        state.binding(blockIndex: 3, block: tool).wrappedValue = true
        XCTAssertFalse(state.binding(blockIndex: 2, block: tool).wrappedValue)
        XCTAssertFalse(state.binding(blockIndex: 3, block: .init(type: "thinking")).wrappedValue)
        XCTAssertFalse(state.binding(blockIndex: 3, block: .init(type: "tool_use", id: "tool-b")).wrappedValue)
        XCTAssertTrue(state.binding(blockIndex: 3, block: tool).wrappedValue)
    }

    private func scope(file: String = "a", transcriptID: ConversationTranscriptID = .main)
        -> ConversationScrollInputScope {
        .init(file: URL(fileURLWithPath: "/tmp/native-reader-\(file).jsonl"), transcriptID: transcriptID)
    }

    private func key() -> ConversationMessageInteractionState.Key {
        .init(blockIndex: 2, block: .init(type: "tool_use", id: "fixture-tool"))
    }

    private final class WeakState {
        weak var value: ConversationMessageInteractionState?
        init(_ value: ConversationMessageInteractionState) { self.value = value }
    }
}
