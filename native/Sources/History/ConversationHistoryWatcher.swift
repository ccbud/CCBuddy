import CoreServices
import Foundation

enum ConversationHistoryRootChangeKind: String, Equatable, Sendable {
    case appeared
    case disappeared
    case replaced
}

struct ConversationHistoryRootChange: Equatable, Sendable {
    let root: URL
    let kind: ConversationHistoryRootChangeKind
}

/// One trailing-debounced batch of file-system changes relevant to conversation history.
///
/// `changedPaths` retains the concrete FSEvents paths so an indexer can ask its source adapters
/// for only the affected sessions. The three signals deliberately remain separate: callers may
/// use paths for ordinary incremental work while falling back to a complete reconciliation when
/// FSEvents reports a gap or a watched root changes identity.
struct ConversationHistoryWatchEvent: Equatable, Sendable {
    let changedPaths: [URL]
    let rootChanges: [ConversationHistoryRootChange]
    let rootReplacementDetected: Bool
    let droppedEventsDetected: Bool
    let requiresFullRescan: Bool
}

struct ConversationHistoryEventDisposition: Equatable, Sendable {
    let rootReplacementDetected: Bool
    let droppedEventsDetected: Bool
    let requiresFullRescan: Bool
}

/// Recursive FSEvents watcher for the conversation index.
///
/// Unlike `UsageHistoryWatcher`, this watcher preserves event paths and performs its own trailing
/// debounce. Missing roots are watched through their nearest existing ancestor and are also
/// probed periodically; after a root appears or is atomically replaced, the stream is re-armed on
/// the new inode before the change is delivered.
final class ConversationHistoryWatcher: @unchecked Sendable {
    private struct RawEvent: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private enum RootState: Equatable {
        case missing
        case present(isDirectory: Bool, device: UInt64?, inode: UInt64?)
    }

    private struct StreamHandle {
        let stream: FSEventStreamRef
        let callbackBox: StreamCallbackBox
        let anchors: [String]
    }

    private final class StreamCallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private let receiver: @Sendable ([RawEvent]) -> Void
        private var invalidated = false

        init(receiver: @escaping @Sendable ([RawEvent]) -> Void) {
            self.receiver = receiver
        }

        func receive(_ events: [RawEvent]) {
            lock.lock()
            let active = !invalidated
            lock.unlock()
            if active { receiver(events) }
        }

        func invalidate() {
            lock.lock()
            invalidated = true
            lock.unlock()
        }
    }

    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private let receiver: @Sendable (ConversationHistoryWatchEvent) -> Void
        private var invalidated = false

        init(receiver: @escaping @Sendable (ConversationHistoryWatchEvent) -> Void) {
            self.receiver = receiver
        }

        func deliver(_ event: ConversationHistoryWatchEvent) {
            lock.lock()
            let active = !invalidated
            lock.unlock()
            if active { receiver(event) }
        }

        func invalidate() {
            lock.lock()
            invalidated = true
            lock.unlock()
        }
    }

    private let roots: [URL]
    private let fileManager: FileManager
    private let latency: TimeInterval
    private let debounceInterval: TimeInterval
    private let rootProbeInterval: TimeInterval
    private let callbackQueue: DispatchQueue
    private let onEvent: @Sendable (ConversationHistoryWatchEvent) -> Void
    private let stateQueue = DispatchQueue(
        label: "dev.ccbud.conversation-history-watcher.state",
        qos: .utility
    )
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private let eventQueue = DispatchQueue(
        label: "dev.ccbud.conversation-history-watcher.events",
        qos: .utility
    )

    private var running = false
    private var streamHandle: StreamHandle?
    private var deliveryGate: DeliveryGate?
    private var rootProbeTimer: DispatchSourceTimer?
    private var rootStates: [String: RootState] = [:]
    private var needsStreamRearm = false

    private var pendingPaths = Set<String>()
    private var pendingRootChanges: [String: ConversationHistoryRootChangeKind] = [:]
    private var pendingRootReplacement = false
    private var pendingDroppedEvents = false
    private var pendingFullRescan = false
    private var pendingFlush: DispatchWorkItem?

    init?(
        roots: [URL],
        latency: TimeInterval = 0.10,
        debounceInterval: TimeInterval = 0.35,
        rootProbeInterval: TimeInterval = 1.0,
        callbackQueue: DispatchQueue = .main,
        fileManager: FileManager = FileManager(),
        onEvent: @escaping @Sendable (ConversationHistoryWatchEvent) -> Void
    ) {
        let paths = Set(roots.filter(\.isFileURL).map { $0.standardizedFileURL.path })
        guard !paths.isEmpty else { return nil }
        self.roots = paths.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.fileManager = fileManager
        self.latency = max(0.01, latency)
        self.debounceInterval = max(0.01, debounceInterval)
        self.rootProbeInterval = max(0.05, rootProbeInterval)
        self.callbackQueue = callbackQueue
        self.onEvent = onEvent
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    var isRunning: Bool {
        withSynchronizedState { running }
    }

    /// Starts the stream. Calling this repeatedly is harmless, and a watcher may be restarted
    /// after `stop()`.
    @discardableResult
    func start() -> Bool {
        withSynchronizedState {
            guard !running else { return true }
            running = true
            rootStates = Dictionary(uniqueKeysWithValues: roots.map {
                ($0.path, rootState(at: $0))
            })
            deliveryGate = DeliveryGate(receiver: onEvent)
            needsStreamRearm = true

            guard installStream(force: true) else {
                deliveryGate?.invalidate()
                deliveryGate = nil
                running = false
                return false
            }
            startRootProbe()
            return true
        }
    }

    /// Stops callbacks, pending debounce work, root probes, and the underlying stream. The method
    /// is idempotent and safe to call from the event callback because delivery uses another queue.
    func stop() {
        withSynchronizedState {
            guard running || streamHandle != nil else { return }
            running = false
            pendingFlush?.cancel()
            pendingFlush = nil
            rootProbeTimer?.cancel()
            rootProbeTimer = nil
            deliveryGate?.invalidate()
            deliveryGate = nil
            clearPendingBatch()
            if let streamHandle {
                stopStream(streamHandle)
                self.streamHandle = nil
            }
            rootStates.removeAll()
            needsStreamRearm = false
        }
    }

    deinit {
        stop()
    }

    private func withSynchronizedState<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil { return body() }
        return stateQueue.sync(execute: body)
    }

    static func classify(
        flags: FSEventStreamEventFlags
    ) -> ConversationHistoryEventDisposition {
        let droppedMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        let rootMask = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let fullRescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        let rootReplacement = flags & rootMask != 0
        let dropped = flags & droppedMask != 0
        return ConversationHistoryEventDisposition(
            rootReplacementDetected: rootReplacement,
            droppedEventsDetected: dropped,
            requiresFullRescan: rootReplacement || dropped || flags & fullRescanMask != 0
        )
    }

    private func receive(_ events: [RawEvent]) {
        stateQueue.async { [weak self] in
            guard let self, self.running else { return }

            var disposition = ConversationHistoryEventDisposition(
                rootReplacementDetected: false,
                droppedEventsDetected: false,
                requiresFullRescan: false
            )
            for event in events {
                let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
                if self.isRelevant(path: path) { self.pendingPaths.insert(path) }
                let value = Self.classify(flags: event.flags)
                disposition = ConversationHistoryEventDisposition(
                    rootReplacementDetected: disposition.rootReplacementDetected
                        || value.rootReplacementDetected,
                    droppedEventsDetected: disposition.droppedEventsDetected
                        || value.droppedEventsDetected,
                    requiresFullRescan: disposition.requiresFullRescan
                        || value.requiresFullRescan
                )
            }

            let rootChanges = self.detectRootChanges()
            for change in rootChanges {
                self.pendingPaths.insert(change.root.path)
                self.pendingRootChanges[change.root.path] = change.kind
            }
            if !rootChanges.isEmpty || disposition.rootReplacementDetected {
                self.needsStreamRearm = true
                _ = self.installStream(force: true)
            }

            self.pendingRootReplacement = self.pendingRootReplacement
                || disposition.rootReplacementDetected
                || rootChanges.contains(where: { $0.kind == .replaced })
            self.pendingDroppedEvents = self.pendingDroppedEvents
                || disposition.droppedEventsDetected
            self.pendingFullRescan = self.pendingFullRescan
                || disposition.requiresFullRescan
                || !rootChanges.isEmpty

            guard !self.pendingPaths.isEmpty
                    || !self.pendingRootChanges.isEmpty
                    || self.pendingRootReplacement
                    || self.pendingDroppedEvents
                    || self.pendingFullRescan else { return }
            self.scheduleTrailingFlush()
        }
    }

    private func startRootProbe() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + rootProbeInterval,
            repeating: rootProbeInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let changes = self.detectRootChanges()
            for change in changes {
                self.pendingPaths.insert(change.root.path)
                self.pendingRootChanges[change.root.path] = change.kind
            }
            if !changes.isEmpty {
                self.pendingRootReplacement = self.pendingRootReplacement
                    || changes.contains(where: { $0.kind == .replaced })
                self.pendingFullRescan = true
                self.needsStreamRearm = true
                self.scheduleTrailingFlush()
            }
            if self.needsStreamRearm || self.streamHandle == nil {
                _ = self.installStream(force: true)
            }
        }
        rootProbeTimer = timer
        timer.resume()
    }

    private func detectRootChanges() -> [ConversationHistoryRootChange] {
        var changes: [ConversationHistoryRootChange] = []
        for root in roots {
            let previous = rootStates[root.path] ?? .missing
            let current = rootState(at: root)
            guard previous != current else { continue }
            rootStates[root.path] = current
            let kind: ConversationHistoryRootChangeKind
            switch (previous, current) {
            case (.missing, .present): kind = .appeared
            case (.present, .missing): kind = .disappeared
            case (.present, .present): kind = .replaced
            case (.missing, .missing): continue
            }
            changes.append(.init(root: root, kind: kind))
        }
        return changes
    }

    private func rootState(at root: URL) -> RootState {
        guard let attributes = try? fileManager.attributesOfItem(atPath: root.path) else {
            return .missing
        }
        let type = attributes[.type] as? FileAttributeType
        return .present(
            isDirectory: type == .typeDirectory,
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func scheduleTrailingFlush() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingBatch() }
        pendingFlush = work
        stateQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func flushPendingBatch() {
        guard running, let deliveryGate else { return }
        pendingFlush = nil
        let changedPaths = pendingPaths.sorted().map { URL(fileURLWithPath: $0) }
        let rootChanges = pendingRootChanges.sorted { $0.key < $1.key }.map {
            ConversationHistoryRootChange(
                root: URL(fileURLWithPath: $0.key, isDirectory: true),
                kind: $0.value
            )
        }
        let event = ConversationHistoryWatchEvent(
            changedPaths: changedPaths,
            rootChanges: rootChanges,
            rootReplacementDetected: pendingRootReplacement,
            droppedEventsDetected: pendingDroppedEvents,
            requiresFullRescan: pendingFullRescan
        )
        clearPendingBatch()
        callbackQueue.async { deliveryGate.deliver(event) }
    }

    private func clearPendingBatch() {
        pendingPaths.removeAll()
        pendingRootChanges.removeAll()
        pendingRootReplacement = false
        pendingDroppedEvents = false
        pendingFullRescan = false
    }

    private func installStream(force: Bool) -> Bool {
        let anchors = watchAnchors()
        if !force, let streamHandle, streamHandle.anchors == anchors {
            needsStreamRearm = false
            return true
        }
        guard let replacement = makeStream(anchors: anchors) else {
            needsStreamRearm = true
            return streamHandle != nil
        }
        let previous = streamHandle
        streamHandle = replacement
        needsStreamRearm = false
        if let previous { stopStream(previous) }
        return true
    }

    private func makeStream(anchors: [String]) -> StreamHandle? {
        guard !anchors.isEmpty else { return nil }
        let callbackBox = StreamCallbackBox { [weak self] events in
            self?.receive(events)
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<StreamCallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<StreamCallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            anchors as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            callbackBox.invalidate()
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return StreamHandle(stream: stream, callbackBox: callbackBox, anchors: anchors)
    }

    private func stopStream(_ handle: StreamHandle) {
        handle.callbackBox.invalidate()
        FSEventStreamStop(handle.stream)
        FSEventStreamInvalidate(handle.stream)
        FSEventStreamRelease(handle.stream)
    }

    private func watchAnchors() -> [String] {
        let candidates = roots.map(nearestExistingDirectory)
            .sorted {
                let left = URL(fileURLWithPath: $0).pathComponents.count
                let right = URL(fileURLWithPath: $1).pathComponents.count
                return left == right ? $0 < $1 : left < right
            }
        var anchors: [String] = []
        for candidate in candidates {
            if anchors.contains(where: { Self.contains(path: candidate, in: $0) }) { continue }
            anchors.removeAll(where: { Self.contains(path: $0, in: candidate) })
            anchors.append(candidate)
        }
        return anchors.sorted()
    }

    private func nearestExistingDirectory(for root: URL) -> String {
        var candidate = root.standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return candidate.path }
            candidate = parent
        }
    }

    private func isRelevant(path: String) -> Bool {
        roots.contains { root in
            Self.contains(path: path, in: root.path)
                || Self.contains(path: root.path, in: path)
        }
    }

    private static func contains(path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, eventCount, eventPaths, eventFlags, _ in
        guard eventCount > 0, let clientInfo else { return }
        let values = unsafeBitCast(eventPaths, to: NSArray.self)
        var events: [RawEvent] = []
        events.reserveCapacity(eventCount)
        for index in 0..<eventCount {
            guard let path = values.object(at: index) as? String else { continue }
            events.append(RawEvent(path: path, flags: eventFlags[index]))
        }
        guard !events.isEmpty else { return }
        Unmanaged<StreamCallbackBox>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
            .receive(events)
    }
}
