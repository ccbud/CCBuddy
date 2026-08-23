import Foundation

struct ConversationIndexScanResult: Equatable, Sendable {
    var discovered: Int = 0
    var metadataPublished: Int = 0
    var parsed: Int = 0
    var unchanged: Int = 0
    var removed: Int = 0
    var failed: Int = 0
    var generation: Int64 = 0

    var hasChanges: Bool { metadataPublished > 0 || parsed > 0 || removed > 0 }

    var completed: Int { parsed + unchanged + failed }
}

typealias ConversationIndexScanProgress = @Sendable (ConversationIndexScanResult) -> Void
typealias ConversationIndexScanCancellation = @Sendable () -> Bool

struct ConversationIndexScopeAvailabilityToken: Equatable, Sendable {
    var directoryIdentities: [String]
    var availableDiscoveryRoots: [String] = []
    var missingDiscoveryRoots: [String] = []
}

/// A scope may be reconciled only when the same non-nil token is observed immediately before and
/// after discovery. A missing root, an unreadable directory, or an atomic root replacement thus
/// retains the warm catalog instead of turning a transient filesystem failure into data loss.
protocol ConversationIndexScopeAvailabilityChecking: Sendable {
    func token(for directory: HistoryDirectory) -> ConversationIndexScopeAvailabilityToken?
}

struct ConversationIndexFileSystemAvailability: ConversationIndexScopeAvailabilityChecking,
    @unchecked Sendable {
    private let fileManager: FileManager
    private let maximumDepth: Int

    init(fileManager: FileManager = FileManager(), maximumDepth: Int = 8) {
        self.fileManager = fileManager
        self.maximumDepth = max(1, maximumDepth)
    }

    func token(for directory: HistoryDirectory) -> ConversationIndexScopeAvailabilityToken? {
        let base = directory.baseURL.standardizedFileURL
        guard let baseIdentity = directoryIdentity(base, rejectSymbolicLink: false),
              let baseChildren = directoryContents(base) else { return nil }

        var identities = [baseIdentity]
        var availableRoots: [String] = []
        var missingRoots: [String] = []
        let children = Set(baseChildren.map { $0.standardizedFileURL.path })
        for root in Self.discoveryRoots(for: directory) {
            let root = root.standardizedFileURL
            guard fileManager.fileExists(atPath: root.path) else {
                // If enumeration observed the name but a later stat did not, the tree changed
                // during the proof. Treat it as unavailable rather than a stable missing root.
                guard !children.contains(root.path) else { return nil }
                identities.append(root.path + "|missing")
                missingRoots.append(root.path)
                continue
            }
            guard collectDirectoryIdentities(
                root,
                depth: 0,
                identities: &identities
            ) else { return nil }
            availableRoots.append(root.path)
        }
        return ConversationIndexScopeAvailabilityToken(
            directoryIdentities: identities.sorted(),
            availableDiscoveryRoots: availableRoots.sorted(),
            missingDiscoveryRoots: missingRoots.sorted()
        )
    }

    private static func discoveryRoots(for directory: HistoryDirectory) -> [URL] {
        [
            directory.projectsURL,
            directory.sessionsURL,
            directory.baseURL.appendingPathComponent("archived_sessions", isDirectory: true),
            directory.baseURL.appendingPathComponent("session-state", isDirectory: true),
            directory.baseURL.appendingPathComponent("conversations", isDirectory: true),
        ]
    }

    private func collectDirectoryIdentities(
        _ directory: URL,
        depth: Int,
        identities: inout [String]
    ) -> Bool {
        guard let identity = directoryIdentity(directory, rejectSymbolicLink: true),
              let children = directoryContents(directory) else { return false }
        identities.append(identity)
        guard depth < maximumDepth else { return true }

        for child in children {
            guard let attributes = try? fileManager.attributesOfItem(atPath: child.path),
                  let type = attributes[.type] as? FileAttributeType else { return false }
            switch type {
            case .typeDirectory:
                guard collectDirectoryIdentities(
                    child,
                    depth: depth + 1,
                    identities: &identities
                ) else { return false }
            case .typeSymbolicLink:
                // Discovery intentionally skips linked descendants. Their presence is stable
                // scope state, but their target must never participate in availability.
                identities.append(child.standardizedFileURL.path + "|symlink")
            default:
                continue
            }
        }
        return true
    }

    private func directoryIdentity(
        _ directory: URL,
        rejectSymbolicLink: Bool
    ) -> String? {
        let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rejectSymbolicLink, values?.isSymbolicLink == true { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeDirectory else { return nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        return [
            directory.standardizedFileURL.path,
            device.map(String.init) ?? "?",
            inode.map(String.init) ?? "?",
            modified.map { String(format: "%.9f", $0) } ?? "?",
        ].joined(separator: "|")
    }

    private func directoryContents(_ directory: URL) -> [URL]? {
        try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.path < $1.path }
    }
}

protocol ConversationIndexScanStoring: Sendable {
    func scannerEntries() throws -> [ConversationIndexEntry]
    func generation() throws -> Int64
    @discardableResult func replace(_ session: ConversationIndexedSession) throws -> Int64
    @discardableResult func replaceMetadata(_ sessions: [ConversationIndexedSession]) throws -> Int64
    @discardableResult func invalidateProjection() throws -> Int64
    func reconcile(
        scope: String,
        seenPaths: Set<String>,
        allowEmpty: Bool
    ) throws -> ConversationIndexReconciliation
}

extension ConversationIndexScanStoring {
    @discardableResult
    func replaceMetadata(_ sessions: [ConversationIndexedSession]) throws -> Int64 {
        var revision = try generation()
        for session in sessions { revision = try replace(session) }
        return revision
    }
}

extension ConversationIndexDatabase: ConversationIndexScanStoring {
    func scannerEntries() throws -> [ConversationIndexEntry] {
        try listEntries(deleted: nil, limit: .max)
    }
}

protocol ConversationIndexSourceRegistering: Sendable {
    func manifest(
        for candidate: HistoryFileCandidate,
        format: HistoryTranscriptFormat,
        configuration: HistoryConfiguration
    ) throws -> ConversationDependencyManifest
    func discoverCandidates(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate]
    func eventImpact(
        _ eventFiles: [URL],
        knownManifests: [ConversationDependencyManifest],
        configuration: HistoryConfiguration
    ) -> ConversationSourceEventImpact
}

extension ConversationSourceAdapterRegistry: ConversationIndexSourceRegistering {}

/// Synchronous scanner used from the coordinator's detached worker.
///
/// One lock covers discovery, parsing, replacement, and reconciliation. Concurrent full scans and
/// watcher scans therefore queue instead of interleaving catalog generations or publishing stale
/// manifests. Producer files are never mutated; every successful projection replacement is one
/// database transaction.
final class ConversationIndexScanner: @unchecked Sendable {
    private struct Discovery {
        var candidates: [HistoryFileCandidate]
        var directories: [HistoryDirectory]
        var availabilityBefore: [String: ConversationIndexScopeAvailabilityToken]
    }

    private let configuration: HistoryConfiguration
    private let catalog: any ConversationIndexScanStoring
    private let loader: any HistorySessionLoading
    private let registry: any ConversationIndexSourceRegistering
    private let availability: any ConversationIndexScopeAvailabilityChecking
    private let fileManager: FileManager
    private let scanLock = NSLock()

    private var manifestsByPath: [String: ConversationDependencyManifest] = [:]
    private var lastGeneration: Int64

    init(
        configuration: HistoryConfiguration,
        database: ConversationIndexDatabase,
        qoderReader: QoderFileReader = .shared,
        registry: ConversationSourceAdapterRegistry = .init(),
        fileManager: FileManager = FileManager()
    ) {
        self.configuration = configuration
        catalog = database
        loader = HistorySessionLoader(
            configuration: configuration,
            qoderReader: qoderReader,
            adapters: registry
        )
        self.registry = registry
        availability = ConversationIndexFileSystemAvailability(fileManager: fileManager)
        self.fileManager = fileManager
        lastGeneration = (try? database.generation()) ?? 0
    }

    init(
        configuration: HistoryConfiguration,
        database: ConversationIndexDatabase,
        loader: any HistorySessionLoading,
        registry: ConversationSourceAdapterRegistry = .init(),
        availability: (any ConversationIndexScopeAvailabilityChecking)? = nil,
        fileManager: FileManager = FileManager()
    ) {
        self.configuration = configuration
        catalog = database
        self.loader = loader
        self.registry = registry
        self.availability = availability
            ?? ConversationIndexFileSystemAvailability(fileManager: fileManager)
        self.fileManager = fileManager
        lastGeneration = (try? database.generation()) ?? 0
    }

    init(
        configuration: HistoryConfiguration,
        catalog: any ConversationIndexScanStoring,
        loader: any HistorySessionLoading,
        registry: any ConversationIndexSourceRegistering,
        availability: any ConversationIndexScopeAvailabilityChecking,
        fileManager: FileManager = FileManager()
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.loader = loader
        self.registry = registry
        self.availability = availability
        self.fileManager = fileManager
        lastGeneration = (try? catalog.generation()) ?? 0
    }

    var manifests: [ConversationDependencyManifest] {
        withScanLock {
            manifestsByPath.values.sorted {
                Self.path(of: $0.candidate) < Self.path(of: $1.candidate)
            }
        }
    }

    /// Includes configured producer trees plus dependency files outside those trees (for example
    /// Codex state SQLite and CCBuddy metadata sidecars). The watcher accepts missing/file paths
    /// and anchors them at their nearest existing parent.
    var watchRoots: [URL] {
        withScanLock { watchRootsWithoutLock() }
    }

    var generation: Int64 {
        withScanLock { lastGeneration }
    }

    func scanAll(
        onProgress: ConversationIndexScanProgress? = nil,
        isCancelled: ConversationIndexScanCancellation = { false }
    ) throws -> ConversationIndexScanResult {
        try withScanLock {
            try scanAllWithoutLock(
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        }
    }

    /// Applies a watcher batch. `eventImpact` selects already-known owners; discovery additionally
    /// finds new candidates and safely reconciles deletions. `forceDiscovery` does not force every
    /// unchanged transcript to parse—use `scanAll()` for a dropped-event full verification.
    func scan(
        changedPaths: [URL],
        forceDiscovery: Bool = false,
        onProgress: ConversationIndexScanProgress? = nil,
        isCancelled: ConversationIndexScanCancellation = { false }
    ) throws -> ConversationIndexScanResult {
        try withScanLock {
            try scanChangedPathsWithoutLock(
                changedPaths.map(\.standardizedFileURL),
                forceDiscovery: forceDiscovery,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        }
    }

    private func scanAllWithoutLock(
        onProgress: ConversationIndexScanProgress?,
        isCancelled: ConversationIndexScanCancellation
    ) throws -> ConversationIndexScanResult {
        try Self.checkCancellation(isCancelled)
        let discovery = beginDiscovery()
        try Self.checkCancellation(isCancelled)
        var result = ConversationIndexScanResult(
            discovered: discovery.candidates.count,
            generation: lastGeneration
        )
        var entriesByPath = try indexedEntriesByPath()
        let ordered = Self.scanOrder(
            Self.unique(discovery.candidates),
            activeScope: configuration.active
        )
        try Self.checkCancellation(isCancelled)
        try publishQuickMetadata(
            ordered,
            entriesByPath: &entriesByPath,
            result: &result,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        try Self.checkCancellation(isCancelled)
        loader.prefetch(ordered)
        try Self.checkCancellation(isCancelled)
        try process(
            ordered,
            entriesByPath: &entriesByPath,
            result: &result,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        try reconcile(
            discovery,
            entriesByPath: &entriesByPath,
            result: &result,
            onProgress: onProgress,
            isCancelled: isCancelled,
            purgeUnconfiguredScopes: true
        )
        try Self.checkCancellation(isCancelled)
        result.generation = try catalog.generation()
        lastGeneration = result.generation
        return result
    }

    private func scanChangedPathsWithoutLock(
        _ changedPaths: [URL],
        forceDiscovery: Bool,
        onProgress: ConversationIndexScanProgress?,
        isCancelled: ConversationIndexScanCancellation
    ) throws -> ConversationIndexScanResult {
        try Self.checkCancellation(isCancelled)
        let knownManifests = manifestsByPath.values.sorted {
            Self.path(of: $0.candidate) < Self.path(of: $1.candidate)
        }
        let impact = registry.eventImpact(
            changedPaths,
            knownManifests: knownManifests,
            configuration: configuration
        )
        let shouldDiscover = forceDiscovery || impact.requiresDiscovery
        let discovery = shouldDiscover ? beginDiscovery() : nil
        try Self.checkCancellation(isCancelled)
        var entriesByPath = try indexedEntriesByPath()

        let work: [HistoryFileCandidate]
        if let discovery {
            let discoveredByPath = Dictionary(
                uniqueKeysWithValues: Self.unique(discovery.candidates).map {
                    (Self.path(of: $0), $0)
                }
            )
            let impactedPaths = Set(impact.candidates.map(Self.path))
            var paths = impactedPaths
            paths.formUnion(discoveredByPath.keys.filter { entriesByPath[$0] == nil })
            work = paths.sorted().compactMap { discoveredByPath[$0] }
        } else {
            work = Self.unique(impact.candidates)
        }

        var result = ConversationIndexScanResult(
            // Incremental progress describes the candidates actually processed, not every
            // transcript observed while discovering additions and deletions.
            discovered: work.count,
            generation: lastGeneration
        )
        let ordered = Self.newestFirst(work)
        try Self.checkCancellation(isCancelled)
        try publishQuickMetadata(
            ordered,
            entriesByPath: &entriesByPath,
            result: &result,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        try Self.checkCancellation(isCancelled)
        loader.prefetch(ordered)
        try Self.checkCancellation(isCancelled)
        try process(
            ordered,
            entriesByPath: &entriesByPath,
            result: &result,
            onProgress: onProgress,
            isCancelled: isCancelled
        )
        if let discovery {
            try reconcile(
                discovery,
                entriesByPath: &entriesByPath,
                result: &result,
                onProgress: onProgress,
                isCancelled: isCancelled,
                purgeUnconfiguredScopes: false
            )
        }
        try Self.checkCancellation(isCancelled)
        if impact.requiresProjectionRefresh {
            let projectionGeneration = try catalog.invalidateProjection()
            lastGeneration = projectionGeneration
            result.generation = projectionGeneration
            onProgress?(result)
        }
        try Self.checkCancellation(isCancelled)
        result.generation = try catalog.generation()
        lastGeneration = result.generation
        return result
    }

    private func beginDiscovery() -> Discovery {
        let resolver = HistoryPathResolver(configuration: configuration)
        let directories = resolver.directories(activeOnly: false)
        var availabilityBefore: [String: ConversationIndexScopeAvailabilityToken] = [:]
        for directory in directories {
            availabilityBefore[directory.id] = availability.token(for: directory)
        }
        return Discovery(
            candidates: registry.discoverCandidates(
                configuration: configuration,
                activeOnly: false
            ),
            directories: directories,
            availabilityBefore: availabilityBefore
        )
    }

    private func process(
        _ candidates: [HistoryFileCandidate],
        entriesByPath: inout [String: ConversationIndexEntry],
        result: inout ConversationIndexScanResult,
        onProgress: ConversationIndexScanProgress?,
        isCancelled: ConversationIndexScanCancellation
    ) throws {
        for candidate in candidates {
            try Self.checkCancellation(isCancelled)
            let path = Self.path(of: candidate)
            let entry = entriesByPath[path]
            if let preflight = preflight(candidate, entry: entry),
               entry?.fingerprint == preflight.fingerprint,
               entry?.scope == candidate.directory.id {
                manifestsByPath[path] = preflight.manifest
                result.unchanged += 1
                onProgress?(result)
                continue
            }

            let loaded: LoadedHistorySession
            do {
                loaded = try loadRetryingDependencyChange(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failed += 1
                onProgress?(result)
                continue
            }
            try Self.checkCancellation(isCancelled)
            guard let fingerprint = Self.fingerprint(
                manifest: loaded.manifest,
                snapshot: loaded.dependencySnapshot
            ) else {
                result.failed += 1
                onProgress?(result)
                continue
            }

            let indexed = ConversationIndexedSession(
                projection: loaded.projection,
                scope: candidate.directory.id,
                fingerprint: fingerprint
            )
            try Self.checkCancellation(isCancelled)
            let replacementGeneration = try catalog.replace(indexed)
            lastGeneration = replacementGeneration
            result.generation = replacementGeneration
            entriesByPath[path] = ConversationIndexEntry(
                sourcePath: path,
                metadata: loaded.projection.metadata,
                scope: candidate.directory.id,
                fingerprint: fingerprint,
                indexedAt: Date()
            )
            manifestsByPath[path] = loaded.manifest
            result.parsed += 1
            onProgress?(result)
        }
    }

    /// Mirrors Wake's quickMeta contract: changed candidates become visible in bounded batches
    /// before any transcript is fully parsed. The sentinel fingerprint can never equal the source
    /// snapshot, so a failed or cancelled full parse remains visible but retryable on the next pass.
    private func publishQuickMetadata(
        _ candidates: [HistoryFileCandidate],
        entriesByPath: inout [String: ConversationIndexEntry],
        result: inout ConversationIndexScanResult,
        onProgress: ConversationIndexScanProgress?,
        isCancelled: ConversationIndexScanCancellation
    ) throws {
        let changed = candidates.filter { candidate in
            let entry = entriesByPath[Self.path(of: candidate)]
            guard let preflight = preflight(candidate, entry: entry) else { return true }
            return entry?.fingerprint != preflight.fingerprint
                || entry?.scope != candidate.directory.id
        }
        guard !changed.isEmpty else { return }

        let batches = Self.quickMetadataBatches(
            changed,
            activeScope: configuration.active
        )
        for requested in batches {
            try Self.checkCancellation(isCancelled)
            let requestedPaths = Set(requested.map(Self.path))
            let loaded = loader.loadQuickMetadata(requested)

            var replacements: [ConversationIndexedSession] = []
            var accepted: [(QuickLoadedHistorySession, ConversationIndexFingerprint)] = []
            var seen = Set<String>()
            for quick in loaded {
                let path = Self.path(of: quick.candidate)
                guard requestedPaths.contains(path), seen.insert(path).inserted,
                      quick.metadata.file.standardizedFileURL.path == path,
                      let sourceFingerprint = Self.fingerprint(
                        manifest: quick.manifest,
                        snapshot: quick.dependencySnapshot
                      ) else { continue }
                let sentinel = ConversationIndexFingerprint(
                    modificationTime: Date(timeIntervalSince1970: 0),
                    sizeBytes: sourceFingerprint.sizeBytes,
                    dependencyFingerprint: "quick:\(sourceFingerprint.dependencyFingerprint ?? "")"
                )
                replacements.append(ConversationIndexedSession(
                    metadata: quick.metadata,
                    scope: quick.candidate.directory.id,
                    fingerprint: sentinel,
                    documents: []
                ))
                accepted.append((quick, sentinel))
            }
            guard !replacements.isEmpty else { continue }

            try Self.checkCancellation(isCancelled)
            let revision = try catalog.replaceMetadata(replacements)
            lastGeneration = revision
            result.generation = revision
            result.metadataPublished += replacements.count
            let indexedAt = Date()
            for (quick, fingerprint) in accepted {
                let path = Self.path(of: quick.candidate)
                entriesByPath[path] = ConversationIndexEntry(
                    sourcePath: path,
                    metadata: quick.metadata,
                    scope: quick.candidate.directory.id,
                    fingerprint: fingerprint,
                    indexedAt: indexedAt
                )
                manifestsByPath[path] = quick.manifest
            }
            onProgress?(result)
        }
    }

    private func loadRetryingDependencyChange(
        _ candidate: HistoryFileCandidate
    ) throws -> LoadedHistorySession {
        do {
            return try loader.load(candidate, consistency: .dependencyStable)
        } catch HistorySessionLoadError.dependenciesChanged {
            return try loader.load(candidate, consistency: .dependencyStable)
        }
    }

    private func preflight(
        _ candidate: HistoryFileCandidate,
        entry: ConversationIndexEntry?
    ) -> (
        manifest: ConversationDependencyManifest,
        fingerprint: ConversationIndexFingerprint
    )? {
        let path = Self.path(of: candidate)
        let format = candidate.formatHint
            ?? manifestsByPath[path].flatMap { Self.format(for: $0.source) }
            ?? entry.flatMap { Self.format(for: $0.metadata.source) }
        guard let format,
              let manifest = try? registry.manifest(
                  for: candidate,
                  format: format,
                  configuration: configuration
              ) else { return nil }
        let snapshot = manifest.snapshot(fileManager: fileManager)
        guard let fingerprint = Self.fingerprint(manifest: manifest, snapshot: snapshot) else {
            return nil
        }
        return (manifest, fingerprint)
    }

    private func reconcile(
        _ discovery: Discovery,
        entriesByPath: inout [String: ConversationIndexEntry],
        result: inout ConversationIndexScanResult,
        onProgress: ConversationIndexScanProgress?,
        isCancelled: ConversationIndexScanCancellation,
        purgeUnconfiguredScopes: Bool
    ) throws {
        let seenByScope = Dictionary(grouping: discovery.candidates, by: { $0.directory.id })
            .mapValues { Set($0.map(Self.path)) }
        for directory in discovery.directories {
            try Self.checkCancellation(isCancelled)
            guard let before = discovery.availabilityBefore[directory.id],
                  let after = availability.token(for: directory),
                  before == after else { continue }
            let indexedInScope = entriesByPath.values.filter { $0.scope == directory.id }
            let availableRoots = after.availableDiscoveryRoots.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            // A producer container which never existed is a valid empty source. Once the catalog
            // has rows beneath it, however, disappearance/unavailability is not proof of deletion.
            // Preserve the entire scope until every indexed primary path still has an available
            // discovery root.
            guard indexedInScope.allSatisfy({ entry in
                let file = URL(fileURLWithPath: entry.sourcePath)
                return availableRoots.contains { Self.contains(file, in: $0) }
            }) else { continue }
            try Self.checkCancellation(isCancelled)
            let reconciliation = try catalog.reconcile(
                scope: directory.id,
                seenPaths: seenByScope[directory.id, default: []],
                allowEmpty: true
            )
            lastGeneration = reconciliation.generation
            result.generation = reconciliation.generation
            result.removed += reconciliation.removedPaths.count
            for path in reconciliation.removedPaths {
                entriesByPath.removeValue(forKey: path)
                manifestsByPath.removeValue(forKey: path)
            }
            if !reconciliation.removedPaths.isEmpty { onProgress?(result) }
        }

        // The database intentionally survives repository recreation so the next scope/config
        // change can render a warm catalog immediately. A completed full scan is also the point at
        // which the current topology becomes authoritative: scopes removed from configuration must
        // not leave transcript text or metadata behind in that shared derived index.
        guard purgeUnconfiguredScopes else { return }
        // Imported sessions always remain a logical scope, even when a configured producer root
        // resolves to the same physical path and HistoryPathResolver deduplicates that directory.
        let configuredScopes = Set(discovery.directories.map(\.id)).union(["__imported__"])
        let unconfiguredScopes = Set(entriesByPath.values.map(\.scope))
            .subtracting(configuredScopes)
            .sorted()
        for scope in unconfiguredScopes {
            try Self.checkCancellation(isCancelled)
            let reconciliation = try catalog.reconcile(
                scope: scope,
                seenPaths: [],
                allowEmpty: true
            )
            lastGeneration = reconciliation.generation
            result.generation = reconciliation.generation
            result.removed += reconciliation.removedPaths.count
            for path in reconciliation.removedPaths {
                entriesByPath.removeValue(forKey: path)
                manifestsByPath.removeValue(forKey: path)
            }
            if !reconciliation.removedPaths.isEmpty { onProgress?(result) }
        }
    }

    private func indexedEntriesByPath() throws -> [String: ConversationIndexEntry] {
        Dictionary(uniqueKeysWithValues: try catalog.scannerEntries().map {
            ($0.sourcePath, $0)
        })
    }

    private func watchRootsWithoutLock() -> [URL] {
        let configured = HistoryPathResolver(configuration: configuration)
            .watchRoots()
            .map(\.standardizedFileURL)
        var result = configured
        var seen = Set(configured.map(\.path))
        for dependency in manifestsByPath.values.flatMap(\.dependencies) {
            let file = dependency.file.standardizedFileURL
            let covered = configured.contains { root in
                Self.contains(file, in: root)
            }
            if !covered, seen.insert(file.path).inserted { result.append(file) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func withScanLock<T>(_ operation: () throws -> T) rethrows -> T {
        scanLock.lock()
        defer { scanLock.unlock() }
        return try operation()
    }

    private static func checkCancellation(
        _ isCancelled: ConversationIndexScanCancellation
    ) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func fingerprint(
        manifest: ConversationDependencyManifest,
        snapshot: ConversationDependencySnapshot
    ) -> ConversationIndexFingerprint? {
        guard let primary = manifest.primary,
              let stamp = snapshot.stamp(for: primary.file, role: primary.role),
              stamp.kind == .regularFile,
              let nanoseconds = stamp.modifiedAtNanoseconds,
              let sizeBytes = stamp.sizeBytes else { return nil }
        return ConversationIndexFingerprint(
            modificationTime: Date(
                timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000
            ),
            sizeBytes: sizeBytes,
            dependencyFingerprint: snapshot.fingerprint
        )
    }

    private static func format(for source: HistorySource) -> HistoryTranscriptFormat? {
        switch source {
        case .claude: .claude
        case .codex: .codex
        case .qoder: .qoder
        case .grok: .grok
        case .copilot: .copilot
        case .antigravity: .antigravity
        }
    }

    private static func unique(
        _ candidates: [HistoryFileCandidate]
    ) -> [HistoryFileCandidate] {
        var result: [HistoryFileCandidate] = []
        var positions: [String: Int] = [:]
        for candidate in candidates {
            let path = Self.path(of: candidate)
            if let position = positions[path] {
                if result[position].formatHint == nil, candidate.formatHint != nil {
                    result[position] = candidate
                }
            } else {
                positions[path] = result.count
                result.append(candidate)
            }
        }
        return result
    }

    private static let quickMetadataBatchSize = 32

    /// Do not hide the selected scope behind unrelated work in the same catalog transaction.
    /// Each partition is still bounded so large active scopes remain cancellation-friendly.
    private static func quickMetadataBatches(
        _ candidates: [HistoryFileCandidate],
        activeScope: String
    ) -> [[HistoryFileCandidate]] {
        let partitions: [[HistoryFileCandidate]]
        if activeScope == "all" || activeScope == "__trash__" {
            partitions = [candidates]
        } else {
            let active = candidates.filter { $0.directory.id == activeScope }
            if active.isEmpty {
                partitions = [candidates]
            } else {
                partitions = [active, candidates.filter { $0.directory.id != activeScope }]
            }
        }

        return partitions.flatMap { partition in
            stride(from: 0, to: partition.count, by: quickMetadataBatchSize).map { start in
                let end = min(start + quickMetadataBatchSize, partition.count)
                return Array(partition[start..<end])
            }
        }
    }

    private static func newestFirst(
        _ candidates: [HistoryFileCandidate]
    ) -> [HistoryFileCandidate] {
        candidates.sorted { left, right in
            let leftStamp = primaryStamp(left)
            let rightStamp = primaryStamp(right)
            if leftStamp != rightStamp { return leftStamp > rightStamp }
            return path(of: left) < path(of: right)
        }
    }

    /// A cold catalog must make the currently selected scope visible before spending time on
    /// newer sessions from unrelated roots. Within each partition we retain the established
    /// newest-first order. `all` and trash keep the global order because they span every scope.
    private static func scanOrder(
        _ candidates: [HistoryFileCandidate],
        activeScope: String
    ) -> [HistoryFileCandidate] {
        let ordered = newestFirst(candidates)
        guard activeScope != "all", activeScope != "__trash__" else { return ordered }
        let active = ordered.filter { $0.directory.id == activeScope }
        guard !active.isEmpty else { return ordered }
        return active + ordered.filter { $0.directory.id != activeScope }
    }

    private static func primaryStamp(_ candidate: HistoryFileCandidate) -> Int64 {
        let dependency = ConversationSourceDependency(
            file: candidate.file,
            role: candidate.formatHint == .antigravity ? .primaryDatabase : .primaryTranscript
        )
        return ConversationDependencyStamp.read(dependency).modifiedAtNanoseconds ?? .min
    }

    private static func path(of candidate: HistoryFileCandidate) -> String {
        candidate.file.standardizedFileURL.path
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return childComponents.count >= parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}
