import Foundation

enum HistorySessionLoadConsistency: Sendable {
    /// The catalog must never commit a parse produced from a mixture of dependency generations.
    case dependencyStable
    /// Detail/export callers may prefer the successfully parsed snapshot even if a producer
    /// appended again while it was being opened.
    case bestEffort
}

enum HistorySessionLoadError: LocalizedError, Equatable, Sendable {
    case dependenciesChanged(URL)

    var errorDescription: String? {
        switch self {
        case .dependenciesChanged(let file):
            "会话在读取时发生变化，请重试：\(file.path)"
        }
    }
}

struct LoadedHistorySession: Sendable {
    var session: HistorySession
    var projection: HistoryCatalogProjection
    var manifest: ConversationDependencyManifest
    var dependencySnapshot: ConversationDependencySnapshot
}

struct QuickLoadedHistorySession: Sendable {
    var candidate: HistoryFileCandidate
    var metadata: HistorySessionMetadata
    var manifest: ConversationDependencyManifest
    var dependencySnapshot: ConversationDependencySnapshot
}

/// Small enough for the indexer to replace with a counting/failing test double.
protocol HistorySessionLoading: Sendable {
    func prefetch(_ candidates: [HistoryFileCandidate])
    func loadQuickMetadata(_ candidates: [HistoryFileCandidate]) -> [QuickLoadedHistorySession]
    func load(
        _ candidate: HistoryFileCandidate,
        consistency: HistorySessionLoadConsistency
    ) throws -> LoadedHistorySession
}

extension HistorySessionLoading {
    func loadQuickMetadata(_ candidates: [HistoryFileCandidate]) -> [QuickLoadedHistorySession] {
        return []
    }

    func load(_ candidate: HistoryFileCandidate) throws -> LoadedHistorySession {
        try load(candidate, consistency: .dependencyStable)
    }
}

/// Owns the only producer-neutral raw-file-to-session path used by the new catalog. It deliberately
/// retains the existing parsers as the source of truth, including lossless raw content blocks.
struct HistorySessionLoader: HistorySessionLoading, Sendable {
    static let maximumQuickReadBytes = 256 * 1_024

    let configuration: HistoryConfiguration
    let qoderReader: QoderFileReader
    let adapters: ConversationSourceAdapterRegistry

    init(
        configuration: HistoryConfiguration,
        qoderReader: QoderFileReader = .shared,
        adapters: ConversationSourceAdapterRegistry = .init()
    ) {
        self.configuration = configuration
        self.qoderReader = qoderReader
        self.adapters = adapters
    }

    init(
        historyDirs: [String],
        active: String = "all",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        importsRoot: URL? = nil,
        qoderReader: QoderFileReader = .shared,
        adapters: ConversationSourceAdapterRegistry = .init()
    ) {
        self.init(
            configuration: HistoryConfiguration(
                historyDirs: historyDirs,
                active: active,
                homeDirectory: homeDirectory,
                importsRoot: importsRoot
            ),
            qoderReader: qoderReader,
            adapters: adapters
        )
    }

    var pathResolver: HistoryPathResolver {
        HistoryPathResolver(configuration: configuration)
    }

    func discoverCandidates(activeOnly: Bool = true) -> [HistoryFileCandidate] {
        adapters.discoverCandidates(configuration: configuration, activeOnly: activeOnly)
    }

    func prefetch(_ candidates: [HistoryFileCandidate]) {
        adapters.prefetch(candidates: candidates, qoderReader: qoderReader)
    }

    /// Wake-style metadata first pass. Ordinary transcripts are sampled through a bounded prefix;
    /// Qoder remains behind its permission-aware reader; Antigravity never opens the steps table.
    /// A bad producer file is skipped independently so one row cannot blank the cold catalog.
    func loadQuickMetadata(
        _ candidates: [HistoryFileCandidate]
    ) -> [QuickLoadedHistorySession] {
        // State is an independent quick-metadata source. Query it before prefix parsing so a
        // rollout whose first JSONL record is larger than the read budget still gets a cold row.
        let stateRows = CodexStateDatabase.quickMetadata(
            for: candidates.map(\.file),
            homeDirectory: configuration.homeDirectory
        )
        var loaded: [QuickLoadedHistorySession] = []
        for candidate in candidates {
            let state = stateRows[candidate.file.standardizedFileURL.path]
            if var value = try? loadQuickMetadata(candidate) {
                if value.metadata.source == .codex, let state {
                    value.metadata = Self.mergeCodexState(state, into: value.metadata)
                }
                loaded.append(value)
                continue
            }

            // A Qoder candidate must always remain behind its permission-aware reader. A Codex
            // state hit, by contrast, is authoritative enough to build metadata from file facts.
            let qoder = candidate.formatHint == .qoder
                || QoderFileReader.isQoderDataPath(candidate.file)
            guard !qoder, candidate.formatHint != .antigravity, let state,
                  let fallback = try? loadCodexStateQuickMetadata(candidate, state: state) else {
                continue
            }
            loaded.append(fallback)
        }
        return loaded
    }

    func load(
        _ candidate: HistoryFileCandidate,
        consistency: HistorySessionLoadConsistency = .dependencyStable
    ) throws -> LoadedHistorySession {
        let primaryRole: ConversationDependencyRole = candidate.formatHint == .antigravity
            ? .primaryDatabase
            : .primaryTranscript
        let primaryDependency = ConversationSourceDependency(
            file: candidate.file,
            role: primaryRole
        )
        let primaryBeforeRead = ConversationDependencyStamp.read(primaryDependency)

        let document: HistoryJSONLDocument?
        if candidate.formatHint == .antigravity {
            document = nil
        } else {
            document = try HistoryJSONLDocument.read(
                from: candidate.file,
                qoderReader: qoderReader
            )
        }

        let adapter = try adapters.adapter(for: candidate, document: document)
        let manifest = ConversationDependencyManifest(
            candidate: candidate,
            source: adapter.source,
            dependencies: adapter.dependencies(for: candidate, configuration: configuration)
        )
        let dependenciesBeforeParse = manifest.snapshot()
        if consistency == .dependencyStable,
           let primaryAfterRead = dependenciesBeforeParse.stamp(
               for: candidate.file,
               role: primaryRole
           ), primaryAfterRead != primaryBeforeRead {
            throw HistorySessionLoadError.dependenciesChanged(candidate.file)
        }

        let facts = try HistoryFileFacts.read(
            candidate.file,
            records: document?.records ?? []
        )
        var session = try adapter.parse(ConversationSourceParseInput(
            candidate: candidate,
            document: document,
            facts: facts,
            configuration: configuration
        ))
        if adapter.attachesSubagents {
            session = HistorySubagentReader.attach(
                to: session,
                mainRecords: document?.records ?? [],
                qoder: adapter.format == .qoder,
                qoderReader: qoderReader
            )
        }

        if session.metadata.source == .codex,
           let state = CodexStateDatabase.quickMetadata(
             for: [candidate.file],
             homeDirectory: configuration.homeDirectory
           )[candidate.file.standardizedFileURL.path] {
            session.metadata = Self.mergeCodexState(state, into: session.metadata)
        }

        let projection = HistoryCatalogProjection(session: session)
        let dependenciesAfterParse = manifest.snapshot()
        if consistency == .dependencyStable,
           dependenciesBeforeParse != dependenciesAfterParse {
            throw HistorySessionLoadError.dependenciesChanged(candidate.file)
        }
        return LoadedHistorySession(
            session: session,
            projection: projection,
            manifest: manifest,
            dependencySnapshot: dependenciesAfterParse
        )
    }

    func load(file: URL, consistency: HistorySessionLoadConsistency = .bestEffort) throws
        -> LoadedHistorySession {
        try load(pathResolver.validatedCandidate(for: file), consistency: consistency)
    }

    func load(filePath: String, consistency: HistorySessionLoadConsistency = .bestEffort) throws
        -> LoadedHistorySession {
        try load(file: URL(fileURLWithPath: filePath), consistency: consistency)
    }

    func getSession(file: URL) throws -> HistorySession {
        try load(file: file, consistency: .bestEffort).session
    }

    func getSession(filePath: String) throws -> HistorySession {
        try getSession(file: URL(fileURLWithPath: filePath))
    }

    private func loadQuickMetadata(
        _ candidate: HistoryFileCandidate
    ) throws -> QuickLoadedHistorySession {
        let facts = try HistoryFileFacts.read(candidate.file, records: [])
        let adapter: any ConversationSourceAdapter
        let metadata: HistorySessionMetadata

        if candidate.formatHint == .antigravity {
            guard let resolved = adapters.adapter(for: .antigravity) else {
                throw HistoryError.unsupportedTranscript(candidate.file)
            }
            adapter = resolved
            metadata = Self.antigravityMetadata(
                candidate: candidate,
                facts: facts,
                appDataRoot: configuration.appDataRoot
            )
        } else {
            let document = try quickDocument(candidate)
            adapter = try adapters.adapter(for: candidate, document: document)
            let session = try adapter.parse(ConversationSourceParseInput(
                candidate: candidate,
                document: document,
                facts: try HistoryFileFacts.read(candidate.file, records: document.records),
                configuration: configuration
            ))
            metadata = session.metadata
        }

        let manifest = ConversationDependencyManifest(
            candidate: candidate,
            source: adapter.source,
            dependencies: adapter.dependencies(for: candidate, configuration: configuration)
        )
        let snapshot = manifest.snapshot()
        guard let primary = manifest.primary,
              snapshot.stamp(for: primary.file, role: primary.role)?.kind == .regularFile else {
            throw HistoryError.unreadableFile(candidate.file, "会话主文件不可用")
        }
        return QuickLoadedHistorySession(
            candidate: candidate,
            metadata: metadata,
            manifest: manifest,
            dependencySnapshot: snapshot
        )
    }

    private func quickDocument(_ candidate: HistoryFileCandidate) throws -> HistoryJSONLDocument {
        let data: Data
        do {
            if candidate.formatHint == .qoder || QoderFileReader.isQoderDataPath(candidate.file) {
                data = try qoderReader.read(candidate.file)
            } else {
                let handle = try FileHandle(forReadingFrom: candidate.file)
                defer { try? handle.close() }
                data = try handle.read(upToCount: Self.maximumQuickReadBytes) ?? Data()
            }
        } catch {
            throw HistoryError.unreadableFile(candidate.file, String(describing: error))
        }

        let bounded = data.prefix(Self.maximumQuickReadBytes)
        if data.count < Self.maximumQuickReadBytes {
            // A short read reached EOF. Keep a valid final record even without its conventional
            // newline, but still discard a producer which stopped halfway through JSON/UTF-8.
            let tailStart = data.lastIndex(of: 0x0A).map { data.index(after: $0) }
                ?? data.startIndex
            let tail = Data(data[tailStart..<data.endIndex])
            if let text = String(data: data, encoding: .utf8),
               let tailText = String(data: tail, encoding: .utf8) {
                let tailDocument = HistoryJSONLDocument.parse(tailText)
                if tailDocument.diagnostics.malformedLines == 0 {
                    return HistoryJSONLDocument.parse(text)
                }
            }
        }
        guard let newline = bounded.lastIndex(of: 0x0A) else {
            // At the cap there is no proof that the final bytes form a complete JSON record.
            throw HistoryError.unsupportedTranscript(candidate.file)
        }
        let complete = Data(bounded[bounded.startIndex...newline])
        guard let text = String(data: complete, encoding: .utf8) else {
            throw HistoryError.unreadableFile(candidate.file, "文件前缀不是有效的 UTF-8 文本")
        }
        return HistoryJSONLDocument.parse(text)
    }

    private func loadCodexStateQuickMetadata(
        _ candidate: HistoryFileCandidate,
        state: CodexThreadQuickMetadata
    ) throws -> QuickLoadedHistorySession {
        guard let adapter = adapters.adapter(for: .codex) else {
            throw HistoryError.unsupportedTranscript(candidate.file)
        }
        let facts = try HistoryFileFacts.read(candidate.file, records: [])
        let stem = candidate.file.deletingPathExtension().lastPathComponent
        let autoTitle = Self.preferredCodexTitle(state) ?? stem
        let custom: ForeignHistoryCustomMetadata
        if candidate.directory.id == "__imported__" {
            custom = .init(title: nil, tags: [], deleted: false)
        } else {
            custom = ForeignHistorySupport.codexMetadata(
                sessionKey: stem,
                appDataRoot: configuration.appDataRoot
            )
        }
        let canonicalID = Self.nonempty(state.id) ?? stem
        var metadata = HistorySessionMetadata(
            id: "codex:\(candidate.directory.id):\(stem)",
            file: candidate.file,
            source: .codex,
            dirID: candidate.directory.id,
            dirLabel: candidate.directory.label,
            sessionID: canonicalID,
            threadID: canonicalID,
            rootSessionID: canonicalID,
            canonicalThreadIDValid: HistoryParsingSupport.isCanonicalThreadID(canonicalID),
            cwd: state.cwd,
            project: HistoryParsingSupport.projectName(
                cwd: state.cwd,
                encodedDirectory: candidate.projectDirectoryName
            ),
            gitBranch: state.gitBranch,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: state.model,
            imported: candidate.directory.id == "__imported__",
            deleted: custom.deleted,
            createdAt: state.createdAt ?? facts.createdAt,
            lastActivity: state.updatedAt ?? facts.modifiedAt,
            sizeBytes: facts.sizeBytes
        )
        metadata = Self.mergeCodexState(state, into: metadata)

        let manifest = ConversationDependencyManifest(
            candidate: candidate,
            source: adapter.source,
            dependencies: adapter.dependencies(for: candidate, configuration: configuration)
        )
        let snapshot = manifest.snapshot()
        guard let primary = manifest.primary,
              snapshot.stamp(for: primary.file, role: primary.role)?.kind == .regularFile else {
            throw HistoryError.unreadableFile(candidate.file, "会话主文件不可用")
        }
        return QuickLoadedHistorySession(
            candidate: candidate,
            metadata: metadata,
            manifest: manifest,
            dependencySnapshot: snapshot
        )
    }

    private static func antigravityMetadata(
        candidate: HistoryFileCandidate,
        facts: HistoryFileFacts,
        appDataRoot: URL
    ) -> HistorySessionMetadata {
        let stem = candidate.file.deletingPathExtension().lastPathComponent
        let custom = ForeignHistorySupport.customMetadata(
            source: .antigravity,
            sessionKey: stem,
            appDataRoot: appDataRoot
        )
        let fallbackTitle = stem
        return HistorySessionMetadata(
            id: "antigravity:\(stem)",
            file: candidate.file,
            source: .antigravity,
            dirID: candidate.directory.id,
            dirLabel: candidate.directory.label,
            sessionID: stem,
            project: HistoryPathResolver.baseName(of: candidate.directory.baseURL.path),
            title: custom.title ?? fallbackTitle,
            autoTitle: fallbackTitle,
            tags: custom.tags,
            imported: false,
            deleted: custom.deleted,
            createdAt: facts.createdAt,
            lastActivity: facts.modifiedAt,
            sizeBytes: facts.sizeBytes
        )
    }

    private static func mergeCodexState(
        _ state: CodexThreadQuickMetadata,
        into original: HistorySessionMetadata
    ) -> HistorySessionMetadata {
        var metadata = original
        let hasCustomTitle = !metadata.title.isEmpty && metadata.title != metadata.autoTitle
        if !hasCustomTitle, let stateTitle = preferredCodexTitle(state) {
            metadata.title = stateTitle
        }
        if !state.id.isEmpty {
            metadata.sessionID = state.id
            metadata.threadID = state.id
            metadata.rootSessionID = state.id
            metadata.canonicalThreadIDValid = HistoryParsingSupport.isCanonicalThreadID(state.id)
        }
        if let cwd = nonempty(state.cwd) {
            metadata.cwd = cwd
            metadata.project = HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil)
        }
        if let model = nonempty(state.model) { metadata.model = model }
        if let branch = nonempty(state.gitBranch) { metadata.gitBranch = branch }
        if let createdAt = state.createdAt { metadata.createdAt = createdAt }
        if let updatedAt = state.updatedAt { metadata.lastActivity = updatedAt }
        if let tokens = state.tokensUsed,
           metadata.totals.inputTokens == 0,
           metadata.totals.outputTokens == 0,
           metadata.totals.cacheRead == 0,
           metadata.totals.cacheCreation == 0 {
            // Codex exposes only an aggregate here. The quick row uses the existing aggregate sum
            // slot and is replaced by exact per-direction transcript totals after the full parse.
            metadata.totals.inputTokens = tokens
            metadata.totals.tokenUsageAvailable = true
        }
        return metadata
    }

    private static func preferredCodexTitle(_ state: CodexThreadQuickMetadata) -> String? {
        if let name = usableCodexTitle(state.name, rejectsInjectedContent: false) { return name }
        return usableCodexTitle(state.title, rejectsInjectedContent: true)
    }

    private static func usableCodexTitle(
        _ raw: String?,
        rejectsInjectedContent: Bool
    ) -> String? {
        guard let raw = nonempty(raw), raw.caseInsensitiveCompare("Untitled") != .orderedSame else {
            return nil
        }
        if rejectsInjectedContent {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let injectedPrefixes = [
                "<recommended_plugins", "<environment_context", "<user_instructions",
                "<permissions", "<workspace", "<system-", "<context ", "<session_context",
                "IMPORTANT: Do NOT read", "Caveat: The messages below",
                "# Files pasted by the user",
            ]
            if injectedPrefixes.contains(where: value.hasPrefix)
                || value.contains("/.codex/plugins/")
                || (value.contains("/plugins/cache/") && value.contains("SKILL.md")) {
                return nil
            }
        }
        let compact = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return compact.count > 90 ? String(compact.prefix(90)) : compact
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
