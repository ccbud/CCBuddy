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

    /// An upgraded install finds the cache its previous version wrote. Version 1 entries lack the
    /// continuation fields and must not be trusted as-is: the gate ignores them wholesale, the
    /// scan rebuilds from the transcripts, and the next commit rewrites the file as version 2 —
    /// exactly the path every real user crosses once. (A rollback crosses the same gate in the
    /// other direction: version-1 code ignores a version-2 document identically.)
    func testVersionOneCacheIsIgnoredRebuiltAndRewrittenAsVersionTwo() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let file = try write(claudeLine, to: "session.jsonl", in: projects)
        let cacheFile = root.appendingPathComponent("cache.json")

        // A version-1 document whose entry matches the file's identity but carries poisoned
        // counts. If the gate ever trusted old entries, the poison would reach the aggregates.
        let identity = try XCTUnwrap(UsageHistoryFileIdentity.of(file))
        let poisoned = UsageHistoryFileRecords(
            modifiedAt: identity.modifiedAt,
            sizeBytes: identity.sizeBytes,
            claude: [.init(
                id: "m1", requestID: nil, sidechain: false,
                timestamp: Date(timeIntervalSince1970: 1_767_236_645),
                model: "claude", input: 999_999, output: 999_999,
                cacheRead: 0, cacheCreation: 0
            )],
            codex: []
        )
        let seed = UsageHistoryRecordCache(file: cacheFile)
        seed.store(poisoned, for: file)
        seed.commit(retaining: [UsageHistoryRecordCache.key(for: file)])
        var document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any]
        )
        XCTAssertEqual(document["version"] as? Int, 2)
        document["version"] = 1
        try JSONSerialization.data(withJSONObject: document).write(to: cacheFile)

        let days = UsageHistoryScanner(
            calendar: utcCalendar(),
            recordCache: UsageHistoryRecordCache(file: cacheFile)
        ).scan(configuration: configuration(historyRoot))
        XCTAssertEqual(
            days.values.reduce(0) { $0 + $1.tokens },
            15,
            "Version-1 entries must be rebuilt from disk, never trusted"
        )

        let upgraded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any]
        )
        XCTAssertEqual(upgraded["version"] as? Int, 2)
        let reloaded = UsageHistoryRecordCache(file: cacheFile)
        XCTAssertEqual(reloaded.records(for: file, identity: identity)?.claude.first?.input, 10)
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

    // MARK: - Append-only continuation

    private func codexJSONLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func codexTokenTotalsLine(
        _ timestamp: String,
        totals: (input: Int, cached: Int, output: Int)
    ) -> String {
        codexJSONLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": totals.input,
                        "cached_input_tokens": totals.cached,
                        "output_tokens": totals.output,
                        "total_tokens": totals.input + totals.output,
                    ],
                ],
            ],
        ])
    }

    /// A live rollout appends every few seconds while the head of the file never changes. Deltas
    /// against previous cumulative totals and the current model both live in cross-line parser
    /// state, so the append must resume that state — and must not re-read the head at all.
    func testCodexAppendContinuesParseWithCarriedStateInsteadOfRereading() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let sessions = historyRoot.appendingPathComponent("sessions/2026/07/01", isDirectory: true)
        let modelLine = codexJSONLine([
            "timestamp": "2026-07-01T12:00:01Z",
            "type": "turn_context",
            "payload": ["model": "gpt-9"],
        ])
        // Filler keeps the later corruption outside the 256-byte append-only proof window: the
        // point of the test is that untouched bytes far behind the boundary are never read again.
        let filler = (0..<4).map { index in
            codexJSONLine(["timestamp": "2026-07-01T12:00:01Z", "type": "filler-\(index)",
                           "payload": ["noise": String(repeating: "x", count: 96)]])
        }.joined()
        let head = modelLine + filler + codexTokenTotalsLine(
            "2026-07-01T12:00:02Z",
            totals: (1_000, 600, 80)
        )
        let file = try write(head, to: "rollout-live.jsonl", in: sessions)

        let cache = UsageHistoryRecordCache(file: root.appendingPathComponent("cache.json"))
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
        let first = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertEqual(first.values.reduce(0) { $0 + $1.models["gpt-9", default: 0] }, 1_080)

        // Corrupt the head in place (same byte count, no longer a turn_context) and append the
        // next cumulative report. A scanner that re-read the file would lose the model and
        // mis-derive the delta; the continuation must notice neither.
        let corrupted = head.replacingOccurrences(of: "turn_context", with: "xurn_context")
        XCTAssertEqual(corrupted.utf8.count, head.utf8.count)
        try Data((corrupted + codexTokenTotalsLine(
            "2026-07-01T12:00:09Z",
            totals: (1_500, 900, 130)
        )).utf8).write(to: file)

        let second = scanner.scan(configuration: configuration(historyRoot))
        let day = try XCTUnwrap(second["2026-07-01"])
        XCTAssertEqual(day.requests, 2)
        XCTAssertEqual(
            day.models["gpt-9", default: 0],
            1_080 + 550,
            "Both the carried model and the carried totals must survive the append"
        )
    }

    func testCodexRewrittenFileIsFullyReparsedNotContinued() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let sessions = historyRoot.appendingPathComponent("sessions/2026/07/01", isDirectory: true)
        let file = try write(
            codexTokenTotalsLine("2026-07-01T12:00:02Z", totals: (1_000, 600, 80)),
            to: "rollout-rewrite.jsonl",
            in: sessions
        )

        let cache = UsageHistoryRecordCache(file: root.appendingPathComponent("cache.json"))
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
        _ = scanner.scan(configuration: configuration(historyRoot))

        // Replace the file with unrelated, longer content: the bytes before the previously parsed
        // boundary changed, so the append-only proof fails and everything reparses.
        try Data((
            codexTokenTotalsLine("2026-07-02T09:00:00Z", totals: (10, 0, 5))
                + codexTokenTotalsLine("2026-07-02T09:00:01Z", totals: (30, 0, 15))
        ).utf8).write(to: file)

        let second = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertNil(second["2026-07-01"], "No stale event from the replaced content may survive")
        XCTAssertEqual(second["2026-07-02"]?.requests, 2)
        XCTAssertEqual(second["2026-07-02"]?.tokens, 15 + 30)
    }

    func testPartialTrailingLineIsPickedUpOnceCompleted() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let secondLine = #"{"type":"assistant","timestamp":"2026-01-02T03:04:06Z","message":{"id":"m2","model":"claude","usage":{"input_tokens":100,"output_tokens":1}}}"# + "\n"
        let fragment = String(secondLine.prefix(40))
        let file = try write(claudeLine + fragment, to: "session.jsonl", in: projects)

        let cache = UsageHistoryRecordCache(file: root.appendingPathComponent("cache.json"))
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
        let first = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertEqual(first.values.reduce(0) { $0 + $1.tokens }, 15)

        try Data((claudeLine + secondLine).utf8).write(to: file)
        let second = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertEqual(
            second.values.reduce(0) { $0 + $1.tokens },
            116,
            "The record whose line was mid-write must appear once its terminator lands"
        )
    }

    func testUnterminatedCompleteFinalLineIsStillCounted() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let unterminated = String(claudeLine.dropLast())
        _ = try write(unterminated, to: "imported.jsonl", in: projects)

        let cache = UsageHistoryRecordCache(file: root.appendingPathComponent("cache.json"))
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
        XCTAssertEqual(
            scanner.scan(configuration: configuration(historyRoot))
                .values.reduce(0) { $0 + $1.tokens },
            15
        )
        // And again from the warm cache: the fast path must agree with the first parse.
        XCTAssertEqual(
            scanner.scan(configuration: configuration(historyRoot))
                .values.reduce(0) { $0 + $1.tokens },
            15
        )
    }

    func testCommitPacesRewritesAndFlushPersistsImmediately() throws {
        let historyRoot = root.appendingPathComponent("home", isDirectory: true)
        let projects = historyRoot.appendingPathComponent("projects/app", isDirectory: true)
        let file = try write(claudeLine, to: "session.jsonl", in: projects)
        let cacheFile = root.appendingPathComponent("cache.json")

        let cache = UsageHistoryRecordCache(file: cacheFile, minimumPersistInterval: 3_600)
        let scanner = UsageHistoryScanner(calendar: utcCalendar(), recordCache: cache)
        _ = scanner.scan(configuration: configuration(historyRoot))
        let firstWrite = try Data(contentsOf: cacheFile)

        let grown = claudeLine + #"{"type":"assistant","timestamp":"2026-01-02T03:04:06Z","message":{"id":"m2","model":"claude","usage":{"input_tokens":100,"output_tokens":1}}}"# + "\n"
        try Data(grown.utf8).write(to: file)
        _ = scanner.scan(configuration: configuration(historyRoot))
        XCTAssertEqual(
            try Data(contentsOf: cacheFile),
            firstWrite,
            "A second commit inside the persistence window must not rewrite the file"
        )

        cache.flush()
        XCTAssertNotEqual(try Data(contentsOf: cacheFile), firstWrite)
        let reloaded = UsageHistoryRecordCache(file: cacheFile)
        let identity = try XCTUnwrap(UsageHistoryFileIdentity.of(file))
        XCTAssertEqual(reloaded.records(for: file, identity: identity)?.claude.count, 2)
    }
}
