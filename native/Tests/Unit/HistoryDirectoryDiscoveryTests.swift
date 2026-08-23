import XCTest
@testable import CCBuddy

final class HistoryDirectoryDiscoveryTests: XCTestCase {
    func testDiscoversEverySupportedRootInLegacyStartupOrder() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-all")
        defer { try? FileManager.default.removeItem(at: home) }

        let codex = home.appendingPathComponent("custom-codex", isDirectory: true)
        let xdg = home.appendingPathComponent("xdg", isDirectory: true)
        let grok = home.appendingPathComponent("custom-grok", isDirectory: true)
        try makeDirectory(codex.appendingPathComponent("sessions", isDirectory: true))
        try makeDirectory(xdg.appendingPathComponent("claude/projects", isDirectory: true))
        try makeDirectory(grok.appendingPathComponent("sessions/%2Ftmp%2Fproject", isDirectory: true))
        try makeDirectory(home.appendingPathComponent(".copilot/session-state", isDirectory: true))
        try makeDirectory(home.appendingPathComponent(
            ".gemini/antigravity-cli/conversations", isDirectory: true
        ))
        try makeDirectory(home.appendingPathComponent(".qoder/projects", isDirectory: true))
        try makeDirectory(home.appendingPathComponent(".qoderwork/projects", isDirectory: true))

        let service = HistoryDirectoryDiscovery(
            environment: [
                "HOME": home.path,
                "CODEX_HOME": codex.path,
                "XDG_CONFIG_HOME": xdg.path,
                "GROK_HOME": grok.path,
            ],
            homeDirectory: home
        )
        let result = service.discover(in: AppConfig())

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.config.historyDirs, [
            "~/.claude",
            "~/custom-codex",
            "~/xdg/claude",
            "~/custom-grok",
            "~/.copilot",
            "~/.gemini/antigravity-cli",
            "~/.qoder",
            "~/.qoderwork",
        ])
        XCTAssertEqual(result.addedDirectories, Array(result.config.historyDirs.dropFirst()))
        for flag in HistoryDirectoryDiscovery.migrationFlags {
            XCTAssertEqual(result.config.additionalProperties[flag], .bool(true), flag)
        }
    }

    func testMissingMarkersStayUnflaggedAndAreDetectedOnALaterLaunch() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-retry")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path],
            homeDirectory: home
        )

        let first = service.discover(in: AppConfig())
        XCTAssertFalse(first.didChange)
        XCTAssertTrue(first.addedDirectories.isEmpty)
        for flag in HistoryDirectoryDiscovery.migrationFlags {
            XCTAssertNil(first.config.additionalProperties[flag], flag)
        }

        try makeDirectory(home.appendingPathComponent(".codex/sessions", isDirectory: true))
        try makeDirectory(home.appendingPathComponent(".qoder/projects", isDirectory: true))
        let second = service.discover(in: first.config)

        XCTAssertTrue(second.didChange)
        XCTAssertEqual(second.addedDirectories, ["~/.codex", "~/.qoder"])
        XCTAssertEqual(second.config.additionalProperties["codexDirAutoAdded"], .bool(true))
        XCTAssertEqual(second.config.additionalProperties["qoderDirAutoAdded"], .bool(true))
        XCTAssertNil(second.config.additionalProperties["qoderworkDirAutoAdded"])
        XCTAssertNil(second.config.additionalProperties["copilotDirAutoAdded"])
    }

    func testQoderAndQoderWorkCompleteIndependentlyAcrossLaunches() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-qoder-retry")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path],
            homeDirectory: home
        )

        try makeDirectory(home.appendingPathComponent(".qoder/projects", isDirectory: true))
        let first = service.discover(in: AppConfig())

        XCTAssertEqual(first.addedDirectories, ["~/.qoder"])
        XCTAssertEqual(first.config.additionalProperties["qoderDirAutoAdded"], .bool(true))
        XCTAssertNil(first.config.additionalProperties["qoderworkDirAutoAdded"])

        try makeDirectory(home.appendingPathComponent(".qoderwork/projects", isDirectory: true))
        let second = service.discover(in: first.config)

        XCTAssertTrue(second.didChange)
        XCTAssertEqual(second.addedDirectories, ["~/.qoderwork"])
        XCTAssertEqual(second.config.historyDirs, ["~/.claude", "~/.qoder", "~/.qoderwork"])
        XCTAssertEqual(second.config.additionalProperties["qoderDirAutoAdded"], .bool(true))
        XCTAssertEqual(second.config.additionalProperties["qoderworkDirAutoAdded"], .bool(true))
    }

    func testCompletedFlagRespectsAUserRemovingTheDirectory() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-removal")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDirectory(home.appendingPathComponent(".codex/sessions", isDirectory: true))
        let service = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path],
            homeDirectory: home
        )

        let first = service.discover(in: AppConfig())
        XCTAssertEqual(first.addedDirectories, ["~/.codex"])
        var userEdited = first.config
        userEdited.historyDirs.removeAll { $0 == "~/.codex" }

        let second = service.discover(in: userEdited)
        XCTAssertFalse(second.didChange)
        XCTAssertFalse(second.config.historyDirs.contains("~/.codex"))
        XCTAssertEqual(second.config.additionalProperties["codexDirAutoAdded"], .bool(true))
    }

    func testExistingEquivalentDirectoryOnlyCompletesTheFlag() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-dedup")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDirectory(home.appendingPathComponent(".copilot/session-state", isDirectory: true))
        var config = AppConfig()
        config.historyDirs.append(home.appendingPathComponent(".copilot").path + "/")
        config.additionalProperties["copilotDirAutoAdded"] = .string("true")

        let result = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path],
            homeDirectory: home
        ).discover(in: config)

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.addedDirectories.isEmpty)
        XCTAssertEqual(result.config.historyDirs, ["~/.claude", "~/.copilot"])
        XCTAssertEqual(result.config.additionalProperties["copilotDirAutoAdded"], .bool(true))
    }

    func testBlankOverridesFallBackAndGrokRequiresAnEncodedWorkspaceDirectory() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-defaults")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDirectory(home.appendingPathComponent(".codex/sessions", isDirectory: true))
        try makeDirectory(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        try makeDirectory(home.appendingPathComponent(".grok/sessions/plain-workspace", isDirectory: true))
        let service = HistoryDirectoryDiscovery(
            environment: [
                "HOME": home.path,
                "CODEX_HOME": "  ",
                "XDG_CONFIG_HOME": "\t",
                "GROK_HOME": "",
            ],
            homeDirectory: home
        )

        let first = service.discover(in: AppConfig())
        XCTAssertEqual(first.addedDirectories, ["~/.codex", "~/.config/claude"])
        XCTAssertNil(first.config.additionalProperties["grokDirAutoAdded"])

        try makeDirectory(home.appendingPathComponent(
            ".grok/sessions/%3A%5CUsers%5Cfixture", isDirectory: true
        ))
        let second = service.discover(in: first.config)
        XCTAssertEqual(second.addedDirectories, ["~/.grok"])
        XCTAssertEqual(second.config.additionalProperties["grokDirAutoAdded"], .bool(true))
    }

    func testEnvironmentRootsOutsideHomeRemainAbsolute() throws {
        let container = try HistoryTestSupport.temporaryDirectory("directory-discovery-external")
        defer { try? FileManager.default.removeItem(at: container) }
        let home = container.appendingPathComponent("home", isDirectory: true)
        let codex = container.appendingPathComponent("codex", isDirectory: true)
        let xdg = container.appendingPathComponent("xdg", isDirectory: true)
        let grok = container.appendingPathComponent("grok", isDirectory: true)
        try makeDirectory(home)
        try makeDirectory(codex.appendingPathComponent("sessions", isDirectory: true))
        try makeDirectory(xdg.appendingPathComponent("claude/projects", isDirectory: true))
        try makeDirectory(grok.appendingPathComponent("sessions/%2fexternal", isDirectory: true))

        let result = HistoryDirectoryDiscovery(
            environment: [
                "HOME": home.path,
                "CODEX_HOME": codex.path,
                "XDG_CONFIG_HOME": xdg.path,
                "GROK_HOME": grok.path,
            ],
            homeDirectory: home
        ).discover(in: AppConfig())

        XCTAssertEqual(result.addedDirectories, [
            codex.path,
            xdg.appendingPathComponent("claude").path,
            grok.path,
        ])
    }

    func testRetiredCodexSelectionMapsToAlreadyConfiguredEnvironmentRoot() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-codex-configured")
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent("custom-codex", isDirectory: true)
        var config = AppConfig()
        config.historyDirs.append("~/custom-codex")
        config.historyActive = "__codex__"
        config.additionalProperties["codexDirAutoAdded"] = .bool(true)

        let result = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path, "CODEX_HOME": codex.path],
            homeDirectory: home
        ).discover(in: config)

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.addedDirectories.isEmpty)
        XCTAssertEqual(result.config.historyActive, "~/custom-codex")
    }

    func testRetiredCodexSelectionMapsToRootDiscoveredDuringSameMigration() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-codex-active")
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent("custom-codex", isDirectory: true)
        try makeDirectory(codex.appendingPathComponent("sessions", isDirectory: true))
        var config = AppConfig()
        config.historyActive = "__codex__"

        let result = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path, "CODEX_HOME": codex.path],
            homeDirectory: home
        ).discover(in: config)

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.addedDirectories, ["~/custom-codex"])
        XCTAssertEqual(result.config.historyActive, "~/custom-codex")
        XCTAssertEqual(result.config.additionalProperties["codexDirAutoAdded"], .bool(true))
    }

    func testRetiredCodexSelectionFallsBackToAllWhenRootIsUnavailable() throws {
        let home = try HistoryTestSupport.temporaryDirectory("directory-discovery-codex-missing")
        defer { try? FileManager.default.removeItem(at: home) }
        var config = AppConfig()
        config.historyActive = "__codex__"

        let result = HistoryDirectoryDiscovery(
            environment: ["HOME": home.path],
            homeDirectory: home
        ).discover(in: config)

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.addedDirectories.isEmpty)
        XCTAssertEqual(result.config.historyActive, "all")
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
