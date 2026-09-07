import Foundation
import XCTest
@testable import CCBuddy

final class ConversationLiteralSearchTests: XCTestCase {
    func testFastCandidatesPreserveFoundationUnicodeAndGraphemeSemantics() {
        let samples = [
            "ERROR error Error errors error\u{0301} error\u{0338} error",
            "Straße STRASSE Straßeß SS ss ſs ﬀ ffi ﬃ ﬁ ﬅ ﬆ K K k",
            "搜索 搜索\u{FE0F} 搜索\u{0301} 搜索\u{0338} 搜索",
            "神 神 神\u{FE0F} 丽 一 工具 代码",
            "é e\u{0301} É E\u{0301} İ I i ı ᾲ ὰι",
            "foo\u{0000}bar foo\r\nbar foo bar foo\u{200D}bar",
            "aaaa\u{0338}aaa aaa aaaaa ababa\u{0301}baba",
            "emoji 👩🏽‍💻 Swift Swift\u{034F} swift 🏳️‍🌈 search",
            "error error\u{200D} error s\u{200D}s| \u{0600}aa\u{0600}aa \u{0600}aaa",
        ]
        let queries = ["error", "ss", "strasse", "ffi", "fi", "ff", "st", "k", "i", "搜索", "神", "工具", "代码",
                       "é", "e\u{0301}", "ὰι", "foo bar", "foo\u{0000}bar", "aa", "aaa", "aba", "Swift", "👩🏽‍💻", ""]
        for sample in samples {
            for query in queries { assertParity(text: sample, query: query) }
        }
    }

    func testASCIIFastPathMatchesFoundationAcrossUnicodeCaseFoldCharacters() {
        var text = ""
        for value in Array(0..<0x3000) + Array(0xfb00..<0xfb50) + Array(0x10400..<0x10450) {
            guard let scalar = UnicodeScalar(value) else { continue }
            text.unicodeScalars.append(scalar)
            text.append("|")
        }
        for query in Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init) + ["ss", "ff", "ffi", "fi", "st", "SS", "FFI"] {
            assertParity(text: text, query: query)
        }
    }

    func testDenseLongTranscriptKeepsEveryNonoverlappingOccurrence() {
        let text = String(repeating: "Swift 搜索 e\u{0301} error\u{0338} SS Straße\n", count: 10_000)
        for query in ["Swift", "搜索", "error", "ss", "e\u{0301}"] {
            let result = ConversationLiteralSearch(query: query).match(in: text)
            let expected = query == "error" ? 0 : (query == "ss" ? 20_000 : 10_000)
            XCTAssertEqual(result?.count ?? 0, expected, query)
        }
    }

    func testFastCandidatesRespectCombiningMarkBoundaries() {
        var text = ""
        for base in ["s", "ſ", "ß", "ﬃ", "K", "a", "神"] {
            for value in Array(0x0300...0x036f) + Array(0xfe00...0xfe0f) + [0x200d] {
                guard let scalar = UnicodeScalar(value) else { continue }
                text += base + String(scalar) + base + "|"
            }
        }
        for query in ["s", "ss", "ff", "ffi", "k", "a", "aa", "神"] {
            assertParity(text: text, query: query)
        }
    }

    func testRejectedOverlappingCandidatesDoNotHideValidMatches() {
        for scalar in [0x0600, 0x0601, 0x0605, 0x06dd, 0x070f, 0x0890, 0x08e2, 0x110bd, 0x111c2] {
            let prepend = String(UnicodeScalar(scalar)!)
            for body in ["aaa", "aaaaa", "ababab", "ssss", "神神神"] {
                for query in ["a", "aa", "aaa", "ab", "s", "ss", "神", "神神"] {
                    assertParity(text: prepend + body + " " + body, query: query)
                }
            }
        }
    }

    func testPrecancelledMatcherDoesNotReturnAResult() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ConversationLiteralSearch(query: "error").match(in: "error error")
        }
        let result = await worker.value
        XCTAssertNil(result)
    }

    func testChunkBoundariesKeepCrossingMatchesAndNonoverlapCounts() {
        for offset in [65_530, 65_535, 65_536, 65_537] {
            for body in ["Swift Swift", "ſs ss", "神神神神", "𠀀𠀀𠀀", "a\u{200D}aaa", "\u{0600}aaaa"] {
                let text = String(repeating: "|", count: offset) + body
                for query in ["Swift", "ss", "神神", "𠀀𠀀", "aa"] {
                    assertParity(text: text, query: query)
                }
            }
        }
        let text = String(repeating: "a", count: 140_000)
        for length in [3, 257, 65_535, 65_537] {
            XCTAssertEqual(ConversationLiteralSearch(query: String(repeating: "a", count: length))
                .match(in: text)?.count, text.count / length)
        }
    }

    func testNoHitScanHandlesConcurrentCancellation() async {
        let text = String(repeating: "payload without target ", count: 1_000_000)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            continuation.yield(())
            continuation.finish()
            return ConversationLiteralSearch(query: "missing").match(in: text)
        }
        for await _ in started { break }
        worker.cancel()
        let result = await worker.value
        XCTAssertNil(result)
    }

    func testCancellationDuringDenseScanDoesNotReturnPartialCounts() async {
        let text = String(repeating: "error 搜索 ", count: 1_000_000)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            continuation.yield(())
            continuation.finish()
            return ConversationLiteralSearch(query: "error").match(in: text)
        }
        for await _ in started { break }
        try? await Task.sleep(nanoseconds: 5_000_000)
        worker.cancel()
        let result = await worker.value
        XCTAssertNil(result, "A cancelled scan must not publish the count of only its visited prefix")
    }

    private func assertParity(text: String, query: String, file: StaticString = #filePath, line: UInt = #line) {
        var ranges: [Range<String.Index>] = []
        if !query.isEmpty {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(of: query, options: .caseInsensitive, range: cursor..<text.endIndex) {
                ranges.append(range)
                cursor = range.upperBound
            }
        }
        let matcher = ConversationLiteralSearch(query: query)
        let actual = matcher.match(in: text)
        XCTAssertEqual(actual?.range, ranges.first, "first range for \(query.debugDescription)", file: file, line: line)
        XCTAssertEqual(actual?.count ?? 0, ranges.count, "count for \(query.debugDescription)", file: file, line: line)
        XCTAssertEqual(matcher.firstMatch(in: text), ranges.first, "first-only range for \(query.debugDescription)", file: file, line: line)
    }
}
