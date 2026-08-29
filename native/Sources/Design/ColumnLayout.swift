import SwiftUI

/// Where the window's vertical rules sit, and whether the columns behind them are shown at all.
///
/// This is view state, not configuration: it is remembered per install rather than written into
/// `config.json`, which the gateway watches and would restart for every drag of a divider.
@MainActor
final class ColumnLayout: ObservableObject {
    /// A resizable column: its stored width and the range a drag is allowed to reach.
    struct Column {
        let key: String
        let range: ClosedRange<CGFloat>
        let `default`: CGFloat
    }

    nonisolated static let rail = Column(
        key: "layout.rail.width", range: 180...380, default: 224
    )
    nonisolated static let stream = Column(
        key: "layout.stream.width", range: 260...560, default: 336
    )
    nonisolated static let inspector = Column(
        key: "layout.inspector.width", range: 240...420, default: 288
    )

    @Published var railWidth: CGFloat { didSet { store.set(railWidth, forKey: Self.rail.key) } }
    @Published var streamWidth: CGFloat { didSet { store.set(streamWidth, forKey: Self.stream.key) } }
    @Published var inspectorWidth: CGFloat {
        didSet { store.set(inspectorWidth, forKey: Self.inspector.key) }
    }
    @Published var railVisible: Bool { didSet { store.set(railVisible, forKey: Self.railVisibleKey) } }
    @Published var streamVisible: Bool { didSet { store.set(streamVisible, forKey: Self.streamVisibleKey) } }
    /// The session overview. It is a column rather than a popover — the facts about a session are
    /// something you read *alongside* the transcript, and a sheet that covers the transcript to
    /// show them is the wrong shape. It only takes space while a session is open.
    @Published var inspectorVisible: Bool {
        didSet { store.set(inspectorVisible, forKey: Self.inspectorVisibleKey) }
    }

    private static let railVisibleKey = "layout.rail.visible"
    private static let streamVisibleKey = "layout.stream.visible"
    private static let inspectorVisibleKey = "layout.inspector.visible"

    private let store: UserDefaults

    /// Under UI testing the layout is deliberately volatile. Widths and visibility are the one
    /// piece of state that is *not* under `CCBUD_HOME`, so a test that put a column away would hand
    /// that column's absence to every test after it in the same run.
    static func defaultStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        guard environment["CCBUD_UI_TESTING"] == "1" else { return .standard }
        let suite = "dev.ccbud.uitesting.layout.\(ProcessInfo.processInfo.processIdentifier)"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        return store
    }

    init(store: UserDefaults? = nil) {
        let store = store ?? Self.defaultStore()
        self.store = store
        railWidth = Self.width(for: Self.rail, in: store)
        streamWidth = Self.width(for: Self.stream, in: store)
        inspectorWidth = Self.width(for: Self.inspector, in: store)
        railVisible = store.object(forKey: Self.railVisibleKey) as? Bool ?? true
        streamVisible = store.object(forKey: Self.streamVisibleKey) as? Bool ?? true
        inspectorVisible = store.object(forKey: Self.inspectorVisibleKey) as? Bool ?? true
    }

    /// A stored width is only honoured inside the column's range: a build that narrows the limits,
    /// or a defaults file edited by hand, must not leave a column the window cannot show.
    static func clamped(_ width: CGFloat, in column: Column) -> CGFloat {
        guard width.isFinite else { return column.default }
        return min(max(width, column.range.lowerBound), column.range.upperBound)
    }

    private static func width(for column: Column, in store: UserDefaults) -> CGFloat {
        guard let stored = store.object(forKey: column.key) as? Double else { return column.default }
        return clamped(CGFloat(stored), in: column)
    }

    func resize(_ column: Column, to width: CGFloat) {
        let value = Self.clamped(width, in: column)
        switch column.key {
        case Self.rail.key: railWidth = value
        case Self.inspector.key: inspectorWidth = value
        default: streamWidth = value
        }
    }

    func reset(_ column: Column) {
        resize(column, to: column.default)
    }

    func toggleRail() { railVisible.toggle() }

    func toggleStream() { streamVisible.toggle() }

    func toggleInspector() { inspectorVisible.toggle() }

    /// What the columns actually get, given the space there is.
    ///
    /// The stored widths are what the user dragged; these are what fits today. Space is taken back
    /// in the order it is least missed: the overview narrows first, then the stream, each only as
    /// far as its own minimum. A column is dropped only when even the minimums cannot leave the
    /// transcript something to read in — the first version of this dropped the whole overview when
    /// the reading column came out four points short, which is not a trade anyone would choose.
    struct Resolved: Equatable {
        var streamVisible: Bool
        var streamWidth: CGFloat
        var inspectorVisible: Bool
        var inspectorWidth: CGFloat
    }

    nonisolated static func resolved(
        available: CGFloat,
        streamWidth: CGFloat,
        inspectorWidth: CGFloat,
        wantsStream: Bool,
        wantsInspector: Bool,
        minimumReading: CGFloat = 380,
        dividerWidth: CGFloat = 1
    ) -> Resolved {
        var result = Resolved(
            streamVisible: wantsStream,
            streamWidth: streamWidth,
            inspectorVisible: wantsInspector,
            inspectorWidth: inspectorWidth
        )
        guard available > 0 else { return result }

        func reading() -> CGFloat {
            var used: CGFloat = 0
            if result.streamVisible { used += result.streamWidth + dividerWidth }
            if result.inspectorVisible { used += result.inspectorWidth + dividerWidth }
            return available - used
        }

        // Returns the narrowed width rather than taking it `inout`: the closure below reads the
        // same value it would be writing, which is an exclusivity violation at runtime.
        func squeezed(_ width: CGFloat, floor: CGFloat) -> CGFloat {
            let deficit = minimumReading - reading()
            guard deficit > 0 else { return width }
            return max(floor, width - deficit)
        }

        if result.inspectorVisible {
            result.inspectorWidth = squeezed(
                result.inspectorWidth, floor: inspector.range.lowerBound
            )
        }
        if result.streamVisible {
            result.streamWidth = squeezed(result.streamWidth, floor: stream.range.lowerBound)
        }
        if result.inspectorVisible, reading() < minimumReading {
            result.inspectorVisible = false
            result.inspectorWidth = inspectorWidth
            // The stream can have its own width back now that the overview stepped aside.
            result.streamWidth = streamWidth
            if result.streamVisible {
                result.streamWidth = squeezed(result.streamWidth, floor: stream.range.lowerBound)
            }
        }
        if result.streamVisible, reading() < minimumReading {
            result.streamVisible = false
            result.streamWidth = streamWidth
        }
        return result
    }

    /// Narrower than this and a transcript stops being prose. Repeated as the default above
    /// because a main-actor property cannot be a default argument.
    nonisolated static let minimumReadingWidth: CGFloat = 380
}

/// The rule between two columns, and the handle that moves it.
///
/// The visible line stays one pixel wide — the grab area around it is invisible, because a divider
/// thick enough to hit comfortably would read as a fourth surface.
struct ColumnDivider: View {
    /// Which side of the rule the column being sized is on. A trailing column grows as the pointer
    /// travels left, so the drag has to read the opposite direction.
    enum Side { case leading, trailing }

    let column: ColumnLayout.Column
    var side: Side = .leading
    @Binding var width: CGFloat
    var onCommit: (CGFloat) -> Void = { _ in }
    var identifier: String?

    @State private var dragOrigin: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // The hit area straddles the line rather than sitting beside it, so the cursor
                // changes where the eye expects the handle to be.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let origin = dragOrigin ?? width
                                if dragOrigin == nil { dragOrigin = origin }
                                let travel = side == .leading
                                    ? value.translation.width
                                    : -value.translation.width
                                onCommit(ColumnLayout.clamped(origin + travel, in: column))
                            }
                            .onEnded { _ in dragOrigin = nil }
                    )
                    .onTapGesture(count: 2) { onCommit(column.default) }
            }
            .accessibilityIdentifier(identifier ?? "")
            .accessibilityLabel(Text(verbatim: "column divider"))
    }
}

/// The control that puts a column away and brings it back. Always in the same place whether the
/// column is there or not, so restoring it never becomes a hunt.
struct ColumnToggle: View {
    let symbol: String
    let help: String
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(CCIconButtonStyle(size: 26, symbolSize: Typography.body))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier ?? "")
    }
}
