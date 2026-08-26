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
        let loader = HistorySessionLoader(configuration: configuration, qoderReader: qoderReader)
        let candidates = loader.discoverCandidates()
        loader.prefetch(candidates)
        var sessions = candidates.compactMap { candidate in
            try? loader.load(candidate, consistency: .bestEffort).session.metadata
        }
        sessions = HistoryCatalogProjection.canonicalizedCodexSessions(
            sessions,
            homeDirectory: configuration.homeDirectory
        )

        let trash = configuration.active == "__trash__"
        sessions.removeAll { $0.deleted != trash }
        sessions = HistoryCatalogProjection.activityOrdered(sessions)
        return HistoryCatalogProjection.limitedKeepingCodexAncestors(sessions, limit: limit)
    }

    func listProjects(limit: Int = 600) -> [HistoryProject] {
        HistoryCatalogProjection.projects(from: listSessions(limit: limit))
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
        try HistorySessionLoader(
            configuration: configuration,
            qoderReader: qoderReader
        ).getSession(file: file)
    }

    func getSession(filePath: String) throws -> HistorySession {
        try getSession(file: URL(fileURLWithPath: filePath))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
