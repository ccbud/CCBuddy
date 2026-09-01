import Foundation
import XCTest
@testable import CCBuddy

final class SkillsTransactionTests: XCTestCase {
    func testUpdateIndexFailureRestoresTargetsAndCentral() async throws {
        let fixture = try makeFixture(label: "update")
        defer { fixture.layout.remove() }
        let skill = try await fixture.service.importLocal(from: fixture.source)
        _ = try await fixture.service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let target = fixture.layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        try makeTestSkill(at: fixture.source, value: "after")

        fixture.gate.arm()
        do {
            _ = try await fixture.service.update(id: skill.id)
            XCTFail("Injected index failure should fail update")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("Injected"))
        }
        XCTAssertEqual(try testSkillValue(at: fixture.layout.root.appendingPathComponent(skill.id)), "before")
        XCTAssertEqual(try testSkillValue(at: target), "before")
        let restored = try await fixture.service.snapshot()
        XCTAssertEqual(restored.skills.first?.targets.count, 1)
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: fixture.layout.root))
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testUpdateRollbackPreservesReplacementCreatedDuringIndexFailure() async throws {
        let layout = try SkillsTestLayout(label: "rollback-replacement")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Rollback Ownership", value: "before")
        let gate = SkillsIndexMutationFailureGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let central = layout.root.appendingPathComponent(skill.id)
        let target = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        try makeTestSkill(at: source, name: "Rollback Ownership", value: "after")
        gate.arm {
            try FileManager.default.removeItem(at: target)
            try makeTestSkill(
                at: target,
                name: "User Replacement",
                value: "user replacement"
            )
        }

        do {
            _ = try await service.update(id: skill.id)
            XCTFail("Injected index failure should fail update")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("rollback failed"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "user replacement")
        XCTAssertEqual(try testSkillValue(at: central), "before")
    }

    func testUpdateRollbackPreservesInPlaceEditCreatedDuringIndexFailure() async throws {
        let layout = try SkillsTestLayout(label: "rollback-in-place")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Rollback Digest", value: "before")
        let gate = SkillsIndexMutationFailureGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let central = layout.root.appendingPathComponent(skill.id)
        let target = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        try makeTestSkill(at: source, name: "Rollback Digest", value: "after")
        gate.arm {
            try Data("user in-place edit".utf8).write(
                to: target.appendingPathComponent("value.txt")
            )
        }

        do {
            _ = try await service.update(id: skill.id)
            XCTFail("Injected index failure should fail update")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("rollback failed"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "user in-place edit")
        XCTAssertEqual(try testSkillValue(at: central), "before")
    }

    func testMissingCentralUpdateRollsBackThenRecovers() async throws {
        let fixture = try makeFixture(label: "missing")
        defer { fixture.layout.remove() }
        let skill = try await fixture.service.importLocal(from: fixture.source)
        _ = try await fixture.service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let central = fixture.layout.root.appendingPathComponent(skill.id)
        let target = fixture.layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        try FileManager.default.removeItem(at: central)
        try makeTestSkill(at: fixture.source, value: "after")

        fixture.gate.arm()
        do {
            _ = try await fixture.service.update(id: skill.id)
            XCTFail("Injected failure should roll back a newly created central copy")
        } catch {}
        XCTAssertEqual(try SkillPathSafety.entryKind(at: central), .missing)
        XCTAssertEqual(try testSkillValue(at: target), "before")

        _ = try await fixture.service.update(id: skill.id)
        XCTAssertEqual(try testSkillValue(at: central), "after")
        XCTAssertEqual(try testSkillValue(at: target), "after")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: fixture.layout.root))
    }

    func testUnsyncIndexFailureRestoresBothPhysicalTargetsThenCommits() async throws {
        let fixture = try makeFixture(label: "unsync")
        defer { fixture.layout.remove() }
        let skill = try await fixture.service.importLocal(from: fixture.source)
        _ = try await fixture.service.sync(
            id: skill.id,
            toolKeys: ["cursor", "amp"],
            mode: .copy
        )
        let cursor = fixture.layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        let amp = fixture.layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")

        fixture.gate.arm()
        do {
            _ = try await fixture.service.unsync(id: skill.id, toolKeys: ["cursor", "amp"])
            XCTFail("Injected failure should fail unsync")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursor.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: amp.path))
        let restored = try await fixture.service.snapshot()
        XCTAssertEqual(restored.skills.first?.targets.count, 2)

        _ = try await fixture.service.unsync(id: skill.id, toolKeys: ["cursor", "amp"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursor.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: amp.path))
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: cursor.deletingLastPathComponent()))
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: amp.deletingLastPathComponent()))
    }

    func testDeleteIndexFailureRestoresCentralAndTargetThenCommits() async throws {
        let fixture = try makeFixture(label: "delete")
        defer { fixture.layout.remove() }
        let skill = try await fixture.service.importLocal(from: fixture.source)
        _ = try await fixture.service.sync(id: skill.id, toolKeys: ["amp"], mode: .copy)
        let central = fixture.layout.root.appendingPathComponent(skill.id)
        let target = fixture.layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")

        fixture.gate.arm()
        do {
            _ = try await fixture.service.remove(id: skill.id)
            XCTFail("Injected failure should fail delete")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: central.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let restored = try await fixture.service.snapshot()
        XCTAssertEqual(restored.skills.map(\.id), [skill.id])

        let removed = try await fixture.service.remove(id: skill.id)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: central.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let empty = try await fixture.service.snapshot()
        XCTAssertTrue(empty.skills.isEmpty)
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: fixture.layout.root))
    }

    func testSyncPreservesManagedTargetReplacedAfterOwnershipProof() async throws {
        let layout = try SkillsTestLayout(label: "sync-proof-replacement")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsBeforeFileMoveMutationGate()
        let service = layout.service(beforeFileMove: { try gate.beforeMove(target: $0) })
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let target = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        gate.arm(target: target) {
            try FileManager.default.removeItem(at: target)
            try makeTestSkill(at: target, name: "User Replacement", value: "keep replacement")
        }

        do {
            _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
            XCTFail("A target replaced after ownership proof must reject sync")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside CC Buddy"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "keep replacement")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testSyncPreservesTargetCreatedAfterMissingOwnershipProof() async throws {
        let layout = try SkillsTestLayout(label: "sync-proof-missing")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsBeforeFileMoveMutationGate()
        let service = layout.service(beforeFileMove: { try gate.beforeMove(target: $0) })
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["amp"], mode: .symlink)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.removeItem(at: target)
        gate.arm(target: target) {
            try Data("keep creation".utf8).write(to: target)
        }

        do {
            _ = try await service.sync(id: skill.id, toolKeys: ["amp"], mode: .symlink)
            XCTFail("A target created after a missing proof must reject sync")
        } catch let error as SkillSyncConfirmationRequired {
            let conflict = try XCTUnwrap(error.conflicts.first)
            XCTAssertEqual(error.conflicts.count, 1)
            XCTAssertEqual(conflict.path.standardizedFileURL, target.standardizedFileURL)
            XCTAssertEqual(conflict.toolKeys, ["amp"])
        } catch {
            XCTFail("Expected a typed conflict, got: \(skillErrorMessage(error))")
        }
        XCTAssertEqual(try SkillPathSafety.entryKind(at: target), .file)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep creation")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testNewConflictDuringLaterStageRollsBackEarlierTargetBeforeConfirmation() async throws {
        let layout = try SkillsTestLayout(label: "sync-proof-later-target")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsBeforeFileMoveMutationGate()
        let service = layout.service(beforeFileMove: { try gate.beforeMove(target: $0) })
        let skill = try await service.importLocal(from: source)
        let cursor = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        let amp = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try makeTestSkill(
            at: cursor,
            name: "Earlier User Target",
            value: "keep earlier target"
        )
        let initialConflicts = try await service.syncConflicts(
            id: skill.id,
            toolKeys: ["cursor", "amp"]
        )
        XCTAssertEqual(initialConflicts.count, 1)
        XCTAssertEqual(initialConflicts.first?.path.standardizedFileURL, cursor.standardizedFileURL)
        gate.arm(target: amp) {
            try makeTestSkill(at: amp, name: "User Creation", value: "keep later creation")
        }

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["cursor", "amp"],
                mode: .copy,
                authorizing: initialConflicts
            )
            XCTFail("A target created during staging must require confirmation")
        } catch let error as SkillSyncConfirmationRequired {
            XCTAssertEqual(error.conflicts.count, 2)
            let conflictsByPath = Dictionary(uniqueKeysWithValues: error.conflicts.map {
                ($0.path.standardizedFileURL, $0.toolKeys)
            })
            XCTAssertEqual(conflictsByPath[cursor.standardizedFileURL], ["cursor"])
            XCTAssertEqual(conflictsByPath[amp.standardizedFileURL], ["amp"])
        } catch {
            XCTFail("Expected a typed conflict, got: \(skillErrorMessage(error))")
        }

        XCTAssertEqual(try testSkillValue(at: cursor), "keep earlier target")
        XCTAssertEqual(try testSkillValue(at: amp), "keep later creation")
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.skills.first?.targets.isEmpty == true)
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: cursor.deletingLastPathComponent()))
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: amp.deletingLastPathComponent()))
    }

    func testAuthorizedSyncIndexFailureRestoresUnmanagedTargetAndIndex() async throws {
        let layout = try SkillsTestLayout(label: "authorized-sync-rollback")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsIndexFailureGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let userFile = target.appendingPathComponent("user.txt")
        try Data("preserve me".utf8).write(to: userFile)
        let originalIdentity = try SkillPathSafety.entryIdentity(at: target)
        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        let index = layout.root.appendingPathComponent(".ccbud-index.json")
        let indexBeforeSync = try Data(contentsOf: index)

        gate.arm()
        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["amp"],
                mode: .copy,
                authorizing: conflicts
            )
            XCTFail("Injected index failure should roll back an authorized replacement")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("Injected"))
        }

        XCTAssertEqual(try SkillPathSafety.entryKind(at: target), .directory)
        XCTAssertEqual(try SkillPathSafety.entryIdentity(at: target), originalIdentity)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "preserve me")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: target.appendingPathComponent("SKILL.md")), .missing)
        XCTAssertEqual(try Data(contentsOf: index), indexBeforeSync)
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.skills.first?.targets.isEmpty == true)
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testAuthorizedSyncPreservesInPlaceEditMadeImmediatelyBeforeMove() async throws {
        let layout = try SkillsTestLayout(label: "authorized-sync-race")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsBeforeFileMoveMutationGate()
        let service = layout.service(beforeFileMove: { try gate.beforeMove(target: $0) })
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let userFile = target.appendingPathComponent("user.txt")
        try Data("before".utf8).write(to: userFile)
        let targetIdentity = try SkillPathSafety.entryIdentity(at: target)
        let fileIdentity = try SkillPathSafety.entryIdentity(at: userFile)
        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        gate.arm(target: target) {
            try Data("after".utf8).write(to: userFile)
        }

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["amp"],
                mode: .copy,
                authorizing: conflicts
            )
            XCTFail("An in-place edit after authorization must prevent replacement")
        } catch let error as SkillSyncConfirmationRequired {
            let conflict = try XCTUnwrap(error.conflicts.first)
            XCTAssertEqual(error.conflicts.count, 1)
            XCTAssertEqual(conflict.path.standardizedFileURL, target.standardizedFileURL)
            XCTAssertNotEqual(conflict.fingerprintToken, conflicts.first?.fingerprintToken)
        } catch {
            XCTFail("Expected a refreshed typed conflict, got: \(skillErrorMessage(error))")
        }

        XCTAssertEqual(try SkillPathSafety.entryIdentity(at: target), targetIdentity)
        XCTAssertEqual(try SkillPathSafety.entryIdentity(at: userFile), fileIdentity)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "after")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: target.appendingPathComponent("SKILL.md")), .missing)
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.skills.first?.targets.isEmpty == true)
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testCommitValidationRestoresIndexAndPreservesInPlaceTargetEdit() async throws {
        let layout = try SkillsTestLayout(label: "commit-in-place-edit")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsIndexMutationGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("original unmanaged".utf8).write(to: target.appendingPathComponent("user.txt"))
        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        let index = layout.root.appendingPathComponent(".ccbud-index.json")
        let indexBeforeSync = try Data(contentsOf: index)
        gate.arm {
            try Data("external edit".utf8).write(to: target.appendingPathComponent("value.txt"))
        }

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["amp"],
                mode: .copy,
                authorizing: conflicts
            )
            XCTFail("A target edit before file commit must reject the transaction")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("commit"))
        }

        XCTAssertEqual(try testSkillValue(at: target), "external edit")
        XCTAssertEqual(try Data(contentsOf: index), indexBeforeSync)
        XCTAssertEqual(gate.invocationCount, 1, "Index recovery must bypass the commit hook")
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.skills.first?.targets.isEmpty == true)
        let backup = try XCTUnwrap(syncBackup(in: target.deletingLastPathComponent()))
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("user.txt"), encoding: .utf8),
            "original unmanaged"
        )
    }

    func testCommitValidationRestoresIndexAndPreservesReplacementTarget() async throws {
        let layout = try SkillsTestLayout(label: "commit-replacement")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsIndexMutationGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("original unmanaged".utf8).write(to: target.appendingPathComponent("user.txt"))
        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        let index = layout.root.appendingPathComponent(".ccbud-index.json")
        let indexBeforeSync = try Data(contentsOf: index)
        gate.arm {
            try FileManager.default.removeItem(at: target)
            try makeTestSkill(at: target, name: "External Replacement", value: "replacement")
        }

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["amp"],
                mode: .copy,
                authorizing: conflicts
            )
            XCTFail("A replacement target before file commit must reject the transaction")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("commit"))
        }

        XCTAssertEqual(try testSkillValue(at: target), "replacement")
        XCTAssertEqual(try Data(contentsOf: index), indexBeforeSync)
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.skills.first?.targets.isEmpty == true)
        let backup = try XCTUnwrap(syncBackup(in: target.deletingLastPathComponent()))
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("user.txt"), encoding: .utf8),
            "original unmanaged"
        )
    }

    func testCommitValidationChecksBackupBeforeFinalization() async throws {
        let layout = try SkillsTestLayout(label: "commit-backup-edit")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsIndexMutationGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("original unmanaged".utf8).write(to: target.appendingPathComponent("user.txt"))
        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        let index = layout.root.appendingPathComponent(".ccbud-index.json")
        let indexBeforeSync = try Data(contentsOf: index)
        gate.arm {
            let backup = try XCTUnwrap(syncBackup(in: target.deletingLastPathComponent()))
            try Data("changed backup".utf8).write(to: backup.appendingPathComponent("user.txt"))
        }

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["amp"],
                mode: .copy,
                authorizing: conflicts
            )
            XCTFail("A changed backup must reject file transaction commit")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("commit"))
        }

        XCTAssertEqual(try testSkillValue(at: target), "managed")
        XCTAssertEqual(try Data(contentsOf: index), indexBeforeSync)
        let backup = try XCTUnwrap(syncBackup(in: target.deletingLastPathComponent()))
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("user.txt"), encoding: .utf8),
            "changed backup"
        )
    }

    func testCommitCleanupPreservesBackupEditedAfterValidation() throws {
        let layout = try SkillsTestLayout(label: "commit-cleanup-edit-race")
        defer { layout.remove() }
        let root = layout.sandbox.appendingPathComponent("targets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("demo", isDirectory: true)
        let backup = root.appendingPathComponent(".ccbud-sync-backup-test", isDirectory: true)
        let cleanup = root.appendingPathComponent(".ccbud-commit-cleanup-test", isDirectory: true)
        try makeTestSkill(at: backup, value: "original target")
        let backupIdentity = try SkillPathSafety.entryIdentity(at: backup)
        let swap = SkillFileSwap(
            root: root,
            target: target,
            backup: backup,
            backupIdentity: backupIdentity,
            commitCleanupQuarantine: cleanup,
            removeCurrent: false,
            actualMode: .copy,
            fileManager: .default,
            validateBackup: { candidate in
                guard try testSkillValue(at: candidate) == "original target" else {
                    throw SkillsServiceError(message: "Backup content changed")
                }
            }
        )

        try swap.validateCommit()
        try Data("external edit".utf8).write(to: backup.appendingPathComponent("value.txt"))
        swap.finalizeCommit()

        XCTAssertEqual(try SkillPathSafety.entryIdentity(at: backup), backupIdentity)
        XCTAssertEqual(try testSkillValue(at: backup), "external edit")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cleanup), .missing)
    }

    func testCommitCleanupPreservesBackupReplacementAfterValidation() throws {
        let layout = try SkillsTestLayout(label: "commit-cleanup-replacement-race")
        defer { layout.remove() }
        let root = layout.sandbox.appendingPathComponent("targets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("demo", isDirectory: true)
        let backup = root.appendingPathComponent(".ccbud-sync-backup-test", isDirectory: true)
        let cleanup = root.appendingPathComponent(".ccbud-commit-cleanup-test", isDirectory: true)
        try makeTestSkill(at: backup, value: "original target")
        let originalIdentity = try SkillPathSafety.entryIdentity(at: backup)
        let swap = SkillFileSwap(
            root: root,
            target: target,
            backup: backup,
            backupIdentity: originalIdentity,
            commitCleanupQuarantine: cleanup,
            removeCurrent: false,
            actualMode: .copy,
            fileManager: .default,
            validateBackup: { candidate in
                guard try testSkillValue(at: candidate) == "original target" else {
                    throw SkillsServiceError(message: "Backup content changed")
                }
            }
        )

        try swap.validateCommit()
        try FileManager.default.removeItem(at: backup)
        try makeTestSkill(at: backup, value: "external replacement")
        let replacementIdentity = try SkillPathSafety.entryIdentity(at: backup)
        XCTAssertNotEqual(replacementIdentity, originalIdentity)
        swap.finalizeCommit()

        XCTAssertEqual(try SkillPathSafety.entryIdentity(at: backup), replacementIdentity)
        XCTAssertEqual(try testSkillValue(at: backup), "external replacement")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cleanup), .missing)
    }

    func testRollbackNeverOverwritesTargetCreatedWhileQuarantined() throws {
        let layout = try SkillsTestLayout(label: "rollback-quarantine-race")
        defer { layout.remove() }
        let root = layout.sandbox.appendingPathComponent("targets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("demo", isDirectory: true)
        let backup = root.appendingPathComponent(".ccbud-sync-backup-test", isDirectory: true)
        let quarantine = root.appendingPathComponent(".ccbud-rollback-current-test", isDirectory: true)
        try makeTestSkill(at: target, value: "managed current")
        try makeTestSkill(at: backup, value: "original target")
        let backupIdentity = try SkillPathSafety.entryIdentity(at: backup)
        let swap = SkillFileSwap(
            root: root,
            target: target,
            backup: backup,
            backupIdentity: backupIdentity,
            rollbackQuarantine: quarantine,
            removeCurrent: true,
            actualMode: .copy,
            fileManager: .default,
            validateCurrent: { candidate in
                XCTAssertEqual(candidate.standardizedFileURL, quarantine.standardizedFileURL)
                try makeTestSkill(at: target, value: "new arrival")
                throw SkillsServiceError(message: "Injected quarantine validation failure")
            }
        )

        XCTAssertThrowsError(try swap.rollback())
        XCTAssertEqual(try testSkillValue(at: target), "new arrival")
        XCTAssertEqual(try testSkillValue(at: quarantine), "managed current")
        XCTAssertEqual(try testSkillValue(at: backup), "original target")
    }

    func testUnsyncPreservesTargetReplacedAfterOwnershipProof() async throws {
        let layout = try SkillsTestLayout(label: "unsync-proof-replacement")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let gate = SkillsBeforeFileMoveMutationGate()
        let service = layout.service(beforeFileMove: { try gate.beforeMove(target: $0) })
        let skill = try await service.importLocal(from: source)
        _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let target = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        gate.arm(target: target) {
            try FileManager.default.removeItem(at: target)
            try makeTestSkill(at: target, name: "User Replacement", value: "keep replacement")
        }

        do {
            _ = try await service.unsync(id: skill.id, toolKeys: ["cursor"])
            XCTFail("A target replaced after ownership proof must reject unsync")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside CC Buddy"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "keep replacement")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testSeparateServiceInstancesSerializeWholeIndexOperations() async throws {
        let layout = try SkillsTestLayout(label: "process-lock")
        defer { layout.remove() }
        let firstSource = layout.sandbox.appendingPathComponent("first", isDirectory: true)
        let secondSource = layout.sandbox.appendingPathComponent("second", isDirectory: true)
        try makeTestSkill(at: firstSource, name: "First", value: "one")
        try makeTestSkill(at: secondSource, name: "Second", value: "two")
        let probe = SkillsConcurrentCommitProbe()
        let firstService = layout.service(beforeIndexCommit: { probe.beforeCommit() })
        let secondService = layout.service(beforeIndexCommit: { probe.beforeCommit() })

        async let first = firstService.importLocal(from: firstSource)
        async let second = secondService.importLocal(from: secondSource)
        let (firstImported, secondImported) = try await (first, second)
        let imported = [firstImported, secondImported]

        XCTAssertEqual(Set(imported.map(\.id)), ["first", "second"])
        XCTAssertEqual(probe.maximumConcurrentCommits, 1)
        let snapshot = try await firstService.snapshot()
        XCTAssertEqual(Set(snapshot.skills.map(\.id)), ["first", "second"])
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: layout.root))
    }

    private func makeFixture(label: String) throws -> (
        layout: SkillsTestLayout,
        source: URL,
        gate: SkillsIndexFailureGate,
        service: LiveSkillsService
    ) {
        let layout = try SkillsTestLayout(label: label)
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "before")
        let gate = SkillsIndexFailureGate()
        let service = layout.service(beforeIndexCommit: { try gate.beforeCommit() })
        return (layout, source, gate, service)
    }
}
