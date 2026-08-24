import Foundation

private struct PiFamilyAdapterCore {
    var source: HistorySource
    var format: HistoryTranscriptFormat
    var label: String
    var rootComponent: String

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(rootComponent)
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : root.deletingLastPathComponent().deletingLastPathComponent()
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: label,
            baseURL: base,
            discoveryRoot: root
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        return WakeHistoryAdapterSupport.jsonlFiles(in: root).map { file in
            HistoryFileCandidate(
                file: file,
                projectDirectoryName: file.deletingLastPathComponent().lastPathComponent,
                directory: directory,
                formatHint: format,
                nativeID: nativeID(file)
            )
        }
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(rootComponent)
        )
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        [
            .init(file: candidate.file, role: .primaryTranscript),
            .init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
    }

    func context(_ input: ConversationSourceParseInput) throws -> HistoryParseContext {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        )
    }

    private func nativeID(_ file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let separator = stem.lastIndex(of: "_"),
              separator < stem.index(before: stem.endIndex) else { return stem }
        return String(stem[stem.index(after: separator)...])
    }
}

struct PiConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.pi
    let format = HistoryTranscriptFormat.pi

    private var core: PiFamilyAdapterCore {
        .init(
            source: source,
            format: format,
            label: "Pi",
            rootComponent: ".pi/agent/sessions"
        )
    }

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        core.discover(configuration: configuration, activeOnly: activeOnly)
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        core.watchRoots(configuration: configuration)
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        core.dependencies(candidate: candidate, configuration: configuration)
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        PiHistoryParser.parse(try core.context(input))
    }
}

struct OMPConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.omp
    let format = HistoryTranscriptFormat.omp

    private var core: PiFamilyAdapterCore {
        .init(
            source: source,
            format: format,
            label: "Oh My Pi",
            rootComponent: ".omp/agent/sessions"
        )
    }

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        core.discover(configuration: configuration, activeOnly: activeOnly)
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        core.watchRoots(configuration: configuration)
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        core.dependencies(candidate: candidate, configuration: configuration)
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        OMPHistoryParser.parse(try core.context(input))
    }
}
