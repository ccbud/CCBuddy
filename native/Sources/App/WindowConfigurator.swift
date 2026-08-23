import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        private weak var window: NSWindow?
        private var observationTokens: [NSObjectProtocol] = []

        deinit {
            removeObservers()
        }

        func attach(to window: NSWindow) {
            if self.window !== window {
                removeObservers()
                self.window = window

                let notifications: [Notification.Name] = [
                    NSWindow.didResizeNotification,
                    NSWindow.didEndLiveResizeNotification,
                    NSWindow.didEnterFullScreenNotification,
                    NSWindow.didExitFullScreenNotification,
                ]
                observationTokens = notifications.map { name in
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.positionTrafficLightsAfterAppKitLayout()
                    }
                }
            }

            positionTrafficLightsAfterAppKitLayout()
        }

        private func positionTrafficLightsAfterAppKitLayout() {
            positionTrafficLights()
            // AppKit can perform one more title-bar layout pass after style-mask and fullscreen
            // transitions, so repeat idempotently on the next main-queue turn.
            DispatchQueue.main.async { [weak self] in
                self?.positionTrafficLights()
            }
        }

        private func positionTrafficLights() {
            guard let window,
                  !window.styleMask.contains(.fullScreen),
                  let closeButton = window.standardWindowButton(.closeButton)
            else { return }

            let targetLeftEdge: CGFloat = 20
            let offset = targetLeftEdge - closeButton.frame.minX
            guard abs(offset) > 0.25 else { return }

            for kind in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton,
            ] {
                guard let button = window.standardWindowButton(kind) else { continue }
                var frame = button.frame
                frame.origin.x += offset
                button.setFrameOrigin(frame.origin)
            }
        }

        private func removeObservers() {
            for token in observationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            observationTokens.removeAll()
        }
    }

    var onWindowAvailable: ((NSWindow) -> Void)?

    init(onWindowAvailable: ((NSWindow) -> Void)? = nil) {
        self.onWindowAvailable = onWindowAvailable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { configure(view.window, coordinator: coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { configure(nsView.window, coordinator: coordinator) }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // Wake limits window dragging to the opaque column headers. Treating the whole window
        // background as draggable makes empty list/detail surfaces steal ordinary clicks and is
        // especially surprising around scroll views.
        window.isMovableByWindowBackground = false
        // Keep the native title bar visually integrated while giving materials an opaque backing.
        // A clear, non-opaque window makes the desktop bleed through behind the traffic lights.
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.minSize = NSSize(width: 940, height: 620)
        window.collectionBehavior.insert(.fullScreenPrimary)
        configureLegacySmokeContentSize(window)
        coordinator.attach(to: window)
        onWindowAvailable?(window)
    }

    /// The visual fixture now captures the integrated title-bar surface as part of the app shell,
    /// so its deterministic size is the complete window frame. Ordinary launches stay untouched.
    private func configureLegacySmokeContentSize(_ window: NSWindow) {
        guard AppModel.uiVisualFixture(environment: ProcessInfo.processInfo.environment) == .legacySmoke
        else { return }

        let target = NSSize(width: 1_180, height: 760)
        let widthDelta = target.width - window.frame.width
        let heightDelta = target.height - window.frame.height
        guard abs(widthDelta) > 0.25 || abs(heightDelta) > 0.25 else { return }

        let topEdge = window.frame.maxY
        var frame = window.frame
        frame.size.width += widthDelta
        frame.size.height += heightDelta
        frame.origin.y = topEdge - frame.height
        window.setFrame(frame, display: true)
    }
}

/// An AppKit-backed drag region for full-size-content windows. Put this behind a solid SwiftUI
/// header so the title bar remains visually part of that column while buttons and text fields in
/// front continue to receive their normal events.
struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}
