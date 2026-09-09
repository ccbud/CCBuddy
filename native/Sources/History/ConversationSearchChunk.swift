import Foundation
import Compression

/// A resumable position, including the byte/UTF-16 coordinates needed while an old catalog
/// is being migrated. It contains no source text and is valid only for its catalog generation.
struct ConversationIndexSearchCursor: Equatable, Sendable {
    var nextOrdinal: Int = 0
    var legacyByteOffset: Int = 0
    var legacyUTF16Offset: Int = 0
    var generation: Int64? = nil
}

/// The first `ownedUTF16Length` UTF-16 units own match starts. The remaining suffix is
/// query-sized lookahead, never a second owner: callers must not count its starts twice.
struct ConversationIndexSearchWindow: Sendable {
    var chunkID: Int64
    var text: String
    var globalUTF16Start: Int
    var ownedUTF16Length: Int
    /// Coordinates remain transcript-global, including spans crossing a physical block.
    var messageSpans: [ConversationIndexMessageSpan]
    var generation: Int64
}

struct ConversationIndexSearchWindowBatch: Sendable {
    var windows: [ConversationIndexSearchWindow]
    var nextCursor: ConversationIndexSearchCursor?
    var generation: Int64
}

/// One copy of each byte is stored, compressed independently. Splitting only at Character
/// boundaries preserves the existing Foundation/grapheme matching semantics. An indivisible
/// grapheme larger than the target is the sole permitted oversized block.
enum ConversationSearchChunk {
    static let targetBytes = 32 * 1_024
    static let candidatePrefixBytes = 64
    static let indexLookaheadCharacters = 64

    struct Part {
        var text: String
        var utf16Location: Int
        var utf16Length: Int
    }

    static func parts(of text: String) -> [Part] {
        var result: [Part] = []
        forEachPart(of: text) { result.append($0) }
        return result
    }

    /// Production writes consume and release one part at a time; the convenience array above
    /// is for tests/non-hot consumers, not a second in-memory copy of a giant transcript.
    static func forEachPart(of text: String, _ body: (Part) throws -> Void) rethrows {
        var start = text.startIndex
        var cursor = start
        var bytes = 0
        var location = 0
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let width = text[cursor..<next].utf8.count
            if bytes > 0, bytes + width > targetBytes {
                let value = String(text[start..<cursor])
                let length = value.utf16.count
                try body(Part(text: value, utf16Location: location, utf16Length: length))
                location += length
                start = cursor
                bytes = 0
            }
            bytes += width
            cursor = next
        }
        if start < text.endIndex || text.isEmpty {
            let value = String(text[start...])
            try body(Part(text: value, utf16Location: location, utf16Length: value.utf16.count))
        }
    }

    /// The full query is always verified against source text. Only its bounded normalized
    /// prefix drives postings, so an arbitrarily long literal cannot disappear at a boundary.
    static func candidatePrefix(_ query: String) -> String {
        let normalized = TgrepSearchIndex.normalized(query)
        var bytes = 0
        var end = normalized.unicodeScalars.startIndex
        for scalar in normalized.unicodeScalars {
            let width = scalar.utf8.count
            if bytes + width > candidatePrefixBytes { break }
            bytes += width
            end = normalized.unicodeScalars.index(after: end)
        }
        return String(normalized[..<end])
    }

    static func lookaheadCharacters(for query: String) -> Int {
        query.folding(options: .caseInsensitive, locale: nil)
            .decomposedStringWithCanonicalMapping.unicodeScalars.count + 64
    }

    static func spans(_ spans: [ConversationIndexMessageSpan], location: Int, length: Int)
        -> [ConversationIndexMessageSpan] {
        // Validated spans are ordered and non-overlapping. A giant conversation should not
        // walk every message again for each physical block.
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if spans[middle].utf16Location + spans[middle].utf16Length < location {
                lower = middle + 1
            } else { upper = middle }
        }
        var result: [ConversationIndexMessageSpan] = []
        for span in spans[lower...] {
            if span.utf16Location > location + length { break }
            if span.utf16Length == 0 {
                if span.utf16Location >= location { result.append(span) }
            } else if span.utf16Location < location + length,
                      span.utf16Location + span.utf16Length > location {
                result.append(span)
            }
        }
        return result
    }
}

enum ConversationSearchCompression {
    static func encode(_ text: String) -> (codec: Int, bytes: Data, decodedBytes: Int) {
        let source = Data(text.utf8)
        guard !source.isEmpty else { return (0, source, 0) }
        var output = Data(count: source.count)
        let count = output.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { input in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count, input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count < source.count else { return (0, source, source.count) }
        output.count = count
        return (1, output, source.count)
    }

    static func decode(_ bytes: Data, codec: Int, decodedBytes: Int) throws -> String {
        guard decodedBytes >= 0 else {
            throw ConversationIndexDatabaseError.corruptRow("negative chunk size")
        }
        let output: Data
        if codec == 0 {
            guard bytes.count == decodedBytes else {
                throw ConversationIndexDatabaseError.corruptRow("raw chunk size")
            }
            output = bytes
        } else if codec == 1, decodedBytes > 0 {
            var decoded = Data(count: decodedBytes)
            let count = decoded.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { input in
                    guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!,
                        destination.count, source, input.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard count == decodedBytes else {
                throw ConversationIndexDatabaseError.corruptRow("compressed chunk size")
            }
            output = decoded
        } else {
            throw ConversationIndexDatabaseError.corruptRow("unknown chunk codec")
        }
        guard let text = String(data: output, encoding: .utf8) else {
            throw ConversationIndexDatabaseError.corruptRow("chunk UTF-8")
        }
        return text
    }
}
