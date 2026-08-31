import Foundation
import XCTest
@testable import CCBuddy

final class QoderFileReaderTests: XCTestCase {
    func testPermissionDeniedQoderReadFallsBackAndCachesByFileStamp() throws {
        let fixture = try makeQoderFixture("single")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.projects.appendingPathComponent("-cwd/session.jsonl")
        try write(Data("first payload\n".utf8), to: file)

        let access = DeniedQoderFileAccess()
        let resolver = FakeQoderHelperResolver()
        let runner = FakeQoderHelperRunner()
        let reader = makeReader(access: access, resolver: resolver, runner: runner)

        XCTAssertEqual(try reader.read(file), Data("first payload\n".utf8))
        XCTAssertEqual(try reader.read(file), Data("first payload\n".utf8))
        XCTAssertEqual(runner.singleReadCount, 1, "The second read must use the stamped helper cache")
        XCTAssertEqual(resolver.resolveCount, 1)

        try write(Data("second payload with a different size\n".utf8), to: file)
        XCTAssertEqual(try reader.read(file), Data("second payload with a different size\n".utf8))
        XCTAssertEqual(runner.singleReadCount, 2, "A changed size/mtime must invalidate the cache")

        let outside = fixture.home.appendingPathComponent("ordinary.jsonl")
        try write(Data("outside\n".utf8), to: outside)
        access.deny(outside)
        XCTAssertThrowsError(try reader.read(outside))
        XCTAssertEqual(runner.singleReadCount, 2, "A non-Qoder permission denial must never execute a helper")
    }

    func testPrefetchBatchesProtectedFilesAndServesEveryLaterReadFromCache() throws {
        let fixture = try makeQoderFixture("batch")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var expected: [URL: Data] = [:]
        for index in 0..<35 {
            let file = fixture.projects.appendingPathComponent(
                String(format: "-cwd/session-%02d.jsonl", index)
            )
            let data = Data("payload-\(index)\n".utf8)
            try write(data, to: file)
            expected[file.resolvingSymlinksInPath().standardizedFileURL] = data
        }

        let access = DeniedQoderFileAccess()
        let resolver = FakeQoderHelperResolver()
        let runner = FakeQoderHelperRunner()
        let reader = makeReader(access: access, resolver: resolver, runner: runner)
        reader.prefetch(Array(expected.keys.reversed()))

        XCTAssertEqual(runner.batchSizes, [32, 3])
        XCTAssertEqual(resolver.resolveCount, 1, "One protected data root should resolve its helper once")
        for (file, data) in expected {
            XCTAssertEqual(try reader.read(file), data)
        }
        XCTAssertEqual(runner.singleReadCount, 0, "A successful batch warm must avoid per-file helper starts")
        XCTAssertEqual(runner.batchSizes, [32, 3])
    }

    func testHelperTargetValidationRejectsOutsideFilesSymlinkEscapesAndOversizeData() throws {
        let fixture = try makeQoderFixture("guard")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let transcript = fixture.projects.appendingPathComponent("-cwd/session.jsonl")
        let metadata = fixture.projects.appendingPathComponent("-cwd/session/agent-a.meta.json")
        try write(Data("{}\n".utf8), to: transcript)
        try write(Data("{}".utf8), to: metadata)

        let validatedTranscript = try QoderFileReader.validatedTarget(transcript)
        let validatedMetadata = try QoderFileReader.validatedTarget(metadata)
        XCTAssertEqual(validatedTranscript.dataRoot, fixture.root.standardizedFileURL)
        XCTAssertEqual(validatedMetadata.dataRoot, fixture.root.standardizedFileURL)
        XCTAssertTrue(QoderFileReader.isQoderDataPath(transcript))
        XCTAssertTrue(QoderFileReader.isQoderDataPath(metadata))

        let outside = fixture.home.appendingPathComponent("outside.jsonl")
        try write(Data("{}\n".utf8), to: outside)
        XCTAssertThrowsError(try QoderFileReader.validatedTarget(outside))

        let text = fixture.projects.appendingPathComponent("-cwd/secret.txt")
        try write(Data("secret".utf8), to: text)
        XCTAssertThrowsError(try QoderFileReader.validatedTarget(text))

        let uppercase = fixture.projects.appendingPathComponent("-cwd/uppercase.JSONL")
        try write(Data("{}\n".utf8), to: uppercase)
        XCTAssertFalse(QoderFileReader.isQoderDataPath(uppercase))
        XCTAssertThrowsError(try QoderFileReader.validatedTarget(uppercase))

        let escaped = fixture.projects.appendingPathComponent("-cwd/escaped.jsonl")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
        XCTAssertThrowsError(try QoderFileReader.validatedTarget(escaped))

        XCTAssertThrowsError(
            try QoderFileReader.validatedTarget(transcript, maximumReadBytes: 1)
        ) { error in
            XCTAssertEqual(error as? QoderFileReadError, .fileTooLarge(1))
        }
    }

    func testProtectedQoderFallbackFeedsRepositoryAndUsageScannerInsteadOfReturningZero() throws {
        let fixture = try makeQoderFixture("integration")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.projects.appendingPathComponent("-tmp-project/qoder-session.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"runtime-config","sessionId":"qoder-session","model":"ultimate"}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-07-01T10:00:00Z","sessionId":"qoder-session","message":{"role":"user","content":"protected qoder"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-01T10:00:01Z","sessionId":"qoder-session","message":{"id":"m1","role":"assistant","model":"ultimate","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":8,"output_tokens":2}}}"#,
        ], to: file)

        let access = DeniedQoderFileAccess()
        let resolver = FakeQoderHelperResolver()
        let runner = FakeQoderHelperRunner()
        let reader = makeReader(access: access, resolver: resolver, runner: runner)
        let repository = HistoryRepository(
            historyDirs: [fixture.root.path],
            homeDirectory: fixture.home,
            qoderReader: reader
        )

        let sessions = repository.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.source, .qoder)
        XCTAssertEqual(sessions.first?.model, "ultimate")
        XCTAssertEqual(sessions.first?.totals.inputTokens, 8)
        XCTAssertEqual(sessions.first?.totals.outputTokens, 2)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = UsageHistoryScanner(calendar: calendar, qoderReader: reader).scan(
            configuration: .init(
                historyDirs: [fixture.root.path],
                homeDirectory: fixture.home
            )
        )
        let summary = UsageHistoryQuery.summary(
            days: days,
            range: .all,
            now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-02T00:00:00Z")),
            calendar: calendar
        )
        XCTAssertEqual(summary.tokens, 10)
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.favoriteModel, "ultimate")
        XCTAssertEqual(runner.singleReadCount, 0)
        XCTAssertEqual(runner.batchSizes, [1], "The repository warm should make usage reuse the same cache")
    }

    private func makeReader(
        access: DeniedQoderFileAccess,
        resolver: FakeQoderHelperResolver,
        runner: FakeQoderHelperRunner
    ) -> QoderFileReader {
        QoderFileReader(
            fileAccess: access,
            helperResolver: resolver,
            helperRunner: runner,
            cache: QoderHelperCache()
        )
    }

    private func makeQoderFixture(
        _ name: String
    ) throws -> (home: URL, root: URL, projects: URL) {
        let home = try HistoryTestSupport.temporaryDirectory("qoder-reader-\(name)")
        let root = home.appendingPathComponent(".qoder", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return (home, root, projects)
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
    }
}

private final class DeniedQoderFileAccess: QoderFileAccessing, @unchecked Sendable {
    private let system = SystemQoderFileAccess()
    private let lock = NSLock()
    private var additionallyDenied = Set<String>()

    func deny(_ file: URL) {
        lock.lock()
        additionallyDenied.insert(file.standardizedFileURL.path)
        lock.unlock()
    }

    func readData(at file: URL) throws -> Data {
        if denied(file) { throw permissionDenied() }
        return try system.readData(at: file)
    }

    func probeReadable(at file: URL) throws {
        if denied(file) { throw permissionDenied() }
        try system.probeReadable(at: file)
    }

    func stamp(of file: URL) throws -> QoderFileStamp {
        try system.stamp(of: file)
    }

    private func denied(_ file: URL) -> Bool {
        if QoderFileReader.isQoderDataPath(file) { return true }
        lock.lock()
        defer { lock.unlock() }
        return additionallyDenied.contains(file.standardizedFileURL.path)
    }

    private func permissionDenied() -> Error {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoPermission.rawValue
        )
    }
}

private final class FakeQoderHelperResolver: QoderHelperResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var resolveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func trustedHelper(for dataRoot: URL) throws -> URL {
        lock.lock()
        count += 1
        lock.unlock()
        return dataRoot.appendingPathComponent("fake-qoder-helper")
    }
}

private final class FakeQoderHelperRunner: QoderHelperRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var singles = 0
    private var batches: [Int] = []

    var singleReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return singles
    }

    var batchSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    func read(
        helper: URL,
        target: URL,
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> Data {
        lock.lock()
        singles += 1
        lock.unlock()
        return try Data(contentsOf: target)
    }

    func readBatch(
        helper: URL,
        targets: [URL],
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> [URL: Data] {
        lock.lock()
        batches.append(targets.count)
        lock.unlock()
        return try Dictionary(uniqueKeysWithValues: targets.map { target in
            (target.standardizedFileURL, try Data(contentsOf: target))
        })
    }
}
