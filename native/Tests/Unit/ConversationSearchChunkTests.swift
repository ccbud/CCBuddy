import Foundation
import SQLite3
import XCTest
@testable import CCBuddy

final class ConversationSearchChunkTests: XCTestCase {
    func testLZFSEAndRawCodecsRoundTripUnicodeAndRejectWrongLengths() throws {
        for text in ["", "x", "👩‍💻e\u{301}\0Straße", String(repeating: "可压缩 payload ", count: 10_000)] {
            let encoded = ConversationSearchCompression.encode(text)
            XCTAssertEqual(try ConversationSearchCompression.decode(encoded.bytes,
                codec: encoded.codec, decodedBytes: encoded.decodedBytes), text)
            XCTAssertThrowsError(try ConversationSearchCompression.decode(encoded.bytes,
                codec: encoded.codec, decodedBytes: encoded.decodedBytes + 1))
        }
        XCTAssertEqual(ConversationSearchCompression.encode(String(repeating: "a", count: 40_000)).codec, 1)
    }

    func testPhysicalPartsOwnEveryByteOnceAndPreserveGraphemeBoundaries() {
        let text = String(repeating: "x", count: ConversationSearchChunk.targetBytes - 1)
            + "👩‍💻e\u{301}\r\n" + String(repeating: "尾部", count: 40_000)
        let parts = ConversationSearchChunk.parts(of: text)
        XCTAssertEqual(parts.map(\.text).joined(), text)
        XCTAssertGreaterThan(parts.count, 2)
        var offset = 0
        for part in parts {
            XCTAssertLessThanOrEqual(part.text.utf8.count, ConversationSearchChunk.targetBytes)
            XCTAssertEqual(part.utf16Location, offset)
            offset += part.utf16Length
            let boundary = String.Index(utf16Offset: offset, in: text)
            XCTAssertTrue(boundary == text.endIndex || text.indices.contains(boundary))
        }
    }

    func testCandidatePrefixIsNormalizedBoundedAndScalarComplete() {
        let query = String(repeating: "a", count: 62) + "𠀀e\u{301}Straße"
        let prefix = ConversationSearchChunk.candidatePrefix(query)
        XCTAssertLessThanOrEqual(prefix.utf8.count, ConversationSearchChunk.candidatePrefixBytes)
        XCTAssertTrue(TgrepSearchIndex.normalized(query).hasPrefix(prefix))
        XCTAssertEqual(String(data: Data(prefix.utf8), encoding: .utf8), prefix)
        XCTAssertEqual(ConversationSearchChunk.candidatePrefix("Straße CAFE\u{301}"), "strasse café")
    }

    func testNewStorageHasNoWholeTranscriptColumnOrFTSAndCompressesBody() throws {
        let fixture = try makeFixture()
        let database = try ConversationIndexDatabase(file: fixture.file)
        let text = String(repeating: "repeated transcript payload ", count: 20_000)
        try database.replace(makeSession(root: fixture.root, text: text))
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM pragma_table_info('conversation_documents') WHERE name = 'search_text'", file: fixture.file), 0)
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'conversation_documents_fts%'", file: fixture.file), 0)
        XCTAssertEqual(try integer("SELECT COUNT(*) FROM pragma_table_info('conversation_catalog_state') WHERE name = 'fts_dirty'", file: fixture.file), 0)
        XCTAssertGreaterThan(try integer("SELECT COUNT(*) FROM conversation_search_chunks", file: fixture.file), 1)
        XCTAssertLessThan(try integer("SELECT SUM(length(body)) FROM conversation_search_chunks", file: fixture.file), Int64(text.utf8.count / 4))
        XCTAssertEqual(try database.documents(for: fixture.root.appendingPathComponent("source.jsonl")).first?.text, text)
    }

    func testPackagedTgrepCandidatesAndOwnedWindowsPreserveUnicodeAcrossBoundaries() throws {
        XCTAssertTrue(TgrepSearchIndex.isAvailable)
        let fixture = try makeFixture()
        let database = try ConversationIndexDatabase(file: fixture.file)
        let cases = [
            ("Straße", "STRASSE"), ("ΣΙΓΜΑ ς ΟΣ", "σιγμα σ"), ("ﬃxture", "ffi"),
            ("豈可搜索", "豈可搜索"), ("e\u{301}👩‍💻foo_bar/path", "É👩‍💻FOO_BAR/PATH"),
            ("Kelvin", "kelvin"), ("before\0after", "e\0a"),
        ]
        for (literal, query) in cases {
            for distance in [1, 2, 5, 63] {
                let text = String(repeating: "x", count: ConversationSearchChunk.targetBytes - distance)
                    + literal + String(repeating: " end", count: 100)
                let expected = try XCTUnwrap(text.range(of: query, options: .caseInsensitive), query)
                try database.replace(makeSession(root: fixture.root, text: text))
                let reference = try XCTUnwrap(database.candidateDocumentReferences(for: query).references.first,
                    "tgrep dropped a Foundation match for \(query)")
                XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
                var cursor: ConversationIndexSearchCursor?
                var starts: [Int] = []
                repeat {
                    let batch = try database.searchChunkWindows(reference: reference, query: query, cursor: cursor)
                    for window in batch.windows {
                        if let range = window.text.range(of: query, options: .caseInsensitive) {
                            let offset = range.lowerBound.utf16Offset(in: window.text)
                            if offset < window.ownedUTF16Length { starts.append(window.globalUTF16Start + offset) }
                        }
                    }
                    cursor = batch.nextCursor
                } while cursor != nil
                XCTAssertEqual(starts, [expected.lowerBound.utf16Offset(in: text)], "\(query) / \(distance)")
            }
        }
    }

    func testArbitrarilyLongQueryUsesBoundedSeedAndQuerySizedLookahead() throws {
        let fixture = try makeFixture()
        let database = try ConversationIndexDatabase(file: fixture.file)
        let query = "unique-start/" + String(repeating: "世界ab", count: 30_000) + "/unique-end"
        let text = String(repeating: "x", count: ConversationSearchChunk.targetBytes - 3) + query + " tail"
        try database.replace(makeSession(root: fixture.root, text: text))
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: query).references.first)
        let batch = try database.searchChunkWindows(reference: reference, query: query)
        let first = try XCTUnwrap(batch.windows.first)
        let match = try XCTUnwrap(first.text.range(of: query, options: .caseInsensitive))
        XCTAssertLessThan(match.lowerBound.utf16Offset(in: first.text), first.ownedUTF16Length)
        XCTAssertGreaterThan(first.text.utf8.count, ConversationSearchChunk.targetBytes * 5)
    }

    func testSnippetReadsPreviousBlockOnlyForActualHitAndPreservesOldWhitespaceRules() throws {
        let fixture = try makeFixture()
        let database = try ConversationIndexDatabase(file: fixture.file)
        let text = String(repeating: "ab \n", count: ConversationSearchChunk.targetBytes / 4)
            + "needle" + String(repeating: " 後\n", count: 100)
        try database.replace(makeSession(root: fixture.root, text: text))
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: "needle").references.first)
        let range = try XCTUnwrap(text.range(of: "needle"))
        let start = text.index(range.lowerBound, offsetBy: -56, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 56, limitedBy: text.endIndex) ?? text.endIndex
        let expected = "…" + text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + "…"
        XCTAssertEqual(try database.searchChunkSnippet(reference: reference,
            offsetUTF16: range.lowerBound.utf16Offset(in: text), matchLengthUTF16: 6), expected)
    }

    func testChunkCursorRejectsSemanticRevisionChange() throws {
        let fixture = try makeFixture()
        let database = try ConversationIndexDatabase(file: fixture.file, enableTgrep: false)
        try database.replace(makeSession(root: fixture.root, text: String(repeating: "candidate ", count: 10_000)))
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: "ca").references.first)
        let first = try database.searchChunkWindows(reference: reference, query: "ca")
        XCTAssertNotNil(first.nextCursor)
        try database.replace(makeSession(root: fixture.root, text: "replacement"))
        XCTAssertThrowsError(try database.searchChunkWindows(reference: reference, query: "ca", cursor: first.nextCursor)) {
            guard case ConversationIndexDatabaseError.staleRevision = $0 else { return XCTFail("\($0)") }
        }
    }

    private func makeFixture() throws -> (root: URL, file: URL) {
        let root = try HistoryTestSupport.temporaryDirectory("compressed-chunks")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("index.sqlite3"))
    }

    private func makeSession(root: URL, text: String) -> ConversationIndexedSession {
        let source = root.appendingPathComponent("source.jsonl")
        return ConversationIndexedSession(metadata: HistorySessionMetadata(id: "disk:chunks", file: source,
            source: .claude, dirID: "scope", dirLabel: "Scope", sessionID: "chunks", project: "Chunks",
            title: "Chunks", autoTitle: "Chunks", createdAt: .now, lastActivity: .now,
            sizeBytes: UInt64(text.utf8.count)), fingerprint: .init(modificationTime: .now,
                sizeBytes: UInt64(text.utf8.count)), documents: [.init(transcriptID: "main", sortOrder: 0,
                    text: text, messageSpans: [.init(sequence: 0, messageIndex: 0, utf16Location: 0,
                        utf16Length: text.utf16.count, role: "user")])])
    }

    private func integer(_ sql: String, file: URL) throws -> Int64 {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "chunk-test-open", code: 1)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "chunk-test-query", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "chunk-test-row", code: 3) }
        return sqlite3_column_int64(statement, 0)
    }
}
