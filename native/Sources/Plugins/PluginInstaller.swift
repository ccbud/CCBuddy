import Foundation

enum PluginInstallDisposition: String, Equatable {
    case installed
    case replaced
    case unchanged
}

enum PluginRecoveryReason: String, Codable, Equatable {
    case replaced
    case uninstalled
    case gitCacheReplaced
    case failedOperation
}

struct PluginRecoveryToken: Codable, Equatable {
    var pluginID: String
    var location: URL
    var reason: PluginRecoveryReason
    var createdAt: Date
}

struct PluginInstallReceipt: Equatable {
    var pluginID: String
    var installedDirectory: URL
    var disposition: PluginInstallDisposition
    var previousVersion: String?
    var recoveryToken: PluginRecoveryToken?
}

struct PluginUninstallReceipt: Equatable {
    var pluginID: String
    var recoveryToken: PluginRecoveryToken
}

/// Transactional file operations shared by local and Git installation. Existing installs are
/// renamed into `~/.ccbud/plugin-recovery` and never recursively deleted.
struct PluginFileTransactions {
    var layout: PluginHomeLayout
    var fileManager: FileManager

    init(layout: PluginHomeLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    func ensureManagedDirectories() throws {
        for directory in [layout.ccbudHome, layout.pluginsRoot, layout.stagingRoot, layout.recoveryRoot, layout.gitCacheRoot] {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PluginCoreError.filesystem("create directory", directory, error.localizedDescription)
            }
        }
    }

    func makeStagingDirectory(label: String) throws -> URL {
        try ensureManagedDirectories()
        let safeLabel = PluginManifestValidator.isValidIdentifier(label) ? label : "plugin"
        let directory = layout.stagingRoot.appendingPathComponent(
            ".\(safeLabel)-\(uniqueSuffix())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            throw PluginCoreError.filesystem("create staging directory", directory, error.localizedDescription)
        }
    }

    func copyDirectory(
        from source: URL,
        to destination: URL,
        includeGitMetadata: Bool = false
    ) throws {
        guard !PluginManifestValidator.isContained(destination, by: source) else {
            throw PluginCoreError.unsafeFilesystemRelationship(
                "Refusing to copy a plugin directory into itself (\(source.path) -> \(destination.path))"
            )
        }
        do {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try copyContents(from: source, to: destination, includeGitMetadata: includeGitMetadata)
        } catch let error as PluginCoreError {
            throw error
        } catch {
            throw PluginCoreError.filesystem("copy plugin", destination, error.localizedDescription)
        }
    }

    func archive(
        _ source: URL,
        pluginID: String,
        reason: PluginRecoveryReason,
        createdAt: Date = Date()
    ) throws -> PluginRecoveryToken {
        try ensureManagedDirectories()
        let pluginRoot = layout.recoveryRoot.appendingPathComponent(pluginID, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: pluginRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PluginCoreError.filesystem("create recovery directory", pluginRoot, error.localizedDescription)
        }
        let destination = pluginRoot.appendingPathComponent(
            "\(Int(createdAt.timeIntervalSince1970))-\(reason.rawValue)-\(uniqueSuffix())",
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: source, to: destination)
            return .init(pluginID: pluginID, location: destination, reason: reason, createdAt: createdAt)
        } catch {
            throw PluginCoreError.filesystem("archive plugin", source, error.localizedDescription)
        }
    }

    /// Moves a staged directory into place. If the final rename fails, the previous directory
    /// is renamed back before the error is surfaced.
    func replace(
        destination: URL,
        with staged: URL,
        pluginID: String,
        recoveryReason: PluginRecoveryReason
    ) throws -> PluginRecoveryToken? {
        var backup: PluginRecoveryToken?
        if fileManager.fileExists(atPath: destination.path) {
            backup = try archive(destination, pluginID: pluginID, reason: recoveryReason)
        }
        do {
            try fileManager.moveItem(at: staged, to: destination)
            return backup
        } catch {
            if let backup, !fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.moveItem(at: backup.location, to: destination)
                } catch {
                    throw PluginCoreError.filesystem(
                        "restore previous plugin after failed install",
                        destination,
                        error.localizedDescription
                    )
                }
            }
            throw PluginCoreError.filesystem("commit plugin install", destination, error.localizedDescription)
        }
    }

    func restore(_ token: PluginRecoveryToken, to destination: URL) throws {
        let recoveryRoot = layout.recoveryRoot.standardizedFileURL
        guard PluginManifestValidator.isContained(token.location, by: recoveryRoot),
              fileManager.fileExists(atPath: token.location.path) else {
            throw PluginCoreError.recoveryUnavailable(token.location)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PluginCoreError.pluginAlreadyInstalled(token.pluginID)
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.moveItem(at: token.location, to: destination)
        } catch {
            throw PluginCoreError.filesystem("restore plugin", destination, error.localizedDescription)
        }
    }

    private func copyContents(from source: URL, to destination: URL, includeGitMetadata: Bool) throws {
        let children = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for child in children {
            if !includeGitMetadata && child.lastPathComponent == ".git" { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            // Match the old host's install semantics: symlinks are never imported.
            if values.isSymbolicLink == true { continue }
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                try copyContents(from: child, to: target, includeGitMetadata: includeGitMetadata)
            } else if values.isRegularFile == true {
                try fileManager.copyItem(at: child, to: target)
            }
        }
    }

    private func uniqueSuffix() -> String {
        "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"
    }
}

final class PluginInstaller {
    let repository: PluginRepository
    private let transactions: PluginFileTransactions
    private let fileManager: FileManager
    private let isRunning: (String) -> Bool
    private let lock = NSLock()

    init(repository: PluginRepository, isRunning: @escaping (String) -> Bool = { _ in false }) {
        self.repository = repository
        fileManager = repository.fileManager
        transactions = .init(layout: repository.layout, fileManager: repository.fileManager)
        self.isRunning = isRunning
    }

    func install(from selectedURL: URL) throws -> PluginInstallReceipt {
        lock.lock()
        defer { lock.unlock() }

        let source = try sourceDirectory(for: selectedURL)
        let manifest = try repository.loader.loadValidated(from: source, fileManager: fileManager)
        let destination = try repository.layout.installedDirectory(for: manifest.id)
        if sameFilesystemLocation(source, destination), fileManager.fileExists(atPath: destination.path) {
            return .init(
                pluginID: manifest.id,
                installedDirectory: destination,
                disposition: .unchanged,
                previousVersion: manifest.version,
                recoveryToken: nil
            )
        }
        if fileManager.fileExists(atPath: destination.path), isRunning(manifest.id) {
            throw PluginCoreError.pluginRunning(manifest.id)
        }

        try transactions.ensureManagedDirectories()
        guard !PluginManifestValidator.isContained(repository.layout.stagingRoot, by: source) else {
            throw PluginCoreError.unsafeFilesystemRelationship(
                "The selected plugin directory contains CC Buddy's transaction workspace"
            )
        }
        let stagingParent = try transactions.makeStagingDirectory(label: manifest.id)
        let stagedPlugin = stagingParent.appendingPathComponent("payload", isDirectory: true)
        try transactions.copyDirectory(from: source, to: stagedPlugin)

        let stagedManifest = try repository.loader.loadValidated(from: stagedPlugin, fileManager: fileManager)
        guard stagedManifest.id == manifest.id else {
            throw PluginCoreError.manifestValidationFailed(
                stagedPlugin.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "changed while the plugin was being staged")]
            )
        }

        var previousVersion: String?
        let existed = fileManager.fileExists(atPath: destination.path)
        if existed {
            previousVersion = try? repository.loader.decode(from: destination).version
            let oldRuntime = destination.appendingPathComponent("runtime.json")
            let newRuntime = stagedPlugin.appendingPathComponent("runtime.json")
            if fileManager.fileExists(atPath: oldRuntime.path), !fileManager.fileExists(atPath: newRuntime.path) {
                do {
                    try fileManager.copyItem(at: oldRuntime, to: newRuntime)
                } catch {
                    throw PluginCoreError.filesystem("preserve runtime.json", newRuntime, error.localizedDescription)
                }
            }
        }

        let recovery = try transactions.replace(
            destination: destination,
            with: stagedPlugin,
            pluginID: manifest.id,
            recoveryReason: .replaced
        )
        return .init(
            pluginID: manifest.id,
            installedDirectory: destination,
            disposition: existed ? .replaced : .installed,
            previousVersion: previousVersion,
            recoveryToken: recovery
        )
    }

    func uninstall(id: String) throws -> PluginUninstallReceipt {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning(id) else { throw PluginCoreError.pluginRunning(id) }
        let destination = try repository.layout.installedDirectory(for: id)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw PluginCoreError.pluginNotInstalled(id)
        }
        let manifest = try repository.loader.decode(from: destination)
        guard manifest.id == id else {
            throw PluginCoreError.manifestValidationFailed(
                destination.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "does not match installed directory '\(id)'")]
            )
        }
        let token = try transactions.archive(destination, pluginID: id, reason: .uninstalled)
        return .init(pluginID: id, recoveryToken: token)
    }

    func restore(_ token: PluginRecoveryToken) throws -> PluginInstallReceipt {
        lock.lock()
        defer { lock.unlock() }

        let destination = try repository.layout.installedDirectory(for: token.pluginID)
        let manifest = try repository.loader.loadValidated(from: token.location, fileManager: fileManager)
        guard manifest.id == token.pluginID else {
            throw PluginCoreError.manifestValidationFailed(
                token.location.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "does not match recovery token")]
            )
        }
        try transactions.restore(token, to: destination)
        return .init(
            pluginID: token.pluginID,
            installedDirectory: destination,
            disposition: .installed,
            previousVersion: nil,
            recoveryToken: nil
        )
    }

    /// Reverses a replacement receipt in one transaction. The currently installed version is
    /// itself archived, so rolling back never discards either side of the swap.
    func rollback(_ receipt: PluginInstallReceipt) throws -> PluginInstallReceipt {
        lock.lock()
        defer { lock.unlock() }

        guard let previous = receipt.recoveryToken,
              previous.reason == .replaced,
              previous.pluginID == receipt.pluginID else {
            throw PluginCoreError.recoveryUnavailable(
                receipt.recoveryToken?.location ?? repository.layout.recoveryRoot
            )
        }
        let destination = try repository.layout.installedDirectory(for: receipt.pluginID)
        guard fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: previous.location.path) else {
            throw PluginCoreError.recoveryUnavailable(previous.location)
        }
        guard !isRunning(receipt.pluginID) else {
            throw PluginCoreError.pluginRunning(receipt.pluginID)
        }
        let manifest = try repository.loader.loadValidated(from: previous.location, fileManager: fileManager)
        guard manifest.id == receipt.pluginID else {
            throw PluginCoreError.manifestValidationFailed(
                previous.location.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "does not match replacement receipt")]
            )
        }
        let replacedCurrent = try transactions.replace(
            destination: destination,
            with: previous.location,
            pluginID: receipt.pluginID,
            recoveryReason: .failedOperation
        )
        return .init(
            pluginID: receipt.pluginID,
            installedDirectory: destination,
            disposition: .replaced,
            previousVersion: receipt.previousVersion,
            recoveryToken: replacedCurrent
        )
    }

    private func sourceDirectory(for selectedURL: URL) throws -> URL {
        let standardized = selectedURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw PluginCoreError.sourceNotDirectory(standardized)
        }
        let directory = isDirectory.boolValue ? standardized : standardized.deletingLastPathComponent()
        var confirmedDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &confirmedDirectory),
              confirmedDirectory.boolValue else {
            throw PluginCoreError.sourceNotDirectory(directory)
        }
        return directory.resolvingSymlinksInPath()
    }

    private func sameFilesystemLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
}
