import AppKit
import XCTest
@testable import CCBuddy

final class ConversationLatestScrollIntentTests: XCTestCase {
    private func request(file: String = "a", transcript: ConversationTranscriptID = .main,
                         revision: Int = 1) -> ConversationScrollLayoutRequest {
        .init(file: URL(fileURLWithPath: "/tmp/\(file).jsonl"), transcriptID: transcript,
              target: .latest(revision: revision))
    }

    private func jumpRequest(id: UUID = UUID(), index: Int = 12_191) -> ConversationScrollLayoutRequest {
        .init(file: URL(fileURLWithPath: "/tmp/a.jsonl"), transcriptID: .main,
              target: .message(.init(id: id, messageIndex: index)))
    }

    func testOnlyActiveNavigationCanAuthorizeLayoutCorrections() throws {
        var intent = ConversationScrollLayoutIntent()
        XCTAssertNil(intent.token)
        intent.update(request())
        let token = try XCTUnwrap(intent.token)
        XCTAssertTrue(intent.accepts(token))
        XCTAssertFalse(intent.update(request()), "Unrelated redraws do not create new navigation")
        XCTAssertTrue(intent.accepts(token))
        intent.update(nil)
        XCTAssertFalse(intent.accepts(token), "Opening a search result cancels pending following layout work")
    }

    func testUserScrollCancelsQueuedWorkAndSameRequestCannotReviveIt() throws {
        var intent = ConversationScrollLayoutIntent()
        intent.update(request())
        let token = try XCTUnwrap(intent.token)
        intent.cancelFromUser()
        XCTAssertFalse(intent.accepts(token))
        XCTAssertNil(intent.token)
        intent.update(request())
        XCTAssertNil(intent.token, "A stale SwiftUI update must not fight a user's gesture")
        intent.update(request(revision: 2))
        XCTAssertNotNil(intent.token, "A new explicit Latest choice can resume following")
        XCTAssertFalse(intent.accepts(token))
    }

    func testSourceTranscriptAndRevisionRejectStaleCorrections() throws {
        for replacement in [request(file: "b"), request(transcript: .subagent("child")), request(revision: 2)] {
            var intent = ConversationScrollLayoutIntent()
            intent.update(request())
            let old = try XCTUnwrap(intent.token)
            intent.update(replacement)
            XCTAssertFalse(intent.accepts(old))
            XCTAssertEqual(intent.token?.request, replacement)
        }
    }

    func testDisappearanceAndReappearanceNeverAuthorizeOldQueuedCallback() throws {
        var intent = ConversationScrollLayoutIntent()
        intent.update(request())
        let old = try XCTUnwrap(intent.token)
        intent.update(nil)
        intent.update(request())
        XCTAssertFalse(intent.accepts(old))
        XCTAssertNotNil(intent.token)
    }

    func testExplicitJumpIsRevokedByNextLatestAndSourceChanges() throws {
        let first = jumpRequest()
        for replacement in [jumpRequest(), jumpRequest(index: 12_193), request(),
                            request(file: "b"), request(transcript: .subagent("child"))] {
            var intent = ConversationScrollLayoutIntent()
            intent.update(first)
            let old = try XCTUnwrap(intent.token)
            intent.update(replacement)
            XCTAssertFalse(intent.accepts(old))
            XCTAssertEqual(intent.token?.request, replacement)
        }
    }

    func testManualScrollRevokesJumpUntilANewExplicitUUID() throws {
        var intent = ConversationScrollLayoutIntent()
        let first = jumpRequest()
        intent.update(first)
        let old = try XCTUnwrap(intent.token)
        intent.cancelFromUser()
        intent.update(first)
        XCTAssertNil(intent.token)
        XCTAssertFalse(intent.accepts(old))
        intent.update(jumpRequest())
        XCTAssertNotNil(intent.token, "An explicit jump to the same row is a new user intent")
    }

    func testMessageAnchorUsesOriginWhileLatestUsesBottom() {
        let jump = jumpRequest()
        XCTAssertEqual(jump.anchorID, ConversationPresentation.messageAnchor(12_191))
        XCTAssertEqual(jump.anchor, .top, "Growing owner content must not recenter away from its heading")
        XCTAssertEqual(request().anchorID, ConversationPresentation.bottomAnchor)
        XCTAssertEqual(request().anchor, .bottom)
    }

    func testNativeListScrollIdentityMatchesForEachWithoutASecondContentID() {
        let jump = jumpRequest(index: 12_191)
        XCTAssertEqual(jump.scrollID, AnyHashable(12_191),
                       "Message scrolling must reuse the Int identity provided by ForEach")
        XCTAssertNotEqual(jump.scrollID, AnyHashable(jump.anchorID),
                          "The diagnostic/layout string is not a second row identity")
        XCTAssertEqual(request().scrollID, AnyHashable(ConversationPresentation.bottomAnchor),
                       "The one footer row keeps its explicit bottom identity")
    }

    @MainActor
    func testActualDelayedLayoutChangesCoalesceWithoutRepeatingUnchangedFrames() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let probe = ConversationScrollLayoutObserver.Probe(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scrollView.documentView = probe
        window.contentView = scrollView
        defer { probe.disconnect(); window.contentView = nil; window.close() }
        let target = jumpRequest()
        var corrections: [ConversationScrollLayoutRequest] = []
        probe.configure(request: target, onContentLayout: { corrections.append($0) })
        await drainLayoutQueue()
        corrections.removeAll()

        probe.setFrameSize(NSSize(width: 600, height: 1_200))
        probe.setFrameSize(NSSize(width: 600, height: 1_600))
        await drainLayoutQueue()
        XCTAssertEqual(corrections, [target], "A burst of real lazy layout changes is one correction")
        probe.setFrameSize(NSSize(width: 600, height: 1_600))
        await drainLayoutQueue()
        XCTAssertEqual(corrections.count, 1, "No repeated correction when layout has not changed")

        probe.setFrameSize(NSSize(width: 600, height: 2_200))
        await drainLayoutQueue()
        XCTAssertEqual(corrections, [target, target], "Later asynchronous content can still stabilize its owner")
    }

    @MainActor
    func testUserScrollSynchronouslyCancelsQueuedAndLaterLayoutWork() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let probe = ConversationScrollLayoutObserver.Probe(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let input = ConversationScrollInputObserver.Probe(frame: container.bounds)
        scrollView.documentView = probe
        container.addSubview(scrollView)
        container.addSubview(input)
        window.contentView = container
        defer { probe.disconnect(); input.disconnect(); window.contentView = nil; window.close() }
        let target = jumpRequest()
        var activeRequest: ConversationScrollLayoutRequest? = target
        var corrections = 0
        var userScrolls = 0
        probe.configure(request: target, onContentLayout: { request in
            if activeRequest == request { corrections += 1 }
        })
        input.configure(scope: .init(file: target.file, transcriptID: target.transcriptID)) { _ in
            activeRequest = nil
            userScrolls += 1
        }
        XCTAssertNil(input.enclosingScrollView, "The permanent monitor belongs outside the native List")
        await drainLayoutQueue()
        corrections = 0

        probe.setFrameSize(NSSize(width: 600, height: 1_200))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        XCTAssertEqual(userScrolls, 1)
        await drainLayoutQueue()
        XCTAssertEqual(corrections, 0, "The already-queued callback must lose authority before user input proceeds")
        probe.configure(request: target, onContentLayout: { request in
            if activeRequest == request { corrections += 1 }
        })
        probe.setFrameSize(NSSize(width: 600, height: 1_600))
        await drainLayoutQueue()
        XCTAssertEqual(corrections, 0, "Old SwiftUI state and later content preparation cannot revive the jump")
    }

    @MainActor
    func testResidentInputMonitorWorksWithoutAnActiveRowAndAfterItsRecycling() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let reader = NSScrollView(frame: container.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000))
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        document.addSubview(row)
        reader.documentView = document
        let input = ConversationScrollInputObserver.Probe(frame: container.bounds)
        container.addSubview(reader)
        container.addSubview(input)
        window.contentView = container
        defer { input.disconnect(); window.contentView = nil; window.close() }
        let scope = ConversationScrollInputScope(file: URL(fileURLWithPath: "/tmp/input.jsonl"), transcriptID: .main)
        var calls: [ConversationScrollInputScope] = []
        for _ in 0..<5 { input.configure(scope: scope) { calls.append($0) } }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        XCTAssertEqual(calls, [scope], "Redraws install exactly one listener, even with no active search row")
        row.removeFromSuperview()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        XCTAssertEqual(calls, [scope, scope], "Scrolling beyond/recycling the old target cannot remove input monitoring")
        input.isHidden = true
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        XCTAssertEqual(calls.count, 2, "An invisible reader must not intercept another surface's navigation")
    }

    @MainActor
    func testResidentInputMonitorScopesWindowsPanesSourcesAndDisconnection() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 400))
        let sidebar = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let reader = NSScrollView(frame: NSRect(x: 500, y: 0, width: 500, height: 400))
        let foreign = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let input = ConversationScrollInputObserver.Probe(frame: reader.frame)
        container.addSubview(sidebar)
        container.addSubview(reader)
        container.addSubview(input)
        window.contentView = container
        otherWindow.contentView = foreign
        defer {
            input.disconnect()
            window.contentView = nil
            otherWindow.contentView = nil
            window.close()
            otherWindow.close()
        }
        let first = ConversationScrollInputScope(file: URL(fileURLWithPath: "/tmp/first.jsonl"), transcriptID: .main)
        let next = ConversationScrollInputScope(file: URL(fileURLWithPath: "/tmp/next.jsonl"), transcriptID: .subagent("child"))
        var calls: [ConversationScrollInputScope] = []
        input.configure(scope: first) { calls.append($0) }
        for ignored in [sidebar, foreign] {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: ignored)
        }
        XCTAssertTrue(calls.isEmpty)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        input.configure(scope: next) { calls.append($0) }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        XCTAssertEqual(calls, [first, next], "Source changes replace the callback scope, never reuse a stale row's source")
        input.removeFromSuperview()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        XCTAssertEqual(calls.count, 2, "Detached readers must immediately uninstall their listener")
        container.addSubview(input)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: reader)
        XCTAssertEqual(calls, [first, next, next], "Reattachment installs one current listener, not duplicates")
    }

    @MainActor
    private func drainLayoutQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
