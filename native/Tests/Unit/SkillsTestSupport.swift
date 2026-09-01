import Foundation
import XCTest
@testable import CCBuddy

struct SkillsTestLayout {
    let sandbox: URL
    let root: URL
    let home: URL

    init(label: String) throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-native-skills-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        root = sandbox.appendingPathComponent("ccbud/skills", isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func service(
        gitRunner: any SkillCommandRunning = SkillProcessCommandRunner(),
        beforeIndexCommit: @escaping @Sendable () throws -> Void = {},
        beforeFileMove: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> LiveSkillsService {
        LiveSkillsService(
            root: root,
            userHome: home,
            gitRunner: gitRunner,
            beforeIndexCommit: beforeIndexCommit,
            beforeFileMove: beforeFileMove
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}

func makeTestSkill(at path: URL, name: String = "Test Skill", value: String) throws {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    try Data("---\nname: \(name)\ndescription: A test skill\n---\n".utf8)
        .write(to: path.appendingPathComponent("SKILL.md"))
    try Data(value.utf8).write(to: path.appendingPathComponent("value.txt"))
}

func testSkillValue(at path: URL) throws -> String {
    try String(contentsOf: path.appendingPathComponent("value.txt"), encoding: .utf8)
}

func hasSkillsTransactionArtifacts(in root: URL) -> Bool {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
        return false
    }
    return entries.contains { entry in
        entry.lastPathComponent.hasPrefix(".ccbud-sync-") ||
            entry.lastPathComponent.hasPrefix(".ccbud-commit-cleanup-") ||
            entry.lastPathComponent.hasPrefix(".ccbud-rollback-current-") ||
            entry.lastPathComponent.hasPrefix(".ccbud-remove-backup-") ||
            entry.lastPathComponent.hasPrefix(".ccbud-git-")
    }
}

func syncBackup(in root: URL) throws -> URL? {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .first { $0.lastPathComponent.hasPrefix(".ccbud-sync-backup-") }
}

final class SkillsBeforeFileMoveMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var targetPath: String?
    private var action: (@Sendable () throws -> Void)?

    func arm(target: URL, action: @escaping @Sendable () throws -> Void) {
        lock.lock()
        targetPath = target.standardizedFileURL.path
        self.action = action
        lock.unlock()
    }

    func beforeMove(target: URL) throws {
        lock.lock()
        guard target.standardizedFileURL.path == targetPath, let action else {
            lock.unlock()
            return
        }
        targetPath = nil
        self.action = nil
        lock.unlock()
        try action()
    }
}

final class SkillsIndexFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func beforeCommit() throws {
        lock.lock()
        let shouldFail = armed
        armed = false
        lock.unlock()
        if shouldFail {
            throw SkillsServiceError(message: "Injected index commit failure")
        }
    }
}

final class SkillsIndexMutationFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?

    func arm(action: @escaping @Sendable () throws -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func beforeCommit() throws {
        lock.lock()
        let action = action
        self.action = nil
        lock.unlock()
        guard let action else { return }
        try action()
        throw SkillsServiceError(message: "Injected index commit failure after target mutation")
    }
}

final class SkillsIndexMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?
    private var count = 0

    func arm(action: @escaping @Sendable () throws -> Void) {
        lock.lock()
        self.action = action
        count = 0
        lock.unlock()
    }

    func beforeCommit() throws {
        lock.lock()
        let action = action
        self.action = nil
        count += 1
        lock.unlock()
        try action?()
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class SkillsConcurrentCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    func beforeCommit() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.04)
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var maximumConcurrentCommits: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
}
