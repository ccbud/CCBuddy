import XCTest

@testable import CCBuddy

/// Switching a session location off has to keep it configured while removing it from everything
/// that scans, lists or searches — that difference is the whole point of the control, and it is
/// easy to implement as a removal by accident.
final class HistoryLocationToggleTests: XCTestCase {
    private func config(dirs: [String], disabled: [String] = []) -> AppConfig {
        var value = AppConfig()
        value.historyDirs = dirs
        value.disabledHistoryDirs = disabled
        return value
    }

    func testDisabledLocationsAreExcludedFromTheScanSetButStayConfigured() {
        let value = config(dirs: ["~/.claude", "~/.codex", "~/.grok"], disabled: ["~/.codex"])
        XCTAssertEqual(value.enabledHistoryDirs, ["~/.claude", "~/.grok"])
        XCTAssertEqual(value.historyDirs, ["~/.claude", "~/.codex", "~/.grok"])
        XCTAssertFalse(value.isHistoryDirectoryEnabled("~/.codex"))
        XCTAssertTrue(value.isHistoryDirectoryEnabled("~/.claude"))
    }

    func testEnabledOrderFollowsTheConfiguredOrder() {
        let value = config(dirs: ["~/a", "~/b", "~/c"], disabled: ["~/b"])
        XCTAssertEqual(value.enabledHistoryDirs, ["~/a", "~/c"])
    }

    func testNormalizeDropsDisabledEntriesForLocationsThatNoLongerExist() {
        var value = config(dirs: ["~/.claude"], disabled: ["~/.codex", "~/.claude"])
        value.normalize()
        XCTAssertEqual(value.disabledHistoryDirs, ["~/.claude"])
    }

    func testNormalizeDeduplicatesTheDisabledList() {
        var value = config(dirs: ["~/.claude", "~/.codex"], disabled: ["~/.codex", "~/.codex"])
        value.normalize()
        XCTAssertEqual(value.disabledHistoryDirs, ["~/.codex"])
    }

    func testEveryLocationMayBeSwitchedOff() {
        // Wake lets you silence any location, including the default one; an empty library is a
        // legitimate state, not something to guard against.
        var value = config(dirs: ["~/.claude"], disabled: ["~/.claude"])
        value.normalize()
        XCTAssertEqual(value.disabledHistoryDirs, ["~/.claude"])
        XCTAssertTrue(value.enabledHistoryDirs.isEmpty)
    }

    func testDisabledListSurvivesAConfigurationRoundTrip() throws {
        var value = config(dirs: ["~/.claude", "~/.codex"], disabled: ["~/.codex"])
        value.normalize()

        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(restored.disabledHistoryDirs, ["~/.codex"])
        XCTAssertEqual(restored.enabledHistoryDirs, ["~/.claude"])
    }

    func testConfigurationsWrittenBeforeTheFeatureDecodeWithEveryLocationEnabled() throws {
        let legacy = #"{"historyDirs":["~/.claude","~/.codex"]}"#
        let restored = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(restored.disabledHistoryDirs.isEmpty)
        XCTAssertEqual(restored.enabledHistoryDirs, ["~/.claude", "~/.codex"])
    }

    func testTheCatalogSignatureChangesWhenALocationIsSwitchedOff() {
        // The store rebuilds its scoping from this signature, so it has to notice the change; if it
        // did not, a switched-off location would keep being scanned until the next relaunch.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let imports = home.appendingPathComponent(".ccbud/imports", isDirectory: true)
        func signature(_ dirs: [String]) -> String {
            IndexedHistoryRepository.topologySignature(
                historyDirs: dirs,
                homeDirectory: home,
                importsRoot: imports
            )
        }
        let all = config(dirs: ["~/.claude", "~/.codex"])
        let some = config(dirs: ["~/.claude", "~/.codex"], disabled: ["~/.codex"])
        XCTAssertNotEqual(
            signature(all.enabledHistoryDirs),
            signature(some.enabledHistoryDirs)
        )
    }
}
