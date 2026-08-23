import Foundation

enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .oneDay: "今日"
        case .sevenDays: "7天"
        case .thirtyDays: "30天"
        case .all: "全部"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .all: nil
        }
    }

    func contains(_ date: Date?, now: Date) -> Bool {
        guard let interval else { return true }
        guard let date else { return false }
        return date >= now.addingTimeInterval(-interval) && date <= now
    }
}

struct UsageModelSummary: Identifiable, Equatable, Sendable {
    let model: String
    let provider: String
    let requestCount: Int
    let totalTokens: Int

    var id: String { "\(provider)\u{0}\(model)" }
}

struct UsageSnapshot: Equatable, Sendable {
    enum Coverage: Equatable, Sendable {
        /// Headline values are from Bifrost's dedicated aggregate endpoint. Bifrost does not
        /// expose an equivalent per-model aggregate, so model rows remain cache-scoped.
        case bifrostAllTime(cachedModelRequestCount: Int)
        /// Every value is derived from MonitorStore's bounded, currently loaded request buffer.
        case monitorBuffer(included: Int, available: Int, undatedExcluded: Int)
    }

    let range: UsageRange
    let totalTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    let requestCount: Int
    let successRate: Double?
    let totalCost: Double
    let models: [UsageModelSummary]
    let coverage: Coverage

    var coverageDescription: String {
        switch coverage {
        case .bifrostAllTime(let cachedModelRequestCount):
            return "总览来自 Bifrost 全库；模型仅基于当前缓存的 \(cachedModelRequestCount) 条。"
        case .monitorBuffer(let included, let available, let undatedExcluded):
            var value = "基于监控缓存中的 \(included)/\(available) 条；缓存最多 100 条。"
            if undatedExcluded > 0 { value += " \(undatedExcluded) 条无时间记录未计入。" }
            return value
        }
    }
}

enum UsageAggregator {
    static func aggregate(
        logs: [BifrostLog],
        range: UsageRange,
        now: Date = Date(),
        allTimeStats: BifrostLogStats? = nil
    ) -> UsageSnapshot {
        let filtered = logs.filter { range.contains($0.timestamp ?? $0.createdAt, now: now) }
        let excludedUndated = range == .all ? 0 : logs.reduce(into: 0) { count, log in
            if log.timestamp == nil && log.createdAt == nil { count += 1 }
        }

        var promptTokens = 0
        var completionTokens = 0
        var totalTokens = 0
        var totalCost = 0.0
        var terminalCount = 0
        var successCount = 0
        var modelBuckets: [String: ModelBucket] = [:]

        for log in filtered {
            let usage = resolvedUsage(log.tokenUsage)
            promptTokens += usage.prompt
            completionTokens += usage.completion
            totalTokens += usage.total
            if let cost = log.cost, cost.isFinite { totalCost += cost }

            if log.isTerminal {
                terminalCount += 1
                if log.isSuccess { successCount += 1 }
            }

            let model = nonempty(log.requestedModel, fallback: "未知模型")
            let provider = nonempty(log.displayProvider, fallback: "未知服务")
            let key = "\(provider)\u{0}\(model)"
            var bucket = modelBuckets[key] ?? ModelBucket(model: model, provider: provider)
            bucket.requestCount += 1
            bucket.totalTokens += usage.total
            modelBuckets[key] = bucket
        }

        let models = modelBuckets.values
            .map {
                UsageModelSummary(
                    model: $0.model,
                    provider: $0.provider,
                    requestCount: $0.requestCount,
                    totalTokens: $0.totalTokens
                )
            }
            .sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                if $0.requestCount != $1.requestCount { return $0.requestCount > $1.requestCount }
                if $0.model != $1.model { return $0.model.localizedStandardCompare($1.model) == .orderedAscending }
                return $0.provider.localizedStandardCompare($1.provider) == .orderedAscending
            }

        if range == .all, let stats = allTimeStats {
            return UsageSnapshot(
                range: range,
                totalTokens: max(0, stats.totalTokens),
                promptTokens: max(0, stats.promptTokens),
                completionTokens: max(0, stats.completionTokens),
                requestCount: max(0, stats.totalRequests),
                successRate: normalizedPercent(stats.successRate),
                totalCost: stats.totalCost.isFinite ? max(0, stats.totalCost) : 0,
                models: models,
                coverage: .bifrostAllTime(cachedModelRequestCount: filtered.count)
            )
        }

        return UsageSnapshot(
            range: range,
            totalTokens: max(0, totalTokens),
            promptTokens: max(0, promptTokens),
            completionTokens: max(0, completionTokens),
            requestCount: filtered.count,
            successRate: terminalCount > 0 ? Double(successCount) / Double(terminalCount) * 100 : nil,
            totalCost: max(0, totalCost),
            models: models,
            coverage: .monitorBuffer(
                included: filtered.count,
                available: logs.count,
                undatedExcluded: excludedUndated
            )
        )
    }

    private struct ModelBucket {
        let model: String
        let provider: String
        var requestCount = 0
        var totalTokens = 0
    }

    private static func resolvedUsage(_ usage: BifrostTokenUsage?) -> (prompt: Int, completion: Int, total: Int) {
        guard let usage else { return (0, 0, 0) }
        let prompt = max(0, usage.promptTokens ?? usage.inputTokens ?? 0)
        let completion = max(0, usage.completionTokens ?? usage.outputTokens ?? 0)
        let total = max(0, usage.totalTokens ?? (prompt + completion))
        return (prompt, completion, total)
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }
}

struct MenuBarUsageTitlePresentation: Equatable, Sendable {
    let title: String
    let accessibilityValue: String
}

enum MenuBarUsageTitlePresenter {
    static func presentation(
        enabled: Bool,
        range: UsageRange,
        state: UsageHistoryLoadState,
        summary: UsageHistorySummary?
    ) -> MenuBarUsageTitlePresentation {
        guard enabled else {
            return .init(title: "", accessibilityValue: "仅图标")
        }
        if case .failed = state {
            return .init(title: " —", accessibilityValue: "历史用量读取失败")
        }
        guard let summary else {
            return .init(title: " …", accessibilityValue: "历史用量加载中")
        }
        let rangeDescription = range == .all ? "全部" : range.shortLabel
        return .init(
            title: " \(UsageFormat.compactTrayTokens(summary.tokens))",
            accessibilityValue: "\(rangeDescription) \(summary.tokens) Tokens"
        )
    }
}

enum UsageFormat {
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func integer(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func compactTokens(_ value: Int) -> String {
        compactTokens(value, rendererRounding: true)
    }

    /// The legacy native tray formatter used Rust's ties-to-even formatting, while renderer
    /// surfaces used JavaScript `toFixed` (ties away from zero). Keep both so every surface
    /// preserves its prior boundary behavior.
    static func compactTrayTokens(_ value: Int) -> String {
        compactTokens(value, rendererRounding: false)
    }

    private static func compactTokens(_ value: Int, rendererRounding: Bool) -> String {
        let safeValue = max(0, value)
        if safeValue < 1_000 { return String(safeValue) }

        let threshold: Double
        let suffix: String
        let fractionDigits: Int
        switch safeValue {
        case ..<1_000_000:
            threshold = 1_000
            suffix = "K"
            fractionDigits = safeValue < 10_000 ? 1 : 0
        case ..<1_000_000_000:
            threshold = 1_000_000
            suffix = "M"
            fractionDigits = safeValue < 10_000_000 ? 1 : 0
        default:
            threshold = 1_000_000_000
            suffix = "B"
            fractionDigits = 1
        }
        var scaled = Double(safeValue) / threshold
        if rendererRounding {
            let factor = pow(10.0, Double(fractionDigits))
            scaled = (scaled * factor).rounded(.toNearestOrAwayFromZero) / factor
        }
        let formatted = String(format: "%.*f", fractionDigits, scaled)
        return formatted.replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
            + suffix
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", min(max(value, 0), 100))
    }

    static func cost(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value > 0, value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", max(0, value))
    }
}
