import XCTest
@testable import CCBuddy

final class TgrepSearchIndexTests: XCTestCase {
    func testPersistentCheckpointReopensWithoutReindexingAndStoresNoOriginalIdentity() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-persistent")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        let value = session(root: root, id: "private-session-sentinel", text: "persistent checkpoint search phrase")
        var database: ConversationFileCatalog? = try ConversationFileCatalog(file: file)
        try database?.replace(value)
        try await prepare(database)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        database = nil

        database = try ConversationFileCatalog(file: file)
        try await prepare(database)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        let cache = file.appendingPathComponent("tgrep-groups-v1")
        let active = try String(contentsOf: cache.appendingPathComponent("active"), encoding: .utf8)
        let manifest = try String(contentsOf: cache.appendingPathComponent(active)
            .appendingPathComponent("ccbuddy-manifest.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("private-session-sentinel"))
        XCTAssertFalse(manifest.contains(root.path))
        XCTAssertFalse(manifest.contains("search phrase"))
        database = nil
    }

    func testRecreatedCatalogWithSameGenerationRejectsOldCheckpointContentIdentity() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-recreated")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        var database: ConversationFileCatalog? = try ConversationFileCatalog(file: file)
        try database?.replace(session(root: root, id: "original", text: "previous obsolete phrase"))
        try await prepare(database)
        let oldGeneration = try database?.generation()
        let previous = try XCTUnwrap(database?.candidateDocumentReferences(for: "obsolete phrase").references.first)
        database = nil
        // Replace only a disposable fixture's catalog state. The postings checkpoint survives,
        // deliberately reusing generation/document/chunk numbers but not immutable content tokens.
        try FileManager.default.removeItem(at: file.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: file.appendingPathComponent("objects"))
        database = try ConversationFileCatalog(file: file)
        try database?.replace(session(root: root, id: "original", text: "current replacement phrase"))
        XCTAssertEqual(try database?.generation(), oldGeneration)
        try await prepare(database)
        XCTAssertTrue(try XCTUnwrap(database?.candidateDocumentReferences(for: "obsolete phrase").references.isEmpty))
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "replacement phrase").references.count, 1)
        XCTAssertThrowsError(try database?.refinementDocument(reference: previous, cachedGeneration: nil)) {
            guard case ConversationCatalogError.staleRevision = $0 else {
                return XCTFail("A recreated catalog must reject the preceding catalog's reference: \($0)")
            }
        }
        database = nil
    }

    func testDamagedCheckpointManifestSafelyRebuildsAllDocuments() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-corrupt-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        var database: ConversationFileCatalog? = try ConversationFileCatalog(file: file)
        try database?.replace(session(root: root, id: "retained", text: "intact original search phrase"))
        try await prepare(database)
        _ = try database?.candidateDocumentReferences(for: "search phrase")
        database = nil
        let cache = file.appendingPathComponent("tgrep-groups-v1")
        let active = try String(contentsOf: cache.appendingPathComponent("active"), encoding: .utf8)
        try Data("{partial".utf8).write(to: cache.appendingPathComponent(active).appendingPathComponent("ccbuddy-manifest.json"))
        database = try ConversationFileCatalog(file: file)
        try await prepare(database)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "search phrase").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, false)
        database = nil
    }

    func testSymlinkedCheckpointUsesExactFallbackWithoutWritingTarget() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
        try FileManager.default.createSymbolicLink(at: database.file.appendingPathComponent("tgrep-groups-v1"),
            withDestinationURL: target)
        let searchRepository = repository(database, root: root)
        defer { withExtendedLifetime(searchRepository) {} }
        try database.replace(session(root: root, id: "unicode", text: "Straße and 搜索"))
        try await prepare(database)
        XCTAssertEqual(try searchRepository.search(query: "STRASSE").count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        XCTAssertTrue(database.searchDiagnostics.usedFallback)
        XCTAssertEqual(database.searchDiagnostics.fallbackReason, "unsafeCache")
        XCTAssertEqual(try searchRepository.search(query: "搜索").count, 1)
        XCTAssertTrue(try searchRepository.search(query: "absent").isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testCJKByteTrigramsAccelerateOneAndTwoCharacterQueries() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-short-cjk")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
        try database.replace(session(root: root, id: "chinese", text: "搜索工具和代码，設定を変更"))
        try database.replace(session(root: root, id: "unrelated", text: "unrelated document"))
        try await prepare(database)
        for query in ["搜索", "工具", "代", "設定"] {
            XCTAssertEqual(try database.candidateDocumentReferences(for: query).references.count, 1)
            XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
            XCTAssertFalse(database.searchDiagnostics.usedFallback)
        }
        XCTAssertFalse(TgrepSearchIndex.canIndex("a"))
        XCTAssertFalse(TgrepSearchIndex.canIndex("ab"))
        XCTAssertTrue(TgrepSearchIndex.canIndex("搜"))
    }

    func testPackagedTgrepIsAvailableAndMatchesFoundationUnicodeSemantics() async throws {
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

    func testWarmQueriesReadNoTranscriptsAndReplacementOnlyIndexesChangedDocument() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-incremental")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
        var first = session(root: root, id: "first", text: "old deployment phrase")
        let second = session(root: root, id: "second", text: "other deployment phrase")
        try database.replace(first)
        try database.replace(second)
        try await prepare(database)

        XCTAssertEqual(try database.candidateDocumentReferences(for: "deployment phrase").references.count, 2)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 2)
        let preparedDiagnostics = database.searchDiagnostics
        _ = try database.candidateDocumentReferences(for: "deployment phrase")
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 2,
            "This metric describes the last background preparation, not foreground work")
        XCTAssertEqual(database.searchDiagnostics.cumulativeNormalizationMilliseconds,
            preparedDiagnostics.cumulativeNormalizationMilliseconds)
        XCTAssertEqual(database.searchDiagnostics.cumulativeTrigramBuildMilliseconds,
            preparedDiagnostics.cumulativeTrigramBuildMilliseconds)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.metadata.file.path),
            "Warm search must use local packs, not reopen unavailable producer transcripts")

        first.documents[0].text = "new replacement phrase"
        first.fingerprint.sizeBytes += 1
        try database.replace(first)
        try await prepare(database)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "replacement phrase").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertTrue(try database.candidateDocumentReferences(for: "old deployment").references.isEmpty)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "other deployment").references.count, 1)

        _ = try database.reconcile(scope: "test", seenPaths: [first.metadata.file.path], allowEmpty: false)
        try await prepare(database)
        XCTAssertTrue(try database.candidateDocumentReferences(for: "other deployment").references.isEmpty)
        XCTAssertEqual(database.searchDiagnostics.indexedDocuments, 1)
    }

    func testScopeTrashAndSubagentIdentityRemainAuthoritativeAfterCandidateGeneration() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
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
        try await prepare(database)

        let scoped = try database.candidateDocumentReferences(for: "shared target", scope: "test")
        XCTAssertEqual(scoped.references.map(\.transcriptID), ["agent-1"])
        XCTAssertEqual(scoped.references.first?.agentType, "Explore")
        XCTAssertEqual(try database.candidateDocumentReferences(for: "shared target", deleted: true)
            .references.map(\.sessionPath), [deleted.metadata.file.path])
        XCTAssertEqual(try database.candidateDocumentReferences(for: "shared target", deleted: nil)
            .references.count, 3)
    }

    func testLiteralFallbackMatchesNonASCIICaseAndEmbeddedNUL() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(
            file: root.appendingPathComponent("catalog"), enableTgrep: false
        )
        let searchRepository = repository(database, root: root)
        defer { withExtendedLifetime(searchRepository) {} }
        try database.replace(session(root: root, id: "unicode", text: "É СО hello\0World"))
        for query in ["é", "со", "o\0w"] {
            let result = try database.candidateDocumentReferences(for: query)
            XCTAssertEqual(result.references.count, 1, query)
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        }
        XCTAssertTrue(try searchRepository.search(query: "absent word").isEmpty)
    }

    func testBroadCandidateResultExceedingABatchDoesNotLoseDocuments() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-broad")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
        var value = session(root: root, id: "many", text: "unused")
        value.documents = (0..<825).map {
            .init(transcriptID: "agent-\($0)", sortOrder: $0, text: "common phrase \($0)")
        }
        try database.replace(value)
        try await prepare(database)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "common phrase").references.count, 825)
        XCTAssertEqual(database.searchDiagnostics.candidateCount, 825)
    }

    func testRemovedDocumentIDsAreNeverReusedAndOldReferenceCannotMisattributeAnotherTranscript() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-reused-id")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
        let original = session(root: root, id: "original", text: "shared phrase original")
        try database.replace(original)
        try await prepare(database)
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: "shared phrase").references.first)
        _ = try database.reconcile(scope: "test", seenPaths: [], allowEmpty: true)
        try database.replace(session(root: root, id: "replacement", text: "shared phrase unrelated"))
        try await prepare(database)
        let replacement = try XCTUnwrap(database.candidateDocumentReferences(for: "shared phrase").references.first)
        XCTAssertGreaterThan(replacement.documentID, reference.documentID)
        XCTAssertNil(try database.document(id: reference.documentID))
        XCTAssertNil(try database.document(
            id: reference.documentID, expectedSessionPath: reference.sessionPath,
            expectedTranscriptID: reference.transcriptID
        ))
        XCTAssertThrowsError(try database.refinementDocument(reference: reference, cachedGeneration: nil)) {
            guard case ConversationCatalogError.staleRevision = $0 else {
                return XCTFail("Old reference must be rejected: \($0)")
            }
        }
    }

    func testCancelledSearchDoesNotDisableTheNextSearch() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"))
        try database.replace(session(root: root, id: "cancel", text: "recoverable search phrase"))
        try await prepare(database)
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

    func testLowDiskFallbackRetriesAfterCooldownWithoutCatalogChange() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-disk-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 100)
        var capacity: Int64 = 0
        var attempts = 0
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"),
            tgrepRuntime: .init(now: { now }, availableCapacity: { _ in capacity }, makeIndex: {
                attempts += 1
                return try TgrepSearchIndex(cacheDirectory: $0)
            }))
        let searchRepository = repository(database, root: root)
        defer { withExtendedLifetime(searchRepository) {} }
        try database.replace(session(root: root, id: "low-space", text: "系统代理与搜索工具 Straße"))
        let generation = try database.generation()
        try await prepare(database)
        XCTAssertEqual(try searchRepository.search(query: "系统代理").count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        XCTAssertEqual(database.searchDiagnostics.fallbackReason, "lowDiskSpace")
        XCTAssertEqual(database.searchDiagnostics.tgrepRetryAfter, now.addingTimeInterval(30))
        capacity = .max
        try await prepare(database)
        XCTAssertEqual(try searchRepository.search(query: "STRASSE").count, 1)
        XCTAssertEqual(attempts, 1, "Cooldown must not repeat failed background preparation")
        now = now.addingTimeInterval(31)
        try await prepare(database)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "搜索工具").references.count, 1)
        XCTAssertEqual(try database.generation(), generation)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertNil(database.searchDiagnostics.fallbackReason)
        XCTAssertNil(database.searchDiagnostics.tgrepRetryAfter)
    }

    func testTransientIOFailureDoesNotDisableTheEnginePermanently() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-io-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 100)
        var attempts = 0
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"),
            tgrepRuntime: .init(now: { now }, availableCapacity: { _ in .max }, makeIndex: {
                attempts += 1
                if attempts == 1 { throw TgrepSearchIndex.Failure.ioFailure }
                return try TgrepSearchIndex(cacheDirectory: $0)
            }))
        let searchRepository = repository(database, root: root)
        defer { withExtendedLifetime(searchRepository) {} }
        try database.replace(session(root: root, id: "retry", text: "Straße recoverable phrase"))
        try await prepare(database)
        XCTAssertEqual(try searchRepository.search(query: "STRASSE").count, 1)
        XCTAssertEqual(database.searchDiagnostics.fallbackReason, "ioFailure")
        try await prepare(database)
        XCTAssertEqual(try searchRepository.search(query: "recoverable").count, 1)
        XCTAssertEqual(attempts, 1)
        now = now.addingTimeInterval(31)
        try await prepare(database)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "STRASSE").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(database.searchDiagnostics.fallbackReason)
    }

    func testVerifiedCheckpointCanReopenAtLowCapacityWithoutRebuilding() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-warm-low-capacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        var database: ConversationFileCatalog? = try ConversationFileCatalog(file: file)
        try database?.replace(session(root: root, id: "warm", text: "searchable retained checkpoint"))
        try await prepare(database)
        let generation = try database?.generation()
        database = nil
        database = try ConversationFileCatalog(file: file,
            tgrepRuntime: .init(availableCapacity: { _ in 0 }))
        try await prepare(database)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "retained checkpoint").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.engine, "tgrep")
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        XCTAssertNil(database?.searchDiagnostics.fallbackReason)
        XCTAssertEqual(try database?.generation(), generation)
        database = nil
    }

    func testCancelledBackgroundPreparationReleasesPublisherAndNextPreparationRecovers() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-transaction-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"),
            tgrepRuntime: .init(availableCapacity: { _ in .max }, makeIndex: {
                attempts += 1
                if attempts == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return try TgrepSearchIndex(cacheDirectory: $0)
            }))
        let searchRepository = repository(database, root: root)
        defer { withExtendedLifetime(searchRepository) {} }
        try database.replace(session(root: root, id: "transaction", text: "recoverable transaction phrase"))
        try await prepare(database)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try searchRepository.search(query: "transaction").count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "Literal")
        XCTAssertNil(database.searchDiagnostics.tgrepRetryAfter,
            "Cancellation is not an engine failure and cannot install a retry cooldown")
        try await prepare(database)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "transaction").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
        XCTAssertNil(database.searchDiagnostics.fallbackReason)
    }

    func testMetadataOnlyRefreshDoesNotReindexTranscriptAcrossReopen() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-metadata-stamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        var attempts = 0
        let runtime = ConversationFileCatalog.TgrepRuntime(availableCapacity: { _ in .max }, makeIndex: {
            attempts += 1
            return try TgrepSearchIndex(cacheDirectory: $0)
        })
        var database: ConversationFileCatalog? = try ConversationFileCatalog(file: file, tgrepRuntime: runtime)
        var value = session(root: root, id: "metadata", text: "original searchable phrase")
        try database?.replace(value)
        try await prepare(database)
        XCTAssertEqual(attempts, 1)
        _ = try database?.candidateDocumentReferences(for: "searchable")
        value.metadata.title = "A renamed and starred session"
        value.metadata.starred = true
        value.documents = []
        try database?.replaceMetadata([value])
        try await prepare(database)
        XCTAssertEqual(attempts, 1,
            "A metadata-only revision must reuse its prepared reader without reopening the checkpoint")
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "searchable").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        database = nil
        database = try ConversationFileCatalog(file: file, tgrepRuntime: runtime)
        try await prepare(database)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "searchable").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        value.documents = [.init(transcriptID: "main", sortOrder: 0, text: "new replacement phrase")]
        try database?.replace(value)
        try await prepare(database)
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(try XCTUnwrap(database?.candidateDocumentReferences(for: "searchable").references.isEmpty))
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "replacement").references.count, 1)
        database = nil
    }

    func testFutureCatalogFormatIsRejectedWithoutChangingSearchCheckpointOrRecords() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-stamp-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        var database: ConversationFileCatalog? = try ConversationFileCatalog(file: file)
        try database?.replace(session(root: root, id: "legacy", text: "retained migration phrase"))
        try await prepare(database)
        _ = try database?.candidateDocumentReferences(for: "migration")
        let generation = try database?.generation()
        database = nil
        let manifestFile = file.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: manifestFile)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
        manifest["version"] = ConversationFileCatalog.formatVersion + 1
        let futureManifest = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try futureManifest.write(to: manifestFile, options: [.atomic])
        let before = try fileContents(in: file)
        XCTAssertThrowsError(try ConversationFileCatalog(file: file)) {
            guard case ConversationFileCatalog.Failure.unsupportedVersion = $0 else {
                return XCTFail("Future format should fail explicitly: \($0)")
            }
        }
        XCTAssertEqual(try fileContents(in: file), before,
            "Refusing a future format must not reset its data or the tgrep checkpoint")
        // Restore this test fixture's valid manifest and prove its warm postings remain useful.
        try originalManifest.write(to: manifestFile, options: [.atomic])
        database = try ConversationFileCatalog(file: file)
        try await prepare(database)
        XCTAssertEqual(try database?.generation(), generation)
        XCTAssertEqual(try database?.candidateDocumentReferences(for: "migration").references.count, 1)
        XCTAssertEqual(database?.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(database?.searchDiagnostics.restoredFromCache, true)
        database = nil
    }

    func testIndependentCatalogWriterPreservesMetadataOnlyStampAndInvalidatesReplacedContent() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-legacy-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog")
        let database = try ConversationFileCatalog(file: file)
        var value = session(root: root, id: "legacy", text: "original legacy phrase")
        let searchRepository = repository(database, root: root)
        defer { withExtendedLifetime(searchRepository) {} }
        try database.replace(value)
        try await prepare(database)
        _ = try database.candidateDocumentReferences(for: "original")
        let original = try XCTUnwrap(database.candidateDocumentReferences(for: "original").references.first)
        let writer = try ConversationFileCatalog(file: file, enableTgrep: false)
        value.metadata.title = "Changed by another catalog instance"
        value.metadata.starred = true
        value.documents = []
        try writer.replaceMetadata([value])
        try await prepare(database)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "original").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 0)
        XCTAssertEqual(try database.entry(for: value.metadata.file)?.metadata.title, value.metadata.title)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "original").references.first?.documentID,
            original.documentID, "Metadata-only publication retains the immutable content identity")
        value.documents = [.init(transcriptID: "main", sortOrder: 0, text: "replacement legacy phrase")]
        try writer.replace(value)
        // The old prepared index cannot exclude content published by another instance.
        XCTAssertEqual(try searchRepository.search(query: "replacement").count, 1)
        XCTAssertTrue(try searchRepository.search(query: "original").isEmpty)
        try await prepare(database)
        XCTAssertTrue(try database.candidateDocumentReferences(for: "original").references.isEmpty)
        XCTAssertEqual(database.searchDiagnostics.incrementallyIndexedDocuments, 1)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "replacement").references.count, 1)
    }

    func testCancelledChunkScanReleasesReaderForNextCatalogOperation() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-literal-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"), enableTgrep: false)
        try database.replace(session(root: root, id: "large", text:
            String(repeating: "payload without target ", count: 10_000)))
        let reference = try XCTUnwrap(database.candidateDocumentReferences(for: "zz").references.first)
        let worker = Task.detached {
            let first = try database.searchChunkWindows(reference: reference, query: "zz")
            withUnsafeCurrentTask { $0?.cancel() }
            return try database.searchChunkWindows(reference: reference, query: "zz", cursor: first.nextCursor)
        }
        do {
            _ = try await worker.value
            XCTFail("A cancelled block scan must throw, not return a partial page")
        } catch is CancellationError {}
        XCTAssertGreaterThan(try database.generation(), 0)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "pa").references.count, 1)
    }

    func testCancelledCatalogReadAndDiagnosticsStayResponsiveWhileBackgroundPreparationIsBlocked() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("tgrep-lock-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "Background preparation is blocked")
        let waiterFinished = expectation(description: "Cancelled catalog read exits promptly")
        let diagnosticsFinished = expectation(description: "Diagnostics never wait behind search")
        let release = ReadGate()
        defer { release.open() }
        let database = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"),
            tgrepRuntime: .init(availableCapacity: { _ in .max }, makeIndex: { directory in
                entered.fulfill()
                release.wait()
                return try TgrepSearchIndex(cacheDirectory: directory)
            }))
        try database.replace(session(root: root, id: "locked", text: "searchable phrase"))
        database.scheduleSearchIndexPreparation()
        await fulfillment(of: [entered], timeout: 2)
        let waiter = Task.detached {
            defer { waiterFinished.fulfill() }
            withUnsafeCurrentTask { $0?.cancel() }
            return try database.generation()
        }
        // Diagnostics must not join the expensive builder's queue. Catalog reads are also
        // independent, and cancellation is honored before returning a snapshot.
        let diagnostics = Task.detached {
            _ = database.searchDiagnostics
            diagnosticsFinished.fulfill()
        }
        await fulfillment(of: [waiterFinished, diagnosticsFinished], timeout: 0.5)
        release.open()
        await diagnostics.value
        await database.waitForSearchIndexPreparation()
        do {
            _ = try await waiter.value
            XCTFail("The cancelled waiter must not perform its read")
        } catch is CancellationError {}
        XCTAssertGreaterThan(try database.generation(), 0)
        XCTAssertEqual(try database.candidateDocumentReferences(for: "searchable").references.count, 1)
        XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
    }

    private func prepare(_ database: ConversationFileCatalog?) async throws {
        let catalog = try XCTUnwrap(database)
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
    }

    private func repository(_ database: ConversationFileCatalog, root: URL) -> IndexedHistoryRepository {
        IndexedHistoryRepository(configuration: .init(historyDirs: ["test"], homeDirectory: root,
            importsRoot: root.appendingPathComponent("imports")), database: database)
    }

    private func fileContents(in directory: URL) throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(directory.path.count))] = try Data(contentsOf: file)
            }
        }
        return result
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
