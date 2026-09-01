import Foundation
import XCTest
@testable import CCBuddy

final class SkillsSafetyTests: XCTestCase {
    func testOperationLockRejectsSymlinkWithoutTouchingDestination() async throws {
        let layout = try SkillsTestLayout(label: "operation-lock-link")
        defer { layout.remove() }
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let outside = layout.sandbox.appendingPathComponent("outside-lock")
        try Data("keep".utf8).write(to: outside)
        let lock = layout.root.appendingPathComponent(".ccbud-operation.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)

        do {
            _ = try await layout.service().snapshot()
            XCTFail("A symbolic-link operation lock must be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("operation lock"))
        }
        XCTAssertEqual(try SkillPathSafety.entryKind(at: lock), .symlink)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testIndexSaveRejectsAbnormalReservedEntriesWithoutDeletingThem() throws {
        let layout = try SkillsTestLayout(label: "index-reserved")
        defer { layout.remove() }
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let repository = SkillsIndexRepository(fileManager: .default, beforeCommit: {})
        let legacyTemporary = layout.root.appendingPathComponent(".ccbud-index.tmp")
        try FileManager.default.createDirectory(at: legacyTemporary, withIntermediateDirectories: false)
        let marker = legacyTemporary.appendingPathComponent("user.txt")
        try Data("keep directory".utf8).write(to: marker)

        XCTAssertThrowsError(try repository.save(root: layout.root, document: SkillIndexDocument()))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep directory")

        try FileManager.default.removeItem(at: legacyTemporary)
        let outside = layout.sandbox.appendingPathComponent("outside-backup")
        try Data("keep symlink destination".utf8).write(to: outside)
        let backup = layout.root.appendingPathComponent(".ccbud-index.bak")
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)

        XCTAssertThrowsError(try repository.save(root: layout.root, document: SkillIndexDocument()))
        XCTAssertEqual(try SkillPathSafety.entryKind(at: backup), .symlink)
        XCTAssertEqual(
            try String(contentsOf: outside, encoding: .utf8),
            "keep symlink destination"
        )
    }

    func testCentralSymlinkIsInvalidAndUpdateNeverFollowsIt() async throws {
        let layout = try SkillsTestLayout(label: "central-link")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        let outside = layout.sandbox.appendingPathComponent("outside", isDirectory: true)
        try makeTestSkill(at: source, value: "before")
        try makeTestSkill(at: outside, value: "outside")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let central = layout.root.appendingPathComponent(skill.id)
        try FileManager.default.removeItem(at: central)
        try FileManager.default.createSymbolicLink(at: central, withDestinationURL: outside)

        let invalid = try await service.snapshot().skills.first
        XCTAssertEqual(invalid?.status, "invalid")
        XCTAssertEqual(invalid?.name, skill.id)
        try makeTestSkill(at: source, value: "after")
        _ = try await service.update(id: skill.id)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: central), .directory)
        XCTAssertEqual(try testSkillValue(at: central), "after")
        XCTAssertEqual(try testSkillValue(at: outside), "outside")
    }

    func testIndexBackupRecoveryAndUnsafeRecordedTargetRefusal() async throws {
        let layout = try SkillsTestLayout(label: "index-safety")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        let outside = layout.sandbox.appendingPathComponent("outside", isDirectory: true)
        try makeTestSkill(at: source, value: "source")
        try makeTestSkill(at: outside, value: "outside")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let indexURL = layout.root.appendingPathComponent(".ccbud-index.json")
        let backupURL = layout.root.appendingPathComponent(".ccbud-index.bak")
        try FileManager.default.moveItem(at: indexURL, to: backupURL)
        let recovered = try await service.snapshot()
        XCTAssertEqual(recovered.skills.map(\.id), [skill.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        let repository = SkillsIndexRepository(fileManager: .default, beforeCommit: {})
        var document = try repository.load(root: layout.root)
        document.skills[skill.id]?.targets = [SkillTarget(
            key: "amp",
            path: outside,
            syncMode: .copy
        )]
        try repository.save(root: layout.root, document: document)
        do {
            _ = try await service.remove(id: skill.id)
            XCTFail("Unsafe recorded paths must be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("unsafe recorded target"))
        }
        XCTAssertEqual(try testSkillValue(at: outside), "outside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(skill.id).path))
    }

    func testOversizedPreviewAndInvalidLocalUpdateMetadataAreRejected() async throws {
        let layout = try SkillsTestLayout(label: "preview")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "source")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let oversized = layout.root.appendingPathComponent("\(skill.id)/large.txt")
        try Data(repeating: 0x61, count: 4 * 1_024 * 1_024 + 1).write(to: oversized)
        do {
            _ = try await service.readFile(id: skill.id, path: "large.txt")
            XCTFail("Oversized previews must be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("too large"))
        }

        let repository = SkillsIndexRepository(fileManager: .default, beforeCommit: {})
        var document = try repository.load(root: layout.root)
        document.skills[skill.id]?.sourceReference = "relative/source"
        try repository.save(root: layout.root, document: document)
        do {
            _ = try await service.update(id: skill.id)
            XCTFail("Relative local metadata must be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("absolute"))
        }
    }

    func testModifiedManagedCopyIsPreservedByEveryDestructiveOperation() async throws {
        let layout = try SkillsTestLayout(label: "copy-ownership")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Owned Copy", value: "before")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["amp"], mode: .copy)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try Data("user replacement".utf8).write(to: target.appendingPathComponent("value.txt"))

        do {
            _ = try await service.sync(id: skill.id, toolKeys: ["amp"], mode: .copy)
            XCTFail("Sync must not replace a modified managed copy")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "user replacement")

        do {
            _ = try await service.unsync(id: skill.id, toolKeys: ["amp"])
            XCTFail("Unsync must not remove a modified managed copy")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "user replacement")

        try makeTestSkill(at: source, name: "Owned Copy", value: "after")
        let updated = try await service.update(id: skill.id)
        XCTAssertEqual(updated.status, "sync_error")
        XCTAssertEqual(updated.targets.first?.status, "error")
        XCTAssertEqual(try testSkillValue(at: layout.root.appendingPathComponent(skill.id)), "after")
        XCTAssertEqual(try testSkillValue(at: target), "user replacement")

        do {
            _ = try await service.remove(id: skill.id)
            XCTFail("Delete must not remove a modified managed copy")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside"))
        }
        XCTAssertEqual(try testSkillValue(at: layout.root.appendingPathComponent(skill.id)), "after")
        XCTAssertEqual(try testSkillValue(at: target), "user replacement")
    }

    func testSameContentCopyReplacementAndRedirectedSymlinkArePreserved() async throws {
        let layout = try SkillsTestLayout(label: "replacement-ownership")
        defer { layout.remove() }
        let copySource = layout.sandbox.appendingPathComponent("copy-source", isDirectory: true)
        let linkSource = layout.sandbox.appendingPathComponent("link-source", isDirectory: true)
        let outside = layout.sandbox.appendingPathComponent("outside", isDirectory: true)
        try makeTestSkill(at: copySource, name: "Copy Identity", value: "same")
        try makeTestSkill(at: linkSource, name: "Link Identity", value: "managed")
        try makeTestSkill(at: outside, name: "Outside", value: "outside")
        let service = layout.service()

        let copy = try await service.importLocal(from: copySource)
        _ = try await service.sync(id: copy.id, toolKeys: ["cursor"], mode: .copy)
        let copyTarget = layout.home.appendingPathComponent(".cursor/skills/\(copy.id)")
        try FileManager.default.removeItem(at: copyTarget)
        try makeTestSkill(at: copyTarget, name: "Copy Identity", value: "same")
        do {
            _ = try await service.unsync(id: copy.id, toolKeys: ["cursor"])
            XCTFail("An inode-replaced copy must not be removed even when its contents match")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside"))
        }
        XCTAssertEqual(try testSkillValue(at: copyTarget), "same")

        let linked = try await service.importLocal(from: linkSource)
        _ = try await service.sync(id: linked.id, toolKeys: ["amp"], mode: .symlink)
        let linkTarget = layout.home.appendingPathComponent(".config/agents/skills/\(linked.id)")
        try FileManager.default.removeItem(at: linkTarget)
        try FileManager.default.createSymbolicLink(at: linkTarget, withDestinationURL: outside)
        do {
            _ = try await service.remove(id: linked.id)
            XCTFail("A redirected symbolic link must not be removed")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside"))
        }
        XCTAssertEqual(try SkillPathSafety.entryKind(at: linkTarget), .symlink)
        XCTAssertEqual(try testSkillValue(at: outside), "outside")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.root.appendingPathComponent(linked.id).path
        ))
    }

    func testLegacyV1TargetWithoutOwnershipProofCanStillUnsyncWhenContentMatches() async throws {
        let layout = try SkillsTestLayout(label: "legacy-proof")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Legacy", value: "same")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["amp"], mode: .copy)

        let repository = SkillsIndexRepository(fileManager: .default, beforeCommit: {})
        var document = try repository.load(root: layout.root)
        document.skills[skill.id]?.targets[0].managedIdentity = nil
        document.skills[skill.id]?.targets[0].managedDigest = nil
        try repository.save(root: layout.root, document: document)

        let unsynced = try await service.unsync(id: skill.id, toolKeys: ["amp"])
        XCTAssertTrue(unsynced.targets.isEmpty)
        XCTAssertEqual(
            try SkillPathSafety.entryKind(
                at: layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
            ),
            .missing
        )
    }

    func testRawLegacyV1IndexFixtureLoadsAndUnsyncsWithoutOwnershipFields() async throws {
        let layout = try SkillsTestLayout(label: "legacy-v1-json")
        defer { layout.remove() }
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let central = layout.root.appendingPathComponent("legacy", isDirectory: true)
        let target = layout.home.appendingPathComponent(
            ".config/agents/skills/legacy",
            isDirectory: true
        )
        try makeTestSkill(at: central, name: "Legacy Fixture", value: "same")
        try makeTestSkill(at: target, name: "Legacy Fixture", value: "same")
        let escapedPath = target.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let fixture = """
        {
          "version": 1,
          "skills": {
            "legacy": {
              "source_type": "local",
              "source_ref": "/legacy/source",
              "source_subdir": "",
              "source_revision": null,
              "updated_at": 123,
              "tags": ["legacy"],
              "targets": [{
                "key": "amp",
                "path": "\(escapedPath)",
                "sync_mode": "copy",
                "status": "ok"
              }],
              "status": "ok"
            }
          }
        }
        """
        try Data(fixture.utf8).write(to: layout.root.appendingPathComponent(".ccbud-index.json"))

        let loaded = try SkillsIndexRepository(fileManager: .default, beforeCommit: {})
            .load(root: layout.root)
        XCTAssertEqual(loaded.version, 1)
        XCTAssertNil(loaded.skills["legacy"]?.targets.first?.managedIdentity)
        XCTAssertNil(loaded.skills["legacy"]?.targets.first?.managedDigest)

        let unsynced = try await layout.service().unsync(id: "legacy", toolKeys: ["amp"])
        XCTAssertTrue(unsynced.targets.isEmpty)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: target), .missing)
    }

    func testSnapshotPersistsRetiredTargetMetadataRemovalWithoutTouchingPhysicalPath() async throws {
        let layout = try SkillsTestLayout(label: "retired-snapshot")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Retired Snapshot", value: "managed")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let orphan = layout.home.appendingPathComponent(
            ".retired/skills/\(skill.id)",
            isDirectory: true
        )
        try makeTestSkill(at: orphan, name: "Retired Physical", value: "keep")
        try recordRetiredTarget(skillID: skill.id, path: orphan, root: layout.root)

        let snapshot = try await service.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.skills.first).targets.isEmpty)
        let persisted = try SkillsIndexRepository(fileManager: .default, beforeCommit: {})
            .load(root: layout.root)
        XCTAssertTrue(try XCTUnwrap(persisted.skills[skill.id]).targets.isEmpty)
        XCTAssertEqual(try testSkillValue(at: orphan), "keep")
    }

    func testUpdateAndDeleteReconcileRetiredTargetsWithoutTouchingPhysicalPath() async throws {
        let layout = try SkillsTestLayout(label: "retired-mutations")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Retired Mutation", value: "before")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let orphan = layout.home.appendingPathComponent(
            ".retired/skills/\(skill.id)",
            isDirectory: true
        )
        try makeTestSkill(at: orphan, name: "Retired Physical", value: "keep")
        try recordRetiredTarget(skillID: skill.id, path: orphan, root: layout.root)
        try makeTestSkill(at: source, name: "Retired Mutation", value: "after")

        let updated = try await service.update(id: skill.id)
        XCTAssertTrue(updated.targets.isEmpty)
        XCTAssertEqual(try testSkillValue(at: updated.path), "after")
        XCTAssertEqual(try testSkillValue(at: orphan), "keep")

        try recordRetiredTarget(skillID: skill.id, path: orphan, root: layout.root)
        let removed = try await service.remove(id: skill.id)
        XCTAssertTrue(removed)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: updated.path), .missing)
        XCTAssertEqual(try testSkillValue(at: orphan), "keep")
    }

    private func recordRetiredTarget(skillID: String, path: URL, root: URL) throws {
        let repository = SkillsIndexRepository(fileManager: .default, beforeCommit: {})
        var document = try repository.load(root: root)
        var entry = try XCTUnwrap(document.skills[skillID])
        entry.targets = [SkillTarget(
            key: "retired_tool",
            path: path,
            syncMode: .copy
        )]
        document.skills[skillID] = entry
        try repository.save(root: root, document: document)
    }
}
