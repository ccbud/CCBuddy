import Foundation

/// The wire protocol a *client* spoke, recovered from the request path before the request is
/// rewritten onto a Bifrost integration route.
///
/// CC Buddy's gateway accepts all three caller shapes unconditionally. What the user configures
/// is the set of *upstreams*: one, two or three of Anthropic Messages, OpenAI Chat Completions
/// and OpenAI Responses. Recovering the caller's protocol is the first half of honouring that
/// contract — the second half is `GatewayProtocolRouter`, which decides whether the request can
/// be handed to a same-protocol upstream untouched or has to be converted.
enum GatewayClientProtocol: String, Equatable, Sendable, CaseIterable {
    case anthropic
    case openAIChat
    case openAIResponses

    /// The upstream wire protocol that serves this caller without any conversion.
    var passthroughProtocol: Provider.WireProtocol {
        switch self {
        case .anthropic: .anthropic
        case .openAIChat: .openAIChat
        case .openAIResponses: .openAIResponses
        }
    }

    init(_ wireProtocol: Provider.WireProtocol) {
        switch wireProtocol {
        case .anthropic: self = .anthropic
        case .openAIChat: self = .openAIChat
        case .openAIResponses: self = .openAIResponses
        }
    }

    /// Classifies a request path. Both the caller-facing aliases CC Buddy has always accepted
    /// (`/v1/messages`, `/chat/completions`, …) and Bifrost's own integration paths
    /// (`/anthropic/v1/messages`, `/openai/v1/responses`, …) are recognised, so a client pointed
    /// straight at a Bifrost route is routed by the same rules as one pointed at the alias.
    static func classify(path: String) -> GatewayClientProtocol? {
        var normalized = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        guard !normalized.isEmpty else { return nil }

        // Longest-suffix first: `/v1/responses/compact` must not be read as `/compact`, and
        // `/v1/messages/count_tokens` must not fall through to the bare `/count_tokens`.
        if normalized.hasSuffix("/messages/count_tokens") { return .anthropic }
        if normalized.hasSuffix("/chat/completions") { return .openAIChat }
        if normalized.hasSuffix("/responses/compact") { return .openAIResponses }
        if normalized.hasSuffix("/v1/messages") || normalized == "/messages" { return .anthropic }
        if normalized.hasSuffix("/v1/complete") || normalized == "/complete" { return .anthropic }
        // Bifrost publishes the Responses endpoint under three spellings on each prefix —
        // `/v1/responses`, `/responses` and `/openai/responses` — so match the trailing segment
        // rather than enumerating them.
        if normalized.hasSuffix("/responses") { return .openAIResponses }
        // Responses object lifecycle: retrieve / delete / cancel / input_items all hang off an
        // opaque response id, so match the segment rather than the whole path.
        if normalized.contains("/responses/") { return .openAIResponses }
        return nil
    }
}

/// One configured upstream paired with the Bifrost provider name that addresses it.
struct GatewayUpstreamRoute: Equatable, Sendable {
    let bifrostName: String
    let provider: Provider
    /// The protocol this route's address speaks. A provider binds up to three addresses and
    /// contributes one route per bound protocol, so this is not simply `provider.protocol` —
    /// that one names only the route which also takes the callers nothing else matches.
    let wireProtocol: Provider.WireProtocol

    init(
        bifrostName: String,
        provider: Provider,
        wireProtocol: Provider.WireProtocol? = nil
    ) {
        self.bifrostName = bifrostName
        self.provider = provider
        self.wireProtocol = wireProtocol ?? provider.primaryProtocol
    }
}

/// Decides which configured upstream serves a caller, and whether Bifrost has to convert.
///
/// The rule the gateway promises, over the addresses configured across every routed provider:
///
/// * **Three of three.** Every caller protocol has an upstream that speaks it, so every request
///   is handed to that upstream untouched. Nothing is converted. One provider that publishes all
///   three of its own endpoints reaches this on its own.
/// * **One or two of three.** A caller whose protocol *is* configured still passes through. A
///   caller whose protocol is not configured is routed to the primary upstream (the head of the
///   failover queue, or the active provider when no queue is enabled) and Bifrost performs the
///   conversion.
///
/// Bifrost resolves an unprefixed model name through its model catalog, which has no notion of
/// the caller's protocol and — when several providers advertise the same wildcard model list —
/// collapses onto whichever provider it happens to index first. That is why the decision is made
/// here and then *pinned* by rewriting the request model to `"<bifrost provider>/<model>"`, which
/// Bifrost honours ahead of catalog resolution.
struct GatewayProtocolRouter: Equatable, Sendable {
    let routes: [GatewayUpstreamRoute]

    init(routes: [GatewayUpstreamRoute]) {
        self.routes = routes
    }

    init(config: AppConfig) {
        routes = BifrostConfigBuilder.routedProviders(from: config).map {
            GatewayUpstreamRoute(
                bifrostName: $0.bifrostName,
                provider: $0.provider,
                wireProtocol: $0.wireProtocol
            )
        }
    }

    /// A single configured upstream is already unambiguous to Bifrost, so its requests keep the
    /// byte-identical passthrough path instead of being rewritten to carry a provider prefix.
    var pinsProviderName: Bool { routes.count > 1 }

    var primaryRoute: GatewayUpstreamRoute? { routes.first }

    /// The caller protocols that reach an upstream speaking the same protocol.
    var passthroughProtocols: Set<GatewayClientProtocol> {
        Set(routes.map { GatewayClientProtocol($0.wireProtocol) })
    }

    /// True when every caller shape has a matching upstream — the "three of three" case, where
    /// the gateway is a pure pass-through.
    var servesEveryProtocolDirectly: Bool {
        passthroughProtocols.count == GatewayClientProtocol.allCases.count
    }

    /// The upstream that serves this caller. An exact protocol match always wins; otherwise the
    /// primary upstream takes the request and Bifrost converts it.
    func route(for clientProtocol: GatewayClientProtocol?) -> GatewayUpstreamRoute? {
        guard let clientProtocol else { return primaryRoute }
        if let direct = routes.first(where: { $0.wireProtocol == clientProtocol.passthroughProtocol }) {
            return direct
        }
        return primaryRoute
    }

    /// Whether serving this caller requires Bifrost to translate between protocols. Used to keep
    /// the generated Bifrost configuration's conversion hooks in step with the configured set.
    func requiresConversion(for clientProtocol: GatewayClientProtocol) -> Bool {
        guard let route = route(for: clientProtocol) else { return false }
        return route.wireProtocol != clientProtocol.passthroughProtocol
    }

    /// Removes a `"<bifrost provider>/"` prefix that belongs to one of this gateway's own
    /// providers. Bifrost echoes prefixed identifiers in `/v1/models`, and those names are an
    /// internal detail that must never reach a client.
    func strippingProviderPrefix(_ identifier: String) -> String {
        for route in routes {
            let prefix = "\(route.bifrostName)/"
            if identifier.hasPrefix(prefix) {
                return String(identifier.dropFirst(prefix.count))
            }
        }
        return identifier
    }
}
