import Darwin
import Foundation
import SQLite3

struct ConversationMetadataPatch: Equatable, Sendable {
    var title: String?
    var tags: [String]?
    var deleted: Bool?
    var starred: Bool?
    var pinned: Bool?

    init(
        title: String? = nil,
        tags: [String]? = nil,
        deleted: Bool? = nil,
        starred: Bool? = nil,
        pinned: Bool? = nil
    ) {
        self.title = title
        self.tags = tags
        self.deleted = deleted
        self.starred = starred
        self.pinned = pinned
    }

    var userMetadataPatch: ConversationUserMetadataPatch {
        .init(
            title: title,
            tags: tags,
            deleted: deleted,
            starred: starred,
            pinned: pinned
        )
    }
}

enum ConversationImportDisposition: Equatable, Sendable {
    case imported(URL)
    case skipped(URL)
    case failed(URL, String)
}

struct ConversationImportSummary: Equatable, Sendable {
    var imported = 0
    var skipped = 0
    var failed = 0
    var results: [ConversationImportDisposition] = []

    mutating func append(_ result: ConversationImportDisposition) {
        results.append(result)
        switch result {
        case .imported: imported += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
    }
}

struct ConversationRawExportResult: Equatable, Sendable {
    var destination: URL
    var bundled: Bool
    var fileExtension: String
}

enum ConversationMutationError: LocalizedError, Equatable, Sendable {
    case invalidPath(URL)
    case outsideAllowedRoots(URL)
    case symbolicLink(URL)
    case notRegularFile(URL)
    case unsupportedFile(URL)
    case unreadable(URL, String)
    case invalidMetadata(String)
    case noConversationRecords
    case unsupportedTranscript
    case foreignTranscript
    case conflict(URL)
    case foreignPermanentDelete
    case unsafeCompanion(URL)
    case writeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let file): "无效路径：\(file.path)"
        case .outsideAllowedRoots(let file): "路径不在已配置的会话目录内：\(file.path)"
        case .symbolicLink(let file): "为安全起见拒绝符号链接：\(file.path)"
        case .notRegularFile(let file): "会话不是普通文件：\(file.path)"
        case .unsupportedFile(let file): "不支持的会话文件：\(file.lastPathComponent)"
        case .unreadable(let file, let detail): "无法读取 \(file.lastPathComponent)：\(detail)"
        case .invalidMetadata(let detail): "会话元数据无效：\(detail)"
        case .noConversationRecords: "文件中没有可导入的会话消息"
        case .unsupportedTranscript: "无法识别该 JSONL 会话格式"
        case .foreignTranscript: "Grok、Copilot 等外部会话不能作为裸 JSONL 导入"
        case .conflict(let file): "会话在编辑期间已被其他进程修改，请刷新后重试：\(file.lastPathComponent)"
        case .foreignPermanentDelete: "生产工具的原始会话为只读；只有导入的副本可以永久删除"
        case .unsafeCompanion(let file): "会话的关联文件不安全，已停止删除：\(file.path)"
        case .writeFailed(let file, let detail): "无法写入 \(file.lastPathComponent)：\(detail)"
        }
    }
}

struct ConversationMutationConfiguration: Equatable, Sendable {
    var historyDirs: [String]
    var homeDirectory: URL
    var importsRoot: URL
    var sessionLocationOverrides: ConversationSessionLocationOverrides

    init(
        historyDirs: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        importsRoot: URL? = nil,
        sessionLocationOverrides: ConversationSessionLocationOverrides = .init()
    ) {
        self.historyDirs = historyDirs
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.importsRoot = (importsRoot ?? homeDirectory
            .appendingPathComponent(".ccbud", isDirectory: true)
            .appendingPathComponent("imports", isDirectory: true)).standardizedFileURL
        self.sessionLocationOverrides = sessionLocationOverrides
    }

    var appDataRoot: URL { importsRoot.deletingLastPathComponent() }
    var conversationDatabase: URL {
        appDataRoot.appendingPathComponent("conversation-index-v1.sqlite3")
    }
}

/// The only write-capable history component. Every target is scoped to a configured producer tree
/// or the app-owned import store, and every existing path component is checked with `lstat` before
/// mutation so a symlink cannot redirect an edit/delete outside that scope.
struct ConversationMutationService: @unchecked Sendable {
    private struct StableRead {
        var data: Data
    }

    private struct ValidatedStorage {
        var file: URL
        var isContainerBacked: Bool
        var subagentFiles: [URL]
    }

    private struct PreparedImport {
        var data: Data
        var records: [[String: HistoryValue]]
        var format: HistoryTranscriptFormat
        var cwd: String?
        var sessionID: String
        var qoderNormalized: Bool
    }

    let configuration: ConversationMutationConfiguration
    private let fileManager: FileManager
    private let archiveLimits: ConversationArchiveLimits
    private let metadataDatabase: ConversationIndexDatabase?
    private let metadataDatabaseOpenError: String?
    private let sourceAdapters: ConversationSourceAdapterRegistry
    private let qoderReader: QoderFileReader

    init(
        configuration: ConversationMutationConfiguration,
        fileManager: FileManager = .default,
        archiveLimits: ConversationArchiveLimits = .init(),
        metadataDatabase: ConversationIndexDatabase? = nil,
        sourceAdapters: ConversationSourceAdapterRegistry = .init(),
        qoderReader: QoderFileReader = .shared
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.archiveLimits = archiveLimits
        self.sourceAdapters = sourceAdapters
        self.qoderReader = qoderReader
        if let metadataDatabase {
            self.metadataDatabase = metadataDatabase
            metadataDatabaseOpenError = nil
        } else {
            do {
                self.metadataDatabase = try ConversationIndexDatabase(
                    file: configuration.conversationDatabase
                )
                metadataDatabaseOpenError = nil
            } catch {
                self.metadataDatabase = nil
                metadataDatabaseOpenError = error.localizedDescription
            }
        }
    }

    func updateMetadata(
        for metadata: HistorySessionMetadata,
        patch: ConversationMetadataPatch
    ) throws {
        // Container-backed sources expose a stable virtual URL per conversation. Validate the
        // physical database, but deliberately keep the logical URL as the app-owned metadata key.
        _ = try validatedStorage(for: metadata)
        guard let metadataDatabase else {
            throw ConversationMutationError.writeFailed(
                configuration.conversationDatabase,
                metadataDatabaseOpenError ?? "无法打开会话元数据数据库"
            )
        }
        _ = try metadataDatabase.updateUserMetadata(
            for: metadata.file.standardizedFileURL,
            patch: patch.userMetadataPatch
        )
    }

    func softDelete(_ metadata: HistorySessionMetadata) throws {
        try updateMetadata(for: metadata, patch: .init(deleted: true))
    }

    func restore(_ metadata: HistorySessionMetadata) throws {
        try updateMetadata(for: metadata, patch: .init(deleted: false))
    }

    func canPermanentlyDelete(_ metadata: HistorySessionMetadata) -> Bool {
        let imports = configuration.importsRoot
            .appendingPathComponent("projects", isDirectory: true)
            .standardizedFileURL
        return metadata.imported
            && isWithin(metadata.file.standardizedFileURL, root: imports)
    }

    func permanentlyDelete(_ metadata: HistorySessionMetadata) throws {
        guard canPermanentlyDelete(metadata) else {
            throw ConversationMutationError.foreignPermanentDelete
        }
        try validateImportStoreRootChain()
        let file = try validateScopedRegularFile(metadata.file)
        let directory = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { throw ConversationMutationError.invalidPath(file) }
        let importSidecar = directory.appendingPathComponent("\(stem).import.json")
        let subagentRoot = directory.appendingPathComponent(stem, isDirectory: true)

        if fileManager.fileExists(atPath: importSidecar.path) {
            try validateScopedNode(importSidecar, expectedDirectory: false)
        }
        if fileManager.fileExists(atPath: subagentRoot.path) {
            try validateScopedTree(subagentRoot)
        }

        // Delete companions first. If one cannot be removed the main transcript remains visible
        // and recoverable instead of leaving an orphaned import record.
        do {
            if fileManager.fileExists(atPath: subagentRoot.path) {
                try fileManager.removeItem(at: subagentRoot)
            }
            if fileManager.fileExists(atPath: importSidecar.path) {
                try fileManager.removeItem(at: importSidecar)
            }
            try fileManager.removeItem(at: file)
            if let metadataDatabase {
                _ = try metadataDatabase.removeUserMetadata(for: file)
            }
        } catch {
            throw ConversationMutationError.writeFailed(file, String(describing: error))
        }
    }

    func importFile(_ source: URL) -> ConversationImportDisposition {
        do {
            guard source.isFileURL else { throw ConversationMutationError.invalidPath(source) }
            let values = try source.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ConversationMutationError.symbolicLink(source)
            }
            guard values.isRegularFile == true else {
                throw ConversationMutationError.notRegularFile(source)
            }
            guard (values.fileSize ?? 0) <= archiveLimits.maximumArchiveBytes else {
                throw ConversationArchiveError.archiveTooLarge
            }

            let lowerExtension = source.pathExtension.lowercased()
            let raw: Data
            let subagents: [ConversationArchiveEntry]
            switch lowerExtension {
            case "jsonl":
                raw = try Data(contentsOf: source, options: [.mappedIfSafe])
                subagents = try readSubagentFiles(
                    for: source,
                    manifestFiles: [],
                    validationRoot: source.deletingLastPathComponent()
                )
            case "zip":
                let archive = try Data(contentsOf: source, options: [.mappedIfSafe])
                let bundle = try ConversationArchive.splitBundle(
                    ConversationArchive.read(archive, limits: archiveLimits)
                )
                raw = bundle.main.data
                subagents = bundle.subagents
            default:
                throw ConversationMutationError.unsupportedFile(source)
            }

            let prepared = try prepareImport(raw, fallbackName: source.lastPathComponent)
            let destination = try writeImport(
                prepared,
                source: source,
                originalName: source.lastPathComponent,
                subagents: subagents
            )
            return destination.1 ? .skipped(destination.0) : .imported(destination.0)
        } catch {
            return .failed(source, error.localizedDescription)
        }
    }

    func importFiles(_ sources: [URL]) -> ConversationImportSummary {
        var summary = ConversationImportSummary()
        for source in sources { summary.append(importFile(source)) }
        return summary
    }

    func suggestedRawFileExtension(for metadata: HistorySessionMetadata) throws -> String {
        let storage = try validatedStorage(for: metadata)
        if storage.isContainerBacked || metadata.source == .antigravity {
            return storage.file.pathExtension.isEmpty ? "db" : storage.file.pathExtension
        }
        if storage.file.lastPathComponent.hasSuffix(".jsonl.zstd") {
            return "jsonl.zstd"
        }
        return try readSubagentFiles(
            for: storage.file,
            manifestFiles: storage.subagentFiles
        ).isEmpty ? "jsonl" : "zip"
    }

    func exportRaw(
        _ metadata: HistorySessionMetadata,
        to destination: URL
    ) throws -> ConversationRawExportResult {
        let storage = try validatedStorage(for: metadata)
        let source = storage.file
        let databaseBacked = storage.isContainerBacked || metadata.source == .antigravity
        let sourceData = databaseBacked
            ? try consistentSQLiteSnapshot(source)
            : try stableRead(source).data
        let subagents = databaseBacked ? [] : try readSubagentFiles(
            for: source,
            manifestFiles: storage.subagentFiles
        )
        let data: Data
        let fileExtension: String
        let bundled: Bool
        if databaseBacked {
            data = sourceData
            fileExtension = source.pathExtension.isEmpty ? "db" : source.pathExtension
            bundled = false
        } else if subagents.isEmpty {
            data = sourceData
            fileExtension = source.lastPathComponent.hasSuffix(".jsonl.zstd")
                ? "jsonl.zstd"
                : "jsonl"
            bundled = false
        } else {
            let mainName = source.lastPathComponent.isEmpty ? "conversation.jsonl" : source.lastPathComponent
            data = try ConversationArchive.build(
                entries: [.init(name: mainName, data: sourceData)] + subagents.map {
                    .init(name: "subagents/\($0.name)", data: $0.data)
                },
                limits: archiveLimits
            )
            fileExtension = "zip"
            bundled = true
        }
        do {
            try SecureAtomicFile.write(data, to: destination, fileManager: fileManager)
        } catch {
            throw ConversationMutationError.writeFailed(destination, String(describing: error))
        }
        return ConversationRawExportResult(
            destination: destination,
            bundled: bundled,
            fileExtension: fileExtension
        )
    }

    // MARK: - Import

    private func prepareImport(_ data: Data, fallbackName: String) throws -> PreparedImport {
        guard data.count <= archiveLimits.maximumEntryBytes else {
            throw ConversationArchiveError.entryTooLarge(fallbackName)
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ConversationMutationError.unreadable(
                URL(fileURLWithPath: fallbackName),
                "文件不是有效 UTF-8"
            )
        }
        let document = HistoryJSONLDocument.parse(raw)
        guard !document.records.isEmpty else { throw ConversationMutationError.noConversationRecords }
        if looksForeignJSONL(document.records) { throw ConversationMutationError.foreignTranscript }
        guard let detected = HistoryTranscriptFormat.detect(document.records),
              detected == .claude || detected == .codex || detected == .qoder else {
            throw ConversationMutationError.unsupportedTranscript
        }

        let fallbackStem = URL(fileURLWithPath: fallbackName)
            .deletingPathExtension().lastPathComponent
        if detected == .codex {
            let normalized = CodexMessageNormalizer.normalize(document.records)
            guard !normalized.messages.isEmpty else { throw ConversationMutationError.noConversationRecords }
            return PreparedImport(
                data: data,
                records: document.records,
                format: .codex,
                cwd: normalized.cwd,
                sessionID: normalized.identity.threadID
                    ?? normalized.identity.rootSessionID
                    ?? fallbackStem,
                qoderNormalized: false
            )
        }

        let qoder = detected == .qoder
        var records = qoder ? QoderHistoryParser.normalize(document.records) : document.records
        let hasMessage = records.contains { record in
            let type = record["type"]?.stringValue
            return (type == "user" || type == "assistant") && record["message"] != nil
        }
        guard hasMessage else { throw ConversationMutationError.noConversationRecords }
        if qoder, let title = qoderTitle(document.records),
           let first = records.indices.first(where: { _ in true }) {
            var object = records[first]
            var custom = object["__ccbud__"]?.objectValue ?? [:]
            if custom["title"] == nil { custom["title"] = .string(title) }
            object["__ccbud__"] = .object(custom)
            records[first] = object
        }
        let metadata = records.first(where: { $0["cwd"] != nil })
            ?? records.first(where: { $0["sessionId"] != nil })
        let cwd = qoderWorkingDirectory(document.records) ?? metadata?["cwd"]?.stringValue
        let sessionID = metadata?["sessionId"]?.stringValue ?? fallbackStem
        let output = qoder ? try encodeJSONL(records) : data
        return PreparedImport(
            data: output,
            records: records,
            format: detected,
            cwd: cwd,
            sessionID: sessionID,
            qoderNormalized: qoder
        )
    }

    private func writeImport(
        _ prepared: PreparedImport,
        source: URL,
        originalName: String,
        subagents: [ConversationArchiveEntry]
    ) throws -> (URL, Bool) {
        try ensureImportsDirectory()
        let cwd = safeDirectoryName(prepared.cwd)
        let stem = safeIdentifier(prepared.sessionID, fallback: source.deletingPathExtension().lastPathComponent)
        let destinationDirectory = configuration.importsRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(cwd, isDirectory: true)
        try createOwnedDirectory(destinationDirectory)
        let destination = destinationDirectory.appendingPathComponent("\(stem).jsonl")
        try rejectSymlink(destination, allowMissing: true, rootedAt: configuration.importsRoot)
        if fileManager.fileExists(atPath: destination.path) { return (destination, true) }

        let importSidecar = destinationDirectory.appendingPathComponent("\(stem).import.json")
        let subagentRoot = destinationDirectory
            .appendingPathComponent(stem, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        var createdSubagentContainer = false
        var createdSidecar = false
        do {
            if !subagents.isEmpty {
                try createOwnedDirectory(subagentRoot)
                createdSubagentContainer = true
                var seen = Set<String>()
                for entry in subagents {
                    guard ConversationArchive.isSubagentBasename(entry.name),
                          seen.insert(entry.name.lowercased()).inserted else { continue }
                    var bytes = entry.data
                    if prepared.qoderNormalized, entry.name.lowercased().hasSuffix(".jsonl") {
                        guard let text = String(data: bytes, encoding: .utf8) else { continue }
                        bytes = try encodeJSONL(QoderHistoryParser.normalize(
                            HistoryJSONLDocument.parse(text).records
                        ))
                    }
                    let target = subagentRoot.appendingPathComponent(entry.name)
                    try rejectSymlink(target, allowMissing: true, rootedAt: configuration.importsRoot)
                    try atomicCreate(bytes, at: target)
                }
            }

            let manifest: [String: Any] = [
                "originalPath": source.path,
                "originalName": originalName,
                "sessionId": stem,
                "importedAt": Int64(Date().timeIntervalSince1970 * 1_000),
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try atomicCreate(manifestData, at: importSidecar)
            createdSidecar = true

            // Publishing the main file last makes the import appear atomically to history scans.
            try atomicCreate(prepared.data, at: destination)
            return (destination, false)
        } catch {
            if createdSidecar { try? fileManager.removeItem(at: importSidecar) }
            if createdSubagentContainer {
                try? fileManager.removeItem(at: subagentRoot.deletingLastPathComponent())
            }
            if (error as? POSIXError)?.code == .EEXIST { return (destination, true) }
            throw error
        }
    }

    private func readSubagentFiles(
        for transcript: URL,
        manifestFiles: [URL],
        validationRoot: URL? = nil
    ) throws -> [ConversationArchiveEntry] {
        guard transcript.isFileURL else { throw ConversationMutationError.invalidPath(transcript) }
        let files: [URL]
        if manifestFiles.isEmpty {
            let stem = transcript.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty else { return [] }
            let root = transcript.deletingLastPathComponent()
                .appendingPathComponent(stem, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { return [] }
            try rejectSymlink(
                root,
                allowMissing: false,
                rootedAt: transcript.deletingLastPathComponent()
            )
            files = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } else {
            files = manifestFiles
        }

        var result: [ConversationArchiveEntry] = []
        var seenNames = Set<String>()
        var total = 0
        for file in files.sorted(by: { $0.path < $1.path })
            where ConversationArchive.isSubagentBasename(file.lastPathComponent)
                && seenNames.insert(file.lastPathComponent.lowercased()).inserted {
            if let validationRoot {
                _ = try validateRegularFile(file, rootedAt: validationRoot)
            } else {
                _ = try validateScopedRegularFile(file)
            }
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ConversationMutationError.symbolicLink(file)
            }
            guard values.isRegularFile == true else { continue }
            let count = values.fileSize ?? 0
            guard count <= archiveLimits.maximumEntryBytes else {
                throw ConversationArchiveError.entryTooLarge(file.lastPathComponent)
            }
            guard total <= archiveLimits.maximumExpandedBytes - count else {
                throw ConversationArchiveError.expandedDataTooLarge
            }
            let data = try stableRead(file).data
            total += data.count
            result.append(.init(name: file.lastPathComponent, data: data))
        }
        return result
    }

    private func looksForeignJSONL(_ records: [[String: HistoryValue]]) -> Bool {
        records.prefix(8).contains { record in
            let type = record["type"]?.stringValue ?? ""
            switch type {
            case "session.start", "user.message", "assistant.message",
                 "tool.execution_complete", "tool.execution_start":
                return true
            case "reasoning", "tool_result":
                return record["message"] == nil
            case "system":
                return record["content"] != nil && record["message"] == nil
            default:
                return false
            }
        }
    }

    private func qoderTitle(_ records: [[String: HistoryValue]]) -> String? {
        for (type, field) in [
            ("custom-title", "customTitle"),
            ("ai-title", "aiTitle"),
            ("last-prompt", "lastPrompt"),
        ] {
            if let value = records.reversed().lazy.compactMap({ record -> String? in
                guard record["type"]?.stringValue == type else { return nil }
                return record[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }).first(where: { !$0.isEmpty }) { return value }
        }
        return nil
    }

    private func qoderWorkingDirectory(_ records: [[String: HistoryValue]]) -> String? {
        records.reversed().lazy.compactMap { record -> String? in
            guard record["type"]?.stringValue == "workspace-directories" else { return nil }
            return record["directories"]?.arrayValue?.compactMap(\.stringValue).first
        }.first
    }

    private func encodeJSONL(_ records: [[String: HistoryValue]]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try records.map { record -> String in
            let data = try encoder.encode(HistoryValue.object(record))
            guard let value = String(data: data, encoding: .utf8) else {
                throw ConversationMutationError.invalidMetadata("JSONL 不是 UTF-8")
            }
            return value
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - Scope, conflicts, and atomic creation

    private var allowedRoots: [URL] {
        let producerRoots = sourceAdapters.ownedRoots(configuration: historyConfiguration)
        return producerRoots + [
            configuration.importsRoot.appendingPathComponent("projects", isDirectory: true)
                .standardizedFileURL,
        ]
    }

    private var historyConfiguration: HistoryConfiguration {
        HistoryConfiguration(
            historyDirs: configuration.historyDirs,
            active: "all",
            homeDirectory: configuration.homeDirectory,
            importsRoot: configuration.importsRoot,
            sessionLocationOverrides: configuration.sessionLocationOverrides
        )
    }

    /// Permanent deletion is intentionally limited to the app-owned import store. Lexical path
    /// containment alone is not sufficient here: replacing `imports` or `projects` with a symlink
    /// would make a descendant `lstat` follow that intermediate link into an unrelated tree.
    private func validateImportStoreRootChain() throws {
        let appDataRoot = configuration.appDataRoot.standardizedFileURL
        let importsRoot = configuration.importsRoot.standardizedFileURL
        let projectsRoot = importsRoot
            .appendingPathComponent("projects", isDirectory: true)
            .standardizedFileURL

        guard importsRoot.deletingLastPathComponent().standardizedFileURL == appDataRoot,
              projectsRoot.deletingLastPathComponent().standardizedFileURL == importsRoot else {
            throw ConversationMutationError.outsideAllowedRoots(projectsRoot)
        }
        for directory in [appDataRoot, importsRoot, projectsRoot] {
            var facts = stat()
            guard lstat(directory.path, &facts) == 0 else {
                throw ConversationMutationError.unsafeCompanion(directory)
            }
            if facts.st_mode & S_IFMT == S_IFLNK {
                throw ConversationMutationError.symbolicLink(directory)
            }
            guard facts.st_mode & S_IFMT == S_IFDIR else {
                throw ConversationMutationError.unsafeCompanion(directory)
            }
        }
    }

    private func validatedStorage(
        for metadata: HistorySessionMetadata
    ) throws -> ValidatedStorage {
        let logical = metadata.file.standardizedFileURL
        let candidate = try? sourceAdapters.candidate(
            for: logical,
            configuration: historyConfiguration
        )
        let physical = candidate?.primaryStorageFile ?? logical
        var subagentFiles: [URL] = []
        if let candidate,
           let format = candidate.formatHint,
           let manifest = try? sourceAdapters.manifest(
               for: candidate,
               format: format,
               configuration: historyConfiguration
           ) {
            var seen = Set<String>()
            subagentFiles = manifest.dependencies.compactMap { dependency in
                guard dependency.role == .subagentTranscript
                        || dependency.role == .subagentMetadata else { return nil }
                let file = dependency.file.standardizedFileURL
                return seen.insert(file.path).inserted ? file : nil
            }
        }
        return ValidatedStorage(
            file: try validateScopedRegularFile(physical),
            isContainerBacked: candidate?.backingFile != nil || physical.path != logical.path,
            subagentFiles: subagentFiles
        )
    }

    private func validateScopedRegularFile(_ requested: URL) throws -> URL {
        guard requested.isFileURL else { throw ConversationMutationError.invalidPath(requested) }
        let file = requested.standardizedFileURL
        guard let root = allowedRoots.first(where: { isWithin(file, root: $0) }) else {
            throw ConversationMutationError.outsideAllowedRoots(file)
        }
        return try validateRegularFile(file, rootedAt: root)
    }

    private func validateRegularFile(_ requested: URL, rootedAt root: URL) throws -> URL {
        guard requested.isFileURL else { throw ConversationMutationError.invalidPath(requested) }
        let file = requested.standardizedFileURL
        guard isWithin(file, root: root.standardizedFileURL) else {
            throw ConversationMutationError.outsideAllowedRoots(file)
        }
        try rejectSymlink(file, allowMissing: false, rootedAt: root)
        var facts = stat()
        guard lstat(file.path, &facts) == 0 else {
            throw ConversationMutationError.notRegularFile(file)
        }
        guard facts.st_mode & S_IFMT == S_IFREG else {
            throw ConversationMutationError.notRegularFile(file)
        }
        return file
    }

    private func validateScopedNode(_ requested: URL, expectedDirectory: Bool) throws {
        guard let root = allowedRoots.first(where: { isWithin(requested, root: $0) }) else {
            throw ConversationMutationError.outsideAllowedRoots(requested)
        }
        try rejectSymlink(requested, allowMissing: false, rootedAt: root)
        var facts = stat()
        guard lstat(requested.path, &facts) == 0 else {
            throw ConversationMutationError.unsafeCompanion(requested)
        }
        let type = facts.st_mode & S_IFMT
        guard expectedDirectory ? type == S_IFDIR : type == S_IFREG else {
            throw ConversationMutationError.unsafeCompanion(requested)
        }
    }

    private func validateScopedTree(_ root: URL) throws {
        try validateScopedNode(root, expectedDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw ConversationMutationError.unsafeCompanion(root) }
        while let node = enumerator.nextObject() as? URL {
            var facts = stat()
            guard lstat(node.path, &facts) == 0,
                  facts.st_mode & S_IFMT != S_IFLNK else {
                throw ConversationMutationError.unsafeCompanion(node)
            }
        }
    }

    private func rejectSymlink(_ file: URL, allowMissing: Bool, rootedAt rawRoot: URL) throws {
        let root = rawRoot.standardizedFileURL
        let target = file.standardizedFileURL
        guard let relative = relativeComponents(target, under: root) else {
            throw ConversationMutationError.outsideAllowedRoots(target)
        }
        var cursor = root
        for (index, component) in relative.enumerated() {
            cursor.appendPathComponent(component)
            var facts = stat()
            if lstat(cursor.path, &facts) != 0 {
                if errno == ENOENT, allowMissing, index == relative.count - 1 { return }
                if errno == ENOENT, allowMissing { continue }
                throw ConversationMutationError.notRegularFile(cursor)
            }
            if facts.st_mode & S_IFMT == S_IFLNK {
                throw ConversationMutationError.symbolicLink(cursor)
            }
        }
    }

    private func stableRead(_ file: URL) throws -> StableRead {
        let before = try structuralFingerprint(file)
        let data: Data
        do {
            data = QoderFileReader.isQoderDataPath(file)
                ? try qoderReader.read(file)
                : try Data(contentsOf: file, options: [.mappedIfSafe])
        }
        catch { throw ConversationMutationError.unreadable(file, String(describing: error)) }
        let after = try structuralFingerprint(file)
        guard before == after else { throw ConversationMutationError.conflict(file) }
        return StableRead(data: data)
    }

    /// A plain copy can omit committed rows which still live in `-wal`. SQLite's online backup
    /// API reads the same consistent view as the producer without checkpointing or mutating it.
    private func consistentSQLiteSnapshot(_ source: URL) throws -> Data {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                _ = try validateScopedRegularFile(sidecar)
            }
        }

        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "ccbud-sqlite-export-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ConversationMutationError.writeFailed(
                temporaryDirectory,
                String(describing: error)
            )
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let temporary = temporaryDirectory.appendingPathComponent("snapshot.db")

        var input: OpaquePointer?
        var outputConnection: OpaquePointer?
        guard sqlite3_open_v2(
            source.path,
            &input,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let input else {
            if let input { sqlite3_close(input) }
            throw ConversationMutationError.unreadable(source, "无法打开 SQLite 会话")
        }
        defer { sqlite3_close(input) }
        sqlite3_busy_timeout(input, 1_000)
        let sourcePageCount = sqliteInteger("PRAGMA page_count", database: input) ?? -1

        guard sqlite3_open_v2(
            temporary.path,
            &outputConnection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let output = outputConnection else {
            if let outputConnection { sqlite3_close(outputConnection) }
            throw ConversationMutationError.writeFailed(temporary, "无法创建 SQLite 快照")
        }
        defer {
            if let outputConnection { sqlite3_close(outputConnection) }
        }
        sqlite3_busy_timeout(output, 1_000)

        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw ConversationMutationError.unreadable(
                source,
                String(cString: sqlite3_errmsg(output))
            )
        }
        var status: Int32 = SQLITE_OK
        var retries = 0
        repeat {
            status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                retries += 1
                guard retries <= 100 else { break }
                sqlite3_sleep(10)
            }
        } while status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED
        let finishStatus = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw ConversationMutationError.unreadable(
                source,
                String(cString: sqlite3_errmsg(output))
            )
        }
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw ConversationMutationError.unreadable(
                source,
                "无法将 SQLite 快照转换为独立数据库"
            )
        }
        let snapshotPageCount = sqliteInteger("PRAGMA page_count", database: output) ?? -1
        guard sourcePageCount > 0, snapshotPageCount == sourcePageCount else {
            throw ConversationMutationError.unreadable(
                source,
                "SQLite 快照页数异常（源 \(sourcePageCount)，快照 \(snapshotPageCount)）"
            )
        }

        // The source's WAL mode is copied into the destination header. Convert the temporary
        // snapshot to rollback-journal mode so the exported main file is independently readable
        // without a generated `-wal`/`-shm` pair.
        let closeStatus = sqlite3_close(output)
        outputConnection = nil
        guard closeStatus == SQLITE_OK else {
            throw ConversationMutationError.unreadable(
                source,
                "无法完成 SQLite 快照（错误码 \(closeStatus)）"
            )
        }
        do {
            return try Data(contentsOf: temporary, options: [.mappedIfSafe])
        } catch {
            throw ConversationMutationError.unreadable(temporary, String(describing: error))
        }
    }

    private func sqliteInteger(_ sql: String, database: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func structuralFingerprint(_ file: URL) throws -> (UInt64, UInt64, Int64, Int64, Int64) {
        var facts = stat()
        guard lstat(file.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG else {
            throw ConversationMutationError.notRegularFile(file)
        }
        return (
            UInt64(facts.st_dev), UInt64(facts.st_ino), facts.st_size,
            Int64(facts.st_mtimespec.tv_sec), Int64(facts.st_mtimespec.tv_nsec)
        )
    }

    private func ensureAppDataDirectory() throws {
        try createOwnedDirectory(configuration.appDataRoot)
    }

    private func ensureImportsDirectory() throws {
        try ensureAppDataDirectory()
        try createOwnedDirectory(configuration.importsRoot)
        try createOwnedDirectory(configuration.importsRoot.appendingPathComponent("projects", isDirectory: true))
    }

    private func createOwnedDirectory(_ directory: URL) throws {
        let root = configuration.appDataRoot.standardizedFileURL
        let target = directory.standardizedFileURL
        if target == root {
            do { try fileManager.createDirectory(at: target, withIntermediateDirectories: true) }
            catch { throw ConversationMutationError.writeFailed(target, String(describing: error)) }
            var facts = stat()
            guard lstat(target.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR else {
                throw ConversationMutationError.symbolicLink(target)
            }
            return
        }
        guard let components = relativeComponents(target, under: root) else {
            throw ConversationMutationError.outsideAllowedRoots(target)
        }
        try createOwnedDirectory(root)
        var cursor = root
        for component in components {
            cursor.appendPathComponent(component, isDirectory: true)
            var facts = stat()
            if lstat(cursor.path, &facts) == 0 {
                guard facts.st_mode & S_IFMT == S_IFDIR else {
                    throw ConversationMutationError.symbolicLink(cursor)
                }
            } else if errno == ENOENT {
                guard Darwin.mkdir(cursor.path, S_IRWXU) == 0 else {
                    throw ConversationMutationError.writeFailed(
                        cursor,
                        String(cString: strerror(errno))
                    )
                }
            } else {
                throw ConversationMutationError.writeFailed(cursor, String(cString: strerror(errno)))
            }
        }
    }

    private func atomicCreate(_ data: Data, at destination: URL) throws {
        try rejectSymlink(destination, allowMissing: true, rootedAt: configuration.appDataRoot)
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).ccbud-\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary { try? fileManager.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        removeTemporary = false
    }

    private func isWithin(_ file: URL, root: URL) -> Bool {
        relativeComponents(file.standardizedFileURL, under: root.standardizedFileURL) != nil
    }

    private func relativeComponents(_ file: URL, under root: URL) -> [String]? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count >= rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    private func safeDirectoryName(_ cwd: String?) -> String {
        guard var value = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "-imported"
        }
        value = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        if value == "." || value == ".." || value.hasPrefix(".") { value = "-" + value }
        return String(value.prefix(180))
    }

    private func safeIdentifier(_ raw: String, fallback: String) -> String {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : raw
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var value = String(source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if value.isEmpty || value == "." || value == ".." { value = "import-" + UUID().uuidString.lowercased() }
        return String(value.prefix(120))
    }
}
