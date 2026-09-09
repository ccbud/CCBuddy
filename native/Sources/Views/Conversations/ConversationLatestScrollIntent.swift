import AppKit
import SwiftUI

struct ConversationScrollLayoutRequest: Equatable {
    enum Target: Equatable {
        case latest(revision: Int)
        case message(ConversationJumpRequest)
    }

    let file: URL
    let transcriptID: ConversationTranscriptID
    let target: Target

    var anchorID: String {
        switch target {
        case .latest: ConversationPresentation.bottomAnchor
        case .message(let jump): ConversationPresentation.messageAnchor(jump.messageIndex)
        }
    }

    /// Reuse ForEach's data identity instead of adding a second content ID to every List row.
    /// Only the single bottom spacer needs its own explicit string identity.
    var scrollID: AnyHashable {
        switch target {
        case .latest: AnyHashable(ConversationPresentation.bottomAnchor)
        case .message(let jump): AnyHashable(jump.messageIndex)
        }
    }

    // Align the message's origin, not its center: asynchronous tool/Markdown preparation can
    // enlarge the owner row itself far beyond a viewport without moving its heading away.
    var anchor: UnitPoint {
        switch target {
        case .latest: .bottom
        case .message: .top
        }
    }
}

/// A layout correction belongs to one explicit source-scoped navigation intent.
/// Remember canceled requests so an unrelated SwiftUI update cannot resurrect a user's scroll.
struct ConversationScrollLayoutIntent {
    struct Token: Equatable {
        let request: ConversationScrollLayoutRequest
        fileprivate let generation: UInt64
    }

    private var request: ConversationScrollLayoutRequest?
    private var generation: UInt64 = 0
    private var isActive = false

    @discardableResult
    mutating func update(_ request: ConversationScrollLayoutRequest?) -> Bool {
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

/// The background gets the active native row's actual laid-out size, including asynchronous Markdown.
/// Bounds-origin changes are deliberately NOT observed: they include our own programmatic scrolls.
struct ConversationScrollLayoutObserver: NSViewRepresentable {
    let request: ConversationScrollLayoutRequest?
    let onContentLayout: (ConversationScrollLayoutRequest) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.configure(request: request, onContentLayout: onContentLayout)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        private var intent = ConversationScrollLayoutIntent()
        private var desiredRequest: ConversationScrollLayoutRequest?
        private var pendingCorrection: ConversationScrollLayoutIntent.Token?
        private var onContentLayout: ((ConversationScrollLayoutRequest) -> Void)?
        private weak var observedScrollView: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(request: ConversationScrollLayoutRequest?,
                       onContentLayout: @escaping (ConversationScrollLayoutRequest) -> Void) {
            desiredRequest = request
            self.onContentLayout = onContentLayout
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
            observedScrollView = scrollView
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
            observedScrollView = nil
        }
    }
}

struct ConversationScrollInputScope: Equatable {
    let file: URL
    let transcriptID: ConversationTranscriptID
}

/// One resident input monitor belongs to the reader viewport, not a virtualized row. A pending
/// search has no active row yet, and a reader can scroll far enough to recycle the old anchor.
/// Neither case may remove the user's ability to cancel navigation. Bounds-origin changes are
/// deliberately not observed, so programmatic scrollTo and native row-height updates are inert.
struct ConversationScrollInputObserver: NSViewRepresentable {
    let scope: ConversationScrollInputScope
    let onUserScroll: (ConversationScrollInputScope) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.configure(scope: scope, onUserScroll: onUserScroll)
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        private var scope: ConversationScrollInputScope?
        private var onUserScroll: ((ConversationScrollInputScope) -> Void)?
        private var liveScrollObserver: NSObjectProtocol?
        private var eventMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(scope: ConversationScrollInputScope,
                       onUserScroll: @escaping (ConversationScrollInputScope) -> Void) {
            self.scope = scope
            self.onUserScroll = onUserScroll
            connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { disconnect() } else { connect() }
        }

        private func connect() {
            guard window != nil, liveScrollObserver == nil, eventMonitor == nil else { return }
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self, let scrollView = notification.object as? NSScrollView,
                      self.containsScrollView(scrollView) else { return }
                self.userDidScroll()
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
                [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func containsScrollView(_ scrollView: NSScrollView) -> Bool {
            guard let window, scrollView.window === window, !bounds.isEmpty,
                  !isHiddenOrHasHiddenAncestor else { return false }
            return bounds.intersects(convert(scrollView.bounds, from: scrollView))
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, !bounds.isEmpty,
                  !isHiddenOrHasHiddenAncestor else { return }
            if event.type == .keyDown {
                let scrollingKeys: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
                guard scrollingKeys.contains(event.keyCode),
                      let responder = window.firstResponder as? NSView,
                      let scrollView = (responder as? NSScrollView) ?? responder.enclosingScrollView,
                      containsScrollView(scrollView) else { return }
                userDidScroll()
            } else {
                guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
                if event.type == .scrollWheel, event.scrollingDeltaY != 0 {
                    userDidScroll()
                } else if event.type == .leftMouseDown, let content = window.contentView {
                    var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                    while let candidate = hit {
                        if candidate is NSScroller { userDidScroll(); break }
                        hit = candidate.superview
                    }
                }
            }
        }

        private func userDidScroll() {
            // Store revokes the source-scoped request synchronously, before forwarding the input.
            // Queued row corrections consult that current request again before scrolling.
            guard let scope else { return }
            onUserScroll?(scope)
        }

        func disconnect() {
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            liveScrollObserver = nil
            eventMonitor = nil
        }

        deinit {
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }
    }
}
