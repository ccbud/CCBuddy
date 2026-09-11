import Dispatch
import Foundation

/// How urgently the system wants memory back.
enum MemoryPressureLevel: Equatable, Sendable {
    /// The system is short on memory. Shed what is cheap to rebuild.
    case warning
    /// The system is about to start killing processes. Shed everything optional.
    case critical
}

/// Relays macOS memory-pressure notifications to the app's caches.
///
/// Without this, a large history library degrades the whole machine rather than just the app:
/// every cache holds what it holds, the app never gives anything back, and the system pages other
/// applications out to keep serving a cache that would happily have been rebuilt from disk. The
/// monitor is the one place that hears the system and the one place caches subscribe to it.
///
/// Handlers run on a background queue and must be safe to call at any time.
final class MemoryPressureMonitor: @unchecked Sendable {
    static let shared = MemoryPressureMonitor()

    /// Cancels a registration. Deinit is enough; holding it is only needed to unsubscribe early.
    final class Registration {
        private let cancel: () -> Void
        private var isCancelled = false

        fileprivate init(cancel: @escaping () -> Void) { self.cancel = cancel }

        func invalidate() {
            guard !isCancelled else { return }
            isCancelled = true
            cancel()
        }

        deinit { invalidate() }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "dev.ccbud.memory-pressure", qos: .utility
    )
    private var handlers: [UUID: @Sendable (MemoryPressureLevel) -> Void] = [:]
    private var source: DispatchSourceMemoryPressure?

    private init() {}

    @discardableResult
    func register(
        _ handler: @escaping @Sendable (MemoryPressureLevel) -> Void
    ) -> Registration {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        startIfNeededLocked()
        lock.unlock()
        return Registration { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    /// Delivers a level to every handler. Exposed so tests can exercise the response to pressure
    /// without waiting on the system to actually run out of memory.
    func dispatch(_ level: MemoryPressureLevel) {
        lock.lock()
        let handlers = Array(self.handlers.values)
        lock.unlock()
        for handler in handlers { handler(level) }
    }

    private func startIfNeededLocked() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            let level: MemoryPressureLevel =
                data.contains(.critical) ? .critical : .warning
            self.dispatch(level)
        }
        source.resume()
        self.source = source
    }
}
