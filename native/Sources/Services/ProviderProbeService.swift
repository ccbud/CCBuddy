import Foundation

struct ProviderProbeResult: Equatable, Sendable {
    enum FailureReason: String, Equatable, Sendable {
        case baseURLEmpty
        case baseURLInvalid
        case timeout
    }

    var succeeded: Bool
    var statusCode: Int?
    var model: String?
    var message: String?
    var reason: FailureReason?
}

struct ProviderProbeService: Sendable {
    private let injectedSession: URLSession?

    init(session: URLSession? = nil) {
        injectedSession = session
    }

    func test(_ provider: Provider, insecureSkipVerify: Bool) async -> ProviderProbeResult {
        let baseURL = provider.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            return .init(succeeded: false, reason: .baseURLEmpty)
        }
        guard let components = URLComponents(string: baseURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              let primaryURL = endpointURL(baseURL: baseURL, protocol: provider.protocol)
        else {
            return .init(succeeded: false, reason: .baseURLInvalid)
        }

        let session = injectedSession ?? Self.makeSession(insecureSkipVerify: insecureSkipVerify)
        let body = requestBody(for: provider)
        do {
            // Exactly one request, to exactly the URL the gateway will call. The probe used to
            // try a second spelling and quietly rewrite the user's base URL when it answered,
            // which is how a provider could test healthy against an address the gateway never
            // used. `GatewayUpstreamURL` now maps each base URL to a single upstream URL, so
            // there is no second spelling to try.
            let response = try await send(
                to: primaryURL,
                provider: provider,
                body: body,
                session: session
            )
            return decode(
                response,
                protocol: provider.protocol,
                requestedModel: selectedModel(for: provider)
            )
        } catch let error as URLError where error.code == .timedOut {
            return .init(succeeded: false, message: error.localizedDescription, reason: .timeout)
        } catch {
            return .init(succeeded: false, message: error.localizedDescription)
        }
    }

    private func send(
        to url: URL,
        provider: Provider,
        body: Data,
        session: URLSession
    ) async throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.authToken)", forHTTPHeaderField: "Authorization")
        if provider.protocol == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (response.statusCode, data)
    }

    private func requestBody(for provider: Provider) -> Data {
        let model = selectedModel(for: provider)
        let object: [String: Any]
        switch provider.protocol {
        case .openAIResponses:
            object = ["model": model, "max_output_tokens": 16, "input": "ping"]
        case .openAIChat, .anthropic:
            object = [
                "model": model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "ping"]],
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func selectedModel(for provider: Provider) -> String {
        let primary = provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        if let mapped = provider.models.first?.upstream.trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty { return mapped }
        return "claude-3-5-haiku-20241022"
    }

    private func decode(
        _ response: (statusCode: Int, data: Data),
        protocol wireProtocol: Provider.WireProtocol,
        requestedModel: String
    ) -> ProviderProbeResult {
        let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        let shapeIsValid: Bool
        switch wireProtocol {
        case .anthropic:
            shapeIsValid = object?["type"] as? String == "message"
        case .openAIChat:
            shapeIsValid = object?["choices"] is [Any]
        case .openAIResponses:
            shapeIsValid = object?["output"] != nil || object?["id"] != nil
        }
        if (200..<300).contains(response.statusCode), shapeIsValid {
            return .init(
                succeeded: true,
                statusCode: response.statusCode,
                model: object?["model"] as? String ?? requestedModel
            )
        }

        let error = object?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? {
            let text = String(decoding: response.data.prefix(200), as: UTF8.self)
            return text.isEmpty ? "HTTP \(response.statusCode)" : text
        }()
        return .init(
            succeeded: false,
            statusCode: response.statusCode,
            message: message
        )
    }

    /// The URL a real inference request will reach.
    ///
    /// Shared with the Bifrost configuration builder on purpose. When the probe computed its own
    /// URL, it could report a healthy provider the gateway then answered with 404, because the
    /// two disagreed about whether the base URL already carried its version segment.
    private func endpointURL(
        baseURL: String,
        protocol wireProtocol: Provider.WireProtocol
    ) -> URL? {
        GatewayUpstreamURL.endpointURL(baseURL: baseURL, wireProtocol: wireProtocol)
    }

    private static func makeSession(insecureSkipVerify: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        guard insecureSkipVerify else { return URLSession(configuration: configuration) }
        return URLSession(
            configuration: configuration,
            delegate: ProviderProbeTLSDelegate(),
            delegateQueue: nil
        )
    }
}

private final class ProviderProbeTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
