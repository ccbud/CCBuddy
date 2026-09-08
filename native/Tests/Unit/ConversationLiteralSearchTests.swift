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

    func testGenericFoundationWindowsPreserveComplexCrossingMatches() {
        for offset in [16_378, 16_383, 16_384, 16_385, 32_767] {
            let prefix = String(repeating: "|", count: offset)
            for (body, queries) in [
                ("CAFÉ cafe\u{301} CAFÉ", ["café", "CAFE\u{301}"]),
                ("ᾲ ὰι ᾲ ὰι", ["ᾲ", "ὰι"]),
                ("한글 한글 한글", ["한글", "한글"]),
                ("\u{301}\u{300}X e\u{301}\u{300}X", ["\u{301}\u{300}X", "é\u{300}X"]),
                ("神 神 神 丽 一", ["神", "一"]),
                ("foo\0bar foo\0bar", ["foo\0bar"]),
                ("👩🏽‍💻 👩🏽‍💻", ["👩🏽‍💻"]),
                ("Straße/STRASSE ß/ss", ["straße/strasse", "ß/ss"]),
                ("\u{0600}aaa aa\u{200D}aa a\u{0338}a", ["\u{0600}a", "aa\u{200D}a", "a\u{0338}"])
            ] {
                for query in queries { assertParity(text: prefix + body, query: query) }
            }
        }
        // A pasted query can be larger than the scan window and must never be truncated.
        let query = String(repeating: "é!", count: 9_000)
        assertParity(text: String(repeating: "|", count: 16_383) + query + query, query: query)
    }

    func testDeterministicRandomizedUnicodeParityAcrossFoundationWindows() {
        var state: UInt64 = 0x5eed_cafe
        func next(_ upperBound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int(state >> 32) % upperBound
        }
        let pieces = ["a", "A", "é", "e\u{301}", "ß", "SS", "ﬃ", "ffi", "ᾲ", "ὰι", "神", "神",
                      "👩🏽‍💻", "\0", "\u{0600}a", "a\u{200D}a", "a\u{0338}", "İ", "i\u{307}", "Σ", "ς", " ", "!"]
        for _ in 0..<60 {
            let body = (0..<40).map { _ in pieces[next(pieces.count)] }.joined()
            let text = String(repeating: "|", count: 16_375 + next(20)) + body + body
            let query = (0..<(1 + next(3))).map { _ in pieces[next(pieces.count)] }.joined()
            assertParity(text: text, query: query)
        }
    }

    func testComplexAndHanAliasNoHitScansHandleConcurrentCancellation() async {
        let text = "神" + String(repeating: "payload without target ", count: 1_000_000)
        for query in ["café!", "系统代理"] {
            let (started, continuation) = AsyncStream<Void>.makeStream()
            let worker = Task.detached {
                continuation.yield(())
                continuation.finish()
                return ConversationLiteralSearch(query: query).firstMatch(in: text)
            }
            for await _ in started { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
            worker.cancel()
            let result = await worker.value
            XCTAssertNil(result)
        }
    }

    func testEveryCanonicalHanAliasMatchesFoundationForSingleAndMixedTwoCharacterQueries() {
        let aliases = canonicalHanAliases()
        XCTAssertGreaterThanOrEqual(aliases.count, 1_002)
        for (index, current) in aliases.enumerated() {
            assertParity(text: current.alias + " " + current.base + " " + current.alias,
                query: current.base)
            let next = aliases[(index + 1) % aliases.count]
            // Every alias participates in a two-character query with both plain
            // and compatibility forms at either position, including two aliases.
            let text = [current.base + next.base, current.base + next.alias,
                        current.alias + next.base, current.alias + next.alias].joined(separator: "|")
            assertParity(text: text, query: current.base + next.base)
        }
    }

    func testHanAliasesCrossUTF16ChunksWithoutLosingAnchorsOrNonoverlapCounts() {
        let supplementary = String(Unicode.Scalar(0x2f874)!) // canonical 当, two UTF-16 units
        let bmp = String(Unicode.Scalar(0xf9e4)!) // canonical 理, one UTF-16 unit
        for offset in [65_530, 65_533, 65_534, 65_535, 65_536, 65_537] {
            let prefix = String(repeating: "|", count: offset)
            let cases = [
                ("当前" + supplementary + "前当前" + supplementary + "前", "当前"),
                ("当" + supplementary + "当" + supplementary + "当", "当当"),
                ("系统代" + bmp + "系统代理系统代" + bmp, "系统代理"),
                (supplementary + bmp + "当理当" + bmp + supplementary + "理", "当理")
            ]
            for (body, query) in cases { assertParity(text: prefix + body, query: query) }
        }
    }

    func testHanAliasCandidatesRespectGraphemesAndRejectedOverlappingStarts() {
        for value in [0xf9e4, 0xfa19, 0x2f874, 0x2f800] {
            let alias = String(Unicode.Scalar(value)!)
            let base = alias.precomposedStringWithCanonicalMapping
            for suffix in ["\u{0301}", "\u{0338}", "\u{FE0F}", "\u{200D}", "\u{034F}"] {
                let text = alias + suffix + alias + " " + base + " " + alias
                assertParity(text: text, query: base)
                assertParity(text: text, query: base + base)
            }
            for prefix in ["\u{0600}", "\u{06DD}", "\u{110BD}"] {
                let text = prefix + alias + alias + alias + " " + base + alias
                assertParity(text: text, query: base)
                assertParity(text: text, query: base + base)
            }
        }
    }

    private func canonicalHanAliases() -> [(alias: String, base: String)] {
        (Array(0xf900...0xfaff) + Array(0x2f800...0x2fa1f)).compactMap { value in
            guard let scalar = Unicode.Scalar(value) else { return nil }
            let alias = String(scalar)
            let base = alias.precomposedStringWithCanonicalMapping
            guard base.unicodeScalars.count == 1,
                  base.unicodeScalars.first?.value != scalar.value else { return nil }
            return (alias, base)
        }
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
