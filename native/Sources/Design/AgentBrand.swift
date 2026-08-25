import AppKit
import SwiftUI

/// Agent identity, in one place.
///
/// Identity is carried by the brand mark and the agent's name — never by tinting rows, icons or
/// panels. Monochrome marks ship in two inks: the plain asset for dark mode and a `-light` dark-ink
/// asset for light mode. Agents without a usable mark fall back to a neutral lettermark rather than
/// borrowing an unrelated SF Symbol.
enum AgentBrand {
    struct Mark {
        /// Asset base name used in dark mode, or for full-color marks in both modes.
        var asset: String?
        /// Whether the mark is monochrome and therefore needs the `-light` ink in light mode.
        var monochrome: Bool
        /// Shown when no asset resolves.
        var letter: String
    }

    static func mark(for source: HistorySource) -> Mark {
        switch source {
        case .claude: Mark(asset: "claude-code", monochrome: false, letter: "C")
        case .codex: Mark(asset: "codex", monochrome: false, letter: "O")
        case .grok: Mark(asset: "grok", monochrome: true, letter: "G")
        case .copilot: Mark(asset: "copilot", monochrome: true, letter: "G")
        case .antigravity: Mark(asset: "antigravity", monochrome: false, letter: "A")
        case .qoder: Mark(asset: nil, monochrome: false, letter: "Q")
        }
    }

    /// Resolution order matches Wake: monochrome marks pick their ink from the effective appearance.
    static func image(for source: HistorySource, dark: Bool) -> NSImage? {
        let mark = mark(for: source)
        guard let asset = mark.asset else { return nil }
        let name = mark.monochrome && !dark ? "\(asset)-light" : asset
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard let fallback = Bundle.main.url(forResource: asset, withExtension: "png") else { return nil }
        return NSImage(contentsOf: fallback)
    }
}

/// The brand mark at a given size. Renders at its original colors; selection never recolors it.
struct AgentBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme

    let source: HistorySource
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let image = AgentBrand.image(for: source, dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(Theme.fill)
                    Text(AgentBrand.mark(for: source).letter)
                        .font(.system(size: size * 0.58, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
