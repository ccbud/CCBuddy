import Foundation
import XCTest
@testable import CCBuddy

final class ConversationIndexScannerTests: XCTestCase {
    func testFullScanPrefetchesOnceNewestFirstAndComparesEveryDependency() throws {
        let environment = try makeEnvironment("scanner-full")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let older = try makeCandidate(
            environment,
            name: "older.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = try makeCandidate(
            environment,
            name: "newer.jsonl",
            format: .qoder,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let sidecar = environment.root.appendingPathComponent("metadata.json")
        try Data("one".utf8).write(to: sidecar)

        let registry = ScannerTestRegistry(
            candidates: [older, newer],
            dependencies: [
                older.file.path: [
                    .init(file: older.file, role: .primaryTranscript),
                    .init(file: sidecar, role: .providerMetadata),
                ],
                newer.file.path: [
                    .init(file: newer.file, role: .primaryTranscript),
                ],
            ]
        )
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let initial = try scanner.scanAll()
        XCTAssertEqual(initial.discovered, 2)
        XCTAssertEqual(initial.parsed, 2)
        XCTAssertEqual(initial.unchanged, 0)
        XCTAssertEqual(initial.failed, 0)
        XCTAssertTrue(initial.hasChanges)
        XCTAssertEqual(loader.prefetchBatches, [[newer.file.path, older.file.path]])
        XCTAssertEqual(loader.loadPaths, [newer.file.path, older.file.path])

        loader.resetObservations()
        let warm = try scanner.scanAll()
        XCTAssertEqual(warm.discovered, 2)
        XCTAssertEqual(warm.parsed, 0)
        XCTAssertEqual(warm.unchanged, 2)
        XCTAssertFalse(warm.hasChanges)
        XCTAssertEqual(warm.generation, initial.generation)
        XCTAssertEqual(loader.prefetchBatches, [[newer.file.path, older.file.path]])
        XCTAssertTrue(loader.loadPaths.isEmpty)

        try Data("dependency changed and is longer".utf8).write(to: sidecar)
        loader.resetObservations()
        let dependencyChange = try scanner.scanAll()
        XCTAssertEqual(dependencyChange.parsed, 1)
        XCTAssertEqual(dependencyChange.unchanged, 1)
        XCTAssertEqual(loader.loadPaths, [older.file.path])
        XCTAssertGreaterThan(dependencyChange.generation, warm.generation)
        XCTAssertEqual(scanner.manifests.count, 2)
        XCTAssertTrue(scanner.watchRoots.map(\.path).contains(sidecar.path))
    }

    func testColdFullScanPublishesActiveQuickMetadataBeforeOtherScopesAndFullParse() throws {
        var environment = try makeEnvironment("scanner-active-scope-first")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let activeScope = environment.historyRoot.path
        let otherRoot = environment.root.appendingPathComponent("newer-history", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        environment.configuration.historyDirs = [activeScope, otherRoot.path]
        environment.configuration.active = activeScope

        let directories = HistoryPathResolver(configuration: environment.configuration)
            .directories(activeOnly: false)
        environment.directory = try XCTUnwrap(directories.first { $0.id == activeScope })
        var otherEnvironment = environment
        otherEnvironment.directory = try XCTUnwrap(directories.first { $0.id == otherRoot.path })

        let activeOlder = try makeCandidate(
            environment,
            name: "active-older.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let unrelatedNewer = try makeCandidate(
            otherEnvironment,
            name: "unrelated-newer.jsonl",
            format: .codex,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let registry = ScannerTestRegistry(candidates: [unrelatedNewer, activeOlder])
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry,
            providesQuickMetadata: true
        )
        let database = try ConversationIndexDatabase(file: environment.database)
        let catalog = ScannerRecordingCatalog(database: database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: catalog,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let progress = ScannerProgressProbe()

        let result = try scanner.scanAll { value in progress.append(value) }

        XCTAssertEqual(result.parsed, 2)
        XCTAssertEqual(result.metadataPublished, 2)
        XCTAssertEqual(loader.quickMetadataBatches, [
            [activeOlder.file.path],
            [unrelatedNewer.file.path],
        ])
        XCTAssertEqual(loader.prefetchBatches, [[activeOlder.file.path, unrelatedNewer.file.path]])
        XCTAssertEqual(loader.loadPaths, [activeOlder.file.path, unrelatedNewer.file.path])
        XCTAssertEqual(catalog.mutations, [
            .metadata([activeOlder.file.path]),
            .metadata([unrelatedNewer.file.path]),
            .full(activeOlder.file.path),
            .full(unrelatedNewer.file.path),
        ])
        XCTAssertEqual(progress.results.first?.metadataPublished, 1)
        XCTAssertEqual(progress.results.first?.parsed, 0)
    }

    func testRetriesOneDependencyChangeThenReportsStableFailureWithoutReplacing() throws {
        let environment = try makeEnvironment("scanner-retry")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidate = try makeCandidate(
            environment,
            name: "retry.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let registry = ScannerTestRegistry(candidates: [candidate])
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        loader.failForDependencyChanges(path: candidate.file.path, count: 1)
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let recovered = try scanner.scanAll()
        XCTAssertEqual(recovered.parsed, 1)
        XCTAssertEqual(recovered.failed, 0)
        XCTAssertEqual(loader.loadPaths, [candidate.file.path, candidate.file.path])
        let indexedFingerprint = try XCTUnwrap(database.entry(for: candidate.file)?.fingerprint)

        try Data("changed primary transcript".utf8).write(to: candidate.file)
        loader.resetObservations()
        loader.failForDependencyChanges(path: candidate.file.path, count: 2)
        let failed = try scanner.scanAll()
        XCTAssertEqual(failed.parsed, 0)
        XCTAssertEqual(failed.failed, 1)
        XCTAssertEqual(loader.loadPaths, [candidate.file.path, candidate.file.path])
        XCTAssertEqual(try database.entry(for: candidate.file)?.fingerprint, indexedFingerprint)
        XCTAssertFalse(failed.hasChanges)
    }

    func testFullParseFailureRetainsQuickRowAndSentinelRetriesNextScan() throws {
        let environment = try makeEnvironment("scanner-quick-retry")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidate = try makeCandidate(
            environment,
            name: "quick-retry.jsonl",
            format: .codex,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let registry = ScannerTestRegistry(candidates: [candidate])
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry,
            providesQuickMetadata: true
        )
        loader.failForDependencyChanges(path: candidate.file.path, count: 2)
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let failed = try scanner.scanAll()

        XCTAssertEqual(failed.metadataPublished, 1)
        XCTAssertEqual(failed.parsed, 0)
        XCTAssertEqual(failed.failed, 1)
        XCTAssertTrue(failed.hasChanges)
        let quickEntry = try XCTUnwrap(database.entry(for: candidate.file))
        XCTAssertEqual(quickEntry.metadata.title, "Quick quick-retry.jsonl")
        XCTAssertEqual(quickEntry.fingerprint.modificationTime, Date(timeIntervalSince1970: 0))
        XCTAssertTrue(quickEntry.fingerprint.dependencyFingerprint?.hasPrefix("quick:") == true)
        XCTAssertTrue(try database.documents(for: candidate.file).isEmpty)

        loader.resetObservations()
        let retried = try scanner.scanAll()

        XCTAssertEqual(retried.metadataPublished, 1)
        XCTAssertEqual(retried.parsed, 1)
        XCTAssertEqual(retried.failed, 0)
        XCTAssertEqual(loader.loadPaths, [candidate.file.path])
        let completeEntry = try XCTUnwrap(database.entry(for: candidate.file))
        XCTAssertNotEqual(completeEntry.fingerprint.modificationTime, Date(timeIntervalSince1970: 0))
        XCTAssertFalse(completeEntry.fingerprint.dependencyFingerprint?.hasPrefix("quick:") == true)
        XCTAssertEqual(completeEntry.metadata.title, "quick-retry.jsonl")
        XCTAssertEqual(try database.documents(for: candidate.file).count, 1)
    }

    func testReconcileRetainsRowsForMissingBaseOrProducerRoot() throws {
        let root = try HistoryTestSupport.temporaryDirectory("scanner-reconcile")
        defer { try? FileManager.default.removeItem(at: root) }
        let missingProducerBase = root.appendingPathComponent("missing-producer", isDirectory: true)
        let missingBase = root.appendingPathComponent("missing-base", isDirectory: true)
        let availableBase = root.appendingPathComponent("available", isDirectory: true)
        try FileManager.default.createDirectory(
            at: missingProducerBase,
            withIntermediateDirectories: true
        )
        let availableProjects = availableBase.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: availableProjects,
            withIntermediateDirectories: true
        )
        let configuration = HistoryConfiguration(
            historyDirs: [missingProducerBase.path, missingBase.path, availableBase.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let database = try ConversationIndexDatabase(
            file: root.appendingPathComponent("app/scanner.sqlite")
        )
        let missingProducerFile = missingProducerBase
            .appendingPathComponent("projects/p/resumable.jsonl")
        let missingBaseFile = missingBase.appendingPathComponent("projects/p/offline.jsonl")
        let removableFile = availableProjects.appendingPathComponent("p/deleted.jsonl")
        try database.replace(indexedSession(file: missingProducerFile, scope: missingProducerBase.path))
        try database.replace(indexedSession(file: missingBaseFile, scope: missingBase.path))
        try database.replace(indexedSession(file: removableFile, scope: availableBase.path))

        let registry = ScannerTestRegistry(candidates: [])
        let loader = ScannerTestLoader(configuration: configuration, registry: registry)
        let scanner = ConversationIndexScanner(
            configuration: configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let result = try scanner.scanAll()
        XCTAssertEqual(result.discovered, 0)
        XCTAssertEqual(result.removed, 1)
        XCTAssertNotNil(try database.entry(for: missingProducerFile))
        XCTAssertNotNil(try database.entry(for: missingBaseFile))
        XCTAssertNil(try database.entry(for: removableFile))
    }

    func testFullScanPurgesRowsFromScopesRemovedFromConfiguration() throws {
        let environment = try makeEnvironment("scanner-removed-scope")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let retiredRoot = environment.root.appendingPathComponent("retired", isDirectory: true)
        let retiredFile = retiredRoot.appendingPathComponent("projects/p/private.jsonl")
        let database = try ConversationIndexDatabase(file: environment.database)
        try database.replace(indexedSession(file: retiredFile, scope: retiredRoot.path))
        XCTAssertEqual(try database.candidateDocuments(for: "fixture").documents.count, 1)

        let registry = ScannerTestRegistry(candidates: [])
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: ScannerTestLoader(
                configuration: environment.configuration,
                registry: registry
            ),
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let result = try scanner.scanAll()

        XCTAssertEqual(result.removed, 1)
        XCTAssertNil(try database.entry(for: retiredFile))
        XCTAssertTrue(try database.candidateDocuments(for: "fixture").documents.isEmpty)
    }

    func testFullScanMigratesUnchangedPathWhenScopeIdentifierChanges() throws {
        let root = try HistoryTestSupport.temporaryDirectory("scanner-scope-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = root.appendingPathComponent("history", isDirectory: true)
        let project = canonicalRoot.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("session.jsonl")
        try Data("scope migration".utf8).write(to: transcript)
        let aliasRoot = root.appendingPathComponent("history-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: canonicalRoot
        )
        let importsRoot = root.appendingPathComponent("app/imports", isDirectory: true)
        let database = try ConversationIndexDatabase(
            file: root.appendingPathComponent("app/scanner.sqlite")
        )

        let aliasConfiguration = HistoryConfiguration(
            historyDirs: [aliasRoot.path],
            homeDirectory: root,
            importsRoot: importsRoot
        )
        let aliasDirectory = try XCTUnwrap(
            HistoryPathResolver(configuration: aliasConfiguration)
                .directories(activeOnly: false)
                .first(where: { $0.id == aliasRoot.path })
        )
        let aliasCandidate = HistoryFileCandidate(
            file: transcript,
            projectDirectoryName: "p",
            directory: aliasDirectory,
            formatHint: .claude
        )
        let aliasRegistry = ScannerTestRegistry(candidates: [aliasCandidate])
        let aliasScanner = ConversationIndexScanner(
            configuration: aliasConfiguration,
            catalog: database,
            loader: ScannerTestLoader(
                configuration: aliasConfiguration,
                registry: aliasRegistry
            ),
            registry: aliasRegistry,
            availability: ConversationIndexFileSystemAvailability()
        )
        XCTAssertEqual(try aliasScanner.scanAll().parsed, 1)
        let originalFingerprint = try XCTUnwrap(database.entry(for: transcript)?.fingerprint)

        let canonicalConfiguration = HistoryConfiguration(
            historyDirs: [canonicalRoot.path],
            homeDirectory: root,
            importsRoot: importsRoot
        )
        let canonicalDirectory = try XCTUnwrap(
            HistoryPathResolver(configuration: canonicalConfiguration)
                .directories(activeOnly: false)
                .first(where: { $0.id == canonicalRoot.path })
        )
        let canonicalCandidate = HistoryFileCandidate(
            file: transcript,
            projectDirectoryName: "p",
            directory: canonicalDirectory,
            formatHint: .claude
        )
        let canonicalRegistry = ScannerTestRegistry(candidates: [canonicalCandidate])
        let canonicalScanner = ConversationIndexScanner(
            configuration: canonicalConfiguration,
            catalog: database,
            loader: ScannerTestLoader(
                configuration: canonicalConfiguration,
                registry: canonicalRegistry
            ),
            registry: canonicalRegistry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let migrated = try canonicalScanner.scanAll()

        XCTAssertEqual(migrated.parsed, 1)
        XCTAssertEqual(migrated.removed, 0)
        let migratedEntry = try XCTUnwrap(database.entry(for: transcript))
        XCTAssertEqual(migratedEntry.scope, canonicalRoot.path)
        XCTAssertEqual(migratedEntry.metadata.dirID, canonicalRoot.path)
        XCTAssertEqual(migratedEntry.fingerprint, originalFingerprint)
        XCTAssertEqual(try database.candidateDocuments(for: "session").documents.count, 1)
    }

    func testWatcherImpactIsIncrementalAndConcurrentScansSerialize() throws {
        let environment = try makeEnvironment("scanner-incremental")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let first = try makeCandidate(
            environment,
            name: "first.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = try makeCandidate(
            environment,
            name: "second.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let registry = ScannerTestRegistry(candidates: [first, second])
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        _ = try scanner.scanAll()

        try Data("changed".utf8).write(to: first.file)
        registry.setImpact(candidates: [first], requiresDiscovery: false)
        loader.resetObservations()
        let incremental = try scanner.scan(changedPaths: [first.file], forceDiscovery: false)
        XCTAssertEqual(incremental.discovered, 1)
        XCTAssertEqual(incremental.parsed, 1)
        XCTAssertEqual(loader.loadPaths, [first.file.path])
        XCTAssertEqual(registry.eventImpactCalls, 1)

        try Data("changed again with a different size".utf8).write(to: first.file)
        loader.resetObservations()
        loader.loadDelay = 0.20
        let completed = expectation(description: "both serialized scans complete")
        completed.expectedFulfillmentCount = 2
        let errors = ScannerErrorProbe()
        for _ in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try scanner.scan(changedPaths: [first.file], forceDiscovery: false)
                } catch {
                    errors.append(error)
                }
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 8)

        XCTAssertTrue(errors.errors.isEmpty)
        XCTAssertEqual(loader.loadPaths, [first.file.path])
        XCTAssertEqual(loader.maximumConcurrentLoads, 1)
    }

    func testProjectionRefreshAdvancesGenerationWithoutReparsingDocuments() throws {
        let environment = try makeEnvironment("scanner-projection-refresh")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidate = try makeCandidate(
            environment,
            name: "projection.jsonl",
            format: .codex,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let registry = ScannerTestRegistry(candidates: [candidate])
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        let initial = try scanner.scanAll()
        let initialEntry = try XCTUnwrap(database.entry(for: candidate.file))
        loader.resetObservations()
        registry.setImpact(
            candidates: [candidate],
            requiresDiscovery: false,
            requiresProjectionRefresh: true
        )
        let progress = ScannerProgressProbe()

        let refreshed = try scanner.scan(
            changedPaths: [environment.root.appendingPathComponent("state_5.sqlite-wal")],
            onProgress: { @Sendable result in progress.append(result) }
        )

        XCTAssertEqual(refreshed.parsed, 0)
        XCTAssertEqual(refreshed.unchanged, 1)
        XCTAssertTrue(loader.loadPaths.isEmpty)
        XCTAssertEqual(refreshed.generation, initial.generation + 1)
        XCTAssertEqual(try database.entry(for: candidate.file)?.fingerprint, initialEntry.fingerprint)
        XCTAssertEqual(progress.results.last?.generation, refreshed.generation)
    }

    func testCancellationStopsBeforeTheNextCatalogReplacement() throws {
        let environment = try makeEnvironment("scanner-cancel")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidates = try (0..<3).map { index in
            try makeCandidate(
                environment,
                name: "cancel-\(index).jsonl",
                format: .claude,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        }
        let registry = ScannerTestRegistry(candidates: candidates)
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let cancellation = ScannerCancellationProbe()
        let progress = ScannerProgressProbe()

        XCTAssertThrowsError(try scanner.scanAll(
            onProgress: { result in
                progress.append(result)
                if result.parsed == 1 { cancellation.cancel() }
            },
            isCancelled: { @Sendable in cancellation.isCancelled() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(progress.results.last?.parsed, 1)
        XCTAssertEqual(try database.listEntries(deleted: nil, limit: .max).count, 1)
        XCTAssertEqual(loader.loadPaths.count, 1)
    }

    func testQuickMetadataPublishesInBatchesOf32AndCancelsBeforeNextBatch() throws {
        let environment = try makeEnvironment("scanner-quick-batches")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidates = try (0..<33).map { index in
            try makeCandidate(
                environment,
                name: String(format: "quick-batch-%02d.jsonl", index),
                format: .claude,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        }
        let registry = ScannerTestRegistry(candidates: candidates)
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry,
            providesQuickMetadata: true
        )
        let database = try ConversationIndexDatabase(file: environment.database)
        let catalog = ScannerRecordingCatalog(database: database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: catalog,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        XCTAssertThrowsError(try scanner.scanAll(
            isCancelled: { @Sendable in catalog.metadataBatchCount == 1 }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(loader.quickMetadataBatches.map(\.count), [32])
        XCTAssertEqual(catalog.metadataBatchSizes, [32])
        XCTAssertTrue(loader.prefetchBatches.isEmpty)
        XCTAssertTrue(loader.loadPaths.isEmpty)
        XCTAssertEqual(try database.listEntries(deleted: nil, limit: .max).count, 32)

        loader.resetObservations()
        catalog.resetMutations()
        let completed = try scanner.scanAll()

        XCTAssertEqual(loader.quickMetadataBatches.map(\.count), [32, 1])
        XCTAssertEqual(catalog.metadataBatchSizes, [32, 1])
        XCTAssertEqual(completed.metadataPublished, 33)
        XCTAssertEqual(completed.parsed, 33)
        XCTAssertEqual(try database.listEntries(deleted: nil, limit: .max).count, 33)
    }

    func testCoordinatorPublishesProgressAndTerminalEventsAcrossCancellationRestart() async throws {
        let environment = try makeEnvironment("coordinator-restart")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidates = try (0..<3).map { index in
            try makeCandidate(
                environment,
                name: "coordinator-\(index).jsonl",
                format: .claude,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        }
        let registry = ScannerTestRegistry(candidates: candidates)
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        loader.loadDelay = 0.12
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let coordinator = ConversationCatalogCoordinator(
            configuration: environment.configuration,
            database: database,
            scanner: scanner
        )
        let firstRun = CatalogEventProbe()
        coordinator.start { event in firstRun.append(event) }
        let firstProgress = await waitForEvent(
            in: firstRun,
            timeoutNanoseconds: 3_000_000_000
        ) {
            $0.phase == .progress && $0.revision > 0
        }
        XCTAssertTrue(firstProgress)

        await Task.detached(priority: .utility) { coordinator.stop() }.value
        XCTAssertEqual(
            try database.listEntries(deleted: nil, limit: .max).count,
            1,
            "stop() must cancel and drain before a second candidate can replace catalog rows"
        )

        loader.loadDelay = 0
        let secondRun = CatalogEventProbe()
        coordinator.start { event in secondRun.append(event) }
        let secondFinished = await waitForEvent(
            in: secondRun,
            timeoutNanoseconds: 3_000_000_000
        ) {
            $0.phase == .finished && $0.errorDescription == nil
        }
        XCTAssertTrue(secondFinished)
        await Task.detached(priority: .utility) { coordinator.stop() }.value

        XCTAssertEqual(try database.listEntries(deleted: nil, limit: .max).count, 3)
        XCTAssertEqual(secondRun.events.last?.phase, .finished)
        XCTAssertEqual(secondRun.events.last?.completed, 3)
    }

    func testStartupFullScanDoesNotRunHeavyDatabaseMaintenance() throws {
        let environment = try makeEnvironment("scanner-no-startup-maintenance")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let registry = ScannerTestRegistry(candidates: [])
        let catalog = ScannerMaintenanceProbeCatalog()
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: catalog,
            loader: ScannerTestLoader(
                configuration: environment.configuration,
                registry: registry
            ),
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )

        _ = try scanner.scanAll()

        XCTAssertEqual(catalog.maintenanceInvocationCount, 0)
    }

    func testCoordinatorReattachmentCannotReplayProgressAfterTerminalEvent() async throws {
        let environment = try makeEnvironment("coordinator-reattach-order")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidates = try (0..<3).map { index in
            try makeCandidate(
                environment,
                name: "reattach-\(index).jsonl",
                format: .claude,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            )
        }
        let registry = ScannerTestRegistry(candidates: candidates)
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        loader.loadDelay = 0.50
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let coordinator = ConversationCatalogCoordinator(
            configuration: environment.configuration,
            database: database,
            scanner: scanner
        )
        let initial = CatalogEventProbe()
        coordinator.start { event in initial.append(event) }
        let initialProgress = await waitForEvent(
            in: initial,
            timeoutNanoseconds: 3_000_000_000
        ) {
            $0.phase == .progress && $0.completed == 1
        }
        XCTAssertTrue(initialProgress)

        // A synchronous stale replay would run on this caller queue. Hold only that replay until
        // the worker publishes its terminal event, making the old progress-after-finished race
        // deterministic instead of relying on scheduler timing.
        let callerQueue = DispatchQueue(
            label: "dev.ccbud.tests.catalog-reattach-caller",
            qos: .utility
        )
        let callerKey = DispatchSpecificKey<UInt8>()
        callerQueue.setSpecific(key: callerKey, value: 1)
        let reattached = CatalogEventProbe()
        let startReturned = expectation(description: "reattachment returns")
        callerQueue.async {
            coordinator.start { event in
                if DispatchQueue.getSpecific(key: callerKey) != nil,
                   event.phase == .progress {
                    _ = reattached.waitForEvent(timeout: 3) { $0.phase == .finished }
                }
                reattached.append(event)
            }
            startReturned.fulfill()
        }

        // This call is a subscription reattachment. It must not touch the scanner lock held by
        // the deliberately slow full scan.
        await fulfillment(of: [startReturned], timeout: 0.40)
        let reattachedFinished = await waitForEvent(
            in: reattached,
            timeoutNanoseconds: 4_000_000_000
        ) {
            $0.phase == .finished && $0.errorDescription == nil
        }
        XCTAssertTrue(reattachedFinished)
        try? await Task.sleep(nanoseconds: 80_000_000)
        await Task.detached(priority: .utility) { coordinator.stop() }.value

        let reattachedEvents = reattached.events
        XCTAssertEqual(reattachedEvents.last?.phase, .finished)
        XCTAssertEqual(reattachedEvents.last?.completed, 3)
        XCTAssertEqual(
            reattachedEvents.filter { $0.phase == .finished }.count,
            1,
            "Reattaching during one scan must deliver exactly one terminal event"
        )

        var terminalReached = false
        var progressAfterTerminalWithoutRestart: [ConversationCatalogScanEvent] = []
        for event in reattachedEvents {
            switch event.phase {
            case .started:
                terminalReached = false
            case .progress:
                if terminalReached {
                    progressAfterTerminalWithoutRestart.append(event)
                }
            case .finished:
                terminalReached = true
            }
        }
        XCTAssertTrue(
            progressAfterTerminalWithoutRestart.isEmpty,
            "Progress must not follow a terminal event unless a new scan starts first"
        )
    }

    func testCoordinatorPublishesTerminalFailureInsteadOfSwallowingIt() async throws {
        let environment = try makeEnvironment("coordinator-failure")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let database = try ConversationIndexDatabase(file: environment.database)
        let registry = ScannerTestRegistry(candidates: [])
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: ScannerFailingCatalog(),
            loader: ScannerTestLoader(
                configuration: environment.configuration,
                registry: registry
            ),
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let coordinator = ConversationCatalogCoordinator(
            configuration: environment.configuration,
            database: database,
            scanner: scanner
        )
        let events = CatalogEventProbe()
        coordinator.start { event in events.append(event) }
        let terminalFailure = await waitForEvent(
            in: events,
            timeoutNanoseconds: 3_000_000_000
        ) {
            $0.phase == .finished && $0.errorDescription == "fixture catalog failure"
        }
        XCTAssertTrue(terminalFailure)
        await Task.detached(priority: .utility) { coordinator.stop() }.value

        XCTAssertTrue(events.events.contains(where: { $0.phase == .started }))
        XCTAssertEqual(events.events.last?.phase, .finished)
        XCTAssertEqual(events.events.last?.errorDescription, "fixture catalog failure")
    }

    func testCoordinatorSurfacesWatcherFailureAndRetriesItOnReconcile() async throws {
        let environment = try makeEnvironment("coordinator-watcher-retry")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let database = try ConversationIndexDatabase(file: environment.database)
        let registry = ScannerTestRegistry(candidates: [])
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: ScannerTestLoader(
                configuration: environment.configuration,
                registry: registry
            ),
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let starter = WatcherStartProbe()
        let coordinator = ConversationCatalogCoordinator(
            configuration: environment.configuration,
            database: database,
            scanner: scanner,
            watcherStarter: { watcher in starter.start(watcher) }
        )
        let events = CatalogEventProbe()
        coordinator.start { event in events.append(event) }

        let unavailable = await waitForEvent(
            in: events,
            timeoutNanoseconds: 3_000_000_000
        ) {
            guard $0.phase == .finished,
                  case .unavailable = $0.watcherState else { return false }
            return true
        }
        XCTAssertTrue(unavailable)
        XCTAssertGreaterThanOrEqual(starter.attemptCount, 2)

        starter.allowSuccess()
        try await Task.detached(priority: .utility) {
            try coordinator.reconcileNow()
        }.value
        let recovered = await waitForEvent(
            in: events,
            timeoutNanoseconds: 3_000_000_000
        ) {
            $0.phase == .finished && $0.watcherState == .active
        }
        XCTAssertTrue(recovered)
        XCTAssertGreaterThanOrEqual(starter.attemptCount, 3)
        await Task.detached(priority: .utility) { coordinator.stop() }.value
    }

    func testCoordinatorStopDrainsAnInFlightObserverAndSuppressesQueuedEvents() async throws {
        let environment = try makeEnvironment("coordinator-stop-observer")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidate = try makeCandidate(
            environment,
            name: "stop-observer.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let registry = ScannerTestRegistry(candidates: [candidate])
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: ScannerTestLoader(
                configuration: environment.configuration,
                registry: registry
            ),
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let coordinator = ConversationCatalogCoordinator(
            configuration: environment.configuration,
            database: database,
            scanner: scanner
        )
        let events = CatalogEventProbe()
        let releaseObserver = DispatchSemaphore(value: 0)
        coordinator.start { event in
            events.append(event)
            if event.phase == .started { releaseObserver.wait() }
        }
        let observerEntered = await waitForEvent(
            in: events,
            timeoutNanoseconds: 3_000_000_000
        ) { $0.phase == .started }
        XCTAssertTrue(observerEntered)

        let stopStarted = ScannerCancellationProbe()
        let stopFinished = ScannerCancellationProbe()
        let stopTask = Task.detached(priority: .utility) {
            stopStarted.cancel()
            coordinator.stop()
            stopFinished.cancel()
        }
        let stopDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !stopStarted.isCancelled(),
              DispatchTime.now().uptimeNanoseconds < stopDeadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(stopStarted.isCancelled())
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(
            stopFinished.isCancelled(),
            "stop() must wait for a callback which already began"
        )

        releaseObserver.signal()
        await stopTask.value
        XCTAssertTrue(stopFinished.isCancelled())
        let countAfterStop = events.events.count
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(events.events.count, countAfterStop)
    }

    func testCoordinatorObserverCanSynchronouslyRefreshWithoutScannerLockReentry() async throws {
        let environment = try makeEnvironment("coordinator-observer-refresh")
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let candidate = try makeCandidate(
            environment,
            name: "observer-refresh.jsonl",
            format: .claude,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let registry = ScannerTestRegistry(candidates: [candidate])
        let loader = ScannerTestLoader(
            configuration: environment.configuration,
            registry: registry
        )
        loader.loadDelay = 0.08
        let database = try ConversationIndexDatabase(file: environment.database)
        let scanner = ConversationIndexScanner(
            configuration: environment.configuration,
            catalog: database,
            loader: loader,
            registry: registry,
            availability: ConversationIndexFileSystemAvailability()
        )
        let coordinator = ConversationCatalogCoordinator(
            configuration: environment.configuration,
            database: database,
            scanner: scanner
        )
        let refreshStarted = ScannerCancellationProbe()
        let refreshFinished = ScannerCancellationProbe()
        let errors = ScannerErrorProbe()
        coordinator.start { event in
            guard event.phase == .progress, !refreshStarted.isCancelled() else { return }
            refreshStarted.cancel()
            do {
                try coordinator.refreshNow(files: [candidate.file])
            } catch {
                errors.append(error)
            }
            refreshFinished.cancel()
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !refreshFinished.isCancelled(),
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(refreshStarted.isCancelled())
        XCTAssertTrue(
            refreshFinished.isCancelled(),
            "Observer-triggered refresh must complete instead of re-entering the scanner lock"
        )
        XCTAssertTrue(errors.errors.isEmpty)
        await Task.detached(priority: .utility) { coordinator.stop() }.value
    }

    private func waitForEvent(
        in probe: CatalogEventProbe,
        timeoutNanoseconds: UInt64,
        matching predicate: (ConversationCatalogScanEvent) -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !probe.events.contains(where: predicate),
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return probe.events.contains(where: predicate)
    }

    private struct Environment {
        var root: URL
        var historyRoot: URL
        var directory: HistoryDirectory
        var configuration: HistoryConfiguration
        var database: URL
    }

    private func makeEnvironment(_ name: String) throws -> Environment {
        let root = try HistoryTestSupport.temporaryDirectory(name)
        let historyRoot = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        let configuration = HistoryConfiguration(
            historyDirs: [historyRoot.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports")
        )
        let directory = try XCTUnwrap(
            HistoryPathResolver(configuration: configuration)
                .directories(activeOnly: false)
                .first(where: { $0.id == historyRoot.path })
        )
        return Environment(
            root: root,
            historyRoot: historyRoot,
            directory: directory,
            configuration: configuration,
            database: root.appendingPathComponent("app/scanner.sqlite")
        )
    }

    private func makeCandidate(
        _ environment: Environment,
        name: String,
        format: HistoryTranscriptFormat,
        modifiedAt: Date
    ) throws -> HistoryFileCandidate {
        let project = environment.directory.projectsURL
            .appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent(name)
        try Data(name.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: file.path
        )
        return HistoryFileCandidate(
            file: file,
            projectDirectoryName: "fixture",
            directory: environment.directory,
            formatHint: format
        )
    }

    private func indexedSession(file: URL, scope: String) -> ConversationIndexedSession {
        ConversationIndexedSession(
            metadata: metadata(file: file, scope: scope, source: .claude),
            scope: scope,
            fingerprint: ConversationIndexFingerprint(
                modificationTime: Date(timeIntervalSince1970: 1),
                sizeBytes: 0,
                dependencyFingerprint: "fixture"
            ),
            documents: [
                ConversationIndexDocument(
                    transcriptID: ConversationIndexDocument.mainTranscriptID,
                    sortOrder: 0,
                    text: "fixture"
                ),
            ]
        )
    }
}

private final class ScannerTestRegistry: ConversationIndexSourceRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var candidateStorage: [HistoryFileCandidate]
    private var dependencyStorage: [String: [ConversationSourceDependency]]
    private var impactCandidates: [HistoryFileCandidate]?
    private var impactRequiresDiscovery = false
    private var impactRequiresProjectionRefresh = false
    private var impactCallCount = 0

    init(
        candidates: [HistoryFileCandidate],
        dependencies: [String: [ConversationSourceDependency]] = [:]
    ) {
        candidateStorage = candidates
        dependencyStorage = dependencies
    }

    var eventImpactCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return impactCallCount
    }

    func setImpact(
        candidates: [HistoryFileCandidate],
        requiresDiscovery: Bool,
        requiresProjectionRefresh: Bool = false
    ) {
        lock.lock()
        impactCandidates = candidates
        impactRequiresDiscovery = requiresDiscovery
        impactRequiresProjectionRefresh = requiresProjectionRefresh
        lock.unlock()
    }

    func manifest(
        for candidate: HistoryFileCandidate,
        format: HistoryTranscriptFormat,
        configuration: HistoryConfiguration
    ) throws -> ConversationDependencyManifest {
        lock.lock()
        let dependencies = dependencyStorage[candidate.file.standardizedFileURL.path]
        lock.unlock()
        return ConversationDependencyManifest(
            candidate: candidate,
            source: Self.source(for: format),
            dependencies: dependencies ?? [
                .init(
                    file: candidate.file,
                    role: format == .antigravity ? .primaryDatabase : .primaryTranscript
                ),
            ]
        )
    }

    func discoverCandidates(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return candidateStorage
    }

    func eventImpact(
        _ eventFiles: [URL],
        knownManifests: [ConversationDependencyManifest],
        configuration: HistoryConfiguration
    ) -> ConversationSourceEventImpact {
        lock.lock()
        defer { lock.unlock() }
        impactCallCount += 1
        return ConversationSourceEventImpact(
            candidates: impactCandidates ?? candidateStorage.filter { candidate in
                eventFiles.contains {
                    $0.standardizedFileURL.path == candidate.file.standardizedFileURL.path
                }
            },
            requiresDiscovery: impactRequiresDiscovery,
            requiresProjectionRefresh: impactRequiresProjectionRefresh
        )
    }

    private static func source(for format: HistoryTranscriptFormat) -> HistorySource {
        switch format {
        case .claude: .claude
        case .codex: .codex
        case .qoder: .qoder
        case .grok: .grok
        case .copilot: .copilot
        case .antigravity: .antigravity
        }
    }
}

private final class ScannerTestLoader: HistorySessionLoading, @unchecked Sendable {
    private let configuration: HistoryConfiguration
    private let registry: ScannerTestRegistry
    private let providesQuickMetadata: Bool
    private let lock = NSLock()
    private var prefetchStorage: [[String]] = []
    private var quickMetadataStorage: [[String]] = []
    private var loadStorage: [String] = []
    private var dependencyFailures: [String: Int] = [:]
    private var activeLoads = 0
    private var maximumActiveLoads = 0
    private var delay: TimeInterval = 0

    init(
        configuration: HistoryConfiguration,
        registry: ScannerTestRegistry,
        providesQuickMetadata: Bool = false
    ) {
        self.configuration = configuration
        self.registry = registry
        self.providesQuickMetadata = providesQuickMetadata
    }

    var prefetchBatches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return prefetchStorage
    }

    var loadPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadStorage
    }

    var quickMetadataBatches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return quickMetadataStorage
    }

    var maximumConcurrentLoads: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveLoads
    }

    var loadDelay: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return delay
        }
        set {
            lock.lock()
            delay = newValue
            lock.unlock()
        }
    }

    func resetObservations() {
        lock.lock()
        prefetchStorage.removeAll()
        quickMetadataStorage.removeAll()
        loadStorage.removeAll()
        maximumActiveLoads = activeLoads
        lock.unlock()
    }

    func failForDependencyChanges(path: String, count: Int) {
        lock.lock()
        dependencyFailures[URL(fileURLWithPath: path).standardizedFileURL.path] = max(0, count)
        lock.unlock()
    }

    func prefetch(_ candidates: [HistoryFileCandidate]) {
        lock.lock()
        prefetchStorage.append(candidates.map { $0.file.standardizedFileURL.path })
        lock.unlock()
    }

    func loadQuickMetadata(
        _ candidates: [HistoryFileCandidate]
    ) -> [QuickLoadedHistorySession] {
        lock.lock()
        quickMetadataStorage.append(candidates.map { $0.file.standardizedFileURL.path })
        lock.unlock()
        guard providesQuickMetadata else { return [] }

        return candidates.compactMap { candidate in
            let format = candidate.formatHint ?? .claude
            guard let manifest = try? registry.manifest(
                for: candidate,
                format: format,
                configuration: configuration
            ) else { return nil }
            var value = metadata(
                file: candidate.file,
                scope: candidate.directory.id,
                source: manifest.source
            )
            value.title = "Quick \(candidate.file.lastPathComponent)"
            value.autoTitle = value.title
            return QuickLoadedHistorySession(
                candidate: candidate,
                metadata: value,
                manifest: manifest,
                dependencySnapshot: manifest.snapshot()
            )
        }
    }

    func load(
        _ candidate: HistoryFileCandidate,
        consistency: HistorySessionLoadConsistency
    ) throws -> LoadedHistorySession {
        let path = candidate.file.standardizedFileURL.path
        let shouldFail: Bool
        let loadDelay: TimeInterval
        lock.lock()
        loadStorage.append(path)
        activeLoads += 1
        maximumActiveLoads = max(maximumActiveLoads, activeLoads)
        let failures = dependencyFailures[path, default: 0]
        shouldFail = failures > 0
        if shouldFail { dependencyFailures[path] = failures - 1 }
        loadDelay = delay
        lock.unlock()
        defer {
            lock.lock()
            activeLoads -= 1
            lock.unlock()
        }

        if loadDelay > 0 { Thread.sleep(forTimeInterval: loadDelay) }
        if shouldFail { throw HistorySessionLoadError.dependenciesChanged(candidate.file) }
        let format = candidate.formatHint ?? .claude
        let manifest = try registry.manifest(
            for: candidate,
            format: format,
            configuration: configuration
        )
        let source = manifest.source
        let session = HistorySession(
            metadata: metadata(file: candidate.file, scope: candidate.directory.id, source: source),
            messages: [
                HistoryMessage(
                    role: "user",
                    content: [.init(type: "text", text: candidate.file.lastPathComponent)]
                ),
            ]
        )
        return LoadedHistorySession(
            session: session,
            projection: HistoryCatalogProjection(session: session),
            manifest: manifest,
            dependencySnapshot: manifest.snapshot()
        )
    }
}

private final class ScannerErrorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}

private final class ScannerProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversationIndexScanResult] = []

    var results: [ConversationIndexScanResult] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ result: ConversationIndexScanResult) {
        lock.lock()
        storage.append(result)
        lock.unlock()
    }
}

private final class ScannerCancellationProbe: @unchecked Sendable {
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

private final class WatcherStartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeds = false
    private var attempts = 0

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func allowSuccess() {
        lock.lock()
        succeeds = true
        lock.unlock()
    }

    func start(_ watcher: ConversationHistoryWatcher) -> Bool {
        lock.lock()
        attempts += 1
        let shouldStart = succeeds
        lock.unlock()
        return shouldStart && watcher.start()
    }
}

private final class CatalogEventProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var storage: [ConversationCatalogScanEvent] = []

    var events: [ConversationCatalogScanEvent] {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }

    func append(_ event: ConversationCatalogScanEvent) {
        condition.lock()
        storage.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func waitForEvent(
        timeout: TimeInterval,
        matching predicate: (ConversationCatalogScanEvent) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !storage.contains(where: predicate), condition.wait(until: deadline) {}
        return storage.contains(where: predicate)
    }
}

private struct ScannerCatalogFailure: LocalizedError {
    var errorDescription: String? { "fixture catalog failure" }
}

private final class ScannerRecordingCatalog:
    ConversationIndexScanStoring, @unchecked Sendable {
    enum Mutation: Equatable {
        case metadata([String])
        case full(String)
    }

    private let database: ConversationIndexDatabase
    private let lock = NSLock()
    private var mutationStorage: [Mutation] = []

    init(database: ConversationIndexDatabase) {
        self.database = database
    }

    var mutations: [Mutation] {
        lock.lock()
        defer { lock.unlock() }
        return mutationStorage
    }

    var metadataBatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mutationStorage.reduce(into: 0) { count, mutation in
            if case .metadata = mutation { count += 1 }
        }
    }

    var metadataBatchSizes: [Int] {
        mutations.compactMap { mutation in
            guard case .metadata(let paths) = mutation else { return nil }
            return paths.count
        }
    }

    func resetMutations() {
        lock.lock()
        mutationStorage.removeAll()
        lock.unlock()
    }

    func scannerEntries() throws -> [ConversationIndexEntry] {
        try database.listEntries(deleted: nil, limit: .max)
    }

    func generation() throws -> Int64 {
        try database.generation()
    }

    func replace(_ session: ConversationIndexedSession) throws -> Int64 {
        let revision = try database.replace(session)
        lock.lock()
        mutationStorage.append(.full(session.metadata.file.standardizedFileURL.path))
        lock.unlock()
        return revision
    }

    func replaceMetadata(_ sessions: [ConversationIndexedSession]) throws -> Int64 {
        let revision = try database.replaceMetadata(sessions)
        lock.lock()
        mutationStorage.append(.metadata(
            sessions.map { $0.metadata.file.standardizedFileURL.path }
        ))
        lock.unlock()
        return revision
    }

    func invalidateProjection() throws -> Int64 {
        try database.invalidateProjection()
    }

    func reconcile(
        scope: String,
        seenPaths: Set<String>,
        allowEmpty: Bool
    ) throws -> ConversationIndexReconciliation {
        try database.reconcile(scope: scope, seenPaths: seenPaths, allowEmpty: allowEmpty)
    }
}

private final class ScannerMaintenanceProbeCatalog:
    ConversationIndexScanStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var maintenanceInvocations = 0

    var maintenanceInvocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maintenanceInvocations
    }

    func scannerEntries() throws -> [ConversationIndexEntry] { [] }
    func generation() throws -> Int64 { 0 }
    func replace(_ session: ConversationIndexedSession) throws -> Int64 { 0 }
    func invalidateProjection() throws -> Int64 { 0 }

    func finishFullScanMaintenance(
        isCancelled: ConversationIndexScanCancellation
    ) throws {
        lock.lock()
        maintenanceInvocations += 1
        lock.unlock()
    }

    func reconcile(
        scope: String,
        seenPaths: Set<String>,
        allowEmpty: Bool
    ) throws -> ConversationIndexReconciliation {
        ConversationIndexReconciliation(removedPaths: [], generation: 0)
    }
}

private final class ScannerFailingCatalog: ConversationIndexScanStoring, @unchecked Sendable {
    func scannerEntries() throws -> [ConversationIndexEntry] { throw ScannerCatalogFailure() }
    func generation() throws -> Int64 { 0 }
    func replace(_ session: ConversationIndexedSession) throws -> Int64 {
        throw ScannerCatalogFailure()
    }
    func invalidateProjection() throws -> Int64 { throw ScannerCatalogFailure() }
    func finishFullScanMaintenance(
        isCancelled: ConversationIndexScanCancellation
    ) throws {
        throw ScannerCatalogFailure()
    }
    func reconcile(
        scope: String,
        seenPaths: Set<String>,
        allowEmpty: Bool
    ) throws -> ConversationIndexReconciliation {
        throw ScannerCatalogFailure()
    }
}

private func metadata(
    file: URL,
    scope: String,
    source: HistorySource
) -> HistorySessionMetadata {
    HistorySessionMetadata(
        id: "\(source.rawValue):\(file.lastPathComponent)",
        file: file.standardizedFileURL,
        source: source,
        dirID: scope,
        dirLabel: scope,
        sessionID: file.deletingPathExtension().lastPathComponent,
        project: "fixture",
        title: file.lastPathComponent,
        autoTitle: file.lastPathComponent,
        createdAt: Date(timeIntervalSince1970: 1),
        lastActivity: Date(timeIntervalSince1970: 1),
        sizeBytes: 0
    )
}
