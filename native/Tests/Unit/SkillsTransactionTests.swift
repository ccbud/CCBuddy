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
        _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
        let target = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        try FileManager.default.removeItem(at: target)
        gate.arm(target: target) {
            try makeTestSkill(at: target, name: "User Creation", value: "keep creation")
        }

        do {
            _ = try await service.sync(id: skill.id, toolKeys: ["cursor"], mode: .copy)
            XCTFail("A target created after a missing proof must reject sync")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("changed outside CC Buddy"))
        }
        XCTAssertEqual(try testSkillValue(at: target), "keep creation")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
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
