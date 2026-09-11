import Foundation

/// What a provider's model-listing endpoint turned out to be.
///
/// `/v1/models` (and its unversioned `/models` sibling) is a convention, not a guarantee: plenty
/// of Anthropic-compatible relays and self-hosted gateways expose inference only. So discovery
/// reports three distinct outcomes rather than a bare optional, and the UI greys its refresh
/// control out for `.unsupported` instead of offering an action that can only fail.
enum ProviderModelCatalogAvailability: String, Equatable, Sendable {
    /// Never probed, or the probe could not reach the host at all. Refresh stays available.
    case unknown
    /// A listing endpoint answered with a parseable catalog.
    case available
    /// The host answered, and every candidate path said the endpoint is not there.
    case unsupported
}

struct ProviderModelCatalog: Equatable, Sendable {
    var availability: ProviderModelCatalogAvailability = .unknown
    /// Upstream model identifiers, in the order the provider returned them.
    var models: [String] = []
    /// The absolute URL that answered, kept so the UI can show what was probed.
    var endpoint: String?
    var statusCode: Int?
    var message: String?

    var canRefresh: Bool { availability != .unsupported }

    static let unknown = ProviderModelCatalog()
}

/// Sniffs the conventional model-listing endpoints and turns whatever comes back into model
/// bindings.
///
/// Ordering matters. A base URL that already carries a version segment is asked for `/models`
/// first, because appending another `/v1` to it is how `…/v1/v1/models` 404s get produced. A base
/// URL without one is asked for `/v1/models` first, since that is what the overwhelming majority
/// of OpenAI-compatible hosts publish.
struct ProviderModelDiscoveryService: Sendable {
    private let injectedSession: URLSession?

    init(session: URLSession? = nil) {
        injectedSession = session
    }

    func discover(
        _ provider: Provider,
        insecureSkipVerify: Bool = false
    ) async -> ProviderModelCatalog {
        let baseURL = provider.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            return .init(availability: .unknown, message: "服务地址为空")
        }
        let candidates = Self.candidateURLs(baseURL: baseURL)
        guard !candidates.isEmpty else {
            return .init(availability: .unknown, message: "服务地址无效")
        }

        let session = injectedSession ?? Self.makeSession(insecureSkipVerify: insecureSkipVerify)
        var sawDefinitiveMiss = false
        var lastStatus: Int?
        var lastMessage: String?

        for url in candidates {
            do {
                let response = try await send(to: url, provider: provider, session: session)
                lastStatus = response.statusCode
                if (200..<300).contains(response.statusCode) {
                    let models = Self.parseModels(from: response.data)
                    if models.isEmpty {
                        // A 200 that carries no recognisable catalog is not proof the endpoint is
                        // missing, so keep probing and leave refresh enabled.
                        lastMessage = "模型列表为空或无法解析"
                        continue
                    }
                    return .init(
                        availability: .available,
                        models: models,
                        endpoint: url.absoluteString,
                        statusCode: response.statusCode
                    )
                }
                // 404/405/501 are the honest "no such endpoint" answers. Anything else (401, 403,
                // 429, 5xx) says the endpoint may well exist and the request was simply rejected.
                if [404, 405, 501].contains(response.statusCode) {
                    sawDefinitiveMiss = true
                } else {
                    lastMessage = Self.errorMessage(from: response.data, status: response.statusCode)
                }
            } catch {
                lastMessage = error.localizedDescription
            }
        }

        if sawDefinitiveMiss && lastMessage == nil {
            return .init(
                availability: .unsupported,
                statusCode: lastStatus,
                message: "该服务未提供模型列表接口"
            )
        }
        return .init(availability: .unknown, statusCode: lastStatus, message: lastMessage)
    }

    /// Folds discovered identifiers into a provider's bindings without disturbing anything the
    /// user wrote. Existing rows win on both sides of the arrow: an alias the user already mapped
    /// keeps its upstream, and a discovered model that some row already targets is not duplicated.
    static func merging(
        discovered models: [String],
        into existing: [ModelMapping]
    ) -> [ModelMapping] {
        let kept = existing.filter {
            !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var claimedAliases = Set(kept.map { $0.alias.trimmingCharacters(in: .whitespacesAndNewlines) })
        var claimedUpstreams = Set(
            kept.map { $0.upstream.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        var result = kept
        for model in models {
            let identifier = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, identifier != "*" else { continue }
            guard !claimedAliases.contains(identifier),
                  !claimedUpstreams.contains(identifier) else { continue }
            claimedAliases.insert(identifier)
            claimedUpstreams.insert(identifier)
            result.append(ModelMapping(alias: identifier, upstream: identifier))
        }
        return result
    }

    private func send(
        to url: URL,
        provider: Provider,
        session: URLSession
    ) async throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Compressed bodies are decoded by URLSession, but asking for identity keeps the
        // occasional relay that mis-advertises its encoding from handing back bytes we cannot read.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let token = provider.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if provider.protocol == .anthropic {
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }
        }
        if provider.protocol == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (response.statusCode, data)
    }

    /// The conventional listing paths, ordered so the likelier one for this base URL goes first.
    static func candidateURLs(baseURL: String) -> [URL] {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: base),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return [] }
        // One shared definition of "does this base already carry its version segment". A second,
        // slightly different copy of that question living here is exactly how the gateway and the
        // connection test came to disagree about it.
        let carriesVersion = GatewayUpstreamURL.versioning(of: base) != .none
        let paths = carriesVersion ? ["/models", "/v1/models"] : ["/v1/models", "/models"]
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let url = URL(string: base + path), seen.insert(url.absoluteString).inserted
            else { return nil }
            return url
        }
    }

    /// Accepts every catalog shape these endpoints are served in: OpenAI's and Anthropic's
    /// `{"data":[…]}`, the `{"models":[…]}` used by several self-hosted relays, and a bare array
    /// of either objects or plain strings.
    static func parseModels(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) else { return [] }
        let entries: [Any]
        if let array = root as? [Any] {
            entries = array
        } else if let object = root as? [String: Any] {
            if let list = object["data"] as? [Any] {
                entries = list
            } else if let list = object["models"] as? [Any] {
                entries = list
            } else {
                return []
            }
        } else {
            return []
        }

        var seen = Set<String>()
        var models: [String] = []
        for entry in entries {
            let identifier: String?
            if let text = entry as? String {
                identifier = text
            } else if let object = entry as? [String: Any] {
                identifier = (object["id"] as? String)
                    ?? (object["name"] as? String)
                    ?? (object["model"] as? String)
            } else {
                identifier = nil
            }
            guard let raw = identifier else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            models.append(trimmed)
        }
        return models
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        let text = String(decoding: data.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP \(status)" : text
    }

    private static func makeSession(insecureSkipVerify: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        guard insecureSkipVerify else { return URLSession(configuration: configuration) }
        return URLSession(
            configuration: configuration,
            delegate: ProviderModelDiscoveryTLSDelegate(),
            delegateQueue: nil
        )
    }
}

private final class ProviderModelDiscoveryTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
