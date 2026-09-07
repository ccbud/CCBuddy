import AppKit
import SwiftUI

/// CC Buddy's native workbench: quiet reading surfaces, translucent navigation and floating
/// controls. Glass communicates an interactive layer; transcripts remain opaque and readable.
/// Colors here are also the solid fallbacks for Reduce Transparency and Increase Contrast.
enum Theme {}

// MARK: - Materials

extension Theme {
    /// Window drag strip. Shares the sidebar tone so the title bar reads as part of the rail.
    static let titleBar = Color.themed(light: 0xE8ECF3, dark: 0x161B24)
    /// Library rail — the darkest persistent step in light mode.
    static let sidebar = Color.themed(light: 0xE8ECF3, dark: 0x161B24)
    /// Middle column: session stream, settings rail, provider list.
    static let list = Color.themed(light: 0xF6F8FC, dark: 0x1D2430)
    /// Outer canvas of the reading/detail area.
    static let background = Color.themed(light: 0xEDF1F7, dark: 0x252D3A)
    /// Raised reading material: reading card, popovers, menus, sheets.
    static let surface = Color.themed(light: 0xFFFFFF, dark: 0x303948)
    /// Quiet filled control: search field, badge backing, segmented track.
    static let fill = Color.themed(light: 0xE3E9F2, dark: 0x354051)
    /// A second, slightly quieter fill for nested chips inside `fill`.
    static let fillSubtle = Color.themed(light: 0xEEF2F8, dark: 0x2B3442)
    /// Row hover in the session stream and lists.
    static let hover = Color.themed(light: 0xE5EBF5, dark: 0x303C4E)
    /// Selected row in the session stream / reading target. Deliberately a low-saturation wash: a
    /// selected row has to survive being repeated down a long list without shouting.
    static let selection = Color.themed(light: 0xDAE8FF, dark: 0x263F61)
    /// Selected destination inside the library rail.
    static let sidebarAccent = Color.themed(light: 0xD5E3F8, dark: 0x294161)
    /// Hairline. Only where two surfaces share the same tone.
    static let separator = Color.themed(light: 0xCFD7E3, dark: 0x475164)
}

// MARK: - Content

extension Theme {
    /// Body copy and titles.
    static let foreground = Color.themed(light: 0x182236, dark: 0xF3F6FC)
    /// Every kind of secondary text. Never stack opacity on top of it.
    ///
    /// Dark enough to clear 4.5:1 against `sidebarAccent`, the darkest material it ever sits on —
    /// metadata here is body-sized, so the large-text allowance does not apply to it.
    static let mutedForeground = Color.themed(light: 0x4D5A6E, dark: 0xB9C5D8)
    /// Placeholder / disabled text — the only third step, used sparingly.
    static let faintForeground = Color.themed(light: 0x7B8799, dark: 0x8996AA)

    /// Blue is action, navigation and focus; agent brands keep their own identities.
    static let accent = Color.themed(light: 0x0068E1, dark: 0x006FE8)
    /// A separate text accent keeps small text readable on every material.
    static let accentText = Color.themed(light: 0x064EA8, dark: 0xA3CAFF)
    /// Content placed on top of `accent`.
    static let onAccent = Color.themed(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let accentSoft = Color.themed(light: 0xE5EFFF, dark: 0x233D60)
    static let glassHighlight = Color.themed(light: 0xFFFFFF, dark: 0x71829C)
}

// MARK: - Status

extension Theme {
    static let success = Color.themed(light: 0x3B774C, dark: 0x56C789)
    static let successSoft = Color.themed(light: 0xE7EFE6, dark: 0x1D3527)
    static let danger = Color.themed(light: 0xB4442F, dark: 0xFF8077)
    static let dangerSoft = Color.themed(light: 0xF8E7E2, dark: 0x3E2321)
    static let warning = Color.themed(light: 0x8D6316, dark: 0xE0A94A)
    static let warningSoft = Color.themed(light: 0xF6EEDD, dark: 0x3A2F1C)
}

// MARK: - Typography

/// Six fixed steps plus a small conversation annex, mirroring Wake's scale.
/// Anything that needs a size that is not listed here is a design bug, not a missing constant.
enum Typography {
    /// Product name on the About pane.
    static let display: CGFloat = 34
    /// Context title at the top of the middle column.
    static let title: CGFloat = 24
    /// Section and dialog titles, session title in the reading header.
    static let heading: CGFloat = 16
    /// Navigation rows, list titles, buttons, inputs, dialog body.
    static let body: CGFloat = 14
    /// List sub-rows, metadata, placeholders, empty-state copy, paths.
    static let caption: CGFloat = 12
    /// Counts, keyboard badges, status strip, group heads.
    static let label: CGFloat = 11

    // Conversation annex — calibrated against long-form transcripts.
    static let messageUser: CGFloat = 13.5
    static let messageBody: CGFloat = 13
    static let messageThinking: CGFloat = 11.5
    static let messageMono: CGFloat = 12
}

extension Font {
    static func ccTitle(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: Typography.title, weight: weight)
    }
    static func ccHeading(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: Typography.heading, weight: weight)
    }
    static func ccBody(_ weight: Font.Weight = .regular) -> Font {
        .system(size: Typography.body, weight: weight)
    }
    static func ccCaption(_ weight: Font.Weight = .regular) -> Font {
        .system(size: Typography.caption, weight: weight)
    }
    static func ccLabel(_ weight: Font.Weight = .regular) -> Font {
        .system(size: Typography.label, weight: weight)
    }
    static func ccMono(_ size: CGFloat = Typography.messageMono, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Metrics

/// 4px grid. Views reference these instead of writing raw numbers so the rhythm survives edits.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

/// Four corner steps. Panels are the roundest, badges the tightest; nothing else is allowed.
enum Radius {
    static let panel: CGFloat = 20
    static let row: CGFloat = 12
    static let button: CGFloat = 10
    static let keyboard: CGFloat = 5
    static let badge: CGFloat = 6
}

/// Column widths shared by the shell and its columns.
enum Metrics {
    /// Library rail. Matches Wake's reference width.
    static let sidebarWidth: CGFloat = 224
    /// Session stream / settings rail.
    static let streamWidth: CGFloat = 336
    /// Height of the window drag strip that hosts the traffic lights.
    static let titleBarHeight: CGFloat = 38
    /// Leading offset a control needs to clear the traffic lights and still look deliberate rather
    /// than crowded against the green one.
    static let trafficLightClearance: CGFloat = 94
    /// Primary navigation row.
    static let rowHeight: CGFloat = 36
    /// Nested navigation row (agents, projects).
    static let subRowHeight: CGFloat = 30
    /// Toolbar/inline control height.
    static let controlHeight: CGFloat = 32
    /// Maximum measure for long-form reading copy.
    static let readingMaxWidth: CGFloat = 860
}

/// Sidebar geometry, derived from the traffic lights rather than from round numbers.
///
/// The close button sits at (20, 11) and measures 13.5pt, so its center falls on x = 26.75. Every
/// row's *leading element* is centered on that line — not left-aligned to it. Choosing center
/// alignment means an 18pt brand mark starts 2.25pt left of the red light; that is the expected
/// consequence of the choice, not a misalignment.
enum Rail {
    /// Horizontal padding of the rail container; also the left/right inset of a row's hover pill.
    static let edge: CGFloat = 10
    /// Fixed slot for the leading element, which is centered inside it so titles start in one place.
    static let leadBox: CGFloat = 18
    /// 26.75 − leadBox/2 − edge.
    static let leadInset: CGFloat = 7.75
    /// Nested rows step right to express subordination; they no longer sit on the center line.
    static let subIndent: CGFloat = 12
    /// Group heads carry no leading element, so their inset is derived from the glyph instead.
    static let groupHeadInset: CGFloat = 12.125
    /// Derived from the "C" of the wordmark at heading weight.
    static let titleInset: CGFloat = 9
}

// MARK: - Color plumbing

extension Color {
    /// Builds an appearance-aware opaque color. Every token in this file goes through here so a
    /// single implementation governs light/dark resolution.
    static func themed(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(themeHex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(themeHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
