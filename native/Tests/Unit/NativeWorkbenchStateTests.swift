import XCTest

@testable import CCBuddy

@MainActor
final class NativeWorkbenchStateTests: XCTestCase {
    func testFocusRestoresEveryOriginalVisibilityAndWidth() throws {
        let suite = "dev.ccbud.tests.focus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = ColumnLayout(store: defaults)
        layout.streamVisible = false
        layout.resize(ColumnLayout.rail, to: 280)
        layout.resize(ColumnLayout.inspector, to: 310)

        layout.toggleFocusMode()
        XCTAssertTrue(layout.focusModeEnabled)
        XCTAssertFalse(layout.railVisible)
        XCTAssertFalse(layout.streamVisible)
        XCTAssertFalse(layout.inspectorVisible)

        // Temporarily revealing a column while focused must not overwrite the saved layout.
        layout.toggleRail()
        layout.endFocusMode()
        XCTAssertFalse(layout.focusModeEnabled)
        XCTAssertTrue(layout.railVisible)
        XCTAssertFalse(layout.streamVisible)
        XCTAssertTrue(layout.inspectorVisible)
        XCTAssertEqual(layout.railWidth, 280)
        XCTAssertEqual(layout.inspectorWidth, 310)
    }

    func testRelaunchDuringFocusLoadsTheLastDeliberateLayout() throws {
        let suite = "dev.ccbud.tests.focus-relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let running = ColumnLayout(store: defaults)
        running.inspectorVisible = false
        running.resize(ColumnLayout.stream, to: 390)
        running.toggleFocusMode()
        running.toggleRail()

        // Do not call endFocusMode: this represents a crash or forced quit before view cleanup.
        let relaunched = ColumnLayout(store: defaults)
        XCTAssertFalse(relaunched.focusModeEnabled)
        XCTAssertTrue(relaunched.railVisible)
        XCTAssertTrue(relaunched.streamVisible)
        XCTAssertFalse(relaunched.inspectorVisible)
        XCTAssertEqual(relaunched.streamWidth, 390)

        running.endFocusMode()
        running.streamVisible = false
        XCTAssertFalse(ColumnLayout(store: defaults).streamVisible,
                       "Ordinary layout changes must resume persistence after leaving focus")
    }
}
