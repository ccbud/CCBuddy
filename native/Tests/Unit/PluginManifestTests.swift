import XCTest
@testable import CCBuddy

final class PluginManifestTests: XCTestCase {
    func testReferenceFixturesResolveInsideTestBundle() throws {
        let fixture = PluginTestSupport.fixtureManifest("valid")
        let resourceRoot = try XCTUnwrap(Bundle(for: PluginManifestTests.self).resourceURL)

        XCTAssertEqual(
            fixture.deletingLastPathComponent().standardizedFileURL.path,
            resourceRoot.absoluteURL.standardizedFileURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testReferenceFixtureDecodesRustCompatibleDefaultsAndDeclarativeActions() throws {
        let fixture = PluginTestSupport.fixtureManifest("valid")
        let manifest = try PluginManifestLoader().decode(data: Data(contentsOf: fixture), sourceURL: fixture)

        XCTAssertEqual(manifest.spec, "ccbud-plugin/1")
        XCTAssertEqual(manifest.id, "fixture-plugin")
        XCTAssertEqual(manifest.endpoint.protocolName, "openai-responses")
        XCTAssertEqual(manifest.source.branch, "main")
        XCTAssertEqual(manifest.models.map(\.alias), ["fixture-primary", "fixture-light"])
        XCTAssertEqual(manifest.userInterface.actions.map(\.id), ["settings", "docs"])
        XCTAssertEqual(manifest.userInterface.actions[0].submitPath, "/v1/plugin/action/settings")
        XCTAssertEqual(manifest.userInterface.actions[0].loadPath, "/v1/plugin/action/settings/load")
        XCTAssertNil(manifest.userInterface.actions[0].publicValues["submitPath"])
        XCTAssertEqual(manifest.userInterface.actions[1].requiresRunning, nil)

        let validation = PluginManifestValidator().validate(manifest)
        XCTAssertTrue(validation.isValid, validation.issues.map(\.message).joined(separator: ", "))
    }

    func testInvalidFixtureReportsTraversalProtocolAndControlPlaneFailures() throws {
        let directory = PluginTestSupport.fixture("invalid-traversal")
        let fixture = PluginTestSupport.fixtureManifest("invalid-traversal")
        let manifest = try PluginManifestLoader().decode(data: Data(contentsOf: fixture), sourceURL: fixture)
        let validation = PluginManifestValidator().validate(manifest, directory: directory)
        let paths = Set(validation.errors.map(\.path))

        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(paths.contains("id"))
        XCTAssertTrue(paths.contains("icon"))
        XCTAssertTrue(paths.contains("runtime.exec.darwin-arm64"))
        XCTAssertTrue(paths.contains("endpoint.protocol"))
        XCTAssertTrue(paths.contains("endpoint.basePath"))
        XCTAssertTrue(paths.contains("endpoint.healthPath"))
        XCTAssertTrue(paths.contains("endpoint.readyTimeoutMs"))
        XCTAssertTrue(paths.contains("auth.statusPath"))
        XCTAssertTrue(paths.contains("ui.actions[0].id"))
        XCTAssertTrue(paths.contains("ui.actions[0].kind"))
    }

    func testLegacyMissingOptionalFieldsUseFormerHostDefaults() throws {
        let data = Data(#"{"id":"legacy","runtime":{"exec":{"darwin-arm64":"legacy"}}}"#.utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.spec, PluginManifest.supportedSpec)
        XCTAssertEqual(manifest.name, "Plugin")
        XCTAssertEqual(manifest.version, "0.0.0")
        XCTAssertEqual(manifest.runtime.arguments, PluginRuntime.defaultArguments)
        XCTAssertEqual(manifest.endpoint, PluginEndpoint())
        XCTAssertEqual(manifest.authentication, PluginAuthentication())
        XCTAssertEqual(manifest.source.branch, "main")
    }

    func testSemverishComparisonMatchesFormerRustOrdering() {
        XCTAssertTrue(PluginVersion.isNewer("v0.2.0", than: "0.1.9"))
        XCTAssertTrue(PluginVersion.isNewer("1.0.1-beta", than: "1.0.0"))
        XCTAssertFalse(PluginVersion.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(PluginVersion.isNewer("0.9.9", than: "1.0.0"))
    }
}
