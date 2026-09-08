import AppKit
import SwiftUI

struct ConversationLatestScrollRequest: Equatable {
    let file: URL
    let transcriptID: ConversationTranscriptID
    let revision: Int
}

/// A layout correction belongs to one explicit following intent, never a persistent search jump.
/// Remember canceled requests so an unrelated SwiftUI update cannot resurrect a user's scroll.
struct ConversationLatestScrollIntent {
    struct Token: Equatable {
        let request: ConversationLatestScrollRequest
        fileprivate let generation: UInt64
    }

    private var request: ConversationLatestScrollRequest?
    private var generation: UInt64 = 0
    private var isActive = false

    @discardableResult
    mutating func update(_ request: ConversationLatestScrollRequest?) -> Bool {
        guard self.request != request else { return false }
        self.request = request
        generation &+= 1
        isActive = request != nil
        return true
    }

    mutating func cancelFromUser() {
        generation &+= 1
        isActive = false
    }

    var token: Token? {
        guard isActive, let request else { return nil }
        return Token(request: request, generation: generation)
    }

    func accepts(_ token: Token) -> Bool { self.token == token }
}

/// The background gets the lazy stack's actual laid-out size, including asynchronous Markdown.
/// Bounds-origin changes are deliberately NOT observed: they include our own programmatic scrolls.
struct ConversationLatestScrollObserver: NSViewRepresentable {
    let request: ConversationLatestScrollRequest?
    let onContentLayout: (ConversationLatestScrollRequest) -> Void
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.configure(request: request, onContentLayout: onContentLayout, onUserScroll: onUserScroll)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        private var intent = ConversationLatestScrollIntent()
        private var desiredRequest: ConversationLatestScrollRequest?
        private var pendingCorrection: ConversationLatestScrollIntent.Token?
        private var onContentLayout: ((ConversationLatestScrollRequest) -> Void)?
        private var onUserScroll: (() -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?
        private var eventMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(request: ConversationLatestScrollRequest?,
                       onContentLayout: @escaping (ConversationLatestScrollRequest) -> Void,
                       onUserScroll: @escaping () -> Void) {
            desiredRequest = request
            self.onContentLayout = onContentLayout
            self.onUserScroll = onUserScroll
            if intent.update(request) {
                pendingCorrection = nil
                scheduleCorrection()
            }
            connect()
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { scheduleCorrection() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                disconnect()
            } else {
                intent.update(desiredRequest)
                connect()
                scheduleCorrection()
            }
        }

        private func connect() {
            guard window != nil, let scrollView = enclosingScrollView else { return }
            guard observedScrollView !== scrollView else { return }
            removeObservers()
            observedScrollView = scrollView
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView, queue: .main
            ) { [weak self] _ in self?.userDidScroll() }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
                [weak self] event in
                guard let self, let scrollView = self.observedScrollView,
                      event.window === scrollView.window else { return event }
                if event.type == .keyDown {
                    // Only scrolling keys whose first responder belongs to this reader. A search
                    // field, another pane or another window must not cancel following here.
                    let scrollingKeys: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
                    if scrollingKeys.contains(event.keyCode),
                       let responder = scrollView.window?.firstResponder as? NSView,
                       responder === scrollView || responder.isDescendant(of: scrollView.contentView) {
                        self.userDidScroll()
                    }
                } else {
                    let point = scrollView.convert(event.locationInWindow, from: nil)
                    guard scrollView.bounds.contains(point) else { return event }
                    if event.type == .scrollWheel, event.scrollingDeltaY != 0 {
                        self.userDidScroll()
                    } else if event.type == .leftMouseDown,
                              let scroller = scrollView.verticalScroller,
                              scroller.frame.contains(point) {
                        self.userDidScroll()
                    }
                }
                return event
            }
        }

        private func userDidScroll() {
            // Cancel before forwarding the actual input, not after a queued SwiftUI state update.
            intent.cancelFromUser()
            pendingCorrection = nil
            onUserScroll?()
        }

        private func scheduleCorrection() {
            guard pendingCorrection == nil, let token = intent.token else { return }
            pendingCorrection = token
            // Coalesce actual layout events until AppKit/SwiftUI finish this layout transaction.
            // There is no timer, retry loop or content preparation driven by this observer.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingCorrection == token else { return }
                self.pendingCorrection = nil
                guard self.window != nil, self.intent.accepts(token),
                      self.enclosingScrollView === self.observedScrollView else { return }
                self.onContentLayout?(token.request)
            }
        }

        func disconnect() {
            intent.update(nil)
            pendingCorrection = nil
            removeObservers()
        }

        private func removeObservers() {
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            liveScrollObserver = nil
            eventMonitor = nil
            observedScrollView = nil
        }

        deinit {
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }
    }
}
