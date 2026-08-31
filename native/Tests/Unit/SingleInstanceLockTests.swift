import Foundation
import XCTest
@testable import CCBuddy

final class SingleInstanceLockTests: XCTestCase {
    func testSecondLockReadsPrimaryLifetimeTokenAndCanAcquireAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-single-instance-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SingleInstanceLock(url: lockURL)
        let firstAcquisition = try first.acquire()
        guard case .primary(let primaryToken) = firstAcquisition else {
            return XCTFail("The first isolated lock must be primary")
        }

        let second = SingleInstanceLock(url: lockURL)
        XCTAssertEqual(try second.acquire(), .secondary(primaryToken: primaryToken))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        first.release()
        let successor = SingleInstanceLock(url: lockURL)
        guard case .primary(let successorToken) = try successor.acquire() else {
            return XCTFail("A released lock must be acquirable")
        }
        XCTAssertNotEqual(successorToken, primaryToken)
        successor.release()
    }

    func testLegacyBundleNameMigratesAndRequestsRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bundle-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("CCBuddy.app", isDirectory: true)
        let executable = legacy.appendingPathComponent("Contents/MacOS/CCBuddy")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: executable)

        var relaunchedURL: URL?
        let result = LegacyBundleNameMigrator.migrate(executableURL: executable) { target in
            relaunchedURL = target
            return true
        }

        let target = root.appendingPathComponent("CC Buddy.app", isDirectory: true)
        XCTAssertEqual(result, .relaunched)
        XCTAssertEqual(relaunchedURL?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testLegacyBundleNameRestoresOriginalWhenRelaunchFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bundle-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("ccbud.app", isDirectory: true)
        let executable = legacy.appendingPathComponent("Contents/MacOS/ccbud")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: executable)

        let result = LegacyBundleNameMigrator.migrate(executableURL: executable) { _ in false }

        XCTAssertEqual(result, .relaunchFailed(restoredLegacyName: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("CC Buddy.app").path
        ))
    }

    func testLegacyBundleNameLeavesExistingTargetUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bundle-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("CCBuddy.app", isDirectory: true)
        let executable = legacy.appendingPathComponent("Contents/MacOS/CCBuddy")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("CC Buddy.app", isDirectory: true),
            withIntermediateDirectories: true
        )

        var relaunched = false
        let result = LegacyBundleNameMigrator.migrate(executableURL: executable) { _ in
            relaunched = true
            return true
        }

        XCTAssertEqual(result, .targetAlreadyExists)
        XCTAssertFalse(relaunched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
}
