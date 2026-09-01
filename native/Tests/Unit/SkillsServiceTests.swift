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
        XCTAssertEqual(snapshot.tools.count, 46)
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
        let central = layout.root.appendingPathComponent(skill.id, isDirectory: true)
        let cursor = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cursor), .directory)
        XCTAssertEqual(try testSkillValue(at: cursor), "sync")
        let shared = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: shared), .symlink)
        for key in ["amp", "kimi_cli"] {
            let target = try XCTUnwrap(synced.targets.first { $0.key == key })
            XCTAssertEqual(target.path.standardizedFileURL, shared.standardizedFileURL)
            XCTAssertEqual(target.syncMode, .symlink)
        }
        let rawDestination = try FileManager.default.destinationOfSymbolicLink(atPath: shared.path)
        let linkDestination = NSString(string: rawDestination).isAbsolutePath
            ? URL(fileURLWithPath: rawDestination)
            : shared.deletingLastPathComponent().appendingPathComponent(rawDestination)
        XCTAssertEqual(
            linkDestination.standardizedFileURL.resolvingSymlinksInPath(),
            central.standardizedFileURL.resolvingSymlinksInPath()
        )

        try Data("central-only".utf8).write(to: central.appendingPathComponent("value.txt"))
        XCTAssertEqual(try testSkillValue(at: shared), "central-only")
        XCTAssertEqual(try testSkillValue(at: cursor), "sync")
        try Data("sync".utf8).write(to: central.appendingPathComponent("value.txt"))

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
        let cursorRoot = layout.home.appendingPathComponent(".cursor/skills", isDirectory: true)
        let index = layout.root.appendingPathComponent(".ccbud-index.json")
        let indexBeforePreview = try Data(contentsOf: index)

        let conflicts = try await service.syncConflicts(
            id: skill.id,
            toolKeys: ["cursor", "amp"]
        )
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.path.standardizedFileURL, unmanaged.standardizedFileURL)
        XCTAssertEqual(conflicts.first?.toolKeys, ["amp"])
        XCTAssertEqual(try Data(contentsOf: index), indexBeforePreview)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cursorRoot), .missing)

        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["cursor", "amp"],
                mode: .copy
            )
            XCTFail("Unmanaged targets should reject the entire operation")
        } catch let error as SkillSyncConfirmationRequired {
            XCTAssertEqual(error.conflicts, conflicts)
        } catch {
            XCTFail("Expected typed confirmation requirement, got: \(skillErrorMessage(error))")
        }
        XCTAssertEqual(try Data(contentsOf: index), indexBeforePreview)
        XCTAssertEqual(try SkillPathSafety.entryKind(at: cursorRoot), .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.appendingPathComponent("user.txt").path))
    }

    func testAuthorizedSyncReplacesUnmanagedDirectory() async throws {
        let layout = try SkillsTestLayout(label: "authorized-directory")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("user data".utf8).write(to: target.appendingPathComponent("user.txt"))

        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        XCTAssertEqual(conflicts.count, 1)
        let synced = try await service.sync(
            id: skill.id,
            toolKeys: ["amp"],
            mode: .copy,
            authorizing: conflicts
        )

        XCTAssertEqual(try SkillPathSafety.entryKind(at: target), .directory)
        XCTAssertEqual(try testSkillValue(at: target), "managed")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: target.appendingPathComponent("user.txt")), .missing)
        XCTAssertEqual(synced.targets.map(\.key), ["amp"])
        XCTAssertNotNil(synced.targets.first?.managedIdentity)
        XCTAssertNotNil(synced.targets.first?.managedDigest)
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: target.deletingLastPathComponent()))
    }

    func testSharedUnmanagedTargetProducesOneConflictAndOneReplacement() async throws {
        let layout = try SkillsTestLayout(label: "shared-confirmation")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "shared")
        let probe = SkillsFileMoveProbe()
        let service = layout.service(beforeFileMove: { probe.record($0) })
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("user data".utf8).write(to: target.appendingPathComponent("user.txt"))

        let conflicts = try await service.syncConflicts(
            id: skill.id,
            toolKeys: ["kimi_cli", "amp"]
        )
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflict.path.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(conflict.toolKeys, ["amp", "kimi_cli"])

        let synced = try await service.sync(
            id: skill.id,
            toolKeys: ["kimi_cli", "amp"],
            mode: .copy,
            authorizing: conflicts
        )

        XCTAssertEqual(probe.count(for: target), 1)
        XCTAssertEqual(synced.targets.map(\.key), ["amp", "kimi_cli"])
        XCTAssertEqual(Set(synced.targets.map { $0.path.standardizedFileURL }), [target.standardizedFileURL])
        XCTAssertEqual(Set(synced.targets.compactMap(\.managedIdentity)).count, 1)
        XCTAssertEqual(Set(synced.targets.compactMap(\.managedDigest)).count, 1)
        XCTAssertEqual(try testSkillValue(at: target), "shared")
    }

    func testAuthorizedSyncRejectsStaleFingerprintWithTypedConflict() async throws {
        let layout = try SkillsTestLayout(label: "stale-confirmation")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let target = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let userFile = target.appendingPathComponent("user.txt")
        try Data("before".utf8).write(to: userFile)
        let identity = try SkillPathSafety.entryIdentity(at: target)
        let conflicts = try await service.syncConflicts(id: skill.id, toolKeys: ["amp"])
        let staleConflict = try XCTUnwrap(conflicts.first)

        try Data("after".utf8).write(to: userFile)
        XCTAssertEqual(try SkillPathSafety.entryIdentity(at: target), identity)
        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["amp"],
                mode: .copy,
                authorizing: conflicts
            )
            XCTFail("A stale authorization token must not replace the target")
        } catch let error as SkillSyncConfirmationRequired {
            let current = try XCTUnwrap(error.conflicts.first)
            XCTAssertEqual(error.conflicts.count, 1)
            XCTAssertEqual(current.path.standardizedFileURL, target.standardizedFileURL)
            XCTAssertNotEqual(current.fingerprintToken, staleConflict.fingerprintToken)
        } catch {
            XCTFail("Expected a refreshed typed conflict, got: \(skillErrorMessage(error))")
        }
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "after")
        XCTAssertEqual(try SkillPathSafety.entryKind(at: target.appendingPathComponent("SKILL.md")), .missing)
        let snapshot = try await service.snapshot()
        XCTAssertTrue(snapshot.skills.first?.targets.isEmpty == true)
    }

    func testStaleAuthorizationReturnsEveryCurrentConflictForOneStepReconfirmation() async throws {
        let layout = try SkillsTestLayout(label: "stale-multiple-confirmations")
        defer { layout.remove() }
        let source = layout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: source, value: "managed")
        let service = layout.service()
        let skill = try await service.importLocal(from: source)
        let cursor = layout.home.appendingPathComponent(".cursor/skills/\(skill.id)")
        let amp = layout.home.appendingPathComponent(".config/agents/skills/\(skill.id)")
        for target in [cursor, amp] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("before".utf8).write(to: target.appendingPathComponent("user.txt"))
        }
        let original = try await service.syncConflicts(
            id: skill.id,
            toolKeys: ["cursor", "amp"]
        )
        XCTAssertEqual(original.count, 2)
        let originalTokens = Dictionary(uniqueKeysWithValues: original.map {
            ($0.path.standardizedFileURL.path, $0.fingerprintToken)
        })

        try Data("after".utf8).write(to: amp.appendingPathComponent("user.txt"))
        let refreshed: [SkillSyncConflict]
        do {
            _ = try await service.sync(
                id: skill.id,
                toolKeys: ["cursor", "amp"],
                mode: .copy,
                authorizing: original
            )
            XCTFail("One stale token must require confirmation for the complete current conflict set")
            return
        } catch let error as SkillSyncConfirmationRequired {
            refreshed = error.conflicts
        } catch {
            XCTFail("Expected refreshed typed conflicts, got: \(skillErrorMessage(error))")
            return
        }

        XCTAssertEqual(refreshed.count, 2)
        let refreshedTokens = Dictionary(uniqueKeysWithValues: refreshed.map {
            ($0.path.standardizedFileURL.path, $0.fingerprintToken)
        })
        XCTAssertEqual(refreshedTokens[cursor.standardizedFileURL.path], originalTokens[cursor.standardizedFileURL.path])
        XCTAssertNotEqual(refreshedTokens[amp.standardizedFileURL.path], originalTokens[amp.standardizedFileURL.path])
        XCTAssertEqual(
            try String(contentsOf: cursor.appendingPathComponent("user.txt"), encoding: .utf8),
            "before"
        )
        XCTAssertEqual(
            try String(contentsOf: amp.appendingPathComponent("user.txt"), encoding: .utf8),
            "after"
        )

        let synced = try await service.sync(
            id: skill.id,
            toolKeys: ["cursor", "amp"],
            mode: .copy,
            authorizing: refreshed
        )
        XCTAssertEqual(synced.targets.map(\.key), ["amp", "cursor"])
        XCTAssertEqual(try testSkillValue(at: cursor), "managed")
        XCTAssertEqual(try testSkillValue(at: amp), "managed")
    }

    func testAuthorizedSyncReplacesUnmanagedFileAndSymlink() async throws {
        let fileLayout = try SkillsTestLayout(label: "authorized-file")
        defer { fileLayout.remove() }
        let fileSource = fileLayout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: fileSource, value: "from file")
        let fileService = fileLayout.service()
        let fileSkill = try await fileService.importLocal(from: fileSource)
        let fileTarget = fileLayout.home.appendingPathComponent(".cursor/skills/\(fileSkill.id)")
        try FileManager.default.createDirectory(
            at: fileTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unmanaged file".utf8).write(to: fileTarget)
        let fileConflicts = try await fileService.syncConflicts(id: fileSkill.id, toolKeys: ["cursor"])
        XCTAssertEqual(fileConflicts.count, 1)

        _ = try await fileService.sync(
            id: fileSkill.id,
            toolKeys: ["cursor"],
            mode: .copy,
            authorizing: fileConflicts
        )
        XCTAssertEqual(try SkillPathSafety.entryKind(at: fileTarget), .directory)
        XCTAssertEqual(try testSkillValue(at: fileTarget), "from file")

        let linkLayout = try SkillsTestLayout(label: "authorized-link")
        defer { linkLayout.remove() }
        let linkSource = linkLayout.sandbox.appendingPathComponent("source", isDirectory: true)
        try makeTestSkill(at: linkSource, value: "from link")
        let linkService = linkLayout.service()
        let linkSkill = try await linkService.importLocal(from: linkSource)
        let linkTarget = linkLayout.home.appendingPathComponent(".config/agents/skills/\(linkSkill.id)")
        let destination = linkLayout.sandbox.appendingPathComponent("user-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: destination.appendingPathComponent("user.txt"))
        try FileManager.default.createDirectory(
            at: linkTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkTarget, withDestinationURL: destination)
        let linkConflicts = try await linkService.syncConflicts(id: linkSkill.id, toolKeys: ["amp"])
        XCTAssertEqual(linkConflicts.count, 1)

        _ = try await linkService.sync(
            id: linkSkill.id,
            toolKeys: ["amp"],
            mode: .copy,
            authorizing: linkConflicts
        )
        XCTAssertEqual(try SkillPathSafety.entryKind(at: linkTarget), .directory)
        XCTAssertEqual(try testSkillValue(at: linkTarget), "from link")
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("user.txt"), encoding: .utf8),
            "preserve"
        )
    }
}

private final class SkillsFileMoveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ target: URL) {
        lock.lock()
        counts[target.standardizedFileURL.path, default: 0] += 1
        lock.unlock()
    }

    func count(for target: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[target.standardizedFileURL.path, default: 0]
    }
}
