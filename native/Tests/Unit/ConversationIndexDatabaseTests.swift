import SQLite3
import XCTest
@testable import CCBuddy

final class ConversationIndexDatabaseTests: XCTestCase {
    func testMetadataDocumentsAndFingerprintRoundTripAcrossReopen() throws {
        let fixture = try Fixture()
        let metadata = makeMetadata(file: fixture.source, id: "qoder-full", source: .qoder)
        let fingerprint = ConversationIndexFingerprint(
            modificationTime: Date(timeIntervalSince1970: 1_800_000_111.25),
            sizeBytes: 4_096,
            dependencyFingerprint: "sha256:dependencies"
        )
        let document = makeDocument(
            transcriptID: "tool-child",
            type: "Explore",
            order: 1,
            text: "请实现二维码搜索"
        )

        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        XCTAssertEqual(try database?.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: fingerprint,
            documents: [document]
        )), 1)
        XCTAssertEqual(try database?.loadAllMetadata(), [metadata])
        XCTAssertEqual(try database?.documents(for: fixture.source), [document])
        XCTAssertEqual(
            try database?.storedFingerprints(),
            [ConversationIndexDatabase.normalizedPath(fixture.source): fingerprint]
        )
        database = nil

        let reopened = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertEqual(try reopened.loadAllMetadata(), [metadata])
        XCTAssertEqual(try reopened.documents(for: fixture.source), [document])
        XCTAssertEqual(try reopened.generation(), 1)
        XCTAssertTrue(try reopened.hasRows())

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.database.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testUserMetadataOverridesProducerProjectionAndSurvivesIndexReplacement() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        var producer = makeMetadata(file: fixture.source, id: "owned-overlay")
        producer.title = "Producer title"
        producer.tags = ["producer"]
        _ = try database.replace(ConversationIndexedSession(
            metadata: producer,
            fingerprint: .init(modificationTime: .now, sizeBytes: 10),
            documents: [makeDocument(text: "searchable overlay")]
        ))

        _ = try database.updateUserMetadata(
            for: fixture.source,
            patch: .init(
                title: "  User title  ",
                tags: [" local ", "local", "two"],
                deleted: true,
                starred: true,
                pinned: true
            )
        )
        var projected = try XCTUnwrap(database.entry(for: fixture.source))
        XCTAssertEqual(projected.metadata.title, "User title")
        XCTAssertEqual(projected.metadata.tags, ["local", "two"])
        XCTAssertTrue(projected.metadata.deleted)
        XCTAssertTrue(projected.metadata.starred)
        XCTAssertTrue(projected.metadata.pinned)
        XCTAssertEqual(projected.userMetadata.title, "User title")
        XCTAssertEqual(try database.listEntries(deleted: false, limit: .max), [])
        XCTAssertEqual(
            try database.listEntries(deleted: true, starred: true, limit: .max)
                .map(\.sourcePath),
            [ConversationIndexDatabase.normalizedPath(fixture.source)]
        )
        XCTAssertTrue(try database.candidateDocuments(for: "searchable").documents.isEmpty)
        XCTAssertEqual(
            try database.candidateDocuments(for: "searchable", deleted: true)
                .documents.count,
            1
        )

        producer.title = "Producer changed"
        producer.tags = ["new producer tag"]
        _ = try database.replace(ConversationIndexedSession(
            metadata: producer,
            fingerprint: .init(modificationTime: .now, sizeBytes: 11),
            documents: [makeDocument(text: "replacement")]
        ))
        projected = try XCTUnwrap(database.entry(for: fixture.source))
        XCTAssertEqual(projected.metadata.title, "User title")
        XCTAssertEqual(projected.metadata.tags, ["local", "two"])
        XCTAssertTrue(projected.metadata.deleted)
        XCTAssertTrue(projected.metadata.starred)
        XCTAssertTrue(projected.metadata.pinned)

        _ = try database.remove(paths: [fixture.source.path])
        _ = try database.replace(ConversationIndexedSession(
            metadata: producer,
            fingerprint: .init(modificationTime: .now, sizeBytes: 12),
            documents: []
        ))
        projected = try XCTUnwrap(database.entry(for: fixture.source))
        XCTAssertEqual(projected.metadata.title, "User title")
        XCTAssertTrue(projected.metadata.pinned, "rebuildable rows must not own user metadata")
    }

    func testPinnedRowsSortFirstAndStarFilterUsesAppOwnedState() throws {
        let fixture = try Fixture()
        let newerFile = fixture.directory.appendingPathComponent("newer.jsonl")
        let pinnedFile = fixture.directory.appendingPathComponent("older-pinned.jsonl")
        let database = try ConversationIndexDatabase(file: fixture.database)
        var newer = makeMetadata(file: newerFile, id: "newer")
        newer.lastActivity = Date(timeIntervalSince1970: 300)
        var pinned = makeMetadata(file: pinnedFile, id: "pinned")
        pinned.lastActivity = Date(timeIntervalSince1970: 100)
        _ = try database.replace(ConversationIndexedSession(
            metadata: newer,
            fingerprint: .init(modificationTime: .now, sizeBytes: 1),
            documents: []
        ))
        _ = try database.replace(ConversationIndexedSession(
            metadata: pinned,
            fingerprint: .init(modificationTime: .now, sizeBytes: 1),
            documents: []
        ))
        _ = try database.updateUserMetadata(
            for: pinnedFile,
            patch: .init(starred: true, pinned: true)
        )

        XCTAssertEqual(
            try database.listEntries(deleted: false, limit: .max).map(\.metadata.sessionID),
            ["pinned", "newer"]
        )
        XCTAssertEqual(
            try database.listEntries(deleted: false, starred: true, limit: .max)
                .map(\.metadata.sessionID),
            ["pinned"]
        )
    }

    func testHistoryMetadataDecodesPreStarAndPinCatalogJSON() throws {
        let fixture = try Fixture()
        let metadata = makeMetadata(file: fixture.source, id: "legacy-json")
        let encoded = try JSONEncoder().encode(metadata)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "starred")
        object.removeValue(forKey: "pinned")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(HistorySessionMetadata.self, from: legacy)
        XCTAssertFalse(decoded.starred)
        XCTAssertFalse(decoded.pinned)
        XCTAssertEqual(decoded.id, metadata.id)
    }

    func testRepeatedOpenReadReleaseAndReopenClosesBothConnectionsCleanly() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "lifecycle", scope: "scope"))

        for _ in 0..<16 {
            XCTAssertEqual(
                try database?.listEntries(scope: "scope", deleted: nil, limit: 1)
                    .map(\.metadata.id),
                ["disk:lifecycle"]
            )
            database = nil
            database = try ConversationIndexDatabase(file: fixture.database)
            XCTAssertEqual(try database?.generation(), 1)
        }
        database = nil

        XCTAssertEqual(
            try ConversationIndexDatabase(file: fixture.database)
                .listEntries(scope: "scope", deleted: nil, limit: 1)
                .map(\.metadata.id),
            ["disk:lifecycle"]
        )
    }

    func testTrigramAndShortQueryFallbackReturnMainAndSubagentCandidates() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        let main = makeDocument(
            transcriptID: "main",
            type: nil,
            order: 0,
            text: "请实现二维码搜索，并保留 useEffect( 代码。"
        )
        let child = makeDocument(
            transcriptID: "agent-1",
            type: "Explore",
            order: 1,
            text: "子代理也找到了二维码。"
        )
        _ = try database.replace(ConversationIndexedSession(
            metadata: makeMetadata(file: fixture.source, id: "search"),
            fingerprint: .init(modificationTime: .now, sizeBytes: 100),
            documents: [child, main]
        ))

        let chinese = try database.candidateDocuments(for: "二维码")
        XCTAssertFalse(chinese.usedFallback)
        XCTAssertEqual(chinese.documents.map(\.document.transcriptID), ["main", "agent-1"])
        XCTAssertEqual(chinese.documents.last?.document.messageSpans.first?.messageIndex, 0)

        let code = try database.candidateDocuments(for: "useEffect(")
        XCTAssertFalse(code.usedFallback)
        XCTAssertEqual(code.documents.map(\.document.transcriptID), ["main"])

        let short = try database.candidateDocuments(for: "实现")
        XCTAssertTrue(short.usedFallback)
        XCTAssertEqual(short.documents.map(\.document.transcriptID), ["main"])
    }

    func testReplacementIsAtomicAndRemovesStaleSearchRows() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        let metadata = makeMetadata(file: fixture.source, id: "replace")
        _ = try database.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: 1),
            documents: [makeDocument(text: "obsolete phrase")]
        ))

        let invalid = ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: 2),
            documents: [makeDocument(text: "new phrase"), makeDocument(text: "duplicate")]
        )
        XCTAssertThrowsError(try database.replace(invalid))
        XCTAssertEqual(try database.candidateDocuments(for: "obsolete").documents.count, 1)
        XCTAssertEqual(try database.generation(), 1)

        _ = try database.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: 3),
            documents: [makeDocument(text: "replacement phrase")]
        ))
        XCTAssertTrue(try database.candidateDocuments(for: "obsolete").documents.isEmpty)
        XCTAssertEqual(try database.candidateDocuments(for: "replacement").documents.count, 1)
        XCTAssertEqual(try database.generation(), 2)
    }

    func testCorruptMetadataRowDoesNotHideValidRows() throws {
        let fixture = try Fixture()
        let corruptFile = fixture.directory.appendingPathComponent("zz-corrupt.jsonl")
        let validFile = fixture.directory.appendingPathComponent("aa-valid.jsonl")
        let database = try ConversationIndexDatabase(file: fixture.database)
        _ = try database.replace(indexed(file: corruptFile, id: "corrupt", scope: "bad"))
        _ = try database.replace(indexed(file: validFile, id: "valid", scope: "good"))

        var rawHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                fixture.database.path,
                &rawHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let raw = try XCTUnwrap(rawHandle)
        defer { sqlite3_close(raw) }
        try executeRaw(
            "UPDATE conversation_sessions SET metadata_json = X'FF' WHERE scope = 'bad'",
            database: raw
        )

        XCTAssertEqual(
            try database.listEntries(deleted: nil, limit: .max).map(\.metadata.id),
            ["disk:valid"]
        )
        XCTAssertEqual(
            try database.listEntries(deleted: nil, limit: 1).map(\.metadata.id),
            ["disk:valid"],
            "The SQL row limit must be backfilled after a corrupt newest row is skipped"
        )
        XCTAssertNil(try database.entry(for: corruptFile))
        XCTAssertEqual(try database.entry(for: validFile)?.metadata.id, "disk:valid")
    }

    func testCorruptLatestMetadataRowDoesNotConsumeSearchCandidateLimit() throws {
        let fixture = try Fixture()
        let corruptFile = fixture.directory.appendingPathComponent("zz-corrupt-search.jsonl")
        let validFile = fixture.directory.appendingPathComponent("aa-valid-search.jsonl")
        let database = try ConversationIndexDatabase(file: fixture.database)
        var corrupt = indexed(
            file: corruptFile,
            id: "needle corrupt",
            scope: "bad-search"
        )
        corrupt.metadata.lastActivity = Date(timeIntervalSince1970: 1_800_000_300)
        var valid = indexed(
            file: validFile,
            id: "needle valid",
            scope: "good-search"
        )
        valid.metadata.lastActivity = Date(timeIntervalSince1970: 1_800_000_200)
        _ = try database.replace(corrupt)
        _ = try database.replace(valid)

        var rawHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                fixture.database.path,
                &rawHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let raw = try XCTUnwrap(rawHandle)
        defer { sqlite3_close(raw) }
        try executeRaw(
            "UPDATE conversation_sessions SET metadata_json = X'FF' "
                + "WHERE scope = 'bad-search'",
            database: raw
        )

        let candidates = try database.candidateDocuments(for: "needle", limit: 1)
        XCTAssertEqual(
            candidates.documents.map(\.entry.metadata.id),
            ["disk:needle valid"],
            "The candidate limit must be backfilled after a corrupt newest row is skipped"
        )
    }

    func testReadConnectionStaysResponsiveWhileWriterWaitsOnCompetingTransaction() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        _ = try database.replace(indexed(file: fixture.source, id: "baseline", scope: "scope"))

        var blockerHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                fixture.database.path,
                &blockerHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let blocker = try XCTUnwrap(blockerHandle)
        defer { sqlite3_close(blocker) }
        try executeRaw("BEGIN IMMEDIATE", database: blocker)
        var blockerReleased = false
        defer {
            if !blockerReleased { try? executeRaw("ROLLBACK", database: blocker) }
        }

        let writerResult = DatabaseMaintenanceResultProbe()
        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchGroup()
        let replacement = indexed(
            file: fixture.source,
            id: "replacement",
            scope: "scope"
        )
        writerFinished.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            writerStarted.signal()
            writerResult.run {
                _ = try database.replace(replacement)
            }
            writerFinished.leave()
        }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            writerFinished.wait(timeout: .now() + 0.15),
            .timedOut,
            "The catalog writer should be waiting on the competing transaction"
        )

        let readerResult = DatabaseEntryReadProbe()
        let readerFinished = DispatchGroup()
        readerFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            readerResult.load {
                try database.listEntries(scope: "scope", deleted: nil, limit: .max)
            }
            readerFinished.leave()
        }
        XCTAssertEqual(
            readerFinished.wait(timeout: .now() + 0.5),
            .success,
            "A read-only WAL snapshot should not wait for the catalog writer lock"
        )
        XCTAssertNil(readerResult.error)
        XCTAssertEqual(readerResult.entries?.map(\.metadata.id), ["disk:baseline"])

        try executeRaw("ROLLBACK", database: blocker)
        blockerReleased = true
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 3), .success)
        XCTAssertNil(writerResult.error)
        XCTAssertEqual(try database.entry(for: fixture.source)?.metadata.id, "disk:replacement")
    }

    func testReconciliationIsScopedAndRejectsAccidentalEmptyDiscovery() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        let first = fixture.directory.appendingPathComponent("first.jsonl")
        let second = fixture.directory.appendingPathComponent("second.jsonl")
        _ = try database.replace(indexed(file: first, id: "first", scope: "one"))
        _ = try database.replace(indexed(file: second, id: "second", scope: "two"))

        XCTAssertThrowsError(try database.reconcile(scope: "one", seenPaths: [])) { error in
            guard case ConversationIndexDatabaseError.unsafeEmptyReconciliation("one") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let result = try database.reconcile(scope: "one", seenPaths: [], allowEmpty: true)
        XCTAssertEqual(result.removedPaths, [ConversationIndexDatabase.normalizedPath(first)])
        XCTAssertEqual(try database.loadAllMetadata().map(\.id), ["disk:second"])
        XCTAssertEqual(try database.scopeSummaries().map(\.scope), ["two"])
    }

    func testSchemaVersionMismatchRebuildsDerivedRows() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "old", scope: "scope"))
        database = nil

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let rebuilt = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertFalse(try rebuilt.hasRows())
        XCTAssertEqual(try rebuilt.generation(), 0)
    }

    func testProjectionInvalidationAdvancesOnlyGeneration() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        _ = try database.replace(indexed(file: fixture.source, id: "projection", scope: "scope"))
        try database.finishFullScanMaintenance()
        let entry = try XCTUnwrap(database.entry(for: fixture.source))
        let documents = try database.documents(for: fixture.source)

        XCTAssertEqual(try database.invalidateProjection(), 2)
        XCTAssertEqual(try database.generation(), 2)
        XCTAssertEqual(try database.entry(for: fixture.source), entry)
        XCTAssertEqual(try database.documents(for: fixture.source), documents)
        XCTAssertEqual(
            try database.candidateDocuments(for: "projection").documents.map(\.entry),
            [entry]
        )
    }

    func testFullScanMaintenanceIsGenerationNeutralAndNoOpsWhenUnchanged() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        _ = try database.replace(indexed(file: fixture.source, id: "maintenance", scope: "scope"))
        let generation = try database.generation()
        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")

        try database.finishFullScanMaintenance()
        XCTAssertEqual(try database.generation(), generation)
        XCTAssertEqual(try database.candidateDocuments(for: "maintenance").documents.count, 1)
        let firstWALSize = try fileSize(wal)
        XCTAssertEqual(firstWALSize, 0)

        try database.finishFullScanMaintenance()
        XCTAssertEqual(try database.generation(), generation)
        XCTAssertEqual(try fileSize(wal), firstWALSize)
    }

    func testVersionOneMigrationKeepsWarmRowsWithoutAutomaticFullCompaction() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        let legacyText = String(repeating: "legacy transcript payload ", count: 80_000)
        _ = try database?.replace(ConversationIndexedSession(
            metadata: makeMetadata(file: fixture.source, id: "legacy"),
            scope: "scope",
            fingerprint: .init(modificationTime: .now, sizeBytes: UInt64(legacyText.utf8.count)),
            documents: [makeDocument(text: legacyText)]
        ))
        try database?.finishFullScanMaintenance()
        let legacyEntry = try XCTUnwrap(database?.entry(for: fixture.source))
        let legacyDocuments = try XCTUnwrap(database?.documents(for: fixture.source))
        let legacyGeneration = try XCTUnwrap(database?.generation())
        database = nil

        try prepareVersionOneCatalog(fixture.database, discardedBytes: 8 * 1_024 * 1_024)
        let legacySize = try fileSize(fixture.database)
        XCTAssertGreaterThan(legacySize, 8 * 1_024 * 1_024)

        let migrated = try ConversationIndexDatabase(file: fixture.database)
        let warmSize = try fileSize(fixture.database)
        XCTAssertTrue(try migrated.hasRows())
        XCTAssertEqual(try migrated.generation(), legacyGeneration)
        XCTAssertEqual(try migrated.entry(for: fixture.source), legacyEntry)
        XCTAssertEqual(try migrated.documents(for: fixture.source), legacyDocuments)
        XCTAssertEqual(try migrated.candidateDocuments(for: "legacy").documents.count, 1)
        XCTAssertEqual(try userVersion(fixture.database), ConversationIndexDatabase.schemaVersion)
        XCTAssertEqual(try catalogStateValue("one_time_compaction_pending", fixture.database), 1)
        XCTAssertGreaterThanOrEqual(warmSize + 4_096, legacySize)

        try migrated.finishFullScanMaintenance()
        XCTAssertEqual(try migrated.generation(), legacyGeneration)
        XCTAssertEqual(try migrated.entry(for: fixture.source), legacyEntry)
        XCTAssertEqual(try migrated.documents(for: fixture.source), legacyDocuments)
        XCTAssertEqual(try catalogStateValue("one_time_compaction_pending", fixture.database), 0)
        XCTAssertEqual(try catalogStateValue("maintenance_pending", fixture.database), 0)
        XCTAssertGreaterThanOrEqual(
            try fileSize(fixture.database) + 4_096,
            warmSize,
            "Deferred maintenance must not run a full VACUUM of the legacy catalog"
        )
    }

    func testVersionTwoMigrationKeepsWarmRowsAndInstallsDurableUserTable() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "v2-warm", scope: "scope"))
        let generation = try XCTUnwrap(database?.generation())
        database = nil
        try prepareVersionTwoCatalog(fixture.database)

        let migrated = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertEqual(try userVersion(fixture.database), ConversationIndexDatabase.schemaVersion)
        XCTAssertEqual(try migrated.generation(), generation)
        XCTAssertEqual(try migrated.entry(for: fixture.source)?.metadata.sessionID, "v2-warm")
        _ = try migrated.updateUserMetadata(
            for: fixture.source,
            patch: .init(title: "Migrated", starred: true, pinned: true)
        )
        let projected = try XCTUnwrap(migrated.entry(for: fixture.source)?.metadata)
        XCTAssertEqual(projected.title, "Migrated")
        XCTAssertTrue(projected.starred)
        XCTAssertTrue(projected.pinned)
    }

    func testDeferredFTSMaintenanceCanBeCancelledWhileWaitingForAnotherWriter() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "warm", scope: "scope"))
        try database?.finishFullScanMaintenance()
        database = nil
        try prepareVersionOneCatalog(fixture.database)

        let migrated = try ConversationIndexDatabase(file: fixture.database)
        var blockerHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                fixture.database.path,
                &blockerHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let blocker = try XCTUnwrap(blockerHandle)
        defer { sqlite3_close(blocker) }
        try executeRaw(
            "UPDATE conversation_catalog_state SET fts_dirty = 1 WHERE singleton = 1",
            database: blocker
        )
        try executeRaw("BEGIN IMMEDIATE", database: blocker)
        var blockerCommitted = false
        defer {
            if !blockerCommitted { try? executeRaw("ROLLBACK", database: blocker) }
        }

        let cancellation = DatabaseCancellationProbe()
        let result = DatabaseMaintenanceResultProbe()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        // XCTest runs this synchronous test at user-interactive QoS. Match that QoS so the
        // intentional bounded wait below does not become a Thread Performance Checker issue.
        DispatchQueue.global(qos: .userInteractive).async {
            started.signal()
            result.run {
                try migrated.finishFullScanMaintenance(
                    isCancelled: { @Sendable in cancellation.isCancelled() }
                )
            }
            finished.leave()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            finished.wait(timeout: .now() + 0.15),
            .timedOut,
            "Deferred maintenance should be waiting on the competing writer"
        )

        let readerResult = DatabaseEntryReadProbe()
        let readerFinished = DispatchGroup()
        readerFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            readerResult.load {
                try migrated.listEntries(scope: "scope", deleted: nil, limit: 1)
            }
            readerFinished.leave()
        }
        XCTAssertEqual(
            readerFinished.wait(timeout: .now() + 0.5),
            .success,
            "Deferred maintenance must not block warm-catalog reads"
        )
        XCTAssertNil(readerResult.error)
        XCTAssertEqual(readerResult.entries?.map(\.metadata.id), ["disk:warm"])

        let cancellationStarted = DispatchTime.now().uptimeNanoseconds
        cancellation.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        let cancellationLatency = Double(
            DispatchTime.now().uptimeNanoseconds - cancellationStarted
        ) / 1_000_000_000
        XCTAssertLessThan(cancellationLatency, 0.5)
        XCTAssertTrue(result.error is CancellationError, String(describing: result.error))
        XCTAssertEqual(try catalogStateValue("one_time_compaction_pending", fixture.database), 1)
        XCTAssertEqual(try catalogStateValue("maintenance_pending", fixture.database), 1)
        XCTAssertTrue(try migrated.hasRows())

        try executeRaw("ROLLBACK", database: blocker)
        blockerCommitted = true
        try migrated.finishFullScanMaintenance()
        XCTAssertEqual(try catalogStateValue("one_time_compaction_pending", fixture.database), 0)
    }

    func testDirtyFTSFallbackSearchInterruptsPromptlyBeforeMaterializingStaleResults() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        _ = try database.replace(ConversationIndexedSession(
            metadata: makeMetadata(file: fixture.source, id: "cancel-search"),
            fingerprint: .init(modificationTime: .now, sizeBytes: 1),
            documents: [makeDocument(text: "seed")]
        ))
        try inflateSearchDocument(
            fixture.database,
            bytes: 32 * 1_024 * 1_024
        )

        let cancellation = SearchCancellationProbe(signalAfterPollCount: 6)
        let result = DatabaseMaintenanceResultProbe()
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            result.run {
                _ = try database.candidateDocuments(
                    for: "absent-search-value",
                    isCancelled: { @Sendable in cancellation.isCancelled() }
                )
            }
            finished.leave()
        }
        XCTAssertTrue(
            cancellation.waitUntilObserved(timeout: 1),
            "The query must install its progress/interrupt cancellation path before stepping"
        )

        let cancellationStarted = DispatchTime.now().uptimeNanoseconds
        cancellation.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        let cancellationLatency = Double(
            DispatchTime.now().uptimeNanoseconds - cancellationStarted
        ) / 1_000_000_000
        XCTAssertLessThan(cancellationLatency, 0.5)
        XCTAssertTrue(result.error is CancellationError, String(describing: result.error))
    }

    func testConcurrentOpensSerializeVersionOneMigrationWithoutDroppingRows() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "old", scope: "scope"))
        database = nil

        try prepareVersionOneCatalog(fixture.database)

        let probe = ConcurrentDatabaseOpenProbe()
        let databaseFile = fixture.database
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            probe.open(databaseFile)
        }

        XCTAssertTrue(probe.errors.isEmpty, probe.errors.joined(separator: "\n"))
        XCTAssertEqual(probe.generations, Array(repeating: 1, count: 8))
        XCTAssertEqual(try userVersion(fixture.database), ConversationIndexDatabase.schemaVersion)
        XCTAssertTrue(try ConversationIndexDatabase(file: fixture.database).hasRows())
    }

    func testVersionAndColumnChecksWaitForCrossConnectionMigrationTransaction() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "old", scope: "scope"))
        database = nil
        try prepareVersionOneCatalog(fixture.database)

        // This raw connection stands in for a second process. Process-local locks cannot
        // coordinate with it; only BEGIN IMMEDIATE on the database file can serialize migration.
        var migratorHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                fixture.database.path,
                &migratorHandle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let migrator = try XCTUnwrap(migratorHandle)
        defer { sqlite3_close(migrator) }
        try executeRaw("BEGIN IMMEDIATE", database: migrator)
        var migratorCommitted = false
        defer {
            if !migratorCommitted { try? executeRaw("ROLLBACK", database: migrator) }
        }

        let probe = ConcurrentDatabaseOpenProbe()
        let finished = DispatchGroup()
        let databaseFile = fixture.database
        finished.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            probe.open(databaseFile)
            finished.leave()
        }
        XCTAssertEqual(
            finished.wait(timeout: .now() + 0.15),
            .timedOut,
            "The opener should wait for the database migration lock"
        )

        try executeRaw(
            """
            ALTER TABLE conversation_catalog_state ADD COLUMN maintenance_pending
                INTEGER NOT NULL DEFAULT 1 CHECK (maintenance_pending IN (0, 1));
            ALTER TABLE conversation_catalog_state ADD COLUMN one_time_compaction_pending
                INTEGER NOT NULL DEFAULT 1 CHECK (one_time_compaction_pending IN (0, 1));
            UPDATE conversation_catalog_state SET maintenance_pending = 1,
                one_time_compaction_pending = 1 WHERE singleton = 1;
            PRAGMA user_version = \(ConversationIndexDatabase.schemaVersion);
            COMMIT;
            """,
            database: migrator
        )
        migratorCommitted = true

        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(probe.errors.isEmpty, probe.errors.joined(separator: "\n"))
        XCTAssertEqual(probe.generations, [1])
        XCTAssertEqual(try userVersion(fixture.database), ConversationIndexDatabase.schemaVersion)
        XCTAssertTrue(try ConversationIndexDatabase(file: fixture.database).hasRows())
    }

    private func fileSize(_ file: URL) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func userVersion(_ file: URL) throws -> Int32 {
        try readInteger("PRAGMA user_version", from: file)
    }

    private func catalogStateValue(_ column: String, _ file: URL) throws -> Int32 {
        let allowed = ["maintenance_pending", "one_time_compaction_pending"]
        guard allowed.contains(column) else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 4)
        }
        return try readInteger(
            "SELECT \(column) FROM conversation_catalog_state WHERE singleton = 1",
            from: file
        )
    }

    private func readInteger(_ sql: String, from file: URL) throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 3)
        }
        return sqlite3_column_int(statement, 0)
    }

    private func prepareVersionOneCatalog(
        _ file: URL,
        discardedBytes: Int = 0,
        liveBytes: Int = 0
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 5)
        }
        defer { sqlite3_close(database) }
        try executeRaw(
            """
            BEGIN IMMEDIATE;
            ALTER TABLE conversation_catalog_state RENAME TO conversation_catalog_state_v2;
            CREATE TABLE conversation_catalog_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                generation INTEGER NOT NULL,
                fts_dirty INTEGER NOT NULL CHECK (fts_dirty IN (0, 1))
            );
            INSERT INTO conversation_catalog_state(singleton, generation, fts_dirty)
                SELECT singleton, generation, fts_dirty FROM conversation_catalog_state_v2;
            DROP TABLE conversation_catalog_state_v2;
            PRAGMA user_version = 1;
            COMMIT;
            PRAGMA auto_vacuum = NONE;
            VACUUM;
            """,
            database: database
        )
        if liveBytes > 0 {
            try executeRaw(
                """
                CREATE TABLE ccbud_migration_live_bloat(payload BLOB);
                INSERT INTO ccbud_migration_live_bloat(payload) VALUES (zeroblob(\(liveBytes)));
                PRAGMA wal_checkpoint(TRUNCATE);
                """,
                database: database
            )
        }
        if discardedBytes > 0 {
            try executeRaw(
                """
                CREATE TABLE ccbud_migration_bloat(payload BLOB);
                INSERT INTO ccbud_migration_bloat(payload) VALUES (zeroblob(\(discardedBytes)));
                DROP TABLE ccbud_migration_bloat;
                PRAGMA wal_checkpoint(TRUNCATE);
                """,
                database: database
            )
        }
    }

    private func prepareVersionTwoCatalog(_ file: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 6)
        }
        defer { sqlite3_close(database) }
        try executeRaw(
            """
            BEGIN IMMEDIATE;
            DROP TABLE conversation_user_metadata;
            PRAGMA user_version = 2;
            COMMIT;
            """,
            database: database
        )
    }

    private func inflateSearchDocument(_ file: URL, bytes: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 7)
        }
        defer { sqlite3_close(database) }
        try executeRaw(
            """
            BEGIN IMMEDIATE;
            UPDATE conversation_documents
            SET search_text = replace(hex(zeroblob(\(bytes))), '00', 'x');
            UPDATE conversation_catalog_state SET fts_dirty = 1 WHERE singleton = 1;
            COMMIT;
            """,
            database: database
        )
    }

    private func executeRaw(_ sql: String, database: OpaquePointer) throws {
        var detail: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &detail)
        defer { if let detail { sqlite3_free(detail) } }
        guard status == SQLITE_OK else {
            let message = detail.map { String(cString: $0) } ?? "SQLite \(status)"
            throw NSError(
                domain: "ConversationIndexDatabaseTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func indexed(file: URL, id: String, scope: String) -> ConversationIndexedSession {
        ConversationIndexedSession(
            metadata: makeMetadata(file: file, id: id),
            scope: scope,
            fingerprint: .init(modificationTime: .now, sizeBytes: 10),
            documents: [makeDocument(text: id)]
        )
    }

    private func makeDocument(
        transcriptID: String = "main",
        type: String? = nil,
        order: Int = 0,
        text: String
    ) -> ConversationIndexDocument {
        ConversationIndexDocument(
            transcriptID: transcriptID,
            agentType: type,
            sortOrder: order,
            text: text,
            messageSpans: [.init(
                sequence: 0,
                messageIndex: 0,
                utf16Location: 0,
                utf16Length: text.utf16.count,
                role: "user",
                timestamp: Date(timeIntervalSince1970: 1_800_000_001)
            )]
        )
    }

    private func makeMetadata(
        file: URL,
        id: String,
        source: HistorySource = .claude
    ) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "\(source.rawValue):\(id)",
            file: file,
            source: source,
            dirID: "scope",
            dirLabel: "Scope",
            sessionID: id,
            threadID: "thread-\(id)",
            rootSessionID: "root-\(id)",
            parentThreadID: "parent",
            forkedFromID: "fork",
            canonicalThreadIDValid: true,
            cwd: "/tmp/Project",
            project: "Project",
            gitBranch: "main",
            version: "1.2.3",
            title: "Full metadata",
            autoTitle: "Automatic",
            tags: ["one", "二"],
            summary: .object(["nested": .array([.number(2), .bool(true)])]),
            model: "model",
            isSubagent: true,
            skill: "review",
            agentPath: "/tmp/agent.jsonl",
            agentNickname: "Scout",
            agentRole: "explorer",
            agentDepth: 2,
            subagentCount: 3,
            imported: true,
            deleted: false,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100.75),
            sizeBytes: 9_999,
            totals: HistoryTotals(
                inputTokens: 10,
                outputTokens: 20,
                cacheRead: 30,
                cacheCreation: 40,
                turns: 2,
                credits: 1.25,
                tokenUsageAvailable: true
            ),
            messageCount: 4,
            diagnostics: .init(decodedLines: 11, malformedLines: 2)
        )
    }
}

private final class DatabaseCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class SearchCancellationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let signalAfterPollCount: Int
    private var pollCount = 0
    private var cancelled = false

    init(signalAfterPollCount: Int) {
        self.signalAfterPollCount = signalAfterPollCount
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func isCancelled() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        pollCount += 1
        if pollCount >= signalAfterPollCount { condition.broadcast() }
        return cancelled
    }

    func waitUntilObserved(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while pollCount < signalAfterPollCount, condition.wait(until: deadline) {}
        return pollCount >= signalAfterPollCount
    }
}

private final class DatabaseEntryReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entriesStorage: [ConversationIndexEntry]?
    private var errorStorage: Error?

    var entries: [ConversationIndexEntry]? {
        lock.lock()
        defer { lock.unlock() }
        return entriesStorage
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func load(_ operation: () throws -> [ConversationIndexEntry]) {
        do {
            let entries = try operation()
            lock.lock()
            entriesStorage = entries
            lock.unlock()
        } catch {
            lock.lock()
            errorStorage = error
            lock.unlock()
        }
    }
}

private final class DatabaseMaintenanceResultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var errorStorage: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func run(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            lock.lock()
            errorStorage = error
            lock.unlock()
        }
    }
}

private final class ConcurrentDatabaseOpenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var generationStorage: [Int64] = []
    private var errorStorage: [String] = []

    var generations: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return generationStorage.sorted()
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func open(_ file: URL) {
        do {
            let database = try ConversationIndexDatabase(file: file)
            let generation = try database.generation()
            lock.lock()
            generationStorage.append(generation)
            lock.unlock()
        } catch {
            lock.lock()
            errorStorage.append(String(describing: error))
            lock.unlock()
        }
    }
}

private final class Fixture {
    let directory: URL
    let database: URL
    let source: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-conversation-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("catalog.sqlite")
        source = directory.appendingPathComponent("session.jsonl")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
