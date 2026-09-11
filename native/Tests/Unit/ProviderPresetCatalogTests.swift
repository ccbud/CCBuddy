import XCTest

@testable import CCBuddy

/// The catalog is generated data, which is exactly the kind of thing that rots quietly: a duplicate
/// id silently shadows an entry in the picker, a bare `http://` endpoint would send API keys in the
/// clear, and a leftover referral parameter would attribute this app's users to another project.
final class ProviderPresetCatalogTests: XCTestCase {
    func testIdentifiersAreUnique() {
        let identifiers = ProviderPreset.all.map(\.id)
        XCTAssertEqual(
            Set(identifiers).count,
            identifiers.count,
            "duplicate ids make one preset unreachable in the picker"
        )
    }

    func testEveryEndpointIsHTTPS() {
        for preset in ProviderPreset.all where !preset.baseURL.isEmpty {
            XCTAssertTrue(
                preset.baseURL.hasPrefix("https://"),
                "\(preset.name) would carry its API key over plaintext: \(preset.baseURL)"
            )
            for (wireProtocol, endpoint) in preset.resolvedEndpoints {
                XCTAssertTrue(
                    endpoint.hasPrefix("https://"),
                    "\(preset.name) \(wireProtocol.rawValue): \(endpoint)"
                )
            }
        }
    }

    /// The base URL is the root the editor derives from and discovery falls back to, so it must
    /// not itself be one protocol's endpoint — that is what the per-protocol addresses are for.
    func testBaseURLsCarryNoProtocolSpecificPath() {
        for preset in ProviderPreset.all where !preset.baseURL.isEmpty {
            for suffix in ["/messages", "/chat/completions", "/responses", "/anthropic"] {
                XCTAssertFalse(
                    preset.baseURL.hasSuffix(suffix),
                    "\(preset.name) put a protocol path in its base URL: \(preset.baseURL)"
                )
            }
        }
    }

    /// Every preset names the endpoint that also takes the callers it publishes nothing for.
    func testThePrimaryProtocolIsAlwaysOneOfTheBoundEndpoints() {
        for preset in ProviderPreset.all where !preset.baseURL.isEmpty {
            XCTAssertNotNil(
                preset.resolvedEndpoints[preset.wireProtocol],
                "\(preset.name) would convert every caller onto an address it does not bind"
            )
        }
    }

    /// Applying a preset is what puts a provider into the "three of three" or "one of three"
    /// state the gateway routes on, so the addresses have to survive the copy.
    func testApplyingAPresetBindsEveryEndpointItPublishes() throws {
        let deepSeek = try XCTUnwrap(ProviderPreset.all.first { $0.id == "deepseek" })
        var draft = Provider(
            baseUrl: "https://old", protocolUrls: ["openai-responses": "https://old/responses"]
        )
        deepSeek.apply(to: &draft)

        XCTAssertEqual(draft.baseUrl, "https://api.deepseek.com")
        XCTAssertEqual(
            draft.upstreamURL(for: .anthropic), "https://api.deepseek.com/anthropic"
        )
        XCTAssertEqual(
            draft.upstreamURL(for: .openAIChat), "https://api.deepseek.com/chat/completions"
        )
        XCTAssertNil(
            draft.upstreamURL(for: .openAIResponses),
            "the previous provider's address must not survive into this one"
        )
        XCTAssertEqual(draft.configuredProtocols, [.anthropic, .openAIChat])
        XCTAssertFalse(draft.servesEveryProtocolDirectly)
    }

    func testWebsiteLinksCarryNoReferralParameters() {
        for preset in ProviderPreset.all {
            XCTAssertFalse(
                preset.website.contains("aff="),
                "\(preset.name) still carries an upstream referral parameter"
            )
        }
    }

    func testOnlyTheCustomEntryHasNoEndpoint() {
        let endpointless = ProviderPreset.all.filter(\.baseURL.isEmpty)
        XCTAssertEqual(endpointless.map(\.id), ["custom"])
    }

    func testCatalogListsOnlyFirstPartyVendors() {
        // Aggregators and resellers were dropped: their endpoints move, their protocol support is
        // whatever their own upstream exposes that week, and listing them implied vetting this
        // app cannot do. What is left is vendors serving their own models.
        XCTAssertGreaterThan(ProviderPreset.all.count, 15)
        XCTAssertEqual(Set(ProviderPreset.all.map(\.category)), [.official, .vendor, .custom])
        for removed in ["packycode", "openrouter", "aihubmix", "siliconflow", "dmxapi"] {
            XCTAssertNil(ProviderPreset.all.first { $0.id == removed }, removed)
        }
    }

    func testGroupingCoversEveryNonCustomPresetExactlyOnce() {
        let grouped = ProviderPreset.grouped(matching: "")
        let ids = grouped.flatMap { $0.presets }.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a preset must not appear in two groups")

        let expected = Set(ProviderPreset.all.filter { $0.category != .custom }.map(\.id))
        XCTAssertEqual(Set(ids), expected)
    }

    func testSearchMatchesName() {
        let hits = ProviderPreset.grouped(matching: "kimi").flatMap { $0.presets }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.matches("kimi") })
    }

    func testSearchAlsoMatchesHostAndModel() {
        // Looking a provider up by the endpoint you already have in a config file is the common case.
        let byHost = ProviderPreset.all.filter { $0.matches("moonshot") }
        XCTAssertFalse(byHost.isEmpty, "searching by host should find the vendor")

        let byModel = ProviderPreset.all.filter { $0.matches("kimi-for-coding") }
        XCTAssertFalse(byModel.isEmpty, "searching by model id should find the vendor")

        // The address people have in hand is often one protocol's endpoint, not the root.
        let byEndpoint = ProviderPreset.all.filter { $0.matches("api/paas/v4") }
        XCTAssertEqual(byEndpoint.map(\.id).sorted(), ["zhipu-glm", "zhipu-glm-en"])
    }

    func testEmptyQueryReturnsEveryGroup() {
        let groups = ProviderPreset.grouped(matching: "   ")
        XCTAssertEqual(groups.map(\.category), ProviderPreset.categoryOrder)
    }

    func testApplyingAPresetFillsTheDraftAndClearsAStaleIcon() {
        let preset = try? XCTUnwrap(ProviderPreset.all.first { $0.id == "kimi" })
        guard let preset else { return }

        var draft = Provider(name: "old", baseUrl: "https://old", icon: "stale")
        preset.apply(to: &draft)

        XCTAssertEqual(draft.name, preset.name)
        XCTAssertEqual(draft.baseUrl, preset.baseURL)
        XCTAssertEqual(draft.configuredUpstreamURLs, preset.resolvedEndpoints)
        XCTAssertEqual(draft.defaultModel, preset.defaultModel)
        XCTAssertEqual(draft.smallFastModel, preset.smallModel)
        XCTAssertEqual(draft.protocol, preset.wireProtocol)
        XCTAssertNil(draft.icon, "an icon chosen for the previous provider must not survive")
    }

    func testProtocolsAreOnesTheGatewayCanActuallySpeak() {
        // Presets requiring a wire format the gateway cannot translate are omitted rather than
        // shipped in a state where selecting them produces a provider that never works.
        let supported = Set(Provider.WireProtocol.allCases)
        for preset in ProviderPreset.all {
            XCTAssertTrue(supported.contains(preset.wireProtocol), preset.name)
        }
    }
}
