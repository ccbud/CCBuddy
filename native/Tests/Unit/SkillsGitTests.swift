import Foundation
import XCTest
@testable import CCBuddy

final class SkillsFakeGitRunner: SkillCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = "aaaaaaaa"
    private var value = "one"
    private var failClone = false

    func configure(revision: String, value: String, failClone: Bool = false) {
        lock.lock()
        self.revision = revision
        self.value = value
        self.failClone = failClone
        lock.unlock()
    }

    func run(_ invocation: SkillCommandInvocation) throws -> SkillCommandResult {
        lock.lock()
        let revision = revision
        let value = value
        let failClone = failClone
        lock.unlock()

        let arguments = invocation.arguments
        if arguments.first == "clone" {
            let destination = URL(fileURLWithPath: try XCTUnwrap(arguments.last), isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if failClone {
                return SkillCommandResult(terminationStatus: 1, output: Data("clone failed".utf8))
            }
            try makeTestSkill(
                at: destination.appendingPathComponent("nested/skill", isDirectory: true),
                name: "Git Skill",
                value: value
            )
            return SkillCommandResult(terminationStatus: 0, output: Data())
        }
        if arguments.contains("rev-parse") {
            return SkillCommandResult(terminationStatus: 0, output: Data("\(revision)\n".utf8))
        }
        if arguments.first == "ls-remote" {
            return SkillCommandResult(
                terminationStatus: 0,
                output: Data("\(revision)\tHEAD\n".utf8)
            )
        }
        return SkillCommandResult(terminationStatus: 1, output: Data("unexpected Git command".utf8))
    }
}

final class SkillsGitTests: XCTestCase {
    func testGitImportRefreshAndUpdateUseInjectedRunner() async throws {
        let layout = try SkillsTestLayout(label: "git")
        defer { layout.remove() }
        let runner = SkillsFakeGitRunner()
        let service = layout.service(gitRunner: runner)
        let source = "https://github.com/example/skills.git"

        let imported = try await service.importGit(from: source)
        XCTAssertEqual(imported.map(\.id), ["git-skill"])
        XCTAssertEqual(imported.first?.sourceType, "git")
        XCTAssertEqual(try testSkillValue(at: layout.root.appendingPathComponent("git-skill")), "one")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: layout.root))

        let repeated = try await service.importGit(from: source)
        XCTAssertEqual(repeated.map(\.id), ["git-skill"])
        let repeatedSnapshot = try await service.snapshot()
        XCTAssertEqual(repeatedSnapshot.skills.map(\.id), ["git-skill"])
        let indexData = try Data(contentsOf: layout.root.appendingPathComponent(".ccbud-index.json"))
        let indexJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: indexData) as? [String: Any])
        let indexedSkills = try XCTUnwrap(indexJSON["skills"] as? [String: Any])
        let indexedSkill = try XCTUnwrap(indexedSkills["git-skill"] as? [String: Any])
        XCTAssertEqual(indexedSkill["source_subdir"] as? String, "nested/skill")
        XCTAssertEqual(indexedSkill["source_revision"] as? String, "aaaaaaaa")

        let current = try await service.refreshUpdates(id: "git-skill")
        XCTAssertEqual(current.skills.first?.status, "ok")
        runner.configure(revision: "bbbbbbbb", value: "two")
        let available = try await service.refreshUpdates(id: "git-skill")
        XCTAssertEqual(available.skills.first?.status, "update_available")

        let updated = try await service.update(id: "git-skill")
        XCTAssertEqual(updated.status, "ok")
        XCTAssertEqual(try testSkillValue(at: layout.root.appendingPathComponent("git-skill")), "two")
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: layout.root))
    }

    func testGitURLBoundariesAndFailedCloneCleanup() async throws {
        let layout = try SkillsTestLayout(label: "git-failure")
        defer { layout.remove() }
        let runner = SkillsFakeGitRunner()
        runner.configure(revision: "aaaaaaaa", value: "one", failClone: true)
        let service = layout.service(gitRunner: runner)

        do {
            _ = try await service.importGit(from: "file:///tmp/repository")
            XCTFail("Local Git URLs must be rejected")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("Only HTTPS"))
        }
        do {
            _ = try await service.importGit(from: "https://github.com/example/skills.git")
            XCTFail("Clone failure should surface")
        } catch {
            XCTAssertTrue(skillErrorMessage(error).contains("clone failed"))
        }
        XCTAssertFalse(hasSkillsTransactionArtifacts(in: layout.root))
    }
}
