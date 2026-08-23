import Foundation

/// Serializes initial reconciliation, FSEvents updates, and explicit mutation refreshes.
///
/// A full scan and an incremental scan can therefore never commit out of order. The coordinator
/// is intentionally a small lifecycle shell around the synchronous scanner: views subscribe only
/// to completed catalog generations and never observe partially rebuilt state.
final class ConversationCatalogCoordinator: @unchecked Sendable {
    let scanner: ConversationIndexScanner

    private let workerQueue = DispatchQueue(
        label: "dev.ccbud.conversation-catalog-coordinator",
        qos: .utility
    )
    private let workerQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private var running = false
    private var watcher: ConversationHistoryWatcher?
    private var watchedRootPaths = Set<String>()
    private var revisionObserver: (@Sendable (Int64) -> Void)?

    init(
        configuration: HistoryConfiguration,
        database: ConversationIndexDatabase,
        loader: (any HistorySessionLoading)? = nil,
        scanner: ConversationIndexScanner? = nil
    ) {
        if let scanner {
            self.scanner = scanner
        } else if let loader {
            self.scanner = ConversationIndexScanner(
                configuration: configuration,
                catalog: database,
                loader: loader,
                registry: ConversationSourceAdapterRegistry(),
                availability: ConversationIndexFileSystemAvailability()
            )
        } else {
            self.scanner = ConversationIndexScanner(
                configuration: configuration,
                database: database
            )
        }
        workerQueue.setSpecific(key: workerQueueKey, value: 1)
    }

    /// Starts watching before the initial reconciliation is queued, so writes which arrive during
    /// a cold scan are delivered behind it on the same serial queue instead of being lost.
    func start(onRevision: @escaping @Sendable (Int64) -> Void) {
        stateLock.lock()
        revisionObserver = onRevision
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        let roots = scanner.watchRoots
        let watcher = ConversationHistoryWatcher(
            roots: roots,
            callbackQueue: workerQueue
        ) { [weak self] event in
            self?.handle(event)
        }
        self.watcher = watcher
        watchedRootPaths = Set(roots.map { $0.standardizedFileURL.path })
        _ = watcher?.start()
        stateLock.unlock()

        workerQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            do {
                let result = try self.scanner.scanAll()
                guard self.isRunning else { return }
                self.finishBackgroundScan(result)
            } catch {
                // The index is disposable and the raw-file detail path remains available. A later
                // watcher event, explicit mutation, or activation performs another reconciliation.
            }
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        revisionObserver = nil
        let watcher = self.watcher
        self.watcher = nil
        watchedRootPaths.removeAll()
        stateLock.unlock()
        watcher?.stop()
    }

    /// Synchronous barrier used after imports and destructive mutations.
    func reconcileNow() throws {
        let result = try onWorkerQueue { try scanner.scanAll() }
        finishBackgroundScan(result)
    }

    /// Synchronous barrier used after a known transcript or metadata sidecar mutation.
    func refreshNow(files: [URL]) throws {
        let paths = Self.unique(files)
        guard !paths.isEmpty else { return }
        let result = try onWorkerQueue {
            try scanner.scan(changedPaths: paths, forceDiscovery: false)
        }
        finishBackgroundScan(result)
    }

    deinit {
        stop()
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func handle(_ event: ConversationHistoryWatchEvent) {
        guard isRunning else { return }
        do {
            let result: ConversationIndexScanResult
            if event.requiresFullRescan {
                result = try scanner.scanAll()
            } else {
                result = try scanner.scan(
                    changedPaths: event.changedPaths,
                    forceDiscovery: !event.rootChanges.isEmpty
                )
            }
            guard isRunning else { return }
            finishBackgroundScan(result)
        } catch {
            // A later debounced event or foreground mutation retries. Never replace a valid warm
            // catalog with an error or fall through to producer-file writes.
        }
    }

    private func publish(_ result: ConversationIndexScanResult) {
        guard result.hasChanges else { return }
        stateLock.lock()
        let observer = revisionObserver
        stateLock.unlock()
        observer?(result.generation)
    }

    /// Manifests discovered by the first scan can add dependencies outside the configured trees,
    /// such as Codex state databases and CC Buddy metadata sidecars. Re-arm the watcher and queue
    /// one cheap fingerprint-verification pass so a write during that first-scan window is covered.
    private func finishBackgroundScan(_ result: ConversationIndexScanResult) {
        let rootsChanged = rearmWatcherIfNeeded()
        publish(result)
        guard rootsChanged else { return }
        workerQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            do {
                let verification = try self.scanner.scanAll()
                guard self.isRunning else { return }
                self.finishBackgroundScan(verification)
            } catch {
                // A later event performs the same stable-fingerprint verification.
            }
        }
    }

    private func rearmWatcherIfNeeded() -> Bool {
        let roots = scanner.watchRoots
        let paths = Set(roots.map { $0.standardizedFileURL.path })

        stateLock.lock()
        guard running, paths != watchedRootPaths else {
            stateLock.unlock()
            return false
        }
        let replacement = ConversationHistoryWatcher(
            roots: roots,
            callbackQueue: workerQueue
        ) { [weak self] event in
            self?.handle(event)
        }
        let previous = watcher
        watcher = replacement
        watchedRootPaths = paths
        _ = replacement?.start()
        stateLock.unlock()

        // Start the replacement first to avoid an uncovered interval between streams.
        previous?.stop()
        return true
    }

    private func onWorkerQueue<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: workerQueueKey) != nil { return try work() }
        return try workerQueue.sync(execute: work)
    }

    private static func unique(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.compactMap { file in
            let value = file.standardizedFileURL
            return seen.insert(value.path).inserted ? value : nil
        }
    }
}
