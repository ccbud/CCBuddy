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

    func setImpact(candidates: [HistoryFileCandidate], requiresDiscovery: Bool) {
        lock.lock()
        impactCandidates = candidates
        impactRequiresDiscovery = requiresDiscovery
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
            requiresDiscovery: impactRequiresDiscovery
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
    private let lock = NSLock()
    private var prefetchStorage: [[String]] = []
    private var loadStorage: [String] = []
    private var dependencyFailures: [String: Int] = [:]
    private var activeLoads = 0
    private var maximumActiveLoads = 0
    private var delay: TimeInterval = 0

    init(configuration: HistoryConfiguration, registry: ScannerTestRegistry) {
        self.configuration = configuration
        self.registry = registry
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
