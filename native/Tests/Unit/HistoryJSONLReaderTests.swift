import XCTest

@testable import CCBuddy

/// The reader walks the file in one-megabyte chunks instead of turning it into one enormous string,
/// so the seams between chunks are where it can go wrong: a record longer than a chunk, and a
/// multi-byte character split across one.
final class HistoryJSONLReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, name: String = "session.jsonl") throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    func testReadsOneRecordPerLine() throws {
        let file = try write("""
        {"type":"user","id":"a"}
        {"type":"assistant","id":"b"}

        """)

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertEqual(document.records.count, 2)
        XCTAssertEqual(document.records.first?["id"]?.stringValue, "a")
        XCTAssertEqual(document.diagnostics.decodedLines, 2)
        XCTAssertEqual(document.diagnostics.malformedLines, 0)
    }

    func testAFinalLineWithoutANewlineIsStillRead() throws {
        let file = try write(#"{"type":"user","id":"a"}"# + "\n" + #"{"type":"user","id":"tail"}"#)

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertEqual(document.records.count, 2)
        XCTAssertEqual(document.records.last?["id"]?.stringValue, "tail")
    }

    func testCarriageReturnsAndBlankLinesAreIgnored() throws {
        let file = try write("{\"id\":\"a\"}\r\n\r\n   \r\n{\"id\":\"b\"}\r\n")

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertEqual(document.records.compactMap { $0["id"]?.stringValue }, ["a", "b"])
        XCTAssertEqual(document.diagnostics.malformedLines, 0, "blank lines are not malformed")
    }

    func testMalformedLinesAreCountedAndSkipped() throws {
        let file = try write("""
        {"id":"a"}
        not json at all
        ["an","array","is","not","a","record"]
        {"id":"b"}

        """)

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertEqual(document.records.compactMap { $0["id"]?.stringValue }, ["a", "b"])
        XCTAssertEqual(document.diagnostics.malformedLines, 2)
    }

    func testARecordLargerThanOneChunkSurvives() throws {
        // Codex writes single records of tens of megabytes; the buffer has to hold a line that
        // spans many reads and still decode it exactly once.
        let padding = String(repeating: "x", count: 3 * 1_024 * 1_024)
        let file = try write("""
        {"id":"before"}
        {"id":"huge","text":"\(padding)"}
        {"id":"after"}

        """)

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertEqual(
            document.records.compactMap { $0["id"]?.stringValue },
            ["before", "huge", "after"]
        )
        XCTAssertEqual(document.records[1]["text"]?.stringValue?.count, padding.count)
    }

    func testMultiByteCharactersSplitAcrossChunksAreNotCorrupted() throws {
        // A chunk boundary lands in the middle of these characters' bytes; decoding whole lines
        // rather than whole chunks is what keeps them intact.
        let line = "{\"id\":\"cjk\",\"text\":\"" + String(repeating: "漢字🌱", count: 200_000) + "\"}"
        let file = try write("{\"id\":\"first\"}\n" + line + "\n")

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertEqual(document.records.count, 2)
        let text = try XCTUnwrap(document.records[1]["text"]?.stringValue)
        XCTAssertTrue(text.hasPrefix("漢字🌱"))
        XCTAssertTrue(text.hasSuffix("漢字🌱"))
        XCTAssertEqual(text.count, 200_000 * 3)
    }

    func testAnEmptyFileReadsAsAnEmptyDocument() throws {
        let file = try write("")

        let document = try HistoryJSONLDocument.read(from: file)

        XCTAssertTrue(document.records.isEmpty)
        XCTAssertEqual(document.diagnostics.malformedLines, 0)
    }

    func testAMissingFileReportsItRatherThanReturningNothing() {
        let missing = root.appendingPathComponent("absent.jsonl")

        XCTAssertThrowsError(try HistoryJSONLDocument.read(from: missing)) { error in
            guard case HistoryError.unreadableFile = error else {
                return XCTFail("expected an unreadable-file error, got \(error)")
            }
        }
    }

    func testParsingBytesDirectlyMatchesReadingTheFile() throws {
        let text = """
        {"id":"a","n":1}
        {"id":"b","n":2}

        """
        let file = try write(text)

        let fromFile = try HistoryJSONLDocument.read(from: file)
        let fromBytes = HistoryJSONLDocument.parse(data: Data(text.utf8))

        XCTAssertEqual(fromFile.records.count, fromBytes.records.count)
        XCTAssertEqual(
            fromFile.records.compactMap { $0["id"]?.stringValue },
            fromBytes.records.compactMap { $0["id"]?.stringValue }
        )
    }
}
