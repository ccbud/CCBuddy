import Foundation

struct HistoryJSONLDocument: Sendable {
    var records: [[String: HistoryValue]]
    var diagnostics: HistoryReadDiagnostics

    static func read(
        from file: URL,
        qoderReader: QoderFileReader = .shared
    ) throws -> HistoryJSONLDocument {
        if QoderFileReader.isQoderDataPath(file) {
            let data: Data
            do { data = try qoderReader.read(file) }
            catch { throw HistoryError.unreadableFile(file, String(describing: error)) }
            return parse(data: data)
        }
        do {
            return try streamed(from: file)
        } catch let error as HistoryError {
            throw error
        } catch {
            throw HistoryError.unreadableFile(file, String(describing: error))
        }
    }

    /// Reads the file in chunks and decodes one line at a time.
    ///
    /// The whole file used to be turned into a `String` first, so a 438 MB transcript cost a second
    /// full-size copy of itself before a single record existed — and mapping it instead only traded
    /// the copy for 438 MB of resident pages held until the parse finished. A rolling buffer keeps
    /// one chunk and one line alive; what survives is the records the caller asked for.
    private static func streamed(from file: URL) throws -> HistoryJSONLDocument {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch { throw HistoryError.unreadableFile(file, String(describing: error)) }
        defer { try? handle.close() }

        var records: [[String: HistoryValue]] = []
        var malformed = 0
        let decoder = JSONDecoder()
        // A byte array rather than `Data`: scanning for newlines through `Data`'s collection
        // conformance is several times slower than walking contiguous storage.
        var pending: [UInt8] = []
        pending.reserveCapacity(chunkSize * 2)

        // Compacted once per chunk rather than once per line, and every byte is examined once:
        // rescanning the buffer from the start on each chunk is quadratic, and a single Codex
        // record can be tens of megabytes, so one line can span many chunks.
        var scanFrom = 0
        func drain(finalChunk: Bool) {
            var lineStart = 0
            // Decoded straight out of the buffer's storage: handing each line to the decoder as a
            // fresh `Data` copied every byte of the file a second time.
            pending.withUnsafeBufferPointer { buffer in
                var index = scanFrom
                while index < buffer.count {
                    if buffer[index] == newlineByte {
                        decode(
                            buffer, from: lineStart, to: index,
                            into: &records, malformed: &malformed, decoder: decoder
                        )
                        lineStart = index + 1
                    }
                    index += 1
                }
                if finalChunk, lineStart < buffer.count {
                    decode(
                        buffer, from: lineStart, to: buffer.count,
                        into: &records, malformed: &malformed, decoder: decoder
                    )
                }
            }
            if finalChunk {
                pending.removeAll(keepingCapacity: false)
                scanFrom = 0
            } else {
                if lineStart > 0 { pending.removeFirst(lineStart) }
                scanFrom = pending.count
            }
        }

        while true {
            let chunk = autoreleasepool { () -> Data in
                (try? handle.read(upToCount: chunkSize)) ?? Data()
            }
            if chunk.isEmpty { break }
            // Appending a `Data` element by element goes through its collection conformance; the
            // raw buffer is the fast path.
            chunk.withUnsafeBytes { raw in
                pending.append(contentsOf: raw.bindMemory(to: UInt8.self))
            }
            autoreleasepool { drain(finalChunk: false) }
        }
        drain(finalChunk: true)

        return HistoryJSONLDocument(
            records: records,
            diagnostics: HistoryReadDiagnostics(decodedLines: records.count, malformedLines: malformed)
        )
    }

    private static let chunkSize = 1 << 20
    private static let newlineByte = UInt8(ascii: "\n")

    private static func isTrimmable(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func decode(
        _ buffer: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        into records: inout [[String: HistoryValue]],
        malformed: inout Int,
        decoder: JSONDecoder
    ) {
        var from = start
        var to = end
        while from < to, isTrimmable(buffer[from]) { from += 1 }
        while to > from, isTrimmable(buffer[to - 1]) { to -= 1 }
        guard to > from, let base = buffer.baseAddress else { return }
        // The decoder does not outlive this call, so it can read the buffer in place.
        let line = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: base + from),
            count: to - from,
            deallocator: .none
        )
        guard let value = try? decoder.decode(HistoryValue.self, from: line),
              let object = value.objectValue else {
            malformed += 1
            return
        }
        records.append(object)
    }

    /// Kept for callers that already hold the bytes, such as the permission-protected Qoder reader.
    static func parse(data: Data) -> HistoryJSONLDocument {
        var records: [[String: HistoryValue]] = []
        var malformed = 0
        let decoder = JSONDecoder()
        let bytes = [UInt8](data)
        bytes.withUnsafeBufferPointer { buffer in
            var lineStart = 0
            var index = 0
            while index < buffer.count {
                if buffer[index] == newlineByte {
                    decode(buffer, from: lineStart, to: index,
                           into: &records, malformed: &malformed, decoder: decoder)
                    lineStart = index + 1
                }
                index += 1
            }
            if lineStart < buffer.count {
                decode(buffer, from: lineStart, to: buffer.count,
                       into: &records, malformed: &malformed, decoder: decoder)
            }
        }
        return HistoryJSONLDocument(
            records: records,
            diagnostics: HistoryReadDiagnostics(decodedLines: records.count, malformedLines: malformed)
        )
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
