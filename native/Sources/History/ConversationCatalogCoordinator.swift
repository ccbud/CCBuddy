import Foundation

enum ConversationCatalogWatcherState: Equatable, Sendable {
    case unknown
    case active
    case unavailable(String)
}

struct ConversationCatalogScanEvent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case started
        case progress
        case finished
    }

    var phase: Phase
    var revision: Int64
    var completed: Int
    var total: Int
    var failed: Int
    var errorDescription: String?
    var watcherState: ConversationCatalogWatcherState

    var isTerminal: Bool { phase == .finished }

    static func started(revision: Int64) -> Self {
        Self(
            phase: .started,
            revision: revision,
            completed: 0,
            total: 0,
            failed: 0,
            errorDescription: nil,
            watcherState: .unknown
        )
    }

    static func progress(_ result: ConversationIndexScanResult) -> Self {
        Self(
            phase: .progress,
            revision: result.generation,
            completed: result.completed,
            total: result.discovered,
            failed: result.failed,
            errorDescription: nil,
            watcherState: .unknown
        )
    }

    static func finished(
        _ result: ConversationIndexScanResult,
        errorDescription: String? = nil
    ) -> Self {
        Self(
            phase: .finished,
            revision: result.generation,
            completed: result.completed,
            total: result.discovered,
            failed: result.failed,
            errorDescription: errorDescription,
            watcherState: .unknown
        )
    }
}

/// Serializes initial reconciliation, FSEvents updates, and explicit mutation refreshes.
///
/// A full scan and an incremental scan can therefore never commit out of order. The coordinator
/// is intentionally a small lifecycle shell around the synchronous scanner: views subscribe only
/// to ordered catalog events while every individual row replacement remains transactionally safe.
final class ConversationCatalogCoordinator: @unchecked Sendable {
    typealias WatcherStarter = @Sendable (ConversationHistoryWatcher) -> Bool

    let scanner: ConversationIndexScanner
    private let database: ConversationIndexDatabase

    private let workerQueue = DispatchQueue(
        label: "dev.ccbud.conversation-catalog-coordinator",
        qos: .utility
    )
    private let observerQueue = DispatchQueue(
        label: "dev.ccbud.conversation-catalog-events",
        qos: .utility
    )
    private let workerQueueKey = DispatchSpecificKey<UInt8>()
    private let observerQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private let watcherStarter: WatcherStarter
    private var running = false
    private var runIdentifier: UUID?
    private var watcher: ConversationHistoryWatcher?
    private var watchedRootPaths = Set<String>()
    private var watcherState: ConversationCatalogWatcherState = .unknown
    private var eventObserver: (@Sendable (ConversationCatalogScanEvent) -> Void)?
    private var eventObserverIdentifier: UUID?
    private var currentEvent: ConversationCatalogScanEvent?
    private var currentEventSequence: UInt64 = 0
    private var observerScheduledEventSequence: UInt64?
    private var deferredReparseToken: UUID?

    init(
        configuration: HistoryConfiguration,
        database: ConversationIndexDatabase,
        loader: (any HistorySessionLoading)? = nil,
        scanner: ConversationIndexScanner? = nil,
        watcherStarter: @escaping WatcherStarter = { $0.start() }
    ) {
        self.database = database
        self.watcherStarter = watcherStarter
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
        observerQueue.setSpecific(key: observerQueueKey, value: 1)
    }

    /// Starts watching before the initial reconciliation is queued, so writes which arrive during
    /// a cold scan are delivered behind it on the same serial queue instead of being lost.
    func start(onEvent: @escaping @Sendable (ConversationCatalogScanEvent) -> Void) {
        let observerIdentifier = UUID()
        stateLock.lock()
        eventObserver = onEvent
        eventObserverIdentifier = observerIdentifier
        observerScheduledEventSequence = nil
        guard !running else {
            let runIdentifier = self.runIdentifier
            stateLock.unlock()
            // Complete any callback which already passed its old-observer guard before returning
            // the new subscription. Queued old callbacks observe the new identifier and no-op.
            drainObserverQueue()
            if let runIdentifier {
                queueCurrentEventReplay(
                    runIdentifier: runIdentifier,
                    observerIdentifier: observerIdentifier
                )
            }
            return
        }
        running = true
        let runIdentifier = UUID()
        self.runIdentifier = runIdentifier
        currentEvent = nil
        watcherState = .unknown
        stateLock.unlock()

        // Scanner-derived startup state and watcher installation live on the same queue as scans.
        // `stop()` can therefore invalidate the token and drain this entire cold-start sequence;
        // no watcher can start and no callback can escape after that barrier returns.
        workerQueue.async { [weak self] in
            guard let self, self.isCurrent(runIdentifier) else { return }
            let initialEvent = ConversationCatalogScanEvent.started(
                revision: self.scanner.generation
            )
            _ = self.rearmWatcherIfNeeded()
            self.publish(initialEvent, identifier: runIdentifier)

            do {
                _ = try self.runScan(identifier: runIdentifier) { progress, isCancelled in
                    try self.scanner.scanAll(
                        onProgress: progress,
                        isCancelled: isCancelled
                    )
                }
            } catch {
                // `runScan` publishes the terminal failure while the run is still active. A later
                // watcher event, explicit mutation, or activation performs another reconciliation.
            }
        }
    }

    /// Compatibility hook for focused embedders which only need catalog revisions. Unlike the old
    /// lifecycle, an unchanged terminal scan is also delivered so clients cannot remain loading.
    func start(onRevision: @escaping @Sendable (Int64) -> Void) {
        start { event in
            guard event.phase != .started else { return }
            onRevision(event.revision)
        }
    }

    func stop() {
        database.cancelDeferredMaintenance()
        stateLock.lock()
        running = false
        runIdentifier = nil
        eventObserver = nil
        eventObserverIdentifier = nil
        currentEvent = nil
        observerScheduledEventSequence = nil
        deferredReparseToken = nil
        let watcher = self.watcher
        self.watcher = nil
        watchedRootPaths.removeAll()
        watcherState = .unknown
        stateLock.unlock()
        watcher?.stop()
        drainWorkerQueue()
        drainObserverQueue()
    }

    /// Synchronous barrier used after imports and destructive mutations. A caller acting on the
    /// user's own edit is promised a current catalog when it returns, so it never inherits the
    /// spacing that protects the machine from a producer writing in a loop.
    func reconcileNow() throws {
        try onWorkerQueue {
            let identifier = currentRunIdentifier
            _ = try runScan(identifier: identifier) { progress, isCancelled in
                try scanner.scanAll(
                    onProgress: progress,
                    isCancelled: isCancelled,
                    forceReparse: true
                )
            }
        }
    }

    /// Synchronous barrier used after a known transcript or metadata sidecar mutation.
    func refreshNow(files: [URL]) throws {
        let paths = Self.unique(files)
        guard !paths.isEmpty else { return }
        try onWorkerQueue {
            let identifier = currentRunIdentifier
            _ = try runScan(identifier: identifier) { progress, isCancelled in
                try scanner.scan(
                    changedPaths: paths,
                    forceDiscovery: false,
                    onProgress: progress,
                    isCancelled: isCancelled,
                    forceReparse: true
                )
            }
        }
    }

    deinit {
        stop()
    }

    private var currentRunIdentifier: UUID? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running ? runIdentifier : nil
    }

    private func isCurrent(_ identifier: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && runIdentifier == identifier
    }

    private func handle(_ event: ConversationHistoryWatchEvent) {
        guard let identifier = currentRunIdentifier else { return }
        do {
            _ = try runScan(identifier: identifier) { progress, isCancelled in
                if event.requiresFullRescan {
                    return try scanner.scanAll(
                        onProgress: progress,
                        isCancelled: isCancelled
                    )
                }
                return try scanner.scan(
                    changedPaths: event.changedPaths,
                    forceDiscovery: !event.rootChanges.isEmpty,
                    onProgress: progress,
                    isCancelled: isCancelled
                )
            }
        } catch {
            // `runScan` has already surfaced the failure. A later debounced event or foreground
            // mutation retries without replacing a valid warm catalog.
        }
    }

    private func publish(
        _ event: ConversationCatalogScanEvent,
        identifier: UUID
    ) {
        stateLock.lock()
        guard running, runIdentifier == identifier else {
            stateLock.unlock()
            return
        }
        var deliveredEvent = event
        deliveredEvent.watcherState = watcherState
        currentEvent = deliveredEvent
        currentEventSequence &+= 1
        let sequence = currentEventSequence
        guard let observer = eventObserver,
              let observerIdentifier = eventObserverIdentifier else {
            stateLock.unlock()
            return
        }
        observerScheduledEventSequence = sequence
        stateLock.unlock()
        queueObserverDelivery(
            deliveredEvent,
            runIdentifier: identifier,
            observerIdentifier: observerIdentifier,
            observer: observer
        )
    }

    /// Reattachment can race the tail of an active scan. Replaying a captured event directly from
    /// the caller would allow a terminal event to arrive first and stale progress afterwards,
    /// leaving the UI permanently scanning. Reading and delivering the replay on the worker queue
    /// preserves event order and makes the terminal event the subscriber's final state.
    private func queueCurrentEventReplay(
        runIdentifier: UUID,
        observerIdentifier: UUID
    ) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.running,
                  self.runIdentifier == runIdentifier,
                  self.eventObserverIdentifier == observerIdentifier,
                  let event = self.currentEvent,
                  self.observerScheduledEventSequence != self.currentEventSequence,
                  let observer = self.eventObserver else {
                self.stateLock.unlock()
                return
            }
            self.observerScheduledEventSequence = self.currentEventSequence
            self.stateLock.unlock()
            self.queueObserverDelivery(
                event,
                runIdentifier: runIdentifier,
                observerIdentifier: observerIdentifier,
                observer: observer
            )
        }
    }

    /// Observer code is never invoked while the scanner lock or worker queue is occupied. Besides
    /// keeping slow UI consumers out of the indexing critical path, this permits a subscriber to
    /// synchronously request reconciliation without recursively acquiring the scanner lock.
    private func queueObserverDelivery(
        _ event: ConversationCatalogScanEvent,
        runIdentifier: UUID,
        observerIdentifier: UUID,
        observer: @escaping @Sendable (ConversationCatalogScanEvent) -> Void
    ) {
        observerQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrentObserver = self.running
                && self.runIdentifier == runIdentifier
                && self.eventObserverIdentifier == observerIdentifier
            self.stateLock.unlock()
            guard isCurrentObserver else { return }
            observer(event)
        }
    }

    private func runScan(
        identifier: UUID?,
        operation: (
            ConversationIndexScanProgress?,
            ConversationIndexScanCancellation
        ) throws -> ConversationIndexScanResult
    ) throws -> ConversationIndexScanResult {
        database.cancelDeferredMaintenance()
        if let identifier {
            guard isCurrent(identifier) else { throw CancellationError() }
            publish(.started(revision: scanner.generation), identifier: identifier)
        }

        let progress: ConversationIndexScanProgress?
        if let identifier {
            progress = { @Sendable [weak self] result in
                guard (result.metadataPublished > 0 && result.completed == 0)
                        || result.completed == 1
                        || (result.completed > 0 && result.completed.isMultiple(of: 24))
                        || (result.discovered > 0 && result.completed == result.discovered)
                else { return }
                self?.publish(.progress(result), identifier: identifier)
            }
        } else {
            progress = nil
        }
        let isCancelled: ConversationIndexScanCancellation = { [weak self] in
            guard let identifier else { return false }
            return self?.isCurrent(identifier) != true
        }

        do {
            let result = try operation(progress, isCancelled)
            guard let identifier else { return result }
            guard isCurrent(identifier) else { throw CancellationError() }
            let rootsChanged = rearmWatcherIfNeeded()
            publish(.finished(result), identifier: identifier)
            database.scheduleDeferredMaintenance()
            if rootsChanged { queueVerification(identifier: identifier) }
            scheduleDeferredReparse(identifier: identifier)
            return result
        } catch {
            if let identifier, isCurrent(identifier) {
                let result = ConversationIndexScanResult(generation: scanner.generation)
                publish(
                    .finished(result, errorDescription: error.localizedDescription),
                    identifier: identifier
                )
            }
            throw error
        }
    }

    /// Finishes the full parses the scanner postponed while a producer was writing.
    ///
    /// Without this, a transcript whose last append arrived inside its spacing window would keep
    /// the metadata the quick pass published but never regain searchable text for its final turns:
    /// no further file-system event is coming once the CLI exits. Rescheduling replaces the
    /// previous timer, so a busy producer costs one pending retry rather than one per event.
    private func scheduleDeferredReparse(identifier: UUID) {
        guard let deferred = scanner.deferredReparse else {
            stateLock.lock()
            deferredReparseToken = nil
            stateLock.unlock()
            return
        }
        let token = UUID()
        stateLock.lock()
        deferredReparseToken = token
        stateLock.unlock()

        let delay = max(0.25, deferred.earliestDeadline.timeIntervalSinceNow)
        workerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrent(identifier), self.isDeferredReparseCurrent(token) else {
                return
            }
            do {
                _ = try self.runScan(identifier: identifier) { progress, isCancelled in
                    try self.scanner.scan(
                        changedPaths: deferred.paths,
                        forceDiscovery: false,
                        onProgress: progress,
                        isCancelled: isCancelled
                    )
                }
            } catch {
                // `runScan` publishes a terminal error if this lifecycle is still active. The next
                // watcher event or activation reconciles again.
            }
        }
    }

    private func isDeferredReparseCurrent(_ token: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return deferredReparseToken == token
    }

    /// Manifests discovered by the first scan can add dependencies outside the configured trees,
    /// such as Codex state databases and CC Buddy metadata sidecars. Re-arm the watcher and queue
    /// one cheap fingerprint-verification pass so a write during that first-scan window is covered.
    private func queueVerification(identifier: UUID) {
        workerQueue.async { [weak self] in
            guard let self, self.isCurrent(identifier) else { return }
            do {
                _ = try self.runScan(identifier: identifier) { progress, isCancelled in
                    try self.scanner.scanAll(
                        onProgress: progress,
                        isCancelled: isCancelled
                    )
                }
            } catch {
                // `runScan` publishes a terminal error if this lifecycle is still active.
            }
        }
    }

    private func rearmWatcherIfNeeded() -> Bool {
        let roots = scanner.watchRoots
        let paths = Set(roots.map { $0.standardizedFileURL.path })

        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return false
        }
        let watcherNeedsReplacement: Bool
        switch watcherState {
        case .active:
            watcherNeedsReplacement = watcher == nil || paths != watchedRootPaths
        case .unknown, .unavailable:
            watcherNeedsReplacement = true
        }
        guard watcherNeedsReplacement else {
            stateLock.unlock()
            return false
        }
        stateLock.unlock()

        let replacement = ConversationHistoryWatcher(
            roots: roots,
            callbackQueue: workerQueue
        ) { [weak self] event in
            self?.handle(event)
        }
        let started = replacement.map(watcherStarter) ?? false

        stateLock.lock()
        guard running else {
            stateLock.unlock()
            replacement?.stop()
            return false
        }
        guard started, let replacement else {
            watcherState = .unavailable("会话实时更新不可用，重试以重新连接")
            stateLock.unlock()
            replacement?.stop()
            return false
        }
        let previous = watcher
        let rootsChanged = paths != watchedRootPaths
        watcher = replacement
        watchedRootPaths = paths
        watcherState = .active
        stateLock.unlock()

        // Start the replacement first to avoid an uncovered interval between streams.
        previous?.stop()
        return rootsChanged
    }

    private func onWorkerQueue<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: workerQueueKey) != nil { return try work() }
        return try workerQueue.sync(execute: work)
    }

    private func drainWorkerQueue() {
        guard DispatchQueue.getSpecific(key: workerQueueKey) == nil else { return }
        workerQueue.sync {}
    }

    private func drainObserverQueue() {
        // An observer may be synchronously waiting on the worker (for example via
        // `reconcileNow`). Never make that worker wait back on the observer queue.
        guard DispatchQueue.getSpecific(key: observerQueueKey) == nil,
              DispatchQueue.getSpecific(key: workerQueueKey) == nil else { return }
        observerQueue.sync {}
    }

    private static func unique(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.compactMap { file in
            let value = file.standardizedFileURL
            return seen.insert(value.path).inserted ? value : nil
        }
    }
}
