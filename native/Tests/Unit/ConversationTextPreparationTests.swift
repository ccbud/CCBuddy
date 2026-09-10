import SwiftUI
import XCTest
@testable import CCBuddy

final class ConversationTextPreparationTests: XCTestCase {
    func testPreparedMarkdownRetainsBlocksLiteralHTMLListsTablesAndCodeLineNumbers() throws {
        let source = """
        # Release **notes**

        A [link](https://example.com) and <script>literal</script>.

        - [x] **shipped**
        - [ ] verify

        > quoted *text*

        ```swift
        let answer = 42
        print(answer)
        ```

        | Key | Value |
        | --- | ---: |
        | a\\|b | `code` |
        """
        let base = try ConversationPreparedTextBase.make(source: source, parsesMarkdown: true)
        XCTAssertEqual(base.blocks, ConversationMarkdownParser.parse(source))
        XCTAssertEqual(base.inlines[[0]]?.rendered, "Release notes")
        XCTAssertEqual(base.inlines[[1]]?.rendered, "A link and <script>literal</script>.")
        XCTAssertEqual(base.inlines[[2, 0]]?.listMarker, "☑")
        XCTAssertEqual(base.inlines[[2, 0]]?.rendered, "shipped")
        XCTAssertEqual(base.inlines[[2, 1]]?.listMarker, "☐")
        XCTAssertEqual(base.inlines[[3, 0]]?.rendered, "quoted text")
        XCTAssertEqual(base.codeLineNumbers[[4]], "1\n2")
        XCTAssertEqual(base.inlines[[5, 0, 0]]?.rendered, "a|b")
        XCTAssertEqual(base.inlines[[5, 0, 1]]?.rendered, "code")
    }

    func testHighlightingPreservesOriginalLinkEmphasisAndCodeAttributes() throws {
        // Foundation drops the inner emphasis intent in `[*linked*](url)`. Outer emphasis
        // produces both attributes on the same run, so this fixture tests real preservation.
        let base = try ConversationPreparedInline.make("*[linked](https://example.com)* **bold** `code`", parsesMarkdown: true)
        XCTAssertTrue(base.attributed.runs.contains {
            $0.link == URL(string: "https://example.com")
                && $0.inlinePresentationIntent?.contains(.emphasized) == true
        }, "The fixture must contain a link and emphasis together before highlighting")
        XCTAssertTrue(base.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let highlighted = try base.highlighting(query: "linked bold code", current: true)
        XCTAssertEqual(String(highlighted.characters), base.rendered)
        for original in base.attributed.runs {
            let expectedIntent = (original.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            for actual in highlighted[original.range].runs {
                XCTAssertEqual(actual.inlinePresentationIntent, expectedIntent,
                               "Highlighting may add bold but must preserve every original intent")
                XCTAssertEqual(actual.link, original.link,
                               "Highlighting must preserve each original link range")
            }
        }
        XCTAssertTrue(highlighted.runs.contains { $0.link == URL(string: "https://example.com") })
        XCTAssertTrue(highlighted.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(highlighted.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(highlighted.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(highlighted.runs.allSatisfy { $0.foregroundColor == Theme.accentText })
    }

    func testHighlightingMatchesFoundationAcrossUnicodeAndWindowBoundaries() throws {
        let fixtures: [(String, String, Locale)] = [
            (String(repeating: "x", count: 16_383) + "系统代理 tail 系统代理", "系统代理", Locale(identifier: "en_US")),
            ("café cafe\u{301} CAFÉ", "cafe", Locale(identifier: "en_US")),
            ("I ı i İ ISTANBUL İstanbul", "i", Locale(identifier: "tr_TR")),
            ("ffi ﬃ FI", "ffi", Locale(identifier: "en_US")),
            ("ΟΣ ος οσ", "ος", Locale(identifier: "el_GR")),
            (String(repeating: "x", count: 16_383) + "a\u{301}b a\u{301}b", "ab", Locale(identifier: "en_US")),
        ]
        for (source, query, locale) in fixtures {
            let prepared = try ConversationPreparedInline.make(source, parsesMarkdown: false)
            let actual = try prepared.highlighting(query: query, current: false, locale: locale)
            let highlighted = actual.runs.filter { $0.foregroundColor == Theme.accent }
                .map { String(actual[$0.range].characters) }.joined()
            var expected = ""
            var cursor = source.startIndex
            while cursor < source.endIndex,
                  let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: cursor..<source.endIndex, locale: locale) {
                expected += source[range]
                cursor = range.upperBound
            }
            XCTAssertEqual(highlighted, expected, "Exact highlighted text for \(query)")
            XCTAssertEqual(String(actual.characters), source, "Highlight preparation never truncates source")
        }
    }

    func testQueryChangesReuseOnlyCurrentSourceAndClearCanImmediatelyReadBase() async throws {
        let worker = ConversationTextPreparationWorker()
        let first = try await worker.prepare(.init(source: "**needle** and tail"))
        let highlighted = try await worker.prepare(.init(source: first.base.source, query: "needle"))
        XCTAssertTrue(first.base === highlighted.base, "A keystroke must not decode the Markdown source again")
        XCTAssertEqual(highlighted.inline(at: [0], query: "", current: false), first.base.inlines[[0]]?.attributed)
        XCTAssertEqual(highlighted.inline(at: [0], query: "replacement", current: false), first.base.inlines[[0]]?.attributed,
                       "A newer query must not display old highlights while its worker is pending")
        let other = try await worker.prepare(.init(source: "different source"))
        XCTAssertFalse(other.base === first.base)
        let returned = try await worker.prepare(.init(source: first.base.source))
        XCTAssertFalse(returned.base === first.base, "No transcript-wide cache may retain older sources")
    }

    func testPreparationRunsOffMainThreadAndPrecancelledWorkDoesNotDecode() async throws {
        let probe = ConversationPreparationProbe()
        let worker = ConversationTextPreparationWorker(prepareBase: { try probe.prepare(source: $0, parsesMarkdown: $1) })
        _ = try await worker.prepare(.init(source: "**off-main**"))
        XCTAssertEqual(probe.mainThreadObservations, [false])
        let gate = ConversationPreparationAsyncGate()
        let canceled = Task.detached {
            await gate.wait()
            return try await worker.prepare(.init(source: "must not parse"))
        }
        canceled.cancel()
        await gate.open()
        do {
            _ = try await canceled.value
            XCTFail("Canceled preparation must throw")
        } catch is CancellationError { }
        XCTAssertEqual(probe.sources, ["**off-main**"])
    }

    @MainActor
    func testNewSourceCannotBeOverwrittenByCanceledPreparation() async throws {
        let probe = ConversationPreparationProbe(blockedSource: "old source")
        defer { probe.release() }
        let model = ConversationTextPreparation(worker: .init(prepareBase: { try probe.prepare(source: $0, parsesMarkdown: $1) }))
        let old = Task { await model.prepare(.init(source: "old source", query: "old")) }
        let deadline = Date().addingTimeInterval(2)
        while probe.sources.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(probe.sources, ["old source"])
        old.cancel()
        let latest = Task { await model.prepare(.init(source: "latest **source**", query: "latest")) }
        probe.release()
        await latest.value
        await old.value
        XCTAssertEqual(model.snapshot?.base.source, "latest **source**")
        XCTAssertEqual(model.snapshot?.query, "latest")
        XCTAssertEqual(probe.maximumConcurrentPreparations, 1)
    }

    @MainActor
    func testDisappearingProseReleasesItsPreparedSourceAndHighlights() async {
        let model = ConversationTextPreparation()
        await model.prepare(.init(source: "**needle** and source", query: "needle"))
        let base = ConversationPreparedTextWeakReference(model.snapshot?.base)
        XCTAssertNotNil(base.value)
        let released = model.release()
        XCTAssertNil(model.snapshot)
        await released.value
        XCTAssertNil(base.value, "A retained SwiftUI StateObject must not keep an offscreen transcript cache alive")
        await model.prepare(.init(source: "source after reappearance"))
        XCTAssertEqual(model.snapshot?.base.source, "source after reappearance")
    }

    @MainActor
    func testChangedSourceDropsOldSnapshotBeforeReplacementPreparationFinishes() async {
        let entered = expectation(description: "replacement preparation entered")
        let probe = ConversationPreparationProbe(blockedSource: "replacement", onSource: {
            if $0 == "replacement" { entered.fulfill() }
        })
        defer { probe.release() }
        let model = ConversationTextPreparation(worker: .init(prepareBase: {
            try probe.prepare(source: $0, parsesMarkdown: $1)
        }))
        await model.prepare(.init(source: "old **source**", query: "source"))
        let oldBase = ConversationPreparedTextWeakReference(model.snapshot?.base)
        XCTAssertNotNil(oldBase.value)
        let replacement = Task { await model.prepare(.init(source: "replacement")) }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(enteredResult, .completed)
        XCTAssertNil(model.snapshot, "A hidden old source must not stay published during its replacement")
        XCTAssertNil(oldBase.value, "Neither snapshot nor idle worker cache may retain the previous source")
        replacement.cancel()
        probe.release()
        await replacement.value
        XCTAssertNil(model.snapshot, "Canceled replacement must not bring back the old source")
        await model.release().value
    }

    @MainActor
    func testInFlightReleaseAndReappearanceUseTheSameSerialWorker() async {
        let entered = expectation(description: "old preparation entered")
        let nextStarted = expectation(description: "reappearance request started")
        let probe = ConversationPreparationProbe(blockedSource: "old source", onSource: {
            if $0 == "old source" { entered.fulfill() }
        })
        defer { probe.release() }
        let model = ConversationTextPreparation(worker: .init(prepareBase: {
            try probe.prepare(source: $0, parsesMarkdown: $1)
        }))
        let old = Task { await model.prepare(.init(source: "old source")) }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(enteredResult, .completed)
        let released = model.release()
        let latest = Task {
            nextStarted.fulfill()
            await model.prepare(.init(source: "reappeared source"))
        }
        let startedResult = await XCTWaiter.fulfillment(of: [nextStarted], timeout: 3)
        XCTAssertEqual(startedResult, .completed)
        XCTAssertEqual(probe.sources, ["old source"], "The stable worker remains occupied until the old call returns")
        probe.release()
        await latest.value
        await old.value
        await released.value
        XCTAssertEqual(probe.sources, ["old source", "reappeared source"],
                       "Reappearance must not silently substitute a fresh parallel worker")
        XCTAssertEqual(probe.maximumConcurrentPreparations, 1)
        XCTAssertEqual(model.snapshot?.base.source, "reappeared source")
        await model.release().value
    }

    func testLateReleaseCannotEraseBaseAdoptedByANewerAppearance() async throws {
        let probe = ConversationPreparationProbe()
        let worker = ConversationTextPreparationWorker(prepareBase: {
            try probe.prepare(source: $0, parsesMarkdown: $1)
        })
        let oldLifetime = UUID()
        let newLifetime = UUID()
        let request = ConversationTextPreparationRequest(source: "same source")
        let first = try await worker.prepare(request, lifetime: oldLifetime)
        let adopted = try await worker.prepare(request, lifetime: newLifetime)
        XCTAssertTrue(first.base === adopted.base)
        // Deliberately execute stale release AFTER new preparation, independent of executor order.
        await worker.release(lifetime: oldLifetime)
        let retained = try await worker.prepare(request, lifetime: newLifetime)
        XCTAssertTrue(adopted.base === retained.base)
        XCTAssertEqual(probe.sources, ["same source"])
        await worker.release(lifetime: newLifetime)
        let rebuilt = try await worker.prepare(request, lifetime: UUID())
        XCTAssertFalse(retained.base === rebuilt.base)
        XCTAssertEqual(probe.sources, ["same source", "same source"])
    }
}

private actor ConversationPreparationAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private final class ConversationPreparedTextWeakReference {
    weak var value: ConversationPreparedTextBase?

    init(_ value: ConversationPreparedTextBase?) { self.value = value }
}

private final class ConversationPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = NSCondition()
    private var isReleased = false
    private let blockedSource: String?
    private let onSource: (@Sendable (String) -> Void)?
    private var recordedSources: [String] = []
    private var observedThreads: [Bool] = []
    private var active = 0
    private var maximum = 0

    init(blockedSource: String? = nil, onSource: (@Sendable (String) -> Void)? = nil) {
        self.blockedSource = blockedSource
        self.onSource = onSource
    }
    var sources: [String] { lock.withLock { recordedSources } }
    var mainThreadObservations: [Bool] { lock.withLock { observedThreads } }
    var maximumConcurrentPreparations: Int { lock.withLock { maximum } }
    func release() {
        gate.lock()
        isReleased = true
        gate.broadcast()
        gate.unlock()
    }

    func prepare(source: String, parsesMarkdown: Bool) throws -> ConversationPreparedTextBase {
        lock.withLock {
            recordedSources.append(source)
            observedThreads.append(Thread.isMainThread)
            active += 1
            maximum = max(maximum, active)
        }
        defer { lock.withLock { active -= 1 } }
        onSource?(source)
        if source == blockedSource {
            gate.lock()
            while !isReleased { gate.wait() }
            gate.unlock()
        }
        return try ConversationPreparedTextBase.make(source: source, parsesMarkdown: parsesMarkdown)
    }
}
