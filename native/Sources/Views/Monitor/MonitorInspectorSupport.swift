import Foundation

enum MonitorDetailSection: String, CaseIterable, Identifiable {
    case clientRequest
    case upstreamRequest
    case upstreamResponse
    case clientResponse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clientRequest: "客户端请求"
        case .upstreamRequest: "上游请求"
        case .upstreamResponse: "上游响应"
        case .clientResponse: "客户端响应"
        }
    }

    var shortTitle: String {
        switch self {
        case .clientRequest: "客户端请求"
        case .upstreamRequest: "上游请求"
        case .upstreamResponse: "上游响应"
        case .clientResponse: "客户端响应"
        }
    }

    var explanation: String {
        switch self {
        case .clientRequest:
            "客户端发送到本机网关的请求"
        case .upstreamRequest:
            "本机网关发往 Provider 的请求"
        case .upstreamResponse:
            "Provider 返回给本机网关的响应"
        case .clientResponse:
            "本机网关返回给客户端的响应"
        }
    }

    var isProviderWirePayload: Bool {
        self == .upstreamRequest || self == .upstreamResponse
    }
}

enum MonitorPayloadPresentation: String, CaseIterable, Identifiable {
    case pretty
    case raw

    var id: String { rawValue }
    var title: String { self == .pretty ? "格式化" : "原文" }
}

struct MonitorInspectorPayload: Equatable {
    enum Source: Equatable {
        case capturedRaw
    }

    let rawText: String
    let prettyText: String
    let source: Source
    let shownBytes: Int
    /// Nil when the helper reports a truncated preview without the original byte count.
    let totalBytes: Int?
    let isTruncated: Bool

    func text(for presentation: MonitorPayloadPresentation) -> String {
        presentation == .pretty ? prettyText : rawText
    }

    var copyIsPartial: Bool {
        isTruncated || totalBytes.map { shownBytes < $0 } == true
    }
}

enum MonitorProtocolDisposition: Equatable {
    case passthrough
    case translated(String)

    var translationLabel: String? {
        guard case .translated(let label) = self else { return nil }
        return label
    }
}

/// Presents the helper's four exact capture boundaries without inferring missing traffic.
struct MonitorInspectorDocument: Equatable {
    let sections: [MonitorDetailSection]
    let protocolDisposition: MonitorProtocolDisposition
    private let payloads: [MonitorDetailSection: MonitorInspectorPayload]

    init(log: GatewayLog) {
        sections = [.clientRequest, .upstreamRequest, .upstreamResponse, .clientResponse]
        payloads = [
            .clientRequest: Self.capturedPayload(log.clientRequest),
            .upstreamRequest: Self.capturedPayload(log.upstreamRequest),
            .upstreamResponse: Self.capturedPayload(log.upstreamResponse),
            .clientResponse: Self.capturedPayload(log.clientResponse),
        ].compactMapValues { $0 }
        if let translation = log.translation?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            protocolDisposition = .translated(translation)
        } else {
            protocolDisposition = .passthrough
        }
    }

    func payload(for section: MonitorDetailSection) -> MonitorInspectorPayload? {
        payloads[section]
    }

    private static func capturedPayload(
        _ message: GatewayCapturedMessage?
    ) -> MonitorInspectorPayload? {
        guard let message else { return nil }
        let bodyValue: JSONValue = {
            guard let data = message.body.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return .string(message.body) }
            return decoded
        }()
        let capture = JSONValue.object([
            "headers": message.headers,
            "body": bodyValue,
            "truncated": .bool(message.truncated),
        ])
        guard let raw = encode(capture, pretty: false),
              let pretty = encode(capture, pretty: true)
        else { return nil }
        let shownBytes = message.body.utf8.count
        return .init(
            rawText: raw,
            prettyText: pretty,
            source: .capturedRaw,
            shownBytes: shownBytes,
            totalBytes: message.truncated ? nil : shownBytes,
            isTruncated: message.truncated
        )
    }

    private static func encode(_ value: JSONValue, pretty: Bool) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}

enum MonitorPrivacyRedactor {
    static let replacement = "••••••（已隐藏）"

    private static let sensitiveKeys: Set<String> = [
        "authorization", "proxyauthorization", "xapikey", "xgoogapikey", "apikey",
        "cookie", "setcookie", "password", "passwd", "secret", "clientsecret",
        "accesstoken", "refreshtoken", "authtoken", "gatewaytoken", "token",
    ]

    static func replacement(for language: AppLanguage) -> String {
        language.localized(replacement)
    }

    static func redact(
        _ text: String,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        guard !text.isEmpty else { return text }
        let localizedReplacement = replacement(for: language)

        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let redactedData = try? JSONSerialization.data(
            withJSONObject: redactJSONObject(object, replacement: localizedReplacement),
            options: text.contains("\n")
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                : [.sortedKeys, .withoutEscapingSlashes]
           ),
           let redacted = String(data: redactedData, encoding: .utf8) {
            return redacted
        }

        return redactPlaintext(text, replacement: localizedReplacement)
    }

    private static func redactPlaintext(_ text: String, replacement: String) -> String {
        var result = text
        result = replace(
            #"(?i)\b(authorization|proxy[-_ ]authorization|x[-_ ]api[-_ ]key|x[-_ ]goog[-_ ]api[-_ ]key|api[-_ ]key|cookie|set[-_ ]cookie|password|passwd|client[-_ ]secret|secret|access[-_ ]token|refresh[-_ ]token|auth[-_ ]token|gateway[-_ ]token|token)\s*([:=])\s*(?:\"[^\"]*\"|'[^']*'|(?:Bearer|Basic)\s+[A-Za-z0-9._~+\-/=]{4,}|[^\s,;]+)"#,
            in: result,
            template: "$1$2 \(replacement)"
        )
        result = replace(
            #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+\-/=]{4,}"#,
            in: result,
            template: "$1 \(replacement)"
        )
        result = replace(
            #"(?i)\bsk-[A-Za-z0-9_-]{8,}"#,
            in: result,
            template: replacement
        )
        result = replace(
            #"(?i)(https?://[^\s:/@]+:)[^\s@]+@"#,
            in: result,
            template: "$1\(replacement)@"
        )
        return result
    }

    private static func redactJSONObject(_ value: Any, replacement: String) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                result[item.key] = isSensitiveKey(item.key)
                    ? replacement
                    : redactJSONObject(item.value, replacement: replacement)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSONObject($0, replacement: replacement) }
        }
        if let string = value as? String {
            return redactNonJSONSecret(string, replacement: replacement)
        }
        return value
    }

    private static func redactNonJSONSecret(_ value: String, replacement: String) -> String {
        redactPlaintext(value, replacement: replacement)
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveKeys.contains(normalized)
    }

    private static func replace(_ pattern: String, in value: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}

struct MonitorPayloadSearchState: Equatable {
    static let markLimit = 800

    private(set) var query = ""
    private(set) var matches: [NSRange] = []
    private(set) var totalMatchCount = 0
    private(set) var currentIndex: Int?

    mutating func update(query: String, in text: String) {
        self.query = query
        matches.removeAll(keepingCapacity: true)
        totalMatchCount = 0
        currentIndex = nil
        guard !query.isEmpty, !text.isEmpty else { return }

        let haystack = text as NSString
        var remaining = NSRange(location: 0, length: haystack.length)
        while remaining.length > 0 {
            let match = haystack.range(of: query, options: [.caseInsensitive], range: remaining)
            guard match.location != NSNotFound, match.length > 0 else { break }
            totalMatchCount += 1
            if matches.count < Self.markLimit { matches.append(match) }
            let nextLocation = match.location + match.length
            guard nextLocation < haystack.length else { break }
            remaining = NSRange(location: nextLocation, length: haystack.length - nextLocation)
        }
        if !matches.isEmpty { currentIndex = 0 }
    }

    mutating func move(by offset: Int) {
        guard !matches.isEmpty else { return }
        let current = currentIndex ?? 0
        currentIndex = (current + offset % matches.count + matches.count) % matches.count
    }

    var currentMatch: NSRange? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var countLabel: String {
        guard let currentIndex, !matches.isEmpty else { return "0/0" }
        let suffix = totalMatchCount > Self.markLimit ? "+" : ""
        return "\(currentIndex + 1)/\(matches.count)\(suffix)"
    }
}
