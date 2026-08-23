import Foundation
import XCTest
@testable import CCBuddy

final class PluginSidecarSupervisorTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testStartPersistsPortBuildsExactArgvBoundsOutputAndStopsGracefully() async throws {
        let fixture = try makeRepository(pluginIDs: ["alpha"])
        let launcher = FakePluginProcessLauncher(output: [
            (.standardOutput, Data(repeating: 65, count: 80)),
            (.standardError, Data("error api_key=visible-key literal-secret".utf8)),
        ])
        let health = ScriptedPluginHealthChecker(results: [true])
        let ports = RecordingPluginPortAllocator(ports: ["alpha": 55_001])
        let clock = RecordingPluginClock()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: health,
            portAllocator: ports,
            clock: clock,
            configuration: .init(outputByteLimitPerStream: 24),
            diagnosticSecrets: ["literal-secret"]
        )

        let running = try await supervisor.start(id: "alpha")
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertEqual(running.port, 55_001)
        XCTAssertEqual(try fixture.repository.readRuntime(id: "alpha"), .init(port: 55_001))
        XCTAssertEqual(launcher.requests.count, 1)
        let request = try XCTUnwrap(launcher.requests.first)
        XCTAssertEqual(request.pluginID, "alpha")
        XCTAssertEqual(request.executable.lastPathComponent, "alpha")
        XCTAssertEqual(request.arguments, [
            "serve", "--port", "55001", "--home",
            try fixture.repository.layout.installedDirectory(for: "alpha").path,
        ])
        XCTAssertNil(request.environment)
        XCTAssertEqual(running.output.retainedStandardOutputBytes, 24)
        XCTAssertGreaterThan(running.output.droppedStandardOutputBytes, 0)
        XCTAssertFalse(running.output.standardError.contains("visible-key"))
        XCTAssertFalse(running.output.standardError.contains("literal-secret"))
        XCTAssertTrue(running.output.standardError.contains("[REDACTED]"))

        let duplicate = try await supervisor.start(id: "alpha")
        XCTAssertEqual(duplicate.processIdentifier, running.processIdentifier)
        XCTAssertEqual(launcher.requests.count, 1)

        let stoppedValue = await supervisor.stop(id: "alpha")
        let stopped = try XCTUnwrap(stoppedValue)
        XCTAssertEqual(stopped.lifecycle, .stopped)
        XCTAssertEqual(stopped.termination, .init(status: 0, reason: .exit))
        XCTAssertEqual(launcher.handles[0].terminateCount, 1)
        XCTAssertEqual(launcher.handles[0].killCount, 0)
    }

    func testHealthPollingUsesInjectedClockWithoutWallClockDelay() async throws {
        let fixture = try makeRepository(pluginIDs: ["polling"])
        let launcher = FakePluginProcessLauncher()
        let health = ScriptedPluginHealthChecker(results: [false, false, true])
        let clock = RecordingPluginClock()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: health,
            portAllocator: RecordingPluginPortAllocator(ports: ["polling": 55_002]),
            clock: clock,
            configuration: .init(healthPollIntervalMilliseconds: 17)
        )

        let state = try await supervisor.start(id: "polling")
        XCTAssertEqual(state.lifecycle, .running)
        let requestCount = await health.requestCount
        let sleeps = await clock.sleeps
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(sleeps, [17, 17])
        _ = await supervisor.stop(id: "polling")
    }

    func testClockFailureTerminatesLaunchedProcessInsteadOfLeavingStartupOrphaned() async throws {
        let fixture = try makeRepository(pluginIDs: ["clock-failure"])
        let launcher = FakePluginProcessLauncher()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: ScriptedPluginHealthChecker(results: [false]),
            portAllocator: RecordingPluginPortAllocator(ports: ["clock-failure": 55_010]),
            clock: ThrowingPluginClock()
        )

        do {
            _ = try await supervisor.start(id: "clock-failure")
            XCTFail("Expected health polling failure")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(
                error,
                .startFailed(
                    pluginID: "clock-failure",
                    failure: .preparation("Plugin health polling failed")
                )
            )
        }
        let state = await supervisor.state(id: "clock-failure")
        XCTAssertEqual(state?.lifecycle, .failed)
        XCTAssertEqual(state?.failure, .preparation("Plugin health polling failed"))
        XCTAssertNil(state?.processIdentifier)
        XCTAssertEqual(launcher.handles[0].terminateCount, 1)
    }

    func testConcurrentStartIsRejectedUntilFirstHealthGateCompletes() async throws {
        let fixture = try makeRepository(pluginIDs: ["gated"])
        let health = GatedPluginHealthChecker()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: FakePluginProcessLauncher(),
            healthChecker: health,
            portAllocator: RecordingPluginPortAllocator(ports: ["gated": 55_003]),
            clock: RecordingPluginClock()
        )
        let first = Task { try await supervisor.start(id: "gated") }
        await health.waitUntilRequested()

        do {
            _ = try await supervisor.start(id: "gated")
            XCTFail("Expected operation-in-progress failure")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(error, .operationInProgress("gated"))
        }
        await health.resolve(true)
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.lifecycle, .running)
        _ = await supervisor.stop(id: "gated")
    }

    func testStopDuringHealthGateCancelsStartupWithoutMisreportingTimeout() async throws {
        let fixture = try makeRepository(pluginIDs: ["cancelled"])
        let health = GatedPluginHealthChecker()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: FakePluginProcessLauncher(),
            healthChecker: health,
            portAllocator: RecordingPluginPortAllocator(ports: ["cancelled": 55_008]),
            clock: RecordingPluginClock()
        )
        let startup = Task { try await supervisor.start(id: "cancelled") }
        await health.waitUntilRequested()
        let stopped = await supervisor.stop(id: "cancelled")
        await health.resolve(false)

        do {
            _ = try await startup.value
            XCTFail("Expected cancelled startup")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(error, .startFailed(pluginID: "cancelled", failure: .cancelled))
        }
        XCTAssertEqual(stopped?.lifecycle, .stopped)
        let final = await supervisor.state(id: "cancelled")
        XCTAssertEqual(final?.lifecycle, .stopped)
        XCTAssertNil(final?.failure)
    }

    func testCancellingStartupTaskDuringHealthGateCannotPromoteProcessToRunning() async throws {
        let fixture = try makeRepository(pluginIDs: ["task-cancelled"])
        let launcher = FakePluginProcessLauncher()
        let health = GatedPluginHealthChecker()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: health,
            portAllocator: RecordingPluginPortAllocator(ports: ["task-cancelled": 55_011]),
            clock: RecordingPluginClock()
        )
        let startup = Task { try await supervisor.start(id: "task-cancelled") }
        await health.waitUntilRequested()
        startup.cancel()
        await health.resolve(true)

        do {
            _ = try await startup.value
            XCTFail("Expected cancelled startup")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(error, .startFailed(pluginID: "task-cancelled", failure: .cancelled))
        }
        let state = await supervisor.state(id: "task-cancelled")
        XCTAssertEqual(state?.lifecycle, .failed)
        XCTAssertEqual(state?.failure, .cancelled)
        XCTAssertNil(state?.processIdentifier)
        XCTAssertEqual(launcher.handles[0].terminateCount, 1)
    }

    func testHealthTimeoutTerminatesChildAndRetainsFailedState() async throws {
        let fixture = try makeRepository(pluginIDs: ["timeout"], readyTimeoutMilliseconds: 3)
        let launcher = FakePluginProcessLauncher()
        let clock = RecordingPluginClock()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: ScriptedPluginHealthChecker(results: [false, false, false, false]),
            portAllocator: RecordingPluginPortAllocator(ports: ["timeout": 55_004]),
            clock: clock,
            configuration: .init(healthPollIntervalMilliseconds: 2)
        )

        do {
            _ = try await supervisor.start(id: "timeout")
            XCTFail("Expected health timeout")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(error, .startFailed(pluginID: "timeout", failure: .healthTimeout))
        }
        let stateValue = await supervisor.state(id: "timeout")
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(state.lifecycle, .failed)
        XCTAssertEqual(state.failure, .healthTimeout)
        XCTAssertEqual(launcher.handles[0].terminateCount, 1)
        XCTAssertNil(state.processIdentifier)
        let timeoutSleeps = await clock.sleeps
        XCTAssertEqual(Array(timeoutSleeps.prefix(2)), [2, 1])
    }

    func testUnexpectedExitIsRecordedAndWaitForExitIsDeterministic() async throws {
        let fixture = try makeRepository(pluginIDs: ["crash"])
        let launcher = FakePluginProcessLauncher()
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: ScriptedPluginHealthChecker(results: [true]),
            portAllocator: RecordingPluginPortAllocator(ports: ["crash": 55_005]),
            clock: RecordingPluginClock()
        )
        _ = try await supervisor.start(id: "crash")
        launcher.handles[0].complete(.init(status: 23, reason: .exit))

        let failedValue = await supervisor.waitForExit(id: "crash")
        let failed = try XCTUnwrap(failedValue)
        XCTAssertEqual(failed.lifecycle, .failed)
        XCTAssertEqual(failed.failure, .unexpectedExit(.init(status: 23, reason: .exit)))
        XCTAssertEqual(failed.termination, .init(status: 23, reason: .exit))
        XCTAssertNil(failed.processIdentifier)
    }

    func testStopEscalatesToKillAndShutdownCleansEveryProcessInSortedState() async throws {
        let fixture = try makeRepository(pluginIDs: ["alpha", "beta"])
        let launcher = FakePluginProcessLauncher(terminateAutomatically: false, killAutomatically: true)
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: ScriptedPluginHealthChecker(results: [true, true]),
            portAllocator: RecordingPluginPortAllocator(ports: ["alpha": 55_006, "beta": 55_007]),
            clock: RecordingPluginClock(),
            configuration: .init(terminationGracePolls: 2, terminationPollIntervalMilliseconds: 1)
        )
        _ = try await supervisor.start(id: "beta")
        _ = try await supervisor.start(id: "alpha")

        await supervisor.shutdown()
        let states = await supervisor.states()
        XCTAssertEqual(states.map(\.pluginID), ["alpha", "beta"])
        XCTAssertEqual(states.map(\.lifecycle), [.stopped, .stopped])
        XCTAssertTrue(launcher.handles.allSatisfy { $0.terminateCount == 1 && $0.killCount == 1 })
        do {
            _ = try await supervisor.start(id: "alpha")
            XCTFail("Expected shutdown rejection")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(error, .shuttingDown)
        }
    }

    func testFailedForcedTerminationPreventsLaunchingDuplicateProcess() async throws {
        let fixture = try makeRepository(pluginIDs: ["stuck"])
        let launcher = FakePluginProcessLauncher(
            terminateAutomatically: false,
            killAutomatically: false
        )
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: launcher,
            healthChecker: ScriptedPluginHealthChecker(results: [true]),
            portAllocator: RecordingPluginPortAllocator(ports: ["stuck": 55_009]),
            clock: RecordingPluginClock(),
            configuration: .init(terminationGracePolls: 1, terminationPollIntervalMilliseconds: 1)
        )
        _ = try await supervisor.start(id: "stuck")

        do {
            _ = try await supervisor.restart(id: "stuck")
            XCTFail("Expected termination timeout")
        } catch let error as PluginSidecarSupervisorError {
            XCTAssertEqual(error, .startFailed(pluginID: "stuck", failure: .terminationTimeout))
        }
        XCTAssertEqual(launcher.requests.count, 1)
        let stuckState = await supervisor.state(id: "stuck")
        XCTAssertEqual(stuckState?.failure, .terminationTimeout)
        launcher.handles[0].complete(.init(status: 9, reason: .uncaughtSignal))
        _ = await supervisor.waitForExit(id: "stuck")
    }

    func testRememberedPortIsPassedToAllocatorAndReusedAcrossRestart() async throws {
        let fixture = try makeRepository(pluginIDs: ["stable"])
        try fixture.repository.writeRuntime(.init(port: 50_123), id: "stable")
        let ports = RecordingPluginPortAllocator(ports: ["stable": 50_123])
        let supervisor = PluginSidecarSupervisor(
            repository: fixture.repository,
            launcher: FakePluginProcessLauncher(),
            healthChecker: ScriptedPluginHealthChecker(results: [true, true]),
            portAllocator: ports,
            clock: RecordingPluginClock()
        )
        let first = try await supervisor.start(id: "stable")
        let second = try await supervisor.restart(id: "stable")
        XCTAssertEqual(first.port, 50_123)
        XCTAssertEqual(second.port, 50_123)
        XCTAssertEqual(ports.preferredPorts, [50_123, 50_123])
        _ = await supervisor.stop(id: "stable")
    }

    func testFoundationLauncherPassesLiteralArgvAndCapturesRealProcessExit() async throws {
        let root = try temporaryRoot(prefix: "ccbud-plugin-real-process")
        let executable = root.appendingPathComponent("literal-argv")
        try Data("#!/bin/sh\nprintf '%s' \"$1\"\nexit 7\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let capture = PluginBoundedOutputCapture(byteLimitPerStream: 1_024)
        let request = PluginSidecarLaunchRequest(
            pluginID: "literal",
            executable: executable,
            arguments: ["literal;$(not-executed)"],
            workingDirectory: root,
            environment: nil
        )
        let handle = try FoundationPluginSidecarProcessLauncher().launch(request) {
            capture.append($0, data: $1)
        }
        let termination = await handle.waitForExit()
        XCTAssertEqual(termination, .init(status: 7, reason: .exit))
        XCTAssertEqual(capture.snapshot().standardOutput, "literal;$(not-executed)")
    }

    func testDefaultAllocatorIsStableHandlesCollisionsAndHonorsLegacyPreferredPort() throws {
        let allocator = PluginDeterministicPortAllocator(
            range: 50_000...50_010,
            availability: AlwaysAvailablePluginPort()
        )
        let first = try allocator.allocate(pluginID: "stable-id", preferred: nil, reserved: [])
        let repeated = try allocator.allocate(pluginID: "stable-id", preferred: nil, reserved: [])
        let collision = try allocator.allocate(pluginID: "stable-id", preferred: nil, reserved: [first])
        let legacy = try allocator.allocate(pluginID: "legacy", preferred: 8_899, reserved: [])

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(collision, first)
        XCTAssertEqual(legacy, 8_899)
    }

    private func makeRepository(
        pluginIDs: [String],
        readyTimeoutMilliseconds: Int = 8_000
    ) throws -> SupervisorFixture {
        let root = try temporaryRoot(prefix: "ccbud-plugin-supervisor")
        let layout = PluginHomeLayout(ccbudHome: root)
        for id in pluginIDs {
            let directory = layout.pluginsRoot.appendingPathComponent(id, isDirectory: true)
            try PluginTestSupport.writePlugin(at: directory, id: id, version: "1.0.0")
            if readyTimeoutMilliseconds != 8_000 {
                let manifestURL = directory.appendingPathComponent("plugin.json")
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
                )
                var endpoint = try XCTUnwrap(object["endpoint"] as? [String: Any])
                endpoint["readyTimeoutMs"] = readyTimeoutMilliseconds
                object["endpoint"] = endpoint
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    .write(to: manifestURL, options: [.atomic])
            }
        }
        return .init(repository: .init(layout: layout, platformKey: "darwin-arm64"))
    }

    private func temporaryRoot(prefix: String) throws -> URL {
        let root = try PluginTestSupport.temporaryDirectory(prefix: prefix)
        temporaryRoots.append(root)
        return root
    }
}

private struct SupervisorFixture {
    var repository: PluginRepository
}

private final class FakePluginProcessLauncher: PluginSidecarProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let output: [(PluginOutputStream, Data)]
    private let terminateAutomatically: Bool
    private let killAutomatically: Bool
    private var nextIdentifier: Int32 = 10_000
    private(set) var requests: [PluginSidecarLaunchRequest] = []
    private(set) var handles: [FakePluginProcessHandle] = []

    init(
        output: [(PluginOutputStream, Data)] = [],
        terminateAutomatically: Bool = true,
        killAutomatically: Bool = true
    ) {
        self.output = output
        self.terminateAutomatically = terminateAutomatically
        self.killAutomatically = killAutomatically
    }

    func launch(
        _ request: PluginSidecarLaunchRequest,
        outputHandler: @escaping @Sendable (PluginOutputStream, Data) -> Void
    ) throws -> any PluginSidecarProcessHandle {
        lock.lock()
        let identifier = nextIdentifier
        nextIdentifier += 1
        let handle = FakePluginProcessHandle(
            processIdentifier: identifier,
            terminateAutomatically: terminateAutomatically,
            killAutomatically: killAutomatically
        )
        requests.append(request)
        handles.append(handle)
        lock.unlock()
        for (stream, data) in output { outputHandler(stream, data) }
        return handle
    }
}

private final class FakePluginProcessHandle: PluginSidecarProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32
    private let terminateAutomatically: Bool
    private let killAutomatically: Bool
    private let lock = NSLock()
    private var termination: PluginProcessTermination?
    private var waiters: [CheckedContinuation<PluginProcessTermination, Never>] = []
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(processIdentifier: Int32, terminateAutomatically: Bool, killAutomatically: Bool) {
        self.processIdentifier = processIdentifier
        self.terminateAutomatically = terminateAutomatically
        self.killAutomatically = killAutomatically
    }

    func terminate() {
        lock.lock()
        terminateCount += 1
        lock.unlock()
        if terminateAutomatically { complete(.init(status: 0, reason: .exit)) }
    }

    func kill() {
        lock.lock()
        killCount += 1
        lock.unlock()
        if killAutomatically { complete(.init(status: 9, reason: .uncaughtSignal)) }
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

    func complete(_ value: PluginProcessTermination) {
        lock.lock()
        guard termination == nil else {
            lock.unlock()
            return
        }
        termination = value
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: value) }
    }
}

private actor ScriptedPluginHealthChecker: PluginHealthChecking {
    private var results: [Bool]
    private(set) var requestCount = 0

    init(results: [Bool]) { self.results = results }

    func isHealthy(url: URL, timeoutMilliseconds: Int) async -> Bool {
        requestCount += 1
        return results.isEmpty ? false : results.removeFirst()
    }
}

private actor GatedPluginHealthChecker: PluginHealthChecking {
    private var resultContinuation: CheckedContinuation<Bool, Never>?
    private var observationContinuations: [CheckedContinuation<Void, Never>] = []
    private var requested = false

    func isHealthy(url: URL, timeoutMilliseconds: Int) async -> Bool {
        requested = true
        let observers = observationContinuations
        observationContinuations.removeAll()
        for observer in observers { observer.resume() }
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { observationContinuations.append($0) }
    }

    func resolve(_ result: Bool) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

private actor RecordingPluginClock: PluginRuntimeClock {
    private(set) var sleeps: [UInt64] = []

    func sleep(milliseconds: UInt64) async throws {
        sleeps.append(milliseconds)
    }
}

private struct ThrowingPluginClock: PluginRuntimeClock, Sendable {
    func sleep(milliseconds: UInt64) async throws {
        throw FixtureClockError.failed
    }
}

private enum FixtureClockError: Error {
    case failed
}

private final class RecordingPluginPortAllocator: PluginPortAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private let ports: [String: UInt16]
    private(set) var preferredPorts: [UInt16?] = []
    private(set) var reservedPorts: [Set<UInt16>] = []

    init(ports: [String: UInt16]) { self.ports = ports }

    func allocate(pluginID: String, preferred: UInt16?, reserved: Set<UInt16>) throws -> UInt16 {
        lock.lock()
        preferredPorts.append(preferred)
        reservedPorts.append(reserved)
        lock.unlock()
        guard let port = ports[pluginID] else { throw PluginPortAllocationError.noAvailablePort }
        return port
    }
}

private struct AlwaysAvailablePluginPort: PluginPortAvailabilityChecking, Sendable {
    func isAvailable(_ port: UInt16) -> Bool { true }
}
