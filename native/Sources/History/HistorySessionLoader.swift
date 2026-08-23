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

/// Small enough for the indexer to replace with a counting/failing test double.
protocol HistorySessionLoading: Sendable {
    func prefetch(_ candidates: [HistoryFileCandidate])
    func load(
        _ candidate: HistoryFileCandidate,
        consistency: HistorySessionLoadConsistency
    ) throws -> LoadedHistorySession
}

extension HistorySessionLoading {
    func load(_ candidate: HistoryFileCandidate) throws -> LoadedHistorySession {
        try load(candidate, consistency: .dependencyStable)
    }
}

/// Owns the only producer-neutral raw-file-to-session path used by the new catalog. It deliberately
/// retains the existing parsers as the source of truth, including lossless raw content blocks.
struct HistorySessionLoader: HistorySessionLoading, Sendable {
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
}
