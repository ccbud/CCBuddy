import Foundation

/// The uncased BERT BasicTokenizer + greedy WordPiece contract used by MiniLM.
/// No network tokenizer service or third-party runtime is involved.
struct SemanticWordPieceTokenizer: Sendable {
    struct Encoding: Equatable, Sendable {
        let inputIDs: [Int32]
        let attentionMask: [Int32]
    }

    static let tokenCount = 128
    private let vocabulary: [String: Int32]

    init(vocabularyURL: URL) throws {
        let contents = try String(contentsOf: vocabularyURL, encoding: .utf8)
        self.init(vocabulary: contents.components(separatedBy: .newlines))
        guard vocabulary["[PAD]"] == 0, vocabulary["[UNK]"] == 100,
              vocabulary["[CLS]"] == 101, vocabulary["[SEP]"] == 102
        else { throw SemanticSearchError.invalidVocabulary }
    }

    init(vocabulary tokens: [String]) {
        var vocabulary: [String: Int32] = [:]
        for (index, token) in tokens.enumerated() where !token.isEmpty {
            vocabulary[token] = Int32(index)
        }
        self.vocabulary = vocabulary
    }

    func encode(_ text: String) -> Encoding {
        let unknown = vocabulary["[UNK]", default: 100]
        var ids: [Int32] = [vocabulary["[CLS]", default: 101]]
        // Conversation snippets are bounded by their caller. This additional bound protects
        // against accidentally supplying an entire multi-megabyte transcript to the tokenizer.
        for token in Self.basicTokens(String(text.prefix(8192))) {
            let characters = Array(token)
            var pieces: [Int32] = []
            var start = 0
            if characters.count > 100 {
                pieces = [unknown]
            } else {
                while start < characters.count {
                    var end = characters.count
                    var match: Int32?
                    while end > start {
                        let piece = (start == 0 ? "" : "##") + String(characters[start..<end])
                        if let id = vocabulary[piece] { match = id; break }
                        end -= 1
                    }
                    guard let match else { pieces = [unknown]; break }
                    pieces.append(match)
                    start = end
                }
            }
            ids.append(contentsOf: pieces.prefix(Self.tokenCount - 1 - ids.count))
            if ids.count == Self.tokenCount - 1 { break }
        }
        ids.append(vocabulary["[SEP]", default: 102])
        let used = ids.count
        ids.append(contentsOf: repeatElement(vocabulary["[PAD]", default: 0], count: Self.tokenCount - used))
        return Encoding(inputIDs: ids,
                        attentionMask: Array(repeating: 1, count: used) + Array(repeating: 0, count: Self.tokenCount - used))
    }

    static func basicTokens(_ text: String) -> [String] {
        let normalized = text.lowercased().decomposedStringWithCanonicalMapping
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty { tokens.append(String(current)); current = .init() }
        }
        for scalar in normalized.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flush()
            } else if scalar.value == 0 || scalar.value == 0xfffd
                        || CharacterSet.controlCharacters.contains(scalar) {
                continue
            } else if isPunctuation(scalar) || isCJK(scalar.value) {
                flush()
                tokens.append(String(scalar))
            } else {
                current.append(scalar)
            }
        }
        flush()
        return tokens
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        return (33...47).contains(code) || (58...64).contains(code)
            || (91...96).contains(code) || (123...126).contains(code)
            || CharacterSet.punctuationCharacters.contains(scalar)
    }

    private static func isCJK(_ code: UInt32) -> Bool {
        (0x4e00...0x9fff).contains(code) || (0x3400...0x4dbf).contains(code)
            || (0x20000...0x2a6df).contains(code) || (0x2a700...0x2b73f).contains(code)
            || (0x2b740...0x2b81f).contains(code) || (0x2b820...0x2ceaf).contains(code)
            || (0xf900...0xfaff).contains(code) || (0x2f800...0x2fa1f).contains(code)
    }
}
