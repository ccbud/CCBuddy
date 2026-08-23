import Darwin
import Foundation
import Network
import SQLite3

enum BifrostGatewayState: Equatable, Sendable {
    case stopped, starting, running(port: Int), failed(String)
    var isRunning: Bool { if case .running = self { true } else { false } }
    var isRunningOrStarting: Bool {
        switch self {
        case .starting, .running:
            true
        case .stopped, .failed:
            false
        }
    }
}

struct BifrostProcessDiagnostics: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let standardOutputBytes: Int
    let standardErrorBytes: Int

    static let empty = BifrostProcessDiagnostics(
        standardOutput: "",
        standardError: "",
        standardOutputBytes: 0,
        standardErrorBytes: 0
    )

    var isEmpty: Bool { standardOutput.isEmpty && standardError.isEmpty }

    var formatted: String {
        var sections: [String] = []
        let stderr = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { sections.append("stderr:\n\(stderr)") }
        if !stdout.isEmpty { sections.append("stdout:\n\(stdout)") }
        return sections.joined(separator: "\n\n")
    }
}

/// A sidecar must not inherit loader or XCTest injection state from the host process. XCTest adds
/// `libXCTestBundleInject` through `DYLD_INSERT_LIBRARIES`; carrying that into the pinned Go helper
/// makes dyld abort before Bifrost can emit its own diagnostics. The same boundary also prevents a
/// shell-launched app from unintentionally injecting arbitrary dynamic libraries into its helper.
enum BifrostChildProcessEnvironment {
    static func make(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String]
    ) -> [String: String] {
        var result = inherited
        result.merge(overrides) { _, override in override }
        let keysToRemove = result.keys.filter(shouldRemove)
        for key in keysToRemove {
            result.removeValue(forKey: key)
        }
        return result
    }

    private static func shouldRemove(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return normalized.hasPrefix("DYLD_")
            || normalized.hasPrefix("__XPC_DYLD_")
            || normalized.hasPrefix("XCTEST")
            || normalized.hasPrefix("XCINJECT")
    }
}

/// Payload-free gateway activity for consumers such as MonitorStore. Request URLs, headers, and
/// bodies are deliberately excluded so subscribing cannot expose prompts, tokens, or credentials.
enum BifrostRequestActivity: Equatable, Sendable {
    case requestReceived
    case responseCompleted
}

enum BifrostError: LocalizedError, Equatable, Sendable {
    case noActiveProvider, invalidBaseURL, binaryMissing, exited(Int32), healthTimeout
    case catalogCacheResetFailed(String)
    case unsafeAppDirectory(String)
    case startupFailed(reason: String, diagnostics: BifrostProcessDiagnostics)

    var errorDescription: String? {
        switch self {
        case .noActiveProvider: "尚未配置服务商"
        case .invalidBaseURL: "当前服务商的 API 地址为空"
        case .binaryMissing: "未找到 bifrost-http；请运行 native/Scripts/fetch-bifrost.sh"
        case .exited(let code): "Bifrost 异常退出（\(code)）"
        case .healthTimeout: "Bifrost 启动健康检查超时"
        case .catalogCacheResetFailed(let detail): "无法刷新 Bifrost 模型目录缓存：\(detail)"
        case .unsafeAppDirectory(let detail): "Bifrost 数据目录不安全：\(detail)"
        case .startupFailed(let reason, let diagnostics):
            diagnostics.isEmpty ? reason : "\(reason)\n\n\(diagnostics.formatted)"
        }
    }
}

/// Mutable only through `BifrostSupervisor`. Keeping every lifecycle resource in one identity
/// prevents cleanup for an older, reentrant `start` from reaching a newer proxy or process.
private final class BifrostLifecycleResources {
    let generation: UInt64
    let processToken = UUID()
    let proxy: LegacyGatewayCompatibilityProxy
    var process: Process?
    var outputPipes: (stdout: Pipe, stderr: Pipe)?
    var outputCapture: BifrostOutputCapture?
    var retainedDiagnostics = BifrostProcessDiagnostics.empty
    var didLaunchProcess = false
    var unexpectedExitStatus: Int32?
    var isDisposing = false
    var isDisposed = false
    var disposalWaiters: [CheckedContinuation<Void, Never>] = []

    var diagnostics: BifrostProcessDiagnostics {
        outputCapture?.snapshot() ?? retainedDiagnostics
    }

    init(generation: UInt64, proxy: LegacyGatewayCompatibilityProxy) {
        self.generation = generation
        self.proxy = proxy
    }
}

actor BifrostSupervisor {
    private(set) var state: BifrostGatewayState = .stopped
    /// Stable only for this supervisor instance. A new app/supervisor lifetime receives a new
    /// value, while restarts of its sidecar keep the management client and config in sync.
    nonisolated let managementCredentials: BifrostManagementCredentials
    nonisolated let requestActivity: AsyncStream<BifrostRequestActivity>
    /// Lifecycle changes are payload-free so UI consumers can follow an unexpected sidecar exit
    /// without polling or gaining access to process output.
    nonisolated let stateChanges: AsyncStream<BifrostGatewayState>

    /// Returns a live snapshot while Bifrost is running and the retained final snapshot after it stops.
    var diagnostics: BifrostProcessDiagnostics {
        activeResources?.diagnostics ?? retainedDiagnostics
    }

    /// Internal observability used to verify that stopped processes retain no FileHandle callbacks.
    var hasActiveOutputReaders: Bool { activeResources?.outputPipes != nil }

    private var lifecycleGeneration: UInt64 = 0
    private var activeResources: BifrostLifecycleResources?
    private var retiringResources: [BifrostLifecycleResources] = []
    private var retainedDiagnostics = BifrostProcessDiagnostics.empty
    private let fileManager: FileManager
    private let session: URLSession
    private let environment: [String: String]
    private let logByteLimitPerStream: Int
    private let healthCheckAttempts: Int
    private let healthCheckIntervalNanoseconds: UInt64
    private let requestActivityContinuation: AsyncStream<BifrostRequestActivity>.Continuation
    private let stateChangesContinuation: AsyncStream<BifrostGatewayState>.Continuation
    /// Test-only scheduling seam used to prove that an old termination observation cannot mutate a
    /// newer generation. Production uses the direct observation path.
    private let processTerminationObserver: (@Sendable (@Sendable () async -> Void) async -> Void)?

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logByteLimitPerStream: Int = 32 * 1_024,
        // A first launch runs both config-store and log-store migrations before
        // the HTTP listener opens. On slower external/APFS volumes the pinned
        // v1.6.11 helper can legitimately need more than 20 seconds, so keep a
        // one-minute startup envelope while retaining the 100 ms responsive poll.
        healthCheckAttempts: Int = 600,
        healthCheckIntervalNanoseconds: UInt64 = 100_000_000,
        processTerminationObserver: (
            @Sendable (@Sendable () async -> Void) async -> Void
        )? = nil
    ) {
        var activityContinuation: AsyncStream<BifrostRequestActivity>.Continuation?
        requestActivity = AsyncStream(bufferingPolicy: .bufferingNewest(128)) {
            activityContinuation = $0
        }
        requestActivityContinuation = activityContinuation!
        var gatewayStateContinuation: AsyncStream<BifrostGatewayState>.Continuation?
        stateChanges = AsyncStream(bufferingPolicy: .bufferingNewest(16)) {
            gatewayStateContinuation = $0
        }
        stateChangesContinuation = gatewayStateContinuation!
        managementCredentials = .generate()
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.logByteLimitPerStream = max(1, logByteLimitPerStream)
        self.healthCheckAttempts = max(1, healthCheckAttempts)
        self.healthCheckIntervalNanoseconds = healthCheckIntervalNanoseconds
        self.processTerminationObserver = processTerminationObserver
        stateChangesContinuation.yield(.stopped)
    }

    deinit {
        requestActivityContinuation.finish()
        stateChangesContinuation.finish()
    }

    func start(config: AppConfig) async throws {
        let generation = advanceLifecycleGeneration()
        if let activeResources { retire(activeResources) }
        retainedDiagnostics = .empty
        updateState(.starting)
        await disposeRetiringResources()
        guard generation == lifecycleGeneration else { throw CancellationError() }

        let appDir = bifrostAppDirectory()
        do {
            try preparePrivateAppDirectory(appDir)
            // Bifrost creates SQLite files with the process umask (commonly 0644). Keeping the
            // store directory private prevents prompts, responses, and provider configuration
            // from being readable by other local accounts even before individual files exist.
            // v1.6.11 loads any persisted model-parameter rows before refreshing the configured
            // catalog in the background. Clear only that derived cache while the helper is
            // stopped, forcing startup to synchronously load the just-generated local catalog.
            // Provider/governance settings remain available for config.json reconciliation.
            try resetModelParametersCache(in: appDir)
            let generated = try BifrostConfigBuilder.build(
                from: config,
                logDatabaseURL: appDir.appendingPathComponent("logs.db"),
                managementCredentials: managementCredentials
            )
            try SecureAtomicFile.write(
                BifrostConfigBuilder.modelParametersData(from: config),
                to: appDir.appendingPathComponent(BifrostConfigBuilder.modelParametersFileName),
                fileManager: fileManager
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try SecureAtomicFile.write(
                encoder.encode(generated),
                to: appDir.appendingPathComponent("config.json"),
                fileManager: fileManager
            )
        } catch {
            if generation == lifecycleGeneration {
                updateState(.failed(error.localizedDescription))
            }
            throw error
        }

        guard let binary = binaryURL() else {
            if generation == lifecycleGeneration {
                updateState(.failed(BifrostError.binaryMissing.localizedDescription))
            }
            throw BifrostError.binaryMissing
        }

        let backendReservation: LoopbackPortReservation
        do {
            backendReservation = try LoopbackPortReservation(excluding: config.port)
        } catch {
            let failure = startupFailure(for: error, diagnostics: .empty)
            if generation == lifecycleGeneration {
                updateState(.failed(failure.localizedDescription))
            }
            throw failure
        }

        let activityContinuation = requestActivityContinuation
        let proxy = LegacyGatewayCompatibilityProxy(
            modelRouting: LegacyModelRoutingCompatibility(config: config)
        ) { activity in
            activityContinuation.yield(activity)
        }
        let resources = BifrostLifecycleResources(generation: generation, proxy: proxy)
        activeResources = resources
        do {
            try await proxy.start(
                publicPort: config.port,
                backendPort: backendReservation.port
            )
        } catch {
            guard owns(resources) else { throw CancellationError() }
            retire(resources)
            await disposeRetiringResources()
            let failure = startupFailure(for: error, diagnostics: resources.diagnostics)
            if generation == lifecycleGeneration {
                retainedDiagnostics = resources.diagnostics
                updateState(.failed(failure.localizedDescription))
            }
            throw failure
        }
        guard owns(resources) else { throw CancellationError() }

        let child = Process()
        child.executableURL = binary
        child.environment = BifrostChildProcessEnvironment.make(overrides: environment)
        child.arguments = [
            "-app-dir", appDir.path, "-host", "127.0.0.1",
            "-port", String(backendReservation.port),
            "-log-level", "info", "-log-style", "json"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        let capture = BifrostOutputCapture(byteLimitPerStream: logByteLimitPerStream)
        capture.attach(stdout: stdout, stderr: stderr)
        child.standardOutput = stdout
        child.standardError = stderr
        resources.process = child
        resources.outputPipes = (stdout, stderr)
        resources.outputCapture = capture
        let processToken = resources.processToken
        let terminationObserver = processTerminationObserver
        child.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let observation: @Sendable () async -> Void = { [weak self] in
                await self?.processDidTerminate(
                    generation: generation,
                    processToken: processToken,
                    status: status
                )
            }
            Task {
                if let terminationObserver {
                    await terminationObserver(observation)
                } else {
                    await observation()
                }
            }
        }

        // Keep the selected backend port unavailable until the listener-facing compatibility
        // proxy is ready, then hand it directly to the pinned Bifrost child.
        backendReservation.release()
        do {
            try child.run()
            resources.didLaunchProcess = true
        } catch {
            guard owns(resources) else { throw CancellationError() }
            retire(resources)
            await disposeRetiringResources()
            let failure = startupFailure(for: error, diagnostics: resources.diagnostics)
            if generation == lifecycleGeneration {
                retainedDiagnostics = resources.diagnostics
                updateState(.failed(failure.localizedDescription))
            }
            throw failure
        }
        // Process has duplicated these descriptors for the child. Keeping the parent's write ends
        // open would prevent the read ends from ever observing EOF during shutdown.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        do {
            try await waitForHealth(port: backendReservation.port, process: child)
            try validate(resources, process: child)
            // The public health probe proves both parts of the gateway are usable: the
            // compatibility listener and the pinned Bifrost backend behind it.
            try await waitForHealth(port: config.port, process: child)
            try validate(resources, process: child)
            securePersistentStoreFiles(in: appDir)
            updateState(.running(port: config.port))
        } catch {
            guard owns(resources) else {
                guard generation == lifecycleGeneration else { throw CancellationError() }
                if let status = resources.unexpectedExitStatus {
                    throw startupFailure(
                        for: BifrostError.exited(status),
                        diagnostics: resources.diagnostics
                    )
                }
                throw CancellationError()
            }
            retire(resources)
            await disposeRetiringResources()
            let failure = startupFailure(for: error, diagnostics: resources.diagnostics)
            if generation == lifecycleGeneration {
                retainedDiagnostics = resources.diagnostics
                updateState(.failed(failure.localizedDescription))
            }
            throw failure
        }
    }

    func stop() async {
        let generation = advanceLifecycleGeneration()
        let stoppedResources = activeResources ?? retiringResources.last
        if let activeResources { retire(activeResources) }
        await disposeRetiringResources()
        guard generation == lifecycleGeneration else { return }
        if let stoppedResources {
            retainedDiagnostics = stoppedResources.diagnostics
        }
        updateState(.stopped)
    }

    private func advanceLifecycleGeneration() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    private func owns(_ resources: BifrostLifecycleResources) -> Bool {
        lifecycleGeneration == resources.generation && activeResources === resources
    }

    private func validate(
        _ resources: BifrostLifecycleResources,
        process: Process
    ) throws {
        guard owns(resources) else { throw CancellationError() }
        guard process.isRunning else { throw BifrostError.exited(process.terminationStatus) }
    }

    private func retire(_ resources: BifrostLifecycleResources) {
        if activeResources === resources { activeResources = nil }
        resources.proxy.stop()
        if !resources.isDisposed,
           !retiringResources.contains(where: { $0 === resources }) {
            retiringResources.append(resources)
        }
    }

    private func disposeRetiringResources() async {
        while let resources = retiringResources.first {
            await dispose(resources, terminateProcess: true)
        }
    }

    private func dispose(
        _ resources: BifrostLifecycleResources,
        terminateProcess: Bool
    ) async {
        if resources.isDisposed { return }
        if resources.isDisposing {
            await withCheckedContinuation { continuation in
                resources.disposalWaiters.append(continuation)
            }
            return
        }

        resources.isDisposing = true
        resources.proxy.stop()
        let child = resources.process
        if terminateProcess, let child { await terminate(child) }
        resources.process = nil
        let drainAfterExit = resources.didLaunchProcess && child?.isRunning == false
        finishOutputCapture(resources, drainAfterExit: drainAfterExit)
        resources.isDisposed = true
        resources.isDisposing = false
        retiringResources.removeAll { $0 === resources }
        let waiters = resources.disposalWaiters
        resources.disposalWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func processDidTerminate(
        generation: UInt64,
        processToken: UUID,
        status: Int32
    ) async {
        guard lifecycleGeneration == generation,
              let resources = activeResources,
              resources.generation == generation,
              resources.processToken == processToken else { return }

        let wasRunning = state.isRunning
        resources.unexpectedExitStatus = status
        retire(resources)
        let exit = BifrostError.exited(status)
        if wasRunning { updateState(.failed(exit.localizedDescription)) }
        await dispose(resources, terminateProcess: false)
        guard generation == lifecycleGeneration else { return }
        retainedDiagnostics = resources.diagnostics
        if !wasRunning {
            let failure = startupFailure(for: exit, diagnostics: resources.diagnostics)
            updateState(.failed(failure.localizedDescription))
        }
    }

    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 {
            if !process.isRunning { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        for _ in 0..<20 {
            if !process.isRunning { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func finishOutputCapture(
        _ resources: BifrostLifecycleResources,
        drainAfterExit: Bool
    ) {
        guard let pipes = resources.outputPipes,
              let capture = resources.outputCapture else { return }
        capture.detachAndDrain(
            stdout: pipes.stdout,
            stderr: pipes.stderr,
            drainAfterExit: drainAfterExit
        )
        resources.retainedDiagnostics = capture.snapshot()
        resources.outputPipes = nil
        resources.outputCapture = nil
    }

    private func startupFailure(
        for error: Error,
        diagnostics: BifrostProcessDiagnostics
    ) -> BifrostError {
        if case let failure as BifrostError = error,
           case .startupFailed = failure {
            return failure
        }
        return .startupFailed(
            reason: error.localizedDescription,
            diagnostics: diagnostics
        )
    }

    private func updateState(_ newState: BifrostGatewayState) {
        guard state != newState else { return }
        state = newState
        stateChangesContinuation.yield(streamSafeState(newState))
    }

    private func streamSafeState(_ state: BifrostGatewayState) -> BifrostGatewayState {
        guard case .failed(let message) = state else { return state }
        // Startup diagnostics remain available through the actor's explicit `diagnostics` and
        // `state` snapshots, but are never broadcast. `startupFailed` appends them after a blank
        // line, while the first paragraph contains only the localized lifecycle reason.
        let reason = message.components(separatedBy: "\n\n").first ?? "Bifrost 服务不可用"
        return .failed(reason)
    }

    private func waitForHealth(port: Int, process: Process) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<healthCheckAttempts {
            if !process.isRunning { throw BifrostError.exited(process.terminationStatus) }
            if let (_, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            if healthCheckIntervalNanoseconds > 0 {
                try await Task.sleep(nanoseconds: healthCheckIntervalNanoseconds)
            }
        }
        throw BifrostError.healthTimeout
    }

    private func bifrostAppDirectory() -> URL {
        if let override = environment["CCBUD_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("bifrost", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccbud", isDirectory: true)
            .appendingPathComponent("bifrost", isDirectory: true)
    }

    /// Never chmod or write through a pre-existing symlink. This is especially important for
    /// packaged self-check, whose otherwise isolated root is supplied by an external harness.
    private func preparePrivateAppDirectory(_ directory: URL) throws {
        var metadata = stat()
        let initialStatus = directory.path.withCString { Darwin.lstat($0, &metadata) }
        if initialStatus == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw BifrostError.unsafeAppDirectory("目标不是普通目录")
            }
        } else {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        metadata = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw BifrostError.unsafeAppDirectory("目录创建后未通过无符号链接校验")
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func securePersistentStoreFiles(in appDirectory: URL) {
        let names = [
            "config.db", "config.db-wal", "config.db-shm",
            "logs.db", "logs.db-wal", "logs.db-shm",
        ]
        for name in names {
            let path = appDirectory.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func resetModelParametersCache(in appDirectory: URL) throws {
        let databaseURL = appDirectory.appendingPathComponent("config.db")
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BifrostError.catalogCacheResetFailed("config.db 不是普通文件")
        }

        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let detail = database.flatMap(sqlite3_errmsg).map(String.init(cString:))
                ?? "SQLite 错误 \(openStatus)"
            if let database { sqlite3_close(database) }
            throw BifrostError.catalogCacheResetFailed(detail)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        var statement: OpaquePointer?
        let lookup = "SELECT 1 FROM sqlite_master WHERE type='table' "
            + "AND name='governance_model_parameters' LIMIT 1"
        guard sqlite3_prepare_v2(database, lookup, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw BifrostError.catalogCacheResetFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return }

        var message: UnsafeMutablePointer<CChar>?
        let deleteStatus = sqlite3_exec(
            database,
            "DELETE FROM governance_model_parameters",
            nil,
            nil,
            &message
        )
        defer { if let message { sqlite3_free(message) } }
        guard deleteStatus == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw BifrostError.catalogCacheResetFailed(detail)
        }
    }

    private func binaryURL() -> URL? {
#if DEBUG
        if let path = environment["CCBUD_BIFROST_BINARY"], fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
#endif
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "bifrost-http"),
           fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/bifrost-http")
        return fileManager.isExecutableFile(atPath: development.path) ? development : nil
    }
}

private final class BifrostOutputCapture: @unchecked Sendable {
    private enum Stream: Sendable {
        case stdout, stderr
    }

    private let lock = NSLock()
    private let readers = DispatchGroup()
    private let byteLimitPerStream: Int
    private var stdoutData = Data()
    private var stderrData = Data()
    private var isAttached = false

    init(byteLimitPerStream: Int) {
        self.byteLimitPerStream = max(1, byteLimitPerStream)
    }

    func attach(stdout: Pipe, stderr: Pipe) {
        lock.lock()
        isAttached = true
        lock.unlock()
        startReader(on: stdout.fileHandleForReading, stream: .stdout)
        startReader(on: stderr.fileHandleForReading, stream: .stderr)
    }

    func detachAndDrain(stdout: Pipe, stderr: Pipe, drainAfterExit: Bool) {
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        if drainAfterExit {
            // The readers normally reach EOF immediately after the child exits. Keep the join
            // bounded because a grandchild may have inherited a pipe descriptor.
            if readers.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                _ = readers.wait(timeout: .now() + .milliseconds(250))
            }
        } else {
            markDetached()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            _ = readers.wait(timeout: .now() + .milliseconds(250))
        }

        markDetached()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func snapshot() -> BifrostProcessDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return BifrostProcessDiagnostics(
            standardOutput: String(decoding: stdoutData, as: UTF8.self),
            standardError: String(decoding: stderrData, as: UTF8.self),
            standardOutputBytes: stdoutData.count,
            standardErrorBytes: stderrData.count
        )
    }

    private func startReader(on handle: FileHandle, stream: Stream) {
        readers.enter()
        let readers = readers
        let thread = Thread { [weak self] in
            defer { readers.leave() }
            self?.readUntilEOF(from: handle, stream: stream)
        }
        thread.name = switch stream {
        case .stdout: "dev.ccbud.bifrost.stdout"
        case .stderr: "dev.ccbud.bifrost.stderr"
        }
        // Draining is part of process liveness: a starved reader lets a full pipe block Bifrost.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func readUntilEOF(from handle: FileHandle, stream: Stream) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            let data = Data(buffer.prefix(count))

            lock.lock()
            guard isAttached else {
                lock.unlock()
                return
            }
            appendLocked(data, stream: stream)
            lock.unlock()
        }
    }

    private func markDetached() {
        lock.lock()
        isAttached = false
        lock.unlock()
    }

    private func appendLocked(_ data: Data, stream: Stream) {
        switch stream {
        case .stdout: appendBounded(data, to: &stdoutData)
        case .stderr: appendBounded(data, to: &stderrData)
        }
    }

    private func appendBounded(_ newData: Data, to retained: inout Data) {
        if newData.count >= byteLimitPerStream {
            retained = Data(newData.suffix(byteLimitPerStream))
            return
        }
        let excess = retained.count + newData.count - byteLimitPerStream
        if excess > 0 { retained.removeFirst(excess) }
        retained.append(newData)
    }
}

/// The Rust gateway accepted these root request targets before the native migration. Bifrost
/// deliberately keeps provider-compatible codecs under namespaces, so translate only the old
/// public targets and leave every other Bifrost route byte-for-byte unchanged.
struct LegacyModelRoute: Equatable, Sendable {
    let requestedModel: String?
    let outgoingModel: String?
    /// Explicit configured aliases are deliberately left for Bifrost's native alias resolver so
    /// they retain precedence and Bifrost records its ordinary `alias` field.
    let usesNativeAlias: Bool

    var needsResponseRestoration: Bool {
        guard let requestedModel, let outgoingModel else { return false }
        return requestedModel != outgoingModel
    }

    var needsRequestBodyRewrite: Bool {
        needsResponseRestoration && !usesNativeAlias
    }
}

final class LegacyKnownModelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var models: Set<String>

    init(_ models: Set<String> = []) { self.models = models }

    func contains(_ model: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return models.contains(model)
    }

    func replace(with models: Set<String>) {
        guard !models.isEmpty else { return }
        lock.lock()
        self.models = models
        lock.unlock()
    }
}

/// Caller-specific compatibility for the legacy gateway's `/v1/models` surface. The old Rust
/// gateway advertised configured aliases first, followed by stable Claude/Codex tier identities,
/// while retaining every upstream entry and caching only the upstream identifiers for routing.
struct LegacyModelListCompatibility: Equatable, Sendable {
    private static let claudeTierModels = [
        "claude-fable-5",
        "claude-opus-4-8",
        "claude-sonnet-5",
        "claude-haiku-4-5",
        "claude-haiku-4-5-20251001",
    ]
    private static let codexTierModels = ["gpt-5.4", "gpt-5.4-mini"]

    let aliases: [String]
    let configuredFallbacks: [String]
    let tierModels: [String]

    init(provider: Provider?, aliases: [String]? = nil, isCodex: Bool) {
        self.aliases = Self.unique(aliases ?? provider?.models.compactMap { mapping in
            mapping.alias.isEmpty ? nil : mapping.alias
        } ?? [])
        configuredFallbacks = Self.unique([
            provider?.defaultModel ?? "",
            provider?.smallFastModel ?? "",
        ].filter { !$0.isEmpty })
        tierModels = isCodex ? Self.codexTierModels : Self.claudeTierModels
    }

    /// Returns a merged legacy list and the original upstream identifiers. Invalid/error model
    /// responses use the same synthesized fallback that the Rust gateway returned with HTTP 200.
    func responseBody(
        from upstreamBody: Data,
        upstreamSucceeded: Bool
    ) -> (body: Data, upstreamModels: Set<String>) {
        if upstreamSucceeded,
           var object = (try? JSONSerialization.jsonObject(with: upstreamBody)) as? [String: Any],
           let upstreamEntries = object["data"] as? [Any] {
            let upstreamModels = Set(upstreamEntries.compactMap { entry -> String? in
                (entry as? [String: Any])?["id"] as? String
            })
            var have = upstreamModels
            let additions = (aliases + tierModels).compactMap { identifier -> [String: Any]? in
                guard have.insert(identifier).inserted else { return nil }
                return Self.modelEntry(identifier)
            }
            object["data"] = additions + upstreamEntries
            if let encoded = try? JSONSerialization.data(withJSONObject: object) {
                return (encoded, upstreamModels)
            }
        }

        var have = Set<String>()
        let base = aliases.isEmpty ? configuredFallbacks : aliases
        let identifiers = (base + tierModels).filter { have.insert($0).inserted }
        let entries = identifiers.map(Self.modelEntry)
        let synthesized: [String: Any] = [
            "data": entries,
            "has_more": false,
            "first_id": identifiers.first.map { $0 as Any } ?? NSNull(),
            "last_id": identifiers.last.map { $0 as Any } ?? NSNull(),
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: synthesized)) ?? Data(#"{"data":[]}"#.utf8)
        return (encoded, [])
    }

    private static func modelEntry(_ identifier: String) -> [String: Any] {
        [
            "type": "model",
            "id": identifier,
            "display_name": identifier,
            "created_at": "2025-01-01T00:00:00Z",
        ]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Conservative structural fallback for Anthropic's count-tokens endpoint. The Rust gateway uses
/// o200k_base when available and falls back to UTF-8 bytes / 4; the native app deliberately keeps
/// the dependency-free fallback while matching Rust's framing, tool, image, and safety overheads.
enum LegacyCountTokensEstimator {
    private static let base = 5
    private static let perMessage = 4
    private static let systemFraming = 4
    private static let toolsFraming = 15
    private static let image = 1_600
    private static let safety = 1.06

    static func estimate(_ value: Any?) -> Int {
        guard let body = value as? [String: Any] else {
            return applySafety(to: base)
        }
        var tokens = 0

        if let system = body["system"] as? String {
            tokens += count(system)
        } else if let blocks = body["system"] as? [Any] {
            for case let block as [String: Any] in blocks where block["type"] as? String == "text" {
                tokens += count(block["text"] as? String ?? "")
            }
        }
        let hasSystem = body["system"].map { !($0 is NSNull) } ?? false

        let messages = body["messages"] as? [Any] ?? []
        for case let message as [String: Any] in messages {
            if let text = message["content"] as? String {
                tokens += count(text)
                continue
            }
            guard let blocks = message["content"] as? [Any] else { continue }
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "text":
                    tokens += count(block["text"] as? String ?? "")
                case "tool_use":
                    tokens += count(block["name"] as? String ?? "")
                    tokens += count(safeJSON(block["input"]))
                case "tool_result":
                    if let text = block["content"] as? String {
                        tokens += count(text)
                    } else if let content = block["content"] as? [Any] {
                        for case let item as [String: Any] in content
                        where item["type"] as? String == "text" {
                            tokens += count(item["text"] as? String ?? "")
                        }
                    }
                case "image":
                    tokens += image
                default:
                    break
                }
            }
        }

        let tools = body["tools"] as? [Any] ?? []
        for case let tool as [String: Any] in tools {
            tokens += count(tool["name"] as? String ?? "")
            tokens += count(tool["description"] as? String ?? "")
            tokens += count(safeJSON(tool["input_schema"]))
        }

        let overhead = base
            + perMessage * messages.count
            + (hasSystem ? systemFraming : 0)
            + (tools.isEmpty ? 0 : toolsFraming)
        return applySafety(to: tokens + overhead)
    }

    private static func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.utf8.count + 3) / 4
    }

    private static func safeJSON(_ value: Any?) -> String {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]
              ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func applySafety(to value: Int) -> Int {
        max(1, Int(ceil(Double(value) * safety)))
    }
}

/// A literal port of `src-tauri/src/gateway/routing.rs`. Keeping this decision outside Bifrost is
/// necessary because v1.6.11 aliases are exact-only, while CC Buddy historically accepted whole
/// Claude/Codex model families and a primary-tier `-ccbud` sentinel.
struct LegacyModelRoutingCompatibility: Sendable {
    private let provider: Provider?
    private let modelListAliases: [String]
    let knownModelStore: LegacyKnownModelStore

    init(provider: Provider?, knownModels: Set<String> = []) {
        self.provider = provider
        modelListAliases = provider?.models.compactMap {
            $0.alias.isEmpty ? nil : $0.alias
        } ?? []
        knownModelStore = LegacyKnownModelStore(knownModels)
    }

    init(config: AppConfig, knownModels: Set<String> = []) {
        provider = config.activeProvider
        modelListAliases = config.providers.flatMap { provider in
            provider.models.compactMap { $0.alias.isEmpty ? nil : $0.alias }
        }
        knownModelStore = LegacyKnownModelStore(knownModels)
    }

    func modelListCompatibility(isCodex: Bool) -> LegacyModelListCompatibility {
        LegacyModelListCompatibility(
            provider: provider,
            aliases: modelListAliases,
            isCodex: isCodex
        )
    }

    func resolve(_ requestedModel: String?) -> LegacyModelRoute? {
        guard let provider else { return nil }
        guard let requestedModel else {
            return .init(requestedModel: nil, outgoingModel: nil, usesNativeAlias: false)
        }

        for mapping in provider.models
        where !mapping.alias.isEmpty
            && mapping.alias == requestedModel
            && !mapping.upstream.isEmpty {
            return .init(
                requestedModel: requestedModel,
                outgoingModel: mapping.upstream,
                usesNativeAlias: true
            )
        }

        let primary = provider.defaultModel
        let fast = provider.smallFastModel
        if requestedModel == primary || requestedModel == fast
            || provider.models.contains(where: { $0.upstream == requestedModel })
            || knownModelStore.contains(requestedModel) {
            return .init(
                requestedModel: requestedModel,
                outgoingModel: requestedModel,
                usesNativeAlias: false
            )
        }

        if requestedModel.hasSuffix("-ccbud") {
            let target = primary.isEmpty ? fast : primary
            if !target.isEmpty {
                return .init(
                    requestedModel: requestedModel,
                    outgoingModel: target,
                    usesNativeAlias: false
                )
            }
        }

        guard provider.mapDefaultModels else {
            return .init(
                requestedModel: requestedModel,
                outgoingModel: requestedModel,
                usesNativeAlias: false
            )
        }

        let big = primary.isEmpty ? fast : primary
        let small = fast.isEmpty ? primary : fast
        let lower = requestedModel.lowercased()
        let target: String
        if lower.hasPrefix("claude-") || lower.hasPrefix("claude_") {
            target = lower.contains("haiku") ? small : big
        } else if lower.hasPrefix("gpt-") || lower.hasPrefix("gpt_") {
            let segments = lower.split(whereSeparator: { $0 == "-" || $0 == "_" })
            let explicitlySmall = segments.contains {
                $0 == "mini" || $0 == "nano" || $0 == "luna" || $0 == "spark"
            }
            let explicitlyPrimary = lower == "gpt-5.4" || (!explicitlySmall && segments.contains {
                $0 == "sol" || $0 == "terra"
            })
            target = explicitlyPrimary ? big : small
        } else {
            target = small
        }

        guard !target.isEmpty else {
            return .init(
                requestedModel: requestedModel,
                outgoingModel: requestedModel,
                usesNativeAlias: false
            )
        }
        return .init(
            requestedModel: requestedModel,
            outgoingModel: target,
            usesNativeAlias: false
        )
    }
}

enum LegacyGatewayRouteCompatibility {
    static let destinations: [String: String] = [
        "/messages": "/anthropic/v1/messages",
        "/v1/messages": "/anthropic/v1/messages",
        "/chat/completions": "/openai/v1/chat/completions",
        "/v1/chat/completions": "/openai/v1/chat/completions",
        "/responses": "/openai/v1/responses",
        "/v1/responses": "/openai/v1/responses",
        "/responses/compact": "/openai/v1/responses/compact",
        "/v1/responses/compact": "/openai/v1/responses/compact",
        // This route was handled specially by the legacy gateway even though wire.rs excludes
        // it from provider-endpoint rebasing.
        "/v1/messages/count_tokens": "/anthropic/v1/messages/count_tokens",
    ]

    static var legacyRoutes: [String] { destinations.keys.sorted() }

    /// Monitor activity is limited to inference traffic. In particular, management polling must
    /// not trigger another monitor refresh and create a self-sustaining request loop.
    static func reportsInferenceActivity(for requestTarget: String) -> Bool {
        if destination(for: requestTarget) != nil { return true }

        let path: String
        if requestTarget.hasPrefix("/") {
            path = String(requestTarget.prefix { $0 != "?" })
        } else if let components = URLComponents(string: requestTarget),
                  components.scheme != nil, components.host != nil {
            path = components.percentEncodedPath
        } else {
            return false
        }
        return path == "/v1" || path.hasPrefix("/v1/")
            || path == "/anthropic" || path.hasPrefix("/anthropic/")
            || path == "/openai" || path.hasPrefix("/openai/")
    }

    static func capturesKnownModels(method: String, requestTarget: String) -> Bool {
        guard method.caseInsensitiveCompare("GET") == .orderedSame else { return false }
        guard let path = requestPath(for: requestTarget) else { return false }
        let normalized = path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast())
            : path
        return normalized.hasSuffix("/v1/models")
    }

    static func isHeadRoot(method: String, requestTarget: String) -> Bool {
        method.caseInsensitiveCompare("HEAD") == .orderedSame
            && requestPath(for: requestTarget) == "/"
    }

    static func isCountTokens(method: String, requestTarget: String) -> Bool {
        guard method.caseInsensitiveCompare("POST") == .orderedSame,
              let path = requestPath(for: requestTarget) else { return false }
        return path.hasSuffix("/v1/messages/count_tokens")
            || path.hasSuffix("/v1/messages/count_tokens/")
    }

    private static func requestPath(for requestTarget: String) -> String? {
        if requestTarget.hasPrefix("/") {
            return String(requestTarget.prefix { $0 != "?" })
        }
        guard let components = URLComponents(string: requestTarget),
              components.scheme != nil, components.host != nil else { return nil }
        return components.percentEncodedPath
    }

    /// Returns a Bifrost request target for an exact legacy route. Query strings survive intact,
    /// while trailing slashes retain wire.rs's `trim_end_matches('/')` behavior.
    static func destination(for requestTarget: String) -> String? {
        let path: String
        let suffix: String
        if requestTarget.hasPrefix("/") {
            if let query = requestTarget.firstIndex(of: "?") {
                path = String(requestTarget[..<query])
                suffix = String(requestTarget[query...])
            } else {
                path = requestTarget
                suffix = ""
            }
        } else if let components = URLComponents(string: requestTarget),
                  components.scheme != nil, components.host != nil {
            path = components.percentEncodedPath
            suffix = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        } else {
            return nil
        }

        var normalizedPath = path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        guard let destination = destinations[normalizedPath] else { return nil }
        return destination + suffix
    }

    fileprivate static func analyze(_ header: Data) -> LegacyHTTPRequestHeaderPlan {
        let delimiter = Data([13, 10])
        guard let lineRange = header.range(of: delimiter),
              let firstLine = String(data: header[..<lineRange.lowerBound], encoding: .isoLatin1)
        else {
            return .init(
                header: header, framing: .tunnel, method: "", reportsActivity: false
            )
        }

        let components = firstLine.split(
            separator: " ", maxSplits: 2, omittingEmptySubsequences: false
        )
        guard components.count == 3 else {
            return .init(
                header: header, framing: .tunnel, method: "", reportsActivity: false
            )
        }
        let method = String(components[0])
        let requestTarget = String(components[1])
        let reportsActivity = reportsInferenceActivity(for: requestTarget)
        let capturesKnownModels = capturesKnownModels(
            method: method, requestTarget: requestTarget
        )
        let isCountTokens = isCountTokens(method: method, requestTarget: requestTarget)
        let modelListIsCodex = capturesKnownModels && clientIsCodex(header)
        var rewrittenHeader = header
        if let destination = destination(for: requestTarget) {
            let rewrittenLine = "\(method) \(destination) \(components[2])"
            rewrittenHeader = Data(rewrittenLine.utf8)
            rewrittenHeader.append(header[lineRange.lowerBound...])
        }
        // This value is trusted only when added by the proxy after it parses the body. Remove a
        // caller-supplied copy even on requests whose model ultimately passes through unchanged.
        rewrittenHeader = LegacyHTTPHeaderEditing.rewrite(
            rewrittenHeader,
            removing: [LegacyRequestedModelMetadata.headerName]
        )
        if capturesKnownModels || isCountTokens {
            // The legacy reqwest client decoded compressed list responses before caching and
            // merging, and did the same before validating count-token replies. Keep those sidecar
            // responses directly parseable when callers advertise compression.
            rewrittenHeader = LegacyHTTPHeaderEditing.rewrite(
                rewrittenHeader,
                removing: ["accept-encoding"],
                setting: [("Accept-Encoding", "identity")]
            )
        }

        guard let headerText = String(data: header, encoding: .isoLatin1) else {
            return .init(
                header: rewrittenHeader, framing: .tunnel, method: method,
                reportsActivity: reportsActivity,
                isCountTokens: isCountTokens
            )
        }
        var fields: [String: [String]] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .init(
                    header: rewrittenHeader, framing: .tunnel, method: method,
                    reportsActivity: reportsActivity,
                    isCountTokens: isCountTokens
                )
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
        let contentTypes = fields["content-type", default: []].map { $0.lowercased() }
        let buffersJSONModel = isCountTokens || (reportsActivity
            && contentTypes.contains(where: { $0.contains("application/json") }))
        let expectsContinue = fields["expect", default: []]
            .flatMap { $0.split(separator: ",") }
            .contains { $0.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare("100-continue") == .orderedSame }

        let connectionTokens = fields["connection", default: []]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if method.caseInsensitiveCompare("CONNECT") == .orderedSame
            || fields["upgrade"] != nil || connectionTokens.contains("upgrade") {
            return .init(
                header: rewrittenHeader, framing: .tunnel, method: method,
                reportsActivity: reportsActivity,
                buffersJSONModel: false,
                expectsContinue: false,
                capturesKnownModels: capturesKnownModels,
                modelListIsCodex: modelListIsCodex,
                isCountTokens: isCountTokens
            )
        }

        if let transferEncodings = fields["transfer-encoding"] {
            let tokens = transferEncodings
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return .init(
                header: rewrittenHeader,
                framing: tokens.last == "chunked" ? .chunked : .tunnel,
                method: method,
                reportsActivity: reportsActivity,
                buffersJSONModel: buffersJSONModel,
                expectsContinue: expectsContinue,
                capturesKnownModels: capturesKnownModels,
                modelListIsCodex: modelListIsCodex,
                isCountTokens: isCountTokens
            )
        }

        if let rawLengths = fields["content-length"] {
            let values = rawLengths.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = values.first.flatMap(Int.init), first >= 0,
                  values.allSatisfy({ Int($0) == first }) else {
                return .init(
                    header: rewrittenHeader, framing: .tunnel, method: method,
                    reportsActivity: reportsActivity,
                    buffersJSONModel: false,
                    expectsContinue: false,
                    capturesKnownModels: capturesKnownModels,
                    modelListIsCodex: modelListIsCodex,
                    isCountTokens: isCountTokens
                )
            }
            return .init(
                header: rewrittenHeader,
                framing: first == 0 ? .none : .fixed(first),
                method: method,
                reportsActivity: reportsActivity,
                buffersJSONModel: buffersJSONModel,
                expectsContinue: expectsContinue,
                capturesKnownModels: capturesKnownModels,
                modelListIsCodex: modelListIsCodex,
                isCountTokens: isCountTokens
            )
        }
        return .init(
            header: rewrittenHeader, framing: .none, method: method,
            reportsActivity: reportsActivity,
            buffersJSONModel: false,
            expectsContinue: false,
            capturesKnownModels: capturesKnownModels,
            modelListIsCodex: modelListIsCodex,
            isCountTokens: isCountTokens
        )
    }

    private static func clientIsCodex(_ header: Data) -> Bool {
        guard let text = String(data: header, encoding: .isoLatin1) else { return false }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "user-agent" || name == "originator" else { continue }
            let value = line[line.index(after: colon)...].lowercased()
            if value.contains("codex") { return true }
        }
        return false
    }
}

fileprivate struct LegacyHTTPRequestHeaderPlan {
    let header: Data
    let framing: LegacyHTTPRequestBodyFraming
    let method: String
    let reportsActivity: Bool
    let buffersJSONModel: Bool
    let expectsContinue: Bool
    let capturesKnownModels: Bool
    let modelListIsCodex: Bool
    let isHeadRoot: Bool
    let isCountTokens: Bool
    let countTokensRequestIsJSON: Bool

    init(
        header: Data,
        framing: LegacyHTTPRequestBodyFraming,
        method: String,
        reportsActivity: Bool,
        buffersJSONModel: Bool = false,
        expectsContinue: Bool = false,
        capturesKnownModels: Bool = false,
        modelListIsCodex: Bool = false,
        isHeadRoot: Bool? = nil,
        isCountTokens: Bool? = nil
    ) {
        let headerText = String(data: header, encoding: .isoLatin1) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        let requestFields = (lines.first ?? "").split(
            separator: " ", maxSplits: 2, omittingEmptySubsequences: false
        )
        let requestTarget = requestFields.count >= 2 ? String(requestFields[1]) : ""
        self.header = header
        self.framing = framing
        self.method = method
        self.reportsActivity = reportsActivity
        self.isHeadRoot = isHeadRoot ?? LegacyGatewayRouteCompatibility.isHeadRoot(
            method: method, requestTarget: requestTarget
        )
        self.isCountTokens = isCountTokens ?? LegacyGatewayRouteCompatibility.isCountTokens(
            method: method, requestTarget: requestTarget
        )
        countTokensRequestIsJSON = lines.dropFirst().contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].lowercased()
            return name == "content-type" && value.contains("application/json")
        }
        self.buffersJSONModel = buffersJSONModel || self.isCountTokens
        self.expectsContinue = expectsContinue
        self.capturesKnownModels = capturesKnownModels
        self.modelListIsCodex = modelListIsCodex
    }
}

fileprivate enum LegacyHTTPRequestBodyFraming {
    case none
    case fixed(Int)
    case chunked
    /// CONNECT, Upgrade, or malformed/unsupported framing must remain an opaque TCP stream.
    case tunnel
}

fileprivate enum LegacyGatewayProxyError: LocalizedError {
    case invalidPort(Int)
    case listenerStopped
    case requestHeaderTooLarge
    case requestBodyTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "无效的网关代理端口：\(port)"
        case .listenerStopped: "网关兼容代理在启动前停止"
        case .requestHeaderTooLarge: "网关请求头超过 64 KiB 限制"
        case .requestBodyTooLarge: "网关 JSON 请求体超过 64 MiB 限制"
        }
    }
}

fileprivate enum LegacyHTTPHeaderEditing {
    /// Rebuilds a header only when a named field actually changes. That conditional is what keeps
    /// the overwhelmingly common passthrough path byte-identical, including original casing and
    /// whitespace.
    static func rewrite(
        _ header: Data,
        removing namesToRemove: Set<String> = [],
        setting fieldsToSet: [(String, String)] = []
    ) -> Data {
        guard let text = String(data: header, encoding: .isoLatin1) else { return header }
        let components = text.components(separatedBy: "\r\n")
        guard components.count >= 3 else { return header }

        let removed = Set(namesToRemove.map { $0.lowercased() })
        let setNames = Set(fieldsToSet.map { $0.0.lowercased() })
        var sawModification = !fieldsToSet.isEmpty
        var output = [components[0]]
        for line in components.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                output.append(line)
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if removed.contains(name) || setNames.contains(name) {
                sawModification = true
            } else {
                output.append(line)
            }
        }
        guard sawModification else { return header }
        output.append(contentsOf: fieldsToSet.map { "\($0.0): \($0.1)" })
        output.append("")
        output.append("")
        return output.joined(separator: "\r\n").data(using: .isoLatin1) ?? header
    }

    static func replacingExisting(
        _ header: Data,
        fields replacements: [String: String]
    ) -> Data {
        guard let text = String(data: header, encoding: .isoLatin1) else { return header }
        let existing = Set(text.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            line.firstIndex(of: ":").map {
                line[..<$0].trimmingCharacters(in: .whitespaces).lowercased()
            }
        })
        let applicable = replacements
            .filter { existing.contains($0.key.lowercased()) }
            .sorted { $0.key < $1.key }
        guard !applicable.isEmpty else { return header }
        return rewrite(header, setting: applicable)
    }

    static func withFixedLength(_ header: Data, byteCount: Int) -> Data {
        rewrite(
            header,
            removing: ["content-length", "transfer-encoding", "trailer"],
            setting: [("Content-Length", String(byteCount))]
        )
    }

    static func withChunkedBody(_ header: Data) -> Data {
        rewrite(
            header,
            removing: ["content-length", "transfer-encoding", "trailer"],
            setting: [("Transfer-Encoding", "chunked")]
        )
    }

    static func withSuccessfulJSONBody(_ header: Data, byteCount: Int) -> Data {
        freshResponse(
            basedOn: header,
            status: "200 OK",
            fields: [
                ("Content-Type", "application/json"),
                ("Content-Length", String(byteCount)),
            ]
        )
    }

    static func withSuccessfulEmptyBody(
        _ header: Data,
        fields: [(String, String)]
    ) -> Data {
        freshResponse(
            basedOn: header,
            status: "200 OK",
            fields: fields
        )
    }

    static func withSuccessfulFixedBodyPreservingHeaders(
        _ header: Data,
        byteCount: Int,
        fields: [(String, String)]
    ) -> Data {
        guard let text = String(data: header, encoding: .isoLatin1) else {
            return freshResponse(
                basedOn: header,
                status: "200 OK",
                fields: fields + [("Content-Length", String(byteCount))]
            )
        }
        var lines = text.components(separatedBy: "\r\n")
        let version = lines.first?.split(separator: " ").first.map(String.init) ?? "HTTP/1.1"
        if lines.isEmpty { lines = [""] }
        lines[0] = "\(version) 200 OK"
        let successful = lines.joined(separator: "\r\n").data(using: .isoLatin1) ?? header
        return rewrite(
            successful,
            removing: ["content-length", "trailer", "transfer-encoding"],
            setting: fields + [("Content-Length", String(byteCount))]
        )
    }

    static func freshResponse(
        basedOn header: Data,
        status: String,
        fields: [(String, String)]
    ) -> Data {
        let text = String(data: header, encoding: .isoLatin1) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let version = lines.first?.split(separator: " ").first.map(String.init) ?? "HTTP/1.1"
        var output = ["\(version) \(status)"]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "connection" || name == "keep-alive" { output.append(line) }
        }
        output.append(contentsOf: fields.map { "\($0.0): \($0.1)" })
        output.append("")
        output.append("")
        return output.joined(separator: "\r\n").data(using: .isoLatin1)
            ?? Data("HTTP/1.1 \(status)\r\n\r\n".utf8)
    }
}

/// Reserves an ephemeral loopback port until the Bifrost process is ready to bind it.
private final class LoopbackPortReservation: @unchecked Sendable {
    let port: Int
    private let lock = NSLock()
    private var descriptor: Int32

    init(excluding excludedPort: Int? = nil) throws {
        var reservation = try Self.openReservation()
        if reservation.port == excludedPort {
            // Keep the colliding socket bound while asking the kernel for another ephemeral
            // port. Releasing it first can cause bind(port: 0) to immediately select it again.
            do {
                let replacement = try Self.openReservation()
                Darwin.close(reservation.descriptor)
                reservation = replacement
            } catch {
                Darwin.close(reservation.descriptor)
                throw error
            }
        }
        port = reservation.port
        descriptor = reservation.descriptor
    }

    private static func openReservation() throws -> (port: Int, descriptor: Int32) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }
        var shouldClose = true
        defer { if shouldClose { Darwin.close(descriptor) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Self.posixError() }

        var resolvedAddress = address
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw Self.posixError() }
        shouldClose = false
        return (Int(UInt16(bigEndian: resolvedAddress.sin_port)), descriptor)
    }

    func release() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    deinit { release() }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// A streaming loopback reverse proxy. It parses only HTTP request boundaries so aliases can be
/// rewritten on persistent connections; request bodies, response bytes, SSE, and upgraded streams
/// continue directly between the caller and the pinned Bifrost process.
private final class LegacyGatewayCompatibilityProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ccbud.gateway.compatibility-proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: LegacyGatewayProxyConnection] = [:]
    private var backendPort: NWEndpoint.Port?
    private let modelRouting: LegacyModelRoutingCompatibility
    private let onActivity: @Sendable (BifrostRequestActivity) -> Void

    init(
        modelRouting: LegacyModelRoutingCompatibility,
        onActivity: @escaping @Sendable (BifrostRequestActivity) -> Void
    ) {
        self.modelRouting = modelRouting
        self.onActivity = onActivity
    }

    func start(publicPort: Int, backendPort: Int) async throws {
        guard let publicEndpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: publicPort) ?? 0),
              let backendEndpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: backendPort) ?? 0),
              publicEndpointPort.rawValue != 0, backendEndpointPort.rawValue != 0 else {
            throw LegacyGatewayProxyError.invalidPort(publicPort)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: publicEndpointPort
        )
        let listener = try NWListener(using: parameters)
        self.backendPort = backendEndpointPort
        self.listener = listener

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let readiness = LegacyGatewayProxyReadiness(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        readiness.succeed()
                    case .failed(let error):
                        readiness.fail(error)
                    case .cancelled:
                        readiness.fail(LegacyGatewayProxyError.listenerStopped)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        backendPort = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        listener?.cancel()
        activeConnections.forEach { $0.cancel() }
    }

    private func accept(_ client: NWConnection) {
        lock.lock()
        guard listener != nil, let backendPort else {
            lock.unlock()
            client.cancel()
            return
        }
        let id = UUID()
        let bridge = LegacyGatewayProxyConnection(
            id: id,
            client: client,
            backendPort: backendPort,
            queue: queue,
            modelRouting: modelRouting,
            onActivity: onActivity
        ) { [weak self] id in
            self?.removeConnection(id)
        }
        connections[id] = bridge
        lock.unlock()
        bridge.start()
    }

    private func removeConnection(_ id: UUID) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()
    }
}

private final class LegacyGatewayProxyReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() { resume(with: .success(())) }
    func fail(_ error: Error) { resume(with: .failure(error)) }

    private func resume(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class LegacyGatewayProxyConnection: @unchecked Sendable {
    private let id: UUID
    private let client: NWConnection
    private let backend: NWConnection
    private let queue: DispatchQueue
    private let onFinish: @Sendable (UUID) -> Void
    private let onActivity: @Sendable (BifrostRequestActivity) -> Void
    private let finishLock = NSLock()
    private var finished = false
    private var requestRewriter: LegacyHTTPRequestStreamRewriter
    private var responseRewriter: LegacyHTTPResponseStreamRewriter
    private var pendingRequests: [LegacyGatewayRequestContext] = []

    init(
        id: UUID,
        client: NWConnection,
        backendPort: NWEndpoint.Port,
        queue: DispatchQueue,
        modelRouting: LegacyModelRoutingCompatibility,
        onActivity: @escaping @Sendable (BifrostRequestActivity) -> Void,
        onFinish: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.client = client
        self.backend = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"), port: backendPort, using: .tcp
        )
        self.queue = queue
        requestRewriter = LegacyHTTPRequestStreamRewriter(modelRouting: modelRouting)
        responseRewriter = LegacyHTTPResponseStreamRewriter(
            knownModelStore: modelRouting.knownModelStore
        )
        self.onActivity = onActivity
        self.onFinish = onFinish
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        backend.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        client.start(queue: queue)
        backend.start(queue: queue)
        receiveRequestBytes()
        receiveResponseBytes()
    }

    func cancel() { finish() }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func receiveRequestBytes() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                finish()
                return
            }
            let transformed: LegacyHTTPRequestTransformResult
            do {
                transformed = try requestRewriter.transform(data ?? Data())
            } catch {
                finish()
                return
            }
            for request in transformed.requests {
                pendingRequests.append(request)
                if request.reportsActivity { onActivity(.requestReceived) }
            }
            let forwardToBackend: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                send(transformed.data, isComplete: isComplete, to: backend) {
                    [weak self] succeeded in
                    guard let self, succeeded else { return }
                    if !isComplete { receiveRequestBytes() }
                }
            }
            if transformed.continueResponses > 0 {
                let interim = Data(
                    String(repeating: "HTTP/1.1 100 Continue\r\n\r\n", count: transformed.continueResponses)
                        .utf8
                )
                send(interim, isComplete: false, to: client) { succeeded in
                    if succeeded { forwardToBackend() }
                }
            } else {
                forwardToBackend()
            }
        }
    }

    private func receiveResponseBytes() {
        backend.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                finish()
                return
            }
            let transformed: LegacyHTTPResponseTransformResult
            do {
                transformed = try responseRewriter.transform(
                    data ?? Data(),
                    requests: &pendingRequests,
                    streamComplete: isComplete
                )
            } catch {
                finish()
                return
            }
            for _ in 0..<transformed.completedResponses { onActivity(.responseCompleted) }
            send(transformed.data, isComplete: isComplete, to: client) { [weak self] succeeded in
                guard let self, succeeded else { return }
                if isComplete { finish() }
                else { receiveResponseBytes() }
            }
        }
    }

    private func send(
        _ data: Data,
        isComplete: Bool,
        to connection: NWConnection,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        if data.isEmpty && !isComplete {
            completion(true)
            return
        }
        connection.send(
            content: data.isEmpty ? nil : data,
            contentContext: .defaultMessage,
            isComplete: isComplete,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    finish()
                    completion(false)
                } else {
                    completion(true)
                }
            }
        )
    }

    private func finish() {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()
        client.stateUpdateHandler = nil
        backend.stateUpdateHandler = nil
        client.cancel()
        backend.cancel()
        onFinish(id)
    }
}

struct LegacyHTTPRequestStreamRewriter {
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumBodyBytes = 64 * 1_024 * 1_024
    private static let maximumChunkWireBytes = maximumBodyBytes * 2

    private enum State {
        case header(Data)
        case fixedBody(Int)
        case chunkedBody(LegacyHTTPChunkedBodyScanner)
        case bufferedFixed(
            plan: LegacyHTTPRequestHeaderPlan,
            remaining: Int,
            body: Data
        )
        case bufferedChunked(
            plan: LegacyHTTPRequestHeaderPlan,
            scanner: LegacyHTTPChunkedBodyScanner,
            body: Data,
            wireBody: Data
        )
        case tunnel
    }

    private let modelRouting: LegacyModelRoutingCompatibility
    private var state: State = .header(Data())

    init(modelRouting: LegacyModelRoutingCompatibility) {
        self.modelRouting = modelRouting
    }

    mutating func transform(_ input: Data) throws -> LegacyHTTPRequestTransformResult {
        var pending = input
        var output = Data()
        var requests: [LegacyGatewayRequestContext] = []
        var continueResponses = 0
        while !pending.isEmpty {
            switch state {
            case .header(var buffered):
                buffered.append(pending)
                pending.removeAll(keepingCapacity: false)
                if let terminator = buffered.range(of: Self.headerTerminator) {
                    let header = Data(buffered[..<terminator.upperBound])
                    pending = Data(buffered[terminator.upperBound...])
                    let plan = LegacyGatewayRouteCompatibility.analyze(header)
                    switch plan.framing {
                    case .none:
                        output.append(plan.header)
                        requests.append(context(plan: plan, route: nil))
                        state = .header(Data())
                    case .fixed(let count) where plan.buffersJSONModel:
                        guard count <= Self.maximumBodyBytes else {
                            throw LegacyGatewayProxyError.requestBodyTooLarge
                        }
                        if plan.expectsContinue && pending.isEmpty { continueResponses += 1 }
                        state = .bufferedFixed(plan: plan, remaining: count, body: Data())
                    case .chunked where plan.buffersJSONModel:
                        if plan.expectsContinue && pending.isEmpty { continueResponses += 1 }
                        state = .bufferedChunked(
                            plan: plan, scanner: .init(), body: Data(), wireBody: Data()
                        )
                    case .fixed(let count):
                        output.append(plan.header)
                        requests.append(context(plan: plan, route: nil))
                        state = .fixedBody(count)
                    case .chunked:
                        output.append(plan.header)
                        requests.append(context(plan: plan, route: nil))
                        state = .chunkedBody(.init())
                    case .tunnel:
                        output.append(plan.header)
                        requests.append(context(plan: plan, route: nil))
                        state = .tunnel
                    }
                } else {
                    guard buffered.count <= Self.maximumHeaderBytes else {
                        throw LegacyGatewayProxyError.requestHeaderTooLarge
                    }
                    state = .header(buffered)
                }

            case .fixedBody(let remaining):
                let count = min(remaining, pending.count)
                output.append(pending.prefix(count))
                pending.removeFirst(count)
                state = count == remaining ? .header(Data()) : .fixedBody(remaining - count)

            case .chunkedBody(var scanner):
                let result = scanner.consume(pending)
                output.append(pending.prefix(result.consumed))
                pending.removeFirst(result.consumed)
                if result.invalid {
                    state = .tunnel
                } else if result.finished {
                    state = .header(Data())
                } else {
                    state = .chunkedBody(scanner)
                }

            case .bufferedFixed(let plan, let remaining, var body):
                let count = min(remaining, pending.count)
                body.append(pending.prefix(count))
                pending.removeFirst(count)
                if count == remaining {
                    let finalized = finalize(plan: plan, jsonBody: body, wireBody: body, chunked: false)
                    output.append(finalized.data)
                    requests.append(finalized.context)
                    state = .header(Data())
                } else {
                    state = .bufferedFixed(
                        plan: plan, remaining: remaining - count, body: body
                    )
                }

            case .bufferedChunked(let plan, var scanner, var body, var wireBody):
                let result = scanner.consume(pending)
                wireBody.append(pending.prefix(result.consumed))
                body.append(result.decoded)
                pending.removeFirst(result.consumed)
                guard body.count <= Self.maximumBodyBytes,
                      wireBody.count <= Self.maximumChunkWireBytes else {
                    throw LegacyGatewayProxyError.requestBodyTooLarge
                }
                if result.invalid {
                    output.append(plan.header)
                    output.append(wireBody)
                    requests.append(context(plan: plan, route: nil))
                    state = .tunnel
                } else if result.finished {
                    let finalized = finalize(
                        plan: plan, jsonBody: body, wireBody: wireBody, chunked: true
                    )
                    output.append(finalized.data)
                    requests.append(finalized.context)
                    state = .header(Data())
                } else {
                    state = .bufferedChunked(
                        plan: plan, scanner: scanner, body: body, wireBody: wireBody
                    )
                }

            case .tunnel:
                output.append(pending)
                pending.removeAll(keepingCapacity: false)
            }
        }
        return .init(
            data: output,
            requests: requests,
            continueResponses: continueResponses
        )
    }

    private func finalize(
        plan: LegacyHTTPRequestHeaderPlan,
        jsonBody: Data,
        wireBody: Data,
        chunked: Bool
    ) -> (data: Data, context: LegacyGatewayRequestContext) {
        let parsed = try? JSONSerialization.jsonObject(with: jsonBody)
        let countTokensEstimate = plan.isCountTokens
            ? LegacyCountTokensEstimator.estimate(
                plan.countTokensRequestIsJSON ? parsed : nil
            )
            : nil
        guard var object = parsed as? [String: Any],
              let requestedModel = object["model"] as? String,
              let route = modelRouting.resolve(requestedModel) else {
            let header = plan.expectsContinue
                ? LegacyHTTPHeaderEditing.rewrite(plan.header, removing: ["expect"])
                : plan.header
            var request = header
            request.append(wireBody)
            return (
                request,
                context(
                    plan: plan, route: nil, countTokensEstimate: countTokensEstimate
                )
            )
        }

        var body = jsonBody
        if route.needsRequestBodyRewrite, let outgoingModel = route.outgoingModel {
            object["model"] = outgoingModel
            if let rewritten = try? JSONSerialization.data(withJSONObject: object) {
                body = rewritten
            }
        }

        var header = plan.header
        if route.needsResponseRestoration, let clientModel = route.requestedModel {
            header = LegacyHTTPHeaderEditing.rewrite(
                header,
                removing: [
                    LegacyRequestedModelMetadata.headerName,
                    "accept-encoding",
                    "expect",
                ],
                setting: [
                    (
                        LegacyRequestedModelMetadata.headerName,
                        LegacyRequestedModelMetadata.encode(clientModel)
                    ),
                    ("Accept-Encoding", "identity"),
                ]
            )
        } else if plan.expectsContinue {
            header = LegacyHTTPHeaderEditing.rewrite(header, removing: ["expect"])
        }

        var request = Data()
        if route.needsRequestBodyRewrite {
            header = LegacyHTTPHeaderEditing.withFixedLength(header, byteCount: body.count)
            request.append(header)
            request.append(body)
        } else {
            request.append(header)
            request.append(chunked ? wireBody : body)
        }
        return (
            request,
            context(
                plan: plan, route: route, countTokensEstimate: countTokensEstimate
            )
        )
    }

    private func context(
        plan: LegacyHTTPRequestHeaderPlan,
        route: LegacyModelRoute?,
        countTokensEstimate: Int? = nil
    ) -> LegacyGatewayRequestContext {
        LegacyGatewayRequestContext(
            plan: plan,
            route: route,
            countTokensEstimate: countTokensEstimate,
            modelListCompatibility: plan.capturesKnownModels
                ? modelRouting.modelListCompatibility(isCodex: plan.modelListIsCodex)
                : nil
        )
    }
}

struct LegacyGatewayRequestContext {
    let method: String
    let reportsActivity: Bool
    let route: LegacyModelRoute?
    let capturesKnownModels: Bool
    let modelListCompatibility: LegacyModelListCompatibility?
    let isHeadRoot: Bool
    let isCountTokens: Bool
    let countTokensEstimate: Int?

    fileprivate init(
        plan: LegacyHTTPRequestHeaderPlan,
        route: LegacyModelRoute?,
        countTokensEstimate: Int?,
        modelListCompatibility: LegacyModelListCompatibility?
    ) {
        method = plan.method
        reportsActivity = plan.reportsActivity
        self.route = route
        capturesKnownModels = plan.capturesKnownModels
        self.modelListCompatibility = modelListCompatibility
        isHeadRoot = plan.isHeadRoot
        isCountTokens = plan.isCountTokens
        self.countTokensEstimate = plan.isCountTokens
            ? countTokensEstimate ?? LegacyCountTokensEstimator.estimate(nil)
            : nil
    }

    init(
        method: String,
        reportsActivity: Bool,
        route: LegacyModelRoute? = nil,
        capturesKnownModels: Bool = false,
        modelListCompatibility: LegacyModelListCompatibility? = nil,
        isHeadRoot: Bool = false,
        isCountTokens: Bool = false,
        countTokensEstimate: Int? = nil
    ) {
        self.method = method
        self.reportsActivity = reportsActivity
        self.route = route
        self.capturesKnownModels = capturesKnownModels
        self.modelListCompatibility = modelListCompatibility
        self.isHeadRoot = isHeadRoot
        self.isCountTokens = isCountTokens
        self.countTokensEstimate = isCountTokens
            ? countTokensEstimate ?? LegacyCountTokensEstimator.estimate(nil)
            : nil
    }
}

struct LegacyHTTPRequestTransformResult {
    let data: Data
    let requests: [LegacyGatewayRequestContext]
    let continueResponses: Int
}

fileprivate struct LegacyHTTPChunkedBodyScanner {
    struct Result {
        let consumed: Int
        let finished: Bool
        let invalid: Bool
        let decoded: Data
    }

    private enum Phase {
        case sizeLine([UInt8])
        case data(Int)
        case dataTerminator(Int)
        case trailerLine([UInt8])
        case invalid
    }

    private var phase: Phase = .sizeLine([])

    mutating func consume(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        var index = 0
        var decoded = Data()
        while index < bytes.count {
            switch phase {
            case .sizeLine(var line):
                line.append(bytes[index])
                index += 1
                guard line.count <= 1_024 else {
                    phase = .invalid
                    return .init(
                        consumed: bytes.count, finished: false, invalid: true, decoded: decoded
                    )
                }
                if line.suffix(2).elementsEqual([13, 10]) {
                    let rawSize = line.dropLast(2).prefix { $0 != 59 }
                    let token = String(decoding: rawSize, as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    guard let size = Int(token, radix: 16), size >= 0 else {
                        phase = .invalid
                        return .init(
                            consumed: bytes.count, finished: false, invalid: true, decoded: decoded
                        )
                    }
                    phase = size == 0 ? .trailerLine([]) : .data(size)
                } else {
                    phase = .sizeLine(line)
                }

            case .data(let remaining):
                let count = min(remaining, bytes.count - index)
                decoded.append(contentsOf: bytes[index..<(index + count)])
                index += count
                phase = count == remaining ? .dataTerminator(0) : .data(remaining - count)

            case .dataTerminator(let offset):
                let expected: UInt8 = offset == 0 ? 13 : 10
                guard bytes[index] == expected else {
                    phase = .invalid
                    return .init(
                        consumed: bytes.count, finished: false, invalid: true, decoded: decoded
                    )
                }
                index += 1
                phase = offset == 0 ? .dataTerminator(1) : .sizeLine([])

            case .trailerLine(var line):
                line.append(bytes[index])
                index += 1
                guard line.count <= 8 * 1_024 else {
                    phase = .invalid
                    return .init(
                        consumed: bytes.count, finished: false, invalid: true, decoded: decoded
                    )
                }
                if line.suffix(2).elementsEqual([13, 10]) {
                    if line.count == 2 {
                        return .init(
                            consumed: index, finished: true, invalid: false, decoded: decoded
                        )
                    }
                    phase = .trailerLine([])
                } else {
                    phase = .trailerLine(line)
                }

            case .invalid:
                return .init(
                    consumed: bytes.count, finished: false, invalid: true, decoded: decoded
                )
            }
        }
        return .init(consumed: index, finished: false, invalid: false, decoded: decoded)
    }
}

/// Observes response framing without changing a byte. Completion is reported at the HTTP message
/// boundary, allowing monitor refreshes while the underlying keep-alive connection remains open.
private struct LegacyHTTPResponseStreamScanner {
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let maximumHeaderBytes = 64 * 1_024

    private enum State {
        case header(Data)
        case fixedBody(Int, reportsActivity: Bool)
        case chunkedBody(LegacyHTTPChunkedBodyScanner, reportsActivity: Bool)
        case untilClose(reportsActivity: Bool)
        case tunnel
    }

    private enum Framing: Equatable {
        case informational
        case none
        case fixed(Int)
        case chunked
        case untilClose
        case tunnel
    }

    private var state: State = .header(Data())

    mutating func observe(
        _ input: Data,
        requests: inout [LegacyGatewayRequestContext],
        streamComplete: Bool
    ) -> Int {
        var pending = input
        var completedResponses = 0
        while !pending.isEmpty {
            switch state {
            case .header(var buffered):
                buffered.append(pending)
                pending.removeAll(keepingCapacity: false)
                if let terminator = buffered.range(of: Self.headerTerminator) {
                    let header = Data(buffered[..<terminator.upperBound])
                    pending = Data(buffered[terminator.upperBound...])
                    let request = requests.first
                    let framing = Self.framing(
                        for: header,
                        requestMethod: request?.method ?? ""
                    )
                    if framing != .informational, !requests.isEmpty {
                        requests.removeFirst()
                    }
                    let reportsActivity = request?.reportsActivity ?? false
                    switch framing {
                    case .informational:
                        state = .header(Data())
                    case .none:
                        if reportsActivity { completedResponses += 1 }
                        state = .header(Data())
                    case .fixed(let count):
                        if count == 0 {
                            if reportsActivity { completedResponses += 1 }
                            state = .header(Data())
                        } else {
                            state = .fixedBody(count, reportsActivity: reportsActivity)
                        }
                    case .chunked:
                        state = .chunkedBody(.init(), reportsActivity: reportsActivity)
                    case .untilClose:
                        state = .untilClose(reportsActivity: reportsActivity)
                    case .tunnel:
                        if reportsActivity { completedResponses += 1 }
                        state = .tunnel
                    }
                } else if buffered.count > Self.maximumHeaderBytes {
                    let reportsActivity = requests.first?.reportsActivity ?? false
                    if !requests.isEmpty { requests.removeFirst() }
                    state = .untilClose(reportsActivity: reportsActivity)
                } else {
                    state = .header(buffered)
                }

            case .fixedBody(let remaining, let reportsActivity):
                let count = min(remaining, pending.count)
                pending.removeFirst(count)
                if count == remaining {
                    if reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .fixedBody(
                        remaining - count,
                        reportsActivity: reportsActivity
                    )
                }

            case .chunkedBody(var scanner, let reportsActivity):
                let result = scanner.consume(pending)
                pending.removeFirst(result.consumed)
                if result.invalid {
                    state = .untilClose(reportsActivity: reportsActivity)
                } else if result.finished {
                    if reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .chunkedBody(scanner, reportsActivity: reportsActivity)
                }

            case .untilClose, .tunnel:
                pending.removeAll(keepingCapacity: false)
            }
        }

        if streamComplete, case .untilClose(let reportsActivity) = state {
            if reportsActivity { completedResponses += 1 }
            state = .header(Data())
        }
        return completedResponses
    }

    private static func framing(for header: Data, requestMethod: String) -> Framing {
        guard let text = String(data: header, encoding: .isoLatin1) else { return .untilClose }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .untilClose }
        let statusFields = statusLine.split(separator: " ", maxSplits: 2)
        guard statusFields.count >= 2, let status = Int(statusFields[1]) else {
            return .untilClose
        }
        if (100..<200).contains(status), status != 101 { return .informational }
        if status == 101
            || (requestMethod.caseInsensitiveCompare("CONNECT") == .orderedSame
                && (200..<300).contains(status)) {
            return .tunnel
        }
        if requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame
            || status == 204 || status == 304 {
            return .none
        }

        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .untilClose }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
        if let transferEncodings = fields["transfer-encoding"] {
            let tokens = transferEncodings
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return tokens.last == "chunked" ? .chunked : .untilClose
        }
        if let rawLengths = fields["content-length"] {
            let values = rawLengths.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = values.first.flatMap(Int.init), first >= 0,
                  values.allSatisfy({ Int($0) == first }) else {
                return .untilClose
            }
            return first == 0 ? .none : .fixed(first)
        }
        return .untilClose
    }
}

struct LegacyHTTPResponseTransformResult {
    let data: Data
    let completedResponses: Int
}

/// Restores caller-facing model identities while retaining a literal passthrough path for every
/// request whose resolver did not change models. Buffered JSON changes only a root string `model`;
/// SSE is processed incrementally and can therefore remain open indefinitely.
struct LegacyHTTPResponseStreamRewriter {
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumBufferedBodyBytes = 64 * 1_024 * 1_024

    private enum Framing: Equatable {
        case informational
        case none
        case fixed(Int)
        case chunked
        case untilClose
        case tunnel
    }

    private struct HeaderPlan {
        let framing: Framing
        let contentType: String
        let hasIdentityEncoding: Bool
        let isSuccessful: Bool
        let statusCode: Int
    }

    private struct BufferedResponse {
        var header: Data
        var body = Data()
        let requestedModel: String
        let reportsActivity: Bool
    }

    private struct SSEResponse {
        var processor: LegacySSEModelProcessor
        let reportsActivity: Bool
    }

    private struct KnownModelsResponse {
        let header: Data
        var decodedBody = Data()
        var wireBody = Data()
        let reportsActivity: Bool
        let upstreamSucceeded: Bool
        let compatibility: LegacyModelListCompatibility
    }

    private struct CountTokensResponse {
        let header: Data
        var decodedBody = Data()
        let reportsActivity: Bool
        let upstreamStatus: Int
        let upstreamSucceeded: Bool
        let hasIdentityEncoding: Bool
        let estimate: Int
    }

    private enum State {
        case header(Data)
        case passthroughFixed(Int, reportsActivity: Bool)
        case passthroughChunked(LegacyHTTPChunkedBodyScanner, reportsActivity: Bool)
        case passthroughUntilClose(reportsActivity: Bool)
        case bufferedFixed(BufferedResponse, remaining: Int)
        case bufferedChunked(BufferedResponse, LegacyHTTPChunkedBodyScanner)
        case bufferedUntilClose(BufferedResponse)
        case knownModelsFixed(KnownModelsResponse, remaining: Int)
        case knownModelsChunked(KnownModelsResponse, LegacyHTTPChunkedBodyScanner)
        case knownModelsUntilClose(KnownModelsResponse)
        case countTokensFixed(CountTokensResponse, remaining: Int)
        case countTokensChunked(CountTokensResponse, LegacyHTTPChunkedBodyScanner)
        case countTokensUntilClose(CountTokensResponse)
        case discardUntilClose
        case sseFixed(SSEResponse, remaining: Int)
        case sseChunked(SSEResponse, LegacyHTTPChunkedBodyScanner)
        case sseUntilClose(SSEResponse)
        case tunnel
    }

    private let knownModelStore: LegacyKnownModelStore
    private var state: State = .header(Data())

    init(knownModelStore: LegacyKnownModelStore = LegacyKnownModelStore()) {
        self.knownModelStore = knownModelStore
    }

    mutating func transform(
        _ input: Data,
        requests: inout [LegacyGatewayRequestContext],
        streamComplete: Bool
    ) throws -> LegacyHTTPResponseTransformResult {
        var pending = input
        var output = Data()
        var completedResponses = 0

        while !pending.isEmpty {
            switch state {
            case .header(var buffered):
                buffered.append(pending)
                pending.removeAll(keepingCapacity: false)
                if let terminator = buffered.range(of: Self.headerTerminator) {
                    let originalHeader = Data(buffered[..<terminator.upperBound])
                    pending = Data(buffered[terminator.upperBound...])
                    let request = requests.first
                    let plan = Self.plan(
                        for: originalHeader,
                        requestMethod: request?.method ?? ""
                    )
                    if plan.framing == .informational {
                        output.append(originalHeader)
                        state = .header(Data())
                        continue
                    }
                    if !requests.isEmpty { requests.removeFirst() }

                    let reportsActivity = request?.reportsActivity ?? false
                    // Bifrost itself answers HEAD / with 405 before consulting the configured
                    // provider. Treat that router-level answer like the upstream 404 handled by
                    // the legacy gateway, while retaining the actual observed status for audits.
                    if request?.isHeadRoot == true,
                       plan.statusCode == 404 || plan.statusCode == 405 {
                        output.append(LegacyHTTPHeaderEditing.withSuccessfulEmptyBody(
                            originalHeader,
                            fields: [
                                ("x-ccbud-fallback", "head-root-404-to-200"),
                                ("x-ccbud-upstream-status", String(plan.statusCode)),
                            ]
                        ))
                        if reportsActivity { completedResponses += 1 }
                        state = .header(Data())
                        continue
                    }

                    // Authentication belongs to Bifrost. Never turn its rejection into a local
                    // estimate, or count_tokens would become the sole unauthenticated route.
                    if request?.isCountTokens == true,
                       plan.statusCode != 401 && plan.statusCode != 403 {
                        let responseHeader = plan.framing == .tunnel
                            ? LegacyHTTPHeaderEditing.rewrite(
                                originalHeader,
                                removing: ["connection", "keep-alive", "upgrade"],
                                setting: [("Connection", "close")]
                            )
                            : originalHeader
                        let response = CountTokensResponse(
                            header: responseHeader,
                            reportsActivity: reportsActivity,
                            upstreamStatus: plan.statusCode,
                            upstreamSucceeded: plan.isSuccessful,
                            hasIdentityEncoding: plan.hasIdentityEncoding,
                            estimate: request?.countTokensEstimate
                                ?? LegacyCountTokensEstimator.estimate(nil)
                        )
                        switch plan.framing {
                        case .fixed(let count):
                            state = .countTokensFixed(response, remaining: count)
                            continue
                        case .chunked:
                            state = .countTokensChunked(response, .init())
                            continue
                        case .untilClose:
                            state = .countTokensUntilClose(response)
                            continue
                        case .none:
                            output.append(Self.finishCountTokens(response))
                            if reportsActivity { completedResponses += 1 }
                            state = .header(Data())
                            continue
                        case .tunnel:
                            output.append(Self.finishCountTokens(response))
                            if reportsActivity { completedResponses += 1 }
                            state = .discardUntilClose
                            continue
                        case .informational:
                            // Handled before the request is dequeued.
                            break
                        }
                    }

                    let route = request?.route
                    let requestedModel = route?.needsResponseRestoration == true
                        ? route?.requestedModel
                        : nil
                    var header = originalHeader
                    if let requestedModel {
                        header = LegacyHTTPHeaderEditing.replacingExisting(
                            header,
                            fields: [
                                "x-bifrost-original-model": requestedModel,
                                "x-bifrost-routing-info-model": requestedModel,
                            ]
                        )
                    }

                    if request?.capturesKnownModels == true,
                       let compatibility = request?.modelListCompatibility {
                        let response = KnownModelsResponse(
                            header: originalHeader,
                            reportsActivity: reportsActivity,
                            upstreamSucceeded: plan.isSuccessful,
                            compatibility: compatibility
                        )
                        switch plan.framing {
                        case .fixed(let count):
                            state = .knownModelsFixed(response, remaining: count)
                            continue
                        case .chunked:
                            state = .knownModelsChunked(response, .init())
                            continue
                        case .untilClose:
                            state = .knownModelsUntilClose(response)
                            continue
                        case .none:
                            output.append(finishKnownModels(response))
                            if reportsActivity { completedResponses += 1 }
                            state = .header(Data())
                            continue
                        default:
                            break
                        }
                    }

                    switch plan.framing {
                    case .informational:
                        // Handled above.
                        state = .header(Data())
                    case .none:
                        output.append(header)
                        if reportsActivity { completedResponses += 1 }
                        state = .header(Data())
                    case .tunnel:
                        output.append(header)
                        if reportsActivity { completedResponses += 1 }
                        state = .tunnel
                    case .fixed(let count):
                        guard let requestedModel, plan.hasIdentityEncoding else {
                            output.append(header)
                            state = .passthroughFixed(count, reportsActivity: reportsActivity)
                            continue
                        }
                        if plan.contentType.contains("text/event-stream") {
                            output.append(LegacyHTTPHeaderEditing.withChunkedBody(header))
                            state = .sseFixed(
                                .init(
                                    processor: .init(requestedModel: requestedModel),
                                    reportsActivity: reportsActivity
                                ),
                                remaining: count
                            )
                        } else if plan.contentType.contains("application/json") {
                            state = .bufferedFixed(
                                .init(
                                    header: header,
                                    requestedModel: requestedModel,
                                    reportsActivity: reportsActivity
                                ),
                                remaining: count
                            )
                        } else {
                            output.append(header)
                            state = .passthroughFixed(count, reportsActivity: reportsActivity)
                        }
                    case .chunked:
                        guard let requestedModel, plan.hasIdentityEncoding else {
                            output.append(header)
                            state = .passthroughChunked(
                                .init(), reportsActivity: reportsActivity
                            )
                            continue
                        }
                        if plan.contentType.contains("text/event-stream") {
                            output.append(header)
                            state = .sseChunked(
                                .init(
                                    processor: .init(requestedModel: requestedModel),
                                    reportsActivity: reportsActivity
                                ),
                                .init()
                            )
                        } else if plan.contentType.contains("application/json") {
                            state = .bufferedChunked(
                                .init(
                                    header: header,
                                    requestedModel: requestedModel,
                                    reportsActivity: reportsActivity
                                ),
                                .init()
                            )
                        } else {
                            output.append(header)
                            state = .passthroughChunked(
                                .init(), reportsActivity: reportsActivity
                            )
                        }
                    case .untilClose:
                        guard let requestedModel, plan.hasIdentityEncoding else {
                            output.append(header)
                            state = .passthroughUntilClose(reportsActivity: reportsActivity)
                            continue
                        }
                        if plan.contentType.contains("text/event-stream") {
                            output.append(header)
                            state = .sseUntilClose(.init(
                                processor: .init(requestedModel: requestedModel),
                                reportsActivity: reportsActivity
                            ))
                        } else if plan.contentType.contains("application/json") {
                            state = .bufferedUntilClose(.init(
                                header: header,
                                requestedModel: requestedModel,
                                reportsActivity: reportsActivity
                            ))
                        } else {
                            output.append(header)
                            state = .passthroughUntilClose(reportsActivity: reportsActivity)
                        }
                    }
                } else if buffered.count > Self.maximumHeaderBytes {
                    // An invalid response cannot safely be model-normalized. Preserve the bytes
                    // already received and treat the remainder as close-delimited.
                    output.append(buffered)
                    let reportsActivity = requests.first?.reportsActivity ?? false
                    if !requests.isEmpty { requests.removeFirst() }
                    state = .passthroughUntilClose(reportsActivity: reportsActivity)
                } else {
                    state = .header(buffered)
                }

            case .passthroughFixed(let remaining, let reportsActivity):
                let count = min(remaining, pending.count)
                output.append(pending.prefix(count))
                pending.removeFirst(count)
                if count == remaining {
                    if reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .passthroughFixed(
                        remaining - count, reportsActivity: reportsActivity
                    )
                }

            case .passthroughChunked(var scanner, let reportsActivity):
                let result = scanner.consume(pending)
                output.append(pending.prefix(result.consumed))
                pending.removeFirst(result.consumed)
                if result.invalid {
                    state = .passthroughUntilClose(reportsActivity: reportsActivity)
                } else if result.finished {
                    if reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .passthroughChunked(
                        scanner, reportsActivity: reportsActivity
                    )
                }

            case .passthroughUntilClose:
                output.append(pending)
                pending.removeAll(keepingCapacity: false)

            case .bufferedFixed(var response, let remaining):
                let count = min(remaining, pending.count)
                response.body.append(pending.prefix(count))
                pending.removeFirst(count)
                try Self.checkBufferedSize(response.body)
                if count == remaining {
                    output.append(Self.finishBuffered(response))
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .bufferedFixed(response, remaining: remaining - count)
                }

            case .bufferedChunked(var response, var scanner):
                let result = scanner.consume(pending)
                response.body.append(result.decoded)
                pending.removeFirst(result.consumed)
                try Self.checkBufferedSize(response.body)
                if result.invalid {
                    // The decoded prefix remains valid data. Finish it only when the backend
                    // closes, which avoids manufacturing an early message boundary.
                    state = .bufferedUntilClose(response)
                } else if result.finished {
                    output.append(Self.finishBuffered(response))
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .bufferedChunked(response, scanner)
                }

            case .bufferedUntilClose(var response):
                response.body.append(pending)
                pending.removeAll(keepingCapacity: false)
                try Self.checkBufferedSize(response.body)
                state = .bufferedUntilClose(response)

            case .knownModelsFixed(var response, let remaining):
                let count = min(remaining, pending.count)
                let bytes = pending.prefix(count)
                response.decodedBody.append(bytes)
                response.wireBody.append(bytes)
                pending.removeFirst(count)
                try Self.checkBufferedSize(response.decodedBody)
                if count == remaining {
                    output.append(finishKnownModels(response))
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .knownModelsFixed(response, remaining: remaining - count)
                }

            case .knownModelsChunked(var response, var scanner):
                let result = scanner.consume(pending)
                response.wireBody.append(pending.prefix(result.consumed))
                response.decodedBody.append(result.decoded)
                pending.removeFirst(result.consumed)
                try Self.checkBufferedSize(response.decodedBody)
                if result.invalid {
                    output.append(response.header)
                    output.append(response.wireBody)
                    state = .passthroughUntilClose(
                        reportsActivity: response.reportsActivity
                    )
                } else if result.finished {
                    output.append(finishKnownModels(response))
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .knownModelsChunked(response, scanner)
                }

            case .knownModelsUntilClose(var response):
                response.decodedBody.append(pending)
                response.wireBody.append(pending)
                pending.removeAll(keepingCapacity: false)
                try Self.checkBufferedSize(response.decodedBody)
                state = .knownModelsUntilClose(response)

            case .countTokensFixed(var response, let remaining):
                let count = min(remaining, pending.count)
                response.decodedBody.append(pending.prefix(count))
                pending.removeFirst(count)
                try Self.checkBufferedSize(response.decodedBody)
                if count == remaining {
                    output.append(Self.finishCountTokens(response))
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .countTokensFixed(response, remaining: remaining - count)
                }

            case .countTokensChunked(var response, var scanner):
                let result = scanner.consume(pending)
                response.decodedBody.append(result.decoded)
                pending.removeFirst(result.consumed)
                try Self.checkBufferedSize(response.decodedBody)
                if result.invalid {
                    state = .countTokensUntilClose(response)
                } else if result.finished {
                    output.append(Self.finishCountTokens(response))
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .countTokensChunked(response, scanner)
                }

            case .countTokensUntilClose(var response):
                response.decodedBody.append(pending)
                pending.removeAll(keepingCapacity: false)
                try Self.checkBufferedSize(response.decodedBody)
                state = .countTokensUntilClose(response)

            case .discardUntilClose:
                pending.removeAll(keepingCapacity: false)

            case .sseFixed(var response, let remaining):
                let count = min(remaining, pending.count)
                let finished = count == remaining
                let transformed = response.processor.consume(
                    Data(pending.prefix(count)), final: finished
                )
                pending.removeFirst(count)
                output.append(LegacyHTTPChunkEncoding.encode(
                    transformed, terminatesBody: finished
                ))
                if finished {
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .sseFixed(response, remaining: remaining - count)
                }

            case .sseChunked(var response, var scanner):
                let result = scanner.consume(pending)
                pending.removeFirst(result.consumed)
                let transformed = response.processor.consume(
                    result.decoded, final: result.finished
                )
                output.append(LegacyHTTPChunkEncoding.encode(
                    transformed, terminatesBody: result.finished
                ))
                if result.invalid {
                    state = .sseUntilClose(response)
                } else if result.finished {
                    if response.reportsActivity { completedResponses += 1 }
                    state = .header(Data())
                } else {
                    state = .sseChunked(response, scanner)
                }

            case .sseUntilClose(var response):
                output.append(response.processor.consume(pending, final: false))
                pending.removeAll(keepingCapacity: false)
                state = .sseUntilClose(response)

            case .tunnel:
                output.append(pending)
                pending.removeAll(keepingCapacity: false)
            }
        }

        if streamComplete {
            switch state {
            case .header(let buffered) where !buffered.isEmpty:
                output.append(buffered)
                state = .header(Data())
            case .passthroughUntilClose(let reportsActivity):
                if reportsActivity { completedResponses += 1 }
                state = .header(Data())
            case .bufferedUntilClose(let response):
                output.append(Self.finishBuffered(response))
                if response.reportsActivity { completedResponses += 1 }
                state = .header(Data())
            case .knownModelsUntilClose(let response):
                output.append(finishKnownModels(response))
                if response.reportsActivity { completedResponses += 1 }
                state = .header(Data())
            case .countTokensUntilClose(let response):
                output.append(Self.finishCountTokens(response))
                if response.reportsActivity { completedResponses += 1 }
                state = .header(Data())
            case .discardUntilClose:
                state = .header(Data())
            case .sseUntilClose(var response):
                output.append(response.processor.consume(Data(), final: true))
                if response.reportsActivity { completedResponses += 1 }
                state = .header(Data())
            default:
                break
            }
        }
        return .init(data: output, completedResponses: completedResponses)
    }

    private static func finishCountTokens(_ response: CountTokensResponse) -> Data {
        if response.upstreamSucceeded,
           response.hasIdentityEncoding,
           let object = (try? JSONSerialization.jsonObject(with: response.decodedBody))
                as? [String: Any],
           signedInteger(object["input_tokens"]) != nil {
            var result = LegacyHTTPHeaderEditing.withSuccessfulFixedBodyPreservingHeaders(
                response.header,
                byteCount: response.decodedBody.count,
                fields: [("x-ccbud-tokens", "upstream")]
            )
            result.append(response.decodedBody)
            return result
        }

        let body = Data("{\"input_tokens\":\(response.estimate)}".utf8)
        var result = LegacyHTTPHeaderEditing.freshResponse(
            basedOn: response.header,
            status: "200 OK",
            fields: [
                ("Content-Type", "application/json"),
                ("Content-Length", String(body.count)),
                ("x-ccbud-tokens", "estimated"),
                ("x-ccbud-upstream-status", String(response.upstreamStatus)),
            ]
        )
        result.append(body)
        return result
    }

    private static func signedInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(type) else {
            return nil
        }
        return Int(number.stringValue)
    }

    private func finishKnownModels(_ response: KnownModelsResponse) -> Data {
        let transformed = response.compatibility.responseBody(
            from: response.decodedBody,
            upstreamSucceeded: response.upstreamSucceeded
        )
        knownModelStore.replace(with: transformed.upstreamModels)
        var result = LegacyHTTPHeaderEditing.withSuccessfulJSONBody(
            response.header,
            byteCount: transformed.body.count
        )
        result.append(transformed.body)
        return result
    }

    private static func checkBufferedSize(_ body: Data) throws {
        guard body.count <= maximumBufferedBodyBytes else {
            throw LegacyGatewayProxyError.requestBodyTooLarge
        }
    }

    private static func finishBuffered(_ response: BufferedResponse) -> Data {
        var body = response.body
        if var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           object["model"] is String {
            object["model"] = response.requestedModel
            if let rewritten = try? JSONSerialization.data(withJSONObject: object) {
                body = rewritten
            }
        }
        var result = LegacyHTTPHeaderEditing.withFixedLength(
            response.header, byteCount: body.count
        )
        result.append(body)
        return result
    }

    private static func plan(for header: Data, requestMethod: String) -> HeaderPlan {
        guard let text = String(data: header, encoding: .isoLatin1) else {
            return .init(
                framing: .untilClose, contentType: "", hasIdentityEncoding: true,
                isSuccessful: false, statusCode: 0
            )
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            return .init(
                framing: .untilClose, contentType: "", hasIdentityEncoding: true,
                isSuccessful: false, statusCode: 0
            )
        }
        let statusFields = statusLine.split(separator: " ", maxSplits: 2)
        guard statusFields.count >= 2, let status = Int(statusFields[1]) else {
            return .init(
                framing: .untilClose, contentType: "", hasIdentityEncoding: true,
                isSuccessful: false, statusCode: 0
            )
        }

        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .init(
                    framing: .untilClose, contentType: "", hasIdentityEncoding: true,
                    isSuccessful: false, statusCode: status
                )
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
        let contentType = fields["content-type"]?.joined(separator: ",").lowercased() ?? ""
        let encodings = fields["content-encoding", default: []]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let identity = encodings.isEmpty || encodings.allSatisfy { $0 == "identity" }
        let make = { (framing: Framing) in
            HeaderPlan(
                framing: framing,
                contentType: contentType,
                hasIdentityEncoding: identity,
                isSuccessful: (200..<300).contains(status),
                statusCode: status
            )
        }

        if (100..<200).contains(status), status != 101 { return make(.informational) }
        if status == 101
            || (requestMethod.caseInsensitiveCompare("CONNECT") == .orderedSame
                && (200..<300).contains(status)) {
            return make(.tunnel)
        }
        if requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame
            || status == 204 || status == 304 {
            return make(.none)
        }
        if let transferEncodings = fields["transfer-encoding"] {
            let tokens = transferEncodings
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return make(tokens.last == "chunked" ? .chunked : .untilClose)
        }
        if let rawLengths = fields["content-length"] {
            let values = rawLengths.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = values.first.flatMap(Int.init), first >= 0,
                  values.allSatisfy({ Int($0) == first }) else {
                return make(.untilClose)
            }
            return make(first == 0 ? .none : .fixed(first))
        }
        return make(.untilClose)
    }
}

fileprivate struct LegacySSEModelProcessor {
    private static let modelValuePattern = try! NSRegularExpression(
        pattern: #""model"\s*:\s*"((?:\\.|[^"\\])*)""#
    )

    private let requestedModel: String
    private let escapedRequestedModel: String
    private var lineBuffer = Data()

    init(requestedModel: String) {
        self.requestedModel = requestedModel
        let encoded = (try? JSONEncoder().encode(requestedModel)) ?? Data(#"""# .utf8)
        let literal = String(decoding: encoded, as: UTF8.self)
        escapedRequestedModel = literal.count >= 2
            ? String(literal.dropFirst().dropLast())
            : requestedModel
    }

    mutating func consume(_ data: Data, final: Bool) -> Data {
        lineBuffer.append(data)
        var output = Data()
        while let newline = lineBuffer.firstIndex(of: 10) {
            let line = Data(lineBuffer[...newline])
            lineBuffer.removeSubrange(...newline)
            output.append(rewrite(line))
        }
        if final, !lineBuffer.isEmpty {
            output.append(rewrite(lineBuffer))
            lineBuffer.removeAll(keepingCapacity: false)
        }
        return output
    }

    private func rewrite(_ data: Data) -> Data {
        let line = String(decoding: data, as: UTF8.self)
        guard line.contains("\"model\"") else { return data }
        let mutable = NSMutableString(string: line)
        let range = NSRange(location: 0, length: mutable.length)
        let matches = Self.modelValuePattern.matches(in: line, range: range)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range(at: 1), with: escapedRequestedModel)
        }
        return String(mutable).data(using: .utf8) ?? data
    }
}

fileprivate enum LegacyHTTPChunkEncoding {
    static func encode(_ data: Data, terminatesBody: Bool) -> Data {
        var encoded = Data()
        if !data.isEmpty {
            encoded.append(Data(String(data.count, radix: 16).utf8))
            encoded.append(Data([13, 10]))
            encoded.append(data)
            encoded.append(Data([13, 10]))
        }
        if terminatesBody { encoded.append(Data("0\r\n\r\n".utf8)) }
        return encoded
    }
}
