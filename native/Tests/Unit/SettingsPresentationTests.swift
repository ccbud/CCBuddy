import XCTest
@testable import CCBuddy

final class SettingsPresentationTests: XCTestCase {
    func testFileCatalogStorageUsageCountsHardLinksOnceAndDoesNotFollowSymlinks() throws {
        let root = try HistoryTestSupport.temporaryDirectory("file-catalog-footprint")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let pack = catalog.appendingPathComponent("body.pack")
        let checkpoint = catalog.appendingPathComponent("checkpoint.bin")
        try Data([1, 2, 3, 4]).write(to: pack)
        try FileManager.default.linkItem(at: pack, to: checkpoint)
        let outside = root.appendingPathComponent("unrelated")
        try Data(repeating: 7, count: 1_024).write(to: outside)
        try FileManager.default.createSymbolicLink(at: catalog.appendingPathComponent("link"),
                                                   withDestinationURL: outside)
        XCTAssertEqual(ConversationStorageFootprint.bytes(in: [catalog, checkpoint]), 4)
        XCTAssertEqual(ConversationStorageFootprint.bytes(in: [root.appendingPathComponent("missing")]), 0)
    }

    func testDataDirectoryPickerCollapsesProducerSubdirectoriesToTheirRoot() {
        let root = URL(fileURLWithPath: "/tmp/ccbud-history-root", isDirectory: true)
        XCTAssertEqual(
            LocationsSettingsPane.historyRoot(for: root.appendingPathComponent("projects")),
            root
        )
        XCTAssertEqual(
            LocationsSettingsPane.historyRoot(for: root.appendingPathComponent("sessions")),
            root
        )
        XCTAssertEqual(LocationsSettingsPane.historyRoot(for: root), root)
    }

    func testConversationFontModesPreserveLegacyConfigurationSemantics() {
        XCTAssertEqual(ConversationFontSizeMode.resolved(from: nil), .defaultSize)
        XCTAssertEqual(ConversationFontSizeMode.resolved(from: 13), .defaultSize)
        XCTAssertEqual(ConversationFontSizeMode.resolved(from: 15), .large)
        XCTAssertEqual(ConversationFontSizeMode.resolved(from: 17), .extraLarge)
        XCTAssertEqual(ConversationFontSizeMode.resolved(from: 14), .custom)
        XCTAssertEqual(ConversationFontSizeMode.resolved(from: 24), .custom)

        XCTAssertNil(ConversationFontSizeMode.defaultSize.presetConfiguration)
        XCTAssertEqual(ConversationFontSizeMode.large.presetConfiguration, 15)
        XCTAssertEqual(ConversationFontSizeMode.extraLarge.presetConfiguration, 17)
        XCTAssertNil(ConversationFontSizeMode.custom.presetConfiguration)
    }

    func testConversationFontCustomValueUsesLegacyBounds() {
        XCTAssertEqual(ConversationFontSizeMode.normalized(nil), 13)
        XCTAssertEqual(ConversationFontSizeMode.normalized(9), 10)
        XCTAssertEqual(ConversationFontSizeMode.normalized(19), 19)
        XCTAssertEqual(ConversationFontSizeMode.normalized(25), 24)
    }

    func testAboutVersionsExposeCurrentAndLatestAcrossUpdaterStates() throws {
        let idle = AboutVersionPresentation(
            updateState: .idle(currentVersion: "2.0.0"),
            fallbackCurrentVersion: "fallback"
        )
        XCTAssertEqual(idle.current, "2.0.0")
        XCTAssertEqual(idle.latest, "—")

        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let current = AboutVersionPresentation(
            updateState: .upToDate(currentVersion: "2.0.0", checkedAt: checkedAt),
            fallbackCurrentVersion: "fallback"
        )
        XCTAssertEqual(current.current, "2.0.0")
        XCTAssertEqual(current.latest, "2.0.0")

        let release = UpdateRelease(
            version: try XCTUnwrap(UpdateSemanticVersion("2.1.0")),
            notes: nil,
            publishedAt: nil,
            artifactURL: nil,
            encodedSignature: nil,
            expectedSHA256: nil,
            releasePageURL: try XCTUnwrap(URL(string: "https://github.com/ccbud/ccbud/releases"))
        )
        let available = AboutVersionPresentation(
            updateState: .available(release),
            fallbackCurrentVersion: "2.0.0"
        )
        XCTAssertEqual(available.current, "2.0.0")
        XCTAssertEqual(available.latest, "2.1.0")
    }

    func testClaudeSettingsDisplayPathIsStableAndHonorsOverride() {
        let fileManager = FileManager.default
        XCTAssertEqual(
            GatewaySettingsPresentation.claudeSettingsDisplayPath(
                environment: ["HOME": "/Users/test"],
                fileManager: fileManager
            ),
            "~/.claude/settings.json"
        )
        XCTAssertEqual(
            GatewaySettingsPresentation.claudeSettingsDisplayPath(
                environment: [
                    "HOME": "/Users/test",
                    "CCBUD_CLAUDE_SETTINGS": "/Volumes/Fixture/claude/settings.json",
                ],
                fileManager: fileManager
            ),
            "/Volumes/Fixture/claude/settings.json"
        )
    }

    func testGatewayEndpointIsProtocolTextWithoutLocalizedDigitGrouping() {
        XCTAssertEqual(
            GatewaySettingsPresentation.endpoint(port: 8_788),
            "http://localhost:8788"
        )
    }
}
