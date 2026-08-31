import Foundation

enum PluginHTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
}

struct PluginHTTPRequest: Equatable, Sendable {
    var method: PluginHTTPMethod
    var url: URL
    var headers: [String: String]
    var body: Data?
    var timeoutMilliseconds: Int

    init(
        method: PluginHTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMilliseconds: Int
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

struct PluginHTTPResponse: Equatable, Sendable {
    var statusCode: Int
    var body: Data
    var headers: [String: String]

    init(statusCode: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    var isSuccessful: Bool { (200..<300).contains(statusCode) }
}

protocol PluginHTTPTransporting: Sendable {
    func send(_ request: PluginHTTPRequest) async throws -> PluginHTTPResponse
}

final class URLSessionPluginHTTPTransport: PluginHTTPTransporting, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: PluginHTTPRequest) async throws -> PluginHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = TimeInterval(max(1, request.timeoutMilliseconds)) / 1_000
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw PluginControlPlaneError.invalidHTTPResponse
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let name = item.key as? String else { return }
            result[name] = String(describing: item.value)
        }
        return .init(statusCode: response.statusCode, body: data, headers: headers)
    }
}

enum PluginControlPlaneError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case transportFailure
    case invalidHTTPResponse
    case responseTooLarge(limit: Int)
    case unsuccessfulStatus(code: Int, message: String)
    case invalidJSON
    case actionNotForwardable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Plugin control-plane endpoint is invalid"
        case .transportFailure:
            return "Plugin control-plane request failed"
        case .invalidHTTPResponse:
            return "Plugin returned a non-HTTP response"
        case .responseTooLarge(let limit):
            return "Plugin response exceeded the \(limit)-byte limit"
        case .unsuccessfulStatus(let code, let message):
            return message.isEmpty ? "Plugin returned HTTP \(code)" : "Plugin returned HTTP \(code): \(message)"
        case .invalidJSON:
            return "Plugin returned invalid JSON"
        case .actionNotForwardable(let id):
            return "Plugin action '\(id)' is not a control-plane call"
        }
    }
}

enum PluginAuthenticationState: Equatable, Sendable {
    case loggedIn
    case loggedOut
    case expired
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "logged_in": self = .loggedIn
        case "logged_out": self = .loggedOut
        case "expired": self = .expired
        default: self = .unknown(rawValue)
        }
    }
}

struct PluginAuthenticationSnapshot: Equatable, Sendable {
    var state: PluginAuthenticationState
    var account: String?
    var message: String?
    var values: [String: PluginJSONValue]
}

struct PluginActionResponse: Equatable, Sendable {
    var succeeded: Bool
    var message: String?
    var values: [String: PluginJSONValue]
}

/// Redacts explicit values plus common credential-shaped fields. It is used only at observable
/// boundaries: process diagnostics and user-facing control-plane messages.
struct PluginSecretRedactor: Sendable {
    static let replacement = "[REDACTED]"

    var explicitSecrets: [String]

    init(explicitSecrets: [String] = []) {
        self.explicitSecrets = Array(Set(explicitSecrets.filter { $0.count >= 4 }))
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
    }

    func redact(_ value: String) -> String {
        var result = value
        for secret in explicitSecrets {
            result = result.replacingOccurrences(of: secret, with: Self.replacement)
        }
        for expression in Self.credentialExpressions {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1\(Self.replacement)"
            )
        }
        return result
    }

    private static let credentialExpressions: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)(\bauthorization\s*[:=]\s*(?:bearer|basic)?\s*)[^\s,;]+"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)((?:[\"']?)(?:access_?token|refresh_?token|api_?key|client_?secret|private_?key|password|passwd|secret|token)(?:[\"']?)\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}]+)"#
        ),
    ]
}

protocol PluginHealthChecking: Sendable {
    func isHealthy(url: URL, timeoutMilliseconds: Int) async -> Bool
}

struct PluginHTTPHealthChecker: PluginHealthChecking, Sendable {
    private let transport: any PluginHTTPTransporting

    init(transport: any PluginHTTPTransporting = URLSessionPluginHTTPTransport()) {
        self.transport = transport
    }

    func isHealthy(url: URL, timeoutMilliseconds: Int) async -> Bool {
        let request = PluginHTTPRequest(
            method: .get,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds
        )
        guard let response = try? await transport.send(request) else { return false }
        return response.isSuccessful
    }
}

struct PluginControlPlaneClient: Sendable {
    private let transport: any PluginHTTPTransporting
    private let maximumResponseBytes: Int
    private let authenticationTimeoutMilliseconds: Int
    private let actionLoadTimeoutMilliseconds: Int
    private let actionSubmitTimeoutMilliseconds: Int

    init(
        transport: any PluginHTTPTransporting = URLSessionPluginHTTPTransport(),
        maximumResponseBytes: Int = 1_048_576,
        authenticationTimeoutMilliseconds: Int = 3_000,
        actionLoadTimeoutMilliseconds: Int = 10_000,
        actionSubmitTimeoutMilliseconds: Int = 30_000
    ) {
        self.transport = transport
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.authenticationTimeoutMilliseconds = max(1, authenticationTimeoutMilliseconds)
        self.actionLoadTimeoutMilliseconds = max(1, actionLoadTimeoutMilliseconds)
        self.actionSubmitTimeoutMilliseconds = max(1, actionSubmitTimeoutMilliseconds)
    }

    func authenticationStatus(for sidecar: PluginSidecarDescriptor) async throws -> PluginAuthenticationSnapshot {
        let response = try await request(
            .init(
                method: .get,
                url: sidecar.authenticationStatusURL,
                timeoutMilliseconds: authenticationTimeoutMilliseconds
            ),
            sensitiveValues: []
        )
        var values = try decodeObject(response.body)
        let state = PluginAuthenticationState(rawValue: values["state"]?.stringValue ?? "")
        let sanitizedMessage = values["message"]?.stringValue.map { PluginSecretRedactor().redact($0) }
        if let sanitizedMessage { values["message"] = .string(sanitizedMessage) }
        return .init(
            state: state,
            account: values["account"]?.stringValue,
            message: sanitizedMessage,
            values: values
        )
    }

    func load(action: PluginAction, for sidecar: PluginSidecarDescriptor) async throws -> PluginActionResponse {
        guard action.kind == "form" || action.kind == "call" else {
            throw PluginControlPlaneError.actionNotForwardable(action.id)
        }
        let url = try endpointURL(path: action.loadPath, sidecar: sidecar)
        let response = try await request(
            .init(method: .get, url: url, timeoutMilliseconds: actionLoadTimeoutMilliseconds),
            sensitiveValues: []
        )
        return try actionResponse(from: response.body, sensitiveValues: [])
    }

    func submit(
        action: PluginAction,
        values: [String: PluginJSONValue],
        for sidecar: PluginSidecarDescriptor
    ) async throws -> PluginActionResponse {
        guard action.kind == "form" || action.kind == "call" else {
            throw PluginControlPlaneError.actionNotForwardable(action.id)
        }
        let url = try endpointURL(path: action.submitPath, sidecar: sidecar)
        let body: Data
        do {
            body = try JSONEncoder().encode(PluginJSONValue.object(values))
        } catch {
            throw PluginControlPlaneError.invalidJSON
        }
        let sensitiveValues = Self.strings(in: values)
        let response = try await request(
            .init(
                method: .post,
                url: url,
                headers: ["Accept": "application/json", "Content-Type": "application/json"],
                body: body,
                timeoutMilliseconds: actionSubmitTimeoutMilliseconds
            ),
            sensitiveValues: sensitiveValues
        )
        return try actionResponse(from: response.body, sensitiveValues: sensitiveValues)
    }

    private func request(
        _ request: PluginHTTPRequest,
        sensitiveValues: [String]
    ) async throws -> PluginHTTPResponse {
        let response: PluginHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch PluginControlPlaneError.invalidHTTPResponse {
            throw PluginControlPlaneError.invalidHTTPResponse
        } catch {
            // URLSession errors can include request details; keep the public failure intentionally generic.
            if Task.isCancelled { throw CancellationError() }
            throw PluginControlPlaneError.transportFailure
        }
        guard response.body.count <= maximumResponseBytes else {
            throw PluginControlPlaneError.responseTooLarge(limit: maximumResponseBytes)
        }
        guard response.isSuccessful else {
            let message = (try? decodeObject(response.body)["message"]?.stringValue) ?? ""
            let sanitized = PluginSecretRedactor(explicitSecrets: sensitiveValues).redact(message)
            throw PluginControlPlaneError.unsuccessfulStatus(
                code: response.statusCode,
                message: String(sanitized.prefix(512))
            )
        }
        return response
    }

    private func actionResponse(from data: Data, sensitiveValues: [String]) throws -> PluginActionResponse {
        var values = try decodeObject(data)
        let redactor = PluginSecretRedactor(explicitSecrets: sensitiveValues)
        let sanitizedMessage = values["message"]?.stringValue.map(redactor.redact)
        if let sanitizedMessage { values["message"] = .string(sanitizedMessage) }
        return .init(
            succeeded: values["ok"]?.boolValue ?? true,
            message: sanitizedMessage,
            values: values
        )
    }

    private func decodeObject(_ data: Data) throws -> [String: PluginJSONValue] {
        do {
            let value = try JSONDecoder().decode(PluginJSONValue.self, from: data)
            guard case .object(let object) = value else { throw PluginControlPlaneError.invalidJSON }
            return object
        } catch let error as PluginControlPlaneError {
            throw error
        } catch {
            throw PluginControlPlaneError.invalidJSON
        }
    }

    private func endpointURL(path: String, sidecar: PluginSidecarDescriptor) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              var components = URLComponents(url: sidecar.healthURL, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1" else {
            throw PluginControlPlaneError.invalidEndpoint
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw PluginControlPlaneError.invalidEndpoint }
        return url
    }

    private static func strings(in values: [String: PluginJSONValue]) -> [String] {
        values.values.flatMap(strings(in:))
    }

    private static func strings(in value: PluginJSONValue) -> [String] {
        switch value {
        case .string(let string): return [string]
        case .array(let array): return array.flatMap(strings(in:))
        case .object(let object): return strings(in: object)
        case .number, .bool, .null: return []
        }
    }
}
