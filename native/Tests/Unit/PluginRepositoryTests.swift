import XCTest
@testable import CCBuddy

final class PluginRepositoryTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
    }

    func testDiscoveryRuntimeCompatibilityAndSidecarDescription() throws {
        let root = try makeTemporaryRoot()
        let layout = PluginHomeLayout(ccbudHome: root)
        let plugin = layout.pluginsRoot.appendingPathComponent("fixture-plugin", isDirectory: true)
        try PluginTestSupport.writePlugin(at: plugin, id: "fixture-plugin", version: "1.0.0")
        let repository = PluginRepository(layout: layout, platformKey: "darwin-arm64")

        try repository.writeRuntime(.init(port: 9_101), id: "fixture-plugin")
        let snapshot = repository.discover()
        XCTAssertEqual(snapshot.installations.map(\.id), ["fixture-plugin"])
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertEqual(snapshot.installations[0].runtime, .init(port: 9_101))

        let descriptor = try repository.sidecarDescriptor(id: "fixture-plugin", port: 9_101)
        XCTAssertEqual(descriptor.pluginID, "fixture-plugin")
        XCTAssertEqual(descriptor.arguments, [
            "serve", "--port", "9101", "--home", plugin.path,
        ])
        XCTAssertEqual(descriptor.healthURL.absoluteString, "http://127.0.0.1:9101/healthz")
        XCTAssertEqual(descriptor.authenticationStatusURL.absoluteString, "http://127.0.0.1:9101/v1/plugin/auth")
        XCTAssertEqual(descriptor.provider.id, "plugin:fixture-plugin")
        XCTAssertEqual(descriptor.provider.baseURL.absoluteString, "http://127.0.0.1:9101/v1")

        let runtimeObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: plugin.appendingPathComponent("runtime.json"))
        ) as? [String: Int]
        XCTAssertEqual(runtimeObject, ["port": 9_101])
    }

    func testDiscoveryIsDeterministicAndReportsBrokenOrMismatchedEntries() throws {
        let root = try makeTemporaryRoot()
        let layout = PluginHomeLayout(ccbudHome: root)
        try PluginTestSupport.writePlugin(
            at: layout.pluginsRoot.appendingPathComponent("z-last"),
            id: "z-last",
            version: "1.0.0"
        )
        try PluginTestSupport.writePlugin(
            at: layout.pluginsRoot.appendingPathComponent("a-first"),
            id: "a-first",
            version: "1.0.0"
        )
        try PluginTestSupport.writePlugin(
            at: layout.pluginsRoot.appendingPathComponent("wrong-directory"),
            id: "different-id",
            version: "1.0.0"
        )
        let broken = layout.pluginsRoot.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("plugin.json"))

        let snapshot = PluginRepository(layout: layout, platformKey: "darwin-arm64").discover()
        XCTAssertEqual(snapshot.installations.map(\.id), ["a-first", "z-last"])
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertTrue(snapshot.issues.contains { $0.message.contains("does not match directory") })
        XCTAssertTrue(snapshot.issues.contains { $0.message.contains("Invalid plugin manifest") })
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = try PluginTestSupport.temporaryDirectory(prefix: "ccbud-plugin-repository")
        temporaryRoots.append(root)
        return root
    }
}
