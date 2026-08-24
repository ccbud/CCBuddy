import Darwin
import Foundation

enum GatewayState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }

    var isRunningOrStarting: Bool {
        switch self {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }
}

struct GatewayProcessDiagnostics: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let standardOutputBytes: Int
    let standardErrorBytes: Int

    static let empty = GatewayProcessDiagnostics(
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

enum GatewayChildProcessEnvironment {
    static func make(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String]
    ) -> [String: String] {
        var result = inherited
        result.merge(overrides) { _, override in override }
        for key in result.keys.filter(shouldRemove) { result.removeValue(forKey: key) }
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

enum GatewayRequestActivity: Equatable, Sendable {
    case requestReceived
    case responseCompleted
}

enum GatewayError: LocalizedError, Equatable, Sendable {
    case binaryMissing
    case exited(Int32)
    case readyTimeout
    case readyStreamClosed
    case invalidReadyEvent
    case healthTimeout
    case unsafeAppDirectory(String)
    case startupFailed(reason: String, diagnostics: GatewayProcessDiagnostics)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            "未找到 ccbud-gateway；请先构建 native/GatewayHelper"
        case .exited(let code):
            "网关进程异常退出（\(code)）"
        case .readyTimeout:
            "网关启动握手超时"
        case .readyStreamClosed:
            "网关在完成启动握手前退出"
        case .invalidReadyEvent:
            "网关返回了无效的启动握手"
        case .healthTimeout:
            "网关管理接口健康检查超时"
        case .unsafeAppDirectory(let detail):
            "网关数据目录不安全：\(detail)"
        case .startupFailed(let reason, let diagnostics):
            diagnostics.isEmpty ? reason : "\(reason)\n\n\(diagnostics.formatted)"
        }
    }
}

private struct GatewayReadyEvent: Decodable, Equatable, Sendable {
    let event: String
    let publicPort: Int
    let managementPort: Int
}

private final class GatewayLifecycleResources {
    let generation: UInt64
    let processToken = UUID()
    var process: Process?
    var outputPipes: (stdout: Pipe, stderr: Pipe)?
    var outputCapture: GatewayOutputCapture?
    var retainedDiagnostics = GatewayProcessDiagnostics.empty
    var didLaunchProcess = false
    var unexpectedExitStatus: Int32?
    var isDisposing = false
    var isDisposed = false
    var disposalWaiters: [CheckedContinuation<Void, Never>] = []

    var diagnostics: GatewayProcessDiagnostics {
        outputCapture?.snapshot() ?? retainedDiagnostics
    }

    init(generation: UInt64) {
        self.generation = generation
    }
}

actor GatewaySupervisor {
    private(set) var state: GatewayState = .stopped
    private(set) var managementPort: Int?
    nonisolated let managementCredentials: GatewayManagementCredentials
    nonisolated let requestActivity: AsyncStream<GatewayRequestActivity>
    nonisolated let stateChanges: AsyncStream<GatewayState>

    var diagnostics: GatewayProcessDiagnostics {
        activeResources?.diagnostics ?? retainedDiagnostics
    }

    var hasActiveOutputReaders: Bool { activeResources?.outputPipes != nil }

    private var lifecycleGeneration: UInt64 = 0
    private var activeResources: GatewayLifecycleResources?
    private var retiringResources: [GatewayLifecycleResources] = []
    private var retainedDiagnostics = GatewayProcessDiagnostics.empty
    private let fileManager: FileManager
    private let session: URLSession
    private let environment: [String: String]
    private let logByteLimitPerStream: Int
    private let readyTimeoutNanoseconds: UInt64
    private let healthCheckAttempts: Int
    private let healthCheckIntervalNanoseconds: UInt64
    private let requestActivityContinuation: AsyncStream<GatewayRequestActivity>.Continuation
    private let stateChangesContinuation: AsyncStream<GatewayState>.Continuation
    private let processTerminationObserver: (@Sendable (@Sendable () async -> Void) async -> Void)?

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logByteLimitPerStream: Int = 32 * 1_024,
        readyTimeoutNanoseconds: UInt64 = 30_000_000_000,
        healthCheckAttempts: Int = 100,
        healthCheckIntervalNanoseconds: UInt64 = 100_000_000,
        processTerminationObserver: (
            @Sendable (@Sendable () async -> Void) async -> Void
        )? = nil
    ) {
        var activityContinuation: AsyncStream<GatewayRequestActivity>.Continuation?
        requestActivity = AsyncStream(bufferingPolicy: .bufferingNewest(128)) {
            activityContinuation = $0
        }
        requestActivityContinuation = activityContinuation!
        var gatewayStateContinuation: AsyncStream<GatewayState>.Continuation?
        stateChanges = AsyncStream(bufferingPolicy: .bufferingNewest(16)) {
            gatewayStateContinuation = $0
        }
        stateChangesContinuation = gatewayStateContinuation!
        managementCredentials = .generate()
        self.fileManager = fileManager
        self.session = session
        self.environment = environment
        self.logByteLimitPerStream = max(1, logByteLimitPerStream)
        self.readyTimeoutNanoseconds = readyTimeoutNanoseconds
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
        managementPort = nil
        managementCredentials.endpoint.reset()
        updateState(.starting)
        await disposeRetiringResources()
        guard generation == lifecycleGeneration else { throw CancellationError() }

        let appDirectory = gatewayAppDirectory()
        do {
            try preparePrivateAppDirectory(appDirectory)
            let generated = try GatewayConfigBuilder.build(
                from: config,
                managementCredentials: managementCredentials
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try SecureAtomicFile.write(
                encoder.encode(generated),
                to: appDirectory.appendingPathComponent("config.json"),
                fileManager: fileManager
            )
        } catch {
            if generation == lifecycleGeneration { updateState(.failed(error.localizedDescription)) }
            throw error
        }

        guard let binary = binaryURL() else {
            if generation == lifecycleGeneration {
                updateState(.failed(GatewayError.binaryMissing.localizedDescription))
            }
            throw GatewayError.binaryMissing
        }

        let resources = GatewayLifecycleResources(generation: generation)
        activeResources = resources
        let child = Process()
        child.executableURL = binary
        child.environment = GatewayChildProcessEnvironment.make(overrides: environment)
        child.arguments = [
            "--config", appDirectory.appendingPathComponent("config.json").path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        let capture = GatewayOutputCapture(byteLimitPerStream: logByteLimitPerStream)
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
                if let terminationObserver { await terminationObserver(observation) }
                else { await observation() }
            }
        }

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
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        do {
            let ready = try await waitForReady(capture.readyEvents)
            try validate(resources, process: child)
            guard ready.event == "ready",
                  ready.publicPort == config.port,
                  (1...65_535).contains(ready.managementPort),
                  ready.managementPort != ready.publicPort else {
                throw GatewayError.invalidReadyEvent
            }
            try await waitForHealth(port: ready.managementPort, process: child)
            try validate(resources, process: child)
            managementPort = ready.managementPort
            managementCredentials.endpoint.update(port: ready.managementPort)
            updateState(.running(port: ready.publicPort))
        } catch {
            guard owns(resources) else {
                guard generation == lifecycleGeneration else { throw CancellationError() }
                if let status = resources.unexpectedExitStatus {
                    throw startupFailure(
                        for: GatewayError.exited(status),
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
                managementPort = nil
                managementCredentials.endpoint.reset()
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
        if let stoppedResources { retainedDiagnostics = stoppedResources.diagnostics }
        managementPort = nil
        managementCredentials.endpoint.reset()
        updateState(.stopped)
    }

    private func advanceLifecycleGeneration() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    private func owns(_ resources: GatewayLifecycleResources) -> Bool {
        lifecycleGeneration == resources.generation && activeResources === resources
    }

    private func validate(_ resources: GatewayLifecycleResources, process: Process) throws {
        guard owns(resources) else { throw CancellationError() }
        guard process.isRunning else { throw GatewayError.exited(process.terminationStatus) }
    }

    private func retire(_ resources: GatewayLifecycleResources) {
        if activeResources === resources { activeResources = nil }
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
        _ resources: GatewayLifecycleResources,
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
        let exit = GatewayError.exited(status)
        if wasRunning {
            managementPort = nil
            managementCredentials.endpoint.reset()
            updateState(.failed(exit.localizedDescription))
        }
        await dispose(resources, terminateProcess: false)
        guard generation == lifecycleGeneration else { return }
        retainedDiagnostics = resources.diagnostics
        if !wasRunning {
            updateState(.failed(startupFailure(
                for: exit,
                diagnostics: resources.diagnostics
            ).localizedDescription))
        }
    }

    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<40 {
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
        _ resources: GatewayLifecycleResources,
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
        diagnostics: GatewayProcessDiagnostics
    ) -> GatewayError {
        if let failure = error as? GatewayError, case .startupFailed = failure { return failure }
        return .startupFailed(reason: error.localizedDescription, diagnostics: diagnostics)
    }

    private func updateState(_ newState: GatewayState) {
        guard state != newState else { return }
        state = newState
        stateChangesContinuation.yield(streamSafeState(newState))
    }

    private func streamSafeState(_ state: GatewayState) -> GatewayState {
        guard case .failed(let message) = state else { return state }
        let reason = message.components(separatedBy: "\n\n").first ?? "网关服务不可用"
        return .failed(reason)
    }

    private func waitForReady(
        _ events: AsyncStream<GatewayReadyEvent>
    ) async throws -> GatewayReadyEvent {
        try await withThrowingTaskGroup(of: GatewayReadyEvent.self) { group in
            group.addTask {
                for await event in events { return event }
                throw GatewayError.readyStreamClosed
            }
            group.addTask { [readyTimeoutNanoseconds] in
                if readyTimeoutNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: readyTimeoutNanoseconds)
                }
                throw GatewayError.readyTimeout
            }
            defer { group.cancelAll() }
            guard let ready = try await group.next() else {
                throw GatewayError.readyStreamClosed
            }
            return ready
        }
    }

    private func waitForHealth(port: Int, process: Process) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<healthCheckAttempts {
            if !process.isRunning { throw GatewayError.exited(process.terminationStatus) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            request.setValue(
                managementCredentials.authorizationHeader,
                forHTTPHeaderField: "Authorization"
            )
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            if healthCheckIntervalNanoseconds > 0 {
                try await Task.sleep(nanoseconds: healthCheckIntervalNanoseconds)
            }
        }
        throw GatewayError.healthTimeout
    }

    private func gatewayAppDirectory() -> URL {
        if let override = environment["CCBUD_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("gateway", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccbud", isDirectory: true)
            .appendingPathComponent("gateway", isDirectory: true)
    }

    private func preparePrivateAppDirectory(_ directory: URL) throws {
        let controlledAppHome = directory.deletingLastPathComponent().standardizedFileURL
        let directory = directory.standardizedFileURL
        let chain = try privateDirectoryChain(from: controlledAppHome, through: directory)
        try validatePrivateDirectoryChain(chain, requireAllExist: false)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try validatePrivateDirectoryChain(chain, requireAllExist: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func privateDirectoryChain(from controlledRoot: URL, through directory: URL) throws
        -> [URL] {
        let rootComponents = controlledRoot.pathComponents
        let directoryComponents = directory.pathComponents
        guard directoryComponents.starts(with: rootComponents) else {
            throw GatewayError.unsafeAppDirectory("目标目录不在受控应用目录内")
        }

        var chain = [controlledRoot]
        var cursor = controlledRoot
        for component in directoryComponents.dropFirst(rootComponents.count) {
            cursor.appendPathComponent(component, isDirectory: true)
            chain.append(cursor)
        }
        return chain
    }

    private func validatePrivateDirectoryChain(
        _ chain: [URL],
        requireAllExist: Bool
    ) throws {
        for component in chain {
            var metadata = stat()
            let status = component.path.withCString { Darwin.lstat($0, &metadata) }
            if status == 0 {
                switch metadata.st_mode & S_IFMT {
                case S_IFDIR:
                    continue
                case S_IFLNK:
                    throw GatewayError.unsafeAppDirectory("路径包含符号链接：\(component.path)")
                default:
                    throw GatewayError.unsafeAppDirectory("路径组件不是目录：\(component.path)")
                }
            }
            if errno == ENOENT, !requireAllExist { continue }
            if errno == ENOENT {
                throw GatewayError.unsafeAppDirectory("目录创建后缺少路径组件：\(component.path)")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func binaryURL() -> URL? {
#if DEBUG
        if let path = environment["CCBUD_GATEWAY_BINARY"],
           fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
#endif
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ccbud-gateway"),
           fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/ccbud-gateway")
        return fileManager.isExecutableFile(atPath: development.path) ? development : nil
    }
}

private final class GatewayOutputCapture: @unchecked Sendable {
    private enum Stream: Equatable, Sendable { case stdout, stderr }

    let readyEvents: AsyncStream<GatewayReadyEvent>

    private let lock = NSLock()
    private let readers = DispatchGroup()
    private let byteLimitPerStream: Int
    private let readyContinuation: AsyncStream<GatewayReadyEvent>.Continuation
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutLineBuffer = Data()
    private var isAttached = false
    private var finishedReadyEvents = false

    init(byteLimitPerStream: Int) {
        self.byteLimitPerStream = max(1, byteLimitPerStream)
        var continuation: AsyncStream<GatewayReadyEvent>.Continuation?
        readyEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        readyContinuation = continuation!
    }

    deinit { finishReadyEvents() }

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
        finishReadyEvents()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func snapshot() -> GatewayProcessDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return GatewayProcessDiagnostics(
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
        case .stdout: "dev.ccbud.gateway.stdout"
        case .stderr: "dev.ccbud.gateway.stderr"
        }
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
            if count == 0 {
                if stream == .stdout { flushFinalReadyLine(); finishReadyEvents() }
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if stream == .stdout { finishReadyEvents() }
                return
            }
            append(Data(buffer.prefix(count)), stream: stream)
        }
    }

    private func append(_ data: Data, stream: Stream) {
        var ready: [GatewayReadyEvent] = []
        lock.lock()
        guard isAttached else {
            lock.unlock()
            return
        }
        switch stream {
        case .stdout:
            appendBounded(data, to: &stdoutData)
            stdoutLineBuffer.append(data)
            ready = parseReadyLinesLocked()
        case .stderr:
            appendBounded(data, to: &stderrData)
        }
        lock.unlock()
        ready.forEach { readyContinuation.yield($0) }
    }

    private func parseReadyLinesLocked() -> [GatewayReadyEvent] {
        var events: [GatewayReadyEvent] = []
        while let newline = stdoutLineBuffer.firstIndex(of: 0x0A) {
            var line = Data(stdoutLineBuffer[..<newline])
            stdoutLineBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if let event = try? JSONDecoder().decode(GatewayReadyEvent.self, from: line),
               event.event == "ready" {
                events.append(event)
            }
        }
        if stdoutLineBuffer.count > 64 * 1_024 { stdoutLineBuffer.removeAll(keepingCapacity: true) }
        return events
    }

    private func flushFinalReadyLine() {
        var event: GatewayReadyEvent?
        lock.lock()
        if !stdoutLineBuffer.isEmpty {
            event = try? JSONDecoder().decode(GatewayReadyEvent.self, from: stdoutLineBuffer)
            stdoutLineBuffer.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        if event?.event == "ready", let event { readyContinuation.yield(event) }
    }

    private func markDetached() {
        lock.lock()
        isAttached = false
        lock.unlock()
    }

    private func finishReadyEvents() {
        lock.lock()
        guard !finishedReadyEvents else {
            lock.unlock()
            return
        }
        finishedReadyEvents = true
        lock.unlock()
        readyContinuation.finish()
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
