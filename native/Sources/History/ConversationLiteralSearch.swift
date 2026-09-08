import Foundation

/// Exact Foundation-compatible matching with a fast candidate scan for common coding queries.
/// ICU's literal regex scanner avoids CFString's expensive per-position canonical comparison.
/// Every candidate is still checked with Foundation at its complete grapheme boundary.
struct ConversationLiteralSearch {
    struct Match {
        let range: Range<String.Index>
        let count: Int
    }

    private let query: String
    private let expression: NSRegularExpression?
    private let candidateUTF16Length: Int
    private let foundationOverlapCharacters: Int

    /// Foundation's canonical Han aliases are single-scalar substitutions. Build
    /// this small, immutable table once using the running OS's normalization data.
    /// Numeric keys are deliberate: Swift String equality is already canonical,
    /// so comparing alias and normalized Strings would hide these substitutions.
    private static let hanCanonicalAliases: [UInt32: [Unicode.Scalar]] = {
        var aliases: [UInt32: [Unicode.Scalar]] = [:]
        for range in [0xf900...0xfaff, 0x2f800...0x2fa1f] {
            for value in range {
                guard let alias = Unicode.Scalar(value) else { continue }
                let normalized = String(alias).precomposedStringWithCanonicalMapping.unicodeScalars
                guard normalized.count == 1, let base = normalized.first,
                      base.value != alias.value, isUnifiedHan(base.value) else { continue }
                aliases[base.value, default: []].append(alias)
            }
        }
        return aliases
    }()

    init(query: String) {
        self.query = query
        let queryUTF16Length = query.utf16.count
        // Canonical case-fold expansion bounds how many source graphemes can
        // participate in one exact match, including Greek/ligature expansions.
        foundationOverlapCharacters = query.folding(options: .caseInsensitive, locale: nil)
            .decomposedStringWithCanonicalMapping.unicodeScalars.count
        let scalars = query.unicodeScalars
        let asciiWords = !scalars.isEmpty && scalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
                || (48...57).contains($0.value) || $0.value == 32
        }
        let unifiedHan = !scalars.isEmpty && scalars.allSatisfy { Self.isUnifiedHan($0.value) }
        var pattern = NSRegularExpression.escapedPattern(for: query)
        var maximumCandidateLength = queryUTF16Length
        if unifiedHan, queryUTF16Length <= 1_024 {
            pattern = ""
            maximumCandidateLength = 0
            for scalar in scalars {
                let aliases = Self.hanCanonicalAliases[scalar.value] ?? []
                if aliases.isEmpty {
                    pattern.append(String(scalar))
                } else {
                    pattern += "[" + String(scalar) + aliases.map(String.init).joined() + "]"
                }
                maximumCandidateLength += ([scalar] + aliases).contains { $0.value > 0xffff } ? 2 : 1
            }
        }
        candidateUTF16Length = maximumCandidateLength
        // Large pasted queries keep the exact Foundation path instead of spending seconds
        // compiling a huge ICU pattern. This selects an algorithm; it never truncates a query.
        expression = (asciiWords || unifiedHan) && queryUTF16Length <= 1_024
            ? try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            : nil
    }

    func firstMatch(in text: String) -> Range<String.Index>? {
        match(in: text, countingOccurrences: false)?.range
    }

    func match(in text: String, countingOccurrences: Bool = true) -> Match? {
        guard !Task.isCancelled else { return nil }
        guard !query.isEmpty, !text.isEmpty else { return nil }
        guard let expression else { return foundationMatch(in: text, countingOccurrences: countingOccurrences) }
        // Bridge once per document. Repeated String.range calls can repeatedly traverse the
        // UTF-8/UTF-16 boundary, especially when counting a frequent term in a long transcript.
        let source = NSString(string: text)
        let bridged = source as String
        var first: NSRange?
        var count = 0
        var cursor = 0
        while cursor < source.length {
            // Literal regex retains ICU's fast skip tables. Only rejected candidates need
            // overlapping rescans; a lookahead would force an attempt at every text position.
            // Bound no-hit scans for cancellation without .reportProgress, which calls back
            // almost once per UTF-16 unit. The overlap includes every possible fast-path
            // match (ASCII fold expansions only shorten it; a Han compatibility alias
            // may occupy two UTF-16 units even when its query scalar occupies one).
            let chunkEnd = scalarBoundary(atOrAfter: min(source.length, cursor + 65_536), in: source)
            let scanEnd = scalarBoundary(atOrAfter:
                chunkEnd + min(source.length - chunkEnd, candidateUTF16Length), in: source)
            var resumeAt = chunkEnd
            var foundFirstOnly = false
            expression.enumerateMatches(in: bridged,
                range: NSRange(location: cursor, length: scanEnd - cursor)) { result, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard let candidate = result?.range else { return }
                guard candidate.location < chunkEnd else { stop.pointee = true; return }
                // NSString's composed-character rules disagree with Swift for ZWJ and Prepend.
                // If a candidate is rejected, resume one Unicode scalar after its beginning:
                // nonoverlapping enumeration alone would hide an overlapping valid match.
                func rejectCandidate() {
                    let firstUnit = source.character(at: candidate.location)
                    resumeAt = candidate.location + ((0xd800...0xdbff).contains(firstUnit) ? 2 : 1)
                    stop.pointee = true
                }
                guard
                      let swiftRange = Range(candidate, in: bridged),
                      swiftRange.lowerBound.samePosition(in: bridged) != nil,
                      swiftRange.upperBound.samePosition(in: bridged) != nil
                else { rejectCandidate(); return }
                let graphemes = source.rangeOfComposedCharacterSequences(for: candidate)
                let checkedRange = NSRange(location: candidate.location,
                    length: NSMaxRange(graphemes) - candidate.location)
                let verified = source.range(of: query, options: [.caseInsensitive, .anchored], range: checkedRange)
                guard verified == candidate else { rejectCandidate(); return }
                if first == nil { first = verified }
                count += 1
                resumeAt = max(resumeAt, NSMaxRange(verified))
                if !countingOccurrences { foundFirstOnly = true; stop.pointee = true }
            }
            guard !Task.isCancelled else { return nil }
            if foundFirstOnly { break }
            cursor = resumeAt
        }
        guard !Task.isCancelled, let first, let range = Range(first, in: text) else { return nil }
        return Match(range: range, count: count)
    }

    private func foundationMatch(in text: String, countingOccurrences: Bool) -> Match? {
        // Preserve Swift Foundation's exact behavior for complex queries. NSString's API is
        // observably different for some Greek case-fold expansions, so it is not a substitute.
        var first: Range<String.Index>?
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if Task.isCancelled { return nil }
            // Keep Foundation as the semantic authority, but bound its no-hit
            // scan as well. Windows end only at Swift grapheme boundaries, and
            // overlap by the canonical-fold length so crossing matches survive.
            let chunkEnd = text.index(cursor, offsetBy: 16_384, limitedBy: text.endIndex) ?? text.endIndex
            let scanEnd = text.index(chunkEnd, offsetBy: foundationOverlapCharacters,
                limitedBy: text.endIndex) ?? text.endIndex
            while cursor < chunkEnd {
                if Task.isCancelled { return nil }
                guard let range = text.range(of: query, options: .caseInsensitive, range: cursor..<scanEnd),
                      range.lowerBound < chunkEnd else { break }
                if first == nil { first = range }
                count += 1
                if !countingOccurrences {
                    return Task.isCancelled ? nil : Match(range: range, count: count)
                }
                cursor = range.upperBound
            }
            cursor = max(cursor, chunkEnd)
        }
        guard !Task.isCancelled else { return nil }
        return first.map { Match(range: $0, count: count) }
    }

    private static func isUnifiedHan(_ value: UInt32) -> Bool {
        (0x3400...0x4dbf).contains(value) || (0x4e00...0x9fff).contains(value)
            || (0x20000...0x2a6df).contains(value) || (0x2a700...0x2ee5f).contains(value)
            || (0x30000...0x323af).contains(value)
    }

    private func scalarBoundary(atOrAfter offset: Int, in source: NSString) -> Int {
        guard offset > 0, offset < source.length,
              (0xd800...0xdbff).contains(source.character(at: offset - 1)) else { return offset }
        return offset + 1
    }
}
