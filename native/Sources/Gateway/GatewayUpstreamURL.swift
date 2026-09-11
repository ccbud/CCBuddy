import Foundation

/// Reconciles the base URL a user types with the path Bifrost builds on top of it.
///
/// Bifrost owns the whole upstream path. Its Anthropic transport posts to
/// `<base>/v1/messages`, its OpenAI transport to `<base>/v1/chat/completions`, and so on: the
/// `/v1` is Bifrost's, not the caller's. Every provider, meanwhile, documents a base URL that
/// already ends where its own version segment begins — `https://api.anthropic.com/v1`,
/// `https://api.moonshot.cn/anthropic/v1`, `https://generativelanguage.googleapis.com/v1beta/openai`.
///
/// Handing one of those straight to Bifrost produces `…/v1/v1/messages`, which every provider
/// answers with 404. That is a single character of path and it breaks the gateway completely, so
/// the reconciliation lives here, in one place, used both when generating Bifrost's configuration
/// and when probing a provider — otherwise the connection test passes against a URL the gateway
/// will never call.
enum GatewayUpstreamURL {
    /// How a base URL relates to the version segment Bifrost inserts.
    enum Versioning: Equatable, Sendable {
        /// No version segment. Bifrost's own `/v1/...` paths are already correct.
        case none
        /// Ends in exactly `/v1`, the segment Bifrost adds back. Dropping it is a complete fix:
        /// every endpoint, including the ones whose paths carry a response id, lands correctly.
        case trailingV1
        /// Carries a version Bifrost cannot reproduce, such as `/v4` or `/v1beta/openai`. The
        /// base has to be kept and Bifrost told not to prepend its own.
        case foreign
    }

    /// Detects a path segment that names an API version: `v1`, `v4`, `v1beta`, `v2alpha`.
    private static func isVersionSegment(_ segment: Substring) -> Bool {
        guard segment.first == "v" || segment.first == "V" else { return false }
        let rest = segment.dropFirst()
        guard let first = rest.first, first.isNumber else { return false }
        return rest.allSatisfy { $0.isNumber || $0.isLetter }
    }

    static func versioning(of baseURL: String) -> Versioning {
        let segments = pathSegments(of: baseURL)
        guard let last = segments.last else { return .none }
        if last == "v1" || last == "V1" { return .trailingV1 }
        return segments.contains(where: isVersionSegment) ? .foreign : .none
    }

    /// The base URL to write into Bifrost's `network_config.base_url`.
    ///
    /// A trailing `/v1` is removed because Bifrost puts it back. Anything else is preserved
    /// exactly as the user typed it; `requestPathOverrides` handles the rest.
    static func bifrostBaseURL(for baseURL: String) -> String {
        let trimmed = trimmedBase(baseURL)
        guard versioning(of: trimmed) == .trailingV1 else { return trimmed }
        guard let range = trimmed.range(of: "/", options: .backwards) else { return trimmed }
        let shortened = String(trimmed[trimmed.startIndex..<range.lowerBound])
        // Never hand back a bare scheme: "https://host/v1" must not become "https:/".
        return shortened.hasSuffix(":/") || shortened.isEmpty ? trimmed : shortened
    }

    /// Every operation path a protocol uses, relative to a base that already carries whatever
    /// version segment the upstream expects.
    ///
    /// Only endpoints with a fixed path are listed. The Responses lifecycle routes embed a
    /// response id in the path, so a static override would replace the id along with the prefix;
    /// they keep Bifrost's default `/v1/responses/<id>`, which is correct for every base that
    /// gets no override at all and for every pinned endpoint that carried a `/v1` of its own.
    private static func relativePaths(
        for wireProtocol: Provider.WireProtocol
    ) -> [String: String] {
        switch wireProtocol {
        case .anthropic:
            return [
                "list_models": "/models",
                "chat_completion": "/messages",
                "chat_completion_stream": "/messages",
                "responses": "/messages",
                "responses_stream": "/messages",
                "count_tokens": "/messages/count_tokens",
            ]
        case .openAIChat, .openAIResponses:
            return [
                "list_models": "/models",
                "chat_completion": "/chat/completions",
                "chat_completion_stream": "/chat/completions",
                "responses": "/responses",
                "responses_stream": "/responses",
                "count_tokens": "/responses/input_tokens",
                "compaction": "/responses/compact",
            ]
        }
    }

    /// Paths Bifrost should use verbatim instead of prefixing its own version segment.
    static func requestPathOverrides(
        for wireProtocol: Provider.WireProtocol,
        baseURL: String
    ) -> [String: String] {
        guard versioning(of: baseURL) == .foreign else { return [:] }
        return relativePaths(for: wireProtocol)
    }

    /// The inference path for a protocol, relative to a base URL that already carries its version.
    static func inferencePath(for wireProtocol: Provider.WireProtocol) -> String {
        switch wireProtocol {
        case .anthropic: "/messages"
        case .openAIChat: "/chat/completions"
        case .openAIResponses: "/responses"
        }
    }

    /// The absolute URL an inference request will actually reach, for the base URL as typed.
    ///
    /// This is what a connection test has to call. Computing it from the same rules the generated
    /// configuration uses is the point: a test that probes a different URL than the gateway can
    /// report success on a provider the gateway cannot reach.
    static func endpointURL(
        baseURL: String,
        wireProtocol: Provider.WireProtocol
    ) -> URL? {
        let base = trimmedBase(baseURL)
        guard !base.isEmpty else { return nil }
        let path = inferencePath(for: wireProtocol)
        switch versioning(of: base) {
        case .none:
            // Bifrost inserts its own version segment for this base, so the probe must too.
            return URL(string: base + "/v1" + path)
        case .trailingV1, .foreign:
            return URL(string: base + path)
        }
    }

    /// The spellings of a protocol's own endpoint a user might type into its address field,
    /// longest first so `…/anthropic/v1/messages` is not mistaken for `…/anthropic/v1` + `/messages`.
    private static func endpointSuffixes(for wireProtocol: Provider.WireProtocol) -> [String] {
        let path = inferencePath(for: wireProtocol)
        return ["/v1" + path, path]
    }

    /// One configured upstream, resolved into everything the gateway and the connection test need.
    struct Upstream: Equatable, Sendable {
        /// What goes into Bifrost's `network_config.base_url`.
        var baseURL: String
        /// Paths Bifrost must use verbatim. Empty when its own `/v1/...` paths already land.
        var requestPathOverrides: [String: String]
        /// The absolute URL an inference request reaches, or nil when the address is unusable.
        var inferenceURL: URL?

        static let unusable = Upstream(baseURL: "", requestPathOverrides: [:], inferenceURL: nil)
    }

    /// Resolves the address bound to one protocol.
    ///
    /// The field takes either spelling people already have in hand: the base their client is
    /// pointed at (`https://api.deepseek.com/anthropic`) or the endpoint their client posts to
    /// (`https://api.deepseek.com/chat/completions`). An endpoint spelling is taken literally and
    /// its exact path pinned, because a provider that publishes `/chat/completions` need not also
    /// answer `/v1/chat/completions` — letting Bifrost insert a version segment there would 404
    /// an address the user copied from the vendor's own documentation. A base spelling keeps the
    /// original reconciliation, which is what every provider saved before this still relies on.
    static func upstream(for wireProtocol: Provider.WireProtocol, url: String) -> Upstream {
        let trimmed = trimmedBase(url)
        guard !trimmed.isEmpty else { return .unusable }
        if let suffix = endpointSuffixes(for: wireProtocol).first(where: { trimmed.hasSuffix($0) }) {
            let base = String(trimmed.dropLast(suffix.count))
            // "https://host/v1/messages" must not shorten to "https:/" or to nothing at all.
            if !base.isEmpty && !base.hasSuffix(":/") {
                let versionPrefix = suffix.hasPrefix("/v1/") ? "/v1" : ""
                return Upstream(
                    baseURL: base,
                    requestPathOverrides: relativePaths(for: wireProtocol)
                        .mapValues { versionPrefix + $0 },
                    inferenceURL: URL(string: base + suffix)
                )
            }
        }
        return Upstream(
            baseURL: bifrostBaseURL(for: trimmed),
            requestPathOverrides: requestPathOverrides(for: wireProtocol, baseURL: trimmed),
            inferenceURL: endpointURL(baseURL: trimmed, wireProtocol: wireProtocol)
        )
    }

    /// The address to offer for a protocol the user has not bound yet, given the provider's base.
    ///
    /// Only a genuinely bare base can be extended this way. One that already carries a version
    /// segment, or that already ends in some endpoint's own path, has been pointed at a specific
    /// API, and guessing a sibling path off it produces nonsense like
    /// `…/api/anthropic/v1/chat/completions` — so nothing is offered and the field stays empty.
    static func derivedURL(for wireProtocol: Provider.WireProtocol, base: String) -> String? {
        let trimmed = trimmedBase(base)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              versioning(of: trimmed) == Versioning.none else { return nil }
        for candidate in Provider.WireProtocol.allCases {
            guard !endpointSuffixes(for: candidate).contains(where: { trimmed.hasSuffix($0) })
            else { return nil }
        }
        switch wireProtocol {
        case .anthropic:
            return trimmed.hasSuffix("/anthropic") ? trimmed : trimmed + "/anthropic"
        case .openAIChat:
            return trimmed + "/chat/completions"
        case .openAIResponses:
            return trimmed + "/responses"
        }
    }

    private static func trimmedBase(_ baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func pathSegments(of baseURL: String) -> [Substring] {
        let base = trimmedBase(baseURL)
        guard let components = URLComponents(string: base) else { return [] }
        // A bare "host/v1" with no scheme parses as a path, which is still worth classifying.
        let path = components.host == nil && components.scheme == nil ? base : components.path
        return path.split(separator: "/")
    }
}
