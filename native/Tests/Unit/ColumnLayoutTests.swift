import XCTest

@testable import CCBuddy

/// Column widths outlive the window, so the rules that keep a remembered width usable are worth
/// pinning: a build that narrows the limits, or a defaults file edited by hand, must never leave a
/// column too wide to fit or too narrow to read.
@MainActor
final class ColumnLayoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "dev.ccbud.tests.columns.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testAFreshInstallStartsAtTheDesignedWidths() {
        let layout = ColumnLayout(store: defaults)

        XCTAssertEqual(layout.railWidth, ColumnLayout.rail.default)
        XCTAssertEqual(layout.streamWidth, ColumnLayout.stream.default)
        XCTAssertTrue(layout.railVisible)
        XCTAssertTrue(layout.streamVisible)
    }

    func testWidthsAndVisibilitySurviveARelaunch() {
        let layout = ColumnLayout(store: defaults)
        layout.resize(ColumnLayout.rail, to: 300)
        layout.resize(ColumnLayout.stream, to: 420)
        layout.toggleStream()

        let relaunched = ColumnLayout(store: defaults)

        XCTAssertEqual(relaunched.railWidth, 300)
        XCTAssertEqual(relaunched.streamWidth, 420)
        XCTAssertTrue(relaunched.railVisible)
        XCTAssertFalse(relaunched.streamVisible, "a column put away stays away")
    }

    func testADragBeyondTheLimitsStopsAtThem() {
        let layout = ColumnLayout(store: defaults)

        layout.resize(ColumnLayout.rail, to: 40)
        XCTAssertEqual(layout.railWidth, ColumnLayout.rail.range.lowerBound)

        layout.resize(ColumnLayout.rail, to: 9_000)
        XCTAssertEqual(layout.railWidth, ColumnLayout.rail.range.upperBound)
    }

    func testAStoredWidthOutsideTheCurrentLimitsIsBroughtBackInside() {
        defaults.set(Double(4_000), forKey: ColumnLayout.rail.key)
        defaults.set(Double(10), forKey: ColumnLayout.stream.key)

        let layout = ColumnLayout(store: defaults)

        XCTAssertEqual(layout.railWidth, ColumnLayout.rail.range.upperBound)
        XCTAssertEqual(layout.streamWidth, ColumnLayout.stream.range.lowerBound)
    }

    func testANonsenseStoredWidthFallsBackToTheDefault() {
        defaults.set(Double.nan, forKey: ColumnLayout.stream.key)

        let layout = ColumnLayout(store: defaults)

        XCTAssertEqual(layout.streamWidth, ColumnLayout.stream.default)
    }

    func testResetReturnsAColumnToItsDesignedWidth() {
        let layout = ColumnLayout(store: defaults)
        layout.resize(ColumnLayout.stream, to: ColumnLayout.stream.range.upperBound)

        layout.reset(ColumnLayout.stream)

        XCTAssertEqual(layout.streamWidth, ColumnLayout.stream.default)
    }

    func testTheInspectorIsRememberedLikeTheOtherColumns() {
        let layout = ColumnLayout(store: defaults)
        XCTAssertTrue(layout.inspectorVisible)

        layout.resize(ColumnLayout.inspector, to: 999)
        layout.toggleInspector()

        let relaunched = ColumnLayout(store: defaults)
        XCTAssertEqual(relaunched.inspectorWidth, ColumnLayout.inspector.range.upperBound)
        XCTAssertFalse(relaunched.inspectorVisible)
    }

    func testResizingOneColumnLeavesTheOtherAlone() {
        let layout = ColumnLayout(store: defaults)
        let rail = layout.railWidth

        let inspector = layout.inspectorWidth
        layout.resize(ColumnLayout.stream, to: 500)

        XCTAssertEqual(layout.railWidth, rail)
        XCTAssertEqual(layout.inspectorWidth, inspector)
        XCTAssertEqual(layout.streamWidth, 500)
    }

    // MARK: - Fitting

    private func resolve(
        _ available: CGFloat,
        stream: CGFloat = 336,
        inspector: CGFloat = 288,
        wantsStream: Bool = true,
        wantsInspector: Bool = true
    ) -> ColumnLayout.Resolved {
        ColumnLayout.resolved(
            available: available,
            streamWidth: stream,
            inspectorWidth: inspector,
            wantsStream: wantsStream,
            wantsInspector: wantsInspector
        )
    }

    func testAWideWindowGivesEveryColumnTheWidthItWasDragged() {
        let result = resolve(1_400)

        XCTAssertTrue(result.streamVisible)
        XCTAssertTrue(result.inspectorVisible)
        XCTAssertEqual(result.streamWidth, 336)
        XCTAssertEqual(result.inspectorWidth, 288)
    }

    func testTheOverviewNarrowsBeforeAnythingIsDropped() {
        // 336 + 288 + rules leaves 374 to read in — six points short. Losing the whole column over
        // that is not a trade anyone would choose.
        let result = resolve(1_000)

        XCTAssertTrue(result.inspectorVisible, "a column is not dropped while it can still narrow")
        XCTAssertEqual(result.inspectorWidth, 282, "it gives up exactly the six points that were missing")
        XCTAssertEqual(result.streamWidth, 336, "the stream is only touched once the overview cannot give more")
    }

    func testTheStreamNarrowsOnlyAfterTheOverviewHitsItsMinimum() {
        let result = resolve(940)

        XCTAssertTrue(result.inspectorVisible)
        XCTAssertEqual(result.inspectorWidth, ColumnLayout.inspector.range.lowerBound)
        XCTAssertEqual(result.streamWidth, 318)
        XCTAssertGreaterThanOrEqual(result.streamWidth, ColumnLayout.stream.range.lowerBound)
    }

    func testTheOverviewIsDroppedOnlyWhenBothMinimumsStillDoNotFit() {
        let result = resolve(860)

        XCTAssertFalse(result.inspectorVisible)
        XCTAssertTrue(result.streamVisible)
        XCTAssertEqual(
            result.streamWidth,
            336,
            "with the overview gone the stream gets its own width back rather than staying squeezed"
        )
    }

    func testTheStreamYieldsLast() {
        let result = resolve(600)

        XCTAssertFalse(result.streamVisible)
        XCTAssertFalse(result.inspectorVisible)
    }

    func testAColumnAlreadyPutAwayIsNotBroughtBackByRoom() {
        let result = resolve(2_000, wantsStream: false, wantsInspector: false)

        XCTAssertFalse(result.streamVisible)
        XCTAssertFalse(result.inspectorVisible)
    }

    func testTheOverviewSurvivesWhenTheStreamIsAlreadyAway() {
        let result = resolve(700, wantsStream: false)

        XCTAssertFalse(result.streamVisible)
        XCTAssertTrue(result.inspectorVisible, "without the stream there is room to read beside it")
    }

    func testAnUnmeasuredWindowChangesNothing() {
        let result = resolve(0)

        XCTAssertTrue(result.streamVisible)
        XCTAssertTrue(result.inspectorVisible)
        XCTAssertEqual(result.streamWidth, 336)
    }

    func testSqueezingNeverWritesBackToTheStoredWidths() {
        let layout = ColumnLayout(store: defaults)
        layout.resize(ColumnLayout.stream, to: 400)
        layout.resize(ColumnLayout.inspector, to: 400)

        _ = resolve(900, stream: layout.streamWidth, inspector: layout.inspectorWidth)

        XCTAssertEqual(layout.streamWidth, 400, "a narrow window must not undo a deliberate drag")
        XCTAssertEqual(layout.inspectorWidth, 400)
    }

    func testHidingAColumnKeepsTheWidthItWillComeBackAt() {
        let layout = ColumnLayout(store: defaults)
        layout.resize(ColumnLayout.rail, to: 320)

        layout.toggleRail()
        layout.toggleRail()

        XCTAssertTrue(layout.railVisible)
        XCTAssertEqual(layout.railWidth, 320, "coming back at the default would undo a deliberate size")
    }
}
