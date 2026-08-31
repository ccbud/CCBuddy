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
        }
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

    func testCatalogIsSubstantiallyLargerThanTheOldHandWrittenList() {
        // The hand-written list had ten entries and covered almost nothing people actually use.
        XCTAssertGreaterThan(ProviderPreset.all.count, 50)
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
