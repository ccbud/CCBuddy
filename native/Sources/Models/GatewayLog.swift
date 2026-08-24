import Foundation

/// Lifecycle state derived from the gateway's HTTP result. The management API deliberately keeps
/// the wire status numeric, while Monitor benefits from a small presentation-oriented state.
enum GatewayLogStatus: Equatable, Hashable {
    case processing
    case success
    case error
    case unknown(String)

    var isProcessing: Bool { self == .processing }
    var isTerminal: Bool { self == .success || self == .error }
    var isSuccess: Bool { self == .success }
    var isError: Bool { self == .error }
}

/// One exact message boundary captured by `ccbud-gateway`.
struct GatewayCapturedMessage: Codable, Equatable {
    var headers: JSONValue
    var body: String
    var truncated: Bool

    init(
        headers: JSONValue = .object([:]),
        body: String = "",
        truncated: Bool = false
    ) {
        self.headers = headers
        self.body = body
        self.truncated = truncated
    }
}

/// A request held by the helper's bounded in-memory monitor ring.
///
/// IDs are strings at the app boundary so SwiftUI identity and URL construction stay lossless.
/// The decoder accepts the helper's native unsigned integer representation as well as a numeric
/// string, which keeps fixtures and forward-compatible management transports interoperable.
struct GatewayLog: Codable, Identifiable, Equatable {
    var id: String
    var startedAt: Date?
    var elapsedMs: Double?
    var method: String
    var path: String
    var httpStatusCode: Int?
    var clientModel: String?
    var providerID: String?
    var providerName: String?
    var attempts: Int
    var translation: String?
    var error: String?
    var clientRequest: GatewayCapturedMessage?
    var upstreamRequest: GatewayCapturedMessage?
    var upstreamResponse: GatewayCapturedMessage?
    var clientResponse: GatewayCapturedMessage?

    init(
        id: String,
        startedAt: Date? = nil,
        elapsedMs: Double? = nil,
        method: String = "POST",
        path: String = "",
        httpStatusCode: Int? = nil,
        clientModel: String? = nil,
        providerID: String? = nil,
        providerName: String? = nil,
        attempts: Int = 0,
        translation: String? = nil,
        error: String? = nil,
        clientRequest: GatewayCapturedMessage? = nil,
        upstreamRequest: GatewayCapturedMessage? = nil,
        upstreamResponse: GatewayCapturedMessage? = nil,
        clientResponse: GatewayCapturedMessage? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.elapsedMs = elapsedMs
        self.method = method
        self.path = path
        self.httpStatusCode = httpStatusCode
        self.clientModel = clientModel
        self.providerID = providerID
        self.providerName = providerName
        self.attempts = attempts
        self.translation = translation
        self.error = error
        self.clientRequest = clientRequest
        self.upstreamRequest = upstreamRequest
        self.upstreamResponse = upstreamResponse
        self.clientResponse = clientResponse
    }

    var status: GatewayLogStatus {
        if error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .error
        }
        guard let httpStatusCode else { return .processing }
        return (200..<400).contains(httpStatusCode) ? .success : .error
    }

    var isProcessing: Bool { status.isProcessing }
    var isTerminal: Bool { status.isTerminal }
    var isSuccess: Bool { status.isSuccess }
    var isError: Bool { status.isError }
    var latency: Double? { elapsedMs }
    var monitorTimestamp: Date { startedAt ?? .distantPast }
    var numberOfRetries: Int? { attempts > 0 ? max(0, attempts - 1) : nil }
    var errorStatusCode: Int? { isError ? httpStatusCode : nil }
    var requestedModel: String { clientModel?.trimmedNonempty ?? "" }

    /// The upstream model can differ after model mapping. It is read only from the captured
    /// upstream request; absent or non-JSON bodies are never guessed.
    var outgoingModel: String {
        guard let body = upstreamRequest?.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = object["model"] as? String,
              let model = model.trimmedNonempty
        else { return requestedModel }
        return model
    }

    var displayProvider: String {
        providerName?.trimmedNonempty ?? providerID?.trimmedNonempty ?? ""
    }

    var routeLabel: String {
        [method.trimmedNonempty, path.trimmedNonempty]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var stream: Bool? {
        guard let data = clientRequest?.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["stream"] as? Bool
    }
}

struct GatewayLogPage: Codable, Equatable {
    var logs: [GatewayLog]

    init(logs: [GatewayLog] = []) {
        self.logs = logs
    }

    private enum CodingKeys: String, CodingKey {
        case logs = "data"
    }
}

struct GatewayProviderStatus: Codable, Equatable {
    var id: String
    var name: String
    var circuit: JSONValue?
}

struct GatewayStatus: Codable, Equatable {
    var running: Bool
    var publicPort: Int
    var managementPort: Int
    var uptimeSeconds: UInt64
    var activeConnections: UInt64
    var totalRequests: UInt64
    var successfulRequests: UInt64
    var failedRequests: UInt64
    var providers: [GatewayProviderStatus]

    init(
        running: Bool = false,
        publicPort: Int = 0,
        managementPort: Int = 0,
        uptimeSeconds: UInt64 = 0,
        activeConnections: UInt64 = 0,
        totalRequests: UInt64 = 0,
        successfulRequests: UInt64 = 0,
        failedRequests: UInt64 = 0,
        providers: [GatewayProviderStatus] = []
    ) {
        self.running = running
        self.publicPort = publicPort
        self.managementPort = managementPort
        self.uptimeSeconds = uptimeSeconds
        self.activeConnections = activeConnections
        self.totalRequests = totalRequests
        self.successfulRequests = successfulRequests
        self.failedRequests = failedRequests
        self.providers = providers
    }
}

/// Monitor-ready metrics. Request totals come from `/status`; latency is calculated from the
/// currently visible ring because the helper does not expose a persisted aggregate endpoint.
struct GatewayLogStats: Equatable {
    var totalRequests: Int
    var totalTokens: Int
    var promptTokens: Int
    var completionTokens: Int
    var totalCost: Double
    var averageLatency: Double?
    var successRate: Double?

    init(
        totalRequests: Int = 0,
        totalTokens: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalCost: Double = 0,
        averageLatency: Double? = nil,
        successRate: Double? = nil
    ) {
        self.totalRequests = totalRequests
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalCost = totalCost
        self.averageLatency = averageLatency
        self.successRate = successRate
    }

    init(status: GatewayStatus, logs: [GatewayLog]) {
        let latencies = logs.compactMap(\.elapsedMs).filter(\.isFinite)
        self.init(
            totalRequests: Int(clamping: status.totalRequests),
            averageLatency: latencies.isEmpty
                ? nil
                : latencies.reduce(0, +) / Double(latencies.count),
            successRate: status.totalRequests > 0
                ? Double(status.successfulRequests) / Double(status.totalRequests) * 100
                : nil
        )
    }

    var rootRequestCount: Int { totalRequests }
    var rootSuccessRate: Double? { successRate }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
