import AppKit
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
        cell.retainsTextFocus = true
        cell.onWillDetach = {}
        cell.onIntrinsicSizeInvalidated = {}
        cell.discardContent()
        XCTAssertNil(cell.sourceIndex)
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
