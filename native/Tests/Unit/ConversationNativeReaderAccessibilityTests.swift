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

    @available(macOS, deprecated: 10.10)
    func testPublishedLogicalAndRealRowsMatchStandardTableRowClassification() throws {
        let fixture = try geometryTable(messageCount: 12_000, target: 11_999)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let standardWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 300),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        standardWindow.isReleasedWhenClosed = false
        defer { standardWindow.close() }
        let standardScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        let standardTable = NSTableView(frame: NSRect(x: 0, y: 0, width: 480, height: 0))
        standardTable.addTableColumn(NSTableColumn(identifier: .init("classification")))
        standardTable.headerView = nil
        standardTable.rowHeight = 100
        let source = Source(count: 12_001)
        standardTable.delegate = source
        standardTable.dataSource = source
        standardScroll.documentView = standardTable
        standardWindow.contentView = standardScroll
        standardTable.reloadData()
        standardTable.scrollRowToVisible(11_999)
        standardScroll.layoutSubtreeIfNeeded()
        // AppKit's internal published row proxy need not formally adopt the Swift-imported
        // NSAccessibilityRow protocol. Compare its public legacy attributes through NSArray.
        let standardRows = try XCTUnwrap(standardTable.accessibilityAttributeValue(.rows) as? NSArray)
        XCTAssertEqual(standardRows.count, 12_001)
        let realizedBefore = fixture.source.viewRequests
        let rows = table.accessibilityArrayAttributeValues(.rows, index: 0, maxCount: Int.max)
        XCTAssertEqual(rows.count, 12_001)
        XCTAssertTrue(rows[0] is ConversationNativeReaderLogicalRow)
        XCTAssertTrue(rows[11_999] is ConversationNativeReaderRowView)
        XCTAssertEqual(rows.filter {
            ($0 as? any NSAccessibilityProtocol)?.accessibilitySubrole() == .tableRow
        }.count, 12_001, "Every row, including offscreen rows, must retain the same table-row classification")
        XCTAssertEqual(rows.filter {
            ($0 as? NSObject)?.accessibilityAttributeValue(.subrole) as? String
                == NSAccessibility.Subrole.tableRow.rawValue
        }.count, 12_001)
        for index in [0, 11_999] {
            let standard = try XCTUnwrap(standardRows.object(at: index) as? NSObject)
            let row = try XCTUnwrap(rows[index] as? any NSAccessibilityProtocol)
            let legacy = try XCTUnwrap(rows[index] as? NSObject)
            XCTAssertEqual(standard.accessibilityAttributeValue(.subrole) as? String,
                           NSAccessibility.Subrole.tableRow.rawValue)
            XCTAssertEqual(row.accessibilityRole()?.rawValue, standard.accessibilityAttributeValue(.role) as? String)
            XCTAssertEqual(row.accessibilitySubrole()?.rawValue, standard.accessibilityAttributeValue(.subrole) as? String)
            XCTAssertEqual(row.accessibilityRoleDescription(), standard.accessibilityAttributeValue(.roleDescription) as? String)
            XCTAssertTrue(legacy.accessibilityAttributeNames().contains(.subrole))
            XCTAssertEqual(legacy.accessibilityAttributeValue(.subrole) as? String, row.accessibilitySubrole()?.rawValue)
            XCTAssertTrue((row.accessibilityWindow() as AnyObject?) === fixture.window)
            XCTAssertTrue((row.accessibilityTopLevelUIElement() as AnyObject?) === fixture.window)
        }
        XCTAssertEqual(fixture.source.viewRequests, realizedBefore,
                       "Comparing complete public row semantics cannot realize offscreen message content")
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

    func testBulkAXSlicesOnlyLookUpVisibleNativeRowsAndPreserveTheCompleteTable() throws {
        var lookedUp: [Int] = []
        let result = ConversationNativeReaderAccessibilityRowSlice.resolve(
            count: 12_001, index: 0, maxCount: Int.max,
            visibleRange: NSRange(location: 11_995, length: 6), logical: { "logical.\($0)" },
            rendered: { row in
                lookedUp.append(row)
                return row == 11_999 ? "actual.11999" : nil
            })
        XCTAssertEqual(lookedUp, Array(11_995...12_000),
                       "A full 12k snapshot must perform native lookups only for the visible intersection")
        XCTAssertEqual(result.count, 12_001)
        XCTAssertEqual(result[0] as? String, "logical.0")
        XCTAssertEqual(result[11_998] as? String, "logical.11998")
        XCTAssertEqual(result[11_999] as? String, "actual.11999")
        XCTAssertEqual(result[12_000] as? String, "logical.12000")
        lookedUp.removeAll()
        _ = ConversationNativeReaderAccessibilityRowSlice.resolve(
            count: 12_001, index: 2, maxCount: 1,
            visibleRange: NSRange(location: NSNotFound, length: Int.max), logical: { $0 },
            rendered: { lookedUp.append($0); return nil })
        XCTAssertTrue(lookedUp.isEmpty)

        let fixture = try geometryTable(messageCount: 12_000, target: 11_999)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let realizedBefore = fixture.source.viewRequests
        let actualTail = try XCTUnwrap(table.rowView(atRow: 11_999, makeIfNecessary: false))
        for attribute: NSAccessibility.Attribute in [.rows, .childrenInNavigationOrderAttribute] {
            let rows = table.accessibilityArrayAttributeValues(attribute, index: 0, maxCount: Int.max)
            XCTAssertEqual(rows.count, 12_001)
            XCTAssertTrue(rows[0] is ConversationNativeReaderLogicalRow)
            XCTAssertTrue((rows[11_999] as AnyObject) === actualTail)
        }
        XCTAssertEqual(fixture.source.viewRequests, realizedBefore)
    }

    func testAccessibilityChildPermutationIsCompleteBoundedAndInvertible() {
        for count in [0, 1, 2, 257, 12_001] {
            let requested = [-1, count, count - 1, count / 2, 0, 0]
            let priority = Set(requested.filter { $0 >= 0 && $0 < count }).sorted()
            let expected = priority + (0..<count).filter { !priority.contains($0) }
            let order = ConversationNativeReaderAccessibilityChildOrder(count: count, prioritized: requested)
            XCTAssertEqual(order.indices(index: 0, maxCount: Int.max), expected)
            XCTAssertTrue(order.indices(index: -1, maxCount: 2).isEmpty)
            XCTAssertTrue(order.indices(index: 0, maxCount: 0).isEmpty)
            XCTAssertTrue(order.indices(index: count, maxCount: Int.max).isEmpty)
            XCTAssertEqual(order.index(ofRow: -1), NSNotFound)
            XCTAssertEqual(order.index(ofRow: count), NSNotFound)
            for (index, row) in expected.enumerated() { XCTAssertEqual(order.index(ofRow: row), index) }
            for index in [0, priority.count - 1, priority.count, count - 2] where index >= 0 && index < count {
                XCTAssertEqual(order.indices(index: index, maxCount: 3),
                               Array(expected[index..<min(count, index + 3)]))
            }
        }
        let huge = ConversationNativeReaderAccessibilityChildOrder(count: Int.max,
                                                                    prioritized: [0, Int.max - 2])
        XCTAssertEqual(huge.indices(index: 0, maxCount: 3), [0, Int.max - 2, 1])
        XCTAssertEqual(huge.indices(index: Int.max - 2, maxCount: Int.max), [Int.max - 3, Int.max - 1])
        XCTAssertEqual(huge.index(ofRow: Int.max - 1), Int.max - 1)
    }

    @available(macOS, deprecated: 10.10)
    func testViewportFirstChildrenPreserveEveryRowAndDocumentNavigation() throws {
        let fixture = try geometryTable(messageCount: 12_000, target: 11_999)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let realized = fixture.source.viewRequests
        let rows = table.accessibilityArrayAttributeValues(.rows, index: 0, maxCount: Int.max)
        let children = try XCTUnwrap(table.accessibilityChildren())
        let navigation = try XCTUnwrap(table.accessibilityChildrenInNavigationOrder())
        let identities: ([Any]) -> [ObjectIdentifier] = { $0.map { ObjectIdentifier($0 as AnyObject) } }
        XCTAssertEqual(rows.count, 12_001)
        XCTAssertEqual(children.count, rows.count)
        XCTAssertEqual(Set(identities(children)), Set(identities(rows)))
        XCTAssertEqual(Set(identities(children)).count, 12_001, "No logical or rendered child can occur twice")
        XCTAssertEqual(identities(navigation), identities(rows), "Linear navigation always keeps document order")
        let visible = try XCTUnwrap(table.accessibilityVisibleRows())
        XCTAssertEqual(identities(Array(children.prefix(visible.count))), identities(visible))
        XCTAssertTrue(children[visible.count] is ConversationNativeReaderLogicalRow)
        XCTAssertEqual((children[visible.count] as? ConversationNativeReaderLogicalRow)?.index, 0)
        let tail = try XCTUnwrap(table.rowView(atRow: 11_999, makeIfNecessary: false))
        XCTAssertTrue((rows[11_999] as AnyObject) === tail)
        XCTAssertTrue(children.prefix(visible.count).contains { ($0 as AnyObject) === tail })
        for (index, child) in children.enumerated() {
            XCTAssertEqual(table.accessibilityIndex(ofChild: child), index)
            XCTAssertTrue(((child as? any NSAccessibilityProtocol)?.accessibilityParent() as AnyObject?) === table)
        }
        for (index, row) in rows.enumerated() {
            XCTAssertEqual((row as? any NSAccessibilityProtocol)?.accessibilityIndex(), index)
        }
        for attribute: NSAccessibility.Attribute in [.children, .rows, .childrenInNavigationOrderAttribute] {
            let expected = attribute == .children ? children : rows
            XCTAssertEqual(table.accessibilityArrayAttributeCount(attribute), expected.count)
            let legacy = try XCTUnwrap(table.accessibilityAttributeValue(attribute) as? [Any])
            XCTAssertEqual(identities(legacy), identities(expected))
            for index in [0, visible.count - 1, visible.count, 999, 11_999, 12_001, Int.max] {
                let page = table.accessibilityArrayAttributeValues(attribute, index: index, maxCount: 3)
                let expectedPage = index < expected.count ? Array(expected[index..<min(expected.count, index + 3)]) : []
                XCTAssertEqual(identities(page), identities(expectedPage))
            }
        }
        XCTAssertTrue((table.accessibilityCell(forColumn: 0, row: 11_999) as AnyObject?) === fixture.cell)
        XCTAssertEqual(fixture.source.viewRequests, realized, "Reordering complete AX collections cannot hydrate text")
    }

    func testThousandChildSnapshotCanReachTheActualTailWithoutPruningTheTable() throws {
        let fixture = try geometryTable(messageCount: 12_000, target: 11_999)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let realized = fixture.source.viewRequests
        let sourcePrefix = table.accessibilityArrayAttributeValues(.rows, index: 0, maxCount: 1000)
        XCTAssertTrue(sourcePrefix.allSatisfy { $0 is ConversationNativeReaderLogicalRow })
        var pending: [NSObject] = [table]
        var seen = Set<ObjectIdentifier>()
        var foundActualHost = false
        while let node = pending.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if node === fixture.cell.host { foundActualHost = true }
            let children = node.accessibilityArrayAttributeValues(.children, index: 0, maxCount: 1000)
            pending.append(contentsOf: children.compactMap { $0 as? NSObject })
        }
        XCTAssertTrue(foundActualHost, "A per-node 1000-child client limit must still reach the real visible 11999 host")
        XCTAssertEqual(fixture.cell.host.messageIdentifier, "conversation.message.11999")
        XCTAssertEqual(table.accessibilityArrayAttributeCount(.children), 12_001)
        XCTAssertEqual(table.accessibilityArrayAttributeCount(.rows), 12_001)
        XCTAssertEqual(table.accessibilityArrayAttributeCount(.childrenInNavigationOrderAttribute), 12_001)
        XCTAssertEqual(fixture.source.viewRequests, realized)
    }

    func testChildPermutationTracksViewportAndRejectsReplacedHandles() throws {
        let fixture = try geometryTable(messageCount: 12_000, target: 20)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let initial = try XCTUnwrap(table.accessibilityRows())
        let stable = try XCTUnwrap(initial[0] as? ConversationNativeReaderLogicalRow)
        let oldLogicalTail = try XCTUnwrap(initial[11_999] as? ConversationNativeReaderLogicalRow)
        let oldActual = try XCTUnwrap(table.rowView(atRow: 20, makeIfNecessary: false))
        _ = table.publishAccessibilityLayoutChangeIfNeeded()
        table.scrollRowToVisible(11_999)
        fixture.scroll.layoutSubtreeIfNeeded()
        let realized = fixture.source.viewRequests
        XCTAssertTrue(table.publishAccessibilityLayoutChangeIfNeeded())
        XCTAssertFalse(table.publishAccessibilityLayoutChangeIfNeeded())
        let current = try XCTUnwrap(table.accessibilityRows())
        XCTAssertTrue((current[0] as AnyObject) === stable)
        XCTAssertEqual(table.accessibilityIndex(ofChild: oldLogicalTail), NSNotFound,
                       "The replaced logical handle is not a currently published child")
        XCTAssertEqual(table.accessibilityIndex(ofChild: oldActual), NSNotFound,
                       "An offscreen cached real row cannot masquerade as its current logical replacement")
        let visibleCount = table.accessibilityVisibleRows()?.count ?? 0
        XCTAssertEqual(table.accessibilityIndex(ofChild: stable), visibleCount)
        XCTAssertEqual(stable.accessibilityIndex(), 0)
        var reveals: [Int] = []
        table.onAccessibilityReveal = { reveals.append($0) }
        XCTAssertTrue(try XCTUnwrap(stable.accessibilityCustomActions()?.first?.handler)())
        XCTAssertEqual(reveals, [0], "Reveal addresses the global document row, never the reordered child position")
        XCTAssertEqual(fixture.source.viewRequests, realized)
    }

    func testAXLayoutChangesPublishOnceForRealMembershipOrTopologyChangesOnly() throws {
        let fixture = try geometryTable(messageCount: 12_000, target: 20)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        _ = table.publishAccessibilityLayoutChangeIfNeeded()
        XCTAssertFalse(table.publishAccessibilityLayoutChangeIfNeeded())
        table.scrollRowToVisible(11_999)
        fixture.scroll.layoutSubtreeIfNeeded()
        let realizedBeforePublish = fixture.source.viewRequests
        XCTAssertTrue(table.publishAccessibilityLayoutChangeIfNeeded(),
                      "Ordinary navigation replaces viewport logical rows with real mounted rows")
        XCTAssertEqual(fixture.source.viewRequests, realizedBeforePublish,
                       "Publishing an accessibility change cannot realize any additional row")
        for _ in 0..<3 {
            fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
            table.scheduleAccessibilityLayoutChange()
        }
        XCTAssertFalse(table.publishAccessibilityLayoutChangeIfNeeded(),
                       "Repeated reflections/measurements with the same members must not cause notification loops")
        XCTAssertEqual(table.accessibilityArrayAttributeCount(.rows), 12_001)
        table.installLogicalRows(sourceIndices: Array(0..<12_000), resetting: true)
        XCTAssertTrue(table.publishAccessibilityLayoutChangeIfNeeded(),
                      "Replacing offscreen logical handles is a real tree change even if mounted rows stay the same")
        XCTAssertFalse(table.publishAccessibilityLayoutChangeIfNeeded())
        fixture.window.contentView = nil
        table.scheduleAccessibilityLayoutChange()
        XCTAssertFalse(table.publishAccessibilityLayoutChangeIfNeeded(),
                       "Detached readers cannot publish stale changes to an external client")
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
        XCTAssertNil((cell.host as any NSAccessibilityProtocol).accessibilityIdentifier())
        XCTAssertFalse(cell.retainsTextFocus)
        XCTAssertNil(cell.onWillDetach)
        XCTAssertNil(cell.onIntrinsicSizeInvalidated)
    }

    @available(macOS, deprecated: 10.10)
    func testReusedHostIdentifierMatchesNativeStorageAndObservableChanges() {
        let cell = ConversationNativeReaderCell()
        let originalHost = cell.host
        let nativeView = NSView()
        let nativeHost = NSHostingView(rootView: Text("Native identifier reference"))
        let initial = "conversation.message.0"
        cell.host.messageIdentifier = initial
        nativeView.setAccessibilityIdentifier(initial)
        nativeHost.setAccessibilityIdentifier(initial)
        let views: [NSView] = [nativeView, nativeHost, cell.host]
        let recorders = views.map { view in
            let recorder = ConversationNativeReaderIdentifierRecorder()
            view.addObserver(recorder, forKeyPath: "accessibilityIdentifier", options: [.old, .new], context: nil)
            return recorder
        }
        defer {
            for (view, recorder) in zip(views, recorders) {
                view.removeObserver(recorder, forKeyPath: "accessibilityIdentifier")
            }
        }
        let identifiers: [String?] = ["conversation.message.11999", nil, "conversation.message.7", nil]
        for identifier in identifiers {
            nativeView.setAccessibilityIdentifier(identifier)
            nativeHost.setAccessibilityIdentifier(identifier)
            if let identifier {
                cell.host.messageIdentifier = identifier
            } else {
                cell.discardContent()
            }
            XCTAssertTrue(cell.host === originalHost, "Cell reuse must update the existing real host")
            XCTAssertEqual(cell.host.messageIdentifier, identifier)
            XCTAssertEqual((cell.host as any NSAccessibilityProtocol).accessibilityIdentifier(),
                           (nativeView as any NSAccessibilityProtocol).accessibilityIdentifier())
            XCTAssertEqual((cell.host as any NSAccessibilityProtocol).accessibilityIdentifier(),
                           (nativeHost as any NSAccessibilityProtocol).accessibilityIdentifier())
            // Stock AppKit's direct deprecated getter need not bridge its modern identifier.
            // Our explicit compatibility bridge must return that same native, current value.
            XCTAssertEqual(cell.host.accessibilityAttributeValue(.identifier) as? String, identifier)
        }
        let directNativeIdentifier = "conversation.message.42"
        for view in views { view.setAccessibilityIdentifier(directNativeIdentifier) }
        XCTAssertEqual(cell.host.messageIdentifier, directNativeIdentifier,
                       "Native setters and the compatibility property cannot have separate storage")
        XCTAssertEqual(cell.host.accessibilityAttributeValue(.identifier) as? String, directNativeIdentifier)
        let expectedOld: [String?] = [initial, "conversation.message.11999", nil, "conversation.message.7", nil]
        let expectedNew = identifiers + [directNativeIdentifier]
        for recorder in recorders {
            XCTAssertEqual(recorder.oldValues, expectedOld)
            XCTAssertEqual(recorder.newValues, expectedNew)
        }
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
        XCTAssertNil((host as any NSAccessibilityProtocol).accessibilityIdentifier(),
                     "Reused hosts cannot retain a stale message identifier")
    }

    func testAccessibilityHitTestingReachesActualHostedControlsAndTheirMessageAncestor() throws {
        let fixture = try geometryTable(messageCount: 12_000, target: 11_999)
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let row = try XCTUnwrap(table.rowView(atRow: 11_999, makeIfNecessary: false))
        let button = try XCTUnwrap(nativeResultButton(in: fixture.cell.host))
        let point = button.accessibilityActivationPoint()
        let roots: [NSView] = [fixture.scroll, table, row, fixture.cell, fixture.cell.host]
        let realizedBefore = fixture.source.viewRequests
        for root in roots {
            let hit = try XCTUnwrap(root.accessibilityHitTest(point))
            XCTAssertTrue(hasAccessibilityAncestor(hit, button),
                          "The public AX hit must reach the real button or its native NSButtonCell, not stop at its table/cell/group")
            XCTAssertTrue(hasAccessibilityAncestor(hit, fixture.cell.host),
                          "The identified message host must be in the actual hit's ancestry")
        }
        XCTAssertEqual(table.accessibilityRows()?.count, 12_001)
        XCTAssertEqual(fixture.source.viewRequests, realizedBefore,
                       "Hit testing only visits already-rendered views; it must not realize offscreen rows")
        XCTAssertLessThan(realizedBefore, 20)
    }

    func testAccessibilityHitTestingRejectsClippedAndOutsideViewportPoints() throws {
        let fixture = try geometryTable()
        defer { fixture.window.close() }
        let table = try XCTUnwrap(fixture.scroll.documentView as? ConversationNativeReaderTable)
        let button = try XCTUnwrap(nativeResultButton(in: fixture.cell.host))
        let buttonInDocument = button.convert(button.bounds, to: table)
        fixture.scroll.contentView.scroll(to: NSPoint(x: 0,
            y: buttonInDocument.minY + buttonInDocument.height * 0.75))
        fixture.scroll.layoutSubtreeIfNeeded()
        let visiblePoint = button.accessibilityActivationPoint()
        let visibleHit = try XCTUnwrap(fixture.scroll.accessibilityHitTest(visiblePoint))
        XCTAssertTrue(hasAccessibilityAncestor(visibleHit, button))
        let hiddenDocumentPoint = NSPoint(x: buttonInDocument.midX, y: buttonInDocument.minY + 1)
        let hiddenPoint = fixture.window.convertPoint(toScreen: table.convert(hiddenDocumentPoint, to: nil))
        let hiddenLocalPoint = button.convert(hiddenDocumentPoint, from: table)
        XCTAssertFalse(button.bounds.intersection(button.visibleRect).contains(hiddenLocalPoint))
        let outsidePoint = fixture.window.convertPoint(toScreen: NSPoint(x: -10, y: -10))
        for point in [hiddenPoint, outsidePoint] {
            XCTAssertNil(fixture.scroll.accessibilityHitTest(point))
            XCTAssertNil(table.accessibilityHitTest(point))
            XCTAssertNil(fixture.cell.accessibilityHitTest(point))
            XCTAssertNil(fixture.cell.host.accessibilityHitTest(point))
        }
    }

    func testAccessibilityHitTestingPreservesNativeSelectableTextAndMessagePadding() throws {
        let fixture = try geometryTable()
        defer { fixture.window.close() }
        let host = fixture.cell.host
        let prose = NSTextView(frame: NSRect(x: 16, y: 3, width: 240, height: 25))
        prose.string = "Actual selectable native prose"
        prose.isEditable = false
        prose.isSelectable = true
        host.addSubview(prose)
        let prosePoint = fixture.window.convertPoint(toScreen: prose.convert(
            NSPoint(x: prose.bounds.midX, y: prose.bounds.midY), to: nil))
        for root in [fixture.scroll, host] {
            let hit = try XCTUnwrap(root.accessibilityHitTest(prosePoint))
            XCTAssertTrue(hasAccessibilityAncestor(hit, prose),
                          "Selectable text must keep its real native AX element rather than be flattened into the message")
            XCTAssertTrue(hasAccessibilityAncestor(hit, host))
        }
        let button = try XCTUnwrap(nativeResultButton(in: host))
        var inheritedCalls = 0
        let inheritedSemanticHit = ConversationNativeReaderAccessibilityHitTesting.hitTest(
            in: host, point: button.accessibilityActivationPoint(), preservesVirtualDescendants: true
        ) {
            inheritedCalls += 1
            // An actual mounted semantic text object stands in for the result of SwiftUI's
            // native resolver. Its result takes precedence over a coarser NSView-only hit.
            return prose
        }
        XCTAssertEqual(inheritedCalls, 1)
        XCTAssertTrue((inheritedSemanticHit as AnyObject?) === prose)
        let visible = host.bounds.intersection(host.visibleRect)
        let paddingPoint = fixture.window.convertPoint(toScreen: host.convert(
            NSPoint(x: visible.maxX - 2, y: visible.maxY - 2), to: nil))
        let paddingHit = try XCTUnwrap(fixture.scroll.accessibilityHitTest(paddingPoint))
        XCTAssertTrue(hasAccessibilityAncestor(paddingHit, host),
                      "Actual message padding remains part of its real identified host, not its enclosing cell")
    }

    private func hasAccessibilityAncestor(_ element: Any, _ ancestor: NSView) -> Bool {
        var current: Any? = element
        for _ in 0..<30 {
            guard let node = current as? any NSAccessibilityElementProtocol else { return false }
            if (node as AnyObject) === ancestor { return true }
            current = node.accessibilityParent()
        }
        return false
    }

    private func nativeResultButton(in view: NSView) -> ConversationToolResultNativeButton? {
        if let button = view as? ConversationToolResultNativeButton { return button }
        for child in view.subviews {
            if let button = nativeResultButton(in: child) { return button }
        }
        return nil
    }

    private func geometryTable(messageCount: Int = 40, target: Int = 20) throws -> (window: NSWindow, scroll: NSScrollView,
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
        let source = GeometrySource(count: messageCount)
        table.delegate = source
        table.dataSource = source
        table.installLogicalRows(sourceIndices: Array(0..<messageCount), resetting: true)
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        table.scrollRowToVisible(target)
        scroll.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: target, makeIfNecessary: false)
            as? ConversationNativeReaderCell)
        cell.layoutSubtreeIfNeeded()
        cell.host.layoutSubtreeIfNeeded()
        return (window, scroll, cell, source)
    }

    private final class GeometrySource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let count: Int
        var viewRequests = 0
        init(count: Int) { self.count = count }
        func numberOfRows(in tableView: NSTableView) -> Int { count + 1 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            viewRequests += 1
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

private final class ConversationNativeReaderIdentifierRecorder: NSObject {
    var oldValues: [String?] = []
    var newValues: [String?] = []

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        oldValues.append(change?[.oldKey] as? String)
        newValues.append(change?[.newKey] as? String)
    }
}
