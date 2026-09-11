import XCTest
@testable import CCBuddy

final class ProviderHeroUsageTests: XCTestCase {
    func testEditorPlaceholderIsARealCatalogRoot() throws {
        // The placeholder is the shape people copy when filling the field by hand. The field now
        // takes a bare root, so the placeholder has to be one a real vendor answers on rather than
        // one protocol's endpoint.
        XCTAssertTrue(
            ProviderPreset.all.contains { $0.baseURL == ProviderEditorLayout.apiURLPlaceholder },
            "placeholder \(ProviderEditorLayout.apiURLPlaceholder) is not any preset's root"
        )
        XCTAssertNotNil(
            GatewayUpstreamURL.derivedURL(
                for: .anthropic, base: ProviderEditorLayout.apiURLPlaceholder
            ),
            "the placeholder must be bare enough for the editor to derive addresses from"
        )
    }

    /// cc-switch stores the base URL a *client* appends `/v1/messages` to; this app stores the
    /// address the gateway is pointed at and resolves the rest. Porting the catalog verbatim would
    /// have shipped presets that each 404 until the user happened to press "test" and let the
    /// probe repair them.
    func testEveryAnthropicEndpointResolvesToASingleVersionedMessagesPath() throws {
        for preset in ProviderPreset.all {
            guard let address = preset.resolvedEndpoints[.anthropic], !address.isEmpty else {
                continue
            }
            let resolved = try XCTUnwrap(
                GatewayUpstreamURL.upstream(for: .anthropic, url: address).inferenceURL,
                preset.name
            )
            XCTAssertTrue(
                resolved.path.hasSuffix("/messages"),
                "\(preset.name) does not resolve to a Messages endpoint: \(resolved)"
            )
            let versions = resolved.path.split(separator: "/").filter {
                $0.first == "v" && $0.dropFirst().first?.isNumber == true
            }
            XCTAssertEqual(
                versions.count, 1,
                "\(preset.name) resolves to \(resolved), which is not versioned exactly once"
            )
        }
    }

    func testTheFirstPartyVendorsPeopleReachForAreStillInTheCatalog() throws {
        // Aggregators and resellers were dropped on purpose; the vendors running their own models
        // must all still be reachable, under whichever name the catalog uses for them.
        let required = [
            "https://open.bigmodel.cn/api/anthropic/v1",
            "https://api.deepseek.com/anthropic",
            "https://api.deepseek.com/chat/completions",
            "https://api.openai.com/v1/responses",
            "https://api.anthropic.com/v1",
            "https://generativelanguage.googleapis.com/v1beta/openai",
        ]
        let addresses = Set(ProviderPreset.all.flatMap { $0.resolvedEndpoints.values })
        for address in required {
            XCTAssertTrue(addresses.contains(address), "lost \(address) from the catalog")
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
