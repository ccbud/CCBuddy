import XCTest

@testable import CCBuddy

/// The timeline's whole correctness is arithmetic: where a bar lands, which bars are worth drawing,
/// and what the ruler says. None of it needs a window on screen.
final class TimelineLayoutTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func session(
        _ id: String,
        source: HistorySource = .claude,
        cwd: String = "/work/alpha",
        project: String = "alpha",
        from: String,
        to: String,
        title: String = "Session"
    ) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: id,
            file: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            source: source,
            dirID: "fixture",
            dirLabel: "Fixture",
            sessionID: id,
            cwd: cwd,
            project: project,
            title: title,
            autoTitle: title,
            createdAt: date(from),
            lastActivity: date(to),
            sizeBytes: 64,
            messageCount: 3
        )
    }

    // MARK: - Window

    func testTheWindowPutsNowNearTheRightEdgeRatherThanOnIt() {
        let now = date("2026-08-27T00:00:00Z")
        let window = TimelineWindow(zoom: .month, anchor: now)

        XCTAssertTrue(window.contains(now))
        let fraction = window.fraction(of: now)
        XCTAssertGreaterThan(fraction, 0.9, "the present should be at the leading edge of attention")
        XCTAssertLessThan(fraction, 1.0, "with a little room after it, so today's bar is not clipped")
    }

    func testPanningMovesBothEdgesByTheSameAmount() {
        let window = TimelineWindow(zoom: .week, anchor: date("2026-08-27T00:00:00Z"))
        let moved = window.shifted(byFractionOfSpan: -0.5)

        XCTAssertEqual(moved.span, window.span, accuracy: 0.5)
        XCTAssertEqual(
            moved.end.timeIntervalSince(window.end),
            -window.span / 2,
            accuracy: 0.5
        )
    }

    func testZoomingHoldsTheRightEdgeSoTheViewDoesNotLeaveThePresent() {
        let window = TimelineWindow(zoom: .week, anchor: date("2026-08-27T00:00:00Z"))
        let zoomed = window.zoomed(to: .year)

        XCTAssertEqual(zoomed.end, window.end)
        XCTAssertEqual(zoomed.span, TimelineZoom.year.span, accuracy: 0.5)
    }

    // MARK: - Bars

    func testABarSpansTheShareOfTheWindowItsSessionOccupied() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-11T00:00:00Z")
        )
        let bar = TimelineLayout.bar(
            from: date("2026-08-03T00:00:00Z"),
            to: date("2026-08-05T00:00:00Z"),
            in: window,
            width: 1_000
        )

        XCTAssertEqual(bar?.x ?? -1, 200, accuracy: 0.5)
        XCTAssertEqual(bar?.width ?? -1, 200, accuracy: 0.5)
    }

    func testABarThatStartedBeforeTheWindowIsClippedToIt() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-11T00:00:00Z")
        )
        let bar = TimelineLayout.bar(
            from: date("2026-07-20T00:00:00Z"),
            to: date("2026-08-03T00:00:00Z"),
            in: window,
            width: 1_000
        )

        XCTAssertEqual(bar?.x ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(bar?.width ?? -1, 200, accuracy: 0.5)
    }

    func testAnInstantSessionStillGetsAClickableBar() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-31T00:00:00Z")
        )
        let moment = date("2026-08-15T00:00:00Z")
        let bar = TimelineLayout.bar(from: moment, to: moment, in: window, width: 800)

        XCTAssertEqual(bar?.width ?? 0, TimelineLayout.minimumBarWidth, accuracy: 0.01)
        XCTAssertNotNil(bar)
    }

    func testAMinimumWidthBarAtTheRightEdgeStaysInsideTheTrack() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-31T00:00:00Z")
        )
        let bar = TimelineLayout.bar(
            from: date("2026-08-31T00:00:00Z"),
            to: date("2026-08-31T00:00:00Z"),
            in: window,
            width: 500
        )

        let unwrapped = try? XCTUnwrap(bar)
        XCTAssertNotNil(unwrapped)
        XCTAssertLessThanOrEqual((unwrapped?.maxX ?? .infinity), 500)
    }

    func testSessionsOutsideTheWindowGetNoBarAtAll() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-11T00:00:00Z")
        )
        XCTAssertNil(TimelineLayout.bar(
            from: date("2026-07-01T00:00:00Z"),
            to: date("2026-07-02T00:00:00Z"),
            in: window,
            width: 400
        ))
        XCTAssertNil(TimelineLayout.bar(
            from: date("2026-09-01T00:00:00Z"),
            to: date("2026-09-02T00:00:00Z"),
            in: window,
            width: 400
        ))
    }

    // MARK: - Hit testing

    private func hitWindow() -> TimelineWindow {
        TimelineWindow(start: date("2026-08-01T00:00:00Z"), end: date("2026-08-11T00:00:00Z"))
    }

    func testAClickOnACapsuleFindsItsSession() {
        let window = hitWindow()
        let entries = [
            TimelineEntry(session: session("a", from: "2026-08-02T00:00:00Z", to: "2026-08-03T00:00:00Z")),
            TimelineEntry(session: session("b", from: "2026-08-06T00:00:00Z", to: "2026-08-07T00:00:00Z")),
        ]

        let hit = TimelineLayout.entry(
            at: CGPoint(x: 550, y: TimelineLayout.capsuleTop + 8),
            in: entries,
            window: window,
            width: 1_000
        )

        XCTAssertEqual(hit?.id, "b")
    }

    func testAClickAboveOrBelowTheCapsuleBandMissesEverything() {
        let window = hitWindow()
        let entries = [
            TimelineEntry(session: session("a", from: "2026-08-02T00:00:00Z", to: "2026-08-03T00:00:00Z")),
        ]

        XCTAssertNil(TimelineLayout.entry(
            at: CGPoint(x: 150, y: 0),
            in: entries,
            window: window,
            width: 1_000
        ))
        XCTAssertNil(TimelineLayout.entry(
            at: CGPoint(x: 150, y: 29),
            in: entries,
            window: window,
            width: 1_000
        ))
    }

    func testAClickInTheGapBetweenCapsulesOpensNothing() {
        let window = hitWindow()
        let entries = [
            TimelineEntry(session: session("a", from: "2026-08-02T00:00:00Z", to: "2026-08-03T00:00:00Z")),
            TimelineEntry(session: session("b", from: "2026-08-08T00:00:00Z", to: "2026-08-09T00:00:00Z")),
        ]

        let hit = TimelineLayout.entry(
            at: CGPoint(x: 550, y: TimelineLayout.capsuleTop + 8),
            in: entries,
            window: window,
            width: 1_000
        )

        XCTAssertNil(hit)
    }

    func testOverlappingCapsulesResolveToTheOneDrawnOnTop() {
        let window = hitWindow()
        let entries = [
            TimelineEntry(session: session("under", from: "2026-08-02T00:00:00Z", to: "2026-08-06T00:00:00Z")),
            TimelineEntry(session: session("over", from: "2026-08-03T00:00:00Z", to: "2026-08-05T00:00:00Z")),
        ]

        let hit = TimelineLayout.entry(
            at: CGPoint(x: 400, y: TimelineLayout.capsuleTop + 8),
            in: entries,
            window: window,
            width: 1_000
        )

        XCTAssertEqual(hit?.id, "over", "the last drawn capsule is the visible one")
    }

    func testAnInstantSessionCanStillBeClicked() {
        let window = hitWindow()
        let moment = "2026-08-05T00:00:00Z"
        let entries = [TimelineEntry(session: session("x", from: moment, to: moment))]

        let bar = try? XCTUnwrap(TimelineLayout.bar(
            from: date(moment),
            to: date(moment),
            in: window,
            width: 1_000
        ))
        let hit = TimelineLayout.entry(
            at: CGPoint(x: (bar?.x ?? 0) + 2, y: TimelineLayout.capsuleTop + 8),
            in: entries,
            window: window,
            width: 1_000
        )

        XCTAssertEqual(hit?.id, "x")
    }

    // MARK: - Ruler

    func testTheYearRulerLabelsMonthsAndEmphasisesQuarters() {
        let window = TimelineWindow(
            start: date("2026-01-01T00:00:00Z"),
            end: date("2026-12-31T00:00:00Z")
        )
        let ticks = TimelineLayout.ticks(
            in: window,
            zoom: .year,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ticks.count, 12)
        XCTAssertEqual(ticks.filter(\.major).count, 4, "one emphasis per quarter")
        XCTAssertTrue(ticks[0].major)
    }

    func testTheWeekRulerLabelsEveryDay() {
        let window = TimelineWindow(
            start: date("2026-08-24T00:00:00Z"),
            end: date("2026-08-30T00:00:00Z")
        )
        let ticks = TimelineLayout.ticks(
            in: window,
            zoom: .week,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(ticks.count, 7)
        XCTAssertTrue(ticks.allSatisfy { window.contains($0.date) })
    }

    func testTheRulerRefusesToRunAwayOnAnAbsurdWindow() {
        let window = TimelineWindow(
            start: date("1990-01-01T00:00:00Z"),
            end: date("2090-01-01T00:00:00Z")
        )
        let ticks = TimelineLayout.ticks(
            in: window,
            zoom: .week,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertLessThanOrEqual(ticks.count, 400)
    }

    // MARK: - Grouping

    func testGroupingByDirectoryKeepsAgentsTogetherUnderTheirWorkingDirectory() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-31T00:00:00Z")
        )
        let sessions = [
            session("a", source: .claude, cwd: "/work/alpha", project: "alpha",
                    from: "2026-08-02T00:00:00Z", to: "2026-08-02T02:00:00Z"),
            session("b", source: .codex, cwd: "/work/alpha", project: "alpha",
                    from: "2026-08-03T00:00:00Z", to: "2026-08-03T01:00:00Z"),
            session("c", source: .codex, cwd: "/work/beta", project: "beta",
                    from: "2026-08-04T00:00:00Z", to: "2026-08-04T01:00:00Z"),
        ]

        let groups = TimelineLayout.groups(from: sessions, grouping: .directory, window: window)

        XCTAssertEqual(groups.map(\.id), ["/work/beta", "/work/alpha"], "newest activity first")
        XCTAssertNil(groups.first?.source, "a directory group is not an agent")

        let alpha = try? XCTUnwrap(groups.last)
        XCTAssertEqual(
            alpha?.lanes.map(\.source),
            [.codex, .claude],
            "one lane per agent that worked in the directory, most recent first"
        )
        XCTAssertEqual(alpha?.lanes.last?.entries.map(\.id), ["a"])
        XCTAssertEqual(alpha?.sessionCount, 2)
    }

    func testGroupingByAgentCollectsOneAgentsWorkAcrossDirectories() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-31T00:00:00Z")
        )
        let sessions = [
            session("a", source: .codex, cwd: "/work/alpha", project: "alpha",
                    from: "2026-08-02T00:00:00Z", to: "2026-08-02T02:00:00Z"),
            session("b", source: .codex, cwd: "/work/beta", project: "beta",
                    from: "2026-08-03T00:00:00Z", to: "2026-08-03T01:00:00Z"),
            session("c", source: .claude, cwd: "/work/beta", project: "beta",
                    from: "2026-08-01T00:00:00Z", to: "2026-08-01T01:00:00Z"),
        ]

        let groups = TimelineLayout.groups(from: sessions, grouping: .agent, window: window)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.source, .codex)
        XCTAssertEqual(
            groups.first?.lanes.map(\.title),
            ["beta", "alpha"],
            "one lane per directory the agent touched, most recent first"
        )
        XCTAssertEqual(groups.first?.sessionCount, 2)
    }

    func testOnlySessionsOverlappingTheWindowAreGrouped() {
        let window = TimelineWindow(
            start: date("2026-08-10T00:00:00Z"),
            end: date("2026-08-20T00:00:00Z")
        )
        let sessions = [
            session("before", from: "2026-07-01T00:00:00Z", to: "2026-07-02T00:00:00Z"),
            session("straddling", from: "2026-08-09T00:00:00Z", to: "2026-08-11T00:00:00Z"),
            session("after", from: "2026-09-01T00:00:00Z", to: "2026-09-02T00:00:00Z"),
        ]

        let groups = TimelineLayout.groups(from: sessions, grouping: .directory, window: window)

        XCTAssertEqual(
            groups.flatMap { $0.lanes.flatMap { $0.entries.map(\.id) } },
            ["straddling"]
        )
    }

    func testASessionWithoutAWorkingDirectoryStillLandsSomewhere() {
        let window = TimelineWindow(
            start: date("2026-08-01T00:00:00Z"),
            end: date("2026-08-31T00:00:00Z")
        )
        var orphan = session("x", from: "2026-08-05T00:00:00Z", to: "2026-08-05T01:00:00Z")
        orphan.cwd = nil
        orphan.project = ""

        let groups = TimelineLayout.groups(from: [orphan], grouping: .directory, window: window)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessionCount, 1)
        XCTAssertFalse(groups.first?.title.isEmpty ?? true)
    }

    func testAnEmptyLibraryProducesNoGroups() {
        let window = TimelineWindow(zoom: .month, anchor: date("2026-08-27T00:00:00Z"))
        XCTAssertTrue(TimelineLayout.groups(from: [], grouping: .directory, window: window).isEmpty)
    }

    func testAnEntryClampsAnEndThatPrecedesItsStart() {
        var reversed = session("r", from: "2026-08-05T00:00:00Z", to: "2026-08-05T00:00:00Z")
        reversed.lastActivity = reversed.createdAt.addingTimeInterval(-3_600)

        let entry = TimelineEntry(session: reversed)

        XCTAssertEqual(entry.end, entry.start, "a bar can never run backwards")
    }
}
