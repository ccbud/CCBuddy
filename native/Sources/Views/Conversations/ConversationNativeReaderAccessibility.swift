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
        case .subrole: return .handled(object.accessibilitySubrole()?.rawValue)
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

/// Geometry belongs to the actual view, not NSCell's default bezel/title metrics or an older
/// SwiftUI accessibility wrapper. A clipped control activates within its visible, real bounds.
enum ConversationNativeReaderViewGeometry {
    static func frame(of view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    static func activationPoint(of view: NSView) -> NSPoint {
        // A SwiftUI hosting ancestor may not clip subviews: AppKit's visibleRect can then extend
        // beyond this button's own bounds. Only their intersection is actually drawn by it.
        let visibleBounds = view.bounds.intersection(view.visibleRect)
        guard let window = view.window, !visibleBounds.isEmpty else { return .zero }
        let rect = window.convertToScreen(view.convert(visibleBounds, to: nil))
        return NSPoint(x: rect.midX, y: rect.midY)
    }
}

/// Publishing children does not make NSView's default accessibility hit test descend into them.
/// In particular NSTableView stops at its cell, outside the identified hosting view's ancestry.
/// Follow the actual rendered view hit first, then let that native control/SwiftUI host resolve
/// its own deepest accessibility descendant. No offscreen row lookup or realization is needed.
enum ConversationNativeReaderAccessibilityHitTesting {
    static func hitTest(in view: NSView, point: NSPoint, preservesVirtualDescendants: Bool = false,
                        inherited: () -> Any?) -> Any? {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let windowPoint = window.convertPoint(fromScreen: point)
        let localPoint = view.convert(windowPoint, from: nil)
        guard view.bounds.intersection(view.visibleRect).contains(localPoint) else { return nil }
        let inheritedHit = preservesVirtualDescendants ? inherited() : nil
        if preservesVirtualDescendants, let inheritedHit,
           (inheritedHit as AnyObject) !== view, isDescendant(inheritedHit, of: view) {
            return inheritedHit
        }
        let hitPoint = view.superview?.convert(windowPoint, from: nil) ?? windowPoint
        if let hit = view.hitTest(hitPoint), hit !== view, hit.isDescendant(of: view) {
            var descendant: NSView? = hit
            while let candidate = descendant, candidate !== view {
                if candidate.isAccessibilityElement() {
                    return candidate.accessibilityHitTest(point)
                }
                descendant = candidate.superview
            }
        }
        // SwiftUI text can be a virtual AX descendant, with no separate NSView to hit. Preserve
        // the hosting view's normal resolver rather than replacing its prose with a parent group.
        return preservesVirtualDescendants ? inheritedHit : inherited()
    }

    static func isDescendant(_ element: Any, of ancestor: NSView) -> Bool {
        var current: Any? = element
        var seen = Set<ObjectIdentifier>()
        while let node = current as? any NSAccessibilityElementProtocol {
            if (node as AnyObject) === ancestor { return true }
            guard seen.insert(ObjectIdentifier(node)).inserted else { return false }
            current = node.accessibilityParent()
        }
        return false
    }
}

enum ConversationNativeReaderAccessibilityRowSlice {
    static func resolve(count: Int, index: Int, maxCount: Int, visibleRange: NSRange,
                        logical: (Int) -> Any, rendered: (Int) -> Any?) -> [Any] {
        guard index >= 0, maxCount > 0, index < count else { return [] }
        return (index..<(index + min(maxCount, count - index))).map { row in
            if contains(row, in: visibleRange), let actual = rendered(row) { return actual }
            return logical(row)
        }
    }

    static func contains(_ row: Int, in range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound
            && row >= range.location && row - range.location < range.length
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
    // Reused hosts must update AppKit's observable identifier storage, not a separate backing
    // property hidden behind a getter override. The legacy bridge reads this same native value.
    var messageIdentifier: String? {
        // NSAccessibilityElementProtocol also declares this getter nonnull. Use the full
        // protocol's nullable declaration so clearing the native value does not become "".
        get { (self as any NSAccessibilityProtocol).accessibilityIdentifier() }
        set { setAccessibilityIdentifier(newValue) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityFrame() -> NSRect { ConversationNativeReaderViewGeometry.frame(of: self) }
    override func accessibilityActivationPoint() -> NSPoint {
        ConversationNativeReaderViewGeometry.activationPoint(of: self)
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ConversationNativeReaderAccessibilityHitTesting.hitTest(in: self, point: point,
                                                               preservesVirtualDescendants: true) {
            super.accessibilityHitTest(point)
        }
    }
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
        host.messageIdentifier = nil
        host.rootView = ConversationNativeReaderHostedContent(
            content: AnyView(EmptyView()), environment: EnvironmentValues(), width: 1)
    }
    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ConversationNativeReaderAccessibilityHitTesting.hitTest(in: self, point: point) {
            super.accessibilityHitTest(point)
        }
    }
    override func accessibilityFrame() -> NSRect { ConversationNativeReaderViewGeometry.frame(of: self) }
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
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.index, .subrole])
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
    // AppKit normally publishes a table-row proxy carrying this subrole. Our real row replaces
    // that proxy, so it must preserve the same public classification as every logical row.
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tableRow }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ConversationNativeReaderAccessibilityHitTesting.hitTest(in: self, point: point) {
            super.accessibilityHitTest(point)
        }
    }
    override func accessibilityFrame() -> NSRect { ConversationNativeReaderViewGeometry.frame(of: self) }
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
            // A complete client snapshot still gets every logical row. Only the visible slice
            // needs AppKit view lookup; do not perform row geometry work 12,000 times per page.
            return ConversationNativeReaderAccessibilityRowSlice.resolve(
                count: logicalRows.count, index: index, maxCount: maxCount,
                visibleRange: rows(in: visibleRect), logical: { self.logicalRows[$0] },
                rendered: { self.rowView(atRow: $0, makeIfNecessary: false) })
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
    private var accessibilityTopologyRevision: UInt64 = 0
    private var publishedAccessibilityTopologyRevision: UInt64 = 0
    private var publishedAccessibilityRows: [Int: ObjectIdentifier] = [:]
    private var accessibilityLayoutChangeScheduled = false

    func installLogicalRows(sourceIndices: [Int], resetting: Bool) {
        let topologyChanged = resetting || logicalRows.count != sourceIndices.count + 1
            || zip(logicalRows, sourceIndices).contains { $0.sourceIndex != $1 }
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
        if topologyChanged { accessibilityTopologyRevision &+= 1 }
        scheduleAccessibilityLayoutChange()
    }

    override func layout() {
        super.layout()
        scheduleAccessibilityLayoutChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            accessibilityLayoutChangeScheduled = false
            publishedAccessibilityRows.removeAll()
        } else {
            scheduleAccessibilityLayoutChange()
        }
    }

    func scheduleAccessibilityLayoutChange() {
        guard window != nil, !accessibilityLayoutChangeScheduled else { return }
        accessibilityLayoutChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.accessibilityLayoutChangeScheduled else { return }
            self.publishAccessibilityLayoutChangeIfNeeded()
        }
    }

    @discardableResult
    func publishAccessibilityLayoutChangeIfNeeded() -> Bool {
        accessibilityLayoutChangeScheduled = false
        guard window != nil else { return false }
        let mounted = mountedAccessibilityRows().mapValues { ObjectIdentifier($0) }
        guard accessibilityTopologyRevision != publishedAccessibilityTopologyRevision
                || mounted != publishedAccessibilityRows else { return false }
        publishedAccessibilityTopologyRevision = accessibilityTopologyRevision
        publishedAccessibilityRows = mounted
        // Logical rows remain present while only viewport entries switch to real hosted rows.
        // Tell external clients when that actual membership changes, including ordinary search
        // navigation; unchanged measurements/scroll reflections must not create a notification loop.
        NSAccessibility.post(element: self, notification: .layoutChanged)
        return true
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
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ConversationNativeReaderAccessibilityHitTesting.hitTest(in: self, point: point) {
            super.accessibilityHitTest(point)
        }
    }
    override func accessibilityRowCount() -> Int { numberOfRows }
    override func accessibilityColumnCount() -> Int { 1 }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        let actual = mountedAccessibilityRows()
        // Do not collapse the table to its viewport. Offscreen logical row/cell elements remain
        // stable and expose an explicit action that scrolls their real content into existence.
        return logicalRows.enumerated().map { index, row -> any NSAccessibilityRow in
            if let visible = actual[index] { return visible }
            return row
        }
    }

    private func mountedAccessibilityRows() -> [Int: ConversationNativeReaderRowView] {
        let visibleRange = rows(in: visibleRect)
        var actual: [Int: ConversationNativeReaderRowView] = [:]
        enumerateAvailableRowViews { view, index in
            if let row = view as? ConversationNativeReaderRowView,
               ConversationNativeReaderAccessibilityRowSlice.contains(index, in: visibleRange) {
                actual[index] = row
            }
        }
        return actual
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
        if ConversationNativeReaderAccessibilityRowSlice.contains(row, in: rows(in: visibleRect)),
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

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        ConversationNativeReaderAccessibilityHitTesting.hitTest(in: self, point: point) {
            super.accessibilityHitTest(point)
        }
    }

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

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        (documentView as? ConversationNativeReaderTable)?.scheduleAccessibilityLayoutChange()
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
        ConversationNativeReaderLegacyAccessibility.names(super.accessibilityAttributeNames(), extra: [.index, .subrole])
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
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .tableRow }
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
