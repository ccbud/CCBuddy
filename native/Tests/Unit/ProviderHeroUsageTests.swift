import XCTest
@testable import CCBuddy

final class ProviderHeroUsageTests: XCTestCase {
    func testEditorPlaceholderIsARealCatalogEndpoint() throws {
        // The placeholder is the shape people copy when filling the field by hand, so it has to be a
        // live endpoint in the catalog rather than a URL that drifted out of date on its own.
        XCTAssertTrue(
            ProviderPreset.all.contains { $0.baseURL == ProviderEditorLayout.apiURLPlaceholder },
            "placeholder \(ProviderEditorLayout.apiURLPlaceholder) is not any preset's endpoint"
        )
    }

    /// cc-switch stores the base URL a *client* appends `/v1/messages` to; this app stores the base
    /// the gateway appends `/messages` to. Porting the catalog verbatim would have shipped seventy
    /// presets that each 404 until the user happened to press "test" and let the probe repair them.
    func testAnthropicEndpointsCarryTheVersionSegmentThisAppExpects() {
        for preset in ProviderPreset.all
        where preset.wireProtocol == .anthropic && !preset.baseURL.isEmpty {
            let segments = preset.baseURL.split(separator: "/").map(String.init)
            let last = try? XCTUnwrap(segments.last)
            XCTAssertTrue(
                (last?.first == "v") && (last?.dropFirst().first?.isNumber == true),
                "\(preset.name) endpoint is missing its version segment: \(preset.baseURL)"
            )
        }
    }

    func testTheProvidersTheHandWrittenListCoveredSurvivedThePort() throws {
        // Every vendor the old ten-entry table reached must still be reachable, under whichever name
        // the upstream catalog uses for it.
        let required = [
            "https://open.bigmodel.cn/api/anthropic/v1",
            "https://api.deepseek.com/anthropic/v1",
            "https://api.openai.com/v1",
            "https://openrouter.ai/api/v1",
            "https://integrate.api.nvidia.com/v1",
            "https://generativelanguage.googleapis.com/v1beta/openai",
        ]
        let endpoints = Set(ProviderPreset.all.map(\.baseURL))
        for endpoint in required {
            XCTAssertTrue(endpoints.contains(endpoint), "lost \(endpoint) in the catalog port")
        }
        XCTAssertTrue(ProviderPreset.all.contains { $0.name.localizedCaseInsensitiveContains("kimi") })
        XCTAssertTrue(ProviderPreset.all.contains { $0.name.localizedCaseInsensitiveContains("minimax") })
        XCTAssertTrue(ProviderPreset.all.contains { $0.name.localizedCaseInsensitiveContains("mimo") })
    }

    func testFallbackIconHashMatchesLegacyRenderer() {
        XCTAssertEqual(ProviderIconView.legacyHue(for: "Demo"), 179)
        XCTAssertEqual(
            ProviderIconView.emojis[ProviderIconView.legacyHue(for: "Demo") % ProviderIconView.emojis.count],
            "❄️"
        )
        XCTAssertEqual(ProviderIconView.legacyHue(for: "GLM"), 104)
    }

    func testSparkUsesHistoryHeatmapSuffixForEachHeroRange() {
        let heatmap = (1...100).map {
            UsageHistoryHeatmapCell(date: "day-\($0)", tokens: $0, level: 1)
        }
        let summary = makeSummary(heatmap: heatmap)

        XCTAssertEqual(
            ProviderHeroUsage.sparkValues(summary: summary, range: .sevenDays),
            Array(94...100)
        )
        XCTAssertEqual(
            ProviderHeroUsage.sparkValues(summary: summary, range: .thirtyDays),
            Array(71...100)
        )
        XCTAssertEqual(
            ProviderHeroUsage.sparkValues(summary: summary, range: .all),
            Array(11...100)
        )
    }

    func testSparkKeepsAvailableHistoryWhenHeatmapIsShort() {
        let heatmap = [
            UsageHistoryHeatmapCell(date: "a", tokens: 3, level: 1),
            UsageHistoryHeatmapCell(date: "b", tokens: 7, level: 2),
        ]

        XCTAssertEqual(
            ProviderHeroUsage.sparkValues(summary: makeSummary(heatmap: heatmap), range: .all),
            [3, 7]
        )
    }

    private func makeSummary(heatmap: [UsageHistoryHeatmapCell]) -> UsageHistorySummary {
        UsageHistorySummary(
            range: .all,
            tokens: heatmap.reduce(0) { $0 + $1.tokens },
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            requests: heatmap.count,
            activeDays: heatmap.count,
            peakHour: nil,
            favoriteModel: nil,
            favoriteProvider: nil,
            byModel: [],
            byProvider: [],
            currentStreak: 0,
            longestStreak: 0,
            heatmap: heatmap
        )
    }
}
