import XCTest
@testable import CCBuddy

final class TgrepSearchIndexTests: XCTestCase {
    func testPersistentCheckpointReopensWithoutReindexingAndStoresNoOriginalIdentity() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-persistent")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.sqlite3")
        let value = session(root: root, id: "private-session-sentinel", text: "persistent checkpoint search phrase")
        var database: ConversationIndexDatabase? = try ConversationIndexDatabase(file: file)
        try database?.replace(value)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        database = nil

        database = try ConversationIndexDatabase(file: file)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        let cache = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".tgrep-v2")
        let active = try String(contentsOf: cache.appendingPathComponent("active"), encoding: .utf8)
        let manifest = try String(contentsOf: cache.appendingPathComponent(active)
            .appendingPathComponent("ccbuddy-manifest.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("private-session-sentinel"))
        XCTAssertFalse(manifest.contains(root.path))
        XCTAssertFalse(manifest.contains("search phrase"))
        database = nil
    }

    func testRecreatedSQLiteWithSameGenerationReconcilesCheckpointIdentities() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-recreated")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.sqlite3")
        var database: ConversationIndexDatabase? = try ConversationIndexDatabase(file: file)
        try database?.replace(session(root: root, id: "original", text: "previous obsolete phrase"))
        let oldGeneration = try database?.generation()
        _ = try database?.candidateDocumentReferences(for: "obsolete phrase")
        database = nil
        // The database closes and checkpoints its WAL before this simulated
        // catalog replacement. The sibling tgrep checkpoint deliberately stays.
        try FileManager.default.removeItem(at: file)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        database = try ConversationIndexDatabase(file: file)
        try database?.replace(session(root: root, id: "replacement", text: "current replacement phrase"))
        XCTAssertEqual(try database?.generation(), oldGeneration)
        XCTAssertTrue(try XCTUnwrap(database?.candidateDocumentReferences(for: "obsolete phrase").references.isEmpty))
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "replacement phrase").references.count, 1)
        database = nil
    }

    func testDamagedCheckpointManifestSafelyRebuildsAllDocuments() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-corrupt-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.sqlite3")
        var database: ConversationIndexDatabase? = try ConversationIndexDatabase(file: file)
        try database?.replace(session(root: root, id: "retained", text: "intact original search phrase"))
        _ = try database?.candidateDocumentReferences(for: "search phrase")
        database = nil
        let cache = root.appendingPathComponent("index.sqlite3.tgrep-v2")
        let active = try String(contentsOf: cache.appendingPathComponent("active"), encoding: .utf8)
        try Data("{partial".utf8).write(to: cache.appendingPathComponent(active).appendingPathComponent("ccbuddy-manifest.json"))
        database = try ConversationIndexDatabase(file: file)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, false)
        database = nil
    }

    func testSymlinkedCheckpointUsesExactFallbackWithoutWritingTarget() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("index.sqlite3.tgrep-v2"),
            withDestinationURL: target)
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        try database.replace(session(root: root, id: "unicode", text: "Straße and 搜索"))
        XCTAssertEqual(try database.candidateDocumentReferences(for: "STRASSE").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        XCTAssertTrue(database.searchDiagnostics.usedFallback)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "搜索").references.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testCJKByteTrigramsAccelerateOneAndTwoCharacterQueries() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-short-cjk")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        try database.replace(session(root: root, id: "chinese", text: "搜索工具和代码，設定を変更"))
        try database.replace(session(root: root, id: "unrelated", text: "unrelated document"))
        for query in ["搜索", "工具", "代", "設定"] {
            XCTAssertEqual(try database.candidateDocumentReferences(for: query).references.count, 1)
            XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
            XCTAssertFalse(database.searchDiagnostics.usedFallback)
        }
        XCTAssertFalse(TgrepSearchIndex.canIndex("a"))
        XCTAssertFalse(TgrepSearchIndex.canIndex("ab"))
        XCTAssertTrue(TgrepSearchIndex.canIndex("搜"))
    }

    func testPackagedTgrepIsAvailableAndMatchesFoundationUnicodeSemantics() throws {
        XCTAssertTrue(TgrepSearchIndex.isAvailable, "The shipping app must embed its pinned tgrep library")
        let engine = try TgrepSearchIndex()
        let texts = [
            "a Straße STRASSE street", "CAFÉ and cafe\u{301}", "ПРИВЕТ мир",
            "二维码搜索和苹果芯片", "x useEffect( value) foo bar", "before\0after",
            "İSTANBUL ıstanbul", "ΣΙΓΜΑ ς ΟΣ", "Kelvin ﬃxture", "a\u{301}bc",
        ]
        var stamps: [Int64: TgrepSearchIndex.Stamp] = [:]
        for (index, text) in texts.enumerated() {
            try engine.upsert(id: Int64(index), text: text)
            stamps[Int64(index)] = .init(path: "\(index)", transcript: "main", indexedAt: 1)
        }
        try engine.commit(revision: 1, stamps: stamps)
        for query in [
            "strasse", "straße", "café", "CAFE\u{301}", "привет", "二维码", "useeffect(", "foo bar", "e\0a",
            "istanbul", "i\u{307}stanbul", "ıstanbul", "σιγμα σ", "οσ", "kelvin", "ffi", "\u{301}bc",
        ] {
            let expected = Set(texts.indices.filter {
                texts[$0].range(of: query, options: [.caseInsensitive]) != nil
            }.map(Int64.init))
            let candidates = Set(try engine.candidates(for: query))
            XCTAssertTrue(expected.isSubset(of: candidates), "tgrep must never drop an exact Foundation hit: \(query)")
            let verified = Set(candidates.filter {
                texts[Int($0)].range(of: query, options: [.caseInsensitive]) != nil
            })
            XCTAssertEqual(verified, expected)
        }
    }

    func testWarmQueriesReadNoTranscriptsAndReplacementOnlyIndexesChangedDocument() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-incremental")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        var first = session(root: root, id: "first", text: "old deployment phrase")
        let second = session(root: root, id: "second", text: "other deployment phrase")
        try database.replace(first)
        try database.replace(second)

        XCTAssertEqual(try database.candidateDocumentReferences(for: "deployment phrase").references.count, 2)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 2)
        _ = try database.candidateDocumentReferences(for: "deployment phrase")
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 0)

        first.documents[0].text = "new replacement phrase"
        first.fingerprint.sizeBytes += 1
        try database.replace(first)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "replacement phrase").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertTrue(try database.candidateDocumentReferences(for: "old deployment").references.isEmpty)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "other deployment").references.count, 1)

        try database.reconcile(scope: "test", seenPaths: [first.metadata.file.path], allowEmpty: false)
        XCTAssertTrue(try database.candidateDocumentReferences(for: "other deployment").references.isEmpty)
        XCTAssertEqual(database.searchDiagnostics.indexedDocuments, 1)
    }

    func testScopeTrashAndSubagentIdentityRemainAuthoritativeAfterCandidateGeneration() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        var live = session(root: root, id: "live", text: "main contents")
        live.documents.append(.init(
            transcriptID: "agent-1", agentType: "Explore", sortOrder: 1,
            text: "shared target in child"
        ))
        var deleted = session(root: root, id: "trash", text: "shared target in trash")
        deleted.metadata.deleted = true
        var foreign = session(root: root, id: "foreign", text: "shared target in foreign scope")
        foreign.scope = "foreign"
        try database.replace(live)
        try database.replace(deleted)
        try database.replace(foreign)

        let scoped = try database.candidateDocumentReferences(for: "shared target", scope: "test")
        XCTAssertEqual(scoped.references.map(\.transcriptID), ["agent-1"])
        XCTAssertEqual(scoped.references.first?.agentType, "Explore")
        XCTAssertEqual(try database.candidateDocumentReferences(for: "shared target", deleted: true)
            .references.map(\.sessionPath), [deleted.metadata.file.path])
        XCTAssertEqual(try database.candidateDocumentReferences(for: "shared target", deleted: nil)
            .references.count, 3)
    }

    func testLiteralFallbackMatchesNonASCIICaseAndEmbeddedNUL() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(
            file: root.appendingPathComponent("index.sqlite3"), enableTgrep: false
        )
        try database.replace(session(root: root, id: "unicode", text: "É СО hello\0World"))
        for query in ["é", "со", "o\0w"] {
            let result = try database.candidateDocumentReferences(for: query)
            XCTAssertEqual(result.references.count, 1, query)
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        }
        XCTAssertTrue(try database.candidateDocumentReferences(for: "absent word").references.isEmpty)
    }

    func testBroadCandidateResultExceedingABatchDoesNotLoseDocuments() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-broad")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        var value = session(root: root, id: "many", text: "unused")
        value.documents = (0..<825).map {
            .init(transcriptID: "agent-\($0)", sortOrder: $0, text: "common phrase \($0)")
        }
        try database.replace(value)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "common phrase").references.count, 825)
        XCTAssertEqual(database.searchDiagnostics.candidateCount, 825)
    }

    func testRowIDReusedBetweenCandidateAndDetailCannotMisattributeAnotherTranscript() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-reused-id")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        let original = session(root: root, id: "original", text: "shared phrase original")
        try database.replace(original)
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: "shared phrase").references.first)
        try database.reconcile(scope: "test", seenPaths: [], allowEmpty: true)
        try database.replace(session(root: root, id: "replacement", text: "shared phrase unrelated"))
        XCTAssertNotNil(try database.document(id: reference.documentID), "Exercise SQLite's actual row-ID reuse")
        XCTAssertNil(try database.document(
            id: reference.documentID, expectedSessionPath: reference.sessionPath,
            expectedTranscriptID: reference.transcriptID
        ))
    }

    func testCancelledSearchDoesNotDisableTheNextSearch() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"))
        try database.replace(session(root: root, id: "cancel", text: "recoverable search phrase"))
        let task = Task.detached {
            // Mark this task cancelled before entering the synchronous catalog
            // without blocking a cooperative executor or racing a sleep.
            withUnsafeCurrentTask { $0?.cancel() }
            return try database.candidateDocumentReferences(for: "search phrase")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work should not build the index")
        } catch is CancellationError {
            // The next independent query must still use the packaged engine.
        }
        XCTAssertEqual(try database.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
    }

    private func session(root: URL, id: String, text: String) -> ConversationIndexedSession {
        ConversationIndexedSession(
            metadata: HistorySessionMetadata(
                id: id, file: root.appendingPathComponent("\(id).jsonl"), source: .claude,
                dirID: "test", dirLabel: "Test", sessionID: id, project: "Test",
                title: id, autoTitle: id, createdAt: .now, lastActivity: .now, sizeBytes: UInt64(text.utf8.count)
            ),
            fingerprint: .init(modificationTime: .now, sizeBytes: UInt64(text.utf8.count)),
            documents: [.init(transcriptID: "main", sortOrder: 0, text: text)]
        )
    }
}
