import CoreServices
import Foundation
import XCTest
@testable import CCBuddy

final class UsageHistoryResilienceTests: XCTestCase {
    func testStreamingLineReaderStopsAfterCooperativeMidFileCancellation() async throws {
        let container = try temporaryDirectory("usage-stream-cancellation")
        let file = container.appendingPathComponent("large.jsonl")
        let payload = (0..<1_000).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try Data(payload.utf8).write(to: file)
        let reader = UsageHistoryLineReader(chunkBytes: 13, maximumLineBytes: 128)

        let result = await Task.detached { () -> (completed: Bool, lines: [String]) in
            var lines: [String] = []
            let completed = reader.forEachLine(in: file) { line in
                lines.append(line)
                if lines.count == 3 {
                    withUnsafeCurrentTask { task in task?.cancel() }
                }
                return true
            }
            return (completed, lines)
        }.value

        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.lines, ["line-0", "line-1", "line-2"])
    }

    func testWatcherRearmsAfterAtomicRootReplacementAndContinuesInvalidating() async throws {
        let container = try temporaryDirectory("usage-watcher-rearm")
        let root = container.appendingPathComponent("history", isDirectory: true)
        let retiredRoot = container.appendingPathComponent("history-retired", isDirectory: true)
        _ = try writeHistory(
            under: root,
            name: "session.jsonl",
            id: "before-replacement",
            input: 2,
            output: 1
        )
        let configuration = UsageHistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: container
        )
        let service = UsageHistoryService(calendar: Self.utcCalendar)

        let initial = try await service.summary(configuration: configuration, range: .all)
        XCTAssertEqual(initial.tokens, 3)

        let rootInvalidated = expectation(description: "replacement invalidates cached usage")
        rootInvalidated.assertForOverFulfill = false
        let rootProbe = WatchInvalidationProbe(
            service: service,
            expectation: rootInvalidated,
            requiresRootChange: true
        )
        var watcher = try XCTUnwrap(UsageHistoryWatcher(
            paths: [root.path],
            latency: 0.05,
            onChange: { rootsChanged in rootProbe.receive(rootsChanged: rootsChanged) }
        ))

        try FileManager.default.moveItem(at: root, to: retiredRoot)
        _ = try writeHistory(
            under: root,
            name: "session.jsonl",
            id: "after-replacement",
            input: 6,
            output: 1
        )

        await fulfillment(of: [rootInvalidated], timeout: 8)
        XCTAssertTrue(rootProbe.observedRootChange)
        watcher.invalidate()

        let replacement = try await service.summary(configuration: configuration, range: .all)
        XCTAssertEqual(replacement.tokens, 7)

        let replacementInvalidated = expectation(
            description: "rebuilt watcher invalidates usage after a later write"
        )
        replacementInvalidated.assertForOverFulfill = false
        let replacementProbe = WatchInvalidationProbe(
            service: service,
            expectation: replacementInvalidated,
            requiresRootChange: false
        )
        watcher = try XCTUnwrap(UsageHistoryWatcher(
            paths: [root.path],
            latency: 0.05,
            onChange: { rootsChanged in replacementProbe.receive(rootsChanged: rootsChanged) }
        ))

        // FSEventStreamStart has completed, but allow its dispatch queue to settle before the
        // mutation so the second assertion cannot be satisfied by replacement setup traffic.
        try await Task.sleep(nanoseconds: 150_000_000)
        let handle = try FileHandle(forWritingTo: firstFileForReplacement(root: root))
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.claudeLine(
            id: "after-rearm",
            input: 4,
            output: 1
        ))
        try handle.close()

        await fulfillment(of: [replacementInvalidated], timeout: 8)
        let refreshed = try await service.summary(configuration: configuration, range: .all)
        XCTAssertEqual(refreshed.tokens, 12)
        watcher.invalidate()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retiredRoot.appendingPathComponent("projects/fixture/session.jsonl").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: firstFileForReplacement(root: root).path
        ))
    }

    func testInvalidateWaitsForCancelledScanToDrainBeforeReplacementScanStarts() async throws {
        let container = try temporaryDirectory("usage-invalidate-drain")
        let slowRoot = container.appendingPathComponent("slow", isDirectory: true)
        let replacementRoot = container.appendingPathComponent("replacement", isDirectory: true)
        _ = try writeHistory(
            under: slowRoot,
            name: "slow.jsonl",
            id: "slow",
            input: 1,
            output: 1
        )
        _ = try writeHistory(
            under: replacementRoot,
            name: "replacement.jsonl",
            id: "replacement",
            input: 8,
            output: 2
        )

        let slowConfiguration = UsageHistoryConfiguration(
            historyDirs: [slowRoot.path],
            homeDirectory: container
        )
        let replacementConfiguration = UsageHistoryConfiguration(
            historyDirs: [replacementRoot.path],
            homeDirectory: container
        )
        let scanner = BlockingUsageHistoryScanner(calendar: Self.utcCalendar)
        defer { scanner.release() }
        let service = UsageHistoryService(calendar: Self.utcCalendar, scanner: scanner)

        let slowScan = Task {
            try await service.summary(configuration: slowConfiguration, range: .all)
        }
        try await scanner.waitUntilStarted()

        let invalidationFinished = LockedFlag()
        let invalidation = Task.detached(priority: .high) {
            await service.invalidate()
            invalidationFinished.set()
        }
        try await scanner.waitUntilCancellationObserved()

        let replacementScan = Task {
            try await service.summary(configuration: replacementConfiguration, range: .all)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(
            invalidationFinished.value,
            "The fixture must keep the old scan alive long enough to exercise drain waiting"
        )
        XCTAssertEqual(
            scanner.startedCallCount,
            1,
            "A replacement scan must not overlap the cancelled scan that invalidate is draining"
        )

        scanner.release()
        await invalidation.value
        let replacement = try await replacementScan.value
        _ = try? await slowScan.value
        XCTAssertEqual(replacement.tokens, 10)
        XCTAssertEqual(scanner.startedCallCount, 2)
    }

    @MainActor
    func testAppShutdownDrainsUsageScanBeforeAllowingAnotherScan() async throws {
        let container = try temporaryDirectory("usage-shutdown-drain")
        let slowRoot = container.appendingPathComponent("slow", isDirectory: true)
        let replacementRoot = container.appendingPathComponent("replacement", isDirectory: true)
        _ = try writeHistory(
            under: slowRoot,
            name: "slow.jsonl",
            id: "slow",
            input: 1,
            output: 1
        )
        _ = try writeHistory(
            under: replacementRoot,
            name: "replacement.jsonl",
            id: "post-shutdown",
            input: 11,
            output: 2
        )

        let slowConfiguration = UsageHistoryConfiguration(
            historyDirs: [slowRoot.path],
            homeDirectory: container
        )
        let replacementConfiguration = UsageHistoryConfiguration(
            historyDirs: [replacementRoot.path],
            homeDirectory: container
        )
        let scanner = BlockingUsageHistoryScanner(calendar: Self.utcCalendar)
        defer { scanner.release() }
        let service = UsageHistoryService(calendar: Self.utcCalendar, scanner: scanner)
        let repository = ConfigRepository(configURL: container.appendingPathComponent("config.json"))
        var config = AppConfig(gatewayEnabled: false)
        config.historyDirs = [slowRoot.path]
        try repository.save(config)
        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": container.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
            usageHistoryService: service
        )

        let slowScan = Task {
            try await service.summary(configuration: slowConfiguration, range: .all)
        }
        try await scanner.waitUntilStarted()

        let shutdownFinished = LockedFlag()
        let shutdown = Task { @MainActor in
            await model.shutdown()
            shutdownFinished.set()
        }
        try await scanner.waitUntilCancellationObserved()

        let postShutdownScan = Task {
            try await service.summary(configuration: replacementConfiguration, range: .all)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(
            shutdownFinished.value,
            "shutdown must await the non-cancellable tail of the active usage scan"
        )
        XCTAssertEqual(
            scanner.startedCallCount,
            1,
            "shutdown must not leave the old usage scan running beside a replacement scan"
        )

        scanner.release()
        await shutdown.value
        let replacement = try await postShutdownScan.value
        _ = try? await slowScan.value
        XCTAssertEqual(replacement.tokens, 13)
        XCTAssertEqual(scanner.startedCallCount, 2)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func writeHistory(
        under root: URL,
        name: String,
        id: String,
        input: Int,
        output: Int
    ) throws -> URL {
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent(name)
        try Self.claudeLine(id: id, input: input, output: output).write(to: file)
        return file
    }

    private func firstFileForReplacement(root: URL) -> URL {
        root.appendingPathComponent("projects/fixture/session.jsonl")
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func claudeLine(id: String, input: Int, output: Int) -> Data {
        let object: [String: Any] = [
            "timestamp": "2026-07-01T10:00:00Z",
            "message": [
                "id": id,
                "model": "claude-resilience",
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data + Data([0x0A])
    }
}

/// Holds the first synchronous scan after it has entered non-async work. Cancellation is observed
/// but deliberately does not release the call, making drain ordering deterministic on every CI
/// machine without relying on a large JSON allocation being slow enough.
private final class BlockingUsageHistoryScanner: UsageHistoryScanning, @unchecked Sendable {
    private let condition = NSCondition()
    private let backing: UsageHistoryScanner
    private var calls = 0
    private var firstCallStarted = false
    private var observedCancellation = false
    private var released = false

    init(calendar: Calendar) {
        backing = UsageHistoryScanner(calendar: calendar)
    }

    func scan(configuration: UsageHistoryConfiguration) -> [String: UsageHistoryDay] {
        condition.lock()
        calls += 1
        let shouldBlock = calls == 1
        if shouldBlock {
            firstCallStarted = true
            condition.broadcast()
            while !released {
                if Task.isCancelled {
                    observedCancellation = true
                    condition.broadcast()
                }
                _ = condition.wait(until: Date().addingTimeInterval(0.002))
            }
        }
        condition.unlock()
        return backing.scan(configuration: configuration)
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilStarted() async throws {
        for _ in 0..<5_000 {
            if hasStarted { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw BlockingUsageScannerError.timedOutWaitingForStart
    }

    func waitUntilCancellationObserved() async throws {
        for _ in 0..<5_000 {
            if hasObservedCancellation { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw BlockingUsageScannerError.timedOutWaitingForCancellation
    }

    var startedCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return firstCallStarted
    }

    private var hasObservedCancellation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedCancellation
    }
}

private enum BlockingUsageScannerError: Error {
    case timedOutWaitingForStart
    case timedOutWaitingForCancellation
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class WatchInvalidationProbe: @unchecked Sendable {
    private let service: UsageHistoryService
    private let expectation: XCTestExpectation
    private let requiresRootChange: Bool
    private let lock = NSLock()
    private var claimed = false
    private var rootChange = false

    init(
        service: UsageHistoryService,
        expectation: XCTestExpectation,
        requiresRootChange: Bool
    ) {
        self.service = service
        self.expectation = expectation
        self.requiresRootChange = requiresRootChange
    }

    var observedRootChange: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rootChange
    }

    func receive(rootsChanged: Bool) {
        lock.lock()
        rootChange = rootChange || rootsChanged
        let shouldClaim = !claimed && (!requiresRootChange || rootsChanged)
        if shouldClaim { claimed = true }
        lock.unlock()
        guard shouldClaim else { return }

        Task {
            await service.invalidate()
            expectation.fulfill()
        }
    }
}
