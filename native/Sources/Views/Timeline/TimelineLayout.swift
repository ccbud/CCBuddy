import Foundation

/// How much time the track shows at once.
enum TimelineZoom: String, CaseIterable, Identifiable, Sendable {
    case week, month, quarter, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "周"
        case .month: "月"
        case .quarter: "季"
        case .year: "年"
        }
    }

    var span: TimeInterval {
        switch self {
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 91 * 86_400
        case .year: 365 * 86_400
        }
    }

    /// Unit and stride of the ruler's ticks, and the coarser unit whose boundaries are emphasised.
    fileprivate var ruler: (unit: Calendar.Component, step: Int, major: Calendar.Component) {
        switch self {
        case .week: (.day, 1, .weekOfYear)
        case .month: (.day, 3, .month)
        case .quarter: (.weekOfYear, 1, .month)
        case .year: (.month, 1, .quarter)
        }
    }
}

/// What the rows are grouped by. Both dimensions stay visible either way: grouping by directory
/// puts the agent's mark on every row, and grouping by agent puts the directory there instead.
enum TimelineGrouping: String, CaseIterable, Identifiable, Sendable {
    case directory, agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directory: "按目录"
        case .agent: "按 Agent"
        }
    }
}

/// The visible span of time, in absolute dates. Panning and zooming are expressed here rather than
/// in the view so both are ordinary arithmetic that can be checked without a window on screen.
struct TimelineWindow: Equatable, Sendable {
    var start: Date
    var end: Date

    /// A window ending shortly after `anchor`, so "now" sits near the right edge with a little room
    /// to breathe rather than exactly on it.
    init(zoom: TimelineZoom, anchor: Date) {
        let span = zoom.span
        end = anchor.addingTimeInterval(span * 0.08)
        start = end.addingTimeInterval(-span)
    }

    init(start: Date, end: Date) {
        self.start = start
        self.end = min(start.addingTimeInterval(-1), end) == end ? start.addingTimeInterval(1) : end
    }

    var span: TimeInterval { max(1, end.timeIntervalSince(start)) }

    func fraction(of date: Date) -> Double {
        date.timeIntervalSince(start) / span
    }

    func x(of date: Date, width: CGFloat) -> CGFloat {
        CGFloat(fraction(of: date)) * width
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    /// Moves by a share of the visible span. Positive moves forward in time.
    func shifted(byFractionOfSpan fraction: Double) -> TimelineWindow {
        let delta = span * fraction
        return TimelineWindow(
            start: start.addingTimeInterval(delta),
            end: end.addingTimeInterval(delta)
        )
    }

    /// Changes span while holding the right edge, which is where the eye already is: zooming out
    /// from today should reveal more history, not scroll away from the present.
    func zoomed(to zoom: TimelineZoom) -> TimelineWindow {
        TimelineWindow(start: end.addingTimeInterval(-zoom.span), end: end)
    }
}

/// A bar's horizontal extent inside a track of a given width.
struct TimelineBar: Equatable, Sendable {
    var x: CGFloat
    var width: CGFloat

    var maxX: CGFloat { x + width }
}

/// One labelled position on the ruler.
struct TimelineTick: Equatable, Sendable {
    var date: Date
    var label: String
    var major: Bool
}

/// A row: one session, drawn as one bar.
struct TimelineEntry: Identifiable, Equatable, Sendable {
    var session: HistorySessionMetadata

    var id: String { session.id }
    var start: Date { session.createdAt }
    /// A session that wrote a single record has identical timestamps; the layout gives it a minimum
    /// width rather than a zero-width bar nobody can click.
    var end: Date { max(session.lastActivity, session.createdAt) }
}

/// One horizontal lane inside a group: the other half of the pair the grouping did not take. A
/// directory group therefore has one lane per agent that worked in it, and an agent group one lane
/// per directory it touched — which is the whole question this view exists to answer, on one screen
/// instead of one row per session.
struct TimelineLane: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    /// Set when the lane *is* an agent, so its label can carry the brand mark.
    var source: HistorySource?
    var entries: [TimelineEntry]

    var lastActivity: Date { entries.map(\.end).max() ?? .distantPast }
}

struct TimelineGroup: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    /// Set when the group *is* an agent.
    var source: HistorySource?
    var lanes: [TimelineLane]

    var sessionCount: Int { lanes.reduce(0) { $0 + $1.entries.count } }
    var lastActivity: Date { lanes.map(\.lastActivity).max() ?? .distantPast }
}

enum TimelineLayout {
    /// Smallest bar that still reads as a bar and can be clicked.
    static let minimumBarWidth: CGFloat = 6

    static func bar(
        from start: Date,
        to end: Date,
        in window: TimelineWindow,
        width: CGFloat,
        minimum: CGFloat = minimumBarWidth
    ) -> TimelineBar? {
        guard width > 0, end >= start else { return nil }
        guard end >= window.start, start <= window.end else { return nil }
        let rawStart = window.x(of: start, width: width)
        let rawEnd = window.x(of: end, width: width)
        var x = max(0, rawStart)
        var barWidth = min(width, rawEnd) - x
        if barWidth < minimum {
            barWidth = minimum
            // Keep a clipped bar inside the track instead of letting the minimum push it out.
            x = min(x, width - minimum)
            x = max(0, x)
        }
        return TimelineBar(x: x, width: min(barWidth, width - x))
    }

    /// Vertical extent of a capsule inside a lane row, so the drawing and the hit test agree.
    static let capsuleTop: CGFloat = 7
    static let capsuleHeight: CGFloat = 16

    /// The session a click at `point` landed on, searched newest-drawn first so the capsule you can
    /// see on top of an overlap is the one that opens.
    static func entry(
        at point: CGPoint,
        in entries: [TimelineEntry],
        window: TimelineWindow,
        width: CGFloat,
        tolerance: CGFloat = 2
    ) -> TimelineEntry? {
        guard point.y >= capsuleTop - tolerance,
              point.y <= capsuleTop + capsuleHeight + tolerance else { return nil }
        for entry in entries.reversed() {
            guard let bar = bar(from: entry.start, to: entry.end, in: window, width: width)
            else { continue }
            if point.x >= bar.x - tolerance, point.x <= bar.maxX + tolerance { return entry }
        }
        return nil
    }

    static func ticks(
        in window: TimelineWindow,
        zoom: TimelineZoom,
        calendar: Calendar,
        locale: Locale
    ) -> [TimelineTick] {
        let ruler = zoom.ruler
        guard let anchor = calendar.dateInterval(of: ruler.unit, for: window.start)?.start
        else { return [] }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(ruler.unit == .month ? "MMM" : "Md")

        var ticks: [TimelineTick] = []
        var cursor = anchor
        // A pathological window (a decade at day resolution) must not spin here; the ruler is only
        // ever asked for one screen's worth.
        while cursor <= window.end, ticks.count < 400 {
            if cursor >= window.start {
                let major = calendar.dateInterval(of: ruler.major, for: cursor)?.start == cursor
                ticks.append(
                    TimelineTick(date: cursor, label: formatter.string(from: cursor), major: major)
                )
            }
            guard let next = calendar.date(byAdding: ruler.unit, value: ruler.step, to: cursor),
                  next > cursor else { break }
            cursor = next
        }
        return ticks
    }

    /// Groups the sessions that overlap the window, newest group first, splitting each group into
    /// lanes by the dimension the grouping did not take. Sessions inside a lane keep start order so
    /// the lane reads left to right the way the work happened.
    static func groups(
        from sessions: [HistorySessionMetadata],
        grouping: TimelineGrouping,
        window: TimelineWindow
    ) -> [TimelineGroup] {
        let visible = sessions.filter { session in
            let end = max(session.lastActivity, session.createdAt)
            return end >= window.start && session.createdAt <= window.end
        }
        guard !visible.isEmpty else { return [] }

        var order: [String] = []
        var buckets: [String: [HistorySessionMetadata]] = [:]
        for session in visible {
            let key = groupKey(for: session, grouping: grouping)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(session)
        }

        return order.compactMap { key -> TimelineGroup? in
            guard let members = buckets[key], let first = members.first else { return nil }
            let lanes = self.lanes(in: members, grouping: grouping)
            switch grouping {
            case .directory:
                return TimelineGroup(
                    id: key,
                    title: directoryTitle(for: first, key: key),
                    subtitle: first.cwd,
                    source: nil,
                    lanes: lanes
                )
            case .agent:
                return TimelineGroup(
                    id: key,
                    title: ConversationPresentation.sourceName(rawValue: first.source.rawValue),
                    subtitle: nil,
                    source: first.source,
                    lanes: lanes
                )
            }
        }
        .sorted { left, right in
            if left.lastActivity != right.lastActivity { return left.lastActivity > right.lastActivity }
            return left.title < right.title
        }
    }

    private static func lanes(
        in members: [HistorySessionMetadata],
        grouping: TimelineGrouping
    ) -> [TimelineLane] {
        var order: [String] = []
        var buckets: [String: [HistorySessionMetadata]] = [:]
        for session in members {
            let key = laneKey(for: session, grouping: grouping)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(session)
        }

        return order.compactMap { key -> TimelineLane? in
            guard let members = buckets[key], let first = members.first else { return nil }
            let entries = members
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id < $1.id
                }
                .map(TimelineEntry.init)
            switch grouping {
            case .directory:
                return TimelineLane(
                    id: key,
                    title: ConversationPresentation.sourceName(rawValue: first.source.rawValue),
                    source: first.source,
                    entries: entries
                )
            case .agent:
                return TimelineLane(
                    id: key,
                    title: directoryTitle(for: first, key: key),
                    source: nil,
                    entries: entries
                )
            }
        }
        .sorted { left, right in
            if left.lastActivity != right.lastActivity { return left.lastActivity > right.lastActivity }
            return left.title < right.title
        }
    }

    private static func directoryTitle(for session: HistorySessionMetadata, key: String) -> String {
        if !session.project.isEmpty { return session.project }
        let leaf = (key as NSString).lastPathComponent
        return leaf.isEmpty ? key : leaf
    }

    private static func groupKey(
        for session: HistorySessionMetadata,
        grouping: TimelineGrouping
    ) -> String {
        grouping == .directory ? directoryKey(for: session) : session.source.rawValue
    }

    private static func laneKey(
        for session: HistorySessionMetadata,
        grouping: TimelineGrouping
    ) -> String {
        grouping == .directory ? session.source.rawValue : directoryKey(for: session)
    }

    private static func directoryKey(for session: HistorySessionMetadata) -> String {
        let cwd = session.cwd ?? ""
        if !cwd.isEmpty { return cwd }
        return session.project.isEmpty ? "—" : session.project
    }
}
