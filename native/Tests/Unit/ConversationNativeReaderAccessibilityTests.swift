import AppKit
import SwiftUI
import XCTest
@testable import CCBuddy

@MainActor
final class ConversationNativeReaderAccessibilityTests: XCTestCase {
    func testWholeTwelveThousandRowTranscriptIsAddressableWithoutHydratingViews() throws {
        let fixture = table(sourceIndices: Array(0..<12_000))
        XCTAssertEqual(fixture.table.accessibilityRowCount(), 12_001)
        XCTAssertEqual(fixture.table.accessibilityColumnCount(), 1)
        XCTAssertEqual(fixture.table.accessibilityArrayAttributeCount(.rows), 12_001)
        let last = try XCTUnwrap(fixture.table.accessibilityArrayAttributeValues(.rows, index: 11_999, maxCount: 1)
            .first as? ConversationNativeReaderLogicalRow)
        XCTAssertEqual(last.accessibilityIndex(), 11_999)
        XCTAssertEqual(last.accessibilityIdentifier(), "conversation.timeline.row.11999")
        XCTAssertTrue(last.accessibilityParent() as? ConversationNativeReaderTable === fixture.table)
        XCTAssertEqual(fixture.source.viewRequests, 0, "Accessibility queries must not realize offscreen content")
        XCTAssertEqual(fixture.table.accessibilityVisibleRows()?.count, 0)
        XCTAssertEqual(last.accessibilityVisibleChildren()?.count, 0)
    }

    func testLogicalRowAndCellStayTheSameObjectsAcrossAppendAndPairing() throws {
        let fixture = table(sourceIndices: [0, 2, 4])
        let original = try XCTUnwrap(fixture.table.accessibilityRows()?[2] as? ConversationNativeReaderLogicalRow)
        let cell = original.cell
        fixture.source.count = 5
        fixture.table.installLogicalRows(sourceIndices: [0, 1, 2, 4], resetting: false)
        fixture.table.reloadData()
        let moved = try XCTUnwrap(fixture.table.accessibilityRows()?[3] as? ConversationNativeReaderLogicalRow)
        XCTAssertTrue(moved === original)
        XCTAssertTrue(moved.cell === cell)
        XCTAssertEqual(moved.accessibilityIndex(), 3)
        XCTAssertEqual(cell.accessibilityRowIndexRange(), NSRange(location: 3, length: 1))
        XCTAssertTrue(cell.accessibilityParent() as? ConversationNativeReaderLogicalRow === moved)
        XCTAssertEqual(fixture.table.accessibilityIndex(ofChild: moved), 3)
    }

    func testRemovedOrOldScopeAccessibilityHandlesCannotNavigateDifferentContent() throws {
        for resetting in [false, true] {
            let fixture = table(sourceIndices: [0, 2, 4])
            let old = try XCTUnwrap(fixture.table.accessibilityRows()?[1] as? ConversationNativeReaderLogicalRow)
            var reveals: [Int] = []
            fixture.table.onAccessibilityReveal = { reveals.append($0) }
            fixture.table.installLogicalRows(sourceIndices: [0, 4], resetting: resetting)
            XCTAssertNil(old.accessibilityParent())
            XCTAssertFalse(try XCTUnwrap(old.accessibilityCustomActions()?.first?.handler)())
            old.setAccessibilityFocused(true)
            XCTAssertTrue(reveals.isEmpty)
        }
    }

    func testExplicitOffscreenNavigationTargetsTheCurrentRealRowWithoutFakeMessageChildren() throws {
        let fixture = table(sourceIndices: [0, 1200, 1201])
        let row = try XCTUnwrap(fixture.table.accessibilityRows()?[1] as? ConversationNativeReaderLogicalRow)
        var reveals: [Int] = []
        fixture.table.onAccessibilityReveal = { reveals.append($0) }
        XCTAssertTrue(try XCTUnwrap(row.accessibilityCustomActions()?.first?.handler)())
        row.cell.setAccessibilityFocused(true)
        XCTAssertEqual(reveals, [1, 1])
        XCTAssertEqual(row.cell.accessibilityChildren()?.count, 0)
        XCTAssertEqual(fixture.source.viewRequests, 0)
        XCTAssertFalse(row.accessibilityIdentifier().hasPrefix("conversation.message."))
    }

    func testAccessibilityBulkSlicesBoundNegativeHugeAndPastEndRequests() {
        let fixture = table(sourceIndices: [0, 1, 2])
        XCTAssertTrue(fixture.table.accessibilityArrayAttributeValues(.rows, index: -1, maxCount: 1).isEmpty)
        XCTAssertTrue(fixture.table.accessibilityArrayAttributeValues(.rows, index: 0, maxCount: 0).isEmpty)
        XCTAssertTrue(fixture.table.accessibilityArrayAttributeValues(.rows, index: Int.max, maxCount: Int.max).isEmpty)
        XCTAssertEqual(fixture.table.accessibilityArrayAttributeValues(.rows, index: 2, maxCount: Int.max).count, 2)
        XCTAssertEqual(fixture.table.accessibilityArrayAttributeValues(.children, index: 0, maxCount: 1).count, 1)
        XCTAssertEqual(fixture.source.viewRequests, 0)
    }

    func testAvailableButOffscreenCellUsesTheSameLogicalParentAsTheTablesRows() throws {
        let fixture = table(sourceIndices: Array(0..<40))
        let available = try XCTUnwrap(fixture.table.view(atColumn: 0, row: 20, makeIfNecessary: true))
        XCTAssertFalse(fixture.table.rect(ofRow: 20).intersects(fixture.table.visibleRect))
        let beforeQueries = fixture.source.viewRequests
        let row = try XCTUnwrap(fixture.table.accessibilityRows()?[20] as? ConversationNativeReaderLogicalRow)
        let cell = try XCTUnwrap(fixture.table.accessibilityCell(forColumn: 0, row: 20)
            as? ConversationNativeReaderLogicalCell)
        XCTAssertTrue(row.cell === cell)
        XCTAssertTrue(cell.accessibilityParent() as? ConversationNativeReaderLogicalRow === row)
        XCTAssertFalse((available as AnyObject) === (cell as AnyObject))
        XCTAssertEqual(fixture.source.viewRequests, beforeQueries, "AX queries never realize more content")
    }

    func testLateRemovedFocusedRowCannotRetainAnOldProjectionOrRemovedSource() {
        let cell = ConversationNativeReaderCell()
        let old = ConversationStore.TranscriptProjection()
        let next = ConversationStore.TranscriptProjection()
        cell.sourceIndex = 3
        cell.contentGeneration = 2
        cell.projection = old
        cell.retainsTextFocus = true
        XCTAssertTrue(cell.canRetainTextFocus(projection: old, generation: 2, visibleSources: [3: 0]))
        XCTAssertFalse(cell.canRetainTextFocus(projection: next, generation: 2, visibleSources: [3: 0]))
        XCTAssertFalse(cell.canRetainTextFocus(projection: old, generation: 3, visibleSources: [3: 0]))
        XCTAssertFalse(cell.canRetainTextFocus(projection: old, generation: 2, visibleSources: [4: 0]))
        cell.discardContent()
        XCTAssertNil(cell.projection)
        XCTAssertFalse(cell.canRetainTextFocus(projection: old, generation: 2, visibleSources: [3: 0]))
    }

    func testCellReuseReleasesOldRenderedContentAndFocusLease() {
        let cell = ConversationNativeReaderCell()
        cell.sourceIndex = 1200
        cell.host.messageIdentifier = "conversation.message.1200"
        cell.retainsTextFocus = true
        cell.onWillDetach = {}
        cell.onIntrinsicSizeInvalidated = {}
        cell.discardContent()
        XCTAssertNil(cell.sourceIndex)
        XCTAssertEqual(cell.host.accessibilityIdentifier(), "")
        XCTAssertFalse(cell.retainsTextFocus)
        XCTAssertNil(cell.onWillDetach)
        XCTAssertNil(cell.onIntrinsicSizeInvalidated)
    }

    func testResultDisclosureIsOneRealNativeButtonWithItsVisibleTitleAndState() {
        let button = resultButton()
        XCTAssertEqual(button.title, "Result")
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityTitle(), "Result, 175 KB")
        XCTAssertEqual(button.accessibilityLabel(), "Result, 175 KB")
        XCTAssertEqual(button.accessibilityValue() as? String, "collapsed")
        XCTAssertEqual(button.accessibilityIdentifier(), "conversation.tool.result.disclosure")
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertTrue(button.subviews.isEmpty, "The real button draws its title, not a substitute AX child")
    }

    func testResultDisclosureNativeTargetActionAndAccessibilityPressShareTheSameState() {
        var changes: [Bool] = []
        let button = resultButton { changes.append($0) }
        button.performClick(nil)
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(button.accessibilityValue() as? String, "expanded")
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(button.accessibilityValue() as? String, "collapsed")
        button.isEnabled = false
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(changes, [true, false])
    }

    @available(macOS, deprecated: 10.10)
    func testResultDisclosureLegacyAccessibilityMatchesModernTitleValueAndAction() {
        var changes: [Bool] = []
        let button = resultButton { changes.append($0) }
        XCTAssertTrue(button.accessibilityAttributeNames().contains(.title))
        XCTAssertTrue(button.accessibilityAttributeNames().contains(.value))
        XCTAssertTrue(button.accessibilityActionNames().contains(.press))
        XCTAssertEqual(button.accessibilityAttributeValue(.title) as? String, button.accessibilityTitle())
        XCTAssertEqual(button.accessibilityAttributeValue(.description) as? String, button.accessibilityLabel())
        XCTAssertEqual(button.accessibilityAttributeValue(.value) as? String, "collapsed")
        button.accessibilityPerformAction(.press)
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(button.accessibilityAttributeValue(.value) as? String, "expanded")
    }

    func testResultDisclosureReconfigurationReplacesBindingsAndLocalizedState() {
        var oldChanges: [Bool] = []
        var newChanges: [Bool] = []
        let button = resultButton { oldChanges.append($0) }
        button.configure(title: "结果", summary: "", isError: false, fontSize: 16,
                         expanded: true, expandedValue: "已展开", collapsedValue: "已折叠",
                         onChange: { newChanges.append($0) })
        XCTAssertEqual(button.accessibilityLabel(), "结果")
        XCTAssertEqual(button.accessibilityValue() as? String, "已展开")
        XCTAssertEqual(button.intrinsicContentSize.height, 28)
        button.performClick(nil)
        XCTAssertEqual(newChanges, [false])
        XCTAssertTrue(oldChanges.isEmpty)
        XCTAssertEqual(button.accessibilityValue() as? String, "已折叠")
    }

    @available(macOS, deprecated: 10.10)
    func testNativeResultGeometryUsesItsDrawnBoundsInsideAScrolledHostingTable() throws {
        let fixture = try geometryTable()
        defer { fixture.window.close() }
        let button = try XCTUnwrap(nativeResultButton(in: fixture.cell.host))
        for delta in [0.0, 8.0] {
            fixture.scroll.contentView.scroll(to: NSPoint(
                x: 0, y: fixture.scroll.contentView.bounds.minY + delta))
            let expected = fixture.window.convertToScreen(button.convert(button.bounds, to: nil))
            XCTAssertGreaterThan(expected.height, 20)
            XCTAssertEqual(button.accessibilityFrame(), expected)
            XCTAssertEqual((button.accessibilityAttributeValue(.position) as? NSValue)?.pointValue, expected.origin)
            XCTAssertEqual((button.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue, expected.size)
            let activation = button.accessibilityActivationPoint()
            XCTAssertTrue(expected.contains(activation), "Activation must be inside the actually drawn strip")
            let windowPoint = fixture.window.convertPoint(fromScreen: activation)
            let root = try XCTUnwrap(fixture.window.contentView)
            let hitPoint = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
            XCTAssertTrue(root.hitTest(hitPoint) === button,
                          "A synthesized mouse click at the advertised point must reach the real NSButton")
        }
        let document = try XCTUnwrap(fixture.scroll.documentView)
        let buttonInDocument = button.convert(button.bounds, to: document)
        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: buttonInDocument.minY + buttonInDocument.height * 0.75))
        fixture.scroll.layoutSubtreeIfNeeded()
        let visibleBounds = button.bounds.intersection(button.visibleRect)
        XCTAssertGreaterThan(visibleBounds.height, 0)
        XCTAssertTrue(visibleBounds.height < button.bounds.height,
                      "This check must exercise a partially clipped, not fully visible, control")
        let visible = fixture.window.convertToScreen(button.convert(visibleBounds, to: nil))
        let activation = button.accessibilityActivationPoint()
        XCTAssertTrue(visible.contains(activation), "The full-frame center is now clipped out")
        let root = try XCTUnwrap(fixture.window.contentView)
        let windowPoint = fixture.window.convertPoint(fromScreen: activation)
        let hitPoint = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
        XCTAssertTrue(root.hitTest(hitPoint) === button)
    }

    @available(macOS, deprecated: 10.10)
    func testVisibleMessageIdentityAndGeometryBelongToItsRealHostingView() throws {
        let fixture = try geometryTable()
        defer { fixture.window.close() }
        let host = fixture.cell.host
        XCTAssertEqual(host.accessibilityIdentifier(), "conversation.message.20")
        let expected = fixture.window.convertToScreen(host.convert(host.bounds, to: nil))
        XCTAssertEqual(host.accessibilityFrame(), expected)
        XCTAssertEqual((host.accessibilityAttributeValue(.position) as? NSValue)?.pointValue, expected.origin)
        XCTAssertEqual((host.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue, expected.size)
        let visible = fixture.window.convertToScreen(host.convert(host.bounds.intersection(host.visibleRect), to: nil))
        XCTAssertTrue(visible.contains(host.accessibilityActivationPoint()))
        XCTAssertTrue(fixture.cell.accessibilityChildren()?.contains { ($0 as AnyObject) === host } == true)
        let button = try XCTUnwrap(nativeResultButton(in: host))
        XCTAssertTrue(button.isAccessibilityElement(), "The identified host owns the actual rendered button")
        // SwiftUI publishes its own AX children on demand for an external accessibility client;
        // a direct in-process getter may be empty even for a standard ordered NSHostingView.
        // The UI tests require the real Result control and exact prose through that external tree.
        fixture.cell.discardContent()
        XCTAssertEqual(host.accessibilityIdentifier(), "", "Reused hosts cannot retain a stale message identifier")
    }

    private func nativeResultButton(in view: NSView) -> ConversationToolResultNativeButton? {
        if let button = view as? ConversationToolResultNativeButton { return button }
        for child in view.subviews {
            if let button = nativeResultButton(in: child) { return button }
        }
        return nil
    }

    private func geometryTable() throws -> (window: NSWindow, scroll: NSScrollView,
                                           cell: ConversationNativeReaderCell, source: GeometrySource) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = ConversationNativeReaderScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let table = ConversationNativeReaderTable(frame: NSRect(x: 0, y: 0, width: 480, height: 0))
        let column = NSTableColumn(identifier: .init("geometry"))
        column.width = 480
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 100
        table.intercellSpacing = .zero
        let source = GeometrySource()
        table.delegate = source
        table.dataSource = source
        table.installLogicalRows(sourceIndices: Array(0..<40), resetting: true)
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        table.scrollRowToVisible(20)
        scroll.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 20, makeIfNecessary: false)
            as? ConversationNativeReaderCell)
        cell.layoutSubtreeIfNeeded()
        cell.host.layoutSubtreeIfNeeded()
        return (window, scroll, cell, source)
    }

    private final class GeometrySource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 41 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = ConversationNativeReaderCell()
            cell.host.messageIdentifier = "conversation.message.\(row)"
            let content = VStack(alignment: .leading, spacing: 0) {
                Text("Real hosted row \(row)").frame(height: 30)
                ConversationToolResultButton(title: "Result", summary: "175 KB", isError: false,
                    fontSize: 9.5, expandedValue: "expanded", collapsedValue: "collapsed", expanded: .constant(false))
            }
            cell.host.rootView = ConversationNativeReaderHostedContent(
                content: AnyView(content), environment: EnvironmentValues(), width: 480)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = ConversationNativeReaderRowView()
            view.logicalIndex = row
            view.table = tableView as? ConversationNativeReaderTable
            return view
        }
    }

    private func resultButton(onChange: @escaping (Bool) -> Void = { _ in }) -> ConversationToolResultNativeButton {
        let button = ConversationToolResultNativeButton()
        button.configure(title: "Result", summary: "175 KB", isError: false, fontSize: 10,
                         expanded: false, expandedValue: "expanded", collapsedValue: "collapsed",
                         onChange: onChange)
        return button
    }

    private func table(sourceIndices: [Int]) -> (table: ConversationNativeReaderTable, source: Source, scroll: NSScrollView) {
        let table = ConversationNativeReaderTable(frame: .zero)
        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = table
        table.addTableColumn(NSTableColumn(identifier: .init("fixture")))
        let source = Source(count: sourceIndices.count + 1)
        table.dataSource = source
        table.delegate = source
        table.installLogicalRows(sourceIndices: sourceIndices, resetting: true)
        table.reloadData()
        return (table, source, scroll)
    }

    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var count: Int
        var viewRequests = 0
        init(count: Int) { self.count = count }
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            viewRequests += 1
            return NSView()
        }
    }
}
