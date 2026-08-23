import Foundation

enum UsageHistoryServiceError: LocalizedError, Equatable, Sendable {
    case rootIsNotDirectory(String)
    case rootIsUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .rootIsNotDirectory(let path):
            return "用量目录不是文件夹：\(path)"
        case .rootIsUnreadable(let path):
            return "无法读取用量目录：\(path)"
        }
    }
}

enum UsageHistoryQuery {
    static let heatmapWeeks = 26

    static func summary(
        days: [String: UsageHistoryDay],
        range: UsageRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageHistorySummary {
        let keys = rangeKeys(days: days, range: range, now: now, calendar: calendar)
        var tokens = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var requests = 0
        var activeDays = 0
        var models: [String: Int] = [:]
        var providers: [String: Int] = [:]
        var hours: [Int: Int] = [:]

        for key in keys {
            guard let day = days[key] else { continue }
            tokens += day.tokens
            input += day.input
            output += day.output
            cacheRead += day.cacheRead
            cacheCreation += day.cacheCreation
            requests += day.requests
            if day.requests > 0 { activeDays += 1 }
            merge(day.models, into: &models)
            merge(day.providers, into: &providers)
            merge(day.hours, into: &hours)
        }

        let streak = streaks(days: days, now: now, calendar: calendar)
        return UsageHistorySummary(
            range: range,
            tokens: tokens,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            requests: requests,
            activeDays: activeDays,
            peakHour: topEntry(hours)?.key,
            favoriteModel: topEntry(models)?.key,
            favoriteProvider: topEntry(providers)?.key,
            byModel: shares(models, totalTokens: tokens),
            byProvider: shares(providers, totalTokens: tokens),
            currentStreak: streak.current,
            longestStreak: streak.longest,
            heatmap: heatmap(days: days, now: now, calendar: calendar)
        )
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    static func date(forDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func rangeKeys(
        days: [String: UsageHistoryDay],
        range: UsageRange,
        now: Date,
        calendar: Calendar
    ) -> [String] {
        let all = days.keys.sorted()
        guard range != .all else { return all }
        let count = switch range {
        case .oneDay: 1
        case .thirtyDays: 30
        case .sevenDays, .all: 7
        }
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(count - 1), to: today) else {
            return all
        }
        return all.filter { key in
            date(forDayKey: key, calendar: calendar).map { $0 >= cutoff } ?? false
        }
    }

    private static func streaks(
        days: [String: UsageHistoryDay],
        now: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        let active = Set(days.compactMap { key, day in
            day.requests > 0 ? date(forDayKey: key, calendar: calendar).map {
                calendar.startOfDay(for: $0)
            } : nil
        })
        let sorted = active.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for date in sorted {
            if let previous,
               calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }

        var cursor = calendar.startOfDay(for: now)
        if !active.contains(cursor),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var current = 0
        while active.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    private static func heatmap(
        days: [String: UsageHistoryDay],
        now: Date,
        calendar: Calendar
    ) -> [UsageHistoryHeatmapCell] {
        let today = calendar.startOfDay(for: now)
        let span = heatmapWeeks * 7
        guard var start = calendar.date(byAdding: .day, value: -(span - 1), to: today) else {
            return []
        }
        let daysFromSunday = calendar.component(.weekday, from: start) - 1
        if let aligned = calendar.date(byAdding: .day, value: -daysFromSunday, to: start) {
            start = aligned
        }

        var values: [(date: String, tokens: Int)] = []
        var maximum = 1
        var cursor = start
        while cursor <= today {
            let key = dayKey(for: cursor, calendar: calendar)
            let tokens = days[key]?.tokens ?? 0
            maximum = max(maximum, tokens)
            values.append((key, tokens))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return values.map { value in
            let ratio = Double(value.tokens) / Double(maximum)
            let level: Int
            if value.tokens == 0 { level = 0 }
            else if ratio > 0.66 { level = 4 }
            else if ratio > 0.33 { level = 3 }
            else if ratio > 0.10 { level = 2 }
            else { level = 1 }
            return UsageHistoryHeatmapCell(date: value.date, tokens: value.tokens, level: level)
        }
    }

    private static func shares(
        _ values: [String: Int],
        totalTokens: Int
    ) -> [UsageHistoryShare] {
        values.map { key, tokens in
            UsageHistoryShare(
                name: key,
                tokens: tokens,
                percentage: totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0
            )
        }.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func topEntry<Key: Comparable>(_ values: [Key: Int]) -> (key: Key, value: Int)? {
        values.map { (key: $0.key, value: $0.value) }.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.first
    }

    private static func merge<Key: Hashable>(_ values: [Key: Int], into output: inout [Key: Int]) {
        for (key, value) in values { output[key, default: 0] += value }
    }
}

/// Cached asynchronous facade for consumers such as ProviderHero and the menu-bar popover.
/// Scanning stays off the main actor, and explicit invalidation lets the existing history watcher
/// decide when disk state changed.
actor UsageHistoryService {
    private struct InFlight {
        let id: UUID
        let signature: String
        let generation: Int
        let task: Task<[String: UsageHistoryDay], Error>
    }

    private let scanner: any UsageHistoryScanning
    private let calendar: Calendar
    private var cachedSignature: String?
    private var cachedDays: [String: UsageHistoryDay] = [:]
    private var generation = 0
    private var inFlight: InFlight?
    private var draining: InFlight?

    init(
        calendar: Calendar = .current,
        scanner: (any UsageHistoryScanning)? = nil
    ) {
        self.calendar = calendar
        self.scanner = scanner ?? UsageHistoryScanner(calendar: calendar)
    }

    func summary(
        configuration: UsageHistoryConfiguration,
        range: UsageRange,
        now: Date = Date()
    ) async throws -> UsageHistorySummary {
        let days = try await data(configuration: configuration)
        return UsageHistoryQuery.summary(days: days, range: range, now: now, calendar: calendar)
    }

    func summaries(
        configuration: UsageHistoryConfiguration,
        ranges: [UsageRange],
        now: Date = Date()
    ) async throws -> [UsageRange: UsageHistorySummary] {
        let days = try await data(configuration: configuration)
        return Dictionary(uniqueKeysWithValues: ranges.map { range in
            (range, UsageHistoryQuery.summary(days: days, range: range, now: now, calendar: calendar))
        })
    }

    func warm(configuration: UsageHistoryConfiguration) async throws {
        _ = try await data(configuration: configuration)
    }

    func invalidate() async {
        generation += 1
        cachedSignature = nil
        cachedDays = [:]
        if let inFlight {
            inFlight.task.cancel()
            draining = inFlight
        }
        inFlight = nil
        if let draining {
            _ = try? await draining.task.value
            if self.draining?.id == draining.id { self.draining = nil }
        }
    }

    private func data(
        configuration: UsageHistoryConfiguration
    ) async throws -> [String: UsageHistoryDay] {
        if let draining {
            _ = try? await draining.task.value
            if self.draining?.id == draining.id { self.draining = nil }
        }
        try Task.checkCancellation()
        let signature = configuration.cacheSignature
        if cachedSignature == signature { return cachedDays }

        if let inFlight,
           inFlight.signature == signature,
           inFlight.generation == generation {
            return try await inFlight.task.value
        }

        let scanGeneration = generation
        let scanner = self.scanner
        let roots = configuration.activeRoots
        let task = Task.detached(priority: .utility) { () throws -> [String: UsageHistoryDay] in
            try Self.validate(roots: roots)
            try Task.checkCancellation()
            return scanner.scan(configuration: configuration)
        }
        let id = UUID()
        inFlight = InFlight(
            id: id,
            signature: signature,
            generation: scanGeneration,
            task: task
        )

        let scanned: [String: UsageHistoryDay]
        do {
            scanned = try await task.value
        } catch {
            if inFlight?.id == id { inFlight = nil }
            throw error
        }
        if inFlight?.id == id { inFlight = nil }
        if generation == scanGeneration {
            cachedSignature = signature
            cachedDays = scanned
        }
        return scanned
    }

    private static func validate(roots: [URL]) throws {
        let fileManager = FileManager()
        var hasUsableSource = roots.isEmpty
        var firstError: UsageHistoryServiceError?
        for root in roots {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                // A configured CLI may not have created its history directory yet. That is a
                // legitimate empty source rather than a scan failure.
                hasUsableSource = true
                continue
            }
            guard isDirectory.boolValue else {
                if firstError == nil { firstError = .rootIsNotDirectory(root.path) }
                continue
            }
            guard fileManager.isReadableFile(atPath: root.path) else {
                if firstError == nil { firstError = .rootIsUnreadable(root.path) }
                continue
            }
            hasUsableSource = true
        }
        if !hasUsableSource, let firstError { throw firstError }
    }
}
