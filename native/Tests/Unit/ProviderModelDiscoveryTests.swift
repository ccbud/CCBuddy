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
