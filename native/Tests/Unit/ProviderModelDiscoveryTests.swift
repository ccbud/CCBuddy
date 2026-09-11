import XCTest

@testable import CCBuddy

/// Sniffing `/v1/models` is a convention, not a contract: the parsing has to accept every shape
/// these endpoints are actually served in, and the availability answer has to distinguish "this
/// host has no listing endpoint" from "the request failed" — because only the first one should
/// grey the refresh control out.
final class ProviderModelDiscoveryTests: XCTestCase {
    func testCandidateOrderAvoidsAppendingASecondVersionSegment() {
        // A base URL that already carries a version is asked for /models first, because
        // appending another /v1 to it is exactly how `.../v1/v1/models` 404s get produced.
        XCTAssertEqual(
            ProviderModelDiscoveryService.candidateURLs(baseURL: "https://api.example.com/v1")
                .map(\.absoluteString),
            ["https://api.example.com/v1/models", "https://api.example.com/v1/v1/models"]
        )
        XCTAssertEqual(
            ProviderModelDiscoveryService.candidateURLs(baseURL: "https://api.example.com")
                .map(\.absoluteString),
            ["https://api.example.com/v1/models", "https://api.example.com/models"]
        )
        XCTAssertEqual(
            ProviderModelDiscoveryService.candidateURLs(baseURL: "https://api.example.com/")
                .map(\.absoluteString),
            ["https://api.example.com/v1/models", "https://api.example.com/models"]
        )
        for invalid in ["", "   ", "not a url", "ftp://api.example.com", "/relative/path"] {
            XCTAssertTrue(
                ProviderModelDiscoveryService.candidateURLs(baseURL: invalid).isEmpty, invalid
            )
        }
    }

    /// The catalog lives with the API whose models are being bound, not necessarily at the
    /// provider root: `https://api.kimi.com/coding/v1` lists models `https://api.kimi.com` does
    /// not. Both are tried, most specific first.
    func testListingLooksAtTheProtocolAddressBeforeTheProviderRoot() {
        let provider = Provider(
            baseUrl: "https://api.kimi.com",
            protocolUrls: ["anthropic": "https://api.kimi.com/coding/v1"],
            protocol: .anthropic
        )
        XCTAssertEqual(
            ProviderModelDiscoveryService.listingRoots(for: provider, wireProtocol: .anthropic),
            ["https://api.kimi.com/coding", "https://api.kimi.com"]
        )

        // An endpoint spelling resolves to the root that serves it, which is where /models lives.
        let deepSeek = Provider(
            baseUrl: "https://api.deepseek.com",
            protocolUrls: ["openai-chat": "https://api.deepseek.com/chat/completions"],
            protocol: .openAIChat
        )
        XCTAssertEqual(
            ProviderModelDiscoveryService.listingRoots(for: deepSeek, wireProtocol: .openAIChat),
            ["https://api.deepseek.com"],
            "the protocol address and the provider root collapse to one probe, not two"
        )

        // A provider saved before per-protocol addresses names one API through its base URL, and
        // the pair has to collapse: probed as two roots, the second contributes the
        // `…/v1/v1/models` spelling the candidate ordering exists to keep off the list.
        let legacy = Provider(baseUrl: "https://api.example.com/v1", protocol: .anthropic)
        let roots = ProviderModelDiscoveryService.listingRoots(
            for: legacy, wireProtocol: .anthropic
        )
        XCTAssertEqual(roots, ["https://api.example.com"])
        let probes = roots
            .flatMap { ProviderModelDiscoveryService.candidateURLs(baseURL: $0) }
            .map(\.absoluteString)
        XCTAssertEqual(
            probes,
            ["https://api.example.com/v1/models", "https://api.example.com/models"],
            "the address this provider has always used stays the first thing asked"
        )
        XCTAssertFalse(probes.contains { $0.contains("/v1/v1/") })
        XCTAssertTrue(
            ProviderModelDiscoveryService.listingRoots(for: Provider(), wireProtocol: .anthropic)
                .isEmpty
        )
    }

    func testEveryCatalogShapeTheseEndpointsAreServedInIsParsed() {
        let openAI = #"{"object":"list","data":[{"id":"gpt-5.4"},{"id":"gpt-5.4-mini"}]}"#
        XCTAssertEqual(
            ProviderModelDiscoveryService.parseModels(from: Data(openAI.utf8)),
            ["gpt-5.4", "gpt-5.4-mini"]
        )
        let anthropic = """
        {"data":[{"id":"claude-sonnet-5","type":"model","display_name":"Claude Sonnet 5"}],
         "has_more":false}
        """
        XCTAssertEqual(
            ProviderModelDiscoveryService.parseModels(from: Data(anthropic.utf8)),
            ["claude-sonnet-5"]
        )
        let selfHosted = #"{"models":[{"name":"llama-3.3"},{"name":"qwen-3"}]}"#
        XCTAssertEqual(
            ProviderModelDiscoveryService.parseModels(from: Data(selfHosted.utf8)),
            ["llama-3.3", "qwen-3"]
        )
        let bareArray = #"[{"id":"a"},{"model":"b"},"c"]"#
        XCTAssertEqual(
            ProviderModelDiscoveryService.parseModels(from: Data(bareArray.utf8)),
            ["a", "b", "c"]
        )
        // Order is the provider's; duplicates and blanks are dropped.
        let messy = #"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"id":"  "},{"unrelated":1}]}"#
        XCTAssertEqual(
            ProviderModelDiscoveryService.parseModels(from: Data(messy.utf8)), ["b", "a"]
        )
        for empty in ["{}", "[]", #"{"data":[]}"#, "not json", ""] {
            XCTAssertTrue(
                ProviderModelDiscoveryService.parseModels(from: Data(empty.utf8)).isEmpty, empty
            )
        }
    }

    func testMergingNeverDisturbsBindingsTheUserWrote() {
        let existing = [
            ModelMapping(alias: "fast", upstream: "gpt-5.4-mini"),
            ModelMapping(alias: "", upstream: ""),
        ]
        let merged = ProviderModelDiscoveryService.merging(
            discovered: ["gpt-5.4", "gpt-5.4-mini", "gpt-5.4", "*", "  "],
            into: existing
        )
        XCTAssertEqual(merged.map(\.alias), ["fast", "gpt-5.4"])
        XCTAssertEqual(merged.map(\.upstream), ["gpt-5.4-mini", "gpt-5.4"])
    }

    func testDiscoveredModelsBecomeIdentityBindings() {
        let merged = ProviderModelDiscoveryService.merging(
            discovered: ["a", "b"], into: []
        )
        XCTAssertEqual(merged.count, 2)
        for mapping in merged { XCTAssertEqual(mapping.alias, mapping.upstream) }
    }

    func testAnEmptyAddressIsReportedWithoutDisablingRefresh() async {
        let catalog = await ProviderModelDiscoveryService().discover(Provider())
        XCTAssertEqual(catalog.availability, .unknown)
        XCTAssertTrue(
            catalog.canRefresh,
            "an address the user has not finished typing is not proof the endpoint is missing"
        )
    }

    func testOnlyAnUnsupportedCatalogDisablesRefresh() {
        XCTAssertTrue(ProviderModelCatalog(availability: .unknown).canRefresh)
        XCTAssertTrue(ProviderModelCatalog(availability: .available).canRefresh)
        XCTAssertFalse(ProviderModelCatalog(availability: .unsupported).canRefresh)
    }
}
