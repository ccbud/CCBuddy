import AppKit
import SwiftUI
import XCTest

@testable import CCBuddy

/// Contrast checks for the palette.
///
/// The materials are deliberately close together in tone — that is what lets columns separate
/// without borders — so it is easy to nudge one step and quietly push text below the readable
/// threshold in one appearance only. These assertions pin the ratios that matter in both modes.
final class ThemeContrastTests: XCTestCase {
    /// WCAG AA for body-sized text.
    private let bodyMinimum = 4.5
    /// WCAG AA for text at 18pt+ or 14pt+ bold, and for meaningful non-text marks.
    private let largeMinimum = 3.0

    private let appearances: [(name: String, appearance: NSAppearance)] = [
        ("light", NSAppearance(named: .aqua)!),
        ("dark", NSAppearance(named: .darkAqua)!),
    ]

    private func srgb(_ color: Color, _ appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    /// Relative luminance per WCAG 2.x.
    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func ratio(_ foreground: Color, on background: Color, _ appearance: NSAppearance) -> Double {
        let a = luminance(srgb(foreground, appearance))
        let b = luminance(srgb(background, appearance))
        let lighter = max(a, b), darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func assertContrast(
        _ foreground: Color,
        _ foregroundName: String,
        on background: Color,
        _ backgroundName: String,
        atLeast minimum: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, appearance) in appearances {
            let value = ratio(foreground, on: background, appearance)
            XCTAssertGreaterThanOrEqual(
                value,
                minimum,
                "\(foregroundName) on \(backgroundName) in \(name): \(String(format: "%.2f", value)):1",
                file: file,
                line: line
            )
        }
    }

    private var materials: [(String, Color)] {
        [
            ("sidebar", Theme.sidebar),
            ("list", Theme.list),
            ("background", Theme.background),
            ("surface", Theme.surface),
            ("fill", Theme.fill),
            ("fillSubtle", Theme.fillSubtle),
            ("selection", Theme.selection),
            ("sidebarAccent", Theme.sidebarAccent),
            ("hover", Theme.hover),
        ]
    }

    func testBodyTextIsReadableOnEveryMaterial() {
        for (name, material) in materials {
            assertContrast(Theme.foreground, "foreground", on: material, name, atLeast: bodyMinimum)
        }
    }

    func testSecondaryTextIsReadableOnEveryMaterial() {
        // Every kind of metadata uses this ink, and metadata is body-sized here, so it has to clear
        // the body threshold rather than the large-text one.
        for (name, material) in materials {
            assertContrast(
                Theme.mutedForeground,
                "mutedForeground",
                on: material,
                name,
                atLeast: bodyMinimum
            )
        }
    }

    func testAccentTextIsReadableWhereItIsUsed() {
        // Clay text appears on the reading surface, on the selection wash and on its own soft tint.
        for (name, material) in [
            ("surface", Theme.surface),
            ("selection", Theme.selection),
            ("accentSoft", Theme.accentSoft),
            ("list", Theme.list),
        ] {
            assertContrast(Theme.accentText, "accentText", on: material, name, atLeast: bodyMinimum)
        }
    }

    func testPrimaryButtonLabelIsReadable() {
        assertContrast(Theme.onAccent, "onAccent", on: Theme.accent, "accent", atLeast: largeMinimum)
    }

    func testStatusInkIsReadableOnItsOwnTintAndOnTheSurface() {
        let pairs: [(String, Color, String, Color)] = [
            ("success", Theme.success, "successSoft", Theme.successSoft),
            ("danger", Theme.danger, "dangerSoft", Theme.dangerSoft),
            ("warning", Theme.warning, "warningSoft", Theme.warningSoft),
        ]
        for (inkName, ink, tintName, tint) in pairs {
            assertContrast(ink, inkName, on: tint, tintName, atLeast: bodyMinimum)
            assertContrast(ink, inkName, on: Theme.surface, "surface", atLeast: bodyMinimum)
        }
    }

    func testAdjacentColumnsAreDistinguishableWithoutBorders() {
        // Separation by tone only works if the steps are actually different. These are deliberately
        // small differences, so the test guards the floor rather than a comfortable margin.
        let ladder: [(String, Color, String, Color)] = [
            ("sidebar", Theme.sidebar, "list", Theme.list),
            ("list", Theme.list, "background", Theme.background),
            ("background", Theme.background, "surface", Theme.surface),
        ]
        for (leftName, left, rightName, right) in ladder {
            for (appearanceName, appearance) in appearances {
                let value = ratio(left, on: right, appearance)
                XCTAssertGreaterThan(
                    value,
                    1.02,
                    "\(leftName) and \(rightName) are indistinguishable in \(appearanceName)"
                )
            }
        }
    }

    func testSelectionReadsAsASelectionAgainstItsColumn() {
        for (appearanceName, appearance) in appearances {
            let value = ratio(Theme.selection, on: Theme.list, appearance)
            XCTAssertGreaterThan(
                value,
                1.03,
                "selected rows do not stand out from the stream in \(appearanceName): \(value)"
            )
        }
    }

    func testHairlineIsVisibleAgainstTheSurfacesItSeparates() {
        for (name, material) in [("surface", Theme.surface), ("list", Theme.list)] {
            for (appearanceName, appearance) in appearances {
                let value = ratio(Theme.separator, on: material, appearance)
                XCTAssertGreaterThan(
                    value,
                    1.05,
                    "separator is invisible on \(name) in \(appearanceName): \(value)"
                )
            }
        }
    }
}
