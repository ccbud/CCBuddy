import Foundation

enum PluginPlatform {
    static var currentKey: String {
        #if os(macOS) && arch(arm64)
        return "darwin-arm64"
        #elseif os(macOS) && arch(x86_64)
        return "darwin-amd64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-amd64"
        #elseif os(Linux) && arch(arm64)
        return "linux-arm64"
        #elseif os(Windows) && arch(x86_64)
        return "windows-amd64"
        #else
        return "unknown"
        #endif
    }
}

struct PluginHomeLayout: Equatable {
    var ccbudHome: URL

    init(ccbudHome: URL) {
        self.ccbudHome = ccbudHome.standardizedFileURL
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let configured = environment["CCBUD_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            self.init(ccbudHome: URL(fileURLWithPath: configured, isDirectory: true))
        } else {
            self.init(ccbudHome: homeDirectory.appendingPathComponent(".ccbud", isDirectory: true))
        }
    }

    var pluginsRoot: URL { ccbudHome.appendingPathComponent("plugins", isDirectory: true) }
    var stagingRoot: URL { ccbudHome.appendingPathComponent("plugin-staging", isDirectory: true) }
    var recoveryRoot: URL { ccbudHome.appendingPathComponent("plugin-recovery", isDirectory: true) }
    var gitCacheRoot: URL { ccbudHome.appendingPathComponent("plugin-sources", isDirectory: true) }

    func installedDirectory(for id: String) throws -> URL {
        guard PluginManifestValidator.isValidIdentifier(id) else {
            throw PluginCoreError.invalidIdentifier(id)
        }
        return pluginsRoot.appendingPathComponent(id, isDirectory: true)
    }

    func gitCacheDirectory(for id: String) throws -> URL {
        guard PluginManifestValidator.isValidIdentifier(id) else {
            throw PluginCoreError.invalidIdentifier(id)
        }
        return gitCacheRoot.appendingPathComponent(id, isDirectory: true)
    }
}

struct PluginRuntimeRecord: Codable, Equatable, Sendable {
    var port: Int

    init(port: Int) {
        self.port = port
    }

    var validPort: UInt16? {
        guard (1...Int(UInt16.max)).contains(port) else { return nil }
        return UInt16(port)
    }
}

struct PluginProviderDescriptor: Equatable, Sendable {
    var id: String
    var name: String
    var pluginID: String
    var baseURL: URL
    var protocolName: String
    var defaultModel: String
    var smallFastModel: String
    var iconFile: URL?
}

struct PluginSidecarDescriptor: Equatable, Sendable {
    var pluginID: String
    var executable: URL
    var arguments: [String]
    var workingDirectory: URL
    var standardErrorLog: URL
    var healthURL: URL
    var authenticationStatusURL: URL
    var readyTimeoutMilliseconds: Int
    var provider: PluginProviderDescriptor
}

enum PluginLifecycleState: String, Codable, Equatable, Sendable {
    case installed
    case starting
    case running
    case stopping
    case stopped
    case failed
}

struct PluginInstallation: Equatable {
    var manifest: PluginManifest
    var directory: URL
    var runtime: PluginRuntimeRecord?
    var validation: PluginManifestValidation

    var id: String { manifest.id }
    var isUsable: Bool { validation.isValid }
    var providerID: String { manifest.providerIdentifier }
    var hasGitSource: Bool { manifest.hasGitSource }
    var isOfficialSource: Bool { PluginGitSource.isOfficial(manifest.source.git) }
}

struct PluginDiscoveryIssue: Equatable {
    var directory: URL
    var message: String
}

struct PluginDiscoverySnapshot: Equatable {
    var installations: [PluginInstallation]
    var issues: [PluginDiscoveryIssue]
}

struct PluginRepository {
    var layout: PluginHomeLayout
    var platformKey: String
    var fileManager: FileManager
    var loader: PluginManifestLoader

    init(
        layout: PluginHomeLayout = .init(),
        platformKey: String = PluginPlatform.currentKey,
        fileManager: FileManager = .default,
        loader: PluginManifestLoader = .init()
    ) {
        self.layout = layout
        self.platformKey = platformKey
        self.fileManager = fileManager
        self.loader = loader
    }

    /// Enumerates only immediate, non-hidden directories under the legacy plugins root.
    /// Broken entries are reported instead of making the complete list fail.
    func discover() -> PluginDiscoverySnapshot {
        guard fileManager.fileExists(atPath: layout.pluginsRoot.path) else {
            return .init(installations: [], issues: [])
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: layout.pluginsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            return .init(
                installations: [],
                issues: [.init(directory: layout.pluginsRoot, message: error.localizedDescription)]
            )
        }

        var installations: [PluginInstallation] = []
        var issues: [PluginDiscoveryIssue] = []
        for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if directory.lastPathComponent.hasPrefix(".") { continue }
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let manifest = try loader.decode(from: directory)
                guard manifest.id == directory.lastPathComponent else {
                    issues.append(.init(
                        directory: directory,
                        message: "manifest id '\(manifest.id)' does not match directory '\(directory.lastPathComponent)'"
                    ))
                    continue
                }
                let validation = loader.validator.validate(
                    manifest,
                    directory: directory,
                    options: .init(platformKey: platformKey),
                    fileManager: fileManager
                )
                var runtime: PluginRuntimeRecord?
                let runtimeURL = directory.appendingPathComponent("runtime.json")
                if fileManager.fileExists(atPath: runtimeURL.path) {
                    do {
                        let decoded = try JSONDecoder().decode(PluginRuntimeRecord.self, from: Data(contentsOf: runtimeURL))
                        if decoded.validPort == nil {
                            issues.append(.init(directory: directory, message: "runtime.json contains an invalid port"))
                        } else {
                            runtime = decoded
                        }
                    } catch {
                        issues.append(.init(directory: directory, message: "invalid runtime.json: \(error.localizedDescription)"))
                    }
                }
                installations.append(.init(
                    manifest: manifest,
                    directory: directory,
                    runtime: runtime,
                    validation: validation
                ))
            } catch {
                issues.append(.init(directory: directory, message: error.localizedDescription))
            }
        }
        return .init(installations: installations, issues: issues)
    }

    func installation(id: String) throws -> PluginInstallation {
        let directory = try layout.installedDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw PluginCoreError.pluginNotInstalled(id)
        }
        let manifest = try loader.loadValidated(from: directory, fileManager: fileManager)
        guard manifest.id == id else {
            throw PluginCoreError.manifestValidationFailed(
                directory.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "does not match installed directory '\(id)'")]
            )
        }
        let runtime = try readRuntime(id: id)
        return .init(
            manifest: manifest,
            directory: directory,
            runtime: runtime,
            validation: loader.validator.validate(manifest, directory: directory, fileManager: fileManager)
        )
    }

    func readRuntime(id: String) throws -> PluginRuntimeRecord? {
        let runtimeURL = try layout.installedDirectory(for: id).appendingPathComponent("runtime.json")
        guard fileManager.fileExists(atPath: runtimeURL.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(PluginRuntimeRecord.self, from: Data(contentsOf: runtimeURL))
            guard record.validPort != nil else {
                throw PluginCoreError.filesystem("decode runtime.json", runtimeURL, "port must be 1...65535")
            }
            return record
        } catch let error as PluginCoreError {
            throw error
        } catch {
            throw PluginCoreError.filesystem("decode runtime.json", runtimeURL, error.localizedDescription)
        }
    }

    /// Writes the same `{ "port": n }` schema used by the Rust manager.
    func writeRuntime(_ record: PluginRuntimeRecord, id: String) throws {
        guard record.validPort != nil else {
            throw PluginCoreError.filesystem("encode runtime.json", layout.pluginsRoot, "port must be 1...65535")
        }
        let directory = try layout.installedDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw PluginCoreError.pluginNotInstalled(id)
        }
        let runtimeURL = directory.appendingPathComponent("runtime.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: runtimeURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)
        } catch {
            throw PluginCoreError.filesystem("write runtime.json", runtimeURL, error.localizedDescription)
        }
    }

    func sidecarDescriptor(id: String, port: UInt16) throws -> PluginSidecarDescriptor {
        let installation = try installation(id: id)
        let manifest = installation.manifest
        let platformValidation = loader.validator.validate(
            manifest,
            directory: installation.directory,
            options: .init(
                platformKey: platformKey,
                requirePlatformExecutable: true,
                requireExecutableFile: true
            ),
            fileManager: fileManager
        )
        guard platformValidation.isValid,
              let executablePath = manifest.executablePath(for: platformKey) else {
            let detail = platformValidation.errors.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            throw PluginCoreError.executableUnavailable(detail)
        }
        let executable = try PluginManifestValidator.containedURL(
            relativePath: executablePath,
            in: installation.directory
        )
        let home = installation.directory.path
        let arguments = manifest.runtime.arguments.map {
            $0.replacingOccurrences(of: "{port}", with: String(port))
                .replacingOccurrences(of: "{home}", with: home)
        }
        guard
            let providerBaseURL = URL(string: "http://127.0.0.1:\(port)\(manifest.endpoint.basePath)"),
            let healthURL = URL(string: "http://127.0.0.1:\(port)\(manifest.endpoint.healthPath)"),
            let authenticationURL = URL(string: "http://127.0.0.1:\(port)\(manifest.authentication.statusPath)")
        else {
            throw PluginCoreError.manifestValidationFailed(
                installation.directory.appendingPathComponent("plugin.json"),
                [.init(.error, "endpoint", "could not construct localhost control-plane URLs")]
            )
        }
        let iconFile: URL?
        if manifest.icon.isEmpty {
            iconFile = nil
        } else {
            iconFile = try? PluginManifestValidator.containedURL(relativePath: manifest.icon, in: installation.directory)
        }
        let provider = PluginProviderDescriptor(
            id: manifest.providerIdentifier,
            name: manifest.name,
            pluginID: id,
            baseURL: providerBaseURL,
            protocolName: manifest.endpoint.protocolName,
            defaultModel: manifest.modelMapping.primary,
            smallFastModel: manifest.modelMapping.light,
            iconFile: iconFile
        )
        return PluginSidecarDescriptor(
            pluginID: id,
            executable: executable,
            arguments: arguments,
            workingDirectory: installation.directory,
            standardErrorLog: installation.directory.appendingPathComponent("plugin.log"),
            healthURL: healthURL,
            authenticationStatusURL: authenticationURL,
            readyTimeoutMilliseconds: manifest.endpoint.readyTimeoutMilliseconds,
            provider: provider
        )
    }
}

enum PluginGitSource {
    static func isOfficial(_ source: String) -> Bool {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: #"\.git$"#, with: "", options: .regularExpression)
        let remainder: String?
        if normalized.hasPrefix("https://github.com/") {
            remainder = String(normalized.dropFirst("https://github.com/".count))
        } else if normalized.hasPrefix("http://github.com/") {
            remainder = String(normalized.dropFirst("http://github.com/".count))
        } else if normalized.hasPrefix("git@github.com:") {
            remainder = String(normalized.dropFirst("git@github.com:".count))
        } else {
            remainder = nil
        }
        return remainder?.split(separator: "/").first?.lowercased() == "ccbud"
    }
}
