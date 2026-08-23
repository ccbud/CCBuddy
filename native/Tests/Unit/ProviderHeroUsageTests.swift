import XCTest
@testable import CCBuddy

final class ProviderHeroUsageTests: XCTestCase {
    func testProviderEditorParityMetricsMatchLegacySheet() throws {
        XCTAssertEqual(ProviderEditorLayout.sheetSize, CGSize(width: 580, height: 654))
        let glm = try XCTUnwrap(ProviderPreset.all.first { $0.id == "glm" })
        XCTAssertEqual(ProviderEditorLayout.apiURLPlaceholder, glm.baseURL)
    }

    func testCompleteProviderPresetTableMatchesLegacyRendererContract() {
        let expected: [(
            id: String,
            title: String,
            name: String,
            baseURL: String,
            defaultModel: String,
            smallModel: String,
            wireProtocol: Provider.WireProtocol
        )] = [
            ("glm", "GLM", "GLM", "https://open.bigmodel.cn/api/anthropic/v1", "glm-5.2", "glm-5.2", .anthropic),
            ("deepseek", "DeepSeek", "DeepSeek", "https://api.deepseek.com/anthropic", "deepseek-v4-pro", "deepseek-v4-flash", .anthropic),
            ("mimo", "MiMo", "MiMo", "https://token-plan-sgp.xiaomimimo.com/anthropic", "mimo-v2.5-pro", "mimo-v2.5", .anthropic),
            ("kimi", "Kimi", "Kimi", "https://api.kimi.com/coding", "kimi-for-coding", "kimi-for-coding", .anthropic),
            ("minimax", "MiniMax", "MiniMax", "https://api.minimax.io/anthropic", "MiniMax-M3", "MiniMax-M3", .anthropic),
            ("nvidia", "NVIDIA", "NVIDIA", "https://integrate.api.nvidia.com/v1", "z-ai/glm-5.2", "z-ai/glm-5.2", .openAIChat),
            ("google", "Google AI Studio", "Google AI Studio", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.5-flash", "gemini-3.1-flash-lite", .openAIChat),
            ("openai", "OpenAI", "OpenAI", "https://api.openai.com/v1", "gpt-5.2", "gpt-5.2-mini", .openAIResponses),
            ("openrouter", "OpenRouter", "OpenRouter", "https://openrouter.ai/api/v1", "", "", .openAIChat),
            ("custom", "自定义", "", "", "", "", .anthropic),
        ]

        XCTAssertEqual(ProviderPreset.all.map(\.id), expected.map(\.id))
        for (preset, contract) in zip(ProviderPreset.all, expected) {
            XCTAssertEqual(preset.title, contract.title, contract.id)
            XCTAssertEqual(preset.name, contract.name, contract.id)
            XCTAssertEqual(preset.baseURL, contract.baseURL, contract.id)
            XCTAssertEqual(preset.defaultModel, contract.defaultModel, contract.id)
            XCTAssertEqual(preset.smallModel, contract.smallModel, contract.id)
            XCTAssertEqual(preset.wireProtocol, contract.wireProtocol, contract.id)
        }
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
