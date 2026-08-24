import Foundation

struct GatewayAPIErrorEnvelope: Decodable, Equatable {
    var error: JSONValue?

    var message: String? {
        Self.message(from: error)
    }

    private static func message(from value: JSONValue?) -> String? {
        switch value {
        case .string(let message):
            return message
        case .object(let fields):
            return fields["message"]?.stringValue
                ?? message(from: fields["error"])
                ?? fields["detail"]?.stringValue
        default:
            return nil
        }
    }
}

enum GatewayManagementError: LocalizedError, Equatable {
    case invalidBaseURL(URL)
    case invalidLimit(Int)
    case invalidLogID
    case invalidResponse
    case decoding(String)
    case api(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            "无效的网关管理地址：\(url.absoluteString)"
        case .invalidLimit(let limit):
            "日志分页 limit 必须在 1...500，当前为 \(limit)"
        case .invalidLogID:
            "日志 ID 必须是无符号整数"
        case .invalidResponse:
            "网关返回了无效的 HTTP 响应"
        case .decoding(let detail):
            "无法解析网关响应：\(detail)"
        case .api(let statusCode, let message):
            "网关请求失败（HTTP \(statusCode)）：\(message)"
        }
    }
}

/// An opaque management destination captured before an async operation begins.
struct GatewayManagementEndpointSnapshot: Sendable {
    fileprivate let baseURL: URL
}

/// Authenticated client for the helper's private management listener.
///
/// The supervisor owns the shared endpoint and publishes the kernel-selected port only after a
/// verified ready event. Each request snapshots that endpoint synchronously so a restart cannot
/// redirect an in-flight operation to a different helper instance.
final class GatewayManagementClient: @unchecked Sendable {
    static let maximumPageSize = 500

    private let session: URLSession
    private let authorizationHeader: String
    private let endpoint: GatewayManagementEndpoint

    var baseURL: URL { endpoint.baseURL }

    init(
        port _: Int,
        credentials: GatewayManagementCredentials,
        session: URLSession = .shared
    ) {
        endpoint = credentials.endpoint
        authorizationHeader = credentials.authorizationHeader
        self.session = session
    }

    init(
        credentials: GatewayManagementCredentials,
        session: URLSession = .shared
    ) {
        endpoint = credentials.endpoint
        authorizationHeader = credentials.authorizationHeader
        self.session = session
    }

    /// Basic authentication remains available for independently hosted compatible helpers.
    init(
        port: Int,
        username: String,
        password: String,
        session: URLSession = .shared
    ) {
        let endpoint = GatewayManagementEndpoint()
        endpoint.update(port: port)
        self.endpoint = endpoint
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        authorizationHeader = "Basic \(token)"
        self.session = session
    }

    /// Test-only compatibility hook. Production updates arrive through the shared endpoint owned
    /// by `GatewayManagementCredentials` after the helper's ready event is authenticated.
    func updatePort(_ port: Int) {
        endpoint.update(port: port)
    }

    func snapshotEndpoint() -> GatewayManagementEndpointSnapshot {
        GatewayManagementEndpointSnapshot(baseURL: endpoint.baseURL)
    }

    func fetchLogs(
        limit: Int = 100,
        before: UInt64? = nil
    ) async throws -> GatewayLogPage {
        try await fetchLogs(limit: limit, before: before, pinnedTo: snapshotEndpoint())
    }

    func fetchLogs(
        limit: Int,
        before: UInt64? = nil,
        pinnedTo snapshot: GatewayManagementEndpointSnapshot
    ) async throws -> GatewayLogPage {
        guard (1...Self.maximumPageSize).contains(limit) else {
            throw GatewayManagementError.invalidLimit(limit)
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: String(before)))
        }
        return try await send(
            pathComponents: ["logs"],
            queryItems: queryItems,
            endpoint: snapshot.baseURL,
            as: GatewayLogPage.self
        )
    }

    func fetchLogDetail(id: String) async throws -> GatewayLog {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericID = UInt64(id) else { throw GatewayManagementError.invalidLogID }
        let snapshot = snapshotEndpoint()
        return try await send(
            pathComponents: ["logs", String(numericID)],
            endpoint: snapshot.baseURL,
            as: GatewayLog.self
        )
    }

    func fetchStatus() async throws -> GatewayStatus {
        let snapshot = snapshotEndpoint()
        return try await send(
            pathComponents: ["status"],
            endpoint: snapshot.baseURL,
            as: GatewayStatus.self
        )
    }

    @discardableResult
    func clearLogs() async throws -> Int {
        try await clearLogs(pinnedTo: snapshotEndpoint())
    }

    @discardableResult
    func clearLogs(pinnedTo snapshot: GatewayManagementEndpointSnapshot) async throws -> Int {
        let response = try await send(
            pathComponents: ["logs", "clear"],
            method: "POST",
            endpoint: snapshot.baseURL,
            as: ClearLogsResponse.self
        )
        return max(0, response.cleared)
    }

    private func send<Response: Decodable>(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        endpoint: URL,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await request(
            pathComponents: pathComponents,
            queryItems: queryItems,
            method: method,
            endpoint: endpoint
        )
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GatewayManagementError.decoding(String(describing: error))
        }
    }

    private func request(
        pathComponents: [String],
        queryItems: [URLQueryItem],
        method: String,
        endpoint: URL
    ) async throws -> Data {
        let url = try makeURL(
            endpoint: endpoint,
            pathComponents: pathComponents,
            queryItems: queryItems
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GatewayManagementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.managementError(statusCode: httpResponse.statusCode, data: data)
        }
        return data
    }

    private func makeURL(
        endpoint: URL,
        pathComponents: [String],
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var url = endpoint
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            throw GatewayManagementError.invalidBaseURL(url)
        }
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GatewayManagementError.invalidBaseURL(url)
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else {
            throw GatewayManagementError.invalidBaseURL(url)
        }
        return result
    }

    private static func managementError(statusCode: Int, data: Data) -> GatewayManagementError {
        let envelope = try? JSONDecoder().decode(GatewayAPIErrorEnvelope.self, from: data)
        let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = envelope?.message
            ?? (fallback?.isEmpty == false
                ? fallback!
                : HTTPURLResponse.localizedString(forStatusCode: statusCode))
        return .api(statusCode: statusCode, message: message)
    }

    private struct ClearLogsResponse: Decodable {
        let cleared: Int
    }
}
