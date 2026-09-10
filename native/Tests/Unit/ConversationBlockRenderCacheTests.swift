import Foundation
import XCTest
@testable import CCBuddy

final class ConversationToolResultByteCountTests: XCTestCase {
    func testByteCountMatchesActualResultTextSelectionAndJSONEncoding() {
        let controls = String((0..<32).compactMap { UnicodeScalar($0) }.map { Character($0) })
        let escaped = controls + "\"\\/系统代理😀e\u{301}\u{2028}\u{2029}"
        let cases: [HistoryValue?] = [
            nil, .string(""), .string(escaped), .null, .bool(true), .bool(false),
            .number(0), .number(-0.0), .number(1.5), .number(1e100),
            .number(.greatestFiniteMagnitude), .number(.leastNonzeroMagnitude),
            .number(.infinity), .number(.nan),
            .array([]), .object([:]), .array([.string("")]),
            .array([.string(""), .string("")]),
            .array([.object(["text": .string("")])]),
            .array([.object(["text": .string("first")]), .number(7), .string("last")]),
            .array([.object(["text": .number(7)]), .bool(true)]),
            .array([.string("usable text"), .number(.infinity)]),
            .object(["nested": .array([.string(escaped), .number(-0.0), .null])]),
            .object([escaped: .object(["slash/key": .string(escaped)])]),
            .object(["invalid": .number(.infinity)]),
        ]
        for (index, value) in cases.enumerated() {
            assertParity(value, label: "case \(index)")
        }
    }

    func testGeneratedNestedObjectsHaveExactCollapsedByteSummaries() {
        for index in 0..<128 {
            let token = "条目 \(index) / \\\"\n\t😀"
            let content: HistoryValue = .object([
                "index": .number(Double(index) / 7),
                "items": .array((0..<(index % 9)).map { item in
                    .object([
                        "text": .string(String(repeating: token, count: item)),
                        "enabled": .bool(item.isMultiple(of: 2)),
                        "nested": .array([.null, .number(Double(item) * -1e-12)]),
                    ])
                }),
            ])
            assertParity(content, label: "generated \(index)")
        }
    }

    func testLargePlainAndStructuredResultsKeepTheCompleteTailAndExactSummary() {
        let tail = "系统代理 — 当前版本 — tail"
        let large = String(repeating: "Large result line.\n", count: 60_000) + tail
        let plain: HistoryValue = .array([
            .object(["type": .string("text"), "text": .string(large)]),
            .object(["text": .string("after tail")]),
        ])
        assertParity(plain, label: "large text array")
        assertParity(.object(["payload": .string(large)]), label: "large JSON object")
        XCTAssertEqual(ConversationVisibleText.toolResultText(plain), large + "\nafter tail")
    }

    func testContainerDepthFailureMatchesEncoderWithoutRejectingSelectedText() {
        var nested = HistoryValue.null
        for depth in 1...513 {
            nested = depth.isMultiple(of: 2) ? .array([nested]) : .object(["nested": nested])
            if depth >= 510 { assertParity(nested, label: "container depth \(depth)") }
        }
        assertParity(.array([.string("selected text"), nested]), label: "text selection ignores deep sibling")
        XCTAssertEqual(ConversationToolResultByteCount.count(.array([.string("selected text"), nested])), 13)
    }

    private func assertParity(_ value: HistoryValue?, label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = ConversationVisibleText.toolResultText(value)
        let count = ConversationToolResultByteCount.count(value)
        XCTAssertEqual(count, actual?.utf8.count, label, file: file, line: line)
        XCTAssertEqual(ConversationToolPresentation.resultSummary(byteCount: count),
                       ConversationToolPresentation.resultSummary(actual), label, file: file, line: line)
    }
}

@MainActor
final class ConversationBlockRenderCacheTests: XCTestCase {
    func testDisappearingBlockReleasesAllDerivedValuesBeforeReappearance() {
        let cache = ConversationBlockRenderCache()
        let version = version()
        _ = cache.presentation(for: version) { .make(name: "old", input: nil) }
        _ = cache.text(for: version) { "old result" }
        _ = cache.summary(for: version) { "old summary" }
        XCTAssertGreaterThan(cache.retainedTextBytes, 0)
        cache.release()
        XCTAssertEqual(cache.retainedTextBytes, 0)
        XCTAssertEqual(cache.presentation(for: version) { .make(name: "new", input: nil) },
                       .make(name: "new", input: nil))
        XCTAssertEqual(cache.text(for: version) { "new result" }, "new result")
        XCTAssertEqual(cache.summary(for: version) { "new summary" }, "new summary")
    }

    func testUnchangedBlockReusesPresentationTextAndSummaryWithoutRepreparing() {
        let cache = ConversationBlockRenderCache()
        let version = version()
        var presentations = 0
        var texts = 0
        var summaries = 0
        let expected = ConversationToolPresentation.make(
            name: "mcp__fixture", input: .object(["value": .string("unaltered input")])
        )
        for _ in 0..<20 {
            XCTAssertEqual(cache.presentation(for: version) {
                presentations += 1
                return expected
            }, expected)
            XCTAssertEqual(cache.text(for: version) {
                texts += 1
                return "complete result"
            }, "complete result")
            XCTAssertEqual(cache.summary(for: version) {
                summaries += 1
                return "15 B"
            }, "15 B")
        }
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(texts, 1)
        XCTAssertEqual(summaries, 1)
    }

    func testProjectionMessageAndBlockChangesEachInvalidateCachedValues() {
        let cache = ConversationBlockRenderCache()
        let first = version()
        let versions = [first,
            version(projection: first.projection, message: 1),
            version(projection: first.projection, message: 1, block: 1),
            version(message: 1, block: 1),
        ]
        for (index, version) in versions.enumerated() {
            let value = "version \(index)"
            XCTAssertEqual(cache.text(for: version) { value }, value)
            XCTAssertEqual(cache.summary(for: version) { value }, value)
            let expected = ConversationToolPresentation.make(name: value, input: nil)
            XCTAssertEqual(cache.presentation(for: version) { expected }, expected)
        }
    }

    func testCollapsedSummaryDoesNotMaterializeBodyAndCollapseReleasesCachedText() {
        let cache = ConversationBlockRenderCache()
        let version = version()
        let content: HistoryValue = .array([.string("first"), .string("last")])
        var bodyPreparations = 0
        let prepareBody = {
            bodyPreparations += 1
            return ConversationVisibleText.toolResultText(content)
        }
        XCTAssertEqual(cache.summary(for: version) {
            ConversationToolPresentation.resultSummary(byteCount: ConversationToolResultByteCount.count(content))
        }, "10 B")
        XCTAssertEqual(bodyPreparations, 0)
        XCTAssertEqual(cache.retainedTextBytes, 0)
        XCTAssertEqual(cache.text(for: version, prepare: prepareBody), "first\nlast")
        XCTAssertEqual(bodyPreparations, 1)
        cache.releaseText()
        XCTAssertEqual(cache.retainedTextBytes, 0)
        XCTAssertEqual(cache.summary(for: version) { XCTFail("Summary should survive collapse"); return "" }, "10 B")
        XCTAssertEqual(cache.text(for: version, prepare: prepareBody), "first\nlast")
        XCTAssertEqual(bodyPreparations, 2)
    }

    func testOversizedExpandedTextAndPresentationAreReturnedWholeWithoutCaching() {
        let cache = ConversationBlockRenderCache(maximumBytes: 16)
        let version = version()
        let full = String(repeating: "complete content ", count: 1_000) + "tail"
        let expected = ConversationToolPresentation.make(
            name: "mcp__fixture", input: .object(["full": .string(full)])
        )
        var calls = 0
        for _ in 0..<2 {
            XCTAssertEqual(cache.text(for: version) { calls += 1; return full }, full)
            XCTAssertEqual(cache.presentation(for: version) { expected }, expected)
            XCTAssertEqual(cache.retainedTextBytes, 0)
        }
        XCTAssertEqual(calls, 2)
        guard case .code(let value) = expected.body else { return XCTFail("Expected complete JSON") }
        XCTAssertTrue(value.contains(full))
    }

    func testRawJSONIsPreparedOnlyWhenExpandedAndKeepsAllContent() {
        let cache = ConversationBlockRenderCache()
        let version = version()
        let raw: HistoryValue = .object(["type": .string("image"), "data": .string("complete payload")])
        var calls = 0
        let prepare = {
            calls += 1
            return Optional(raw.conversationPrettyJSON)
        }
        for _ in 0..<10 {
            XCTAssertNil(cache.text(for: version, whenExpanded: false, prepare: prepare))
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(cache.text(for: version, whenExpanded: true, prepare: prepare), raw.conversationPrettyJSON)
        XCTAssertEqual(cache.text(for: version, whenExpanded: true, prepare: prepare), raw.conversationPrettyJSON)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(cache.text(for: version, whenExpanded: false, prepare: prepare))
        XCTAssertEqual(cache.retainedTextBytes, 0)
        XCTAssertEqual(calls, 1)
    }

    func testZeroBudgetCachesAbsenceButDoesNotRetainTextOrEmptyTodoArrays() {
        let cache = ConversationBlockRenderCache(maximumBytes: 0)
        let version = version()
        var nilCalls = 0
        for _ in 0..<2 {
            XCTAssertNil(cache.text(for: version) { nilCalls += 1; return nil })
        }
        XCTAssertEqual(nilCalls, 1)
        XCTAssertEqual(cache.retainedTextBytes, 0)
        let todos = ConversationToolPresentation(
            symbol: "", label: "", target: "",
            body: .todos(Array(repeating: .init(text: "", status: ""), count: 1_000)), category: .todo
        )
        var todoCalls = 0
        for _ in 0..<2 {
            XCTAssertEqual(cache.presentation(for: version) { todoCalls += 1; return todos }, todos)
        }
        XCTAssertEqual(todoCalls, 2, "Even empty todo strings have array storage that must count toward the budget")
    }

    func testCacheDoesNotKeepAnObsoleteTranscriptAlive() {
        let cache = ConversationBlockRenderCache()
        weak var releasedProjection: ConversationStore.TranscriptProjection?
        do {
            let version = version()
            releasedProjection = version.projection
            _ = cache.text(for: version) { "cached text" }
        }
        XCTAssertNil(releasedProjection)
        XCTAssertEqual(cache.text(for: version()) { "new transcript" }, "new transcript")
    }

    private func version(projection: ConversationStore.TranscriptProjection = .init(),
                         message: Int = 0, block: Int = 0) -> ConversationBlockRenderVersion {
        .init(projection: projection, messageIndex: message, blockIndex: block)
    }
}
