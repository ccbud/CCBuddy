import Foundation

struct BifrostAPIErrorEnvelope: Decodable, Equatable {
    var isBifrostError: Bool?
    var statusCode: Int?
    var eventID: String?
    var error: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case isBifrostError = "is_bifrost_error"
        case statusCode = "status_code"
        case eventID = "event_id"
        case error
    }

    var message: String? {
        Self.message(from: error)
    }

    var resolvedEventID: String? {
        if let eventID, !eventID.isEmpty { return eventID }
        guard case .object(let fields) = error else { return nil }
        return fields["event_id"]?.stringValue
    }

    private static func message(from value: JSONValue?) -> String? {
        switch value {
        case .string(let message): return message
        case .object(let fields):
            return fields["message"]?.stringValue
                ?? message(from: fields["error"])
                ?? fields["detail"]?.stringValue
        default: return nil
        }
    }
}

enum BifrostManagementError: LocalizedError, Equatable {
    case invalidBaseURL(URL)
    case invalidPort(Int)
    case invalidLimit(Int)
    case invalidOffset(Int)
    case invalidLogID
    case invalidResponse
    case decoding(String)
    case api(statusCode: Int, message: String, eventID: String?)
    case paginationDidNotAdvance

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): "无效的 Bifrost 管理地址：\(url.absoluteString)"
        case .invalidPort(let port): "无效的 Bifrost 端口：\(port)"
        case .invalidLimit(let limit): "日志分页 limit 必须在 1...1000，当前为 \(limit)"
        case .invalidOffset(let offset): "日志分页 offset 不能为负数，当前为 \(offset)"
        case .invalidLogID: "日志 ID 不能为空"
        case .invalidResponse: "Bifrost 返回了无效的 HTTP 响应"
        case .decoding(let detail): "无法解析 Bifrost 响应：\(detail)"
        case .api(let statusCode, let message, let eventID):
            if let eventID, !eventID.isEmpty {
                "Bifrost 请求失败（HTTP \(statusCode)，事件 \(eventID)）：\(message)"
            } else {
                "Bifrost 请求失败（HTTP \(statusCode)）：\(message)"
            }
        case .paginationDidNotAdvance: "Bifrost 日志分页没有继续前进"
        }
    }
}

/// A multi-batch delete is not transactional on Bifrost. Preserve the IDs whose batches returned
/// success so MonitorStore can remove only those rows instead of retaining local ghosts after a
/// later batch fails.
struct BifrostPartialLogDeleteError: LocalizedError, Equatable {
    let deletedIDs: [String]
    let failureDescription: String

    var errorDescription: String? {
        "Bifrost 日志仅部分删除（已删除 \(deletedIDs.count) 条）：\(failureDescription)"
    }
}

/// A synchronous snapshot lets an actor bind a destructive operation to the endpoint it authorized
/// before the first async executor hop. The URL stays opaque so callers cannot manufacture a
/// different destination after the operation begins.
struct BifrostManagementEndpointSnapshot: Sendable {
    fileprivate let baseURL: URL
}

/// Small authenticated client for the Bifrost management API used by Monitor.
///
/// The client is safe to retain while the gateway port changes. Every request snapshots the base
/// URL under a lock, so an in-flight request keeps its original destination while subsequent ones
/// use the new port.
final class BifrostManagementClient: @unchecked Sendable {
    static let maximumPageSize = 1_000
    static let maximumDeleteBatchSize = 200

    private let session: URLSession
    private let authorizationHeader: String
    private let stateLock = NSLock()
    private var storedBaseURL: URL

    var baseURL: URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedBaseURL
    }

    init(
        baseURL: URL,
        credentials: BifrostManagementCredentials,
        session: URLSession = .shared
    ) {
        storedBaseURL = baseURL
        authorizationHeader = credentials.basicAuthorizationHeader
        self.session = session
    }

    convenience init(
        port: Int,
        credentials: BifrostManagementCredentials,
        session: URLSession = .shared
    ) {
        self.init(
            baseURL: Self.localBaseURL(port: port),
            credentials: credentials,
            session: session
        )
    }

    init(
        baseURL: URL,
        username: String,
        password: String,
        session: URLSession = .shared
    ) {
        storedBaseURL = baseURL
        authorizationHeader = BifrostManagementCredentials(
            username: username,
            password: password
        ).basicAuthorizationHeader
        self.session = session
    }

    convenience init(
        port: Int,
        username: String,
        password: String,
        session: URLSession = .shared
    ) {
        self.init(
            baseURL: Self.localBaseURL(port: port),
            username: username,
            password: password,
            session: session
        )
    }

    func updatePort(_ port: Int) {
        guard (1...65_535).contains(port) else { return }
        updateBaseURL(Self.localBaseURL(port: port))
    }

    func updateBaseURL(_ baseURL: URL) {
        stateLock.lock()
        storedBaseURL = baseURL
        stateLock.unlock()
    }

    func snapshotEndpoint() -> BifrostManagementEndpointSnapshot {
        BifrostManagementEndpointSnapshot(baseURL: baseURL)
    }

    func fetchLogs(
        limit: Int = 100,
        offset: Int = 0,
        endTime: Date? = nil
    ) async throws -> BifrostLogPage {
        try await fetchLogs(limit: limit, offset: offset, endTime: endTime, endpoint: baseURL)
    }

    private func fetchLogs(
        limit: Int,
        offset: Int,
        endTime: Date?,
        endpoint: URL
    ) async throws -> BifrostLogPage {
        guard (1...Self.maximumPageSize).contains(limit) else {
            throw BifrostManagementError.invalidLimit(limit)
        }
        guard offset >= 0 else { throw BifrostManagementError.invalidOffset(offset) }

        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "sort_by", value: "timestamp"),
            URLQueryItem(name: "order", value: "desc"),
        ]
        if let endTime {
            queryItems.append(URLQueryItem(name: "end_time", value: Self.rfc3339(endTime)))
        }
        return try await send(
            pathComponents: ["api", "logs"],
            queryItems: queryItems,
            endpoint: endpoint,
            as: BifrostLogPage.self
        )
    }

    func fetchLogDetail(id: String) async throws -> BifrostLog {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw BifrostManagementError.invalidLogID }
        return try await send(
            pathComponents: ["api", "logs", id],
            endpoint: baseURL,
            as: BifrostLog.self
        )
    }

    func fetchLogStats(endTime: Date? = nil) async throws -> BifrostLogStats {
        let queryItems = endTime.map {
            [URLQueryItem(name: "end_time", value: Self.rfc3339($0))]
        } ?? []
        return try await send(
            pathComponents: ["api", "logs", "stats"],
            queryItems: queryItems,
            endpoint: baseURL,
            as: BifrostLogStats.self
        )
    }

    /// Deletes IDs in bounded requests. Small caller-driven deletes still issue exactly one
    /// `DELETE /api/logs` request, while a large selection cannot exceed the same safe batch size
    /// used by clear-all.
    func deleteLogs(ids: [String]) async throws {
        try await deleteLogs(ids: ids, endpoint: baseURL)
    }

    private func deleteLogs(ids: [String], endpoint: URL) async throws {
        var seen = Set<String>()
        let ids = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else { return }

        var start = 0
        var deletedIDs: [String] = []
        while start < ids.count {
            let end = min(start + Self.maximumDeleteBatchSize, ids.count)
            let batch = Array(ids[start..<end])
            do {
                try await deleteBatch(batch, endpoint: endpoint)
                deletedIDs.append(contentsOf: batch)
            } catch {
                guard !deletedIDs.isEmpty else { throw error }
                throw BifrostPartialLogDeleteError(
                    deletedIDs: deletedIDs,
                    failureDescription: error.localizedDescription
                )
            }
            start = end
        }
    }

    /// Clears the stable snapshot ending at `endTime`. IDs are collected completely before the
    /// first delete so offset pagination cannot skip rows as earlier batches disappear.
    @discardableResult
    func clearLogs(through endTime: Date = Date()) async throws -> Int {
        try await clearLogs(through: endTime, pinnedTo: snapshotEndpoint())
    }

    /// The snapshot is captured synchronously by MonitorStore on MainActor, closing the gap in
    /// which a port change could otherwise occur before this nonisolated async method starts.
    @discardableResult
    func clearLogs(
        through endTime: Date,
        pinnedTo endpointSnapshot: BifrostManagementEndpointSnapshot
    ) async throws -> Int {
        // One destructive operation must stay on the endpoint on which it began even if the app is
        // reconfigured while pagination or a delete batch is suspended.
        let endpoint = endpointSnapshot.baseURL
        var collected: [String] = []
        var seen = Set<String>()
        var offset = 0

        while true {
            let page = try await fetchLogs(
                limit: Self.maximumPageSize,
                offset: offset,
                endTime: endTime,
                endpoint: endpoint
            )
            guard !page.logs.isEmpty else { break }

            let countBeforePage = collected.count
            for log in page.logs where !log.id.isEmpty && seen.insert(log.id).inserted {
                collected.append(log.id)
            }
            offset += page.logs.count

            if page.pagination.totalCount > 0, offset >= page.pagination.totalCount { break }
            if page.logs.count < Self.maximumPageSize { break }
            if collected.count == countBeforePage {
                throw BifrostManagementError.paginationDidNotAdvance
            }
        }

        try await deleteLogs(ids: collected, endpoint: endpoint)
        return collected.count
    }

    private func deleteBatch(_ ids: [String], endpoint: URL) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(DeleteLogsBody(ids: ids))
        } catch {
            throw BifrostManagementError.decoding(String(describing: error))
        }
        _ = try await request(
            pathComponents: ["api", "logs"],
            method: "DELETE",
            body: body,
            endpoint: endpoint
        )
    }

    private func send<Response: Decodable>(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        endpoint: URL,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await request(
            pathComponents: pathComponents,
            queryItems: queryItems,
            endpoint: endpoint
        )
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BifrostManagementError.decoding(String(describing: error))
        }
    }

    private func request(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        endpoint: URL
    ) async throws -> Data {
        let url = try makeURL(
            endpoint: endpoint,
            pathComponents: pathComponents,
            queryItems: queryItems
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BifrostManagementError.invalidResponse
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
            throw BifrostManagementError.invalidBaseURL(url)
        }
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BifrostManagementError.invalidBaseURL(url)
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else { throw BifrostManagementError.invalidBaseURL(url) }
        return result
    }

    private static func managementError(statusCode: Int, data: Data) -> BifrostManagementError {
        let envelope = try? JSONDecoder().decode(BifrostAPIErrorEnvelope.self, from: data)
        let fallback = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = envelope?.message
            ?? (fallback?.isEmpty == false ? fallback! : HTTPURLResponse.localizedString(forStatusCode: statusCode))
        return .api(
            statusCode: statusCode,
            message: message,
            eventID: envelope?.resolvedEventID
        )
    }

    private static func localBaseURL(port: Int) -> URL {
        // The string is guaranteed to form a URL even for an invalid integer; callers can update
        // only to valid ports, while initialization remains non-failable for dependency injection.
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private struct DeleteLogsBody: Encodable {
        let ids: [String]
    }
}
