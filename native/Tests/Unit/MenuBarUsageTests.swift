import XCTest
@testable import CCBuddy

final class MenuBarUsageTests: XCTestCase {
    func testRangesUseOnlyDatedRequestsInMonitorBuffer() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let logs = [
            makeLog(id: "recent", date: now.addingTimeInterval(-12 * 60 * 60), status: .error,
                    model: "model-a", provider: "provider-a", prompt: 40, completion: 20, total: 100),
            makeLog(id: "week", date: now.addingTimeInterval(-6 * 24 * 60 * 60), status: .success,
                    model: "model-b", provider: "provider-b", prompt: 10, completion: 5),
            makeLog(id: "old", date: now.addingTimeInterval(-8 * 24 * 60 * 60), status: .success,
                    model: "model-c", provider: "provider-c", prompt: 30, completion: 20),
            makeLog(id: "undated", date: nil, status: .success,
                    model: "model-d", provider: "provider-d", prompt: 20, completion: 10),
        ]

        let oneDay = UsageAggregator.aggregate(logs: logs, range: .oneDay, now: now)
        XCTAssertEqual(oneDay.requestCount, 1)
        XCTAssertEqual(oneDay.totalTokens, 100)
        XCTAssertEqual(oneDay.promptTokens, 40)
        XCTAssertEqual(oneDay.completionTokens, 20)
        XCTAssertEqual(oneDay.successRate, 0)
        XCTAssertEqual(oneDay.models.map(\.model), ["model-a"])
        XCTAssertEqual(oneDay.coverage, .monitorBuffer(included: 1, available: 4, undatedExcluded: 1))

        let sevenDays = UsageAggregator.aggregate(logs: logs, range: .sevenDays, now: now)
        XCTAssertEqual(sevenDays.requestCount, 2)
        XCTAssertEqual(sevenDays.totalTokens, 115)
        XCTAssertEqual(sevenDays.successRate, 50)
        XCTAssertEqual(sevenDays.models.map(\.model), ["model-a", "model-b"])
    }

    func testAllRangeUsesBifrostStatsWithoutFabricatingModelTotals() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let logs = [
            makeLog(id: "one", date: now, status: .success, model: "cached-model", provider: "provider",
                    prompt: 7, completion: 3),
        ]
        let stats = BifrostLogStats(
            totalRequests: 432,
            totalTokens: 9_876,
            promptTokens: 7_000,
            completionTokens: 2_876,
            totalCost: 1.25,
            successRate: 98.5
        )

        let snapshot = UsageAggregator.aggregate(logs: logs, range: .all, now: now, allTimeStats: stats)

        XCTAssertEqual(snapshot.requestCount, 432)
        XCTAssertEqual(snapshot.totalTokens, 9_876)
        XCTAssertEqual(snapshot.promptTokens, 7_000)
        XCTAssertEqual(snapshot.completionTokens, 2_876)
        XCTAssertEqual(snapshot.totalCost, 1.25)
        XCTAssertEqual(snapshot.successRate, 98.5)
        XCTAssertEqual(snapshot.models, [
            UsageModelSummary(model: "cached-model", provider: "provider", requestCount: 1, totalTokens: 10),
        ])
        XCTAssertEqual(snapshot.coverage, .bifrostAllTime(cachedModelRequestCount: 1))
    }

    func testCompactTokenFormattingIsStable() {
        XCTAssertEqual(UsageFormat.compactTokens(999), "999")
        XCTAssertEqual(UsageFormat.compactTokens(1_000), "1K")
        XCTAssertEqual(UsageFormat.compactTokens(9_500), "9.5K")
        XCTAssertEqual(UsageFormat.compactTokens(12_500), "13K")
        XCTAssertEqual(UsageFormat.compactTokens(1_250_000), "1.3M")
        XCTAssertEqual(UsageFormat.compactTokens(12_500_000), "13M")
        XCTAssertEqual(UsageFormat.compactTrayTokens(12_500), "12K")
        XCTAssertEqual(UsageFormat.compactTrayTokens(1_250_000), "1.2M")
    }

    func testStatusTitleDistinguishesLoadingFailureEmptyAndLoadedHistory() {
        XCTAssertEqual(
            MenuBarUsageTitlePresenter.presentation(
                enabled: false,
                range: .sevenDays,
                state: .idle,
                summary: nil
            ),
            .init(title: "", accessibilityValue: "仅图标")
        )
        XCTAssertEqual(
            MenuBarUsageTitlePresenter.presentation(
                enabled: true,
                range: .sevenDays,
                state: .loading,
                summary: nil
            ),
            .init(title: " …", accessibilityValue: "历史用量加载中")
        )
        XCTAssertEqual(
            MenuBarUsageTitlePresenter.presentation(
                enabled: true,
                range: .sevenDays,
                state: .failed("denied"),
                summary: nil
            ),
            .init(title: " —", accessibilityValue: "历史用量读取失败")
        )

        let empty = summary(tokens: 0)
        XCTAssertEqual(
            MenuBarUsageTitlePresenter.presentation(
                enabled: true,
                range: .sevenDays,
                state: .loaded,
                summary: empty
            ).title,
            " 0",
            "A successful empty scan is distinct from loading or failure"
        )
        XCTAssertEqual(
            MenuBarUsageTitlePresenter.presentation(
                enabled: true,
                range: .all,
                state: .loaded,
                summary: summary(tokens: 12_500)
            ),
            .init(title: " 12K", accessibilityValue: "全部 12500 Tokens")
        )
    }

    func testStatusAccessibilityUsesConfiguredLanguageForEveryState() {
        let expectations: [(
            language: AppLanguage,
            iconOnly: String,
            loading: String,
            failed: String,
            loaded: String
        )] = [
            (.english, "Icon only", "Loading usage history", "Failed to load usage history",
             "7 days 12500 tokens"),
            (.simplifiedChinese, "仅图标", "历史用量加载中", "历史用量读取失败",
             "7天 12500 Tokens"),
            (.traditionalChinese, "僅顯示圖示", "正在載入歷史用量", "歷史用量讀取失敗",
             "7 天 12500 Tokens"),
            (.japanese, "アイコンのみ", "使用量履歴を読み込み中", "使用量履歴の読み込みに失敗しました",
             "7日 12500 トークン"),
            (.korean, "아이콘만", "사용량 기록 불러오는 중", "사용량 기록을 불러오지 못했습니다",
             "7일 토큰 12500개"),
        ]

        for expected in expectations {
            XCTAssertEqual(
                MenuBarStatusLocalization.accessibilityValue(
                    enabled: false,
                    range: .sevenDays,
                    state: .idle,
                    summary: nil,
                    language: expected.language
                ),
                expected.iconOnly
            )
            XCTAssertEqual(
                MenuBarStatusLocalization.accessibilityValue(
                    enabled: true,
                    range: .sevenDays,
                    state: .loading,
                    summary: nil,
                    language: expected.language
                ),
                expected.loading
            )
            XCTAssertEqual(
                MenuBarStatusLocalization.accessibilityValue(
                    enabled: true,
                    range: .sevenDays,
                    state: .failed("backend detail"),
                    summary: nil,
                    language: expected.language
                ),
                expected.failed
            )
            XCTAssertEqual(
                MenuBarStatusLocalization.accessibilityValue(
                    enabled: true,
                    range: .sevenDays,
                    state: .loaded,
                    summary: summary(tokens: 12_500),
                    language: expected.language
                ),
                expected.loaded
            )
        }
    }

    func testMenuBarRuntimeTemplatesLocalizeTextAndPreserveBackendValues() {
        let provider = "Provider/原样-そのまま-그대로"
        let model = "model/原样-そのまま-그대로"

        XCTAssertEqual(
            AppLanguage.english.localized("网关运行中 · \(provider)"),
            "Gateway running · \(provider)"
        )
        XCTAssertEqual(
            AppLanguage.japanese.localized("\(model)，12500 Tokens"),
            "\(model)、12500 トークン"
        )
        XCTAssertEqual(
            AppLanguage.korean.localized("2026-08-22 · 12500 Tokens"),
            "2026-08-22 · 토큰 12500개"
        )
        XCTAssertEqual(
            AppLanguage.traditionalChinese.localized("4 个活跃日，12500 Tokens"),
            "4 個活躍日，12500 Tokens"
        )
        XCTAssertEqual(AppLanguage.english.localized("3 天"), "3 days")
    }

    private func summary(tokens: Int) -> UsageHistorySummary {
        UsageHistorySummary(
            range: .all,
            tokens: tokens,
            input: tokens,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            requests: tokens == 0 ? 0 : 1,
            activeDays: tokens == 0 ? 0 : 1,
            peakHour: nil,
            favoriteModel: nil,
            favoriteProvider: nil,
            byModel: [],
            byProvider: [],
            currentStreak: 0,
            longestStreak: 0,
            heatmap: []
        )
    }

    private func makeLog(
        id: String,
        date: Date?,
        status: BifrostLogStatus,
        model: String,
        provider: String,
        prompt: Int,
        completion: Int,
        total: Int? = nil
    ) -> BifrostLog {
        BifrostLog(
            id: id,
            provider: provider,
            model: model,
            timestamp: date,
            status: status,
            tokenUsage: BifrostTokenUsage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total
            )
        )
    }
}
