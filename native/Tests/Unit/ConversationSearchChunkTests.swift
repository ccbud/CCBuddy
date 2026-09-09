import Foundation
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

    func testFileStorageHasNoDatabaseOrWholeTranscriptJSONAndCompressesBody() throws {
        let fixture = try makeFixture()
        let database = try ConversationFileCatalog(file: fixture.file)
        let text = String(repeating: "repeated transcript payload ", count: 20_000)
        try database.replace(makeSession(root: fixture.root, text: text))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.type]
            as? FileAttributeType, .typeDirectory)
        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.file.appendingPathComponent("objects"), includingPropertiesForKeys: [.fileSizeKey])
        let header = try XCTUnwrap(files.first { $0.pathExtension == "header" })
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: header)) as? [String: Any])
        let documents = try XCTUnwrap(record["documents"] as? [[String: Any]])
        let document = try XCTUnwrap(documents.first)
        XCTAssertNil(document["text"], "Metadata must not duplicate a whole transcript")
        XCTAssertGreaterThan(try XCTUnwrap(document["chunks"] as? [Any]).count, 1)
        let packs = files.filter { $0.pathExtension == "pack" }
        XCTAssertEqual(packs.count, 1)
        let storedBytes = try packs.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThan(storedBytes, text.utf8.count / 4)
        XCTAssertEqual(try database.documents(for: fixture.root.appendingPathComponent("source.jsonl")).first?.text, text)
    }

    func testPackagedTgrepCandidatesAndOwnedWindowsPreserveUnicodeAcrossBoundaries() async throws {
        XCTAssertTrue(TgrepSearchIndex.isAvailable)
        let fixture = try makeFixture()
        let database = try ConversationFileCatalog(file: fixture.file)
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
                database.scheduleSearchIndexPreparation()
                await database.waitForSearchIndexPreparation()
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
        let database = try ConversationFileCatalog(file: fixture.file)
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
        let database = try ConversationFileCatalog(file: fixture.file)
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
        let database = try ConversationFileCatalog(file: fixture.file, enableTgrep: false)
        try database.replace(makeSession(root: fixture.root, text: String(repeating: "candidate ", count: 10_000)))
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: "ca").references.first)
        let first = try database.searchChunkWindows(reference: reference, query: "ca")
        XCTAssertNotNil(first.nextCursor)
        try database.replace(makeSession(root: fixture.root, text: "replacement"))
        XCTAssertThrowsError(try database.searchChunkWindows(reference: reference, query: "ca", cursor: first.nextCursor)) {
            guard case ConversationCatalogError.staleRevision = $0 else { return XCTFail("\($0)") }
        }
    }

    private func makeFixture() throws -> (root: URL, file: URL) {
        let root = try HistoryTestSupport.temporaryDirectory("compressed-chunks")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("catalog-v1", isDirectory: true))
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

}
