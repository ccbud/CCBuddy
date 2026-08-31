import Darwin
import Foundation

enum PluginOutputStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
}

enum PluginProcessTerminationReason: String, Equatable, Sendable {
    case exit
    case uncaughtSignal
}

struct PluginProcessTermination: Equatable, Sendable {
    var status: Int32
    var reason: PluginProcessTerminationReason

    var wasSuccessful: Bool { reason == .exit && status == 0 }
}

struct PluginSidecarLaunchRequest: Equatable, Sendable {
    var pluginID: String
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String]?
}

enum PluginSidecarLaunchError: Error, LocalizedError, Equatable, Sendable {
    case executableUnavailable
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .executableUnavailable: "Plugin executable is unavailable"
        case .launchFailed: "Plugin process could not be started"
        }
    }
}

protocol PluginSidecarProcessHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    func terminate()
    func kill()
    func terminationIfExited() -> PluginProcessTermination?
    func waitForExit() async -> PluginProcessTermination
}

protocol PluginSidecarProcessLaunching: Sendable {
    func launch(
        _ request: PluginSidecarLaunchRequest,
        outputHandler: @escaping @Sendable (PluginOutputStream, Data) -> Void
    ) throws -> any PluginSidecarProcessHandle
}

/// Foundation adapter for long-running sidecars. It never invokes a shell and never includes
/// argv or environment values in its errors.
struct FoundationPluginSidecarProcessLauncher: PluginSidecarProcessLaunching, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func launch(
        _ request: PluginSidecarLaunchRequest,
        outputHandler: @escaping @Sendable (PluginOutputStream, Data) -> Void
    ) throws -> any PluginSidecarProcessHandle {
        guard fileManager.isExecutableFile(atPath: request.executable.path) else {
            throw PluginSidecarLaunchError.executableUnavailable
        }
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        if let environment = request.environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let handle = FoundationPluginSidecarProcessHandle(
            process: process,
            standardOutput: standardOutput,
            standardError: standardError,
            outputHandler: outputHandler
        )
        handle.prepare()
        do {
            try process.run()
            handle.didLaunch()
            return handle
        } catch {
            handle.cancelLaunch()
            throw PluginSidecarLaunchError.launchFailed
        }
    }
}

private final class FoundationPluginSidecarProcessHandle: PluginSidecarProcessHandle, @unchecked Sendable {
    private let process: Process
    private let standardOutput: Pipe
    private let standardError: Pipe
    private let outputHandler: @Sendable (PluginOutputStream, Data) -> Void
    private let outputQueue = DispatchQueue(label: "dev.ccbud.plugin-sidecar-output")
    private let lock = NSLock()
    private var termination: PluginProcessTermination?
    private var waiters: [CheckedContinuation<PluginProcessTermination, Never>] = []
    private var readersClosed = false

    init(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe,
        outputHandler: @escaping @Sendable (PluginOutputStream, Data) -> Void
    ) {
        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputHandler = outputHandler
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func prepare() {
        installReader(standardOutput.fileHandleForReading, stream: .standardOutput)
        installReader(standardError.fileHandleForReading, stream: .standardError)
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(process)
        }
    }

    func didLaunch() {
        // The child owns duplicated write descriptors. Retaining the parent's copies prevents EOF.
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
    }

    func cancelLaunch() {
        process.terminationHandler = nil
        closeReaders(drain: false)
    }

    func terminate() {
        guard terminationIfExited() == nil, process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard terminationIfExited() == nil, process.isRunning else { return }
        let identifier = process.processIdentifier
        if identifier > 0 { Darwin.kill(identifier, SIGKILL) }
    }

    func terminationIfExited() -> PluginProcessTermination? {
        lock.lock()
        defer { lock.unlock() }
        return termination
    }

    func waitForExit() async -> PluginProcessTermination {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let termination {
                lock.unlock()
                continuation.resume(returning: termination)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func installReader(_ fileHandle: FileHandle, stream: PluginOutputStream) {
        fileHandle.readabilityHandler = { [weak self] readable in
            self?.outputQueue.async { [weak self] in
                guard let self, !self.areReadersClosed() else { return }
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                } else {
                    self.outputHandler(stream, data)
                }
            }
        }
    }

    private func areReadersClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readersClosed
    }

    private func didTerminate(_ process: Process) {
        closeReaders(drain: true)
        let reason: PluginProcessTerminationReason = process.terminationReason == .uncaughtSignal
            ? .uncaughtSignal
            : .exit
        let result = PluginProcessTermination(status: process.terminationStatus, reason: reason)

        lock.lock()
        guard termination == nil else {
            lock.unlock()
            return
        }
        termination = result
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: result) }
    }

    private func closeReaders(drain: Bool) {
        outputQueue.sync {
            lock.lock()
            guard !readersClosed else {
                lock.unlock()
                return
            }
            readersClosed = true
            lock.unlock()

            let handles: [(FileHandle, PluginOutputStream)] = [
                (standardOutput.fileHandleForReading, .standardOutput),
                (standardError.fileHandleForReading, .standardError),
            ]
            for (handle, stream) in handles {
                handle.readabilityHandler = nil
                if drain {
                    do {
                        if let data = try handle.readToEnd(), !data.isEmpty {
                            outputHandler(stream, data)
                        }
                    } catch {
                        // A readability callback may already have consumed EOF.
                    }
                }
                try? handle.close()
            }
        }
    }
}

struct PluginOutputSnapshot: Equatable, Sendable {
    var standardOutput: String
    var standardError: String
    var retainedStandardOutputBytes: Int
    var retainedStandardErrorBytes: Int
    var droppedStandardOutputBytes: Int
    var droppedStandardErrorBytes: Int

    static let empty = PluginOutputSnapshot(
        standardOutput: "",
        standardError: "",
        retainedStandardOutputBytes: 0,
        retainedStandardErrorBytes: 0,
        droppedStandardOutputBytes: 0,
        droppedStandardErrorBytes: 0
    )
}

final class PluginBoundedOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimitPerStream: Int
    private let redactor: PluginSecretRedactor
    private var standardOutput = Data()
    private var standardError = Data()
    private var droppedStandardOutputBytes = 0
    private var droppedStandardErrorBytes = 0

    init(byteLimitPerStream: Int, redactor: PluginSecretRedactor = .init()) {
        self.byteLimitPerStream = max(1, byteLimitPerStream)
        self.redactor = redactor
    }

    func append(_ stream: PluginOutputStream, data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .standardOutput:
            appendBounded(data, retained: &standardOutput, dropped: &droppedStandardOutputBytes)
        case .standardError:
            appendBounded(data, retained: &standardError, dropped: &droppedStandardErrorBytes)
        }
    }

    func snapshot() -> PluginOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            standardOutput: redactor.redact(String(decoding: standardOutput, as: UTF8.self)),
            standardError: redactor.redact(String(decoding: standardError, as: UTF8.self)),
            retainedStandardOutputBytes: standardOutput.count,
            retainedStandardErrorBytes: standardError.count,
            droppedStandardOutputBytes: droppedStandardOutputBytes,
            droppedStandardErrorBytes: droppedStandardErrorBytes
        )
    }

    private func appendBounded(_ incoming: Data, retained: inout Data, dropped: inout Int) {
        let combinedCount = retained.count + incoming.count
        if incoming.count >= byteLimitPerStream {
            dropped += combinedCount - byteLimitPerStream
            retained = incoming.suffix(byteLimitPerStream)
            return
        }
        let overflow = max(0, combinedCount - byteLimitPerStream)
        if overflow > 0 {
            dropped += overflow
            retained.removeFirst(min(overflow, retained.count))
        }
        retained.append(incoming)
    }
}
