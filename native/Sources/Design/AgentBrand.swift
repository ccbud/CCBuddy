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
        /// True when the asset is a full app icon with an opaque background rather than a trimmed
        /// glyph. Those get the squircle clip macOS gives app icons; drawn flat they would sit on
        /// the warm materials as a hard-edged block of their own background colour.
        var appIcon: Bool = false
    }

    static func mark(for source: HistorySource) -> Mark {
        switch source {
        case .claude: Mark(asset: "claude-code", monochrome: false, letter: "C")
        case .codex: Mark(asset: "codex", monochrome: false, letter: "O")
        case .grok: Mark(asset: "grok", monochrome: true, letter: "G")
        case .copilot: Mark(asset: "copilot", monochrome: true, letter: "G")
        case .antigravity: Mark(asset: "antigravity", monochrome: false, letter: "A")
        case .qoder: Mark(asset: "qoder", monochrome: false, letter: "Q", appIcon: true)
        }
    }

    /// Resolution order matches Wake: monochrome marks pick their ink from the effective appearance.
    ///
    /// Held once per asset. Every row of the session stream draws one of these, and reading the
    /// file and decoding the image on each redraw is what made the list scroll stiffly — the marks
    /// are a handful of small PNGs that never change while the app runs.
    static func image(for source: HistorySource, dark: Bool) -> NSImage? {
        let mark = mark(for: source)
        guard let asset = mark.asset else { return nil }
        let name = mark.monochrome && !dark ? "\(asset)-light" : asset

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = imageCache[name] { return cached.image }
        let loaded = load(named: name) ?? load(named: asset)
        imageCache[name] = CachedMark(image: loaded)
        return loaded
    }

    private struct CachedMark { let image: NSImage? }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var imageCache: [String: CachedMark] = [:]

    private static func load(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
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
                let mark = AgentBrand.mark(for: source)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(
                        cornerRadius: mark.appIcon ? size * 0.24 : 0,
                        style: .continuous
                    ))
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
