import AppKit
import SwiftUI

/// The single source of truth for CC Buddy's visual language.
///
/// The system fuses three lineages that used to fight each other on screen:
///
/// * **Wake** contributes the structure — an opaque warm-neutral material ladder where columns are
///   separated by tone rather than borders, persistent chrome casts no shadow, and every surface
///   belongs to one of five steps.
/// * **Claude** contributes the temperature and the accent — warm paper instead of clinical grey,
///   and clay instead of system blue for primary actions and selection.
/// * **cc-switch** contributes the gateway vocabulary, which is expressed with the semantic status
///   trio below rather than with its own palette.
///
/// Rules that every view is expected to honor:
///
/// 1. No color literals outside this file. Use `Theme` tokens.
/// 2. No font size literals outside this file. Use `Typography` steps.
/// 3. No shadows on persistent interface. Shadows belong to popovers, menus, sheets and toasts.
/// 4. No decorative gradients, and no border on a surface that already differs in tone.
/// 5. Agent identity is carried by the brand mark, never by tinting UI chrome.
enum Theme {}

// MARK: - Materials

extension Theme {
    /// Window drag strip. Shares the sidebar tone so the title bar reads as part of the rail.
    static let titleBar = Color.themed(light: 0xEDEBE4, dark: 0x1B1B19)
    /// Library rail — the darkest persistent step in light mode.
    static let sidebar = Color.themed(light: 0xEDEBE4, dark: 0x1B1B19)
    /// Middle column: session stream, settings rail, provider list.
    static let list = Color.themed(light: 0xF7F5F0, dark: 0x201F1D)
    /// Outer canvas of the reading/detail area.
    static let background = Color.themed(light: 0xF1EFE9, dark: 0x242320)
    /// Raised reading material: reading card, popovers, menus, sheets.
    static let surface = Color.themed(light: 0xFDFCFA, dark: 0x2C2B28)
    /// Quiet filled control: search field, badge backing, segmented track.
    static let fill = Color.themed(light: 0xE7E4DB, dark: 0x322F2B)
    /// A second, slightly quieter fill for nested chips inside `fill`.
    static let fillSubtle = Color.themed(light: 0xEEEBE3, dark: 0x2A2825)
    /// Row hover in the session stream and lists.
    static let hover = Color.themed(light: 0xE9E6DE, dark: 0x2A2926)
    /// Selected row in the session stream / reading target. Deliberately a low-saturation wash: a
    /// selected row has to survive being repeated down a long list without shouting.
    static let selection = Color.themed(light: 0xF0E7E1, dark: 0x372C26)
    /// Selected destination inside the library rail.
    static let sidebarAccent = Color.themed(light: 0xE0DCD1, dark: 0x343330)
    /// Hairline. Only where two surfaces share the same tone.
    static let separator = Color.themed(light: 0xE1DDD2, dark: 0x33322E)
}

// MARK: - Content

extension Theme {
    /// Body copy and titles.
    static let foreground = Color.themed(light: 0x1D1B18, dark: 0xF0EEE9)
    /// Every kind of secondary text. Never stack opacity on top of it.
    ///
    /// Dark enough to clear 4.5:1 against `sidebarAccent`, the darkest material it ever sits on —
    /// metadata here is body-sized, so the large-text allowance does not apply to it.
    static let mutedForeground = Color.themed(light: 0x64605A, dark: 0xA8A49B)
    /// Placeholder / disabled text — the only third step, used sparingly.
    static let faintForeground = Color.themed(light: 0x9A958A, dark: 0x7A766D)

    /// Claude clay. Fills for primary buttons, toggles, focus rings and active segments.
    static let accent = Color.themed(light: 0xCC785C, dark: 0xD97757)
    /// Darkened clay for accent-colored *text* so it clears contrast on paper.
    static let accentText = Color.themed(light: 0xA64F2B, dark: 0xE7A184)
    /// Content placed on top of `accent`.
    static let onAccent = Color.themed(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// Faint clay wash for accent-tinted backings.
    static let accentSoft = Color.themed(light: 0xF6E8E1, dark: 0x3A2A22)
}

// MARK: - Status

extension Theme {
    static let success = Color.themed(light: 0x3B774C, dark: 0x56C789)
    static let successSoft = Color.themed(light: 0xE7EFE6, dark: 0x1D3527)
    static let danger = Color.themed(light: 0xB4442F, dark: 0xFF6B60)
    static let dangerSoft = Color.themed(light: 0xF8E7E2, dark: 0x3E2321)
    static let warning = Color.themed(light: 0x8D6316, dark: 0xE0A94A)
    static let warningSoft = Color.themed(light: 0xF6EEDD, dark: 0x3A2F1C)
}

// MARK: - Typography

/// Six fixed steps plus a small conversation annex, mirroring Wake's scale.
/// Anything that needs a size that is not listed here is a design bug, not a missing constant.
enum Typography {
    /// Product name on the About pane.
    static let display: CGFloat = 28
    /// Context title at the top of the middle column.
    static let title: CGFloat = 22
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
    static let panel: CGFloat = 12
    static let row: CGFloat = 8
    static let button: CGFloat = 6
    static let keyboard: CGFloat = 5
    static let badge: CGFloat = 4
}

/// Column widths shared by the shell and its columns.
enum Metrics {
    /// Library rail. Matches Wake's reference width.
    static let sidebarWidth: CGFloat = 224
    /// Session stream / settings rail.
    static let streamWidth: CGFloat = 336
    /// Height of the window drag strip that hosts the traffic lights.
    static let titleBarHeight: CGFloat = 38
    /// Primary navigation row.
    static let rowHeight: CGFloat = 32
    /// Nested navigation row (agents, projects).
    static let subRowHeight: CGFloat = 26
    /// Toolbar/inline control height.
    static let controlHeight: CGFloat = 28
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
