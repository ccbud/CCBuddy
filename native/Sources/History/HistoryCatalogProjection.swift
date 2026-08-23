import Foundation

struct HistoryCatalogMessageSpan: Codable, Equatable, Sendable {
    /// Parser-stable position in this transcript. This is intentionally the raw message array
    /// index so a search result can jump directly without parsing or re-matching the transcript.
    var sequence: Int
    var messageIndex: Int
    var utf16Location: Int
    var utf16Length: Int
    var role: String
    var timestamp: Date?

    var utf16Range: NSRange {
        NSRange(location: utf16Location, length: utf16Length)
    }
}

struct HistoryCatalogThreadProjection: Codable, Equatable, Sendable {
    /// `main` or the exact legacy subagent dictionary key (normally a tool-use id).
    var transcriptID: String
    var transcriptFile: URL
    var agentID: String?
    var agentType: String?
    var sortOrder: Int
    var searchText: String
    var messageSpans: [HistoryCatalogMessageSpan]

    func span(containingUTF16Offset offset: Int) -> HistoryCatalogMessageSpan? {
        messageSpans.first { span in
            offset >= span.utf16Location
                && offset < span.utf16Location + max(1, span.utf16Length)
        }
    }
}

/// Rebuildable catalog input derived from the exact normalized session shown by the detail view.
/// Raw producer files remain authoritative; this value contains only list/search projection data.
struct HistoryCatalogProjection: Codable, Equatable, Sendable {
    var metadata: HistorySessionMetadata
    var threads: [HistoryCatalogThreadProjection]

    init(session: HistorySession) {
        metadata = session.metadata
        var ordered: [(
            transcriptID: String,
            file: URL,
            agentID: String?,
            agentType: String?,
            messages: [HistoryMessage]
        )] = [
            ("main", session.metadata.file, nil, nil, session.messages),
        ]
        ordered.append(contentsOf: session.subagents.sorted {
            if $0.value.file.lastPathComponent != $1.value.file.lastPathComponent {
                return $0.value.file.lastPathComponent < $1.value.file.lastPathComponent
            }
            return $0.key < $1.key
        }.map { key, value in
            (key, value.file, value.agentID, value.type, value.messages)
        })
        threads = ordered.enumerated().map { sortOrder, thread in
            Self.thread(
                transcriptID: thread.transcriptID,
                transcriptFile: thread.file,
                agentID: thread.agentID,
                agentType: thread.agentType,
                sortOrder: sortOrder,
                messages: thread.messages
            )
        }
    }

    /// Performs the existing first-thread-wins search in memory. The SQLite implementation can
    /// use the same thread ordering and text to preserve observable legacy behavior.
    func firstMatch(query rawQuery: String) -> (thread: HistoryCatalogThreadProjection, count: Int)? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        for thread in threads {
            let count = Self.occurrenceCount(of: query, in: thread.searchText)
            if count > 0 { return (thread, count) }
        }
        return nil
    }

    // MARK: - Exact legacy search document

    private static func thread(
        transcriptID: String,
        transcriptFile: URL,
        agentID: String?,
        agentType: String?,
        sortOrder: Int,
        messages: [HistoryMessage]
    ) -> HistoryCatalogThreadProjection {
        var text = ""
        var utf16Count = 0
        var spans: [HistoryCatalogMessageSpan] = []
        for (messageIndex, message) in messages.enumerated() where !message.isMetadata {
            let messageText = legacySearchText(for: message)
            guard !messageText.isEmpty else { continue }
            if !text.isEmpty {
                text.append("\n")
                utf16Count += 1
            }
            let location = utf16Count
            let length = messageText.utf16.count
            text.append(messageText)
            utf16Count += length
            spans.append(HistoryCatalogMessageSpan(
                sequence: messageIndex,
                messageIndex: messageIndex,
                utf16Location: location,
                utf16Length: length,
                role: message.role,
                timestamp: message.timestamp
            ))
        }
        return HistoryCatalogThreadProjection(
            transcriptID: transcriptID,
            transcriptFile: transcriptFile,
            agentID: agentID,
            agentType: agentType,
            sortOrder: sortOrder,
            searchText: text,
            messageSpans: spans
        )
    }

    /// Byte-for-byte equivalent to `HistoryRepository.search`'s searchable text for one message:
    /// promoted text/tool/thinking content, injected transport removed from user blocks, and a
    /// newline between every non-empty block.
    private static func legacySearchText(for message: HistoryMessage) -> String {
        var lines: [String] = []
        for block in message.content {
            guard var text = HistoryParsingSupport.plainText(block), !text.isEmpty else { continue }
            if message.role == "user" { text = stripInjectedText(text) }
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }

    private static func stripInjectedText(_ text: String) -> String {
        var value = text
        for expression in injectedExpressions {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let injectedExpressions: [NSRegularExpression] = [
        #"(?s)<system-reminder>.*?</system-reminder>"#,
        #"(?s)<command-[a-z-]+>.*?</command-[a-z-]+>"#,
        #"(?s)<local-command-[a-z]+>.*?</local-command-[a-z]+>"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func occurrenceCount(of query: String, in text: String) -> Int {
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(
                of: query,
                options: [.caseInsensitive],
                range: cursor..<text.endIndex
              ) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }

    // MARK: - Metadata projection (kept identical to HistoryRepository)

    static func canonicalizedCodexSessions(
        _ sessions: [HistorySessionMetadata],
        homeDirectory: URL
    ) -> [HistorySessionMetadata] {
        var result: [HistorySessionMetadata] = []
        var positions: [String: Int] = [:]
        var queriedPreferredPaths = Set<String>()
        var preferredPaths: [String: URL] = [:]
        for session in sessions {
            guard session.source == .codex, session.canonicalThreadIDValid,
                  let threadID = session.threadID else {
                result.append(session)
                continue
            }
            let key = session.dirID + "\u{0}" + threadID
            if let index = positions[key] {
                if queriedPreferredPaths.insert(key).inserted {
                    for file in [result[index].file, session.file] {
                        if let preferred = CodexStateDatabase.preferredRolloutPath(
                            for: file,
                            threadID: threadID,
                            homeDirectory: homeDirectory
                        ) {
                            preferredPaths[key] = preferred
                            break
                        }
                    }
                }
                if codexCandidate(
                    session,
                    isPreferredTo: result[index],
                    authoritativePath: preferredPaths[key]
                ) {
                    result[index] = session
                }
            } else {
                positions[key] = result.count
                result.append(session)
            }
        }
        return result
    }

    static func activityOrdered(
        _ sessions: [HistorySessionMetadata]
    ) -> [HistorySessionMetadata] {
        sessions.sorted(by: sessionComesFirst)
    }

    static func projects(
        from sessions: [HistorySessionMetadata]
    ) -> [HistoryProject] {
        var order: [String] = []
        var grouped: [String: [HistorySessionMetadata]] = [:]
        for session in sessions {
            let cwd = session.cwd ?? "(unknown)"
            if grouped[cwd] == nil { order.append(cwd) }
            grouped[cwd, default: []].append(session)
        }
        return order.compactMap { cwd in
            guard let group = grouped[cwd], let first = group.first else { return nil }
            return HistoryProject(
                cwd: cwd,
                name: first.project,
                sessions: projectOrdered(group.sorted(by: sessionComesFirst)),
                lastActivity: group.map(\.lastActivity).max() ?? .distantPast
            )
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.cwd > $1.cwd
        }
    }

    static func limitedKeepingCodexAncestors(
        _ sessions: [HistorySessionMetadata],
        limit: Int
    ) -> [HistorySessionMetadata] {
        guard limit > 0 else { return [] }
        guard sessions.count > limit else { return sessions }
        var positions: [String: Int] = [:]
        for (index, session) in sessions.enumerated() {
            guard session.source == .codex, session.canonicalThreadIDValid,
                  let threadID = session.threadID else { continue }
            positions[session.dirID + "\u{0}" + threadID] = index
        }
        var included = Set(0..<limit)
        var queue = Array(0..<limit)
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let session = sessions[index]
            guard session.source == .codex, session.canonicalThreadIDValid else { continue }
            var parentIDs: [String] = []
            if let parent = session.parentThreadID { parentIDs.append(parent) }
            if session.isSubagent, let root = session.rootSessionID { parentIDs.append(root) }
            guard let parentIndex = parentIDs.lazy.compactMap({
                positions[session.dirID + "\u{0}" + $0]
            }).first else { continue }
            if included.insert(parentIndex).inserted { queue.append(parentIndex) }
        }
        return sessions.enumerated().compactMap {
            included.contains($0.offset) ? $0.element : nil
        }
    }

    static func projectOrdered(
        _ sessions: [HistorySessionMetadata]
    ) -> [HistorySessionMetadata] {
        struct Entry {
            var index: Int
            var session: HistorySessionMetadata
        }
        struct Bucket {
            var firstIndex: Int
            var newestActivity: Date
            var entries: [Entry]
        }

        var bucketOrder: [String] = []
        var buckets: [String: Bucket] = [:]
        for (index, session) in sessions.enumerated() {
            let bucketKey: String
            if session.source == .codex, session.canonicalThreadIDValid,
               let rootSessionID = session.rootSessionID, !rootSessionID.isEmpty {
                bucketKey = "codex:\(session.dirID):\(rootSessionID)"
            } else {
                bucketKey = "row:\(session.id):\(session.file.path):\(index)"
            }
            let entry = Entry(index: index, session: session)
            if var bucket = buckets[bucketKey] {
                bucket.newestActivity = max(bucket.newestActivity, session.lastActivity)
                bucket.entries.append(entry)
                buckets[bucketKey] = bucket
            } else {
                bucketOrder.append(bucketKey)
                buckets[bucketKey] = Bucket(
                    firstIndex: index,
                    newestActivity: session.lastActivity,
                    entries: [entry]
                )
            }
        }

        bucketOrder.sort { leftKey, rightKey in
            guard let left = buckets[leftKey], let right = buckets[rightKey] else {
                return leftKey < rightKey
            }
            if left.newestActivity != right.newestActivity {
                return left.newestActivity > right.newestActivity
            }
            return left.firstIndex < right.firstIndex
        }

        func newest(_ lhs: Entry, _ rhs: Entry) -> Bool {
            let left = lhs.session
            let right = rhs.session
            if left.lastActivity != right.lastActivity {
                return left.lastActivity > right.lastActivity
            }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            let leftID = left.threadID ?? left.id
            let rightID = right.threadID ?? right.id
            if leftID != rightID { return leftID < rightID }
            if left.file.path != right.file.path { return left.file.path < right.file.path }
            return lhs.index < rhs.index
        }

        var ordered: [HistorySessionMetadata] = []
        for key in bucketOrder {
            guard let bucket = buckets[key] else { continue }
            guard bucket.entries.count > 1,
                  bucket.entries.first?.session.source == .codex else {
                ordered.append(contentsOf: bucket.entries.map(\.session))
                continue
            }

            var childrenByParent: [String: [Entry]] = [:]
            for entry in bucket.entries {
                childrenByParent[entry.session.parentThreadID ?? "", default: []].append(entry)
            }
            for parent in Array(childrenByParent.keys) {
                childrenByParent[parent]?.sort(by: newest)
            }

            var seen = Set<String>()
            func append(_ entry: Entry) {
                let session = entry.session
                let identity = session.canonicalThreadIDValid
                    ? (session.threadID ?? session.sessionID)
                    : "\(session.id):\(session.file.path)"
                guard seen.insert(identity).inserted else { return }
                ordered.append(session)
                for child in childrenByParent[identity] ?? [] { append(child) }
            }

            bucket.entries
                .filter {
                    !$0.session.isSubagent
                        || $0.session.threadID == $0.session.rootSessionID
                }
                .sorted(by: newest)
                .forEach(append)

            bucket.entries
                .sorted {
                    let leftDepth = $0.session.agentDepth ?? 0
                    let rightDepth = $1.session.agentDepth ?? 0
                    return leftDepth != rightDepth ? leftDepth < rightDepth : newest($0, $1)
                }
                .forEach(append)
        }
        return ordered
    }

    private static func codexCandidate(
        _ candidate: HistorySessionMetadata,
        isPreferredTo current: HistorySessionMetadata,
        authoritativePath: URL?
    ) -> Bool {
        if let authoritativePath {
            let authoritative = authoritativePath.standardizedFileURL.path
            let candidateMatches = candidate.file.standardizedFileURL.path == authoritative
            let currentMatches = current.file.standardizedFileURL.path == authoritative
            if candidateMatches != currentMatches { return candidateMatches }
        }
        if candidate.imported != current.imported { return !candidate.imported }
        let candidateArchived = candidate.file.standardizedFileURL.pathComponents
            .contains("archived_sessions")
        let currentArchived = current.file.standardizedFileURL.pathComponents
            .contains("archived_sessions")
        if candidateArchived != currentArchived { return !candidateArchived }
        if candidate.lastActivity != current.lastActivity {
            return candidate.lastActivity > current.lastActivity
        }
        if candidate.createdAt != current.createdAt {
            return candidate.createdAt > current.createdAt
        }
        let candidateCanonical = hasCanonicalCodexFilename(candidate)
        let currentCanonical = hasCanonicalCodexFilename(current)
        if candidateCanonical != currentCanonical { return candidateCanonical }
        if candidate.sizeBytes != current.sizeBytes { return candidate.sizeBytes > current.sizeBytes }
        return candidate.file.path > current.file.path
    }

    private static func hasCanonicalCodexFilename(_ session: HistorySessionMetadata) -> Bool {
        guard let threadID = session.threadID else { return false }
        let stem = session.file.deletingPathExtension().lastPathComponent
        return stem == threadID || stem.hasSuffix("-\(threadID)")
    }

    private static func sessionComesFirst(
        _ lhs: HistorySessionMetadata,
        _ rhs: HistorySessionMetadata
    ) -> Bool {
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let lhsID = lhs.threadID ?? lhs.sessionID
        let rhsID = rhs.threadID ?? rhs.sessionID
        if lhsID != rhsID { return lhsID > rhsID }
        return lhs.file.path > rhs.file.path
    }
}
