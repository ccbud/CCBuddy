import Foundation

struct HistoryConfiguration: Equatable, Sendable {
    var historyDirs: [String]
    var active: String
    var homeDirectory: URL
    var importsRoot: URL

    var appDataRoot: URL { importsRoot.deletingLastPathComponent() }

    init(
        historyDirs: [String],
        active: String = "all",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        importsRoot: URL? = nil
    ) {
        self.historyDirs = historyDirs
        self.active = active.isEmpty ? "all" : active
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.importsRoot = (importsRoot
            ?? homeDirectory.appendingPathComponent(".ccbud/imports", isDirectory: true))
            .standardizedFileURL
    }
}

struct HistoryFileCandidate: Equatable, Sendable {
    var file: URL
    var projectDirectoryName: String?
    var directory: HistoryDirectory
    var formatHint: HistoryTranscriptFormat? = nil
}

struct HistoryPathResolver: Sendable {
    let configuration: HistoryConfiguration

    init(configuration: HistoryConfiguration) {
        self.configuration = configuration
    }

    static func expandTilde(_ path: String, homeDirectory: URL) -> URL {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory.path
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// Best-effort inverse of Claude Code's encoded project directory names.
    static func decodeProjectDirectoryName(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        let trimmed = String(name.drop(while: { $0 == "-" }))
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }

    static func baseName(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    func directories(activeOnly: Bool = false) -> [HistoryDirectory] {
        var seen = Set<String>()
        var result: [HistoryDirectory] = []
        let active = configuration.active
        let includeConfigured = !activeOnly || active == "all" || active == "__trash__"
            || active != "__imported__"
        if includeConfigured {
            for raw in configuration.historyDirs
                where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if activeOnly, active != "all", active != "__trash__", active != raw { continue }

                let base = Self.expandTilde(raw, homeDirectory: configuration.homeDirectory)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard seen.insert(base.path).inserted else { continue }
                result.append(HistoryDirectory(
                    id: raw,
                    label: raw,
                    baseURL: base,
                    projectsURL: base.appendingPathComponent("projects", isDirectory: true),
                    sessionsURL: base.appendingPathComponent("sessions", isDirectory: true)
                ))
            }
        }

        let includeImports = !activeOnly || active == "all" || active == "__trash__"
            || active == "__imported__"
        if includeImports {
            let base = configuration.importsRoot.resolvingSymlinksInPath().standardizedFileURL
            if seen.insert(base.path).inserted {
                result.append(HistoryDirectory(
                    id: "__imported__",
                    label: "导入",
                    baseURL: base,
                    projectsURL: base.appendingPathComponent("projects", isDirectory: true),
                    sessionsURL: base.appendingPathComponent("sessions", isDirectory: true)
                ))
            }
        }
        return result
    }

    func watchRoots() -> [URL] {
        directories().flatMap {
            [
                $0.projectsURL,
                $0.sessionsURL,
                $0.baseURL.appendingPathComponent("archived_sessions", isDirectory: true),
                $0.baseURL.appendingPathComponent("session-state", isDirectory: true),
                $0.baseURL.appendingPathComponent("conversations", isDirectory: true),
            ]
        }
    }

    /// Finds main transcripts for every supported producer. Container-shaped sources are walked
    /// to their exact leaf (`chat_history.jsonl`, `events.jsonl`, or `<uuid>.db`) so unrelated
    /// sidecars can never be mistaken for sessions. Symlinks are deliberately skipped.
    func discoverSessionFiles(activeOnly: Bool = true) -> [HistoryFileCandidate] {
        var seen = Set<String>()
        var result: [HistoryFileCandidate] = []

        for directory in directories(activeOnly: activeOnly) {
            let candidates = discoverProjectFiles(in: directory)
                + discoverSessionTreeFiles(in: directory)
                + discoverArchivedCodexFiles(in: directory)
                + discoverCopilotFiles(in: directory)
                + discoverAntigravityFiles(in: directory)
            for candidate in candidates {
                let resolved = candidate.file.resolvingSymlinksInPath().standardizedFileURL
                guard seen.insert(resolved.path).inserted else { continue }
                result.append(HistoryFileCandidate(
                    file: resolved,
                    projectDirectoryName: candidate.projectDirectoryName,
                    directory: directory,
                    formatHint: candidate.formatHint
                ))
            }
        }
        return result
    }

    /// Resolves an IPC-facing path back to a configured candidate. This intentionally does not
    /// accept every `.jsonl` beneath a base directory: Claude files must be direct children of a
    /// project bucket and Codex files must be inside the bounded sessions walk.
    func validatedCandidate(for requestedURL: URL) throws -> HistoryFileCandidate {
        guard requestedURL.isFileURL else { throw HistoryError.invalidPath(requestedURL) }
        let resolved = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        let fileExtension = resolved.pathExtension.lowercased()
        guard fileExtension == "jsonl" || fileExtension == "db" else {
            throw HistoryError.notARegularJSONLFile(requestedURL)
        }

        let values: URLResourceValues
        do {
            values = try requestedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw HistoryError.unreadableFile(requestedURL, String(describing: error))
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HistoryError.notARegularJSONLFile(requestedURL)
        }

        for directory in directories() {
            if !Self.isSymbolicLink(directory.projectsURL) {
                let projects = directory.projectsURL.resolvingSymlinksInPath().standardizedFileURL
                if fileExtension == "jsonl",
                   let relative = Self.relativeComponents(of: resolved, under: projects), relative.count == 2 {
                    try Self.requireUnlinkedPath(requestedURL, under: projects)
                    return HistoryFileCandidate(
                        file: resolved,
                        projectDirectoryName: relative.first,
                        directory: directory,
                        formatHint: Self.qoderHint(for: directory)
                    )
                }
            }
            if !Self.isSymbolicLink(directory.sessionsURL) {
                let sessions = directory.sessionsURL.resolvingSymlinksInPath().standardizedFileURL
                if fileExtension == "jsonl",
                   let relative = Self.relativeComponents(of: resolved, under: sessions), !relative.isEmpty {
                    if Self.isGrokCWDDirectoryName(relative[0]) {
                        guard relative.count == 3, relative.last == "chat_history.jsonl" else { continue }
                        try Self.requireUnlinkedPath(requestedURL, under: sessions)
                        return HistoryFileCandidate(
                            file: resolved,
                            projectDirectoryName: nil,
                            directory: directory,
                            formatHint: .grok
                        )
                    }
                    if relative.count <= 7 {
                        try Self.requireUnlinkedPath(requestedURL, under: sessions)
                        return HistoryFileCandidate(
                            file: resolved,
                            projectDirectoryName: nil,
                            directory: directory,
                            formatHint: .codex
                        )
                    }
                }
            }
            let archivedRaw = directory.baseURL.appendingPathComponent(
                "archived_sessions", isDirectory: true
            )
            if !Self.isSymbolicLink(archivedRaw) {
                let archived = archivedRaw.resolvingSymlinksInPath().standardizedFileURL
                if fileExtension == "jsonl",
                   let relative = Self.relativeComponents(of: resolved, under: archived),
                   !relative.isEmpty, relative.count <= 7 {
                    try Self.requireUnlinkedPath(requestedURL, under: archived)
                    return HistoryFileCandidate(
                        file: resolved,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .codex
                    )
                }
            }
            let sessionStateRaw = directory.baseURL.appendingPathComponent(
                "session-state", isDirectory: true
            )
            if !Self.isSymbolicLink(sessionStateRaw) {
                let sessionState = sessionStateRaw.resolvingSymlinksInPath().standardizedFileURL
                if fileExtension == "jsonl",
                   let relative = Self.relativeComponents(of: resolved, under: sessionState),
                   (relative.count == 1 || (relative.count == 2 && relative.last == "events.jsonl")) {
                    try Self.requireUnlinkedPath(requestedURL, under: sessionState)
                    return HistoryFileCandidate(
                        file: resolved,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .copilot
                    )
                }
            }
            let conversationsRaw = directory.baseURL.appendingPathComponent(
                "conversations", isDirectory: true
            )
            if !Self.isSymbolicLink(conversationsRaw) {
                let conversations = conversationsRaw.resolvingSymlinksInPath().standardizedFileURL
                if fileExtension == "db",
                   let relative = Self.relativeComponents(of: resolved, under: conversations),
                   relative.count == 1 {
                    try Self.requireUnlinkedPath(requestedURL, under: conversations)
                    return HistoryFileCandidate(
                        file: resolved,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .antigravity
                    )
                }
            }
        }
        throw HistoryError.pathOutsideConfiguredRoots(requestedURL)
    }

    private func discoverProjectFiles(in directory: HistoryDirectory) -> [HistoryFileCandidate] {
        guard Self.isDirectory(directory.projectsURL),
              !Self.isSymbolicLink(directory.projectsURL) else { return [] }
        var result: [HistoryFileCandidate] = []
        for project in Self.directoryContents(directory.projectsURL) where Self.isDirectory(project) {
            guard !Self.isSymbolicLink(project) else { continue }
            for file in Self.directoryContents(project) where Self.isSafeJSONLFile(file, under: directory.projectsURL) {
                result.append(HistoryFileCandidate(
                    file: file,
                    projectDirectoryName: project.lastPathComponent,
                    directory: directory,
                    formatHint: Self.qoderHint(for: directory)
                ))
            }
        }
        return result
    }

    private func discoverSessionTreeFiles(in directory: HistoryDirectory) -> [HistoryFileCandidate] {
        guard Self.isDirectory(directory.sessionsURL),
              !Self.isSymbolicLink(directory.sessionsURL) else { return [] }
        var result: [HistoryFileCandidate] = []

        func walkCodex(_ folder: URL, depth: Int) {
            guard depth <= 6 else { return }
            for entry in Self.directoryContents(folder) {
                if Self.isDirectory(entry) {
                    guard !Self.isSymbolicLink(entry) else { continue }
                    walkCodex(entry, depth: depth + 1)
                } else if Self.isSafeJSONLFile(entry, under: directory.sessionsURL) {
                    result.append(HistoryFileCandidate(
                        file: entry,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .codex
                    ))
                }
            }
        }

        for child in Self.directoryContents(directory.sessionsURL) {
            guard Self.isDirectory(child), !Self.isSymbolicLink(child) else {
                if Self.isSafeJSONLFile(child, under: directory.sessionsURL) {
                    result.append(HistoryFileCandidate(
                        file: child,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .codex
                    ))
                }
                continue
            }
            if Self.isGrokCWDDirectoryName(child.lastPathComponent) {
                for sessionDirectory in Self.directoryContents(child)
                    where Self.isDirectory(sessionDirectory) && !Self.isSymbolicLink(sessionDirectory) {
                    let chat = sessionDirectory.appendingPathComponent("chat_history.jsonl")
                    guard Self.isSafeJSONLFile(chat, under: directory.sessionsURL) else { continue }
                    result.append(HistoryFileCandidate(
                        file: chat,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .grok
                    ))
                }
            } else {
                walkCodex(child, depth: 1)
            }
        }
        return result
    }

    private func discoverArchivedCodexFiles(in directory: HistoryDirectory) -> [HistoryFileCandidate] {
        let root = directory.baseURL.appendingPathComponent("archived_sessions", isDirectory: true)
        guard Self.isDirectory(root), !Self.isSymbolicLink(root) else { return [] }
        var result: [HistoryFileCandidate] = []
        func walk(_ folder: URL, depth: Int) {
            guard depth <= 6 else { return }
            for entry in Self.directoryContents(folder) {
                if Self.isDirectory(entry) {
                    guard !Self.isSymbolicLink(entry) else { continue }
                    walk(entry, depth: depth + 1)
                } else if Self.isSafeJSONLFile(entry, under: root) {
                    result.append(HistoryFileCandidate(
                        file: entry,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .codex
                    ))
                }
            }
        }
        walk(root, depth: 0)
        return result
    }

    private func discoverCopilotFiles(in directory: HistoryDirectory) -> [HistoryFileCandidate] {
        let root = directory.baseURL.appendingPathComponent("session-state", isDirectory: true)
        guard Self.isDirectory(root), !Self.isSymbolicLink(root) else { return [] }
        var result: [HistoryFileCandidate] = []
        for entry in Self.directoryContents(root) {
            if Self.isDirectory(entry), !Self.isSymbolicLink(entry) {
                let events = entry.appendingPathComponent("events.jsonl")
                if Self.isSafeJSONLFile(events, under: root) {
                    result.append(HistoryFileCandidate(
                        file: events,
                        projectDirectoryName: nil,
                        directory: directory,
                        formatHint: .copilot
                    ))
                }
            } else if Self.isSafeJSONLFile(entry, under: root) {
                result.append(HistoryFileCandidate(
                    file: entry,
                    projectDirectoryName: nil,
                    directory: directory,
                    formatHint: .copilot
                ))
            }
        }
        return result
    }

    private func discoverAntigravityFiles(in directory: HistoryDirectory) -> [HistoryFileCandidate] {
        let root = directory.baseURL.appendingPathComponent("conversations", isDirectory: true)
        guard Self.isDirectory(root), !Self.isSymbolicLink(root) else { return [] }
        return Self.directoryContents(root).compactMap { file in
            guard Self.isSafeRegularFile(file, extension: "db", under: root) else { return nil }
            return HistoryFileCandidate(
                file: file,
                projectDirectoryName: nil,
                directory: directory,
                formatHint: .antigravity
            )
        }
    }

    private static func directoryContents(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.path < $1.path } ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func isSafeJSONLFile(_ url: URL, under root: URL) -> Bool {
        isSafeRegularFile(url, extension: "jsonl", under: root)
    }

    private static func isSafeRegularFile(_ url: URL, extension fileExtension: String, under root: URL) -> Bool {
        guard url.pathExtension.lowercased() == fileExtension,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        return relativeComponents(of: resolved, under: canonicalRoot) != nil
    }

    private static func qoderHint(for directory: HistoryDirectory) -> HistoryTranscriptFormat? {
        [".qoder", ".qoderwork"].contains(directory.baseURL.lastPathComponent) ? .qoder : nil
    }

    static func isGrokCWDDirectoryName(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.hasPrefix("%2f") || value.hasPrefix("%3a%5c")
    }

    /// The configured root itself may resolve through a user-selected symlink. Below that root,
    /// however, every component must be an ordinary directory/file so a later IPC read cannot
    /// take a different path than discovery did.
    private static func requireUnlinkedPath(_ requested: URL, under root: URL) throws {
        let raw = requested.standardizedFileURL
        guard let components = relativeComponents(of: raw, under: root), !components.isEmpty else {
            throw HistoryError.pathOutsideConfiguredRoots(requested)
        }
        var cursor = root
        for component in components {
            cursor.appendPathComponent(component)
            let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw HistoryError.notARegularJSONLFile(requested)
            }
        }
    }

    private static func relativeComponents(of child: URL, under root: URL) -> [String]? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.count > rootComponents.count,
              childComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else { return nil }
        return Array(childComponents.dropFirst(rootComponents.count))
    }
}
