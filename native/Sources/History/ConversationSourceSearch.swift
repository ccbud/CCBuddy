import Foundation

/// Exact query-priority verification for a source whose catalog body is absent or stale.
/// This runs synchronously on the repository's search worker, never on its UI actor. JSONL
/// memory is bounded by the largest decoded record plus a query-sized rolling search window;
/// it is not a claim that an arbitrarily large individual JSON record has constant memory.
enum ConversationSourceSearch {
    static func refine(
        candidate: HistoryFileCandidate,
        metadata: HistorySessionMetadata,
        loader: HistorySessionLoader,
        query: String,
        countingOccurrences: Bool = true,
        validate: () throws -> Void,
        onFirstMatch: ((ConversationSearchRefinement) throws -> Void)? = nil
    ) throws -> ConversationSearchRefinement {
        try Task.checkCancellation()
        try validate()
        let streaming = (metadata.source == .codex || metadata.source == .claude)
            && candidate.formatHint != .qoder && !QoderFileReader.isQoderDataPath(candidate.file)
        if streaming {
            let main = try stream(file: candidate.file, source: metadata.source, query: query,
                                  transcriptID: "main", agentType: nil, validate: validate,
                                  countingOccurrences: countingOccurrences,
                                  onFirstMatch: onFirstMatch)
            if main != .noMatch { return main }
            if metadata.source == .claude, !metadata.isSubagent {
                for child in HistorySubagentReader.searchTranscripts(mainFile: candidate.file) {
                    let result = try stream(file: child.file, source: .claude, query: query,
                        transcriptID: child.transcriptID, agentType: child.agentType,
                        validate: validate, countingOccurrences: countingOccurrences,
                        onFirstMatch: onFirstMatch)
                    if result != .noMatch { return result }
                }
            }
            try validate()
            return .noMatch
        }

        // Non-streaming/permission-aware adapters retain their authoritative parser. In
        // particular this must not turn a Qoder permission denial into an empty completed search.
        let loaded = try loader.load(candidate, consistency: .dependencyStable)
        let matcher = ConversationLiteralSearch(query: query)
        for thread in loaded.projection.threads {
            try Task.checkCancellation()
            guard let match = matcher.match(in: thread.searchText, countingOccurrences: countingOccurrences) else { continue }
            let offset = match.range.lowerBound.utf16Offset(in: thread.searchText)
            let span = thread.span(containingUTF16Offset: offset)
                ?? thread.messageSpans.first(where: { $0.utf16Location >= offset })
                ?? thread.messageSpans.last
            let result = ConversationSearchRefinement.hit(transcriptID: thread.transcriptID,
                agentType: thread.agentType, sequence: span?.sequence,
                snippet: snippet(in: thread.searchText, around: match.range), count: match.count)
            try Task.checkCancellation()
            try validate()
            return result
        }
        try Task.checkCancellation()
        try validate()
        return .noMatch
    }

    private static func stream(
        file: URL, source: HistorySource, query: String, transcriptID: String, agentType: String?,
        validate: () throws -> Void,
        countingOccurrences: Bool,
        onFirstMatch: ((ConversationSearchRefinement) throws -> Void)?
    ) throws -> ConversationSearchRefinement {
        var window = Window(query: query, transcriptID: transcriptID, agentType: agentType,
                            countingOccurrences: countingOccurrences)
        var sequence = 0
        var publishedFirst = false
        func publishFirst(_ result: ConversationSearchRefinement) throws {
            guard !publishedFirst, result != .noMatch else { return }
            try Task.checkCancellation()
            try validate()
            publishedFirst = true
            try onFirstMatch?(result)
            try Task.checkCancellation()
        }
        do {
            _ = try HistoryJSONLDocument.visitRecords(from: file) { record in
                try Task.checkCancellation()
                let messages = source == .codex
                    ? CodexMessageNormalizer.searchMessages(for: record)
                    : ClaudeHistoryParser.message(from: record, parsingTimestamp: false).map { [$0] } ?? []
                for message in messages {
                    defer { sequence += 1 }
                    guard !message.isMetadata else { continue }
                    try window.append(message: message, sequence: sequence, onMatch: { result in
                        try publishFirst(result)
                        if !countingOccurrences { throw StreamStop.firstMatch }
                    })
                }
            }
        } catch StreamStop.firstMatch {
            // The count pass will reopen and validate this source. Retain only its exact first
            // answer, not a live file descriptor, partially decoded record, or transcript text.
            try Task.checkCancellation()
            try validate()
            return window.result
        }
        try window.finish()
        try validate()
        try publishFirst(window.result)
        return window.result
    }

    private enum StreamStop: Error { case firstMatch }

    static func snippet(in text: String, around match: Range<String.Index>) -> String {
        let start = text.index(match.lowerBound, offsetBy: -56, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 56, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    /// The suffix includes canonical-fold lookahead and snippet context, measured in complete
    /// Swift Characters. Only starts before ownedEnd belong to this window; resumeUTF16 carries
    /// non-overlap even when one match ends in its successor's lookahead.
    private struct Window {
        let matcher: ConversationLiteralSearch
        let lookahead: Int
        let transcriptID: String
        let agentType: String?
        let countingOccurrences: Bool
        var text = ""
        var globalStart = 0
        var globalEnd = 0
        var ownedStart = 0
        var resumeUTF16 = 0
        var hasContent = false
        var spans: [(start: Int, end: Int, sequence: Int)] = []
        var first: (sequence: Int?, snippet: String)?
        var count = 0

        init(query: String, transcriptID: String, agentType: String?, countingOccurrences: Bool) {
            matcher = ConversationLiteralSearch(query: query)
            lookahead = ConversationSearchChunk.lookaheadCharacters(for: query)
            self.transcriptID = transcriptID
            self.agentType = agentType
            self.countingOccurrences = countingOccurrences
        }

        var result: ConversationSearchRefinement {
            guard let first else { return .noMatch }
            return .hit(transcriptID: transcriptID, agentType: agentType,
                        sequence: first.sequence, snippet: first.snippet, count: count)
        }

        mutating func append(message: HistoryMessage, sequence: Int,
                             onMatch: (ConversationSearchRefinement) throws -> Void) throws {
            let value = HistoryCatalogProjection.legacySearchText(for: message)
            guard !value.isEmpty else { return }
            if hasContent { text.append("\n"); globalEnd += 1 }
            hasContent = true
            spans.append((globalEnd, globalEnd + value.utf16.count, sequence))
            try ConversationSearchChunk.forEachPart(of: value) { part in
                try Task.checkCancellation()
                text.append(part.text)
                globalEnd += part.utf16Length
                if text.utf8.count >= ConversationSearchChunk.targetBytes * 2 {
                    try drain(final: false)
                    if first != nil { try onMatch(result) }
                }
            }
        }

        mutating func finish() throws { try drain(final: true) }

        private mutating func drain(final: Bool) throws {
            try Task.checkCancellation()
            let end: String.Index
            if final { end = text.endIndex }
            else {
                guard let boundary = text.index(text.endIndex, offsetBy: -lookahead,
                                                limitedBy: text.startIndex) else { return }
                end = boundary
            }
            let ownedEnd = end.utf16Offset(in: text)
            guard ownedEnd > ownedStart else { return }
            if let match = matcher.match(in: text, countingOccurrences: countingOccurrences,
                                         startingAtUTF16: max(ownedStart, resumeUTF16 - globalStart),
                                         ownedUTF16Length: ownedEnd) {
                if first == nil {
                    let location = globalStart + match.range.lowerBound.utf16Offset(in: text)
                    let span = spans.first { location >= $0.start && location < $0.end }
                        ?? spans.first { $0.start >= location } ?? spans.last
                    var excerpt = ConversationSourceSearch.snippet(in: text, around: match.range)
                    // A retained left context at the start of a later rolling window still
                    // has preceding transcript text, just as the complete projection does.
                    let excerptStart = text.index(match.range.lowerBound, offsetBy: -56,
                                                  limitedBy: text.startIndex) ?? text.startIndex
                    if globalStart > 0, excerptStart == text.startIndex { excerpt = "…" + excerpt }
                    first = (span?.sequence, excerpt)
                }
                count += match.count
                resumeUTF16 = globalStart + match.lastUTF16End
            }
            try Task.checkCancellation()
            let removeEnd = text.index(end, offsetBy: -56, limitedBy: text.startIndex) ?? text.startIndex
            let removed = removeEnd.utf16Offset(in: text)
            text = String(text[removeEnd...])
            globalStart += removed
            ownedStart = ownedEnd - removed
            spans.removeAll { $0.end < globalStart }
        }
    }
}
