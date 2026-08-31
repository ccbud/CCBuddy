import CoreServices
import Foundation

enum UsageHistoryRootIdentity {
    static func signature(roots: [URL], fileManager: FileManager = FileManager()) -> String {
        roots.map { root in
            guard let attributes = try? fileManager.attributesOfItem(atPath: root.path),
                  (attributes[.type] as? FileAttributeType) == .typeDirectory else {
                return "\(root.path)|missing"
            }
            let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "?"
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
            return "\(root.path)|\(device)|\(inode)"
        }.joined(separator: "\u{0}")
    }
}

/// Recursive, low-latency history watcher backed by macOS FSEvents. The callback only announces
/// that some watched tree changed; UsageHistoryService remains the single owner of scanning and
/// aggregation. Keeping the callback payload-free also avoids retaining transient C event buffers.
final class UsageHistoryWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        private let onChange: @Sendable (_ rootsChanged: Bool) -> Void
        private let lock = NSLock()
        private var invalidated = false

        init(onChange: @escaping @Sendable (_ rootsChanged: Bool) -> Void) {
            self.onChange = onChange
        }

        func notify(rootsChanged: Bool) {
            lock.lock()
            let shouldNotify = !invalidated
            lock.unlock()
            if shouldNotify { onChange(rootsChanged) }
        }

        func invalidate() {
            lock.lock()
            invalidated = true
            lock.unlock()
        }
    }

    private let callbackBox: CallbackBox
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var invalidated = false

    init?(
        paths: [String],
        latency: TimeInterval = 0.35,
        onChange: @escaping @Sendable (_ rootsChanged: Bool) -> Void
    ) {
        let normalized = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard !normalized.isEmpty else { return nil }

        callbackBox = CallbackBox(onChange: onChange)
        queue = DispatchQueue(label: "dev.ccbud.usage-history-watcher", qos: .utility)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            normalized as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        callbackBox.invalidate()
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        invalidate()
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, eventCount, _, eventFlags, _ in
        guard eventCount > 0, let clientInfo else { return }

        // Root replacement and dropped/coalesced events still require a complete rescan; all
        // other file events do too. Inspecting flags documents that those conditions are not
        // accidentally filtered while retaining the same payload-free callback contract.
        let rootsChanged = UsageHistoryWatcher.rootsChanged(
            in: (0..<eventCount).map { eventFlags[$0] }
        )
        Unmanaged<CallbackBox>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
            .notify(rootsChanged: rootsChanged)
    }

    static func rootsChanged(in flags: [FSEventStreamEventFlags]) -> Bool {
        flags.contains { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
    }
}
