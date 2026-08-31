import Foundation

enum AntigravityWireValue {
    case varint(UInt64)
    case bytes(Data)
    case fixed
}

struct AntigravityWireMessage {
    var fields: [(UInt32, AntigravityWireValue)]

    static func decode(_ data: Data) -> AntigravityWireMessage? {
        let bytes = [UInt8](data)
        var index = 0
        var result: [(UInt32, AntigravityWireValue)] = []

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                index += 1
                let payload = UInt64(byte & 0x7f)
                if shift >= 64 || (shift == 63 && payload > 1) { return nil }
                value |= payload << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        while index < bytes.count {
            guard let tag = readVarint(), tag >> 3 > 0, tag >> 3 <= UInt64(UInt32.max) else {
                return nil
            }
            let field = UInt32(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = readVarint() else { return nil }
                result.append((field, .varint(value)))
            case 2:
                guard let rawLength = readVarint(), rawLength <= UInt64(Int.max) else { return nil }
                let length = Int(rawLength)
                guard length <= bytes.count - index else { return nil }
                result.append((field, .bytes(Data(bytes[index..<(index + length)]))))
                index += length
            case 5:
                guard 4 <= bytes.count - index else { return nil }
                index += 4
                result.append((field, .fixed))
            case 1:
                guard 8 <= bytes.count - index else { return nil }
                index += 8
                result.append((field, .fixed))
            default:
                return nil
            }
        }
        return AntigravityWireMessage(fields: result)
    }

    func bytes(_ field: UInt32) -> Data? {
        fields.lazy.compactMap { number, value -> Data? in
            guard number == field, case .bytes(let data) = value else { return nil }
            return data
        }.first
    }

    func messages(_ field: UInt32) -> [AntigravityWireMessage] {
        fields.compactMap { number, value in
            guard number == field, case .bytes(let data) = value else { return nil }
            return Self.decode(data)
        }
    }

    func message(_ field: UInt32) -> AntigravityWireMessage? {
        messages(field).first
    }

    func string(_ field: UInt32) -> String? {
        guard let data = bytes(field) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func varint(_ field: UInt32) -> UInt64? {
        fields.lazy.compactMap { number, value -> UInt64? in
            guard number == field, case .varint(let result) = value else { return nil }
            return result
        }.first
    }

    func timestamp(_ field: UInt32) -> String? {
        guard let value = message(field), let seconds = value.varint(1) else { return nil }
        return ForeignHistorySupport.timestampText(
            seconds: seconds,
            nanos: value.varint(2) ?? 0
        )
    }
}

enum AntigravityWireSearch {
    static func firstString(in data: Data, withPrefix prefix: String, depth: Int = 0) -> String? {
        guard let message = AntigravityWireMessage.decode(data) else { return nil }
        for (_, value) in message.fields {
            guard case .bytes(let bytes) = value else { continue }
            if let text = String(data: bytes, encoding: .utf8), text.hasPrefix(prefix) { return text }
            if depth < 6, let nested = firstString(in: bytes, withPrefix: prefix, depth: depth + 1) {
                return nested
            }
        }
        return nil
    }
}
