import CoreServices
import Foundation
import XCTest
@testable import CCBuddy

final class ConversationHistoryWatcherTests: XCTestCase {
    func testClassifiesIncrementalDroppedAndRootReplacementEvents() {
        let incremental = ConversationHistoryWatcher.classify(
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )
        XCTAssertEqual(incremental, ConversationHistoryEventDisposition(
            rootReplacementDetected: false,
            droppedEventsDetected: false,
            requiresFullRescan: false
        ))

        let dropped = ConversationHistoryWatcher.classify(flags: FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagKernelDropped
        ))
        XCTAssertTrue(dropped.droppedEventsDetected)
        XCTAssertTrue(dropped.requiresFullRescan)
        XCTAssertFalse(dropped.rootReplacementDetected)

        let replaced = ConversationHistoryWatcher.classify(
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        )
        XCTAssertTrue(replaced.rootReplacementDetected)
        XCTAssertTrue(replaced.requiresFullRescan)
        XCTAssertFalse(replaced.droppedEventsDetected)
    }

    func testMissingRootAppearsAndWatcherRearmsWithConcretePaths() async throws {
        let container = try temporaryDirectory("conversation-watcher-appears")
        let root = container.appendingPathComponent("history", isDirectory: true)
        let file = root.appendingPathComponent("session.jsonl")
        let appeared = expectation(description: "missing conversation root appears")
        appeared.assertForOverFulfill = false
        let changed = expectation(description: "new stream reports a concrete file path")
        changed.assertForOverFulfill = false
        let probe = ConversationWatcherProbe()
        probe.expectRootAppearance(root, expectation: appeared)

        let watcher = try XCTUnwrap(ConversationHistoryWatcher(
            roots: [root],
            latency: 0.02,
            debounceInterval: 0.08,
            rootProbeInterval: 0.05,
            callbackQueue: DispatchQueue(label: "dev.ccbud.tests.conversation-watcher.appears"),
            onEvent: { event in probe.receive(event) }
        ))
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.isRunning)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: file)
        await fulfillment(of: [appeared], timeout: 8)

        probe.expectPath(file, expectation: changed)
        try await Task.sleep(nanoseconds: 150_000_000)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        await fulfillment(of: [changed], timeout: 8)

        XCTAssertTrue(probe.events.contains { event in
            event.rootChanges.contains {
                $0.root.standardizedFileURL == root.standardizedFileURL
                    && $0.kind == .appeared
            } && event.requiresFullRescan
        })
        XCTAssertTrue(probe.events.contains { event in
            event.changedPaths.map(\.standardizedFileURL).contains(file.standardizedFileURL)
        })

        watcher.stop()
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
    }

    func testUsesTrailingDebounceAndSuppressesPendingDeliveryAfterStop() async throws {
        let root = try temporaryDirectory("conversation-watcher-debounce")
        let file = root.appendingPathComponent("session.jsonl")
        try Data().write(to: file)
        let changed = expectation(description: "rapid writes are delivered")
        changed.assertForOverFulfill = false
        let probe = ConversationWatcherProbe()
        probe.expectPath(file, expectation: changed)
        let watcher = try XCTUnwrap(ConversationHistoryWatcher(
            roots: [root],
            latency: 0.02,
            debounceInterval: 0.60,
            rootProbeInterval: 2.0,
            callbackQueue: DispatchQueue(label: "dev.ccbud.tests.conversation-watcher.debounce"),
            onEvent: { event in probe.receive(event) }
        ))
        XCTAssertTrue(watcher.start())
        try await Task.sleep(nanoseconds: 150_000_000)

        let handle = try FileHandle(forWritingTo: file)
        for value in ["one\n", "two\n", "three\n"] {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(value.utf8))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try handle.close()

        await fulfillment(of: [changed], timeout: 8)
        try await Task.sleep(nanoseconds: 900_000_000)
        let deliveredBeforeStop = probe.events.filter {
            $0.changedPaths.map(\.standardizedFileURL).contains(file.standardizedFileURL)
        }.count
        XCTAssertEqual(deliveredBeforeStop, 1)

        watcher.stop()
        try Data("ignored\n".utf8).append(to: file)
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(probe.events.filter {
            $0.changedPaths.map(\.standardizedFileURL).contains(file.standardizedFileURL)
        }.count, deliveredBeforeStop)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private final class ConversationWatcherProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversationHistoryWatchEvent] = []
    private var expectedRoot: (URL, XCTestExpectation)?
    private var expectedPath: (URL, XCTestExpectation)?

    var events: [ConversationHistoryWatchEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func expectRootAppearance(_ root: URL, expectation: XCTestExpectation) {
        lock.lock()
        expectedRoot = (root.standardizedFileURL, expectation)
        lock.unlock()
    }

    func expectPath(_ path: URL, expectation: XCTestExpectation) {
        lock.lock()
        expectedPath = (path.standardizedFileURL, expectation)
        lock.unlock()
    }

    func receive(_ event: ConversationHistoryWatchEvent) {
        var expectations: [XCTestExpectation] = []
        lock.lock()
        storage.append(event)
        if let expectedRoot,
           event.rootChanges.contains(where: {
               $0.root.standardizedFileURL == expectedRoot.0 && $0.kind == .appeared
           }) {
            expectations.append(expectedRoot.1)
            self.expectedRoot = nil
        }
        if let expectedPath,
           event.changedPaths.map(\.standardizedFileURL).contains(expectedPath.0) {
            expectations.append(expectedPath.1)
            self.expectedPath = nil
        }
        lock.unlock()
        for expectation in expectations { expectation.fulfill() }
    }
}

private extension Data {
    func append(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
