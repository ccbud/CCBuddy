import Foundation

extension HistoryRepository {
    /// Basic content search across the same active/soft-delete scope as the session list.
    func search(query: String, limit: Int = 120) -> [HistorySearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        var hits: [HistorySearchHit] = []
        for metadata in listSessions(limit: 600) {
            guard let session = try? getSession(file: metadata.file) else { continue }
            var threads: [(agent: String, type: String?, messages: [HistoryMessage])] = [
                ("main", nil, session.messages),
            ]
            threads.append(contentsOf: session.subagents.sorted {
                $0.value.file.lastPathComponent < $1.value.file.lastPathComponent
            }.map { (key: String, value: HistorySubagent) in
                (key, value.type, value.messages)
            })
            guard let matched = threads.lazy.compactMap({ thread -> HistorySearchHit? in
                let text = searchableText(thread.messages)
                guard let match = text.range(of: query, options: [.caseInsensitive]) else {
                    return nil
                }
                return HistorySearchHit(
                    sessionID: metadata.sessionID,
                    file: metadata.file,
                    source: metadata.source,
                    agent: thread.agent,
                    agentType: thread.type,
                    snippet: snippet(in: text, around: match, context: 56),
                    count: occurrenceCount(of: query, in: text)
                )
            }).first else { continue }
            hits.append(matched)
            if hits.count == limit { break }
        }
        return hits
    }

    private func searchableText(_ messages: [HistoryMessage]) -> String {
        var lines: [String] = []
        for message in messages where !message.isMetadata {
            for block in message.content {
                guard var text = HistoryParsingSupport.plainText(block), !text.isEmpty else { continue }
                if message.role == "user" { text = stripInjectedText(text) }
                if !text.isEmpty { lines.append(text) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func occurrenceCount(of query: String, in text: String) -> Int {
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive], range: cursor..<text.endIndex) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }

    private func snippet(
        in text: String,
        around match: Range<String.Index>,
        context: Int
    ) -> String {
        let start = text.index(match.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    /// Keeps the phase-one search aligned with the most important renderer rule: injected Claude
    /// command/system transport is not user-visible content and therefore is not searchable.
    private func stripInjectedText(_ text: String) -> String {
        var value = text
        for pattern in [
            #"(?s)<system-reminder>.*?</system-reminder>"#,
            #"(?s)<command-[a-z-]+>.*?</command-[a-z-]+>"#,
            #"(?s)<local-command-[a-z]+>.*?</local-command-[a-z]+>"#,
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
