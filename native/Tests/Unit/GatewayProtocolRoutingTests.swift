import XCTest

@testable import CCBuddy

/// The gateway's one-of-three / three-of-three contract.
///
/// The user configures upstreams; clients keep speaking whatever they already speak. When an
/// upstream speaking the caller's protocol exists the request must reach it untouched, and when
/// none does the request must still be served, converted, by the head of the queue. Before this,
/// provider selection was left to Bifrost's model catalog, which has no idea which protocol the
/// caller spoke: with several providers configured every caller collapsed onto whichever one the
/// catalog indexed first, so a Codex client could be answered by an Anthropic upstream even
/// though a Responses upstream was sitting right there in the queue.
final class GatewayProtocolRoutingTests: XCTestCase {
    private func provider(
        _ id: String,
        _ wireProtocol: Provider.WireProtocol,
        primary: String
    ) -> Provider {
        Provider(
            id: id,
            name: id,
            baseUrl: "https://\(id).example.com",
            authToken: "token",
            defaultModel: primary,
            smallFastModel: "\(primary)-fast",
            mapDefaultModels: true,
            protocol: wireProtocol
        )
    }

    private func config(_ providers: [Provider]) -> AppConfig {
        var config = AppConfig()
        config.providers = providers
        config.activeProviderId = providers.first?.id
        if providers.count > 1 {
            config.gatewayFailover = .init(enabled: true, providerIds: providers.map(\.id))
        }
        config.normalize()
        return config
    }

    private var anthropicProvider: Provider { provider("anth", .anthropic, primary: "claude-up") }
    private var chatProvider: Provider { provider("chat", .openAIChat, primary: "chat-up") }
    private var responsesProvider: Provider {
        provider("resp", .openAIResponses, primary: "resp-up")
    }

    func testEveryCallerFacingPathIsClassifiedByItsWireProtocol() {
        let expectations: [(String, GatewayClientProtocol)] = [
            ("/v1/messages", .anthropic),
            ("/messages", .anthropic),
            ("/anthropic/v1/messages", .anthropic),
            ("/v1/messages/count_tokens", .anthropic),
            ("/anthropic/v1/messages/count_tokens", .anthropic),
            ("/v1/complete", .anthropic),
            ("/v1/chat/completions", .openAIChat),
            ("/chat/completions", .openAIChat),
            ("/openai/v1/chat/completions", .openAIChat),
            ("/v1/responses", .openAIResponses),
            ("/responses", .openAIResponses),
            ("/openai/v1/responses", .openAIResponses),
            // Bifrost publishes this third spelling of its Responses route.
            ("/openai/responses", .openAIResponses),
            ("/v1/responses/compact", .openAIResponses),
            ("/v1/responses/resp_123", .openAIResponses),
            ("/v1/responses/resp_123/cancel", .openAIResponses),
        ]
        for (path, expected) in expectations {
            XCTAssertEqual(GatewayClientProtocol.classify(path: path), expected, path)
        }
        // A trailing slash and a query string are part of ordinary client traffic.
        XCTAssertEqual(GatewayClientProtocol.classify(path: "/v1/messages/"), .anthropic)
        XCTAssertEqual(
            GatewayClientProtocol.classify(path: "/v1/messages?beta=true"), .anthropic
        )
        for path in ["/v1/models", "/models", "/messages-extra", "/", "/metrics"] {
            XCTAssertNil(GatewayClientProtocol.classify(path: path), path)
        }
    }

    func testThreeOfThreeHandsEveryCallerToItsOwnUpstreamWithoutConverting() {
        let config = config([anthropicProvider, chatProvider, responsesProvider])
        let router = GatewayProtocolRouter(config: config)
        XCTAssertTrue(router.servesEveryProtocolDirectly)
        XCTAssertTrue(router.pinsProviderName)

        let expectations: [(GatewayClientProtocol, String)] = [
            (.anthropic, "anth"), (.openAIChat, "chat"), (.openAIResponses, "resp"),
        ]
        let routing = LegacyModelRoutingCompatibility(config: config)
        for (clientProtocol, providerID) in expectations {
            XCTAssertEqual(
                router.route(for: clientProtocol)?.provider.id, providerID,
                "\(clientProtocol.rawValue) must reach the upstream that speaks it"
            )
            XCTAssertFalse(
                router.requiresConversion(for: clientProtocol), clientProtocol.rawValue
            )
            let bifrostName = router.routes.first { $0.provider.id == providerID }?.bifrostName
            XCTAssertNotNil(bifrostName)
            let route = routing.resolve("claude-sonnet-5", clientProtocol: clientProtocol)
            XCTAssertEqual(route?.pinnedProviderName, bifrostName)
            XCTAssertEqual(
                route?.wireModel?.hasPrefix("\(bifrostName ?? "")/"), true,
                "the wire model must name the provider so Bifrost cannot pick another"
            )
        }
    }

    func testOneOfThreeServesEveryCallerThroughTheSingleConfiguredUpstream() {
        let config = config([responsesProvider])
        let router = GatewayProtocolRouter(config: config)
        XCTAssertFalse(router.servesEveryProtocolDirectly)
        XCTAssertFalse(
            router.pinsProviderName,
            "one upstream is already unambiguous, so its requests stay byte-identical"
        )
        for clientProtocol in GatewayClientProtocol.allCases {
            XCTAssertEqual(router.route(for: clientProtocol)?.provider.id, "resp")
        }
        XCTAssertTrue(router.requiresConversion(for: .anthropic))
        XCTAssertTrue(router.requiresConversion(for: .openAIChat))
        XCTAssertFalse(router.requiresConversion(for: .openAIResponses))

        let routing = LegacyModelRoutingCompatibility(config: config)
        let route = routing.resolve("claude-sonnet-4-5", clientProtocol: .anthropic)
        XCTAssertEqual(route?.wireModel, "resp-up")
        XCTAssertNil(route?.pinnedProviderName)
        XCTAssertEqual(route?.fallbackModels, [])
    }

    func testTwoOfThreeConvertsOnlyTheProtocolItDoesNotHave() {
        let config = config([chatProvider, responsesProvider])
        let router = GatewayProtocolRouter(config: config)
        XCTAssertEqual(router.route(for: .openAIChat)?.provider.id, "chat")
        XCTAssertEqual(router.route(for: .openAIResponses)?.provider.id, "resp")
        XCTAssertEqual(
            router.route(for: .anthropic)?.provider.id, "chat",
            "an unconfigured caller protocol falls to the head of the queue"
        )
        XCTAssertFalse(router.requiresConversion(for: .openAIChat))
        XCTAssertFalse(router.requiresConversion(for: .openAIResponses))
        XCTAssertTrue(router.requiresConversion(for: .anthropic))
    }

    /// Pinning a provider takes provider choice away from Bifrost's virtual-key balancer, which
    /// is also what used to provide failover. The rest of the queue therefore has to travel with
    /// the request.
    func testPinnedRequestsStillCarryTheRestOfTheQueueAsFallbacks() {
        let config = config([chatProvider, responsesProvider, anthropicProvider])
        let router = GatewayProtocolRouter(config: config)
        let routing = LegacyModelRoutingCompatibility(config: config)
        let names = Dictionary(
            uniqueKeysWithValues: router.routes.map { ($0.provider.id, $0.bifrostName) }
        )

        let route = routing.resolve("claude-haiku-4-5", clientProtocol: .openAIResponses)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.pinnedProviderName, names["resp"])
        XCTAssertEqual(
            route?.fallbackModels,
            ["\(names["chat"] ?? "")/chat-up-fast", "\(names["anth"] ?? "")/claude-up-fast"],
            "fallbacks keep the configured queue order and each provider's own model mapping"
        )
    }

    /// A model the user mapped explicitly keeps its caller spelling on the wire so Bifrost's own
    /// alias resolver still runs and still records which alias it applied.
    func testConfiguredAliasesKeepTheirCallerSpellingBehindTheProviderPrefix() {
        var aliased = chatProvider
        aliased.models = [ModelMapping(alias: "my-alias", upstream: "real-upstream")]
        let config = config([aliased, responsesProvider])
        let router = GatewayProtocolRouter(config: config)
        let routing = LegacyModelRoutingCompatibility(config: config)
        let name = router.routes.first { $0.provider.id == "chat" }?.bifrostName ?? ""

        let route = routing.resolve("my-alias", clientProtocol: .openAIChat)
        XCTAssertEqual(route?.wireModel, "\(name)/my-alias")
        XCTAssertEqual(route?.outgoingModel, "real-upstream")
        XCTAssertTrue(route?.usesNativeAlias == true)
        XCTAssertTrue(
            route?.needsResponseRestoration == true,
            "the caller must see back the model name it sent"
        )
    }

    func testModelMappingFollowsTheUpstreamThatActuallyServesTheRequest() {
        var chat = chatProvider
        chat.models = [ModelMapping(alias: "shared", upstream: "chat-target")]
        var responses = responsesProvider
        responses.models = [ModelMapping(alias: "shared", upstream: "responses-target")]
        let routing = LegacyModelRoutingCompatibility(config: config([chat, responses]))

        XCTAssertEqual(
            routing.resolve("shared", clientProtocol: .openAIChat)?.outgoingModel,
            "chat-target"
        )
        XCTAssertEqual(
            routing.resolve("shared", clientProtocol: .openAIResponses)?.outgoingModel,
            "responses-target",
            "a Responses caller must be mapped through the Responses provider's own aliases"
        )
    }

    func testInternalProviderNamesAreStrippedBeforeAModelListReachesAClient() {
        let router = GatewayProtocolRouter(config: config([chatProvider, responsesProvider]))
        let name = router.routes[0].bifrostName
        XCTAssertEqual(router.strippingProviderPrefix("\(name)/gpt-5.4"), "gpt-5.4")
        XCTAssertEqual(router.strippingProviderPrefix("vendor/model-x"), "vendor/model-x")
        XCTAssertEqual(router.strippingProviderPrefix("gpt-5.4"), "gpt-5.4")
    }

    func testAModelAlreadyNamingItsProviderIsNotPrefixedTwice() {
        let route = LegacyModelRoute(
            requestedModel: "ccbud-1-abc/gpt-5.4",
            outgoingModel: "ccbud-1-abc/gpt-5.4",
            usesNativeAlias: false,
            pinnedProviderName: "ccbud-1-abc"
        )
        XCTAssertEqual(route.wireModel, "ccbud-1-abc/gpt-5.4")
    }

    /// One vendor publishing all three of its own endpoints is the case worth not converting for.
    ///
    /// DeepSeek answers Anthropic Messages, Chat Completions and Responses itself. Before
    /// addresses were bound per protocol, a provider was one protocol, so two of those three
    /// callers were translated on the way to an upstream that spoke their language natively.
    func testOneProviderBindingThreeAddressesConvertsForNobody() {
        var deepSeek = provider("ds", .anthropic, primary: "deepseek-chat")
        deepSeek.baseUrl = "https://api.deepseek.com"
        deepSeek.protocolUrls = [
            "anthropic": "https://api.deepseek.com/anthropic",
            "openai-chat": "https://api.deepseek.com/chat/completions",
            "openai-responses": "https://api.deepseek.com/responses",
        ]
        let router = GatewayProtocolRouter(config: config([deepSeek]))

        XCTAssertEqual(router.routes.count, 3)
        XCTAssertTrue(router.servesEveryProtocolDirectly)
        XCTAssertTrue(
            router.pinsProviderName,
            "three Bifrost entries share one provider, so the request has to name which"
        )
        for clientProtocol in GatewayClientProtocol.allCases {
            XCTAssertEqual(router.route(for: clientProtocol)?.provider.id, "ds")
            XCTAssertEqual(
                router.route(for: clientProtocol)?.wireProtocol,
                clientProtocol.passthroughProtocol
            )
            XCTAssertFalse(router.requiresConversion(for: clientProtocol), clientProtocol.rawValue)
        }
        // The primary — the address that would take an unmatched caller — heads the list.
        XCTAssertEqual(router.primaryRoute?.wireProtocol, .anthropic)
    }

    /// Binding two of three is the on-demand case: the caller the vendor publishes nothing for is
    /// the only one converted.
    func testAProviderBindingTwoAddressesConvertsOnlyTheThirdCaller() {
        var deepSeek = provider("ds", .anthropic, primary: "deepseek-chat")
        deepSeek.baseUrl = "https://api.deepseek.com"
        deepSeek.protocolUrls = [
            "anthropic": "https://api.deepseek.com/anthropic",
            "openai-chat": "https://api.deepseek.com/chat/completions",
        ]
        let router = GatewayProtocolRouter(config: config([deepSeek]))

        XCTAssertFalse(router.servesEveryProtocolDirectly)
        XCTAssertFalse(router.requiresConversion(for: .anthropic))
        XCTAssertFalse(router.requiresConversion(for: .openAIChat))
        XCTAssertTrue(
            router.requiresConversion(for: .openAIResponses),
            "a Codex client has no Responses upstream here, so Bifrost has to translate"
        )
        XCTAssertEqual(router.route(for: .openAIResponses)?.wireProtocol, .anthropic)
    }

    /// Failover is between providers. A provider contributing three routes must not occupy the
    /// whole fallback chain with itself, or the second provider in the queue never gets tried.
    func testFallbacksStillWalkTheProviderQueueWhenOneProviderBindsEveryProtocol() throws {
        var multi = provider("multi", .anthropic, primary: "multi-up")
        multi.protocolUrls = [
            "anthropic": "https://multi.example.com/anthropic",
            "openai-chat": "https://multi.example.com/chat/completions",
            "openai-responses": "https://multi.example.com/responses",
        ]
        let config = config([multi, chatProvider])
        let router = GatewayProtocolRouter(config: config)
        let routing = LegacyModelRoutingCompatibility(config: config)
        let backup = try XCTUnwrap(
            router.routes.first { $0.provider.id == "chat" }?.bifrostName
        )
        let pinned = try XCTUnwrap(router.routes.first {
            $0.provider.id == "multi" && $0.wireProtocol == .openAIResponses
        }?.bifrostName)

        let route = routing.resolve("claude-sonnet-5", clientProtocol: .openAIResponses)
        XCTAssertEqual(route?.pinnedProviderName, pinned)
        XCTAssertEqual(
            route?.fallbackModels, ["\(backup)/chat-up"],
            "the other provider is the fallback; the same provider's other addresses are not"
        )
    }

    /// A provider whose per-protocol addresses were never filled in keeps the single upstream it
    /// has always had, addressed by its base URL.
    func testAProviderSavedBeforePerProtocolAddressesKeepsItsSingleUpstream() {
        let legacy = provider("legacy", .openAIChat, primary: "chat-up")
        XCTAssertTrue(legacy.protocolUrls.isEmpty)
        XCTAssertEqual(legacy.configuredProtocols, [.openAIChat])
        XCTAssertEqual(legacy.upstreamURL(for: .openAIChat), "https://legacy.example.com")
        XCTAssertNil(legacy.upstreamURL(for: .anthropic))

        let router = GatewayProtocolRouter(config: config([legacy]))
        XCTAssertEqual(router.routes.count, 1)
        XCTAssertFalse(router.pinsProviderName)
        XCTAssertTrue(router.requiresConversion(for: .anthropic))
    }

    func testNoConfiguredProviderProducesNoRoute() {
        let router = GatewayProtocolRouter(config: AppConfig())
        XCTAssertNil(router.route(for: .anthropic))
        XCTAssertFalse(router.servesEveryProtocolDirectly)
        XCTAssertNil(LegacyModelRoutingCompatibility(config: AppConfig()).resolve("anything"))
    }
}
