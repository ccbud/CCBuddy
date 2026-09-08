import XCTest
import SQLite3
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
        XCTAssertEqual(database.searchDiagnostics.fallbackReason, "unsafeCache")
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

    func testLowDiskFallbackRetriesAfterCooldownWithoutCatalogChange() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-disk-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 100)
        var capacity: Int64 = 0
        var attempts = 0
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"),
            tgrepRuntime: .init(now: { now }, availableCapacity: { _ in capacity }, makeIndex: {
                attempts += 1
                return try TgrepSearchIndex(cacheDirectory: $0)
            }))
        try database.replace(session(root: root, id: "low-space", text: "系统代理与搜索工具 Straße"))
        let generation = try database.generation()
        XCTAssertEqual(try database.candidateDocumentReferences(for: "系统代理").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        XCTAssertEqual(database.searchDiagnostics.fallbackReason, "lowDiskSpace")
        XCTAssertEqual(database.searchDiagnostics.tgrepRetryAfter, now.addingTimeInterval(30))
        capacity = .max
        XCTAssertEqual(try database.candidateDocumentReferences(for: "STRASSE").references.count, 1)
        XCTAssertEqual(attempts, 1, "Queries in the cooldown must not repeatedly start cold builds")
        now = now.addingTimeInterval(31)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "搜索工具").references.count, 1)
        XCTAssertEqual(try database.generation(), generation)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertNil(database.searchDiagnostics.fallbackReason)
        XCTAssertNil(database.searchDiagnostics.tgrepRetryAfter)
    }

    func testTransientIOFailureDoesNotDisableTheEnginePermanently() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-io-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 100)
        var attempts = 0
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"),
            tgrepRuntime: .init(now: { now }, availableCapacity: { _ in .max }, makeIndex: {
                attempts += 1
                if attempts == 1 { throw TgrepSearchIndex.Failure.ioFailure }
                return try TgrepSearchIndex(cacheDirectory: $0)
            }))
        try database.replace(session(root: root, id: "retry", text: "Straße recoverable phrase"))
        XCTAssertEqual(try database.candidateDocumentReferences(for: "STRASSE").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.fallbackReason, "ioFailure")
        XCTAssertEqual(try database.candidateDocumentReferences(for: "recoverable").references.count, 1)
        XCTAssertEqual(attempts, 1)
        now = now.addingTimeInterval(31)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "STRASSE").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertNil(database.searchDiagnostics.fallbackReason)
    }

    func testCancellationInsideTgrepReadTransactionRestoresTheReaderForNextQuery() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-transaction-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"),
            tgrepRuntime: .init(availableCapacity: { _ in .max }, makeIndex: {
                attempts += 1
                if attempts == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return try TgrepSearchIndex(cacheDirectory: $0)
            }))
        try database.replace(session(root: root, id: "transaction", text: "recoverable transaction phrase"))
        let worker = Task.detached { try database.candidateDocumentReferences(for: "transaction") }
        do {
            _ = try await worker.value
            XCTFail("Cancellation inside synchronization must abandon its read snapshot")
        } catch is CancellationError {}
        XCTAssertEqual(try database.candidateDocumentReferences(for: "transaction").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertNil(database.searchDiagnostics.fallbackReason)
    }

    func testMetadataOnlyRefreshDoesNotReindexTranscriptAcrossReopen() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-metadata-stamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.sqlite3")
        var database: ConversationIndexDatabase? = try ConversationIndexDatabase(file: file)
        var value = session(root: root, id: "metadata", text: "original searchable phrase")
        try database?.replace(value)
        _ = try database?.candidateDocumentReferences(for: "searchable")
        value.metadata.title = "A renamed and starred session"
        value.metadata.starred = true
        value.documents = []
        try database?.replaceMetadata([value])
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "searchable").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        database = nil
        database = try ConversationIndexDatabase(file: file)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "searchable").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        value.documents = [.init(transcriptID: "main", sortOrder: 0, text: "new replacement phrase")]
        try database?.replace(value)
        XCTAssertTrue(try XCTUnwrap(database?.candidateDocumentReferences(for: "searchable").references.isEmpty))
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "replacement").references.count, 1)
        database = nil
    }

    func testAdditiveContentStampMigrationKeepsWarmCheckpoint() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-stamp-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.sqlite3")
        var database: ConversationIndexDatabase? = try ConversationIndexDatabase(file: file)
        try database?.replace(session(root: root, id: "legacy", text: "retained migration phrase"))
        _ = try database?.candidateDocumentReferences(for: "migration")
        let generation = try database?.generation()
        database = nil
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw,
            "DROP TRIGGER conversation_documents_content_stamp; DROP TABLE conversation_content_stamps;",
            nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        database = try ConversationIndexDatabase(file: file)
        XCTAssertEqual(try database?.generation(), generation)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "migration").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        database = nil
    }

    func testLegacyWriterMetadataAndDocumentMutationsMaintainContentStamps() throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-legacy-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.sqlite3")
        let database = try ConversationIndexDatabase(file: file)
        try database.replace(session(root: root, id: "legacy", text: "original legacy phrase"))
        _ = try database.candidateDocumentReferences(for: "original")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        // Simulate an older v4 app, which has no knowledge of the new side table.
        XCTAssertEqual(sqlite3_exec(raw, """
            BEGIN IMMEDIATE;
            UPDATE conversation_sessions SET indexed_at = indexed_at + 1;
            UPDATE conversation_catalog_state SET generation = generation + 1;
            COMMIT;
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "original").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(sqlite3_exec(raw, """
            BEGIN IMMEDIATE;
            UPDATE conversation_sessions SET indexed_at = indexed_at + 1;
            DELETE FROM conversation_documents;
            INSERT INTO conversation_documents(session_path, transcript_id, sort_order, search_text, message_spans_json)
            SELECT source_path, 'main', 0, 'replacement legacy phrase', X'5B5D' FROM conversation_sessions;
            UPDATE conversation_catalog_state SET generation = generation + 1, fts_dirty = 1;
            COMMIT;
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try database.candidateDocumentReferences(for: "original").references.isEmpty)
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "replacement").references.count, 1)
    }

    func testCancelledLiteralScanReleasesReaderForNextCatalogOperation() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-literal-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"), enableTgrep: false)
        try database.replace(session(root: root, id: "large", text:
            String(repeating: "payload without target ", count: 1_000_000)))
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            continuation.yield(())
            continuation.finish()
            return try database.candidateDocumentReferences(for: "系统")
        }
        for await _ in started { break }
        try? await Task.sleep(nanoseconds: 5_000_000)
        worker.cancel()
        do {
            _ = try await worker.value
            XCTFail("A cancelled UDF scan must throw, not return a partial candidate set")
        } catch is CancellationError {}
        XCTAssertGreaterThan(try database.generation(), 0)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "pa").references.count, 1)
    }

    func testCancelledReadLockWaiterExitsBeforeTheCurrentSearchAndDiagnosticsStayReadable() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-lock-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "Search owns read lock")
        let waiterFinished = expectation(description: "Cancelled lock waiter exits promptly")
        let diagnosticsFinished = expectation(description: "Diagnostics never wait behind search")
        let release = ReadGate()
        defer { release.open() }
        let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"),
            tgrepRuntime: .init(availableCapacity: { _ in
                entered.fulfill()
                release.wait()
                return 0
            }))
        try database.replace(session(root: root, id: "locked", text: "searchable phrase"))
        let holder = Task.detached { try database.candidateDocumentReferences(for: "searchable") }
        await fulfillment(of: [entered], timeout: 2)
        let waiter = Task.detached {
            defer { waiterFinished.fulfill() }
            return try database.generation()
        }
        waiter.cancel()
        // A diagnostics read must not join the long search's read-lock queue.
        let diagnostics = Task.detached {
            _ = database.searchDiagnostics
            diagnosticsFinished.fulfill()
        }
        await fulfillment(of: [waiterFinished, diagnosticsFinished], timeout: 0.5)
        release.open()
        await diagnostics.value
        _ = try await holder.value
        do {
            _ = try await waiter.value
            XCTFail("The cancelled waiter must not perform its read")
        } catch is CancellationError {}
        XCTAssertGreaterThan(try database.generation(), 0)
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

    private final class ReadGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false

        func wait() {
            condition.lock()
            defer { condition.unlock() }
            while !isOpen { condition.wait() }
        }

        func open() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }
    }
}
