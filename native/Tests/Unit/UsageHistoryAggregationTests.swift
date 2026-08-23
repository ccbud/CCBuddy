import Foundation
import CoreServices
import XCTest
@testable import CCBuddy

final class UsageHistoryAggregationTests: XCTestCase {
    func testFavoriteModelAttributesUniqueConfiguredProvider() {
        let provider = Provider(
            id: "unique",
            name: "Unique",
            defaultModel: "default-model",
            smallFastModel: "fast-model",
            models: [.init(alias: "alias-model", upstream: "upstream-model")]
        )

        for model in ["default-model", "fast-model", "alias-model", "upstream-model"] {
            XCTAssertEqual(
                UsageHistoryProviderAttribution.providerName(
                    for: model,
                    providers: [provider],
                    activeProviderID: nil
                ),
                "Unique",
                model
            )
        }
    }

    func testFavoriteModelPrefersActiveMatchingProvider() {
        let providers = [
            Provider(id: "first", name: "First", defaultModel: "shared-model"),
            Provider(
                id: "active",
                name: "Active",
                models: [.init(alias: "alias", upstream: "shared-model")]
            ),
        ]

        XCTAssertEqual(
            UsageHistoryProviderAttribution.providerName(
                for: "shared-model",
                providers: providers,
                activeProviderID: "active"
            ),
            "Active"
        )
    }

    func testFavoriteModelLeavesAmbiguousProviderUnattributed() {
        let providers = [
            Provider(id: "first", name: "First", defaultModel: "shared-model"),
            Provider(id: "second", name: "Second", smallFastModel: "shared-model"),
        ]

        XCTAssertNil(UsageHistoryProviderAttribution.providerName(
            for: "shared-model",
            providers: providers,
            activeProviderID: "unmatched"
        ))
    }

    func testClaudeGlobalDedupLossyUTF8AndSyntheticModelSemantics() throws {
        let root = try temporaryDirectory("usage-claude")
        let project = root.appendingPathComponent("projects/-fixture", isDirectory: true)
        let subagents = project.appendingPathComponent("s1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        var main = Data()
        main.append(Self.claudeLine(id: "m1", request: "r1", model: "claude-x", timestamp: "2026-07-01T10:00:00Z", input: 100, output: 10))
        main.append(Self.claudeLine(id: "m1", request: "r1", model: "claude-x", timestamp: "2026-07-01T10:00:00Z", input: 100, output: 10))
        main.append(Data(#"{"garbage":""#.utf8))
        main.append(contentsOf: [0xFF, 0xFE])
        main.append(Data(#""}"#.utf8))
        main.append(0x0A)
        main.append(Self.claudeLine(id: "m1", request: "r2", model: "claude-x", timestamp: "2026-07-01T10:05:00Z", input: 50, output: 5))
        main.append(Self.claudeLine(id: "m1", request: "side", model: "claude-x", timestamp: "2026-07-01T10:00:01Z", input: 100, output: 10, sidechain: true))
        main.append(Self.claudeLine(id: "synthetic", request: "r3", model: "<synthetic>", timestamp: "2026-07-01T10:07:00Z", input: 5, output: 2))
        main.append(Self.claudeLine(id: "msg_ccbud", request: nil, model: "glm", timestamp: "2026-07-02T10:00:00Z", input: 20, output: 2))
        main.append(Self.claudeLine(id: "msg_ccbud", request: nil, model: "glm", timestamp: "2026-07-03T10:00:00Z", input: 30, output: 3))
        try main.write(to: project.appendingPathComponent("s1.jsonl"))

        let fast = #"{"timestamp":"2026-07-01T11:00:00Z","requestId":"r6","message":{"id":"m6","model":"claude-x","usage":{"input_tokens":3,"output_tokens":4,"speed":"fast","cache_read_input_tokens":6,"cache_creation_input_tokens":999,"cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":2}}}}"# + "\n"
        try Data(fast.utf8).write(to: subagents.appendingPathComponent("agent-a.jsonl"))

        let days = UsageHistoryScanner(calendar: Self.utcCalendar).scan(
            configuration: .init(
                historyDirs: [root.path],
                active: "__trash__",
                homeDirectory: root
            )
        )
        let summary = UsageHistoryQuery.summary(
            days: days,
            range: .all,
            now: Self.date("2026-07-04T12:00:00Z"),
            calendar: Self.utcCalendar
        )

        XCTAssertEqual(summary.requests, 6)
        XCTAssertEqual(summary.input, 208)
        XCTAssertEqual(summary.output, 26)
        XCTAssertEqual(summary.cacheRead, 6)
        XCTAssertEqual(summary.cacheCreation, 7)
        XCTAssertEqual(summary.tokens, 247)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: summary.byModel.map { ($0.name, $0.tokens) }), [
            "claude-x": 165,
            "claude-x-fast": 20,
            "glm": 55,
        ])
        XCTAssertNil(summary.byModel.first(where: { $0.name == "<synthetic>" }))
        XCTAssertEqual(days.count, 3, "Degenerate gateway ids must survive across days")
    }

    func testCodexCumulativeDiffResumeAndSubagentReplayDedup() throws {
        let root = try temporaryDirectory("usage-codex")
        let sessions = root.appendingPathComponent("sessions/2026/07/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let main = Self.jsonLine([
            "timestamp": "2026-07-01T12:00:01Z", "type": "turn_context",
            "payload": ["model": "gpt-5.5"],
        ])
            + Self.tokenLine("2026-07-01T12:00:02Z", last: (900, 600, 80), total: (900, 600, 80))
            + Self.tokenLine("2026-07-01T12:00:03Z", last: nil, total: (1400, 900, 130))
            + Self.tokenLine("2026-07-01T12:00:04Z", last: nil, total: nil)
        try Data(main.utf8).write(to: sessions.appendingPathComponent("rollout-a.jsonl"))

        let resumed = Self.jsonLine([
            "timestamp": "2026-07-01T12:10:00Z", "type": "turn_context",
            "payload": ["model": "gpt-5.5"],
        ])
            + Self.tokenLine("2026-07-01T12:00:02Z", last: (900, 600, 80), total: nil)
            + Self.tokenLine("2026-07-01T12:10:01Z", last: (10, 0, 5), total: nil)
        try Data(resumed.utf8).write(to: sessions.appendingPathComponent("rollout-b.jsonl"))

        let subagent = Self.jsonLine([
            "timestamp": "2026-07-01T13:00:00Z", "type": "session_meta",
            "payload": ["id": "sub", "source": ["type": "thread_spawn"]],
        ])
            + Self.tokenLine("2026-07-01T13:00:01Z", last: (900, 600, 80), total: (900, 600, 80))
            + Self.tokenLine("2026-07-01T13:00:01Z", last: (500, 300, 50), total: (1400, 900, 130))
            + Self.tokenLine("2026-07-01T13:00:05Z", last: nil, total: (1600, 900, 160))
        try Data(subagent.utf8).write(to: sessions.appendingPathComponent("rollout-sub.jsonl"))

        let archived = root.appendingPathComponent("archived_sessions/2026/07/01", isDirectory: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try Data(Self.tokenLine("2026-07-01T12:00:02Z", last: (9999, 0, 1), total: nil).utf8)
            .write(to: archived.appendingPathComponent("rollout-a.jsonl"))

        let days = UsageHistoryScanner(calendar: Self.utcCalendar).scan(
            configuration: .init(historyDirs: [root.path], homeDirectory: root)
        )
        let summary = UsageHistoryQuery.summary(
            days: days,
            range: .all,
            now: Self.date("2026-07-02T00:00:00Z"),
            calendar: Self.utcCalendar
        )

        XCTAssertEqual(summary.requests, 4)
        XCTAssertEqual(summary.input, 710)
        XCTAssertEqual(summary.cacheRead, 900)
        XCTAssertEqual(summary.output, 165)
        XCTAssertEqual(summary.tokens, 1_775)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: summary.byModel.map { ($0.name, $0.tokens) }), [
            "gpt-5.5": 1_545,
            "gpt-5": 230,
        ])
    }

    func testRangesHeatmapStreaksAndFavoritesUseLocalCalendarDays() {
        let days: [String: UsageHistoryDay] = [
            "2026-07-01": .init(
                tokens: 100, input: 80, output: 20, requests: 1,
                models: ["alpha": 100], providers: ["p1": 100], hours: [9: 100]
            ),
            "2026-07-02": .init(
                tokens: 200, input: 150, output: 50, requests: 2,
                models: ["beta": 200], providers: ["p2": 200], hours: [11: 200]
            ),
            "2026-07-04": .init(
                tokens: 400, input: 300, output: 100, requests: 1,
                models: ["alpha": 400], providers: ["p1": 400], hours: [14: 400]
            ),
        ]
        let now = Self.date("2026-07-04T12:00:00Z")
        let all = UsageHistoryQuery.summary(
            days: days, range: .all, now: now, calendar: Self.utcCalendar
        )
        let today = UsageHistoryQuery.summary(
            days: days, range: .oneDay, now: now, calendar: Self.utcCalendar
        )

        XCTAssertEqual(all.tokens, 700)
        XCTAssertEqual(all.requests, 4)
        XCTAssertEqual(all.activeDays, 3)
        XCTAssertEqual(all.favoriteModel, "alpha")
        XCTAssertEqual(all.favoriteProvider, "p1")
        XCTAssertEqual(all.peakHour, 14)
        XCTAssertEqual(all.currentStreak, 1)
        XCTAssertEqual(all.longestStreak, 2)
        XCTAssertEqual(all.byModel.first?.percentage ?? -1, 5.0 / 7.0, accuracy: 0.000_001)
        XCTAssertEqual(today.tokens, 400)
        XCTAssertEqual(today.requests, 1)

        XCTAssertEqual(all.heatmap.last, .init(date: "2026-07-04", tokens: 400, level: 4))
        XCTAssertEqual(all.heatmap.first(where: { $0.date == "2026-07-01" })?.level, 2)
        XCTAssertEqual(all.heatmap.first(where: { $0.date == "2026-07-02" })?.level, 3)
        XCTAssertTrue((182...188).contains(all.heatmap.count))
        let firstDate = UsageHistoryQuery.date(
            forDayKey: all.heatmap.first?.date ?? "",
            calendar: Self.utcCalendar
        )
        XCTAssertEqual(firstDate.map { Self.utcCalendar.component(.weekday, from: $0) }, 1)
    }

    func testServiceCachesUntilExplicitInvalidation() async throws {
        let root = try temporaryDirectory("usage-cache")
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try Self.claudeLine(
            id: "first",
            request: "r1",
            model: "claude-cache",
            timestamp: "2026-07-01T10:00:00Z",
            input: 2,
            output: 1
        ).write(to: file)

        let service = UsageHistoryService(calendar: Self.utcCalendar)
        let configuration = UsageHistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root
        )
        let first = try await service.summary(configuration: configuration, range: .all)
        XCTAssertEqual(first.tokens, 3)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.claudeLine(
            id: "second",
            request: "r2",
            model: "claude-cache",
            timestamp: "2026-07-01T10:01:00Z",
            input: 4,
            output: 2
        ))
        try handle.close()

        let cached = try await service.summary(configuration: configuration, range: .all)
        XCTAssertEqual(cached.tokens, 3)
        await service.invalidate()
        let refreshed = try await service.summary(configuration: configuration, range: .all)
        XCTAssertEqual(refreshed.tokens, 9)
    }

    func testServiceFailsClosedOnlyWhenNoConfiguredSourceIsUsable() async throws {
        let container = try temporaryDirectory("usage-failure")
        let invalid = container.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: invalid)
        let service = UsageHistoryService(calendar: Self.utcCalendar)

        do {
            _ = try await service.summary(
                configuration: .init(historyDirs: [invalid.path], homeDirectory: container),
                range: .all
            )
            XCTFail("Expected a non-directory root to fail instead of presenting a false zero")
        } catch {
            XCTAssertEqual(
                error as? UsageHistoryServiceError,
                .rootIsNotDirectory(invalid.standardizedFileURL.path)
            )
        }

        let valid = container.appendingPathComponent("valid", isDirectory: true)
        let project = valid.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Self.claudeLine(
            id: "partial",
            request: nil,
            model: "claude-partial",
            timestamp: "2026-07-01T10:00:00Z",
            input: 6,
            output: 1
        ).write(to: project.appendingPathComponent("session.jsonl"))
        await service.invalidate()
        let partial = try await service.summary(
            configuration: .init(
                historyDirs: [invalid.path, valid.path],
                homeDirectory: container
            ),
            range: .all
        )
        XCTAssertEqual(partial.tokens, 7)
    }

    func testCachedHistoryRequeriesRollingRangeAcrossMidnightWithoutDiskChanges() async throws {
        let root = try temporaryDirectory("usage-midnight")
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Self.claudeLine(
            id: "midnight",
            request: nil,
            model: "claude-midnight",
            timestamp: "2026-07-01T10:00:00Z",
            input: 8,
            output: 2
        ).write(to: project.appendingPathComponent("session.jsonl"))
        let service = UsageHistoryService(calendar: Self.utcCalendar)
        let configuration = UsageHistoryConfiguration(
            historyDirs: [root.path],
            homeDirectory: root
        )

        let before = try await service.summary(
            configuration: configuration,
            range: .oneDay,
            now: Self.date("2026-07-01T23:59:59Z")
        )
        let after = try await service.summary(
            configuration: configuration,
            range: .oneDay,
            now: Self.date("2026-07-02T00:00:01Z")
        )

        XCTAssertEqual(before.tokens, 10)
        XCTAssertEqual(after.tokens, 0)
    }

    func testWatcherClassifiesRootChangesAndRootIdentityDetectsAtomicReplacement() throws {
        XCTAssertFalse(UsageHistoryWatcher.rootsChanged(in: [
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified),
        ]))
        XCTAssertTrue(UsageHistoryWatcher.rootsChanged(in: [
            FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagRootChanged
            ),
        ]))

        let container = try temporaryDirectory("usage-root-replacement")
        let root = container.appendingPathComponent("history", isDirectory: true)
        let oldRoot = container.appendingPathComponent("history-old", isDirectory: true)
        let missing = UsageHistoryRootIdentity.signature(roots: [root])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = UsageHistoryRootIdentity.signature(roots: [root])
        XCTAssertNotEqual(original, missing)

        try FileManager.default.moveItem(at: root, to: oldRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacement = UsageHistoryRootIdentity.signature(roots: [root])
        XCTAssertNotEqual(replacement, original)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ value: String) -> Date {
        try! Date(value, strategy: Date.ISO8601FormatStyle())
    }

    private static func claudeLine(
        id: String,
        request: String?,
        model: String,
        timestamp: String,
        input: Int,
        output: Int,
        sidechain: Bool = false
    ) -> Data {
        var object: [String: Any] = [
            "timestamp": timestamp,
            "isSidechain": sidechain,
            "message": [
                "id": id,
                "model": model,
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
        if let request { object["requestId"] = request }
        return Data((jsonLine(object)).utf8)
    }

    private static func tokenLine(
        _ timestamp: String,
        last: (input: Int, cached: Int, output: Int)?,
        total: (input: Int, cached: Int, output: Int)?
    ) -> String {
        var info: [String: Any] = [:]
        if let last { info["last_token_usage"] = tokenObject(last) }
        if let total { info["total_token_usage"] = tokenObject(total) }
        return jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": ["type": "token_count", "info": info],
        ])
    }

    private static func tokenObject(
        _ value: (input: Int, cached: Int, output: Int)
    ) -> [String: Any] {
        [
            "input_tokens": value.input,
            "cached_input_tokens": value.cached,
            "output_tokens": value.output,
            "total_tokens": value.input + value.output,
        ]
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
