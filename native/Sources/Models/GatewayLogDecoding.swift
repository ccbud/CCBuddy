import Foundation

private enum GatewayDateCoding {
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

extension GatewayLog {
    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case elapsedMs
        case method
        case path
        case httpStatusCode = "status"
        case clientModel
        case providerID = "providerId"
        case providerName
        case attempts
        case translation
        case error
        case clientRequest
        case upstreamRequest
        case upstreamResponse
        case clientResponse
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericID = try? container.decode(UInt64.self, forKey: .id) {
            id = String(numericID)
        } else {
            id = (try? container.decode(String.self, forKey: .id)) ?? ""
        }
        if let rawDate = try? container.decode(String.self, forKey: .startedAt) {
            startedAt = GatewayDateCoding.parse(rawDate)
        } else if let seconds = try? container.decode(Double.self, forKey: .startedAt) {
            startedAt = Date(timeIntervalSince1970: seconds)
        } else {
            startedAt = nil
        }
        elapsedMs = try? container.decodeIfPresent(Double.self, forKey: .elapsedMs)
        method = (try? container.decode(String.self, forKey: .method)) ?? ""
        path = (try? container.decode(String.self, forKey: .path)) ?? ""
        httpStatusCode = try? container.decodeIfPresent(Int.self, forKey: .httpStatusCode)
        clientModel = try? container.decodeIfPresent(String.self, forKey: .clientModel)
        providerID = try? container.decodeIfPresent(String.self, forKey: .providerID)
        providerName = try? container.decodeIfPresent(String.self, forKey: .providerName)
        attempts = (try? container.decode(Int.self, forKey: .attempts)) ?? 0
        translation = try? container.decodeIfPresent(String.self, forKey: .translation)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        clientRequest = try? container.decodeIfPresent(GatewayCapturedMessage.self, forKey: .clientRequest)
        upstreamRequest = try? container.decodeIfPresent(GatewayCapturedMessage.self, forKey: .upstreamRequest)
        upstreamResponse = try? container.decodeIfPresent(GatewayCapturedMessage.self, forKey: .upstreamResponse)
        clientResponse = try? container.decodeIfPresent(GatewayCapturedMessage.self, forKey: .clientResponse)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let numericID = UInt64(id) {
            try container.encode(numericID, forKey: .id)
        } else {
            try container.encode(id, forKey: .id)
        }
        if let startedAt {
            try container.encode(GatewayDateCoding.encode(startedAt), forKey: .startedAt)
        }
        try container.encodeIfPresent(elapsedMs, forKey: .elapsedMs)
        try container.encode(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(httpStatusCode, forKey: .httpStatusCode)
        try container.encodeIfPresent(clientModel, forKey: .clientModel)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(providerName, forKey: .providerName)
        try container.encode(attempts, forKey: .attempts)
        try container.encodeIfPresent(translation, forKey: .translation)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(clientRequest, forKey: .clientRequest)
        try container.encodeIfPresent(upstreamRequest, forKey: .upstreamRequest)
        try container.encodeIfPresent(upstreamResponse, forKey: .upstreamResponse)
        try container.encodeIfPresent(clientResponse, forKey: .clientResponse)
    }
}
