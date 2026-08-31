import Darwin
import Foundation

enum CLIConnectionError: LocalizedError {
    case invalidClaudeSettings(URL)
    case invalidCodexConfiguration(URL)
    case conflictingConfigurationPaths(URL)
    case mixedConnectionUpdates
    case rollbackFailed([URL], recoveryDirectory: URL)

    var errorDescription: String? {
        switch self {
        case .invalidClaudeSettings(let url):
            "Claude Code 配置不是有效的 JSON 对象，已拒绝覆盖：\(url.path)"
        case .invalidCodexConfiguration(let url):
            "Codex 配置不是有效的 UTF-8 文本，已拒绝覆盖：\(url.path)"
        case .conflictingConfigurationPaths(let url):
            "接入配置路径发生冲突，已拒绝写入：\(url.path)"
        case .mixedConnectionUpdates:
            "不能在同一接入事务中同时连接和断开不同的 CLI"
        case .rollbackFailed(let urls, let recoveryDirectory):
            "接入配置写入失败，且无法完整恢复这些文件：\(urls.map(\.path).joined(separator: ", "))。原始文件的私密恢复副本已保留在：\(recoveryDirectory.path)"
        }
    }
}

struct CLIConnectionManager {
    enum ConnectionUpdate: Equatable {
        case unchanged
        case connect
        case disconnect
    }

    typealias FileWriter = (Data, URL, FileManager) throws -> Void
    typealias DirectorySynchronizer = (URL) throws -> Void

    private struct StagedFile {
        let url: URL
        let data: Data
    }

    private struct FileSnapshot {
        let url: URL
        let data: Data?
        let permissions: Int?
    }

    private struct RecoveryManifest: Encodable {
        struct Entry: Encodable {
            let targetPath: String
            let originallyExisted: Bool
            let originalPermissions: Int?
            let recoveryFile: String?
        }

        let version = 1
        let entries: [Entry]
    }

    static let claudeTarget = "claude"
    static let codexTarget = "codex"
    static let codexModel = "gpt-5.4"
    static let recoveryDirectoryName = "cli-connection-recovery"
    static let recoveryJournalFileName = "journal.json"

    private static let claudeModelKeys = [
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
    ]
    private static let claudeOwnedEnvironmentKeys = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
    ] + claudeModelKeys
    private static let codexOwnedKeys = [
        "model", "model_provider", "model_reasoning_effort",
    ]

    let repository: ConfigRepository
    private let environment: [String: String]
    private let fileManager: FileManager
    private let fileWriter: FileWriter
    private let directorySynchronizer: DirectorySynchronizer?

    init(
        repository: ConfigRepository = ConfigRepository(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fileWriter: @escaping FileWriter = { data, url, fileManager in
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        },
        directorySynchronizer: DirectorySynchronizer? = nil
    ) {
        self.repository = repository
        self.environment = environment
        self.fileManager = fileManager
        self.fileWriter = fileWriter
        self.directorySynchronizer = directorySynchronizer
    }

    var claudeSettingsURL: URL {
        if let override = environment["CCBUD_CLAUDE_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    var codexConfigURL: URL {
        if let override = environment["CCBUD_CODEX_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("config.toml")
        }
        return homeDirectory.appendingPathComponent(".codex/config.toml")
    }

    var recoveryRootURL: URL {
        repository.configURL.deletingLastPathComponent()
            .appendingPathComponent(Self.recoveryDirectoryName, isDirectory: true)
    }

    /// Every directory returned here represents a transaction whose original bytes must remain
    /// available until the user completes manual recovery. A journal is created and synchronized
    /// before the first managed file changes, and removed only after a successful commit or a
    /// complete automatic rollback.
    func pendingRecoveryJournalDirectories() throws -> [URL] {
        var rootMetadata = stat()
        let rootStatus = recoveryRootURL.path.withCString { Darwin.lstat($0, &rootMetadata) }
        if rootStatus != 0 {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return []
        }
        guard rootMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.EFTYPE)
        }

        let entries = try fileManager.contentsOfDirectory(
            at: recoveryRootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        var pending: [URL] = []
        pending.reserveCapacity(entries.count)
        for directory in entries {
            var directoryMetadata = stat()
            guard directory.path.withCString({ Darwin.lstat($0, &directoryMetadata) }) == 0 else {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard directoryMetadata.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(.EFTYPE)
            }

            let journal = directory.appendingPathComponent(Self.recoveryJournalFileName)
            var journalMetadata = stat()
            guard journal.path.withCString({ Darwin.lstat($0, &journalMetadata) }) == 0 else {
                let code = errno
                // A crash before journal publication cannot have reached a managed destination.
                // Only that unambiguous incomplete-transaction shape is safe to ignore. Any
                // other inspection failure must keep callers in the manual-recovery state.
                if code == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard journalMetadata.st_mode & S_IFMT == S_IFREG else {
                throw POSIXError(.EFTYPE)
            }
            pending.append(directory)
        }
        return pending.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var isClaudeAvailable: Bool {
        fileManager.fileExists(atPath: claudeSettingsURL.path)
            || fileManager.fileExists(atPath: claudeSettingsURL.deletingLastPathComponent().path)
    }

    var isCodexAvailable: Bool {
        fileManager.fileExists(atPath: codexConfigURL.path)
            || fileManager.fileExists(atPath: codexConfigURL.deletingLastPathComponent().path)
    }

    func isClaudeConnected(port: Int) -> Bool {
        guard let settings = try? readClaudeSettings(),
              let environment = settings["env"]?.objectValue,
              let endpoint = environment["ANTHROPIC_BASE_URL"]?.stringValue else { return false }
        return isLocalEndpoint(endpoint, port: port, acceptedPaths: ["", "/", "/anthropic", "/anthropic/"])
    }

    func isCodexConnected(port: Int) -> Bool {
        guard let document = try? readCodexDocument(),
              let endpoint = document.providerString(for: "base_url") else { return false }
        return isLocalEndpoint(
            endpoint,
            port: port,
            acceptedPaths: ["/v1", "/v1/", "/openai/v1", "/openai/v1/"]
        )
    }

    func currentToken(for config: AppConfig) -> String {
        config.requireToken && !config.gatewayToken.isEmpty ? config.gatewayToken : "ccbud-local"
    }

    @discardableResult
    func connectClaude(config input: AppConfig) throws -> AppConfig {
        try updateConnections(config: input, claude: .connect)
    }

    @discardableResult
    func disconnectClaude(config input: AppConfig) throws -> AppConfig {
        try updateConnections(config: input, claude: .disconnect)
    }

    @discardableResult
    func connectCodex(config input: AppConfig, model: String = Self.codexModel) throws -> AppConfig {
        try updateConnections(config: input, codex: .connect, codexModel: model)
    }

    @discardableResult
    func disconnectCodex(config input: AppConfig) throws -> AppConfig {
        try updateConnections(config: input, codex: .disconnect)
    }

    /// Applies every requested CLI change and the ownership metadata as one recoverable
    /// transaction. All inputs are parsed before the first write, and any later write failure
    /// triggers exact-byte restoration, retaining private recovery copies if restoration fails.
    @discardableResult
    func updateConnections(
        config input: AppConfig,
        claude: ConnectionUpdate = .unchanged,
        codex: ConnectionUpdate = .unchanged,
        codexModel: String = Self.codexModel
    ) throws -> AppConfig {
        let updates = [claude, codex]
        guard !(updates.contains(.connect) && updates.contains(.disconnect)) else {
            throw CLIConnectionError.mixedConnectionUpdates
        }
        var config = input
        config.normalize()
        var externalFiles: [StagedFile] = []

        switch claude {
        case .unchanged:
            break
        case .connect:
            externalFiles.append(.init(
                url: claudeSettingsURL,
                data: try connectedClaudeSettings(config: &config)
            ))
        case .disconnect:
            if let data = try disconnectedClaudeSettings(config: &config) {
                externalFiles.append(.init(url: claudeSettingsURL, data: data))
            }
        }

        switch codex {
        case .unchanged:
            break
        case .connect:
            externalFiles.append(.init(
                url: codexConfigURL,
                data: try connectedCodexDocument(config: &config, model: codexModel)
            ))
        case .disconnect:
            if let data = try disconnectedCodexDocument(config: &config) {
                externalFiles.append(.init(url: codexConfigURL, data: data))
            }
        }
        let configFile = StagedFile(url: repository.configURL, data: try repository.serialized(config))
        // A connect writes ownership metadata first, so an interrupted process can reconcile the
        // selected target on its next launch. A disconnect restores the user files first and only
        // then clears their backups. Runtime failures are rolled back in either order below.
        let hasDisconnect = claude == .disconnect || codex == .disconnect
        let stagedFiles = hasDisconnect ? externalFiles + [configFile] : [configFile] + externalFiles
        try commit(stagedFiles)
        return config
    }

    /// On launch, repair only targets that were explicitly selected and have an ownership backup.
    /// This prevents a schema default from taking over a user's CLI configuration.
    func reconcilePreviouslyManagedConnections(config input: AppConfig) throws -> AppConfig {
        let claude: ConnectionUpdate = input.connectTargets.contains(Self.claudeTarget)
            && input.claudeBackup.objectValue != nil ? .connect : .unchanged
        let codex: ConnectionUpdate = input.connectTargets.contains(Self.codexTarget)
            && input.codexBackup.objectValue != nil ? .connect : .unchanged
        guard claude != .unchanged || codex != .unchanged else { return input }
        return try updateConnections(config: input, claude: claude, codex: codex)
    }

    private var homeDirectory: URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private func readClaudeSettings() throws -> [String: JSONValue] {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else { return [:] }
        let data = try Data(contentsOf: claudeSettingsURL)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            throw CLIConnectionError.invalidClaudeSettings(claudeSettingsURL)
        }
        return object
    }

    private func encodedClaudeSettings(_ settings: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(settings)
    }

    private func readCodexDocument() throws -> CodexConfigDocument {
        guard fileManager.fileExists(atPath: codexConfigURL.path) else {
            return CodexConfigDocument("")
        }
        let data = try Data(contentsOf: codexConfigURL)
        guard let source = String(data: data, encoding: .utf8) else {
            throw CLIConnectionError.invalidCodexConfiguration(codexConfigURL)
        }
        return CodexConfigDocument(source)
    }

    private func connectedClaudeSettings(config: inout AppConfig) throws -> Data {
        var settings = try readClaudeSettings()
        if config.claudeBackup.objectValue == nil {
            let currentEnvironment = settings["env"]?.objectValue ?? [:]
            let backupEnvironment = Dictionary(uniqueKeysWithValues: Self.claudeOwnedEnvironmentKeys.map {
                ($0, currentEnvironment[$0] ?? .null)
            })
            config.claudeBackup = .object([
                "model": settings["model"] ?? .null,
                "env": .object(backupEnvironment),
            ])
        }
        select(Self.claudeTarget, in: &config)

        var nextEnvironment = settings["env"]?.objectValue ?? [:]
        nextEnvironment["ANTHROPIC_BASE_URL"] = .string("http://localhost:\(config.port)/anthropic")
        nextEnvironment["ANTHROPIC_AUTH_TOKEN"] = .string(currentToken(for: config))
        Self.claudeModelKeys.forEach { nextEnvironment.removeValue(forKey: $0) }
        settings["env"] = .object(nextEnvironment)
        settings.removeValue(forKey: "model")
        return try encodedClaudeSettings(settings)
    }

    private func disconnectedClaudeSettings(config: inout AppConfig) throws -> Data? {
        guard let backup = config.claudeBackup.objectValue else {
            config.claudeBackup = .null
            deselect(Self.claudeTarget, in: &config)
            return nil
        }
        var settings = try readClaudeSettings()
        var targetEnvironment = settings["env"]?.objectValue ?? [:]

        let backupEnvironment = backup["env"]?.objectValue ?? [:]
        for key in Self.claudeOwnedEnvironmentKeys {
            if let value = backupEnvironment[key], !value.isNull {
                targetEnvironment[key] = value
            } else {
                targetEnvironment.removeValue(forKey: key)
            }
        }
        if let model = backup["model"], !model.isNull {
            settings["model"] = model
        } else {
            settings.removeValue(forKey: "model")
        }

        if targetEnvironment.isEmpty {
            settings.removeValue(forKey: "env")
        } else {
            settings["env"] = .object(targetEnvironment)
        }
        config.claudeBackup = .null
        deselect(Self.claudeTarget, in: &config)
        return try encodedClaudeSettings(settings)
    }

    private func connectedCodexDocument(config: inout AppConfig, model: String) throws -> Data {
        var document = try readCodexDocument()
        if config.codexBackup.objectValue == nil {
            var backup: [String: JSONValue] = [:]
            for key in Self.codexOwnedKeys {
                backup[key] = document.topLevelString(for: key).map(JSONValue.string) ?? .null
                backup["\(key)_raw"] = document.rawTopLevelAssignment(for: key).map(JSONValue.string) ?? .null
            }
            backup["provider_block_raw"] = document.rawProviderBlock().map(JSONValue.string) ?? .null
            config.codexBackup = .object(backup)
        }
        select(Self.codexTarget, in: &config)
        document.setTopLevelString("ccbud", for: "model_provider")
        if !model.isEmpty { document.setTopLevelString(model, for: "model") }
        document.setTopLevelString("ultra", for: "model_reasoning_effort")
        document.setCCBuddyProvider(port: config.port, token: currentToken(for: config))
        return Data(document.source.utf8)
    }

    private func disconnectedCodexDocument(config: inout AppConfig) throws -> Data? {
        guard let backup = config.codexBackup.objectValue else {
            config.codexBackup = .null
            deselect(Self.codexTarget, in: &config)
            return nil
        }
        var document = try readCodexDocument()
        document.removeCCBuddyProvider()

        for key in Self.codexOwnedKeys {
            document.restoreTopLevelValue(
                for: key,
                rawAssignment: backup["\(key)_raw"]?.stringValue,
                fallbackValue: backup[key]?.stringValue
            )
        }
        document.restoreProviderBlock(backup["provider_block_raw"]?.stringValue)

        config.codexBackup = .null
        deselect(Self.codexTarget, in: &config)
        return Data(document.source.utf8)
    }

    private func commit(_ files: [StagedFile]) throws {
        let files = files.map {
            StagedFile(
                url: $0.url.resolvingSymlinksInPath().standardizedFileURL,
                data: $0.data
            )
        }
        var seenPaths = Set<String>()
        for file in files {
            let path = file.url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                throw CLIConnectionError.conflictingConfigurationPaths(file.url)
            }
        }
        let snapshots = try files.map(snapshot)
        // The recovery copy must be durable before any destination changes. If the app-owned
        // journal cannot be created, fail closed without attempting a forward write.
        let recoveryDirectory = try prepareRecoveryJournal(for: snapshots)
        var completedSnapshots: [FileSnapshot] = []
        do {
            for (index, file) in files.enumerated() {
                try fileWriter(file.data, file.url, fileManager)
                completedSnapshots.append(snapshots[index])
            }
        } catch {
            let failedRollbacks = rollback(completedSnapshots.reversed())
            if failedRollbacks.isEmpty {
                removeRecoveryJournal(at: recoveryDirectory)
                throw error
            }
            throw CLIConnectionError.rollbackFailed(
                failedRollbacks,
                recoveryDirectory: recoveryDirectory
            )
        }
        removeRecoveryJournal(at: recoveryDirectory)
    }

    /// Capture the exact pre-transaction bytes before attempting rollback. The forward writer can
    /// fail for the same reason as rollback (permissions, a full disk, or a replaced path), so these
    /// copies use a separate app-owned location and remain available if rollback cannot finish.
    private func prepareRecoveryJournal(for snapshots: [FileSnapshot]) throws -> URL {
        let root = recoveryRootURL
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try createPrivateDirectory(root)
            try createPrivateDirectory(directory)
            var entries: [RecoveryManifest.Entry] = []
            entries.reserveCapacity(snapshots.count)
            for (index, snapshot) in snapshots.enumerated() {
                let recoveryFile: String?
                if let data = snapshot.data {
                    let name = String(format: "original-%03d.bin", index)
                    try SecureAtomicFile.write(
                        data,
                        to: directory.appendingPathComponent(name),
                        fileManager: fileManager
                    )
                    recoveryFile = name
                } else {
                    recoveryFile = nil
                }
                entries.append(.init(
                    targetPath: snapshot.url.path,
                    originallyExisted: snapshot.data != nil,
                    originalPermissions: snapshot.permissions,
                    recoveryFile: recoveryFile
                ))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try SecureAtomicFile.write(
                encoder.encode(RecoveryManifest(entries: entries)),
                to: directory.appendingPathComponent(Self.recoveryJournalFileName),
                fileManager: fileManager
            )
            try synchronizeDirectory(directory)
            try synchronizeDirectory(root)
            return directory
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        let initialStatus = url.path.withCString { Darwin.lstat($0, &metadata) }
        var directoriesRequiringParentSync: [URL] = []
        if initialStatus == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(.EFTYPE)
            }
        } else {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // createDirectory may need to create the app config parent as well as the journal
            // root. Record every missing directory now so each new directory entry can be made
            // durable in its parent before any managed destination is changed.
            var candidate = url
            while true {
                var candidateMetadata = stat()
                let status = candidate.path.withCString {
                    Darwin.lstat($0, &candidateMetadata)
                }
                if status == 0 { break }
                guard errno == ENOENT else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                directoriesRequiringParentSync.append(candidate)
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else { throw POSIXError(.ENOENT) }
                candidate = parent
            }
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // FileManager follows symlinks. Re-open the final component with O_NOFOLLOW before
        // changing permissions or trusting it as the journal safety boundary.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var verifiedMetadata = stat()
        guard Darwin.fstat(descriptor, &verifiedMetadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard verifiedMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.EFTYPE)
        }
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for directory in directoriesRequiringParentSync {
            // A user may intentionally place the app config directory behind a symlink. The
            // recovery root itself is never allowed to be one, but its already-existing parent
            // can be synchronized through its resolved destination.
            try synchronizeDirectory(
                directory.deletingLastPathComponent().resolvingSymlinksInPath()
            )
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        if let directorySynchronizer {
            try directorySynchronizer(url)
            return
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.EFTYPE)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EFTYPE)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeRecoveryJournal(at directory: URL) {
        try? fileManager.removeItem(at: directory)
        try? synchronizeDirectory(directory.deletingLastPathComponent())
    }

    private func snapshot(_ file: StagedFile) throws -> FileSnapshot {
        guard fileManager.fileExists(atPath: file.url.path) else {
            return .init(url: file.url, data: nil, permissions: nil)
        }
        let attributes = try fileManager.attributesOfItem(atPath: file.url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        return .init(url: file.url, data: try Data(contentsOf: file.url), permissions: permissions)
    }

    private func rollback<S: Sequence>(_ snapshots: S) -> [URL] where S.Element == FileSnapshot {
        var failures: [URL] = []
        for snapshot in snapshots {
            do {
                if let data = snapshot.data {
                    try fileWriter(data, snapshot.url, fileManager)
                    if let permissions = snapshot.permissions {
                        try fileManager.setAttributes(
                            [.posixPermissions: permissions],
                            ofItemAtPath: snapshot.url.path
                        )
                    }
                    // The replacement bytes, restored mode, and any recreated directory entry
                    // must all be durable before the only recovery copy is removed.
                    try synchronizeFile(snapshot.url)
                    try synchronizeDirectory(snapshot.url.deletingLastPathComponent())
                } else {
                    var metadata = stat()
                    let status = snapshot.url.path.withCString { Darwin.lstat($0, &metadata) }
                    if status == 0 {
                        guard metadata.st_mode & S_IFMT == S_IFREG else {
                            throw POSIXError(.EFTYPE)
                        }
                        guard snapshot.url.path.withCString({ Darwin.unlink($0) }) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    } else if errno != ENOENT {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    // unlink(2) is not durable until its parent directory is synchronized. Without
                    // this barrier a crash could resurrect the new file after its journal vanished.
                    try synchronizeDirectory(snapshot.url.deletingLastPathComponent())
                }
            } catch {
                failures.append(snapshot.url)
            }
        }
        return failures
    }

    private func select(_ target: String, in config: inout AppConfig) {
        guard !config.connectTargets.contains(target) else { return }
        config.connectTargets.append(target)
    }

    private func deselect(_ target: String, in config: inout AppConfig) {
        config.connectTargets.removeAll { $0 == target }
    }

    private func isLocalEndpoint(_ endpoint: String, port: Int, acceptedPaths: Set<String>) -> Bool {
        guard let components = URLComponents(string: endpoint) else { return false }
        return ["localhost", "127.0.0.1"].contains(components.host?.lowercased() ?? "")
            && components.port == port
            && acceptedPaths.contains(components.path)
    }
}
