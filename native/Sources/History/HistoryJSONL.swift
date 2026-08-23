import Foundation

struct HistoryJSONLDocument: Sendable {
    var records: [[String: HistoryValue]]
    var diagnostics: HistoryReadDiagnostics

    static func read(
        from file: URL,
        qoderReader: QoderFileReader = .shared
    ) throws -> HistoryJSONLDocument {
        let data: Data
        do {
            if QoderFileReader.isQoderDataPath(file) {
                data = try qoderReader.read(file)
            } else {
                data = try Data(contentsOf: file, options: [.mappedIfSafe])
            }
        } catch {
            throw HistoryError.unreadableFile(file, String(describing: error))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HistoryError.unreadableFile(file, "文件不是有效的 UTF-8 文本")
        }
        return parse(text)
    }

    static func parse(_ text: String) -> HistoryJSONLDocument {
        var records: [[String: HistoryValue]] = []
        var malformed = 0
        let decoder = JSONDecoder()
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let data = trimmed.data(using: .utf8),
                  let value = try? decoder.decode(HistoryValue.self, from: data),
                  let object = value.objectValue else {
                malformed += 1
                return
            }
            records.append(object)
        }
        return HistoryJSONLDocument(
            records: records,
            diagnostics: HistoryReadDiagnostics(decodedLines: records.count, malformedLines: malformed)
        )
    }
}

enum HistoryDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value)
    }
}

struct HistoryFileFacts: Sendable {
    var createdAt: Date
    var modifiedAt: Date
    var sizeBytes: UInt64

    static func read(_ file: URL, records: [[String: HistoryValue]]) throws -> HistoryFileFacts {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch {
            throw HistoryError.unreadableFile(file, String(describing: error))
        }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let filesystemCreated = attributes[.creationDate] as? Date ?? modified
        let recordCreated = records.lazy.compactMap {
            HistoryDateParser.parse($0["timestamp"]?.stringValue)
        }.first
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return HistoryFileFacts(
            createdAt: recordCreated ?? filesystemCreated,
            modifiedAt: modified,
            sizeBytes: size
        )
    }
}
