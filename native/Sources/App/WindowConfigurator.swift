import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    var onWindowAvailable: ((NSWindow) -> Void)?

    init(onWindowAvailable: ((NSWindow) -> Void)? = nil) {
        self.onWindowAvailable = onWindowAvailable
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: 900, height: 600)
        window.collectionBehavior.insert(.fullScreenPrimary)
        configureLegacySmokeContentSize(window)
        onWindowAvailable?(window)
    }

    /// The legacy screenshots compare the SwiftUI surface below the hidden native title bar.
    /// `.defaultSize` sizes the whole window, so grow only the outer frame by the current chrome
    /// delta and keep its top edge fixed. Reading `contentLayoutRect` makes this independent of the
    /// title-bar height and leaves ordinary launches untouched.
    private func configureLegacySmokeContentSize(_ window: NSWindow) {
        guard AppModel.uiVisualFixture(environment: ProcessInfo.processInfo.environment) == .legacySmoke
        else { return }

        let target = NSSize(width: 1_180, height: 760)
        let layoutSize = window.contentLayoutRect.size
        let widthDelta = target.width - layoutSize.width
        let heightDelta = target.height - layoutSize.height
        guard abs(widthDelta) > 0.25 || abs(heightDelta) > 0.25 else { return }

        let topEdge = window.frame.maxY
        var frame = window.frame
        frame.size.width += widthDelta
        frame.size.height += heightDelta
        frame.origin.y = topEdge - frame.height
        window.setFrame(frame, display: true)
    }
}
