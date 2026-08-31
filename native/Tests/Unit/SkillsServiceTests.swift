import Foundation
import XCTest
@testable import CCBuddy

final class SkillsServiceTests: XCTestCase {
    func testScanImportPreviewIndexAndToolCatalog() async throws {
        let layout = try SkillsTestLayout(label: "catalog")
        defer { layout.remove() }
        let candidatesRoot = layout.sandbox.appendingPathComponent("candidates", isDirectory: true)
        let source = candidatesRoot.appendingPathComponent("group/source", isDirectory: true)
        try makeTestSkill(at: source, name: "My Skill", value: "hello")
        try makeTestSkill(
            at: candidatesRoot.appendingPathComponent("node_modules/ignored", isDirectory: true),
            name: "Ignored",
            value: "ignored"
        )
        let service = layout.service()

        let candidates = try await service.scanLocal(at: candidatesRoot)
        XCTAssertEqual(candidates.map(\.name), ["My Skill"])
        let imported = try await service.importLocal(from: source)
        XCTAssertEqual(imported.id, "my-skill")
        XCTAssertEqual(imported.sourceType, "local")
        let preview = try await service.readFile(id: imported.id, path: "value.txt")
        XCTAssertEqual(preview, "hello")

        do {
            _ = try await service.readFile(id: imported.id, path: "../SKILL.md")
            XCTFail("Traversal should be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("relative"))
        }
        let tagged = try await service.setTags(
            id: imported.id,
            tags: [" docs ", "docs", "swift"]
        )
        XCTAssertEqual(tagged.tags, ["docs", "swift"])
        let detail = try await service.detail(id: imported.id)
        XCTAssertEqual(detail.files.map(\.path), ["SKILL.md", "value.txt"])
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.skills.count, 1)
        XCTAssertEqual(snapshot.tools.count, 47)
        XCTAssertEqual(snapshot.tools.first?.key, "cursor")
        XCTAssertEqual(snapshot.tools.first?.defaultSyncMode, .copy)
        XCTAssertEqual(snapshot.summary.localCount, 1)

        let indexData = try Data(contentsOf: layout.root.appendingPathComponent(".ccbud-index.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
        let skills = try XCTUnwrap(json["skills"] as? [String: Any])
        let record = try XCTUnwrap(skills[imported.id] as? [String: Any])
        XCTAssertEqual(record["source_type"] as? String, "local")
        XCTAssertNotNil(record["updated_at"])
    }

    func testTopLevelSourceSymlinkIsAllowedButNestedSymlinkIsRejected() async throws {
        let layout = try SkillsTestLayout(label: "source-links")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        let sourceLink = layout.sandbox.appendingPathComponent("source-link", isDirectory: true)
        try makeTestSkill(at: source, value: "safe")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        let service = layout.service()

        let imported = try await service.importLocal(from: sourceLink)
        XCTAssertEqual(imported.sourceReference, source.path)
        let unsafe = layout.sandbox.appendingPathComponent("unsafe", isDirectory: true)
        try makeTestSkill(at: unsafe, name: "Unsafe", value: "unsafe")
        try FileManager.default.createSymbolicLink(
            at: unsafe.appendingPathComponent("escape"),
            withDestinationURL: source
        )
        do {
            _ = try await service.importLocal(from: unsafe)
            XCTFail("Nested symbolic links must be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("symbolic link"))
        }
    }

    func testSharedTargetSemanticsCursorCopyAndDelete() async throws {
        let layout = try SkillsTestLayout(label: "sync")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "sync")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)

        let synced = try await service.sync(
            id: skill.id,
            toolKeys: ["cursor", "amp", "kimi_cli"],
            mode: .symlink
        )
        XCTAssertEqual(synced.targets.count, 3)
        let cursor = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cursor), .directory)
        let shared = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: shared), .symlink)

        let partly = try await service.unsync(id: skill.id, toolKeys: ["amp"])
        XCTAssertEqual(partly.targets.map(\.key), ["cursor", "kimi_cli"])
        XCTAssertNotEqual(try SkillPathSafety.entryKind(at: shared), .missing)
        _ = try await service.unsync(id: skill.id, toolKeys: ["kimi_cli"])
        XCTAssertEqual(try SkillPathSafety.entryKind(at: shared), .missing)
        let removed = try await service.remove(id: skill.id)
        XCTAssertTrue(removed)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: layout.root.appendingPathComponent(skill.id)), .missing)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cursor), .missing)
    }

    func testSharedTargetResyncUpdatesEveryKeyModeStatusAndOwnership() async throws {
        let layout = try SkillsTestLayout(label: "shared-resync")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, name: "Shared Proof", value: "before")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)

        _ = try await service.sync(id: skill.id, toolKeys: ["amp"], mode: .symlink)
        let synced = try await service.sync(id: skill.id, toolKeys: ["kimi_cli"], mode: .copy)
        let shared = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: shared), .directory)
        XCTAssertEqual(Set(synced.targets.map(\.syncMode)), [.copy])
        XCTAssertEqual(Set(synced.targets.map(\.status)), ["ok"])
        XCTAssertEqual(Set(synced.targets.compactMap(\.managedIdentity)).count, 1)
        XCTAssertEqual(Set(synced.targets.compactMap(\.managedDigest)).count, 1)

        try makeTestSkill(at: source, name: "Shared Proof", value: "after")
        let updated = try await service.update(id: skill.id)
        XCTAssertEqual(Set(updated.targets.map(\.syncMode)), [.copy])
        XCTAssertEqual(Set(updated.targets.map(\.status)), ["ok"])
        XCTAssertEqual(try SkillPathSafety.entryKind(at: shared), .directory)
        XCTAssertEqual(try testSkillValue(at: shared), "after")
    }

    func testUnmanagedTargetPreflightPreventsPartialSync() async throws {
        let layout = try SkillsTestLayout(label: "preflight")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "safe")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let unmanaged = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unmanaged.appendingPathComponent("user.txt"))

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["cursor", "amp"],
                mode: .copy
            )
            XCTFail("Unmanaged targets should reject the entire operation")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("unmanaged"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.home.appendingPathComponent(".cursor/skills/\(skill.id)").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.appendingPathComponent("user.txt").path))
    }
}
