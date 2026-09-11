import XCTest

@testable import CCBuddy

/// One character of path decided whether the gateway worked at all.
///
/// Bifrost builds the whole upstream path and inserts its own `/v1`. Every provider preset ships
/// the base URL its vendor documents, and those already end where the vendor's version segment
/// begins. Handed over untouched, that produced `…/v1/v1/messages`, which every upstream answers
/// with 404 — for seventy-one of the seventy-two presets. The connection test did not catch it,
/// because it computed its own URL and happened to compute the right one.
final class GatewayUpstreamURLTests: XCTestCase {
    func testABaseEndingInTheSegmentBifrostAddsIsClassifiedAsSuch() {
        for base in [
            "https://api.anthropic.com/v1",
            "https://api.moonshot.cn/anthropic/v1",
            "https://api.aicodemirror.ai/api/claudecode/v1",
            "https://host/v1/",
            "https://host/v1//",
        ] {
            XCTAssertEqual(GatewayUpstreamURL.versioning(of: base), .trailingV1, base)
        }
        for base in [
            "https://open.bigmodel.cn/api/paas/v4",
            "https://generativelanguage.googleapis.com/v1beta/openai",
            "https://host/v2alpha/chat",
        ] {
            XCTAssertEqual(GatewayUpstreamURL.versioning(of: base), .foreign, base)
        }
        for base in [
            "https://open.bigmodel.cn/api/anthropic",
            "https://api.anthropic.com",
            "https://host",
            "",
        ] {
            XCTAssertEqual(GatewayUpstreamURL.versioning(of: base), Optional(.none), base)
        }
    }

    /// Dropping the trailing segment is the complete fix for this shape: Bifrost puts it back on
    /// every endpoint, including the Responses routes whose path carries a response id.
    func testATrailingVersionSegmentIsRemovedBecauseBifrostRestoresIt() {
        XCTAssertEqual(
            GatewayUpstreamURL.bifrostBaseURL(for: "https://api.anthropic.com/v1"),
            "https://api.anthropic.com"
        )
        XCTAssertEqual(
            GatewayUpstreamURL.bifrostBaseURL(for: "https://api.moonshot.cn/anthropic/v1/"),
            "https://api.moonshot.cn/anthropic"
        )
        // Anything else is preserved exactly as the user typed it.
        XCTAssertEqual(
            GatewayUpstreamURL.bifrostBaseURL(for: "https://open.bigmodel.cn/api/anthropic"),
            "https://open.bigmodel.cn/api/anthropic"
        )
        XCTAssertEqual(
            GatewayUpstreamURL.bifrostBaseURL(for: "https://open.bigmodel.cn/api/paas/v4"),
            "https://open.bigmodel.cn/api/paas/v4"
        )
    }

    func testOverridesAreEmittedOnlyForAVersionBifrostCannotReproduce() {
        XCTAssertTrue(
            GatewayUpstreamURL.requestPathOverrides(
                for: .anthropic, baseURL: "https://api.anthropic.com/v1"
            ).isEmpty,
            "a trailing /v1 is handled by shortening the base instead"
        )
        XCTAssertTrue(
            GatewayUpstreamURL.requestPathOverrides(
                for: .anthropic, baseURL: "https://open.bigmodel.cn/api/anthropic"
            ).isEmpty
        )
        let google = GatewayUpstreamURL.requestPathOverrides(
            for: .openAIChat,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
        )
        XCTAssertEqual(google["chat_completion"], "/chat/completions")
        XCTAssertEqual(google["chat_completion_stream"], "/chat/completions")
        XCTAssertEqual(google["list_models"], "/models")
        let glm = GatewayUpstreamURL.requestPathOverrides(
            for: .anthropic, baseURL: "https://open.bigmodel.cn/api/paas/v4"
        )
        XCTAssertEqual(glm["chat_completion"], "/messages")
        XCTAssertEqual(glm["count_tokens"], "/messages/count_tokens")
    }

    /// The regression itself: whatever the base URL's shape, the version segment must appear
    /// exactly once in the URL the upstream is asked for.
    func testTheVersionSegmentAppearsExactlyOnceForEveryBaseShape() {
        let cases: [(String, Provider.WireProtocol, String)] = [
            ("https://api.anthropic.com/v1", .anthropic, "https://api.anthropic.com/v1/messages"),
            ("https://api.anthropic.com", .anthropic, "https://api.anthropic.com/v1/messages"),
            (
                "https://api.moonshot.cn/anthropic/v1", .anthropic,
                "https://api.moonshot.cn/anthropic/v1/messages"
            ),
            (
                "https://open.bigmodel.cn/api/anthropic", .anthropic,
                "https://open.bigmodel.cn/api/anthropic/v1/messages"
            ),
            ("https://api.openai.com/v1", .openAIChat, "https://api.openai.com/v1/chat/completions"),
            (
                "https://generativelanguage.googleapis.com/v1beta/openai", .openAIChat,
                "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
            ),
            ("https://api.openai.com/v1", .openAIResponses, "https://api.openai.com/v1/responses"),
        ]
        for (base, wireProtocol, expected) in cases {
            XCTAssertEqual(
                GatewayUpstreamURL.endpointURL(baseURL: base, wireProtocol: wireProtocol)?
                    .absoluteString,
                expected,
                base
            )
        }
    }

    /// What the generated configuration and the connection test each resolve to must be the same
    /// URL. They disagreeing is how a provider could test healthy and then answer every real
    /// request with 404.
    func testEveryShippedPresetResolvesIdenticallyForTheGatewayAndTheProbe() {
        let presets = ProviderPreset.all.filter { !$0.baseURL.isEmpty }
        XCTAssertGreaterThan(presets.count, 60, "the catalog should not have quietly emptied")
        for preset in presets {
            let bifrostBase = GatewayUpstreamURL.bifrostBaseURL(for: preset.baseURL)
            let overrides = GatewayUpstreamURL.requestPathOverrides(
                for: preset.wireProtocol, baseURL: preset.baseURL
            )
            let defaultPath: String
            let overrideKey: String
            switch preset.wireProtocol {
            case .anthropic:
                defaultPath = "/v1/messages"
                overrideKey = "chat_completion"
            case .openAIChat:
                defaultPath = "/v1/chat/completions"
                overrideKey = "chat_completion"
            case .openAIResponses:
                defaultPath = "/v1/responses"
                overrideKey = "responses"
            }
            let gateway = bifrostBase + (overrides[overrideKey] ?? defaultPath)
            let probe = GatewayUpstreamURL.endpointURL(
                baseURL: preset.baseURL, wireProtocol: preset.wireProtocol
            )?.absoluteString
            XCTAssertEqual(gateway, probe, preset.name)
            XCTAssertFalse(
                gateway.contains("/v1/v1/"),
                "\(preset.name) would ask \(preset.baseURL) for a doubled version segment"
            )
        }
    }

    func testAnEmptyOrSchemeOnlyBaseIsNotMangled() {
        XCTAssertNil(GatewayUpstreamURL.endpointURL(baseURL: "", wireProtocol: .anthropic))
        XCTAssertNil(GatewayUpstreamURL.endpointURL(baseURL: "   ", wireProtocol: .anthropic))
        XCTAssertEqual(GatewayUpstreamURL.bifrostBaseURL(for: ""), "")
    }
}
