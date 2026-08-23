import AppKit
import SwiftUI

extension Color {
    static let ccBrand = adaptive(light: 0xCC785C, dark: 0x6366F1)
    static let ccBrandStrong = adaptive(light: 0xBD5D3A, dark: 0x818CF8)
    static let ccBrandSoft = adaptive(light: 0xF7E9E4, dark: 0x2D2A52)
    static let ccAppBackground = adaptive(light: 0xFAF9F5, dark: 0x12141B)
    static let ccSidebar = adaptive(light: 0xEDEDEA, dark: 0x1B1B1A)
    static let ccElevated = adaptive(light: 0xFFFFFF, dark: 0x22242E)
    static let ccInput = adaptive(light: 0xFFFFFF, dark: 0x16181F)
    /// Opaque neighboring materials for the Wake-style conversation workbench.
    static let ccConversationList = adaptive(light: 0xF7F7F5, dark: 0x20201F)
    static let ccConversationBackground = adaptive(light: 0xF1F1EF, dark: 0x242422)
    static let ccConversationSurface = adaptive(light: 0xFDFDFC, dark: 0x2C2C2A)
    static let ccConversationSelection = adaptive(light: 0xE3EBF6, dark: 0x303B4C)
    static let ccSidebarSelection = adaptive(light: 0xDEDEDA, dark: 0x343432)
    static let ccForeground = adaptive(light: 0x29261F, dark: 0xF2F2F4)
    static let ccMuted = adaptive(light: 0x6E6A5F, dark: 0xA1A1AA)
    static let ccCaption = adaptive(light: 0x857F72, dark: 0x8D8D98)
    static let ccBorder = adaptive(light: 0xDDDAD1, dark: 0x353741)
    static let ccBorderStrong = adaptive(light: 0xCBC7BC, dark: 0x464853)
    static let ccGreen = adaptive(light: 0x5B7F3F, dark: 0x32D74B)
    static let ccGreenSoft = adaptive(light: 0xEAF0E5, dark: 0x193A24)
    static let ccRed = adaptive(light: 0xB24632, dark: 0xFF6961)
    static let ccRedSoft = adaptive(light: 0xF7E8E5, dark: 0x492526)
    static let ccOrange = Color(red: 1, green: 0.58, blue: 0)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(hex: useDark ? dark : light)
        })
    }
}
private func nsColor(hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}
