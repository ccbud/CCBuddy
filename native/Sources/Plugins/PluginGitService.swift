import Foundation

struct PluginUpdateStatus: Equatable, Sendable {
    var hasSource: Bool
    var currentVersion: String
    var latestVersion: String?
    var updateAvailable: Bool
    var source: String?

    static func unavailable(currentVersion: String = "") -> PluginUpdateStatus {
        .init(
            hasSource: false,
            currentVersion: currentVersion,
            latestVersion: nil,
            updateAvailable: false,
            source: nil
        )
    }
}

struct PluginGitReceipt: Equatable {
    var install: PluginInstallReceipt
    var cacheDirectory: URL
    var cacheRecovery: PluginRecoveryToken?
}

enum PluginVersion {
    /// Matches the former Rust host's numeric, semver-ish ordering. Non-numeric suffix pieces
    /// become zero, so this is intentionally not a full SemVer precedence implementation.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            return lhs[index] > rhs[index]
        }
        return lhs.count > rhs.count
    }

    private static func components(_ value: String) -> [UInt64] {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" })
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { UInt64($0) ?? 0 }
    }
}

/// Git-backed install/update orchestration. Every command, binary path, environment, and working
/// directory is represented by `PluginCommandInvocation` and passes through an injected runner.
final class PluginGitService {
    private let repository: PluginRepository
    private let installer: PluginInstaller
    private let runner: PluginCommandRunning
    private let toolchain: PluginToolchain
    private let transactions: PluginFileTransactions
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        repository: PluginRepository,
        installer: PluginInstaller? = nil,
        runner: PluginCommandRunning = PluginProcessCommandRunner(),
        toolchain: PluginToolchain = .init()
    ) {
        self.repository = repository
        self.installer = installer ?? PluginInstaller(repository: repository)
        self.runner = runner
        self.toolchain = toolchain
        transactions = .init(layout: repository.layout, fileManager: repository.fileManager)
        fileManager = repository.fileManager
    }

    /// Clones the repository's default branch first, matching the previous implementation, then
    /// switches to `source.branch` when a non-default branch is declared by that manifest.
    func install(from source: String) throws -> PluginGitReceipt {
        lock.lock()
        defer { lock.unlock() }

        let source = try validatedGitSource(source)
        let stagingParent = try transactions.makeStagingDirectory(label: "git-import")
        let checkout = stagingParent.appendingPathComponent("checkout", isDirectory: true)
        try runGit(["clone", "--depth", "1", "--no-tags", "--", source, checkout.path])

        var manifest = try repository.loader.loadValidated(from: checkout, fileManager: fileManager)
        if manifest.source.branch != "main" {
            try fetch(branch: manifest.source.branch, in: checkout)
            try runGit(["-C", checkout.path, "checkout", "-B", "ccbud-managed", "FETCH_HEAD"])
            manifest = try repository.loader.loadValidated(from: checkout, fileManager: fileManager)
        }
        try buildAndValidate(manifest: manifest, checkout: checkout)

        let cache = try repository.layout.gitCacheDirectory(for: manifest.id)
        let cacheRecovery = try transactions.replace(
            destination: cache,
            with: checkout,
            pluginID: manifest.id,
            recoveryReason: .gitCacheReplaced
        )
        let receipt = try installer.install(from: cache)
        return .init(install: receipt, cacheDirectory: cache, cacheRecovery: cacheRecovery)
    }

    /// Reads the remote manifest through Git rather than a GitHub-only raw URL. Fetch updates
    /// only Git's remote reference; the installed plugin and cached checkout remain untouched.
    func checkForUpdate(id: String) throws -> PluginUpdateStatus {
        lock.lock()
        defer { lock.unlock() }

        let installation = try repository.installation(id: id)
        let source = installation.manifest.source.git.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .unavailable(currentVersion: installation.manifest.version) }
        let validatedSource = try validatedGitSource(source)
        let branch = installation.manifest.source.branch
        guard PluginManifestValidator.isSafeGitBranch(branch) else {
            throw PluginCoreError.invalidGitSource("unsafe branch '\(branch)'")
        }

        let cache = try repository.layout.gitCacheDirectory(for: id)
        let remoteManifest: PluginManifest
        if try cacheMatches(cache, source: validatedSource) {
            try fetch(branch: branch, in: cache)
            let output = try runGit([
                "-C", cache.path, "show", "--format=", "--no-ext-diff", "FETCH_HEAD:plugin.json",
            ])
            remoteManifest = try repository.loader.decode(
                data: output.standardOutput,
                sourceURL: URL(fileURLWithPath: "\(cache.path)/FETCH_HEAD:plugin.json")
            )
            let validation = repository.loader.validator.validate(remoteManifest)
            guard validation.isValid else {
                throw PluginCoreError.manifestValidationFailed(cache.appendingPathComponent("plugin.json"), validation.errors)
            }
        } else {
            let stagingParent = try transactions.makeStagingDirectory(label: id)
            let checkout = stagingParent.appendingPathComponent("remote-check", isDirectory: true)
            try clone(source: validatedSource, branch: branch, to: checkout)
            remoteManifest = try repository.loader.loadValidated(from: checkout, fileManager: fileManager)
            guard remoteManifest.id == id else {
                throw PluginCoreError.manifestValidationFailed(
                    checkout.appendingPathComponent("plugin.json"),
                    [.init(.error, "id", "remote manifest changed plugin id to '\(remoteManifest.id)'")]
                )
            }
            _ = try transactions.replace(
                destination: cache,
                with: checkout,
                pluginID: id,
                recoveryReason: .gitCacheReplaced
            )
        }
        guard remoteManifest.id == id else {
            throw PluginCoreError.manifestValidationFailed(
                cache.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "remote manifest changed plugin id to '\(remoteManifest.id)'")]
            )
        }
        return .init(
            hasSource: true,
            currentVersion: installation.manifest.version,
            latestVersion: remoteManifest.version,
            updateAvailable: PluginVersion.isNewer(remoteManifest.version, than: installation.manifest.version),
            source: validatedSource
        )
    }

    /// Updates from an isolated checkout. When a compatible cache exists this performs a real
    /// `git pull --ff-only`; legacy Rust installs without a cache transparently take the clone path.
    func update(id: String) throws -> PluginGitReceipt {
        lock.lock()
        defer { lock.unlock() }

        let installation = try repository.installation(id: id)
        guard installation.manifest.hasGitSource else { throw PluginCoreError.gitSourceMissing(id) }
        let source = try validatedGitSource(installation.manifest.source.git)
        let branch = installation.manifest.source.branch
        guard PluginManifestValidator.isSafeGitBranch(branch) else {
            throw PluginCoreError.invalidGitSource("unsafe branch '\(branch)'")
        }

        let cache = try repository.layout.gitCacheDirectory(for: id)
        let stagingParent = try transactions.makeStagingDirectory(label: id)
        let checkout = stagingParent.appendingPathComponent("checkout", isDirectory: true)
        if try cacheMatches(cache, source: source) {
            // Clone the cache instead of mutating it. A failed pull/build therefore cannot poison
            // the last known-good cache or touch the installed plugin.
            try runGit(["clone", "--no-hardlinks", "--", cache.path, checkout.path])
            try runGit(["-C", checkout.path, "remote", "set-url", "origin", source])
            try runGit(["-C", checkout.path, "pull", "--ff-only", "origin", branch])
        } else {
            try clone(source: source, branch: branch, to: checkout)
        }

        let remoteManifest = try repository.loader.loadValidated(from: checkout, fileManager: fileManager)
        guard remoteManifest.id == id else {
            throw PluginCoreError.manifestValidationFailed(
                checkout.appendingPathComponent("plugin.json"),
                [.init(.error, "id", "remote manifest changed plugin id to '\(remoteManifest.id)'")]
            )
        }
        try buildAndValidate(manifest: remoteManifest, checkout: checkout)

        let receipt = try installer.install(from: checkout)
        let cacheRecovery = try transactions.replace(
            destination: cache,
            with: checkout,
            pluginID: id,
            recoveryReason: .gitCacheReplaced
        )
        return .init(install: receipt, cacheDirectory: cache, cacheRecovery: cacheRecovery)
    }

    private func clone(source: String, branch: String, to checkout: URL) throws {
        try runGit([
            "clone", "--depth", "1", "--no-tags", "--branch", branch, "--single-branch",
            "--", source, checkout.path,
        ])
    }

    private func fetch(branch: String, in checkout: URL) throws {
        guard PluginManifestValidator.isSafeGitBranch(branch) else {
            throw PluginCoreError.invalidGitSource("unsafe branch '\(branch)'")
        }
        try runGit(["-C", checkout.path, "fetch", "--depth", "1", "origin", branch])
    }

    private func buildAndValidate(manifest: PluginManifest, checkout: URL) throws {
        if !manifest.source.build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let invocation = PluginCommandInvocation(
                executable: toolchain.shellExecutable,
                arguments: ["-c", manifest.source.build],
                currentDirectory: checkout,
                environment: toolchain.environment
            )
            let output = try runner.run(invocation)
            guard output.succeeded else { throw PluginCoreError.commandFailed(invocation, output) }
        }
        _ = try repository.loader.loadValidated(
            from: checkout,
            options: .init(
                platformKey: repository.platformKey,
                requirePlatformExecutable: true,
                requireExecutableFile: true
            ),
            fileManager: fileManager
        )
    }

    private func cacheMatches(_ cache: URL, source: String) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cache.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.fileExists(atPath: cache.appendingPathComponent(".git").path) else {
            return false
        }
        let invocation = PluginCommandInvocation(
            executable: toolchain.gitExecutable,
            arguments: ["-C", cache.path, "remote", "get-url", "origin"],
            environment: toolchain.environment
        )
        let output = try runner.run(invocation)
        guard output.succeeded else { return false }
        return normalizedSource(output.standardOutputString) == normalizedSource(source)
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> PluginCommandOutput {
        let invocation = PluginCommandInvocation(
            executable: toolchain.gitExecutable,
            arguments: arguments,
            environment: toolchain.environment
        )
        let output = try runner.run(invocation)
        guard output.succeeded else { throw PluginCoreError.commandFailed(invocation, output) }
        return output
    }

    private func validatedGitSource(_ raw: String) throws -> String {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PluginManifestValidator.isSafeGitSource(source) else {
            throw PluginCoreError.invalidGitSource(raw)
        }
        return source
    }

    private func normalizedSource(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value
    }
}
