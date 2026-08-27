import SwiftUI

/// A schedule of the work that already happened: every session as a bar on a shared time axis,
/// grouped by the directory it ran in or by the agent that ran it.
///
/// The rest of the app answers "what is in this session"; this answers "what was going on, where,
/// and by whom" — the question you ask when a week of work is spread over eight repositories and
/// four agents. Nothing here is scheduled or editable: the bars are history.
struct TimelineView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var store: ConversationStore

    @State private var zoom: TimelineZoom = .month
    @State private var grouping: TimelineGrouping = .directory
    @State private var window = TimelineWindow(zoom: .month, anchor: Date())
    @State private var trackWidth: CGFloat = 0
    @State private var panOrigin: TimelineWindow?
    @State private var hovered: TimelineEntry?

    /// Fixed measure of the left-hand label column, so every track shares one origin.
    private let labelWidth: CGFloat = 232

    var body: some View {
        VStack(spacing: 0) {
            header
            ruler
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityContainerIdentifier("view.timeline", label: appLanguage.localized("时间线"))
    }

    // MARK: - Header

    private var header: some View {
        DestinationHeader(
            title: appLanguage.localized("时间线"),
            subtitle: subtitle
        ) {
            HStack(spacing: Space.sm) {
                groupingPicker
                zoomPicker
                stepControls
            }
        }
    }

    private var subtitle: String {
        let sessions = groups.reduce(0) { $0 + $1.sessionCount }
        return appLanguage.localized("\(groups.count) 个分组 · \(sessions) 个会话")
    }

    private var groupingPicker: some View {
        Picker("", selection: $grouping) {
            ForEach(TimelineGrouping.allCases) { option in
                Text(appLanguage.localized(option.title)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("timeline.grouping")
    }

    private var zoomPicker: some View {
        Picker("", selection: $zoom) {
            ForEach(TimelineZoom.allCases) { option in
                Text(appLanguage.localized(option.title)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .onChange(of: zoom) { window = window.zoomed(to: $0) }
        .accessibilityIdentifier("timeline.zoom")
    }

    private var stepControls: some View {
        HStack(spacing: 2) {
            Button { window = window.shifted(byFractionOfSpan: -0.25) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.ccIcon)
            .help(appLanguage.localized("往前"))
            .accessibilityLabel(appLanguage.localized("往前"))
            .accessibilityIdentifier("timeline.step.back")

            Button { window = TimelineWindow(zoom: zoom, anchor: Date()) } label: {
                Text(appLanguage.localized("今天"))
            }
            .buttonStyle(CompactActionButtonStyle())
            .accessibilityIdentifier("timeline.today")

            Button { window = window.shifted(byFractionOfSpan: 0.25) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.ccIcon)
            .help(appLanguage.localized("往后"))
            .accessibilityLabel(appLanguage.localized("往后"))
            .accessibilityIdentifier("timeline.step.forward")
        }
    }

    // MARK: - Ruler

    /// The ruler doubles as the pan surface: dragging the dates is the gesture people try first, and
    /// putting it here keeps it from fighting the vertical scroll over the rows.
    private var ruler: some View {
        HStack(spacing: 0) {
            Text(appLanguage.localized(grouping == .directory ? "目录 / 会话" : "Agent / 会话"))
                .font(.ccLabel(.medium))
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .padding(.leading, Space.xl)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.date) { tick in
                        let x = window.x(of: tick.date, width: geometry.size.width)
                        Text(tick.label)
                            .font(.ccLabel(tick.major ? .medium : .regular))
                            .foregroundStyle(tick.major ? Theme.foreground : Theme.mutedForeground)
                            .fixedSize()
                            .padding(.leading, 4)
                            .offset(x: x)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onAppear { trackWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { trackWidth = $0 }
                .gesture(panGesture(width: geometry.size.width))
            }
        }
        .frame(height: 26)
        .padding(.bottom, Space.xs)
        .background(Theme.background)
        .hairline(.bottom)
        .accessibilityIdentifier("timeline.ruler")
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = panOrigin ?? window
                if panOrigin == nil { panOrigin = origin }
                guard width > 0 else { return }
                window = origin.shifted(byFractionOfSpan: -Double(value.translation.width / width))
            }
            .onEnded { _ in panOrigin = nil }
    }

    // MARK: - Rows

    @ViewBuilder private var content: some View {
        if groups.isEmpty {
            VStack {
                Spacer(minLength: 0)
                CCEmptyState(
                    symbol: "calendar",
                    title: appLanguage.localized("这段时间没有会话"),
                    message: appLanguage.localized("换个时间范围，或用「今天」回到当前。")
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("timeline.empty")
        } else {
            ScrollView(.vertical) {
                // Deliberately not a `LazyVStack`: inside one, the lanes below the first screen
                // reserved their height and then drew nothing at all, leaving blank rows exactly
                // where the busiest directories were. The row count here is groups plus lanes —
                // tens, not thousands — so laziness bought nothing to begin with.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.lanes) { lane in
                                laneRow(lane, group: group)
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .topLeading) { todayLine }
            .overlay(alignment: .bottom) { hoverBar }
            .accessibilityIdentifier("timeline.rows")
        }
    }

    private func groupHeader(_ group: TimelineGroup) -> some View {
        HStack(spacing: Space.sm) {
            if let source = group.source {
                AgentBrandMark(source: source, size: 14)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: Typography.caption))
                    .foregroundStyle(Theme.mutedForeground)
            }
            Text(group.title)
                .font(.ccBody(.medium))
                .lineLimit(1)
            CCBadge(text: "\(group.sessionCount)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Metrics.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.list)
        .hairline(.bottom)
        .help(group.subtitle ?? group.title)
        .accessibilityIdentifier("timeline.group.\(group.id)")
    }

    /// One lane: who (or where), then every session it ran as a capsule on the shared axis.
    private func laneRow(_ lane: TimelineLane, group: TimelineGroup) -> some View {
        HStack(spacing: 0) {
            laneLabel(lane)
                .frame(width: labelWidth, alignment: .leading)
            laneTrack(lane)
        }
        .frame(height: 30)
        .accessibilityIdentifier("timeline.lane.\(group.id).\(lane.id)")
    }

    private func laneLabel(_ lane: TimelineLane) -> some View {
        HStack(spacing: Space.xs + 2) {
            if let source = lane.source {
                AgentBrandMark(source: source, size: 13)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: Typography.label))
                    .foregroundStyle(Theme.faintForeground)
            }
            Text(lane.title)
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(lane.entries.count)")
                .font(.ccLabel())
                .foregroundStyle(Theme.faintForeground)
            Spacer(minLength: 0)
        }
        .padding(.leading, Space.xl + Space.md)
        .padding(.trailing, Space.sm)
    }

    /// The whole lane is one drawn view.
    ///
    /// A lane can hold hundreds of sessions; as individual buttons SwiftUI simply stopped laying
    /// the busiest ones out, leaving blank rows where the densest work was. Drawing them costs one
    /// view per lane instead of one per session, and clicks are resolved against the same geometry
    /// the drawing used.
    private func laneTrack(_ lane: TimelineLane) -> some View {
        Canvas { context, size in
            for tick in ticks where tick.major {
                let x = window.x(of: tick.date, width: size.width).rounded()
                guard x >= 0, x <= size.width else { continue }
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                    with: .color(Theme.separator.opacity(0.6))
                )
            }

            for entry in lane.entries {
                guard let bar = TimelineLayout.bar(
                    from: entry.start,
                    to: entry.end,
                    in: window,
                    width: size.width
                ) else { continue }
                let rect = CGRect(
                    x: bar.x,
                    y: TimelineLayout.capsuleTop,
                    width: bar.width,
                    height: TimelineLayout.capsuleHeight
                )
                let path = Path(roundedRect: rect, cornerRadius: 4, style: .continuous)
                let state = self.state(of: entry)
                context.fill(path, with: .color(state.fill))
                context.stroke(path, with: .color(state.stroke), lineWidth: 1)

                guard bar.width >= 72 else { continue }
                let title = entry.session.title.isEmpty
                    ? appLanguage.localized("无标题")
                    : entry.session.title
                let text = context.resolve(
                    Text(title)
                        .font(.ccLabel(.medium))
                        .foregroundColor(Theme.foreground)
                )
                // Clipped to its capsule so a long title cannot bleed into the next one.
                context.drawLayer { layer in
                    layer.clip(to: Path(rect.insetBy(dx: 4, dy: 0)))
                    layer.draw(
                        text,
                        at: CGPoint(x: rect.minX + 5, y: rect.midY),
                        anchor: .leading
                    )
                }
            }
        }
        // Flexible, never a fixed width: pinning the track to the measured width fed that width
        // back into the layout, and the row's demand squeezed the navigation rail out of the window.
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hovered = TimelineLayout.entry(
                    at: point,
                    in: lane.entries,
                    window: window,
                    width: trackWidth
                )
            case .ended:
                hovered = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0).onEnded { value in
                guard let entry = TimelineLayout.entry(
                    at: value.location,
                    in: lane.entries,
                    window: window,
                    width: trackWidth
                ) else { return }
                open(entry)
            }
        )
        .accessibilityElement()
        .accessibilityLabel(laneSummary(lane))
    }

    private func state(of entry: TimelineEntry) -> (fill: Color, stroke: Color) {
        if store.selectedMetadata?.id == entry.session.id {
            return (Theme.selection, Theme.accent.opacity(0.6))
        }
        if hovered?.id == entry.id {
            return (Theme.hover, Theme.accentText.opacity(0.5))
        }
        return (Theme.fill, Theme.separator)
    }

    private func laneSummary(_ lane: TimelineLane) -> String {
        "\(lane.title) · " + appLanguage.localized("\(lane.entries.count) 个会话")
    }

    /// A capsule can be two pixels wide, so pointing at one has to say what it is somewhere with
    /// room to say it. One fixed place beats a tooltip that chases the cursor.
    @ViewBuilder private var hoverBar: some View {
        if let hovered {
            HStack(spacing: Space.sm) {
                AgentBrandMark(source: hovered.session.source, size: 13)
                Text(hovered.session.title.isEmpty
                     ? appLanguage.localized("无标题")
                     : hovered.session.title)
                    .font(.ccCaption(.medium))
                    .lineLimit(1)
                Text(hoverDetail(hovered))
                    .font(.ccLabel())
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs + 2)
            .floatingSurface(radius: Radius.button)
            .padding(.bottom, Space.md)
            .allowsHitTesting(false)
            .accessibilityIdentifier("timeline.hover")
        }
    }

    private func hoverDetail(_ entry: TimelineEntry) -> String {
        let session = entry.session
        var parts = [ConversationPresentation.absoluteDate(session.createdAt, language: appLanguage)]
        if let cwd = session.cwd, !cwd.isEmpty { parts.append(cwd) }
        parts.append(appLanguage.localized("\(session.messageCount) 条消息"))
        return parts.joined(separator: " · ")
    }

    private var todayLine: some View {
        GeometryReader { geometry in
            let trackOrigin = labelWidth
            let available = max(0, geometry.size.width - trackOrigin)
            if window.contains(Date()), available > 0 {
                Rectangle()
                    .fill(Theme.accent.opacity(0.55))
                    .frame(width: 1)
                    .offset(x: trackOrigin + window.x(of: Date(), width: available))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Data

    private var sessions: [HistorySessionMetadata] {
        store.projects.flatMap(\.sessions)
    }

    private var groups: [TimelineGroup] {
        TimelineLayout.groups(from: sessions, grouping: grouping, window: window)
    }

    private var ticks: [TimelineTick] {
        TimelineLayout.ticks(
            in: window,
            zoom: zoom,
            calendar: .current,
            locale: appLanguage.locale
        )
    }

    private func tooltip(_ entry: TimelineEntry) -> String {
        let session = entry.session
        var parts = [
            ConversationPresentation.sourceName(rawValue: session.source.rawValue),
            session.cwd ?? session.project,
            ConversationPresentation.absoluteDate(session.createdAt, language: appLanguage),
            appLanguage.localized("\(session.messageCount) 条消息"),
        ]
        if !session.title.isEmpty { parts.insert(session.title, at: 0) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func open(_ entry: TimelineEntry) {
        model.selected = .conversations
        Task { await store.select(entry.session) }
    }
}
