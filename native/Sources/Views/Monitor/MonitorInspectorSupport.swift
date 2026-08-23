import Foundation

enum MonitorDetailSection: String, CaseIterable, Identifiable {
    case request
    case response
    case clientRequest
    case upstreamRequest
    case upstreamResponse
    case clientResponse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .request: "请求"
        case .response: "响应"
        case .clientRequest: "客户端请求"
        case .upstreamRequest: "上游请求"
        case .upstreamResponse: "上游响应"
        case .clientResponse: "客户端响应"
        }
    }

    var shortTitle: String {
        switch self {
        case .request: "请求"
        case .response: "响应"
        case .clientRequest: "客户端请求"
        case .upstreamRequest: "上游请求"
        case .upstreamResponse: "上游响应"
        case .clientResponse: "客户端响应"
        }
    }

    var explanation: String {
        switch self {
        case .request:
            "Bifrost 保存的请求正文"
        case .response:
            "Bifrost 保存的响应正文"
        case .clientRequest:
            "客户端进入 Bifrost 后的规范化请求"
        case .upstreamRequest:
            "Bifrost 发往 Provider 的原始请求正文"
        case .upstreamResponse:
            "Provider 返回给 Bifrost 的原始响应正文"
        case .clientResponse:
            "Bifrost 返回客户端前的规范化响应"
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
        case normalizedJSON
    }

    let rawText: String
    let prettyText: String
    let source: Source
    let shownBytes: Int
    /// Nil when Bifrost reports a truncated large-payload preview without the original byte count.
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
    case translated(clientProtocol: String, upstreamProtocol: Provider.WireProtocol)
    case unknown

    var translationLabel: String? {
        guard case .translated(let clientProtocol, let upstreamProtocol) = self else { return nil }
        return "\(clientProtocol) → \(upstreamProtocol.title)"
    }
}

/// Converts Bifrost's detail record into the legacy inspector's two-sided/four-sided mental model.
/// Pinned Bifrost v1.6.11 has no `translated` field: normalized and raw payloads coexist for normal
/// passthrough traffic too. Four sides are therefore shown only when the route request type and the
/// configured upstream wire protocol prove a conversion. Ambiguous records remain generic two-sided
/// documents rather than being labelled as translated.
struct MonitorInspectorDocument: Equatable {
    let sections: [MonitorDetailSection]
    let protocolDisposition: MonitorProtocolDisposition
    private let payloads: [MonitorDetailSection: MonitorInspectorPayload]

    init(log: BifrostLog, upstreamProtocol: Provider.WireProtocol? = nil) {
        let normalizedRequest = Self.normalizedPayload(
            log.normalizedRequest,
            isTruncated: log.isLargePayloadRequest
        )
        let normalizedResponse = Self.normalizedPayload(
            log.normalizedResponse,
            isTruncated: log.isLargePayloadResponse
        )
        let rawRequest = Self.rawPayload(
            log.rawRequest,
            prefix: "raw_request",
            additionalFields: log.additionalFields,
            isLargePayload: log.isLargePayloadRequest
        )
        let rawResponse = Self.rawPayload(
            log.rawResponse,
            prefix: "raw_response",
            additionalFields: log.additionalFields,
            isLargePayload: log.isLargePayloadResponse
        )
        let passthroughRequest = Self.rawPayload(
            log.passthroughRequestBody,
            prefix: "passthrough_request_body",
            additionalFields: log.additionalFields,
            isLargePayload: log.isLargePayloadRequest
        )
        let passthroughResponse = Self.rawPayload(
            log.passthroughResponseBody,
            prefix: "passthrough_response_body",
            additionalFields: log.additionalFields,
            isLargePayload: log.isLargePayloadResponse
        )

        protocolDisposition = Self.protocolDisposition(
            log: log,
            upstreamProtocol: upstreamProtocol,
            hasExplicitPassthroughBody: passthroughRequest != nil || passthroughResponse != nil
        )

        if case .translated = protocolDisposition {
            sections = [.clientRequest, .upstreamRequest, .upstreamResponse, .clientResponse]
            payloads = [
                .clientRequest: normalizedRequest,
                .upstreamRequest: rawRequest,
                .upstreamResponse: rawResponse,
                .clientResponse: normalizedResponse,
            ].compactMapValues { $0 }
        } else {
            sections = [.request, .response]
            payloads = [
                .request: passthroughRequest ?? rawRequest ?? normalizedRequest,
                .response: passthroughResponse ?? rawResponse ?? normalizedResponse,
            ].compactMapValues { $0 }
        }
    }

    func payload(for section: MonitorDetailSection) -> MonitorInspectorPayload? {
        payloads[section]
    }

    private static func normalizedPayload(
        _ value: JSONValue?,
        isTruncated: Bool
    ) -> MonitorInspectorPayload? {
        guard let value,
              let raw = encode(value, pretty: false),
              let pretty = encode(value, pretty: true)
        else { return nil }
        let bytes = raw.utf8.count
        return .init(
            rawText: raw,
            prettyText: pretty,
            source: .normalizedJSON,
            shownBytes: bytes,
            totalBytes: isTruncated ? nil : bytes,
            isTruncated: isTruncated
        )
    }

    private static func rawPayload(
        _ raw: String?,
        prefix: String,
        additionalFields: [String: JSONValue],
        isLargePayload: Bool
    ) -> MonitorInspectorPayload? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let shownBytes = raw.utf8.count
        let reportedTotal = integer(
            additionalFields["\(prefix)_total_bytes"]
                ?? additionalFields["\(prefix)_bytes"]
        )
        let reportedTruncated = integer(additionalFields["\(prefix)_truncated_bytes"])
        let truncationFlag = boolean(additionalFields["\(prefix)_truncated"]) ?? false
        let knownTotalBytes = reportedTotal.map { max($0, shownBytes) }
            ?? reportedTruncated.map { shownBytes + $0 }
        let isTruncated = isLargePayload || truncationFlag || (reportedTruncated ?? 0) > 0
            || knownTotalBytes.map { $0 > shownBytes } == true
        return .init(
            rawText: raw,
            prettyText: MonitorFormat.prettyRaw(raw) ?? raw,
            source: .capturedRaw,
            shownBytes: shownBytes,
            totalBytes: knownTotalBytes ?? (isTruncated ? nil : shownBytes),
            isTruncated: isTruncated
        )
    }

    private static func protocolDisposition(
        log: BifrostLog,
        upstreamProtocol: Provider.WireProtocol?,
        hasExplicitPassthroughBody: Bool
    ) -> MonitorProtocolDisposition {
        // These are real pinned-schema fields used only by Bifrost's passthrough integration.
        if hasExplicitPassthroughBody { return .passthrough }

        // `object` is populated from Bifrost's route RequestType. Chat routes are unambiguous;
        // Anthropic Messages and OpenAI Responses both intentionally normalize to `responses`, so
        // those records cannot be distinguished without route metadata that v1.6.11 does not emit.
        let object = log.object?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard object == "chat_completion" || object == "chat_completion_stream",
              let upstreamProtocol else { return .unknown }
        if upstreamProtocol == .openAIChat { return .passthrough }
        return .translated(
            clientProtocol: Provider.WireProtocol.openAIChat.title,
            upstreamProtocol: upstreamProtocol
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

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= 0,
                  number <= Double(Int.max)
            else { return nil }
            return Int(number)
        case .string(let string):
            return Int(string)
        default:
            return nil
        }
    }

    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let bool): return bool
        case .number(let number): return number != 0
        case .string(let string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
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
