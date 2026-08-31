import Foundation

private struct BifrostDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum BifrostDateCoding {
    static func decode<K: CodingKey>(
        _ type: Date.Type,
        forKey key: K,
        from container: KeyedDecodingContainer<K>
    ) -> Date? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: seconds)
            }
            return nil
        }
        return parse(raw)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

extension BifrostTokenUsage {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try? container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try? container.decodeIfPresent(Int.self, forKey: .completionTokens)
        totalTokens = try? container.decodeIfPresent(Int.self, forKey: .totalTokens)
        inputTokens = try? container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try? container.decodeIfPresent(Int.self, forKey: .outputTokens)

        let knownNames = Set(CodingKeys.allCases.map(\.rawValue))
        let dynamic = try decoder.container(keyedBy: BifrostDynamicCodingKey.self)
        additionalFields = Dictionary(uniqueKeysWithValues: dynamic.allKeys.compactMap { key in
            guard !knownNames.contains(key.stringValue),
                  let value = try? dynamic.decode(JSONValue.self, forKey: key) else { return nil }
            return (key.stringValue, value)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(promptTokens, forKey: .promptTokens)
        try container.encodeIfPresent(completionTokens, forKey: .completionTokens)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)

        var dynamic = encoder.container(keyedBy: BifrostDynamicCodingKey.self)
        for (name, value) in additionalFields {
            if let key = BifrostDynamicCodingKey(stringValue: name) { try dynamic.encode(value, forKey: key) }
        }
    }
}

extension BifrostLog {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case parentRequestID = "parent_request_id"
        case provider
        case selectedKeyName = "selected_key_name"
        case model
        case alias
        case object
        case timestamp
        case createdAt = "created_at"
        case status
        case latency
        case cost
        case tokenUsage = "token_usage"
        case errorDetails = "error_details"
        case stream
        case numberOfRetries = "number_of_retries"
        case fallbackIndex = "fallback_index"
        case stopReason = "stop_reason"
        case rawRequest = "raw_request"
        case rawResponse = "raw_response"
        case isLargePayloadRequest = "is_large_payload_request"
        case isLargePayloadResponse = "is_large_payload_response"
        case passthroughRequestBody = "passthrough_request_body"
        case passthroughResponseBody = "passthrough_response_body"
        case inputHistory = "input_history"
        case responsesInputHistory = "responses_input_history"
        case outputMessage = "output_message"
        case responsesOutput = "responses_output"
        case params
        case tools
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        parentRequestID = try? container.decodeIfPresent(String.self, forKey: .parentRequestID)
        provider = (try? container.decodeIfPresent(String.self, forKey: .provider)) ?? ""
        selectedKeyName = try? container.decodeIfPresent(String.self, forKey: .selectedKeyName)
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
        alias = try? container.decodeIfPresent(String.self, forKey: .alias)
        object = try? container.decodeIfPresent(String.self, forKey: .object)
        timestamp = BifrostDateCoding.decode(Date.self, forKey: .timestamp, from: container)
        createdAt = BifrostDateCoding.decode(Date.self, forKey: .createdAt, from: container)
        if let rawStatus = try? container.decodeIfPresent(String.self, forKey: .status) {
            status = BifrostLogStatus(rawValue: rawStatus)
        } else {
            status = .unknown("")
        }
        latency = try? container.decodeIfPresent(Double.self, forKey: .latency)
        cost = try? container.decodeIfPresent(Double.self, forKey: .cost)
        tokenUsage = try? container.decodeIfPresent(BifrostTokenUsage.self, forKey: .tokenUsage)
        errorDetails = try? container.decodeIfPresent(JSONValue.self, forKey: .errorDetails)
        stream = try? container.decodeIfPresent(Bool.self, forKey: .stream)
        numberOfRetries = try? container.decodeIfPresent(Int.self, forKey: .numberOfRetries)
        fallbackIndex = try? container.decodeIfPresent(Int.self, forKey: .fallbackIndex)
        stopReason = try? container.decodeIfPresent(String.self, forKey: .stopReason)
        rawRequest = try? container.decodeIfPresent(String.self, forKey: .rawRequest)
        rawResponse = try? container.decodeIfPresent(String.self, forKey: .rawResponse)
        isLargePayloadRequest = (try? container.decodeIfPresent(Bool.self, forKey: .isLargePayloadRequest)) ?? false
        isLargePayloadResponse = (try? container.decodeIfPresent(Bool.self, forKey: .isLargePayloadResponse)) ?? false
        passthroughRequestBody = try? container.decodeIfPresent(String.self, forKey: .passthroughRequestBody)
        passthroughResponseBody = try? container.decodeIfPresent(String.self, forKey: .passthroughResponseBody)
        inputHistory = try? container.decodeIfPresent(JSONValue.self, forKey: .inputHistory)
        responsesInputHistory = try? container.decodeIfPresent(JSONValue.self, forKey: .responsesInputHistory)
        outputMessage = try? container.decodeIfPresent(JSONValue.self, forKey: .outputMessage)
        responsesOutput = try? container.decodeIfPresent(JSONValue.self, forKey: .responsesOutput)
        params = try? container.decodeIfPresent(JSONValue.self, forKey: .params)
        tools = try? container.decodeIfPresent(JSONValue.self, forKey: .tools)
        toolCalls = try? container.decodeIfPresent(JSONValue.self, forKey: .toolCalls)

        let knownNames = Set(CodingKeys.allCases.map(\.rawValue))
        let dynamic = try decoder.container(keyedBy: BifrostDynamicCodingKey.self)
        additionalFields = Dictionary(uniqueKeysWithValues: dynamic.allKeys.compactMap { key in
            guard !knownNames.contains(key.stringValue),
                  let value = try? dynamic.decode(JSONValue.self, forKey: key) else { return nil }
            return (key.stringValue, value)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(parentRequestID, forKey: .parentRequestID)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(selectedKeyName, forKey: .selectedKeyName)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encodeIfPresent(object, forKey: .object)
        if let timestamp { try container.encode(BifrostDateCoding.encode(timestamp), forKey: .timestamp) }
        if let createdAt { try container.encode(BifrostDateCoding.encode(createdAt), forKey: .createdAt) }
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(latency, forKey: .latency)
        try container.encodeIfPresent(cost, forKey: .cost)
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(errorDetails, forKey: .errorDetails)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(numberOfRetries, forKey: .numberOfRetries)
        try container.encodeIfPresent(fallbackIndex, forKey: .fallbackIndex)
        try container.encodeIfPresent(stopReason, forKey: .stopReason)
        try container.encodeIfPresent(rawRequest, forKey: .rawRequest)
        try container.encodeIfPresent(rawResponse, forKey: .rawResponse)
        try container.encode(isLargePayloadRequest, forKey: .isLargePayloadRequest)
        try container.encode(isLargePayloadResponse, forKey: .isLargePayloadResponse)
        try container.encodeIfPresent(passthroughRequestBody, forKey: .passthroughRequestBody)
        try container.encodeIfPresent(passthroughResponseBody, forKey: .passthroughResponseBody)
        try container.encodeIfPresent(inputHistory, forKey: .inputHistory)
        try container.encodeIfPresent(responsesInputHistory, forKey: .responsesInputHistory)
        try container.encodeIfPresent(outputMessage, forKey: .outputMessage)
        try container.encodeIfPresent(responsesOutput, forKey: .responsesOutput)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)

        var dynamic = encoder.container(keyedBy: BifrostDynamicCodingKey.self)
        for (name, value) in additionalFields {
            if let key = BifrostDynamicCodingKey(stringValue: name) { try dynamic.encode(value, forKey: key) }
        }
    }
}

extension BifrostLogPagination {
    private enum CodingKeys: String, CodingKey {
        case limit, offset, order
        case sortBy = "sort_by"
        case totalCount = "total_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = (try? container.decodeIfPresent(Int.self, forKey: .limit)) ?? 0
        offset = (try? container.decodeIfPresent(Int.self, forKey: .offset)) ?? 0
        sortBy = (try? container.decodeIfPresent(String.self, forKey: .sortBy)) ?? "timestamp"
        order = (try? container.decodeIfPresent(String.self, forKey: .order)) ?? "desc"
        totalCount = (try? container.decodeIfPresent(Int.self, forKey: .totalCount)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(limit, forKey: .limit)
        try container.encode(offset, forKey: .offset)
        try container.encode(sortBy, forKey: .sortBy)
        try container.encode(order, forKey: .order)
        try container.encode(totalCount, forKey: .totalCount)
    }
}

extension BifrostLogStats {
    private enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalCost = "total_cost"
        case averageLatency = "average_latency"
        case successRate = "success_rate"
        case userFacingSuccessRate = "user_facing_success_rate"
        case userFacingTotalRequests = "user_facing_total_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalRequests = (try? container.decodeIfPresent(Int.self, forKey: .totalRequests)) ?? 0
        totalTokens = (try? container.decodeIfPresent(Int.self, forKey: .totalTokens)) ?? 0
        promptTokens = (try? container.decodeIfPresent(Int.self, forKey: .promptTokens)) ?? 0
        completionTokens = (try? container.decodeIfPresent(Int.self, forKey: .completionTokens)) ?? 0
        totalCost = (try? container.decodeIfPresent(Double.self, forKey: .totalCost)) ?? 0
        averageLatency = try? container.decodeIfPresent(Double.self, forKey: .averageLatency)
        successRate = try? container.decodeIfPresent(Double.self, forKey: .successRate)
        userFacingSuccessRate = try? container.decodeIfPresent(Double.self, forKey: .userFacingSuccessRate)
        userFacingTotalRequests = try? container.decodeIfPresent(Int.self, forKey: .userFacingTotalRequests)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalRequests, forKey: .totalRequests)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encode(totalCost, forKey: .totalCost)
        try container.encodeIfPresent(averageLatency, forKey: .averageLatency)
        try container.encodeIfPresent(successRate, forKey: .successRate)
        try container.encodeIfPresent(userFacingSuccessRate, forKey: .userFacingSuccessRate)
        try container.encodeIfPresent(userFacingTotalRequests, forKey: .userFacingTotalRequests)
    }
}

extension BifrostLogPage {
    private enum CodingKeys: String, CodingKey {
        case logs, pagination, stats
        case hasLogs = "has_logs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logs = (try? container.decodeIfPresent([BifrostLog].self, forKey: .logs)) ?? []
        pagination = (try? container.decodeIfPresent(BifrostLogPagination.self, forKey: .pagination))
            ?? BifrostLogPagination(totalCount: logs.count)
        hasLogs = (try? container.decodeIfPresent(Bool.self, forKey: .hasLogs)) ?? !logs.isEmpty
        stats = try? container.decodeIfPresent(BifrostLogStats.self, forKey: .stats)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logs, forKey: .logs)
        try container.encode(pagination, forKey: .pagination)
        try container.encode(hasLogs, forKey: .hasLogs)
        try container.encodeIfPresent(stats, forKey: .stats)
    }
}
