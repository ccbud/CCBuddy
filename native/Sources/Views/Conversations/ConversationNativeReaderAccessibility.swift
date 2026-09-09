import AppKit
import SwiftUI

/// AppKit's public legacy accessibility entry points must describe the same real objects as its
/// modern protocol. External accessibility clients still consult both. No private selectors,
/// substitute message controls, or view realization are used by these adapters.
enum ConversationNativeReaderLegacyAccessibility {
    enum Value {
        case handled(Any?)
        case unhandled
    }

    static func names(_ inherited: [NSAccessibility.Attribute], extra: [NSAccessibility.Attribute])
        -> [NSAccessibility.Attribute] {
        var seen = Set<NSAccessibility.Attribute>()
        return (inherited + [.role, .roleDescription, .parent, .children, .visibleChildren,
                             .childrenInNavigationOrderAttribute, .identifier, .position, .size] + extra)
            .filter { seen.insert($0).inserted }
    }

    static func value(_ object: any NSAccessibilityProtocol, attribute: NSAccessibility.Attribute) -> Value {
        switch attribute {
        case .role: return .handled(object.accessibilityRole()?.rawValue)
        case .roleDescription: return .handled(object.accessibilityRoleDescription())
        case .parent: return .handled(object.accessibilityParent())
        case .children: return .handled(object.accessibilityChildren() ?? [])
        case .visibleChildren: return .handled(object.accessibilityVisibleChildren() ?? [])
        case .childrenInNavigationOrderAttribute:
            return .handled(object.accessibilityChildrenInNavigationOrder() ?? [])
        case .identifier: return .handled(object.accessibilityIdentifier())
        case .position: return .handled(NSValue(point: object.accessibilityFrame().origin))
        case .size: return .handled(NSValue(size: object.accessibilityFrame().size))
        case .rows: return .handled(object.accessibilityRows() ?? [])
        case .visibleRows: return .handled(object.accessibilityVisibleRows() ?? [])
        case .rowCount: return .handled(object.accessibilityRowCount())
        case .columnCount: return .handled(object.accessibilityColumnCount())
        case .index: return .handled(object.accessibilityIndex())
        case .rowIndexRange: return .handled(NSValue(range: object.accessibilityRowIndexRange()))
        case .columnIndexRange: return .handled(NSValue(range: object.accessibilityColumnIndexRange()))
        default: return .unhandled
        }
    }

    static func slice(_ values: [Any], index: Int, maxCount: Int) -> [Any] {
        guard index >= 0, maxCount > 0, index < values.count else { return [] }
        return Array(values[index..<(index + min(maxCount, values.count - index))])
    }

    static func index(of child: Any, in children: [Any]) -> Int {
        children.firstIndex { ($0 as AnyObject) === (child as AnyObject) } ?? NSNotFound
    }
}

struct ConversationNativeReaderHostedContent: View {
    let content: AnyView
    let environment: EnvironmentValues
    let width: CGFloat

    var body: some View {
        content
            .environment(\.self, environment)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

final class ConversationNativeReaderHost: NSHostingView<ConversationNativeReaderHostedContent> {

    // Keep the public legacy client path on the same objects as the modern AX tree.
    private var routingLegacyAccessibility = false

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [])
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard !routingLegacyAccessibility else { return super.accessibilityAttributeValue(attribute) }
        routingLegacyAccessibility = true
        defer { routingLegacyAccessibility = false }
        switch ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute) {
        case .handled(let value): return value
        case .unhandled: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityIsIgnored() -> Bool { !isAccessibilityElement() }

    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] { return values.count }
        return super.accessibilityArrayAttributeCount(attribute)
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute,
                                                    index: Int, maxCount: Int) -> [Any] {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] {
            return ConversationNativeReaderLegacyAccessibility.slice(values, index: index, maxCount: maxCount)
        }
        return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount)
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        ConversationNativeReaderLegacyAccessibility.index(of: child, in: accessibilityChildren() ?? [])
    }

    var onIntrinsicSizeInvalidated: (() -> Void)?
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}

final class ConversationNativeReaderCell: NSTableCellView {

    // Keep the public legacy client path on the same objects as the modern AX tree.
    private var routingLegacyAccessibility = false

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.rowIndexRange, .columnIndexRange])
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard !routingLegacyAccessibility else { return super.accessibilityAttributeValue(attribute) }
        routingLegacyAccessibility = true
        defer { routingLegacyAccessibility = false }
        switch ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute) {
        case .handled(let value): return value
        case .unhandled: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityIsIgnored() -> Bool { !isAccessibilityElement() }

    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] { return values.count }
        return super.accessibilityArrayAttributeCount(attribute)
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute,
                                                    index: Int, maxCount: Int) -> [Any] {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] {
            return ConversationNativeReaderLegacyAccessibility.slice(values, index: index, maxCount: maxCount)
        }
        return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount)
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        ConversationNativeReaderLegacyAccessibility.index(of: child, in: accessibilityChildren() ?? [])
    }

    var logicalIndex = -1
    var sourceIndex: Int?
    weak var projection: ConversationStore.TranscriptProjection?
    var contentGeneration: UInt64 = 0
    var retainsTextFocus = false
    var onWillDetach: (() -> Void)?
    var onIntrinsicSizeInvalidated: (() -> Void)?
    let host = ConversationNativeReaderHost(rootView: ConversationNativeReaderHostedContent(
        content: AnyView(EmptyView()), environment: EnvironmentValues(), width: 1
    ))

    init() {
        super.init(frame: .zero)
        host.sizingOptions = [.intrinsicContentSize]
        host.autoresizingMask = [.width, .height]
        host.onIntrinsicSizeInvalidated = { [weak self] in self?.onIntrinsicSizeInvalidated?() }
        addSubview(host)
        host.setAccessibilityParent(self)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func canRetainTextFocus(projection: ConversationStore.TranscriptProjection?, generation: UInt64,
                            visibleSources: [Int: Int]) -> Bool {
        retainsTextFocus && contentGeneration == generation && self.projection === projection
            && sourceIndex.map { visibleSources[$0] != nil } == true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { onWillDetach?() }
        super.viewWillMove(toWindow: newWindow)
    }
    func discardContent() {
        onIntrinsicSizeInvalidated = nil
        onWillDetach = nil
        retainsTextFocus = false
        sourceIndex = nil
        projection = nil
        host.rootView = ConversationNativeReaderHostedContent(
            content: AnyView(EmptyView()), environment: EnvironmentValues(), width: 1)
    }
    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityRowIndexRange() -> NSRange { NSRange(location: logicalIndex, length: 1) }
    override func accessibilityColumnIndexRange() -> NSRange { NSRange(location: 0, length: 1) }
    override func accessibilityChildren() -> [Any]? { [host] }
    override func accessibilityVisibleChildren() -> [Any]? {
        host.window != nil && !host.isHiddenOrHasHiddenAncestor && !host.visibleRect.isEmpty ? [host] : []
    }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? { [host] }
    override func accessibilityParent() -> Any? {
        var ancestor = superview
        while let view = ancestor {
            if view is ConversationNativeReaderRowView { return view }
            ancestor = view.superview
        }
        return super.accessibilityParent()
    }
}

final class ConversationNativeReaderRowView: NSTableRowView {

    // Keep the public legacy client path on the same objects as the modern AX tree.
    private var routingLegacyAccessibility = false

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.index])
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard !routingLegacyAccessibility else { return super.accessibilityAttributeValue(attribute) }
        routingLegacyAccessibility = true
        defer { routingLegacyAccessibility = false }
        switch ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute) {
        case .handled(let value): return value
        case .unhandled: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityIsIgnored() -> Bool { !isAccessibilityElement() }

    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] { return values.count }
        return super.accessibilityArrayAttributeCount(attribute)
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute,
                                                    index: Int, maxCount: Int) -> [Any] {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] {
            return ConversationNativeReaderLegacyAccessibility.slice(values, index: index, maxCount: maxCount)
        }
        return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount)
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        ConversationNativeReaderLegacyAccessibility.index(of: child, in: accessibilityChildren() ?? [])
    }

    weak var table: ConversationNativeReaderTable?
    var logicalIndex = -1
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityParent() -> Any? { table }
    override func accessibilityIndex() -> Int { logicalIndex }
    override func accessibilityChildren() -> [Any]? {
        guard let cell = view(atColumn: 0) else { return [] }
        return [cell]
    }
    override func accessibilityVisibleChildren() -> [Any]? {
        guard let cell = view(atColumn: 0) as? NSView, !cell.visibleRect.isEmpty else { return [] }
        return [cell]
    }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        guard let cell = view(atColumn: 0) as? NSView else { return [] }
        return [cell]
    }
}

final class ConversationNativeReaderTable: NSTableView {

    @available(macOS, deprecated: 10.10)
    override func accessibilityParameterizedAttributeNames() -> [NSAccessibility.ParameterizedAttribute] {
        var names = super.accessibilityParameterizedAttributeNames()
        if !names.contains(.cellForColumnAndRow) { names.append(.cellForColumnAndRow) }
        return names
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute,
                                               forParameter parameter: Any?) -> Any? {
        if attribute == .cellForColumnAndRow {
            guard let indices = parameter as? [NSNumber], indices.count == 2 else { return nil }
            return accessibilityCell(forColumn: indices[0].intValue, row: indices[1].intValue)
        }
        return super.accessibilityAttributeValue(attribute, forParameter: parameter)
    }

    // Keep the public legacy client path on the same objects as the modern AX tree.
    private var routingLegacyAccessibility = false

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.rows, .visibleRows, .rowCount, .columnCount])
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard !routingLegacyAccessibility else { return super.accessibilityAttributeValue(attribute) }
        routingLegacyAccessibility = true
        defer { routingLegacyAccessibility = false }
        switch ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute) {
        case .handled(let value): return value
        case .unhandled: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityIsIgnored() -> Bool { !isAccessibilityElement() }

    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        if [.children, .rows, .childrenInNavigationOrderAttribute].contains(attribute) { return logicalRows.count }
        if [.visibleChildren, .visibleRows].contains(attribute) { return accessibilityVisibleRows()?.count ?? 0 }
        return super.accessibilityArrayAttributeCount(attribute)
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute,
                                                    index: Int, maxCount: Int) -> [Any] {
        if [.children, .rows, .childrenInNavigationOrderAttribute].contains(attribute) {
            guard index >= 0, maxCount > 0, index < logicalRows.count else { return [] }
            return (index..<(index + min(maxCount, logicalRows.count - index))).map { row -> Any in
                if rect(ofRow: row).intersects(visibleRect),
                   let actual = rowView(atRow: row, makeIfNecessary: false) { return actual }
                return logicalRows[row]
            }
        }
        if [.visibleChildren, .visibleRows].contains(attribute) {
            return ConversationNativeReaderLegacyAccessibility.slice(accessibilityVisibleRows() ?? [],
                                                                       index: index, maxCount: maxCount)
        }
        return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount)
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        if let row = child as? ConversationNativeReaderRowView, row.table === self { return row.logicalIndex }
        if let row = child as? ConversationNativeReaderLogicalRow, row.table === self { return row.index }
        return NSNotFound
    }

    var onWidthChanged: (() -> Void)?
    var onAccessibilityReveal: ((Int) -> Void)?
    var rowActionTitle: ((Int?) -> String)?
    private var lastWidth: CGFloat = 0
    private var logicalRows: [ConversationNativeReaderLogicalRow] = []

    func installLogicalRows(sourceIndices: [Int], resetting: Bool) {
        let retainedSources = Set(sourceIndices)
        for row in logicalRows where resetting || row.sourceIndex.map({ !retainedSources.contains($0) }) == true {
            row.table = nil
        }
        let retained = resetting ? [:] : Dictionary(uniqueKeysWithValues: logicalRows.compactMap { row in
            row.sourceIndex.map { ($0, row) }
        })
        let footer = resetting ? nil : logicalRows.last.flatMap { $0.sourceIndex == nil ? $0 : nil }
        logicalRows = sourceIndices.enumerated().map { index, source in
            let row = retained[source] ?? ConversationNativeReaderLogicalRow(table: self, index: index,
                                                                            sourceIndex: source)
            row.index = index
            return row
        }
        let bottom = footer ?? ConversationNativeReaderLogicalRow(table: self, index: sourceIndices.count,
                                                                  sourceIndex: nil)
        bottom.index = sourceIndices.count
        logicalRows.append(bottom)
    }

    func synchronizeWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let changed = width != lastWidth
        lastWidth = width
        if tableColumns.first?.width != width { tableColumns.first?.width = width }
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        if changed { onWidthChanged?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityRowCount() -> Int { numberOfRows }
    override func accessibilityColumnCount() -> Int { 1 }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        var actual: [Int: ConversationNativeReaderRowView] = [:]
        enumerateAvailableRowViews { view, index in
            if let row = view as? ConversationNativeReaderRowView, self.rect(ofRow: index).intersects(self.visibleRect) {
                actual[index] = row
            }
        }
        // Do not collapse the table to its viewport. Offscreen logical row/cell elements remain
        // stable and expose an explicit action that scrolls their real content into existence.
        return logicalRows.enumerated().map { index, row -> any NSAccessibilityRow in
            if let visible = actual[index] { return visible }
            return row
        }
    }

    override func accessibilityChildren() -> [Any]? { accessibilityRows() }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        accessibilityRows()?.map { $0 as any NSAccessibilityElementProtocol }
    }

    override func accessibilityVisibleRows() -> [any NSAccessibilityRow]? {
        let range = rows(in: visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        return (range.location..<min(numberOfRows, NSMaxRange(range))).compactMap {
            rowView(atRow: $0, makeIfNecessary: false)
        }
    }

    override func accessibilityVisibleChildren() -> [Any]? { accessibilityVisibleRows() }

    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        guard column == 0, logicalRows.indices.contains(row) else { return nil }
        if rect(ofRow: row).intersects(visibleRect),
           let cell = view(atColumn: 0, row: row, makeIfNecessary: false) { return cell }
        return logicalRows[row].cell
    }

    func accessibilityFrame(forRow row: Int) -> NSRect {
        guard let window, row >= 0, row < numberOfRows else { return .zero }
        return window.convertToScreen(convert(rect(ofRow: row), to: nil))
    }

}

final class ConversationNativeReaderScrollView: NSScrollView {
    var onForwardedUserScroll: (() -> Void)?
    private var wheelMonitor: Any?
    private var routing = ConversationNestedScrollRouting()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disconnectWheelRouting()
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.routeNestedWheel(event)
        }
    }

    override func layout() {
        super.layout()
        (documentView as? ConversationNativeReaderTable)?.synchronizeWidth(contentSize.width)
    }

    private func routeNestedWheel(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else {
            routing.reset()
            return event
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside || (routing.hasForwardedGesture && !event.momentumPhase.isEmpty) else {
            routing.reset()
            return event
        }
        var view = window.contentView?.hitTest(window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero)
        if let hit = view, hit !== self, !hit.isDescendant(of: self) { view = nil }
        var nested: NSScrollView?
        while let candidate = view, candidate !== self {
            if let scroll = candidate as? NSScrollView { nested = scroll; break }
            view = candidate.superview
        }
        let horizontalOnly = nested.map { scroll in
            !scroll.hasVerticalScroller
                && (scroll.documentView?.frame.height ?? 0) <= scroll.contentView.bounds.height + 1
        } ?? false
        guard routing.forwards(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                               phase: event.phase, momentumPhase: event.momentumPhase,
                               shift: event.modifierFlags.contains(.shift),
                               overHorizontalContent: horizontalOnly) else { return event }
        // Route the original event once, preserving native phases, precision and momentum.
        // This is synchronous user input, so pending search/latest corrections lose authority
        // before the scroll changes even if another local monitor never receives this event.
        onForwardedUserScroll?()
        scrollWheel(with: event)
        return nil
    }

    func disconnectWheelRouting() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        routing.reset()
    }

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }
}

/// These represent actual offscreen table rows, not message/Result substitutes. They have no
/// message identifiers or invented content controls; user navigation materializes the real views.
final class ConversationNativeReaderLogicalRow: NSAccessibilityElement, NSAccessibilityRow {

    // Keep the public legacy client path on the same objects as the modern AX tree.
    private var routingLegacyAccessibility = false

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.index])
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard !routingLegacyAccessibility else { return super.accessibilityAttributeValue(attribute) }
        routingLegacyAccessibility = true
        defer { routingLegacyAccessibility = false }
        switch ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute) {
        case .handled(let value): return value
        case .unhandled: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityIsIgnored() -> Bool { !isAccessibilityElement() }

    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] { return values.count }
        return super.accessibilityArrayAttributeCount(attribute)
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute,
                                                    index: Int, maxCount: Int) -> [Any] {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] {
            return ConversationNativeReaderLegacyAccessibility.slice(values, index: index, maxCount: maxCount)
        }
        return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount)
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        ConversationNativeReaderLegacyAccessibility.index(of: child, in: accessibilityChildren() ?? [])
    }

    weak var table: ConversationNativeReaderTable?
    var index: Int
    let sourceIndex: Int?
    lazy var cell = ConversationNativeReaderLogicalCell(row: self)

    init(table: ConversationNativeReaderTable, index: Int, sourceIndex: Int?) {
        self.table = table
        self.index = index
        self.sourceIndex = sourceIndex
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityParent() -> Any? { table }
    override func accessibilityIndex() -> Int { index }
    override func accessibilityIdentifier() -> String {
        sourceIndex.map { "conversation.timeline.row.\($0)" } ?? "conversation.timeline.row.bottom"
    }
    override func accessibilityFrame() -> NSRect { table?.accessibilityFrame(forRow: index) ?? .zero }
    override func accessibilityChildren() -> [Any]? { [cell] }
    override func accessibilityVisibleChildren() -> [Any]? { [] }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? { [cell] }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: table?.rowActionTitle?(sourceIndex) ?? "\(index + 1)") { [weak self] in
            guard let self, let table = self.table else { return false }
            table.onAccessibilityReveal?(self.index)
            return true
        }]
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused { table?.onAccessibilityReveal?(index) }
    }
}

final class ConversationNativeReaderLogicalCell: NSAccessibilityElement, NSAccessibilityElementProtocol {

    // Keep the public legacy client path on the same objects as the modern AX tree.
    private var routingLegacyAccessibility = false

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.rowIndexRange, .columnIndexRange])
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard !routingLegacyAccessibility else { return super.accessibilityAttributeValue(attribute) }
        routingLegacyAccessibility = true
        defer { routingLegacyAccessibility = false }
        switch ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute) {
        case .handled(let value): return value
        case .unhandled: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityIsIgnored() -> Bool { !isAccessibilityElement() }

    override func accessibilityArrayAttributeCount(_ attribute: NSAccessibility.Attribute) -> Int {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] { return values.count }
        return super.accessibilityArrayAttributeCount(attribute)
    }

    override func accessibilityArrayAttributeValues(_ attribute: NSAccessibility.Attribute,
                                                    index: Int, maxCount: Int) -> [Any] {
        if case .handled(let value) = ConversationNativeReaderLegacyAccessibility.value(self, attribute: attribute),
           let values = value as? [Any] {
            return ConversationNativeReaderLegacyAccessibility.slice(values, index: index, maxCount: maxCount)
        }
        return super.accessibilityArrayAttributeValues(attribute, index: index, maxCount: maxCount)
    }

    override func accessibilityIndex(ofChild child: Any) -> Int {
        ConversationNativeReaderLegacyAccessibility.index(of: child, in: accessibilityChildren() ?? [])
    }

    weak var row: ConversationNativeReaderLogicalRow?
    init(row: ConversationNativeReaderLogicalRow) {
        self.row = row
        super.init()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityRowIndexRange() -> NSRange { NSRange(location: row?.index ?? NSNotFound, length: 1) }
    override func accessibilityColumnIndexRange() -> NSRange { NSRange(location: 0, length: 1) }
    override func accessibilityParent() -> Any? { row }
    override func accessibilityIdentifier() -> String {
        (row?.accessibilityIdentifier() ?? "conversation.timeline.detached") + ".cell"
    }
    override func accessibilityFrame() -> NSRect { row?.accessibilityFrame() ?? .zero }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { row?.accessibilityCustomActions() }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused { row?.table?.onAccessibilityReveal?(row?.index ?? -1) }
    }
}
