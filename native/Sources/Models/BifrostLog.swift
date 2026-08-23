import Foundation

/// Private request provenance carried through Bifrost's logging-header facility. The caller can
/// reach the loopback gateway directly, so the proxy always removes this header before adding its
/// own value. Encoding the model keeps arbitrary Unicode safe in an HTTP field value and prevents
/// CR/LF from becoming header syntax.
enum LegacyRequestedModelMetadata {
    static let headerName = "x-bf-lh-ccbud-requested-model-b64"
    static let metadataKey = "ccbud-requested-model-b64"

    static func encode(_ model: String) -> String {
        Data(model.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ encoded: String) -> String? {
        guard !encoded.contains(where: { $0.isWhitespace }) else { return nil }
        var standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.utf8.count % 4
        if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: standard),
              let model = String(data: data, encoding: .utf8) else { return nil }
        return model
    }
}

/// The lifecycle state reported by Bifrost for a request log.
///
/// Bifrost can add states independently of the app, so unknown values are retained instead of
/// making the whole page fail to decode.
enum BifrostLogStatus: Equatable, Hashable, Codable {
    case processing
    case success
    case error
    case cancelled
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "processing": self = .processing
        case "success": self = .success
        case "error": self = .error
        case "cancelled", "canceled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .processing: "processing"
        case .success: "success"
        case .error: "error"
        case .cancelled: "cancelled"
        case .unknown(let value): value
        }
    }

    var isProcessing: Bool { self == .processing }

    var isTerminal: Bool {
        switch self {
        case .success, .error, .cancelled: true
        case .processing, .unknown: false
        }
    }

    var isSuccess: Bool { self == .success }
    var isError: Bool { self == .error }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct BifrostTokenUsage: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var additionalFields: [String: JSONValue]

    init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.additionalFields = additionalFields
    }
}

/// A Bifrost request log. IDs intentionally remain strings: although current Bifrost builds use
/// UUIDs, converting them to `UUID` would reject forward-compatible identifiers.
struct BifrostLog: Codable, Identifiable, Equatable {
    var id: String
    var parentRequestID: String?
    var provider: String
    var selectedKeyName: String?
    var model: String
    var alias: String?
    var object: String?
    var timestamp: Date?
    var createdAt: Date?
    var status: BifrostLogStatus
    var latency: Double?
    var cost: Double?
    var tokenUsage: BifrostTokenUsage?
    var errorDetails: JSONValue?
    var stream: Bool?
    var numberOfRetries: Int?
    var fallbackIndex: Int?
    var stopReason: String?

    // Provider wire payloads. Bifrost returns these only from the detail endpoint.
    var rawRequest: String?
    var rawResponse: String?

    // Pinned Bifrost v1.6.11 large-payload and passthrough fields. A large-payload flag means the
    // served content is only a preview; Bifrost does not report the original byte count.
    var isLargePayloadRequest: Bool
    var isLargePayloadResponse: Bool
    var passthroughRequestBody: String?
    var passthroughResponseBody: String?

    // Normalized Bifrost payloads. JSONValue keeps provider-specific content lossless.
    var inputHistory: JSONValue?
    var responsesInputHistory: JSONValue?
    var outputMessage: JSONValue?
    var responsesOutput: JSONValue?
    var params: JSONValue?
    var tools: JSONValue?
    var toolCalls: JSONValue?

    /// Fields introduced by providers or newer Bifrost versions that this app does not model yet.
    var additionalFields: [String: JSONValue]

    init(
        id: String,
        parentRequestID: String? = nil,
        provider: String = "",
        selectedKeyName: String? = nil,
        model: String = "",
        alias: String? = nil,
        object: String? = nil,
        timestamp: Date? = nil,
        createdAt: Date? = nil,
        status: BifrostLogStatus = .unknown(""),
        latency: Double? = nil,
        cost: Double? = nil,
        tokenUsage: BifrostTokenUsage? = nil,
        errorDetails: JSONValue? = nil,
        stream: Bool? = nil,
        numberOfRetries: Int? = nil,
        fallbackIndex: Int? = nil,
        stopReason: String? = nil,
        rawRequest: String? = nil,
        rawResponse: String? = nil,
        isLargePayloadRequest: Bool = false,
        isLargePayloadResponse: Bool = false,
        passthroughRequestBody: String? = nil,
        passthroughResponseBody: String? = nil,
        inputHistory: JSONValue? = nil,
        responsesInputHistory: JSONValue? = nil,
        outputMessage: JSONValue? = nil,
        responsesOutput: JSONValue? = nil,
        params: JSONValue? = nil,
        tools: JSONValue? = nil,
        toolCalls: JSONValue? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.parentRequestID = parentRequestID
        self.provider = provider
        self.selectedKeyName = selectedKeyName
        self.model = model
        self.alias = alias
        self.object = object
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.status = status
        self.latency = latency
        self.cost = cost
        self.tokenUsage = tokenUsage
        self.errorDetails = errorDetails
        self.stream = stream
        self.numberOfRetries = numberOfRetries
        self.fallbackIndex = fallbackIndex
        self.stopReason = stopReason
        self.rawRequest = rawRequest
        self.rawResponse = rawResponse
        self.isLargePayloadRequest = isLargePayloadRequest
        self.isLargePayloadResponse = isLargePayloadResponse
        self.passthroughRequestBody = passthroughRequestBody
        self.passthroughResponseBody = passthroughResponseBody
        self.inputHistory = inputHistory
        self.responsesInputHistory = responsesInputHistory
        self.outputMessage = outputMessage
        self.responsesOutput = responsesOutput
        self.params = params
        self.tools = tools
        self.toolCalls = toolCalls
        self.additionalFields = additionalFields
    }

    var isProcessing: Bool { status.isProcessing }
    var isTerminal: Bool { status.isTerminal }
    var isSuccess: Bool { status.isSuccess }
    var isError: Bool { status.isError }

    var requestedModel: String {
        guard let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty else {
            return model
        }
        return alias
    }

    var outgoingModel: String { model }

    var displayProvider: String {
        guard let selectedKeyName = selectedKeyName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedKeyName.isEmpty else { return provider }
        return selectedKeyName
    }

    /// Bifrost records a real upstream HTTP status only inside `error_details`. Missing values are
    /// kept nil; the UI must not infer one from lifecycle state or response content.
    var errorStatusCode: Int? {
        guard case .object(let details) = errorDetails,
              case .number(let value)? = details["status_code"],
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max)
        else { return nil }
        return Int(value)
    }

    var httpStatusCode: Int? { errorStatusCode }

    /// The actual normalized request fragments returned by Bifrost. This never fabricates HTTP
    /// headers or a request status. When several fragments exist their original API field names
    /// are retained in an object.
    var normalizedRequest: JSONValue? {
        normalizedPayload([
            "input_history": inputHistory,
            "responses_input_history": responsesInputHistory,
            "params": params,
            "tools": tools,
            "tool_calls": toolCalls,
            "passthrough_request_body": passthroughRequestBody.map(JSONValue.string),
        ], additionalFieldNames: Self.providerRequestFields)
    }

    /// The actual normalized response fragments returned by Bifrost. Provider-specific output
    /// fields are included without imposing an app-owned response schema.
    var normalizedResponse: JSONValue? {
        normalizedPayload([
            "output_message": outputMessage,
            "responses_output": responsesOutput,
            "error_details": errorDetails,
            "passthrough_response_body": passthroughResponseBody.map(JSONValue.string),
        ], additionalFieldNames: Self.providerResponseFields)
    }

    private func normalizedPayload(
        _ known: [String: JSONValue?],
        additionalFieldNames: Set<String>
    ) -> JSONValue? {
        var fields = known.compactMapValues { $0 }
        for name in additionalFieldNames {
            if let value = additionalFields[name] { fields[name] = value }
        }
        guard !fields.isEmpty else { return nil }
        if fields.count == 1 { return fields.values.first }
        return .object(fields)
    }

    private static let providerRequestFields: Set<String> = [
        "speech_input", "transcription_input", "image_generation_input", "image_edit_input",
        "image_variation_input", "video_generation_input", "ocr_input",
    ]

    private static let providerResponseFields: Set<String> = [
        "embedding_output", "rerank_output", "ocr_output", "speech_output", "transcription_output",
        "image_generation_output", "video_generation_output", "video_retrieve_output",
        "video_download_output", "video_list_output", "video_delete_output", "list_models_output",
    ]
}

extension BifrostLog {
    /// Restores the model Bifrost actually received from the trusted proxy metadata. Native
    /// aliases already populate `alias`; assigning again is harmless and gives proxy-routed
    /// wildcard-family requests the same Monitor identity as the legacy Rust gateway.
    func restoringLegacyRequestedModel() -> BifrostLog {
        guard let encoded = legacyRequestedModelMetadataValue,
              let requestedModel = LegacyRequestedModelMetadata.decode(encoded) else {
            return self
        }
        var restored = self
        restored.alias = requestedModel
        return restored
    }

    private var legacyRequestedModelMetadataValue: String? {
        guard let metadata = additionalFields["metadata"] else { return nil }
        switch metadata {
        case .object(let object):
            return object[LegacyRequestedModelMetadata.metadataKey]?.stringValue
        case .string(let text):
            // SQLite-backed management responses normally expose an object, but tolerate a raw
            // JSON string so list/detail normalization survives older logging-store encoders.
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object[LegacyRequestedModelMetadata.metadataKey] as? String
        default:
            return nil
        }
    }
}

struct BifrostLogPagination: Codable, Equatable {
    var limit: Int
    var offset: Int
    var sortBy: String
    var order: String
    var totalCount: Int

    init(
        limit: Int = 0,
        offset: Int = 0,
        sortBy: String = "timestamp",
        order: String = "desc",
        totalCount: Int = 0
    ) {
        self.limit = limit
        self.offset = offset
        self.sortBy = sortBy
        self.order = order
        self.totalCount = totalCount
    }
}

struct BifrostLogStats: Codable, Equatable {
    var totalRequests: Int
    var totalTokens: Int
    var promptTokens: Int
    var completionTokens: Int
    var totalCost: Double
    var averageLatency: Double?
    var successRate: Double?
    var userFacingSuccessRate: Double?
    var userFacingTotalRequests: Int?

    init(
        totalRequests: Int = 0,
        totalTokens: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalCost: Double = 0,
        averageLatency: Double? = nil,
        successRate: Double? = nil,
        userFacingSuccessRate: Double? = nil,
        userFacingTotalRequests: Int? = nil
    ) {
        self.totalRequests = totalRequests
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalCost = totalCost
        self.averageLatency = averageLatency
        self.successRate = successRate
        self.userFacingSuccessRate = userFacingSuccessRate
        self.userFacingTotalRequests = userFacingTotalRequests
    }

    /// Headline request metrics should describe root user requests, not each provider attempt in a
    /// fallback chain. Older Bifrost versions omit the user-facing variants, so retain the attempt
    /// fields as a compatibility fallback.
    var rootRequestCount: Int { userFacingTotalRequests ?? totalRequests }
    var rootSuccessRate: Double? { userFacingSuccessRate ?? successRate }
}

struct BifrostLogPage: Codable, Equatable {
    var logs: [BifrostLog]
    var pagination: BifrostLogPagination
    var hasLogs: Bool
    /// Kept for compatibility with Bifrost builds that embed stats in the list response. Monitor
    /// refreshes stats from `/api/logs/stats`, so this value is never required.
    var stats: BifrostLogStats?

    init(
        logs: [BifrostLog] = [],
        pagination: BifrostLogPagination = .init(),
        hasLogs: Bool = false,
        stats: BifrostLogStats? = nil
    ) {
        self.logs = logs
        self.pagination = pagination
        self.hasLogs = hasLogs
        self.stats = stats
    }
}
