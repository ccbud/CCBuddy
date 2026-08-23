import CoreServices
import Darwin
import Foundation
import XCTest
@testable import CCBuddy

final class UsageHistoryResilienceTests: XCTestCase {
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
        let slowFile = try writeSlowHistory(under: slowRoot)
        let replacementFile = try writeHistory(
            under: replacementRoot,
            name: "replacement.jsonl",
            id: "replacement",
            input: 8,
            output: 2
        )
        try ageAccessAndModificationTimes(of: slowFile)
        try ageAccessAndModificationTimes(of: replacementFile)

        let slowConfiguration = UsageHistoryConfiguration(
            historyDirs: [slowRoot.path],
            homeDirectory: container
        )
        let replacementConfiguration = UsageHistoryConfiguration(
            historyDirs: [replacementRoot.path],
            homeDirectory: container
        )
        let service = UsageHistoryService(calendar: Self.utcCalendar)
        let slowStamp = try accessStamp(of: slowFile)
        let replacementStamp = try accessStamp(of: replacementFile)

        let slowScan = Task {
            try await service.summary(configuration: slowConfiguration, range: .all)
        }
        try await waitUntilRead(slowFile, after: slowStamp)

        let invalidationFinished = LockedFlag()
        let invalidation = Task.detached(priority: .high) {
            await service.invalidate()
            invalidationFinished.set()
        }
        // Give the high-priority invalidation call a deterministic chance to enter the actor and
        // cancel the scan while its one very large record is still being decoded.
        for _ in 0..<8 { await Task.yield() }

        let replacementScan = Task {
            try await service.summary(configuration: replacementConfiguration, range: .all)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(
            invalidationFinished.value,
            "The fixture must keep the old scan alive long enough to exercise drain waiting"
        )
        XCTAssertEqual(
            try accessStamp(of: replacementFile),
            replacementStamp,
            "A replacement scan must not overlap the cancelled scan that invalidate is draining"
        )

        await invalidation.value
        let replacement = try await replacementScan.value
        _ = try? await slowScan.value
        XCTAssertEqual(replacement.tokens, 10)
        XCTAssertNotEqual(try accessStamp(of: replacementFile), replacementStamp)
    }

    @MainActor
    func testAppShutdownDrainsUsageScanBeforeAllowingAnotherScan() async throws {
        let container = try temporaryDirectory("usage-shutdown-drain")
        let slowRoot = container.appendingPathComponent("slow", isDirectory: true)
        let replacementRoot = container.appendingPathComponent("replacement", isDirectory: true)
        let slowFile = try writeSlowHistory(under: slowRoot)
        let replacementFile = try writeHistory(
            under: replacementRoot,
            name: "replacement.jsonl",
            id: "post-shutdown",
            input: 11,
            output: 2
        )
        try ageAccessAndModificationTimes(of: slowFile)
        try ageAccessAndModificationTimes(of: replacementFile)

        let slowConfiguration = UsageHistoryConfiguration(
            historyDirs: [slowRoot.path],
            homeDirectory: container
        )
        let replacementConfiguration = UsageHistoryConfiguration(
            historyDirs: [replacementRoot.path],
            homeDirectory: container
        )
        let service = UsageHistoryService(calendar: Self.utcCalendar)
        let repository = ConfigRepository(configURL: container.appendingPathComponent("config.json"))
        var config = AppConfig(gatewayEnabled: false)
        config.historyDirs = [slowRoot.path]
        try repository.save(config)
        let model = AppModel(
            repository: repository,
            supervisor: BifrostSupervisor(environment: ["CCBUD_HOME": container.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
            usageHistoryService: service
        )
        let slowStamp = try accessStamp(of: slowFile)
        let replacementStamp = try accessStamp(of: replacementFile)

        let slowScan = Task {
            try await service.summary(configuration: slowConfiguration, range: .all)
        }
        try await waitUntilRead(slowFile, after: slowStamp)

        let shutdownFinished = LockedFlag()
        let shutdown = Task { @MainActor in
            await model.shutdown()
            shutdownFinished.set()
        }
        for _ in 0..<8 { await Task.yield() }

        let postShutdownScan = Task {
            try await service.summary(configuration: replacementConfiguration, range: .all)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(
            shutdownFinished.value,
            "shutdown must await the non-cancellable tail of the active usage scan"
        )
        XCTAssertEqual(
            try accessStamp(of: replacementFile),
            replacementStamp,
            "shutdown must not leave the old usage scan running beside a replacement scan"
        )

        await shutdown.value
        let replacement = try await postShutdownScan.value
        _ = try? await slowScan.value
        XCTAssertEqual(replacement.tokens, 13)
        XCTAssertNotEqual(try accessStamp(of: replacementFile), replacementStamp)
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

    /// A single large line is intentional. UsageHistoryScanner checks cancellation between lines;
    /// once decoding of this line begins, invalidate/shutdown must await that in-progress work.
    private func writeSlowHistory(under root: URL) throws -> URL {
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("slow.jsonl")
        var data = Data(
            #"{"timestamp":"2026-07-01T10:00:00Z","message":{"id":"slow","model":"slow-model","usage":{"input_tokens":1,"output_tokens":1}},"padding":""#.utf8
        )
        data.append(Data(repeating: 0x61, count: 48 * 1_024 * 1_024))
        data.append(Data(#""}"#.utf8))
        data.append(0x0A)
        try data.write(to: file)
        return file
    }

    private func ageAccessAndModificationTimes(of file: URL) throws {
        let times = [
            timespec(tv_sec: 1_600_000_000, tv_nsec: 0),
            timespec(tv_sec: 1_600_000_000, tv_nsec: 0),
        ]
        let result: Int32 = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return times.withUnsafeBufferPointer { buffer in
                Darwin.utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func accessStamp(of file: URL) throws -> FileAccessStamp {
        var information = Darwin.stat()
        guard lstat(file.path, &information) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileAccessStamp(
            seconds: Int64(information.st_atimespec.tv_sec),
            nanoseconds: Int64(information.st_atimespec.tv_nsec)
        )
    }

    private func waitUntilRead(_ file: URL, after original: FileAccessStamp) async throws {
        for _ in 0..<5_000 {
            if try accessStamp(of: file) != original { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ResilienceTestError.timedOutWaitingForRead(file.path)
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

private struct FileAccessStamp: Equatable {
    let seconds: Int64
    let nanoseconds: Int64
}

private enum ResilienceTestError: LocalizedError {
    case timedOutWaitingForRead(String)

    var errorDescription: String? {
        switch self {
        case .timedOutWaitingForRead(let path):
            return "Timed out waiting for usage scanner to read \(path)"
        }
    }
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
