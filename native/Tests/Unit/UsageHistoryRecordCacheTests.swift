import XCTest

@testable import CCBuddy

/// The usage scan used to re-read every transcript on every launch — 14 GB on a real library, for
/// a few hundred day buckets. These tests pin the two properties that make skipping that safe: an
/// unchanged transcript is not read again, and a changed one always is.
final class UsageHistoryRecordCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-usage-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    private var claudeLine: String {
        #"{"type":"assistant","timestamp":"2026-01-02T03:04:05Z","message":{"id":"m1","model":"claude","usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n"
    }

    private func configuration(_ historyRoot: URL) -> UsageHistoryConfiguration {
        UsageHistoryConfiguration(
            historyDirs: [historyRoot.path],
            active: "all",
            homeDirectory: root
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAnUnchangedTranscriptIsNotReadTwice() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let file = try write(claudeLine, to: "session.jsonl", in: projects)

        let cache = UsageHistoryRecordCache(file: root.appendingPathComponent("cache.json"))
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)

        let first = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertEqual(first.values.reduce(0) { $0 + $1.tokens }, 15)

        // Rewrite the contents with a different value of the same byte length, then restore the
        // modification date, so the identity the cache keys on is unchanged. A scanner that read
        // the file again would report 19; one honouring the cache still reports 15.
        let identity = try XCTUnwrap(UsageHistoryFileIdentity.of(file))
        let replacement = claudeLine.replacingOccurrences(
            of: #""output_tokens":5"#,
            with: #""output_tokens":9"#
        )
        XCTAssertEqual(replacement.utf8.count, claudeLine.utf8.count)
        try Data(replacement.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: identity.modifiedAt],
            ofItemAtPath: file.path
        )

        let second = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
            .scan(configuration: configuration(historyRoot))
        XCTAssertEqual(second, first)
    }

    func testAChangedTranscriptIsParsedAgain() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let file = try write(claudeLine, to: "session.jsonl", in: projects)

        let cache = UsageHistoryRecordCache(file: root.appendingPathComponent("cache.json"))
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
        _ = scanner.scan(configuration: configuration(historyRoot))

        let grown = claudeLine + #"{"type":"assistant","timestamp":"2026-01-02T03:04:06Z","message":{"id":"m2","model":"claude","usage":{"input_tokens":100,"output_tokens":1}}}"# + "\n"
        try Data(grown.utf8).write(to: file)

        let second = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertEqual(second.values.reduce(0) { $0 + $1.tokens }, 116)
    }

    func testTheCacheSurvivesARelaunchAndProducesTheSameAggregate() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        _ = try write(claudeLine, to: "session.jsonl", in: projects)
        let cacheFile = root.appendingPathComponent("cache.json")

        let cold = UsageHistoryScanner(
            calendar: utcCalendar(),
            recordCache: UsageHistoryRecordCache(file: cacheFile)
        ).scan(configuration: configuration(historyRoot))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheFile.path),
            "the cache has to reach disk or a relaunch pays the full scan again"
        )

        let warm = UsageHistoryScanner(
            calendar: utcCalendar(),
            recordCache: UsageHistoryRecordCache(file: cacheFile)
        ).scan(configuration: configuration(historyRoot))
        XCTAssertEqual(warm, cold)
    }

    func testEntriesForDeletedTranscriptsAreDropped() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let keep = try write(claudeLine, to: "keep.jsonl", in: projects)
        let remove = try write(claudeLine, to: "remove.jsonl", in: projects)
        let cacheFile = root.appendingPathComponent("cache.json")

        _ = UsageHistoryScanner(
            calendar: utcCalendar(),
            recordCache: UsageHistoryRecordCache(file: cacheFile)
        ).scan(configuration: configuration(historyRoot))

        try FileManager.default.removeItem(at: remove)
        _ = UsageHistoryScanner(
            calendar: utcCalendar(),
            recordCache: UsageHistoryRecordCache(file: cacheFile)
        ).scan(configuration: configuration(historyRoot))

        let reloaded = UsageHistoryRecordCache(file: cacheFile)
        let keepIdentity = try XCTUnwrap(UsageHistoryFileIdentity.of(keep))
        XCTAssertNotNil(reloaded.records(for: keep, identity: keepIdentity))
        XCTAssertNil(
            reloaded.records(
                for: remove,
                identity: .init(modifiedAt: keepIdentity.modifiedAt, sizeBytes: keepIdentity.sizeBytes)
            ),
            "a deleted transcript must not keep its entry, or the cache grows without bound"
        )
    }

    func testACorruptCacheCostsARescanAndNothingElse() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        _ = try write(claudeLine, to: "session.jsonl", in: projects)
        let cacheFile = root.appendingPathComponent("cache.json")
        try Data("not json at all".utf8).write(to: cacheFile)

        let days = UsageHistoryScanner(
            calendar: utcCalendar(),
            recordCache: UsageHistoryRecordCache(file: cacheFile)
        ).scan(configuration: configuration(historyRoot))
        XCTAssertEqual(days.values.reduce(0) { $0 + $1.tokens }, 15)
    }

    func testIdentityComparesSizeAndModificationTime() throws {
        let file = try write("x", to: "identity.txt", in: root)
        let identity = try XCTUnwrap(UsageHistoryFileIdentity.of(file))
        let records = UsageHistoryFileRecords(
            modifiedAt: identity.modifiedAt,
            sizeBytes: identity.sizeBytes,
            claude: [],
            codex: []
        )
        XCTAssertTrue(records.matches(identity))
        XCTAssertFalse(records.matches(.init(
            modifiedAt: identity.modifiedAt,
            sizeBytes: identity.sizeBytes + 1
        )))
        XCTAssertFalse(records.matches(.init(
            modifiedAt: identity.modifiedAt.addingTimeInterval(2),
            sizeBytes: identity.sizeBytes
        )))
    }

    func testScanningWithoutACacheStillWorks() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        _ = try write(claudeLine, to: "session.jsonl", in: projects)

        let days = UsageHistoryScanner(calendar: utcCalendar())
            .scan(configuration: configuration(historyRoot))
        XCTAssertEqual(days.values.reduce(0) { $0 + $1.tokens }, 15)
    }
}
