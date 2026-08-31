import XCTest
@testable import CCBuddy

final class PluginGitServiceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testGitInstallUsesInjectedCloneAndBuildCommands() throws {
        let root = try makeTemporaryRoot()
        let source = "https://example.com/acme/native-plugin.git"
        let runner = RecordingPluginCommandRunner(
            source: source,
            pluginID: "native-plugin",
            remoteVersion: "1.0.0"
        )
        let repository = PluginRepository(
            layout: .init(ccbudHome: root),
            platformKey: "darwin-arm64"
        )
        let toolchain = PluginToolchain(
            gitExecutable: URL(fileURLWithPath: "/fixture/bin/git"),
            shellExecutable: URL(fileURLWithPath: "/fixture/bin/sh"),
            environment: ["PATH": "/fixture/bin"]
        )
        let service = PluginGitService(repository: repository, runner: runner, toolchain: toolchain)

        let receipt = try service.install(from: source)
        XCTAssertEqual(receipt.install.pluginID, "native-plugin")
        XCTAssertEqual(receipt.install.disposition, .installed)
        XCTAssertEqual(try repository.installation(id: "native-plugin").manifest.version, "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.cacheDirectory.appendingPathComponent(".git").path))

        let clone = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(clone.executable.path, "/fixture/bin/git")
        XCTAssertEqual(Array(clone.arguments.prefix(4)), ["clone", "--depth", "1", "--no-tags"])
        XCTAssertTrue(clone.arguments.contains("--"))
        XCTAssertEqual(clone.arguments.dropLast().last, source)
        let build = try XCTUnwrap(runner.invocations.first(where: { $0.executable.path == "/fixture/bin/sh" }))
        XCTAssertEqual(build.arguments, ["-c", "make dist"])
        XCTAssertEqual(build.environment, ["PATH": "/fixture/bin"])
    }

    func testCachedUpdatePullsInIsolationThenTransactionallyReplacesInstall() throws {
        let root = try makeTemporaryRoot()
        let source = "https://example.com/acme/native-plugin.git"
        let repository = PluginRepository(
            layout: .init(ccbudHome: root),
            platformKey: "darwin-arm64"
        )
        let runner = RecordingPluginCommandRunner(
            source: source,
            pluginID: "native-plugin",
            remoteVersion: "1.0.0"
        )
        let service = PluginGitService(repository: repository, runner: runner)
        _ = try service.install(from: source)
        runner.invocations.removeAll()
        runner.remoteVersion = "2.0.0"

        let receipt = try service.update(id: "native-plugin")
        XCTAssertEqual(receipt.install.disposition, .replaced)
        XCTAssertEqual(receipt.install.previousVersion, "1.0.0")
        XCTAssertEqual(try repository.installation(id: "native-plugin").manifest.version, "2.0.0")
        XCTAssertEqual(
            try String(contentsOf: receipt.install.installedDirectory.appendingPathComponent("payload.txt")),
            "remote-2.0.0"
        )
        XCTAssertNotNil(receipt.install.recoveryToken)
        XCTAssertNotNil(receipt.cacheRecovery)

        let argumentLists = runner.invocations.map(\.arguments)
        XCTAssertTrue(argumentLists.contains { $0.contains("--no-hardlinks") })
        XCTAssertTrue(argumentLists.contains { arguments in
            arguments.contains("pull") && arguments.contains("--ff-only")
                && arguments.suffix(2) == ["origin", "main"]
        })
        XCTAssertFalse(argumentLists.contains { $0.contains("reset") || $0.contains("clean") })
    }

    func testUpdateCheckFetchesRemoteManifestAndComparesVersions() throws {
        let root = try makeTemporaryRoot()
        let source = "https://example.com/acme/native-plugin.git"
        let repository = PluginRepository(layout: .init(ccbudHome: root), platformKey: "darwin-arm64")
        let runner = RecordingPluginCommandRunner(
            source: source,
            pluginID: "native-plugin",
            remoteVersion: "1.0.0"
        )
        let service = PluginGitService(repository: repository, runner: runner)
        _ = try service.install(from: source)
        runner.invocations.removeAll()
        runner.remoteVersion = "1.4.0"

        let status = try service.checkForUpdate(id: "native-plugin")
        XCTAssertTrue(status.hasSource)
        XCTAssertEqual(status.currentVersion, "1.0.0")
        XCTAssertEqual(status.latestVersion, "1.4.0")
        XCTAssertTrue(status.updateAvailable)
        XCTAssertTrue(runner.invocations.contains { $0.arguments.contains("fetch") })
        XCTAssertTrue(runner.invocations.contains { $0.arguments.contains("FETCH_HEAD:plugin.json") })
    }

    func testOptionLikeGitSourceIsRejectedBeforeCommandExecution() throws {
        let root = try makeTemporaryRoot()
        let runner = RecordingPluginCommandRunner(
            source: "https://example.com/unused.git",
            pluginID: "unused",
            remoteVersion: "1.0.0"
        )
        let repository = PluginRepository(layout: .init(ccbudHome: root), platformKey: "darwin-arm64")
        let service = PluginGitService(repository: repository, runner: runner)

        XCTAssertThrowsError(try service.install(from: "--upload-pack=attacker")) { error in
            guard case PluginCoreError.invalidGitSource = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = try PluginTestSupport.temporaryDirectory(prefix: "ccbud-plugin-git")
        temporaryRoots.append(root)
        return root
    }
}

private final class RecordingPluginCommandRunner: PluginCommandRunning {
    var invocations: [PluginCommandInvocation] = []
    let source: String
    let pluginID: String
    var remoteVersion: String

    init(source: String, pluginID: String, remoteVersion: String) {
        self.source = source
        self.pluginID = pluginID
        self.remoteVersion = remoteVersion
    }

    func run(_ invocation: PluginCommandInvocation) throws -> PluginCommandOutput {
        invocations.append(invocation)
        if invocation.executable.lastPathComponent == "sh" {
            return .init(terminationStatus: 0)
        }
        let arguments = invocation.arguments
        if arguments.contains("remote"), arguments.contains("get-url") {
            return .init(terminationStatus: 0, standardOutput: Data((source + "\n").utf8))
        }
        if arguments.first == "clone" {
            let destination = URL(fileURLWithPath: arguments.last ?? "")
            if arguments.contains("--no-hardlinks"), arguments.count >= 3 {
                let sourceDirectory = URL(fileURLWithPath: arguments[arguments.count - 2])
                try FileManager.default.copyItem(at: sourceDirectory, to: destination)
            } else {
                try writeRemoteCheckout(at: destination, version: remoteVersion)
            }
            return .init(terminationStatus: 0)
        }
        if arguments.contains("pull") {
            guard let marker = arguments.firstIndex(of: "-C"), arguments.indices.contains(marker + 1) else {
                return .init(terminationStatus: 2, standardError: Data("missing -C".utf8))
            }
            try writeRemoteCheckout(
                at: URL(fileURLWithPath: arguments[marker + 1]),
                version: remoteVersion,
                preserveGit: true
            )
            return .init(terminationStatus: 0)
        }
        if arguments.contains("show"), arguments.contains("FETCH_HEAD:plugin.json") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try writeRemoteCheckout(at: temporary, version: remoteVersion)
            let data = try Data(contentsOf: temporary.appendingPathComponent("plugin.json"))
            try? FileManager.default.removeItem(at: temporary)
            return .init(terminationStatus: 0, standardOutput: data)
        }
        return .init(terminationStatus: 0)
    }

    private func writeRemoteCheckout(at directory: URL, version: String, preserveGit: Bool = false) throws {
        try PluginTestSupport.writePlugin(
            at: directory,
            id: pluginID,
            version: version,
            source: source,
            build: "make dist",
            payload: "remote-\(version)"
        )
        let git = directory.appendingPathComponent(".git", isDirectory: true)
        if !preserveGit || !FileManager.default.fileExists(atPath: git.path) {
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        }
    }
}
