import AppKit
import XCTest
@testable import CCBuddy

final class MenuBarPanelTests: XCTestCase {
    func testPositionerAnchorsBelowAndClampsRightEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 877)
        let anchor = NSRect(x: 1_380, y: 877, width: 24, height: 23)

        let frame = MenuBarPanelPositioner.frame(anchor: anchor, visibleFrame: visible)

        XCTAssertEqual(frame.size, NSSize(width: 424, height: 344))
        XCTAssertEqual(frame.maxX, visible.maxX - 8)
        XCTAssertEqual(frame.maxY, anchor.minY - 6)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 8)
    }

    func testPositionerUsesAboveFallbackAndVisibleBounds() {
        let visible = NSRect(x: -1_280, y: -300, width: 1_280, height: 900)
        let anchor = NSRect(x: -1_270, y: -280, width: 22, height: 22)

        let frame = MenuBarPanelPositioner.frame(anchor: anchor, visibleFrame: visible)

        XCTAssertEqual(frame.minX, visible.minX + 8)
        XCTAssertEqual(frame.minY, anchor.maxY + 6)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - 8)
    }

    func testPanelIsBorderlessNonactivatingAndFullScreenAuxiliary() {
        let assertions = {
            let panel = MenuBarPanel(language: .english)
            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertEqual(panel.frame.size, MenuBarPanelPositioner.defaultSize)
            XCTAssertEqual(panel.appearance?.name, .aqua)
            XCTAssertEqual(panel.accessibilityLabel(), "CC Buddy menu bar panel")
            panel.apply(language: .korean)
            XCTAssertEqual(panel.accessibilityLabel(), "CC Buddy 메뉴 막대 패널")
            panel.apply(themeMode: .dark)
            XCTAssertEqual(panel.appearance?.name, .darkAqua)
            panel.apply(themeMode: .light)
            XCTAssertEqual(panel.appearance?.name, .aqua)
            panel.close()
        }

        if Thread.isMainThread { assertions() }
        else { DispatchQueue.main.sync(execute: assertions) }
    }

    func testPopoverMetricsPreserveLegacyCardAndHeatmapGeometry() {
        XCTAssertEqual(MenuBarPopoverLayout.contentWidth, 402)
        XCTAssertEqual(MenuBarPopoverLayout.cardHeight * 2 + MenuBarPopoverLayout.cardSpacing, 105)
        XCTAssertEqual(MenuBarPopoverLayout.heatmapHeight, 102)
        XCTAssertEqual(MenuBarPopoverLayout.heatmapColumnCapacity, 27)

        let fullHeatmapWidth = CGFloat(MenuBarPopoverLayout.heatmapColumnCapacity)
            * MenuBarPopoverLayout.heatmapCellSize
            + CGFloat(MenuBarPopoverLayout.heatmapColumnCapacity - 1)
            * MenuBarPopoverLayout.heatmapSpacing
        XCTAssertEqual(fullHeatmapWidth, MenuBarPopoverLayout.contentWidth)
    }
}
