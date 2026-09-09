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
        XCTAssertFalse(short.usedFallback, "Two CJK characters contain enough UTF-8 bytes for tgrep")
        XCTAssertEqual(short.documents.map(\.document.transcriptID), ["main"])

        let shortASCII = try database.candidateDocuments(for: "us")
        XCTAssertTrue(shortASCII.usedFallback)
        XCTAssertEqual(shortASCII.documents.map(\.document.transcriptID), ["main"])
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
        DispatchQueue.global(qos: .utility).async {
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

    func testNewerSchemaIsRejectedWithoutDeletingUserMetadata() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        _ = try database?.replace(indexed(file: fixture.source, id: "old", scope: "scope"))
        database = nil

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        XCTAssertThrowsError(try ConversationIndexDatabase(file: fixture.database))
        XCTAssertEqual(try readInteger("SELECT COUNT(*) FROM conversation_sessions", from: fixture.database), 1)
        XCTAssertEqual(try userVersion(fixture.database), 999)
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

        try finishMigration(migrated)
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

    func testDeferredLegacyIndexRemovalCanBeCancelledWhileWaitingForAnotherWriter() throws {
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
        DispatchQueue.global(qos: .utility).async {
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
        try finishMigration(migrated)
        XCTAssertEqual(try catalogStateValue("one_time_compaction_pending", fixture.database), 0)
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
        DispatchQueue.global(qos: .utility).async {
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
            PRAGMA user_version = 4;
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

    func testLegacyMigrationRetainsUserFlagsAndResumesCursorWithoutSemanticRevisionChange() throws {
        let fixture = try Fixture()
        var original = indexed(file: fixture.source, id: "migration-cursor", scope: "scope")
        original.metadata.starred = true
        original.metadata.pinned = true
        original.metadata.tags = ["keep-user-tag", "收藏"]
        let text = String(repeating: "needle 👩‍💻 e\u{301} payload\n", count: 15_000)
        original.documents = [makeDocument(text: text)]
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        try database?.replace(original)
        database = nil
        try prepareVersionOneCatalog(fixture.database)
        let migrated = try ConversationIndexDatabase(file: fixture.database, enableTgrep: false)
        let generation = try migrated.generation()
        let reference = try XCTUnwrap(migrated.candidateDocumentReferences(for: "needle").references.first)
        let first = try migrated.searchChunkWindows(reference: reference, query: "needle")
        var cursor = try XCTUnwrap(first.nextCursor)
        let consumed = first.windows.reduce(0) { $0 + $1.ownedUTF16Length }
        try finishMigration(migrated)
        XCTAssertEqual(try migrated.generation(), generation,
            "Physical migration must not repeatedly invalidate an unchanged interactive search")
        var remainder = ""
        while true {
            let batch = try migrated.searchChunkWindows(reference: reference, query: "needle", cursor: cursor)
            for window in batch.windows {
                let end = String.Index(utf16Offset: window.ownedUTF16Length, in: window.text)
                remainder.append(contentsOf: window.text[..<end])
            }
            guard let next = batch.nextCursor else { break }
            cursor = next
        }
        let suffixStart = String.Index(utf16Offset: consumed, in: text)
        XCTAssertEqual(remainder, String(text[suffixStart...]))
        XCTAssertEqual(try migrated.entry(for: fixture.source)?.metadata, original.metadata)
        XCTAssertEqual(try migrated.documents(for: fixture.source), original.documents)
        XCTAssertEqual(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'conversation_documents_fts%' OR name = 'conversation_documents_legacy'", from: fixture.database), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path),
            "The synthetic producer does not exist: migration must use the old SQLite text only")
    }

    func testLegacyMigrationCancellationAndLowCapacityKeepSourceForRetry() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        let original = indexed(file: fixture.source, id: "capacity-retry", scope: "scope")
        try database?.replace(original)
        database = nil
        try prepareVersionOneCatalog(fixture.database)
        var capacity: Int64 = 0
        let migrated = try ConversationIndexDatabase(file: fixture.database, enableTgrep: false,
            tgrepRuntime: .init(availableCapacity: { _ in capacity }))
        XCTAssertThrowsError(try migrated.finishFullScanMaintenance(isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try migrated.finishFullScanMaintenance(
            shouldYield: { true }, isCancelled: { true }
        )) {
            XCTAssertTrue($0 is CancellationError,
                "Lifecycle cancellation must take precedence over an activity yield")
        }
        try migrated.finishFullScanMaintenance()
        XCTAssertTrue(try migrated.maintenanceIsPending())
        XCTAssertEqual(try readInteger("SELECT COUNT(*) FROM conversation_documents_legacy", from: fixture.database), 1)
        XCTAssertEqual(try migrated.documents(for: fixture.source), original.documents)
        capacity = .max
        try finishMigration(migrated)
        XCTAssertFalse(try migrated.maintenanceIsPending())
        XCTAssertEqual(try migrated.documents(for: fixture.source), original.documents)
    }

    func testIncrementalMaintenanceConsumesAllReturnedRowsBeforeFinalizing() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertEqual(try readInteger("PRAGMA auto_vacuum", from: fixture.database), 2,
            "A fresh catalog must select its incremental pointer-map layout before enabling WAL")
        try database.replace(indexed(file: fixture.source, id: "multi-page-vacuum", scope: "scope"))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        let handle = try XCTUnwrap(raw)
        try executeRaw("""
            CREATE TABLE obsolete_payload(body BLOB);
            INSERT INTO obsolete_payload VALUES(zeroblob(8388608));
            DROP TABLE obsolete_payload;
            PRAGMA wal_checkpoint(TRUNCATE);
            """, database: handle)
        sqlite3_close(handle)
        let before = try readInteger("PRAGMA freelist_count", from: fixture.database)
        XCTAssertGreaterThan(before, 100)
        XCTAssertLessThan(before, 8192)
        try database.finishFullScanMaintenance()
        let after = try readInteger("PRAGMA freelist_count", from: fixture.database)
        XCTAssertGreaterThan(before - after, 100,
            "Consume every SQLITE_ROW, not only the first reclaimed page")
        try finishMigration(database)
        XCTAssertEqual(try readInteger("PRAGMA freelist_count", from: fixture.database), 0)
        XCTAssertFalse(try database.maintenanceIsPending())
    }

    func testIncrementalCatalogKeepsMaintenancePendingUntilLargeFreelistIsReclaimed() throws {
        let fixture = try Fixture()
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        try database?.replace(indexed(file: fixture.source, id: "reclaim", scope: "scope"))
        database = nil
        try prepareVersionOneCatalog(fixture.database)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        let handle = try XCTUnwrap(raw)
        // Manufacture reclaimable pages through public SQL only. FTS shadow tables are
        // private implementation details and defensive SQLite correctly refuses direct writes.
        try executeRaw("""
            PRAGMA auto_vacuum = INCREMENTAL;
            VACUUM;
            CREATE TABLE obsolete_payload(body BLOB);
            INSERT INTO obsolete_payload VALUES(zeroblob(100663296));
            DROP TABLE obsolete_payload;
            PRAGMA wal_checkpoint(TRUNCATE);
            """, database: handle)
        sqlite3_close(handle)
        let originalBytes = try fileSize(fixture.database)
        let migrated = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertEqual(try readInteger("PRAGMA auto_vacuum", from: fixture.database), 2)
        // First commit the tiny legacy document, then retire its tables and reclaim exactly
        // one activity-bounded micro-batch. This assertion must not depend on disk speed.
        try migrated.finishFullScanMaintenance(shouldYield: { true })
        try migrated.finishFullScanMaintenance(shouldYield: { true })
        XCTAssertTrue(try migrated.maintenanceIsPending(),
            "One bounded reclamation pass must not mark a 96 MiB freelist fully reclaimed")
        XCTAssertGreaterThan(try readInteger("PRAGMA freelist_count", from: fixture.database), 0)
        try finishMigration(migrated)
        XCTAssertEqual(try readInteger("PRAGMA freelist_count", from: fixture.database), 0)
        XCTAssertLessThan(try fileSize(fixture.database), originalBytes / 2)
    }

    func testContinuousActivityCommitsConversionBeforeRetiringFTSAndVacuumStillAdvances() throws {
        let fixture = try Fixture()
        var original = indexed(file: fixture.source, id: "busy-producer", scope: "scope")
        original.documents = [makeDocument(text: String(repeating: "busy needle payload ", count: 6_000))]
        var database: ConversationIndexDatabase? = try .init(file: fixture.database)
        try database?.replace(original)
        database = nil
        try prepareVersionOneCatalog(fixture.database)
        let migrated = try ConversationIndexDatabase(file: fixture.database)
        let generation = try migrated.generation()
        var observedConvertedBeforeDrop = false
        for _ in 0..<256 {
            // Model a producer that always has another activity event pending.
            try migrated.finishFullScanMaintenance(shouldYield: { true })
            let converted = try readInteger("SELECT COUNT(*) FROM conversation_documents WHERE storage_version = 0", from: fixture.database) == 0
            let hasFTS = try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE name = 'conversation_documents_fts'", from: fixture.database) != 0
            if converted, hasFTS { observedConvertedBeforeDrop = true }
            if try !migrated.maintenanceIsPending() { break }
        }
        XCTAssertTrue(observedConvertedBeforeDrop,
            "Searchable compressed text must be committed before the long atomic retirement")
        XCTAssertFalse(try migrated.maintenanceIsPending(), "Continuous activity must not starve retirement")
        XCTAssertEqual(try migrated.generation(), generation)
        XCTAssertEqual(try migrated.documents(for: fixture.source), original.documents)
        XCTAssertEqual(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'conversation_documents_fts%'", from: fixture.database), 0)
    }

    func testActivityYieldKeepsEachVacuumMicroBatchCommitted() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        XCTAssertEqual(try readInteger("PRAGMA auto_vacuum", from: fixture.database), 2,
            "Activity-bounded reclamation requires a genuinely incremental fresh catalog")
        try database.replace(indexed(file: fixture.source, id: "busy-reclaim", scope: "scope"))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        let handle = try XCTUnwrap(raw)
        try executeRaw("""
            CREATE TABLE obsolete_payload(body BLOB);
            INSERT INTO obsolete_payload VALUES(zeroblob(8388608));
            DROP TABLE obsolete_payload;
            PRAGMA wal_checkpoint(TRUNCATE);
            """, database: handle)
        sqlite3_close(handle)
        var previous = try readInteger("PRAGMA freelist_count", from: fixture.database)
        for _ in 0..<32 {
            try database.finishFullScanMaintenance(shouldYield: { true })
            let current = try readInteger("PRAGMA freelist_count", from: fixture.database)
            XCTAssertLessThan(current, previous, "Every activity-interrupted pass must retain reclaimed pages")
            previous = current
            if current == 0 { break }
        }
        XCTAssertEqual(previous, 0)
        XCTAssertFalse(try database.maintenanceIsPending())
    }

    func testAtomicFTSRetirementIgnoresActivityButStopInterruptsAndWALSearchRemainsAvailable() throws {
        let fixture = try Fixture()
        let database = try ConversationIndexDatabase(file: fixture.database)
        try database.replace(indexed(file: fixture.source, id: "retirement-needle", scope: "scope"))
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &raw), SQLITE_OK)
        let blocker = try XCTUnwrap(raw)
        defer { sqlite3_close(blocker) }
        try executeRaw("""
            CREATE VIRTUAL TABLE conversation_documents_fts USING fts5(search_text);
            INSERT INTO conversation_documents_fts(search_text) VALUES('obsolete needle');
            BEGIN IMMEDIATE;
            """, database: blocker)
        defer { try? executeRaw("ROLLBACK", database: blocker) }
        let cancellation = DatabaseCancellationProbe()
        let result = DatabaseMaintenanceResultProbe()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global(qos: .utility).async {
            started.signal()
            result.run {
                try database.finishFullScanMaintenance(shouldYield: { true },
                    isCancelled: { cancellation.isCancelled() })
            }
            finished.leave()
        }
        defer { cancellation.cancel(); _ = finished.wait(timeout: .now() + 2) }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.15), .timedOut,
            "Activity must not cancel/restart the atomic DROP while it waits for a writer")
        let reads = DatabaseMaintenanceResultProbe()
        let readFinished = DispatchGroup()
        readFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            reads.run {
                let rows = try database.listEntries(scope: "scope", deleted: nil, limit: 1)
                let references = try database.candidateDocumentReferences(for: "needle").references
                guard rows.count == 1, let reference = references.first else {
                    throw NSError(domain: "retirement-read-identity", code: 1)
                }
                let windows = try database.searchChunkWindows(reference: reference, query: "needle")
                guard windows.windows.contains(where: { $0.text.contains("needle") }) else {
                    throw NSError(domain: "retirement-read-search", code: 2)
                }
            }
            readFinished.leave()
        }
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(reads.error, "Metadata and actual exact-search input must remain readable during retirement")
        let stopStarted = DispatchTime.now().uptimeNanoseconds
        cancellation.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - stopStarted) / 1e9, 0.5)
        XCTAssertTrue(result.error is CancellationError, String(describing: result.error))
        XCTAssertTrue(try database.maintenanceIsPending())
        try executeRaw("ROLLBACK", database: blocker)
        try database.finishFullScanMaintenance(shouldYield: { true })
        XCTAssertEqual(try readInteger("SELECT COUNT(*) FROM sqlite_master WHERE name = 'conversation_documents_fts'", from: fixture.database), 0)
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
        // Manufacture the actual pre-chunk layout, not a v5 layout carrying a v1 number.
        var current: ConversationIndexDatabase? = try .init(file: file, enableTgrep: false)
        var rows: [(String, ConversationIndexDocument)] = []
        for entry in try current!.listEntries(deleted: nil, limit: .max) {
            for document in try current!.documents(forPath: entry.sourcePath) {
                rows.append((entry.sourcePath, document))
            }
        }
        current = nil
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ConversationIndexDatabaseTests", code: 5)
        }
        defer { sqlite3_close(database) }
        try executeRaw(
            """
            BEGIN IMMEDIATE;
            DROP TRIGGER IF EXISTS conversation_documents_content_stamp;
            DROP TABLE conversation_search_chunks;
            DROP INDEX conversation_documents_session_order;
            ALTER TABLE conversation_documents RENAME TO chunk_identities;
            CREATE TABLE conversation_documents (
                id INTEGER PRIMARY KEY,
                session_path TEXT NOT NULL,
                transcript_id TEXT NOT NULL,
                agent_type TEXT,
                sort_order INTEGER NOT NULL,
                search_text TEXT NOT NULL,
                message_spans_json BLOB NOT NULL,
                UNIQUE(session_path, transcript_id)
            );
            DROP TABLE chunk_identities;
            CREATE VIRTUAL TABLE conversation_documents_fts USING fts5(
                search_text, content='conversation_documents', content_rowid='id', tokenize='trigram');
            ALTER TABLE conversation_catalog_state RENAME TO conversation_catalog_state_v2;
            CREATE TABLE conversation_catalog_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                generation INTEGER NOT NULL,
                fts_dirty INTEGER NOT NULL CHECK (fts_dirty IN (0, 1))
            );
            INSERT INTO conversation_catalog_state(singleton, generation, fts_dirty)
                SELECT singleton, generation, 0 FROM conversation_catalog_state_v2;
            DROP TABLE conversation_catalog_state_v2;
            PRAGMA user_version = 1;
            COMMIT;
            PRAGMA auto_vacuum = NONE;
            VACUUM;
            """,
            database: database
        )
        for (path, document) in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, """
                INSERT INTO conversation_documents(session_path, transcript_id, agent_type,
                    sort_order, search_text, message_spans_json) VALUES (?, ?, ?, ?, ?, ?)
                """, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            path.withCString { _ = sqlite3_bind_text(statement, 1, $0, -1, transient) }
            document.transcriptID.withCString { _ = sqlite3_bind_text(statement, 2, $0, -1, transient) }
            if let agentType = document.agentType {
                agentType.withCString { _ = sqlite3_bind_text(statement, 3, $0, -1, transient) }
            } else { sqlite3_bind_null(statement, 3) }
            sqlite3_bind_int64(statement, 4, Int64(document.sortOrder))
            let text = Array(document.text.utf8)
            text.withUnsafeBufferPointer {
                _ = sqlite3_bind_text(statement, 5, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self),
                    Int32($0.count), transient)
            }
            let spans = try JSONEncoder().encode(document.messageSpans)
            spans.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), transient) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        try executeRaw("PRAGMA wal_checkpoint(TRUNCATE)", database: database)
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

    private func finishMigration(_ database: ConversationIndexDatabase) throws {
        for _ in 0..<256 {
            try database.finishFullScanMaintenance()
            if try !database.maintenanceIsPending() { return }
        }
        XCTFail("Synthetic migration did not finish within bounded passes")
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
