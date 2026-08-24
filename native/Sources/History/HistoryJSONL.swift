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

/// Incremental JSONL reader used by producers whose transcripts can grow into hundreds of
/// megabytes. Only one bounded record is assembled at a time; decoded objects are handed to the
/// caller synchronously and are never retained by the reader.
struct HistoryJSONLStreamMetrics: Equatable, Sendable {
    var bytesRead: Int
    var peakBufferedRecordBytes: Int
    var diagnostics: HistoryReadDiagnostics
}

enum HistoryJSONLStreamReader {
    static let defaultChunkBytes = 64 * 1_024
    static let maximumRecordBytes = 16 * 1_024 * 1_024

    /// Returning `false` from `visit` stops after the current decoded record. A record larger than
    /// `maximumRecordBytes` is counted as malformed and discarded through its newline, ensuring a
    /// single producer payload cannot make the process buffer the complete file.
    static func scan(
        from file: URL,
        maximumRecordBytes: Int = maximumRecordBytes,
        chunkBytes: Int = defaultChunkBytes,
        visit: ([String: HistoryValue]) -> Bool
    ) throws -> HistoryJSONLStreamMetrics {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw HistoryError.unreadableFile(file, String(describing: error))
        }
        defer { try? handle.close() }

        let recordLimit = max(1, maximumRecordBytes)
        let readSize = max(1, chunkBytes)
        let decoder = JSONDecoder()
        var pending = Data()
        var discardingOversizedRecord = false
        var bytesRead = 0
        var peakBufferedRecordBytes = 0
        var diagnostics = HistoryReadDiagnostics()
        var stopped = false

        func decode(_ line: Data) -> Bool {
            autoreleasepool {
                guard !line.allSatisfy({ byte in
                    byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
                }) else { return true }
                guard let value = try? decoder.decode(HistoryValue.self, from: line),
                      let object = value.objectValue else {
                    diagnostics.malformedLines += 1
                    return true
                }
                diagnostics.decodedLines += 1
                return visit(object)
            }
        }

        do {
            while !stopped,
                  let chunk = try handle.read(upToCount: readSize),
                  !chunk.isEmpty {
                bytesRead += chunk.count
                var start = chunk.startIndex
                while !stopped, start < chunk.endIndex,
                      let newline = chunk[start..<chunk.endIndex].firstIndex(of: 0x0A) {
                    let segment = chunk[start..<newline]
                    if discardingOversizedRecord {
                        discardingOversizedRecord = false
                    } else if segment.count <= recordLimit - pending.count {
                        pending.append(contentsOf: segment)
                        peakBufferedRecordBytes = max(peakBufferedRecordBytes, pending.count)
                        if !decode(pending) { stopped = true }
                    } else {
                        diagnostics.malformedLines += 1
                    }
                    pending = Data()
                    start = chunk.index(after: newline)
                }
                guard !stopped, start < chunk.endIndex else { continue }
                if discardingOversizedRecord { continue }
                let tail = chunk[start..<chunk.endIndex]
                if tail.count <= recordLimit - pending.count {
                    pending.append(contentsOf: tail)
                    peakBufferedRecordBytes = max(peakBufferedRecordBytes, pending.count)
                } else {
                    diagnostics.malformedLines += 1
                    pending = Data()
                    discardingOversizedRecord = true
                }
            }
        } catch {
            throw HistoryError.unreadableFile(file, String(describing: error))
        }

        if !stopped, !discardingOversizedRecord, !pending.isEmpty {
            _ = decode(pending)
        }
        return HistoryJSONLStreamMetrics(
            bytesRead: bytesRead,
            peakBufferedRecordBytes: peakBufferedRecordBytes,
            diagnostics: diagnostics
        )
    }

    /// Reads a small number of complete records for format detection without mapping the source
    /// file or retaining the remainder of the transcript.
    static func prefix(
        from file: URL,
        maximumRecords: Int = 8
    ) throws -> HistoryJSONLDocument {
        let limit = max(1, maximumRecords)
        var records: [[String: HistoryValue]] = []
        let metrics = try scan(from: file) { record in
            records.append(record)
            return records.count < limit
        }
        return HistoryJSONLDocument(records: records, diagnostics: metrics.diagnostics)
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
