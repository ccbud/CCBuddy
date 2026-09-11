import XCTest

@testable import CCBuddy

/// One character of path decided whether the gateway worked at all.
///
/// Bifrost builds the whole upstream path and inserts its own `/v1`. Every provider preset ships
/// the addresses its vendor documents, and those already end where the vendor's version segment
/// begins. Handed over untouched, that produced `…/v1/v1/messages`, which every upstream answers
/// with 404 — for seventy-one of the seventy-two presets shipping at the time. The connection
/// test did not catch it, because it computed its own URL and happened to compute the right one.
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
    func testEveryShippedPresetEndpointResolvesIdenticallyForTheGatewayAndTheProbe() {
        let presets = ProviderPreset.all.filter { !$0.baseURL.isEmpty }
        XCTAssertGreaterThan(presets.count, 15, "the catalog should not have quietly emptied")
        for preset in presets {
            for (wireProtocol, address) in preset.resolvedEndpoints {
                let upstream = GatewayUpstreamURL.upstream(for: wireProtocol, url: address)
                let overrideKey = wireProtocol == .openAIResponses
                    ? "responses" : "chat_completion"
                let defaultPath: String
                switch wireProtocol {
                case .anthropic: defaultPath = "/v1/messages"
                case .openAIChat: defaultPath = "/v1/chat/completions"
                case .openAIResponses: defaultPath = "/v1/responses"
                }
                let gateway = upstream.baseURL
                    + (upstream.requestPathOverrides[overrideKey] ?? defaultPath)
                XCTAssertEqual(
                    gateway, upstream.inferenceURL?.absoluteString,
                    "\(preset.name) \(wireProtocol.rawValue)"
                )
                XCTAssertFalse(
                    gateway.contains("/v1/v1/"),
                    "\(preset.name) would ask \(address) for a doubled version segment"
                )
            }
        }
    }

    /// The address field takes whichever spelling the vendor's own documentation gives, and a
    /// vendor publishing `/chat/completions` need not also answer `/v1/chat/completions` — so an
    /// endpoint spelling is called exactly as typed rather than rebuilt with Bifrost's `/v1`.
    func testAnEndpointSpellingIsCalledExactlyAsTyped() {
        let chat = GatewayUpstreamURL.upstream(
            for: .openAIChat, url: "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(chat.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(chat.inferenceURL?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(chat.requestPathOverrides["chat_completion"], "/chat/completions")
        XCTAssertEqual(chat.requestPathOverrides["list_models"], "/models")

        // A `/v1` the user typed belongs to the upstream, so it stays on every sibling path too.
        let responses = GatewayUpstreamURL.upstream(
            for: .openAIResponses, url: "https://api.openai.com/v1/responses"
        )
        XCTAssertEqual(responses.baseURL, "https://api.openai.com")
        XCTAssertEqual(
            responses.inferenceURL?.absoluteString, "https://api.openai.com/v1/responses"
        )
        XCTAssertEqual(responses.requestPathOverrides["responses"], "/v1/responses")
        XCTAssertEqual(responses.requestPathOverrides["list_models"], "/v1/models")

        let messages = GatewayUpstreamURL.upstream(
            for: .anthropic, url: "https://api.deepseek.com/anthropic/v1/messages"
        )
        XCTAssertEqual(messages.baseURL, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(messages.requestPathOverrides["chat_completion"], "/v1/messages")
    }

    /// A base spelling keeps the original reconciliation, which is what every provider saved
    /// before per-protocol addresses existed still depends on.
    func testABaseSpellingKeepsTheOriginalReconciliation() {
        let glm = GatewayUpstreamURL.upstream(
            for: .anthropic, url: "https://open.bigmodel.cn/api/anthropic/v1"
        )
        XCTAssertEqual(glm.baseURL, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertTrue(glm.requestPathOverrides.isEmpty)
        XCTAssertEqual(
            glm.inferenceURL?.absoluteString,
            "https://open.bigmodel.cn/api/anthropic/v1/messages"
        )

        let deepSeek = GatewayUpstreamURL.upstream(
            for: .anthropic, url: "https://api.deepseek.com/anthropic"
        )
        XCTAssertEqual(deepSeek.baseURL, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(
            deepSeek.inferenceURL?.absoluteString,
            "https://api.deepseek.com/anthropic/v1/messages"
        )

        // An address with nothing in it resolves to nothing, and the configuration builder
        // rejects it rather than writing an upstream with no host.
        for unusable in ["", "   ", "\n"] {
            let upstream = GatewayUpstreamURL.upstream(for: .anthropic, url: unusable)
            XCTAssertEqual(upstream, GatewayUpstreamURL.Upstream.unusable, unusable)
            XCTAssertTrue(upstream.baseURL.isEmpty, unusable)
            XCTAssertNil(upstream.inferenceURL, unusable)
        }
        // A host that is only a scheme must not be shortened into one: `https://messages` ends
        // with the Anthropic inference path without being an endpoint.
        let schemeOnly = GatewayUpstreamURL.upstream(for: .anthropic, url: "https://messages")
        XCTAssertEqual(schemeOnly.baseURL, "https://messages")
        XCTAssertEqual(
            schemeOnly.inferenceURL?.absoluteString, "https://messages/v1/messages"
        )
    }

    /// What the editor offers for a protocol the user has not bound yet.
    func testAddressesAreOfferedOnlyForABaseThatIsActuallyBare() {
        let base = "https://api.deepseek.com"
        XCTAssertEqual(
            GatewayUpstreamURL.derivedURL(for: .anthropic, base: base),
            "https://api.deepseek.com/anthropic"
        )
        XCTAssertEqual(
            GatewayUpstreamURL.derivedURL(for: .openAIChat, base: base),
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            GatewayUpstreamURL.derivedURL(for: .openAIResponses, base: "\(base)/"),
            "https://api.deepseek.com/responses"
        )
        // Already an Anthropic base: offering `…/anthropic/anthropic` would be nonsense.
        XCTAssertEqual(
            GatewayUpstreamURL.derivedURL(for: .anthropic, base: "\(base)/anthropic"),
            "https://api.deepseek.com/anthropic"
        )
        // A base pointed at one specific API cannot have a sibling path guessed off it.
        for pointed in [
            "https://api.anthropic.com/v1",
            "https://open.bigmodel.cn/api/paas/v4",
            "https://generativelanguage.googleapis.com/v1beta/openai",
            "https://api.deepseek.com/chat/completions",
            "",
            "not a url",
            "ftp://api.deepseek.com",
        ] {
            XCTAssertNil(
                GatewayUpstreamURL.derivedURL(for: .openAIChat, base: pointed), pointed
            )
        }
    }

    func testAnEmptyOrSchemeOnlyBaseIsNotMangled() {
        XCTAssertNil(GatewayUpstreamURL.endpointURL(baseURL: "", wireProtocol: .anthropic))
        XCTAssertNil(GatewayUpstreamURL.endpointURL(baseURL: "   ", wireProtocol: .anthropic))
        XCTAssertEqual(GatewayUpstreamURL.bifrostBaseURL(for: ""), "")
    }
}
