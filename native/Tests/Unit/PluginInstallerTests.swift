import XCTest
@testable import CCBuddy

final class PluginInstallerTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testReplacementPreservesRuntimeAndArchivesPreviousVersion() throws {
        let root = try makeTemporaryRoot()
        let source = try makeTemporaryRoot()
        let sourcePlugin = source.appendingPathComponent("local-plugin")
        try PluginTestSupport.writePlugin(
            at: sourcePlugin,
            id: "local-plugin",
            version: "1.0.0",
            payload: "old"
        )
        let repository = PluginRepository(
            layout: .init(ccbudHome: root),
            platformKey: "darwin-arm64"
        )
        let installer = PluginInstaller(repository: repository)

        let first = try installer.install(from: sourcePlugin)
        XCTAssertEqual(first.disposition, .installed)
        try repository.writeRuntime(.init(port: 9_202), id: "local-plugin")

        try PluginTestSupport.writePlugin(
            at: sourcePlugin,
            id: "local-plugin",
            version: "2.0.0",
            payload: "new"
        )
        let second = try installer.install(from: sourcePlugin)
        XCTAssertEqual(second.disposition, .replaced)
        XCTAssertEqual(second.previousVersion, "1.0.0")
        XCTAssertEqual(try repository.readRuntime(id: "local-plugin"), .init(port: 9_202))
        XCTAssertEqual(try repository.installation(id: "local-plugin").manifest.version, "2.0.0")
        XCTAssertEqual(
            try String(contentsOf: second.installedDirectory.appendingPathComponent("payload.txt")),
            "new"
        )

        let recovery = try XCTUnwrap(second.recoveryToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.location.path))
        XCTAssertEqual(try PluginManifestLoader().decode(from: recovery.location).version, "1.0.0")
        XCTAssertEqual(
            try String(contentsOf: recovery.location.appendingPathComponent("payload.txt")),
            "old"
        )

        let rollback = try installer.rollback(second)
        XCTAssertEqual(try repository.installation(id: "local-plugin").manifest.version, "1.0.0")
        XCTAssertEqual(
            try String(contentsOf: rollback.installedDirectory.appendingPathComponent("payload.txt")),
            "old"
        )
        XCTAssertEqual(
            try PluginManifestLoader().decode(from: try XCTUnwrap(rollback.recoveryToken).location).version,
            "2.0.0"
        )
    }

    func testUninstallMovesToRecoveryAndCanBeRestored() throws {
        let root = try makeTemporaryRoot()
        let source = try makeTemporaryRoot().appendingPathComponent("recoverable")
        try PluginTestSupport.writePlugin(at: source, id: "recoverable", version: "1.0.0")
        let repository = PluginRepository(layout: .init(ccbudHome: root), platformKey: "darwin-arm64")
        let installer = PluginInstaller(repository: repository)
        _ = try installer.install(from: source)

        let uninstall = try installer.uninstall(id: "recoverable")
        let installed = try repository.layout.installedDirectory(for: "recoverable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uninstall.recoveryToken.location.path))

        _ = try installer.restore(uninstall.recoveryToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uninstall.recoveryToken.location.path))
        XCTAssertEqual(try repository.installation(id: "recoverable").manifest.version, "1.0.0")
    }

    func testRunningPluginCannotBeReplacedOrUninstalled() throws {
        let root = try makeTemporaryRoot()
        let source = try makeTemporaryRoot().appendingPathComponent("busy")
        try PluginTestSupport.writePlugin(at: source, id: "busy", version: "1.0.0")
        let repository = PluginRepository(layout: .init(ccbudHome: root), platformKey: "darwin-arm64")
        let initialInstaller = PluginInstaller(repository: repository)
        _ = try initialInstaller.install(from: source)

        try PluginTestSupport.writePlugin(at: source, id: "busy", version: "2.0.0")
        let guardedInstaller = PluginInstaller(repository: repository, isRunning: { $0 == "busy" })
        XCTAssertThrowsError(try guardedInstaller.install(from: source)) { error in
            guard case PluginCoreError.pluginRunning("busy") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try guardedInstaller.uninstall(id: "busy")) { error in
            guard case PluginCoreError.pluginRunning("busy") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try repository.installation(id: "busy").manifest.version, "1.0.0")
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = try PluginTestSupport.temporaryDirectory(prefix: "ccbud-plugin-installer")
        temporaryRoots.append(root)
        return root
    }
}
