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

    /// Paths Bifrost should use verbatim instead of prefixing its own version segment.
    ///
    /// Only endpoints with a fixed path are listed. The Responses lifecycle routes embed a
    /// response id in the path, so a static override would replace the id along with the prefix;
    /// they keep Bifrost's default, which is already correct for every base this returns an empty
    /// map for.
    static func requestPathOverrides(
        for wireProtocol: Provider.WireProtocol,
        baseURL: String
    ) -> [String: String] {
        guard versioning(of: baseURL) == .foreign else { return [:] }
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

    /// The alternative spelling to try when the first probe is refused, or nil when there is none.
    ///
    /// Providers disagree about whether their documented base URL includes the version segment,
    /// and users paste either form. Trying both is what lets the editor accept each.
    static func alternateEndpointURL(
        baseURL: String,
        wireProtocol: Provider.WireProtocol
    ) -> URL? {
        let base = trimmedBase(baseURL)
        guard !base.isEmpty else { return nil }
        let path = inferencePath(for: wireProtocol)
        switch versioning(of: base) {
        case .none:
            return URL(string: base + path)
        case .trailingV1:
            return URL(string: base + "/v1" + path)
        case .foreign:
            return nil
        }
    }

    /// The base URL that corresponds to `alternateEndpointURL`, so a provider probed at the
    /// other spelling can be stored the way it actually answers.
    static func alternateBaseURL(for baseURL: String) -> String {
        let base = trimmedBase(baseURL)
        switch versioning(of: base) {
        case .none: return base + "/v1"
        case .trailingV1: return bifrostBaseURL(for: base)
        case .foreign: return base
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
