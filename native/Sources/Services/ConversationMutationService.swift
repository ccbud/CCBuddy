import CryptoKit
import Darwin
import Foundation

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
        case .foreignPermanentDelete: "外部工具的原始会话只能移入回收站，不能由 CC Buddy 永久删除"
        case .unsafeCompanion(let file): "会话的关联文件不安全，已停止删除：\(file.path)"
        case .writeFailed(let file, let detail): "无法写入 \(file.lastPathComponent)：\(detail)"
        }
    }
}

struct ConversationMutationConfiguration: Equatable, Sendable {
    var historyDirs: [String]
    var homeDirectory: URL
    var importsRoot: URL

    init(
        historyDirs: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        importsRoot: URL? = nil
    ) {
        self.historyDirs = historyDirs
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.importsRoot = (importsRoot ?? homeDirectory
            .appendingPathComponent(".ccbud", isDirectory: true)
            .appendingPathComponent("imports", isDirectory: true)).standardizedFileURL
    }

    var appDataRoot: URL { importsRoot.deletingLastPathComponent() }
}

/// The only write-capable history component. Every target is scoped to a configured producer tree
/// or the app-owned import store, and every existing path component is checked with `lstat` before
/// mutation so a symlink cannot redirect an edit/delete outside that scope.
struct ConversationMutationService: @unchecked Sendable {
    private struct Fingerprint: Equatable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var seconds: Int64
        var nanoseconds: Int64
        var digest: SHA256.Digest
    }

    private struct StableRead {
        var data: Data
        var fingerprint: Fingerprint
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
    private let beforeCommit: (@Sendable (URL) -> Void)?
    private let archiveLimits: ConversationArchiveLimits

    init(
        configuration: ConversationMutationConfiguration,
        fileManager: FileManager = .default,
        archiveLimits: ConversationArchiveLimits = .init(),
        beforeCommit: (@Sendable (URL) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.archiveLimits = archiveLimits
        self.beforeCommit = beforeCommit
    }

    func updateMetadata(
        for metadata: HistorySessionMetadata,
        patch: ConversationMetadataPatch
    ) throws {
        let file = try validateScopedRegularFile(metadata.file)
        if isLiveForeign(metadata) {
            try updateSidecar(for: metadata, transcript: file, patch: patch)
        } else {
            guard file.pathExtension.lowercased() == "jsonl" else {
                throw ConversationMutationError.unsupportedFile(file)
            }
            try rewriteInlineMetadata(file: file, patch: patch)
        }
    }

    func softDelete(_ metadata: HistorySessionMetadata) throws {
        try updateMetadata(for: metadata, patch: .init(deleted: true))
    }

    func restore(_ metadata: HistorySessionMetadata) throws {
        try updateMetadata(for: metadata, patch: .init(deleted: false))
    }

    func canPermanentlyDelete(_ metadata: HistorySessionMetadata) -> Bool {
        metadata.imported || metadata.source == .claude
    }

    func permanentlyDelete(_ metadata: HistorySessionMetadata) throws {
        guard canPermanentlyDelete(metadata) else {
            throw ConversationMutationError.foreignPermanentDelete
        }
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
                subagents = try readSubagentFiles(for: source)
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
        if metadata.source == .antigravity { return "db" }
        return try readSubagentFiles(for: metadata.file).isEmpty ? "jsonl" : "zip"
    }

    func exportRaw(
        _ metadata: HistorySessionMetadata,
        to destination: URL
    ) throws -> ConversationRawExportResult {
        let source = try validateScopedRegularFile(metadata.file)
        let sourceData = try stableRead(source).data
        let subagents = metadata.source == .antigravity ? [] : try readSubagentFiles(for: source)
        let data: Data
        let fileExtension: String
        let bundled: Bool
        if metadata.source == .antigravity {
            data = sourceData
            fileExtension = "db"
            bundled = false
        } else if subagents.isEmpty {
            data = sourceData
            fileExtension = "jsonl"
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

    // MARK: - Metadata writes

    private func rewriteInlineMetadata(file: URL, patch: ConversationMetadataPatch) throws {
        let read = try stableRead(file)
        guard let raw = String(data: read.data, encoding: .utf8) else {
            throw ConversationMutationError.unreadable(file, "文件不是有效 UTF-8")
        }
        var lines = raw.components(separatedBy: "\n")
        var found: (Int, [String: Any])?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { continue }
            found = (index, dictionary)
            break
        }
        guard let (index, initialObject) = found else {
            throw ConversationMutationError.noConversationRecords
        }
        var object = initialObject
        var custom = object["__ccbud__"] as? [String: Any] ?? [:]
        apply(patch, to: &custom)
        if custom.isEmpty { object.removeValue(forKey: "__ccbud__") }
        else { object["__ccbud__"] = custom }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ConversationMutationError.invalidMetadata("JSON 对象无法编码")
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let line = String(data: encoded, encoding: .utf8) else {
            throw ConversationMutationError.invalidMetadata("JSON 不是 UTF-8")
        }
        lines[index] = line
        let output = Data(lines.joined(separator: "\n").utf8)
        try commit(output, to: file, replacing: read.fingerprint)
    }

    private func updateSidecar(
        for metadata: HistorySessionMetadata,
        transcript: URL,
        patch: ConversationMetadataPatch
    ) throws {
        let key: String
        let sidecar: URL
        if metadata.source == .codex {
            key = transcript.deletingPathExtension().lastPathComponent
            sidecar = configuration.appDataRoot.appendingPathComponent("codex-meta.json")
        } else {
            let prefix = metadata.source.rawValue + ":"
            key = metadata.id.hasPrefix(prefix)
                ? String(metadata.id.dropFirst(prefix.count))
                : metadata.sessionID
            sidecar = configuration.appDataRoot.appendingPathComponent("agent-meta.json")
        }
        guard !key.isEmpty, key.count <= 512, !key.contains("\0") else {
            throw ConversationMutationError.invalidMetadata("会话标识为空或过长")
        }
        try ensureAppDataDirectory()
        try rejectSymlink(sidecar, allowMissing: true, rootedAt: configuration.appDataRoot)

        let existing = fileManager.fileExists(atPath: sidecar.path)
        let read: StableRead?
        var root: [String: Any]
        if existing {
            let value = try stableRead(sidecar)
            guard value.data.count <= 8 * 1_024 * 1_024,
                  let decoded = try? JSONSerialization.jsonObject(with: value.data),
                  let dictionary = decoded as? [String: Any] else {
                throw ConversationMutationError.invalidMetadata("sidecar 不是有效 JSON 对象")
            }
            read = value
            root = dictionary
        } else {
            read = nil
            root = [:]
        }
        var custom = root[key] as? [String: Any] ?? [:]
        apply(patch, to: &custom)
        if custom.isEmpty { root.removeValue(forKey: key) }
        else { root[key] = custom }
        let output = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if let read {
            try commit(output, to: sidecar, replacing: read.fingerprint, appOwned: true)
        } else {
            beforeCommit?(sidecar)
            do {
                try atomicCreate(output, at: sidecar)
            } catch let error as POSIXError where error.code == .EEXIST {
                throw ConversationMutationError.conflict(sidecar)
            } catch {
                throw ConversationMutationError.writeFailed(sidecar, String(describing: error))
            }
        }
    }

    private func apply(_ patch: ConversationMetadataPatch, to custom: inout [String: Any]) {
        if let title = patch.title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { custom.removeValue(forKey: "title") }
            else { custom["title"] = value }
        }
        if let tags = patch.tags {
            var normalized: [String] = []
            for tag in tags {
                let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !normalized.contains(value) { normalized.append(value) }
            }
            if normalized.isEmpty { custom.removeValue(forKey: "tagList") }
            else { custom["tagList"] = normalized }
        }
        if let deleted = patch.deleted {
            if deleted { custom["delete"] = true }
            else { custom.removeValue(forKey: "delete") }
        }
        // Absent means "not starred": clearing the key keeps sidecars from accumulating false flags
        // for every session the user has ever glanced at.
        if let starred = patch.starred {
            if starred { custom["starred"] = true }
            else { custom.removeValue(forKey: "starred") }
        }
        if let pinned = patch.pinned {
            if pinned { custom["pinned"] = true }
            else { custom.removeValue(forKey: "pinned") }
        }
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

    private func readSubagentFiles(for transcript: URL) throws -> [ConversationArchiveEntry] {
        guard transcript.isFileURL else { throw ConversationMutationError.invalidPath(transcript) }
        let stem = transcript.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }
        let root = transcript.deletingLastPathComponent()
            .appendingPathComponent(stem, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        try rejectSymlink(root, allowMissing: false, rootedAt: transcript.deletingLastPathComponent())
        var result: [ConversationArchiveEntry] = []
        var total = 0
        let files = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files where ConversationArchive.isSubagentBasename(file.lastPathComponent) {
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
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
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

    private func isLiveForeign(_ metadata: HistorySessionMetadata) -> Bool {
        !metadata.imported && metadata.source != .claude
    }

    private var allowedRoots: [URL] {
        let producerRoots = configuration.historyDirs.flatMap { raw -> [URL] in
            let base = HistoryPathResolver.expandTilde(raw, homeDirectory: configuration.homeDirectory)
                .resolvingSymlinksInPath().standardizedFileURL
            return ["projects", "sessions", "archived_sessions", "session-state", "conversations"].map {
                base.appendingPathComponent($0, isDirectory: true).standardizedFileURL
            }
        }
        return producerRoots + [
            configuration.importsRoot.appendingPathComponent("projects", isDirectory: true)
                .standardizedFileURL,
        ]
    }

    private func validateScopedRegularFile(_ requested: URL) throws -> URL {
        guard requested.isFileURL else { throw ConversationMutationError.invalidPath(requested) }
        let file = requested.standardizedFileURL
        guard let root = allowedRoots.first(where: { isWithin(file, root: $0) }) else {
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
        do { data = try Data(contentsOf: file, options: [.mappedIfSafe]) }
        catch { throw ConversationMutationError.unreadable(file, String(describing: error)) }
        let after = try structuralFingerprint(file)
        guard before == after else { throw ConversationMutationError.conflict(file) }
        return StableRead(data: data, fingerprint: Fingerprint(
            device: after.0,
            inode: after.1,
            size: after.2,
            seconds: after.3,
            nanoseconds: after.4,
            digest: SHA256.hash(data: data)
        ))
    }

    private func commit(
        _ data: Data,
        to file: URL,
        replacing expected: Fingerprint,
        appOwned: Bool = false
    ) throws {
        beforeCommit?(file)
        if !appOwned {
            _ = try validateScopedRegularFile(file)
        } else {
            try rejectSymlink(file, allowMissing: false, rootedAt: configuration.appDataRoot)
        }
        let current = try stableRead(file).fingerprint
        guard current == expected else { throw ConversationMutationError.conflict(file) }
        do { try SecureAtomicFile.write(data, to: file, fileManager: fileManager) }
        catch { throw ConversationMutationError.writeFailed(file, String(describing: error)) }
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
