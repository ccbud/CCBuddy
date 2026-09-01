import Foundation
import XCTest
@testable import CCBuddy

actor SkillsStoreFakeService: SkillsManaging {
    let root: URL
    let skill: ManagedSkill
    let candidate: SkillLocalCandidate
    let syncConflict: SkillSyncConflict?
    private var authorizedSyncCount = 0

    init(root: URL, syncConflict: SkillSyncConflict? = nil) {
        self.root = root
        self.syncConflict = syncConflict
        skill = ManagedSkill(
            id: "demo",
            name: "Demo",
            description: "Store fixture",
            path: root.appendingPathComponent("demo"),
            sourceType: "local",
            sourceReference: "/tmp/demo",
            updatedAt: nil,
            tags: [],
            targets: [],
            status: "ok",
            sourceStatus: "ok"
        )
        candidate = SkillLocalCandidate(
            name: "Candidate",
            description: nil,
            path: root.appendingPathComponent("candidate")
        )
    }

    func snapshot() -> SkillsSnapshot {
        SkillsSnapshot(root: root, skills: [skill], tools: [])
    }

    func detail(id: String) throws -> SkillDetail {
        guard id == skill.id else { throw SkillsServiceError(message: "not found") }
        return SkillDetail(skill: skill, files: [])
    }

    func scanLocal(at root: URL) -> [SkillLocalCandidate] { [candidate] }
    func remove(id: String) throws -> Bool { throw SkillsServiceError(message: "remove failed") }
    func rootURL() -> URL { root }

    func readFile(id: String, path: String) throws -> String { throw unsupported() }
    func importLocal(from source: URL) throws -> ManagedSkill { throw unsupported() }
    func importGit(from source: String) throws -> [ManagedSkill] { throw unsupported() }
    func refreshUpdates(id: String?) -> SkillsSnapshot { SkillsSnapshot(root: root, skills: [skill], tools: []) }
    func update(id: String) throws -> ManagedSkill { throw unsupported() }
    func sync(id: String, toolKeys: [String], mode: SkillSyncMode) throws -> ManagedSkill { throw unsupported() }
    func syncConflicts(id: String, toolKeys: [String]) async -> [SkillSyncConflict] {
        syncConflict.map { [$0] } ?? []
    }
    func sync(
        id: String,
        toolKeys: [String],
        mode: SkillSyncMode,
        authorizing: [SkillSyncConflict]
    ) async throws -> ManagedSkill {
        guard let syncConflict else { throw unsupported() }
        guard authorizing.contains(syncConflict) else {
            throw SkillSyncConfirmationRequired(conflicts: [syncConflict])
        }
        authorizedSyncCount += 1
        return skill
    }
    func unsync(id: String, toolKeys: [String]) throws -> ManagedSkill { throw unsupported() }
    func setTags(id: String, tags: [String]) throws -> ManagedSkill { throw unsupported() }

    func successfulAuthorizedSyncs() -> Int { authorizedSyncCount }

    private func unsupported() -> SkillsServiceError {
        SkillsServiceError(message: "unsupported")
    }
}

@MainActor
final class SkillsStoreTests: XCTestCase {
    func testInjectedStorePublishesSnapshotScanAndPreservesDetailAfterFailedRemove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-store-fixture")
        let service = SkillsStoreFakeService(root: root)
        let store = SkillsStore(service: service, initialRoot: root)

        await store.refresh()
        XCTAssertEqual(store.snapshot.skills.map(\.id), ["demo"])
        await store.select(id: "demo")
        XCTAssertEqual(store.selectedDetail?.skill.id, "demo")
        let candidates = await store.scanLocal(at: root)
        XCTAssertEqual(candidates.map(\.name), ["Candidate"])
        XCTAssertFalse(store.isBusy)

        await store.remove(id: "demo")
        XCTAssertEqual(store.selectedDetail?.skill.id, "demo")
        XCTAssertEqual(store.errorMessage, "remove failed")
        XCTAssertFalse(store.isBusy)
    }

    func testStartingUpdateCheckClearsPreviousRunCountsAndErrors() {
        let previousRun = Date(timeIntervalSince1970: 100)
        var summary = SkillsUpdateRunSummary()
        summary.finishUpdate(
            checked: 3,
            result: SkillsBatchResult(succeeded: 2, errors: ["old failure"]),
            at: previousRun
        )

        summary.beginCheck()

        XCTAssertEqual(summary.lastRun, previousRun)
        XCTAssertEqual(summary.checked, 0)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(summary.errors.isEmpty)
    }

    func testSyncSelectionCanRemoveARecordedUndetectedTarget() {
        let root = URL(fileURLWithPath: "/tmp/skills-sync-selection", isDirectory: true)
        let target = SkillTarget(
            key: "codex",
            path: root.appendingPathComponent("target", isDirectory: true),
            syncMode: .copy
        )
        let skill = ManagedSkill(
            id: "demo",
            name: "Demo",
            description: nil,
            path: root.appendingPathComponent("demo", isDirectory: true),
            sourceType: "local",
            sourceReference: "/tmp/demo",
            updatedAt: nil,
            tags: [],
            targets: [target],
            status: "ok",
            sourceStatus: "ok"
        )
        let undetected = SkillTool(
            key: "codex",
            label: "Codex",
            path: target.path.deletingLastPathComponent(),
            detected: false,
            enabled: true,
            defaultSyncMode: .auto,
            sharedKeys: [],
            projectPath: nil,
            sharedProjectKeys: []
        )

        XCTAssertTrue(SkillsSyncPanel.canToggle(undetected, for: skill))
        XCTAssertEqual(
            SkillsSyncPanel.keysToRemove(for: skill, selectedKeys: []),
            Set(["codex"])
        )
    }

    func testSyncSurfacesTypedConfirmationAndAcceptsExactAuthorization() async {
        let root = URL(fileURLWithPath: "/tmp/skills-store-conflict", isDirectory: true)
        let conflict = SkillSyncConflict(
            skillID: "demo",
            path: root.appendingPathComponent("target/demo", isDirectory: true),
            toolKeys: ["codex"],
            fingerprintToken: "fingerprint"
        )
        let service = SkillsStoreFakeService(root: root, syncConflict: conflict)
        let store = SkillsStore(service: service, initialRoot: root)

        await store.refresh()
        let preview = await store.syncConflicts(id: "demo", toolKeys: ["codex"])
        XCTAssertEqual(preview, [conflict])

        switch await store.sync(id: "demo", toolKeys: ["codex"], mode: .copy) {
        case .confirmationRequired(let conflicts):
            XCTAssertEqual(conflicts, [conflict])
        case .succeeded, .failed:
            XCTFail("An unmanaged target must require confirmation")
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)

        switch await store.sync(
            id: "demo",
            toolKeys: ["codex"],
            mode: .copy,
            authorizing: [conflict]
        ) {
        case .succeeded:
            break
        case .confirmationRequired, .failed:
            XCTFail("The exact conflict authorization should permit sync")
        }
        let successfulAuthorizedSyncs = await service.successfulAuthorizedSyncs()
        XCTAssertEqual(successfulAuthorizedSyncs, 1)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)
    }
}
