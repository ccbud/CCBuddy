import Foundation

enum PluginValidationSeverity: String, Codable, Equatable {
    case warning
    case error
}

struct PluginManifestIssue: Codable, Equatable {
    var severity: PluginValidationSeverity
    var path: String
    var message: String

    init(_ severity: PluginValidationSeverity, _ path: String, _ message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

struct PluginManifestValidation: Equatable {
    var issues: [PluginManifestIssue]

    var errors: [PluginManifestIssue] { issues.filter { $0.severity == .error } }
    var warnings: [PluginManifestIssue] { issues.filter { $0.severity == .warning } }
    var isValid: Bool { errors.isEmpty }
}

struct PluginManifestValidationOptions: Equatable {
    var platformKey: String?
    var requirePlatformExecutable: Bool
    var requireExecutableFile: Bool

    init(
        platformKey: String? = nil,
        requirePlatformExecutable: Bool = false,
        requireExecutableFile: Bool = false
    ) {
        self.platformKey = platformKey
        self.requirePlatformExecutable = requirePlatformExecutable
        self.requireExecutableFile = requireExecutableFile
    }
}

enum PluginCoreError: Error, LocalizedError {
    case invalidIdentifier(String)
    case manifestUnreadable(URL, String)
    case manifestInvalidJSON(URL, String)
    case manifestValidationFailed(URL, [PluginManifestIssue])
    case sourceNotDirectory(URL)
    case unsafeFilesystemRelationship(String)
    case pluginNotInstalled(String)
    case pluginAlreadyInstalled(String)
    case pluginRunning(String)
    case executableUnavailable(String)
    case recoveryUnavailable(URL)
    case filesystem(String, URL, String)
    case invalidGitSource(String)
    case gitSourceMissing(String)
    case commandFailed(PluginCommandInvocation, PluginCommandOutput)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            return "Invalid plugin identifier: \(id)"
        case .manifestUnreadable(let url, let detail):
            return "Could not read \(url.path): \(detail)"
        case .manifestInvalidJSON(let url, let detail):
            return "Invalid plugin manifest at \(url.path): \(detail)"
        case .manifestValidationFailed(let url, let issues):
            let detail = issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            return "Plugin manifest validation failed at \(url.path): \(detail)"
        case .sourceNotDirectory(let url):
            return "Plugin source is not a directory: \(url.path)"
        case .unsafeFilesystemRelationship(let detail):
            return detail
        case .pluginNotInstalled(let id):
            return "Plugin '\(id)' is not installed"
        case .pluginAlreadyInstalled(let id):
            return "Plugin '\(id)' is already installed"
        case .pluginRunning(let id):
            return "Plugin '\(id)' must be stopped before replacing its files"
        case .executableUnavailable(let detail):
            return detail
        case .recoveryUnavailable(let url):
            return "Plugin recovery entry is unavailable: \(url.path)"
        case .filesystem(let operation, let url, let detail):
            return "\(operation) failed at \(url.path): \(detail)"
        case .invalidGitSource(let source):
            return "Invalid Git source: \(source)"
        case .gitSourceMissing(let id):
            return "Plugin '\(id)' does not declare source.git"
        case .commandFailed(let invocation, let output):
            let detail = output.standardErrorString.isEmpty ? output.standardOutputString : output.standardErrorString
            return "\(invocation.displayName) exited with status \(output.terminationStatus): \(detail)"
        }
    }
}

struct PluginManifestValidator {
    static let supportedProtocols = Set(["anthropic", "openai-chat", "openai-responses"])
    static let supportedActionKinds = Set(["link", "call", "form"])

    func validate(
        _ manifest: PluginManifest,
        directory: URL? = nil,
        options: PluginManifestValidationOptions = .init(),
        fileManager: FileManager = .default
    ) -> PluginManifestValidation {
        var issues: [PluginManifestIssue] = []
        func error(_ path: String, _ message: String) {
            issues.append(.init(.error, path, message))
        }
        func warning(_ path: String, _ message: String) {
            issues.append(.init(.warning, path, message))
        }

        if manifest.spec != PluginManifest.supportedSpec {
            error("spec", "unsupported contract '\(manifest.spec)'")
        }
        if !Self.isValidIdentifier(manifest.id) {
            error("id", "use 1–128 ASCII letters, digits, dots, underscores, or hyphens; start with a letter or digit")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("name", "must not be empty")
        }
        if manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("version", "must not be empty")
        }
        if !Self.supportedProtocols.contains(manifest.endpoint.protocolName) {
            error("endpoint.protocol", "must be anthropic, openai-chat, or openai-responses")
        }
        validateEndpointPath(manifest.endpoint.basePath, at: "endpoint.basePath", error: error)
        validateEndpointPath(manifest.endpoint.healthPath, at: "endpoint.healthPath", error: error)
        validateEndpointPath(manifest.authentication.statusPath, at: "auth.statusPath", error: error)
        if !(1...300_000).contains(manifest.endpoint.readyTimeoutMilliseconds) {
            error("endpoint.readyTimeoutMs", "must be between 1 and 300000 milliseconds")
        }

        if manifest.runtime.executables.isEmpty {
            error("runtime.exec", "must declare at least one platform executable")
        }
        for (key, path) in manifest.runtime.executables.sorted(by: { $0.key < $1.key }) {
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("runtime.exec", "contains an empty platform key")
            }
            if !Self.isSafeRelativePath(path) {
                error("runtime.exec.\(key)", "must be a relative path contained by the plugin directory")
            }
        }
        for (index, argument) in manifest.runtime.arguments.enumerated() where Self.containsControlCharacter(argument) {
            error("runtime.args[\(index)]", "must not contain NUL or newline characters")
        }
        if !manifest.icon.isEmpty && !Self.isSafeRelativePath(manifest.icon) {
            error("icon", "must be a relative path contained by the plugin directory")
        }

        if !manifest.source.git.isEmpty && !Self.isSafeGitSource(manifest.source.git) {
            error("source.git", "must be a non-option Git URL or path without control characters")
        }
        if !Self.isSafeGitBranch(manifest.source.branch) {
            error("source.branch", "is not a safe Git branch name")
        }
        if manifest.source.build.contains("\0") {
            error("source.build", "must not contain NUL characters")
        }

        var aliases = Set<String>()
        for (index, model) in manifest.models.enumerated() {
            if model.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("models[\(index)].alias", "must not be empty")
            } else if !aliases.insert(model.alias).inserted {
                error("models[\(index)].alias", "duplicates alias '\(model.alias)'")
            }
            if model.upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("models[\(index)].upstream", "must not be empty")
            }
        }
        if !manifest.modelMapping.primary.isEmpty && !aliases.contains(manifest.modelMapping.primary) {
            warning("modelMapping.primary", "does not match a declared model alias")
        }
        if !manifest.modelMapping.light.isEmpty && !aliases.contains(manifest.modelMapping.light) {
            warning("modelMapping.light", "does not match a declared model alias")
        }

        var actionIDs = Set<String>()
        for (index, action) in manifest.userInterface.actions.enumerated() {
            let base = "ui.actions[\(index)]"
            if !Self.isValidIdentifier(action.id) {
                error("\(base).id", "must be a safe non-empty identifier")
            } else if !actionIDs.insert(action.id).inserted {
                error("\(base).id", "duplicates action '\(action.id)'")
            }
            if !Self.supportedActionKinds.contains(action.kind) {
                error("\(base).kind", "must be link, call, or form")
            }
            if action.kind != "link" || action.requiresRunning == true {
                validateEndpointPath(action.submitPath, at: "\(base).submitPath", error: error)
                validateEndpointPath(action.loadPath, at: "\(base).loadPath", error: error)
            }
            if action.kind == "link" {
                let rawURL = action.values["url"]?.stringValue ?? ""
                guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    error("\(base).url", "link actions require an http or https URL")
                    continue
                }
            }
        }

        if options.requirePlatformExecutable, let platformKey = options.platformKey {
            guard let relative = manifest.executablePath(for: platformKey), Self.isSafeRelativePath(relative) else {
                error("runtime.exec.\(platformKey)", "does not declare a usable executable for this platform")
                return PluginManifestValidation(issues: issues)
            }
            if options.requireExecutableFile, let directory {
                do {
                    let executable = try Self.containedURL(relativePath: relative, in: directory)
                    var isDirectory: ObjCBool = false
                    if !fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory) || isDirectory.boolValue {
                        error("runtime.exec.\(platformKey)", "binary is missing at \(relative)")
                    } else if !fileManager.isExecutableFile(atPath: executable.path) {
                        error("runtime.exec.\(platformKey)", "binary is not executable at \(relative)")
                    }
                } catch {
                    issues.append(.init(
                        .error,
                        "runtime.exec.\(platformKey)",
                        "resolves outside the plugin directory"
                    ))
                }
            }
        }

        return PluginManifestValidation(issues: issues)
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...128).contains(scalars.count), let first = scalars.first, isASCIIAlphaNumeric(first) else {
            return false
        }
        return scalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !containsControlCharacter(value), !value.hasPrefix("/"), !value.hasPrefix("~") else {
            return false
        }
        if value.contains("\\") || value.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    static func isSafeGitSource(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("-") && !containsControlCharacter(trimmed)
    }

    static func isSafeGitBranch(_ value: String) -> Bool {
        let branch = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.hasSuffix("."), !branch.contains(".."), !branch.contains("@{"),
              !branch.contains("//"), !branch.contains("\\"), !containsControlCharacter(branch) else {
            return false
        }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[")
        return branch.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    static func containedURL(relativePath: String, in directory: URL) throws -> URL {
        guard isSafeRelativePath(relativePath) else {
            throw PluginCoreError.unsafeFilesystemRelationship("Unsafe relative plugin path: \(relativePath)")
        }
        let base = directory.standardizedFileURL
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        guard isContained(candidate, by: base) else {
            throw PluginCoreError.unsafeFilesystemRelationship("Plugin path escapes its directory: \(relativePath)")
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolvedBase = base.resolvingSymlinksInPath()
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            guard isContained(resolvedCandidate, by: resolvedBase) else {
                throw PluginCoreError.unsafeFilesystemRelationship("Plugin symlink escapes its directory: \(relativePath)")
            }
        }
        return candidate
    }

    static func isContained(_ candidate: URL, by directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func validateEndpointPath(
        _ value: String,
        at path: String,
        error: (String, String) -> Void
    ) {
        guard value.hasPrefix("/"), !value.hasPrefix("//"), !Self.containsControlCharacter(value),
              URLComponents(string: value)?.scheme == nil else {
            error(path, "must be a local absolute URL path")
            return
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
    }
}

struct PluginManifestLoader {
    var decoder: JSONDecoder
    var validator: PluginManifestValidator

    init(decoder: JSONDecoder = JSONDecoder(), validator: PluginManifestValidator = .init()) {
        self.decoder = decoder
        self.validator = validator
    }

    func decode(from directory: URL) throws -> PluginManifest {
        let manifestURL = directory.appendingPathComponent("plugin.json", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        } catch {
            throw PluginCoreError.manifestUnreadable(manifestURL, error.localizedDescription)
        }
        do {
            return try decoder.decode(PluginManifest.self, from: data)
        } catch {
            throw PluginCoreError.manifestInvalidJSON(manifestURL, error.localizedDescription)
        }
    }

    func decode(data: Data, sourceURL: URL) throws -> PluginManifest {
        do {
            return try decoder.decode(PluginManifest.self, from: data)
        } catch {
            throw PluginCoreError.manifestInvalidJSON(sourceURL, error.localizedDescription)
        }
    }

    func loadValidated(
        from directory: URL,
        options: PluginManifestValidationOptions = .init(),
        fileManager: FileManager = .default
    ) throws -> PluginManifest {
        let manifest = try decode(from: directory)
        let validation = validator.validate(manifest, directory: directory, options: options, fileManager: fileManager)
        guard validation.isValid else {
            throw PluginCoreError.manifestValidationFailed(
                directory.appendingPathComponent("plugin.json"),
                validation.errors
            )
        }
        return manifest
    }
}
