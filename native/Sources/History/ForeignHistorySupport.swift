import Foundation

struct ForeignHistoryCustomMetadata: Sendable {
    var title: String?
    var tags: [String]
    var deleted: Bool
}

enum ForeignHistorySupport {
    static func customMetadata(
        source: HistorySource,
        sessionKey: String,
        appDataRoot: URL
    ) -> ForeignHistoryCustomMetadata {
        metadata(
            file: appDataRoot.appendingPathComponent("agent-meta.json"),
            key: "\(source.rawValue):\(sessionKey)"
        )
    }

    static func codexMetadata(
        sessionKey: String,
        appDataRoot: URL
    ) -> ForeignHistoryCustomMetadata {
        metadata(
            file: appDataRoot.appendingPathComponent("codex-meta.json"),
            key: sessionKey
        )
    }

    private static func metadata(file: URL, key: String) -> ForeignHistoryCustomMetadata {
        guard let root = jsonObject(at: file),
              let custom = root[key]?.objectValue else {
            return .init(title: nil, tags: [], deleted: false)
        }
        let rawTitle = custom["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = custom["tagList"]?.arrayValue?.compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
        return ForeignHistoryCustomMetadata(
            title: rawTitle?.isEmpty == false ? rawTitle : nil,
            tags: tags,
            deleted: custom["delete"]?.boolValue ?? false
        )
    }

    static func jsonObject(at file: URL, maximumBytes: Int = 8 * 1_024 * 1_024) -> [String: HistoryValue]? {
        guard isOrdinaryFile(file),
              let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              data.count <= maximumBytes,
              let value = try? JSONDecoder().decode(HistoryValue.self, from: data) else { return nil }
        return value.objectValue
    }

    static func textFile(at file: URL, maximumBytes: Int = 1 * 1_024 * 1_024) -> String? {
        guard isOrdinaryFile(file),
              let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isOrdinaryFile(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func trimmed(_ value: HistoryValue?) -> String? {
        guard let result = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }
        return result
    }

    static func meaningful(_ value: HistoryValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .string(let string): return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let array): return !array.isEmpty
        case .object(let object): return !object.isEmpty
        case .number, .bool: return true
        }
    }

    static func decodeJSONObject(_ value: HistoryValue?) -> HistoryValue {
        if let object = value?.objectValue { return .object(object) }
        guard let text = value?.stringValue,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(HistoryValue.self, from: data),
              decoded.objectValue != nil else { return .object([:]) }
        return decoded
    }

    static func percentDecode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    static func imageBlock(fromDataURL value: String) -> HistoryContentBlock? {
        guard value.hasPrefix("data:"),
              let marker = value.range(of: ";base64,") else { return nil }
        let mime = String(value[value.index(value.startIndex, offsetBy: 5)..<marker.lowerBound])
        let encoded = String(value[marker.upperBound...])
        guard !mime.isEmpty else { return nil }
        let raw: HistoryValue = .object([
            "type": .string("image"),
            "source": .object([
                "type": .string("base64"),
                "media_type": .string(mime),
                "data": .string(encoded),
            ]),
        ])
        return HistoryContentBlock(type: "image", raw: raw)
    }

    static func firstTimestamp(in messages: [HistoryMessage]) -> Date? {
        messages.compactMap(\.timestamp).first
    }

    static func lastTimestamp(in messages: [HistoryMessage]) -> Date? {
        messages.compactMap(\.timestamp).last
    }

    static func timestampText(seconds: UInt64, nanos: UInt64) -> String? {
        guard seconds <= UInt64(Int64.max), nanos < 1_000_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
