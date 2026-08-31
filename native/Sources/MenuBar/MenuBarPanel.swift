import AppKit

enum MenuBarPopoverLayout {
    static let panelSize = NSSize(width: 424, height: 344)
    static let horizontalInset: CGFloat = 11
    static let topInset: CGFloat = 11
    static let headerHeight: CGFloat = 28
    static let headerToContentSpacing: CGFloat = 8
    static let cardHeight: CGFloat = 50
    static let cardSpacing: CGFloat = 5
    static let heatmapCellSize: CGFloat = 12
    static let heatmapSpacing: CGFloat = 3
    static let heatmapRows = 7
    static let footerHeight: CGFloat = 45

    static var contentWidth: CGFloat {
        panelSize.width - horizontalInset * 2
    }

    static var heatmapHeight: CGFloat {
        heatmapCellSize * CGFloat(heatmapRows)
            + heatmapSpacing * CGFloat(heatmapRows - 1)
    }

    static var heatmapColumnCapacity: Int {
        Int((contentWidth + heatmapSpacing) / (heatmapCellSize + heatmapSpacing))
    }
}

enum MenuBarPanelPositioner {
    static let defaultSize = MenuBarPopoverLayout.panelSize

    /// Positions a panel below its status item, then clamps it into the screen's visible frame.
    /// The fallback above the anchor also makes the function useful for status-item substitutes
    /// placed at the bottom of a display in tests or future layouts.
    static func frame(
        anchor: NSRect,
        visibleFrame: NSRect,
        panelSize: NSSize = defaultSize,
        gap: CGFloat = 6,
        margin: CGFloat = 8
    ) -> NSRect {
        let safeWidth = min(max(1, panelSize.width), max(1, visibleFrame.width - margin * 2))
        let safeHeight = min(max(1, panelSize.height), max(1, visibleFrame.height - margin * 2))

        let minimumX = visibleFrame.minX + margin
        let maximumX = max(minimumX, visibleFrame.maxX - margin - safeWidth)
        let desiredX = anchor.midX - safeWidth / 2
        let x = min(max(desiredX, minimumX), maximumX)

        let minimumY = visibleFrame.minY + margin
        // The anchor gap already protects the menu-bar edge; keep the extra margin only at the
        // lower edge so the requested six-point spatial connection is preserved.
        let maximumY = max(minimumY, visibleFrame.maxY - safeHeight)
        let belowY = anchor.minY - gap - safeHeight
        let aboveY = anchor.maxY + gap
        let desiredY: CGFloat
        if belowY >= minimumY {
            desiredY = belowY
        } else if aboveY <= maximumY {
            desiredY = aboveY
        } else {
            desiredY = belowY
        }
        let y = min(max(desiredY, minimumY), maximumY)

        return NSRect(x: x, y: y, width: safeWidth, height: safeHeight)
    }
}

final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(
        language: AppLanguage = .simplifiedChinese,
        themeMode: AppModel.ThemeMode = .light,
        contentRect: NSRect = NSRect(origin: .zero, size: MenuBarPanelPositioner.defaultSize)
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilityIdentifier("menubar.panel")
        apply(language: language)
        apply(themeMode: themeMode)
    }

    func apply(language: AppLanguage) {
        setAccessibilityLabel(language.localized("CC Buddy 菜单栏面板"))
    }

    /// A status-item panel is hosted outside the app's SwiftUI scene, so it does not inherit the
    /// scene's preferred color scheme. Pin AppKit's material and dynamic colors to the explicit
    /// app theme instead of whichever appearance macOS happens to be using.
    func apply(themeMode: AppModel.ThemeMode) {
        appearance = NSAppearance(named: themeMode == .dark ? .darkAqua : .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
