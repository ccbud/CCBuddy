import Foundation

struct HistoryDirectoryStatistic: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let projectsURL: URL
    let sessionCount: Int
    let exists: Bool
}

/// Read-only entry point for native conversation history.
///
/// The repository owns no mutable cache and contains only value types, so callers may safely use
/// it from detached tasks. Every public file read passes through `HistoryPathResolver` first.
struct HistoryRepository: Sendable {
    let configuration: HistoryConfiguration
    let qoderReader: QoderFileReader

    init(
        configuration: HistoryConfiguration,
        qoderReader: QoderFileReader = .shared
    ) {
        self.configuration = configuration
        self.qoderReader = qoderReader
    }

    init(
        historyDirs: [String],
        active: String = "all",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        importsRoot: URL? = nil,
        qoderReader: QoderFileReader = .shared
    ) {
        self.init(configuration: HistoryConfiguration(
            historyDirs: historyDirs,
            active: active,
            homeDirectory: homeDirectory,
            importsRoot: importsRoot
        ), qoderReader: qoderReader)
    }

    var pathResolver: HistoryPathResolver {
        HistoryPathResolver(configuration: configuration)
    }

    func listSessions(limit: Int = 400) -> [HistorySessionMetadata] {
        guard limit > 0 else { return [] }
        let candidates = pathResolver.discoverSessionFiles()
        let qoderCandidates = candidates.filter { $0.formatHint == .qoder }
        qoderReader.prefetch(
            qoderCandidates.map(\.file)
                + qoderCandidates.flatMap {
                    HistorySubagentReader.qoderPrefetchFiles(mainFile: $0.file)
                }
        )
        var sessions = candidates.compactMap { candidate in
            try? readSession(candidate).metadata
        }
        sessions = deduplicateCanonicalCodexSessions(sessions)

        let trash = configuration.active == "__trash__"
        sessions.removeAll { $0.deleted != trash }
        sessions.sort(by: sessionComesFirst)
        return limitWithCodexAncestors(sessions, limit: limit)
    }

    func listProjects(limit: Int = 600) -> [HistoryProject] {
        let sessions = listSessions(limit: limit)
        var order: [String] = []
        var grouped: [String: [HistorySessionMetadata]] = [:]
        for session in sessions {
            let cwd = session.cwd ?? "(unknown)"
            if grouped[cwd] == nil { order.append(cwd) }
            grouped[cwd, default: []].append(session)
        }
        return order.compactMap { cwd in
            guard let sessions = grouped[cwd], let first = sessions.first else { return nil }
            return HistoryProject(
                cwd: cwd,
                name: first.project,
                // The legacy renderer keeps every Codex root/subagent tree together and presents
                // it depth-first. The repository list remains activity-ordered for limits and
                // search, while the project surface mirrors that final row presentation.
                sessions: orderProjectSessions(sessions.sorted(by: sessionComesFirst)),
                lastActivity: sessions.map(\.lastActivity).max() ?? .distantPast
            )
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.cwd > $1.cwd
        }
    }

    /// Mirrors the legacy `history_dirs` contract for settings: logical, non-deleted sessions are
    /// counted per configured root after canonical Codex deduplication, and a root is considered
    /// present when any supported producer data tree exists.
    func directoryStatistics() -> [HistoryDirectoryStatistic] {
        let counts = Dictionary(grouping: listSessions(limit: .max), by: \.dirID)
            .mapValues(\.count)
        return pathResolver.directories().map { directory in
            let supportedTrees = [
                directory.projectsURL,
                directory.sessionsURL,
                directory.baseURL.appendingPathComponent("session-state", isDirectory: true),
                directory.baseURL.appendingPathComponent("conversations", isDirectory: true),
            ]
            return HistoryDirectoryStatistic(
                id: directory.id,
                label: directory.label,
                projectsURL: directory.projectsURL,
                sessionCount: counts[directory.id, default: 0],
                exists: supportedTrees.contains(where: Self.isDirectory)
            )
        }
    }

    func getSession(file: URL) throws -> HistorySession {
        try readSession(pathResolver.validatedCandidate(for: file))
    }

    func getSession(filePath: String) throws -> HistorySession {
        try getSession(file: URL(fileURLWithPath: filePath))
    }

    private func readSession(_ candidate: HistoryFileCandidate) throws -> HistorySession {
        if candidate.formatHint == .antigravity {
            let facts = try HistoryFileFacts.read(candidate.file, records: [])
            return AntigravityHistoryParser.parse(
                candidate: candidate,
                facts: facts,
                appDataRoot: configuration.appDataRoot
            )
        }
        let document = try HistoryJSONLDocument.read(
            from: candidate.file,
            qoderReader: qoderReader
        )
        let facts = try HistoryFileFacts.read(candidate.file, records: document.records)
        let context = HistoryParseContext(
            candidate: candidate,
            document: document,
            facts: facts,
            homeDirectory: configuration.homeDirectory,
            appDataRoot: configuration.appDataRoot
        )
        let format = candidate.formatHint ?? HistoryTranscriptFormat.detect(document.records)
        let session: HistorySession
        switch format {
        case .claude: session = ClaudeHistoryParser.parse(context)
        case .codex: session = CodexHistoryParser.parse(context)
        case .qoder: session = QoderHistoryParser.parse(context)
        case .grok: session = GrokHistoryParser.parse(context)
        case .copilot: session = CopilotHistoryParser.parse(context)
        case .antigravity:
            session = AntigravityHistoryParser.parse(
                candidate: candidate,
                facts: facts,
                appDataRoot: configuration.appDataRoot
            )
        case nil: throw HistoryError.unsupportedTranscript(candidate.file)
        }
        guard session.metadata.source == .claude || session.metadata.source == .qoder else {
            return session
        }
        return HistorySubagentReader.attach(
            to: session,
            mainRecords: document.records,
            qoder: format == .qoder,
            qoderReader: qoderReader
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func deduplicateCanonicalCodexSessions(
        _ sessions: [HistorySessionMetadata]
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
                            homeDirectory: configuration.homeDirectory
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

    private func codexCandidate(
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
        let candidateArchived = isArchivedCodexRollout(candidate.file)
        let currentArchived = isArchivedCodexRollout(current.file)
        if candidateArchived != currentArchived { return !candidateArchived }
        if candidate.lastActivity != current.lastActivity {
            return candidate.lastActivity > current.lastActivity
        }
        if candidate.createdAt != current.createdAt { return candidate.createdAt > current.createdAt }
        let candidateCanonical = hasCanonicalCodexFilename(candidate)
        let currentCanonical = hasCanonicalCodexFilename(current)
        if candidateCanonical != currentCanonical { return candidateCanonical }
        if candidate.sizeBytes != current.sizeBytes { return candidate.sizeBytes > current.sizeBytes }
        return candidate.file.path > current.file.path
    }

    private func isArchivedCodexRollout(_ file: URL) -> Bool {
        file.standardizedFileURL.pathComponents.contains("archived_sessions")
    }

    private func hasCanonicalCodexFilename(_ session: HistorySessionMetadata) -> Bool {
        guard let threadID = session.threadID else { return false }
        let stem = session.file.deletingPathExtension().lastPathComponent
        return stem == threadID || stem.hasSuffix("-\(threadID)")
    }

    private func sessionComesFirst(
        _ lhs: HistorySessionMetadata,
        _ rhs: HistorySessionMetadata
    ) -> Bool {
        // Phase one intentionally follows the requested mtime ordering for both producers.
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let lhsID = lhs.threadID ?? lhs.sessionID
        let rhsID = rhs.threadID ?? rhs.sessionID
        if lhsID != rhsID { return lhsID > rhsID }
        return lhs.file.path > rhs.file.path
    }

    private func orderProjectSessions(
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
                // Include the input index so even malformed duplicate row identifiers remain
                // independent, as they are in the legacy renderer's standalone-row buckets.
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

            // Orphans and cycles have no reachable root. Preserve the legacy fallback: shallow
            // nodes first, then activity order, while still recursively attaching known children.
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

    private func limitWithCodexAncestors(
        _ sessions: [HistorySessionMetadata],
        limit: Int
    ) -> [HistorySessionMetadata] {
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
        return sessions.enumerated().compactMap { included.contains($0.offset) ? $0.element : nil }
    }
}
