import Darwin
import Foundation

protocol PluginRuntimeClock: Sendable {
    func sleep(milliseconds: UInt64) async throws
}

struct SystemPluginRuntimeClock: PluginRuntimeClock, Sendable {
    func sleep(milliseconds: UInt64) async throws {
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        try await Task.sleep(nanoseconds: overflow ? UInt64.max : nanoseconds)
    }
}

protocol PluginPortAllocating: Sendable {
    func allocate(
        pluginID: String,
        preferred: UInt16?,
        reserved: Set<UInt16>
    ) throws -> UInt16
}

protocol PluginPortAvailabilityChecking: Sendable {
    func isAvailable(_ port: UInt16) -> Bool
}

enum PluginPortAllocationError: Error, LocalizedError, Equatable, Sendable {
    case noAvailablePort

    var errorDescription: String? { "No local port is available for the plugin" }
}

struct PluginDeterministicPortAllocator: PluginPortAllocating, Sendable {
    private let range: ClosedRange<UInt16>
    private let availability: any PluginPortAvailabilityChecking

    init(
        range: ClosedRange<UInt16> = 49_152...60_999,
        availability: any PluginPortAvailabilityChecking = PluginSocketPortAvailabilityChecker()
    ) {
        self.range = range
        self.availability = availability
    }

    func allocate(pluginID: String, preferred: UInt16?, reserved: Set<UInt16>) throws -> UInt16 {
        if let preferred, !reserved.contains(preferred), availability.isAvailable(preferred) {
            return preferred
        }
        let count = Int(range.upperBound) - Int(range.lowerBound) + 1
        let offset = Int(Self.stableHash(pluginID) % UInt64(count))
        for attempt in 0..<count {
            let raw = Int(range.lowerBound) + ((offset + attempt) % count)
            let candidate = UInt16(raw)
            if !reserved.contains(candidate), availability.isAvailable(candidate) { return candidate }
        }
        throw PluginPortAllocationError.noAvailablePort
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var result: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result &*= 1_099_511_628_211
        }
        return result
    }
}

struct PluginSocketPortAvailabilityChecker: PluginPortAvailabilityChecking, Sendable {
    func isAvailable(_ port: UInt16) -> Bool {
        guard port > 0 else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

struct PluginSidecarSupervisorConfiguration: Equatable, Sendable {
    var outputByteLimitPerStream: Int
    var healthPollIntervalMilliseconds: UInt64
    var healthRequestTimeoutMilliseconds: Int
    var terminationGracePolls: Int
    var terminationPollIntervalMilliseconds: UInt64

    init(
        outputByteLimitPerStream: Int = 32 * 1_024,
        healthPollIntervalMilliseconds: UInt64 = 100,
        healthRequestTimeoutMilliseconds: Int = 1_500,
        terminationGracePolls: Int = 20,
        terminationPollIntervalMilliseconds: UInt64 = 25
    ) {
        self.outputByteLimitPerStream = max(1, outputByteLimitPerStream)
        self.healthPollIntervalMilliseconds = max(1, healthPollIntervalMilliseconds)
        self.healthRequestTimeoutMilliseconds = max(1, healthRequestTimeoutMilliseconds)
        self.terminationGracePolls = max(1, terminationGracePolls)
        self.terminationPollIntervalMilliseconds = max(1, terminationPollIntervalMilliseconds)
    }
}

enum PluginRuntimeFailure: Equatable, Sendable {
    case preparation(String)
    case launchFailed
    case healthTimeout
    case cancelled
    case unexpectedExit(PluginProcessTermination)
    case terminationTimeout

    var message: String {
        switch self {
        case .preparation(let message): return message
        case .launchFailed: return "Plugin process could not be started"
        case .healthTimeout: return "Plugin did not become healthy before its ready timeout"
        case .cancelled: return "Plugin startup was cancelled"
        case .unexpectedExit(let termination):
            let label = termination.reason == .uncaughtSignal ? "signal" : "status"
            return "Plugin exited unexpectedly (\(label) \(termination.status))"
        case .terminationTimeout: return "Plugin process did not terminate after a forced stop"
        }
    }
}

struct PluginSidecarSnapshot: Equatable, Sendable {
    var pluginID: String
    var lifecycle: PluginLifecycleState
    var port: UInt16?
    var processIdentifier: Int32?
    var failure: PluginRuntimeFailure?
    var termination: PluginProcessTermination?
    var output: PluginOutputSnapshot

    var isRunning: Bool { lifecycle == .running }
}

enum PluginSidecarSupervisorError: Error, LocalizedError, Equatable, Sendable {
    case operationInProgress(String)
    case shuttingDown
    case startFailed(pluginID: String, failure: PluginRuntimeFailure)

    var errorDescription: String? {
        switch self {
        case .operationInProgress(let id): return "A lifecycle operation is already in progress for plugin '\(id)'"
        case .shuttingDown: return "Plugin supervisor is shutting down"
        case .startFailed(_, let failure): return failure.message
        }
    }
}

actor PluginSidecarSupervisor {
    private struct Entry {
        var lifecycle: PluginLifecycleState
        var port: UInt16?
        var handle: (any PluginSidecarProcessHandle)?
        var capture: PluginBoundedOutputCapture
        var failure: PluginRuntimeFailure?
        var pendingFailure: PluginRuntimeFailure?
        var termination: PluginProcessTermination?
        var expectedStop: Bool
        var generation: UInt64
        var monitor: Task<Void, Never>?
    }

    private let repository: PluginRepository
    private let launcher: any PluginSidecarProcessLaunching
    private let healthChecker: any PluginHealthChecking
    private let portAllocator: any PluginPortAllocating
    private let clock: any PluginRuntimeClock
    private let configuration: PluginSidecarSupervisorConfiguration
    private let processEnvironment: [String: String]?
    private let outputRedactor: PluginSecretRedactor
    private var entries: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 1
    private var isShuttingDown = false

    init(
        repository: PluginRepository,
        launcher: any PluginSidecarProcessLaunching = FoundationPluginSidecarProcessLauncher(),
        healthChecker: any PluginHealthChecking = PluginHTTPHealthChecker(),
        portAllocator: any PluginPortAllocating = PluginDeterministicPortAllocator(),
        clock: any PluginRuntimeClock = SystemPluginRuntimeClock(),
        configuration: PluginSidecarSupervisorConfiguration = .init(),
        processEnvironment: [String: String]? = nil,
        diagnosticSecrets: [String] = []
    ) {
        self.repository = repository
        self.launcher = launcher
        self.healthChecker = healthChecker
        self.portAllocator = portAllocator
        self.clock = clock
        self.configuration = configuration
        self.processEnvironment = processEnvironment
        outputRedactor = .init(explicitSecrets: diagnosticSecrets)
    }

    func start(id: String) async throws -> PluginSidecarSnapshot {
        guard !isShuttingDown else { throw PluginSidecarSupervisorError.shuttingDown }
        if let current = entries[id] {
            if current.lifecycle == .running { return snapshot(id: id, entry: current) }
            if current.lifecycle == .starting || current.lifecycle == .stopping {
                throw PluginSidecarSupervisorError.operationInProgress(id)
            }
            if current.handle != nil {
                _ = await stop(id: id)
                if entries[id]?.handle != nil {
                    throw PluginSidecarSupervisorError.startFailed(
                        pluginID: id,
                        failure: .terminationTimeout
                    )
                }
            }
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        let capture = PluginBoundedOutputCapture(
            byteLimitPerStream: configuration.outputByteLimitPerStream,
            redactor: outputRedactor
        )
        let port: UInt16
        let descriptor: PluginSidecarDescriptor
        do {
            let preferred = try repository.readRuntime(id: id)?.validPort
            let reserved = Set(entries.values.compactMap { $0.handle == nil ? nil : $0.port })
            port = try portAllocator.allocate(pluginID: id, preferred: preferred, reserved: reserved)
            try repository.writeRuntime(.init(port: Int(port)), id: id)
            descriptor = try repository.sidecarDescriptor(id: id, port: port)
        } catch {
            let failure = PluginRuntimeFailure.preparation(safeMessage(error))
            let entry = Entry(
                lifecycle: .failed,
                port: nil,
                handle: nil,
                capture: capture,
                failure: failure,
                pendingFailure: nil,
                termination: nil,
                expectedStop: false,
                generation: generation,
                monitor: nil
            )
            entries[id] = entry
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
        }

        let request = PluginSidecarLaunchRequest(
            pluginID: id,
            executable: descriptor.executable,
            arguments: descriptor.arguments,
            workingDirectory: descriptor.workingDirectory,
            environment: processEnvironment
        )
        let handle: any PluginSidecarProcessHandle
        do {
            handle = try launcher.launch(request) { stream, data in
                capture.append(stream, data: data)
            }
        } catch {
            let failure = PluginRuntimeFailure.launchFailed
            entries[id] = Entry(
                lifecycle: .failed,
                port: port,
                handle: nil,
                capture: capture,
                failure: failure,
                pendingFailure: nil,
                termination: nil,
                expectedStop: false,
                generation: generation,
                monitor: nil
            )
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
        }

        var entry = Entry(
            lifecycle: .starting,
            port: port,
            handle: handle,
            capture: capture,
            failure: nil,
            pendingFailure: nil,
            termination: nil,
            expectedStop: false,
            generation: generation,
            monitor: nil
        )
        entry.monitor = Task { [weak self, weak handle] in
            guard let self, let handle else { return }
            let termination = await handle.waitForExit()
            await self.processExited(id: id, generation: generation, termination: termination)
        }
        entries[id] = entry

        let healthy: Bool
        do {
            healthy = try await waitForHealth(
                id: id,
                generation: generation,
                handle: handle,
                descriptor: descriptor
            )
        } catch is CancellationError {
            await terminateForFailure(id: id, generation: generation, failure: .cancelled)
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: .cancelled)
        } catch {
            let failure: PluginRuntimeFailure = Task.isCancelled
                ? .cancelled
                : .preparation("Plugin health polling failed")
            await terminateForFailure(id: id, generation: generation, failure: failure)
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
        }
        guard healthy else {
            guard let current = entries[id], current.generation == generation,
                  current.lifecycle == .starting else {
                let failure = entries[id]?.failure ?? .cancelled
                throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
            }
            let failure = current.failure ?? .healthTimeout
            await terminateForFailure(id: id, generation: generation, failure: failure)
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
        }

        guard var running = entries[id], running.generation == generation,
              running.lifecycle == .starting, running.handle != nil else {
            let failure = entries[id]?.failure ?? .cancelled
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
        }
        if let termination = handle.terminationIfExited() {
            processExited(id: id, generation: generation, termination: termination)
            let failure = entries[id]?.failure ?? .unexpectedExit(termination)
            throw PluginSidecarSupervisorError.startFailed(pluginID: id, failure: failure)
        }
        running.lifecycle = .running
        entries[id] = running
        return snapshot(id: id, entry: running)
    }

    @discardableResult
    func stop(id: String) async -> PluginSidecarSnapshot? {
        guard var entry = entries[id] else { return nil }
        guard let handle = entry.handle else {
            entry.lifecycle = .stopped
            entry.failure = nil
            entry.pendingFailure = nil
            entries[id] = entry
            return snapshot(id: id, entry: entry)
        }
        entry.lifecycle = .stopping
        entry.expectedStop = true
        entry.pendingFailure = nil
        entries[id] = entry
        await terminate(handle: handle, id: id, generation: entry.generation)
        return entries[id].map { snapshot(id: id, entry: $0) }
    }

    func restart(id: String) async throws -> PluginSidecarSnapshot {
        guard !isShuttingDown else { throw PluginSidecarSupervisorError.shuttingDown }
        _ = await stop(id: id)
        return try await start(id: id)
    }

    func state(id: String) -> PluginSidecarSnapshot? {
        entries[id].map { snapshot(id: id, entry: $0) }
    }

    func states() -> [PluginSidecarSnapshot] {
        entries.keys.sorted().compactMap { id in entries[id].map { snapshot(id: id, entry: $0) } }
    }

    /// Deterministic observation hook for lifecycle owners and tests. The background monitor uses
    /// the same finalizer, so calling this concurrently cannot apply an exit twice.
    func waitForExit(id: String) async -> PluginSidecarSnapshot? {
        guard let entry = entries[id], let handle = entry.handle else {
            return entries[id].map { snapshot(id: id, entry: $0) }
        }
        let termination = await handle.waitForExit()
        processExited(id: id, generation: entry.generation, termination: termination)
        return entries[id].map { snapshot(id: id, entry: $0) }
    }

    func shutdown() async {
        isShuttingDown = true
        let active = entries.compactMap { key, value in value.handle == nil ? nil : key }.sorted()
        for id in active { _ = await stop(id: id) }
    }

    private func waitForHealth(
        id: String,
        generation: UInt64,
        handle: any PluginSidecarProcessHandle,
        descriptor: PluginSidecarDescriptor
    ) async throws -> Bool {
        let timeout = UInt64(max(1, descriptor.readyTimeoutMilliseconds))
        var elapsed: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let current = entries[id], current.generation == generation,
                  current.lifecycle == .starting else { return false }
            if let termination = handle.terminationIfExited() {
                processExited(id: id, generation: generation, termination: termination)
                return false
            }
            let isHealthy = await healthChecker.isHealthy(
                url: descriptor.healthURL,
                timeoutMilliseconds: configuration.healthRequestTimeoutMilliseconds
            )
            try Task.checkCancellation()
            if isHealthy {
                return entries[id]?.generation == generation && handle.terminationIfExited() == nil
            }
            guard elapsed < timeout else { return false }
            let delay = min(configuration.healthPollIntervalMilliseconds, timeout - elapsed)
            try await clock.sleep(milliseconds: delay)
            elapsed += delay
        }
    }

    private func terminateForFailure(
        id: String,
        generation: UInt64,
        failure: PluginRuntimeFailure
    ) async {
        guard var entry = entries[id], entry.generation == generation, let handle = entry.handle else { return }
        entry.lifecycle = .stopping
        entry.expectedStop = false
        entry.pendingFailure = failure
        entries[id] = entry
        await terminate(handle: handle, id: id, generation: generation)
    }

    private func terminate(
        handle: any PluginSidecarProcessHandle,
        id: String,
        generation: UInt64
    ) async {
        handle.terminate()
        if let termination = await waitForTermination(handle) {
            processExited(id: id, generation: generation, termination: termination)
            return
        }
        handle.kill()
        if let termination = await waitForTermination(handle) {
            processExited(id: id, generation: generation, termination: termination)
            return
        }
        guard var entry = entries[id], entry.generation == generation else { return }
        entry.lifecycle = .failed
        entry.failure = .terminationTimeout
        entry.pendingFailure = nil
        entries[id] = entry
    }

    private func waitForTermination(
        _ handle: any PluginSidecarProcessHandle
    ) async -> PluginProcessTermination? {
        for _ in 0..<configuration.terminationGracePolls {
            if let termination = handle.terminationIfExited() { return termination }
            try? await clock.sleep(milliseconds: configuration.terminationPollIntervalMilliseconds)
        }
        return handle.terminationIfExited()
    }

    private func processExited(
        id: String,
        generation: UInt64,
        termination: PluginProcessTermination
    ) {
        guard var entry = entries[id], entry.generation == generation, entry.handle != nil else { return }
        entry.handle = nil
        entry.monitor = nil
        entry.termination = termination
        if let pending = entry.pendingFailure {
            entry.lifecycle = .failed
            entry.failure = pending
        } else if entry.expectedStop {
            entry.lifecycle = .stopped
            entry.failure = nil
        } else {
            entry.lifecycle = .failed
            entry.failure = .unexpectedExit(termination)
        }
        entry.pendingFailure = nil
        entries[id] = entry
    }

    private func snapshot(id: String, entry: Entry) -> PluginSidecarSnapshot {
        .init(
            pluginID: id,
            lifecycle: entry.lifecycle,
            port: entry.port,
            processIdentifier: entry.handle?.processIdentifier,
            failure: entry.failure,
            termination: entry.termination,
            output: entry.capture.snapshot()
        )
    }

    private func safeMessage(_ error: Error) -> String {
        let redacted = outputRedactor.redact(error.localizedDescription)
        return String(redacted.prefix(512))
    }
}
