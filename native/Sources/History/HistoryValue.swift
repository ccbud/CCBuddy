import Foundation

/// A concurrency-safe JSON tree used by the history readers.
///
/// Session transcripts contain tool-specific payloads that cannot be represented by a fixed
/// Codable structure. Keeping those payloads as a value type preserves them without tying the
/// history layer to UI or gateway models.
indirect enum HistoryValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: HistoryValue])
    case array([HistoryValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: HistoryValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([HistoryValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard let value = numberValue, value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: HistoryValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [HistoryValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> HistoryValue? {
        objectValue?[key]
    }

    /// Stable JSON text used for content search and future tool-card rendering.
    var jsonString: String {
        guard let data = try? JSONEncoder.history.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }
}

extension JSONEncoder {
    fileprivate static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
