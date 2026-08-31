import Darwin
import Foundation

@_silgen_name("flock")
private func ccbud_skills_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class SkillsProcessOperationCoordinator: @unchecked Sendable {
    static let shared = SkillsProcessOperationCoordinator()

    private let lock = NSRecursiveLock()
    private let operationLockName = ".ccbud-operation.lock"

    private init() {}

    func perform<T>(
        root configuredRoot: URL,
        fileManager: FileManager,
        operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let root = try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
        let rootDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else {
            throw operationLockFailure("Cannot open Skills root \(root.path)")
        }
        defer { _ = Darwin.close(rootDescriptor) }

        let descriptor = operationLockName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw operationLockFailure("Cannot open Skills operation lock")
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw operationLockFailure("Cannot inspect Skills operation lock")
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1,
              information.st_uid == geteuid()
        else {
            throw SkillPathSafety.failure("Skills operation lock is not a private regular file")
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw operationLockFailure("Cannot secure Skills operation lock")
        }
        guard ccbud_skills_flock(descriptor, LOCK_EX) == 0 else {
            throw operationLockFailure("Cannot acquire Skills operation lock")
        }
        defer { _ = ccbud_skills_flock(descriptor, LOCK_UN) }

        return try operation()
    }

    private func operationLockFailure(_ message: String) -> SkillsServiceError {
        SkillPathSafety.failure("\(message): \(String(cString: strerror(errno)))")
    }
}

actor LiveSkillsService: SkillsManaging {
    nonisolated static var defaultRootURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let value = ProcessInfo.processInfo.environment["CCBUD_HOME"],
           !value.isEmpty,
           NSString(string: value).isAbsolutePath
        {
            return URL(fileURLWithPath: value, isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
                .standardizedFileURL
        }
        return home.appendingPathComponent(".ccbud/skills", isDirectory: true).standardizedFileURL
    }

    let fileManager: FileManager
    let configuredRoot: URL
    let userHome: URL
    let indexRepository: SkillsIndexRepository
    let scanner: SkillManifestScanner
    let transactions: SkillFileTransactions
    let git: SkillGitClient
    let now: @Sendable () -> Date

    init(
        root: URL? = nil,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        gitRunner: any SkillCommandRunning = SkillProcessCommandRunner(),
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        beforeIndexCommit: @escaping @Sendable () throws -> Void = {},
        beforeFileMove: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        configuredRoot = (root ?? Self.defaultRootURL).standardizedFileURL
        self.userHome = userHome.standardizedFileURL
        indexRepository = SkillsIndexRepository(
            fileManager: fileManager,
            beforeCommit: beforeIndexCommit
        )
        scanner = SkillManifestScanner(fileManager: fileManager)
        transactions = SkillFileTransactions(
            fileManager: fileManager,
            makeUUID: makeUUID,
            beforeMove: beforeFileMove
        )
        git = SkillGitClient(
            fileManager: fileManager,
            runner: gitRunner,
            executable: gitExecutable,
            makeUUID: makeUUID
        )
        self.now = now
    }

    func rootURL() -> URL {
        configuredRoot
    }

    func snapshot() throws -> SkillsSnapshot {
        try withProcessLock {
            let root = try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
            var index = try indexRepository.load(root: root)
            if try reconcile(root: root, index: &index) {
                try indexRepository.save(root: root, document: index)
            }
            return try makeSnapshot(root: root, index: index)
        }
    }

    func detail(id: String) throws -> SkillDetail {
        try withProcessLock {
            let root = try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
            var index = try indexRepository.load(root: root)
            if try reconcile(root: root, index: &index) {
                try indexRepository.save(root: root, document: index)
            }
            let skill = try makeSkill(id: id, root: root, index: index)
            let directory = try SkillPathSafety.existingSkillDirectory(root: root, id: id)
            return SkillDetail(skill: skill, files: try scanner.files(in: directory))
        }
    }

    func readFile(id: String, path: String) throws -> String {
        try withProcessLock {
            let root = try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
            let directory = try SkillPathSafety.existingSkillDirectory(root: root, id: id)
            let components = try SkillPathSafety.safeRelativeComponents(path)
            var candidate = directory
            for (offset, component) in components.enumerated() {
                candidate.appendPathComponent(String(component))
                let kind = try SkillPathSafety.entryKind(at: candidate)
                if offset < components.count - 1 {
                    guard kind == .directory else {
                        throw SkillPathSafety.failure("Invalid skill file path")
                    }
                } else if kind != .file {
                    throw SkillPathSafety.failure("Skill file is not a regular file")
                }
            }
            guard SkillPathSafety.isInside(candidate, root: directory) else {
                throw SkillPathSafety.failure("Skill file is outside the skill directory")
            }
            let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size <= 4 * 1_024 * 1_024 else {
                throw SkillPathSafety.failure("Skill file is too large to preview")
            }
            let data = try Data(contentsOf: candidate)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SkillPathSafety.failure("Skill file must be UTF-8")
            }
            return text
        }
    }

    func scanLocal(at root: URL) throws -> [SkillLocalCandidate] {
        try withProcessLock { try scanner.localCandidates(at: root) }
    }

    func refreshUpdates(id: String?) throws -> SkillsSnapshot {
        try withProcessLock {
            let root = try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
            var index = try indexRepository.load(root: root)
            _ = try reconcile(root: root, index: &index)
            if let id {
                try SkillPathSafety.validateID(id)
                guard index.skills[id] != nil else {
                    throw SkillPathSafety.failure("Skill not found: \(id)")
                }
            }
            for skillID in index.skills.keys.sorted() {
                guard id == nil || id == skillID,
                      var entry = index.skills[skillID],
                      entry.sourceType == "git"
                else {
                    continue
                }
                do {
                    let revision = try git.remoteHead(source: entry.sourceReference)
                    entry.status = entry.sourceRevision == revision ? "ok" : "update_available"
                } catch {
                    entry.status = "refresh_error"
                }
                index.skills[skillID] = entry
            }
            try indexRepository.save(root: root, document: index)
            return try makeSnapshot(root: root, index: index)
        }
    }

    func setTags(id: String, tags: [String]) throws -> ManagedSkill {
        try withProcessLock {
            let root = try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
            try SkillPathSafety.validateID(id)
            var index = try indexRepository.load(root: root)
            _ = try reconcile(root: root, index: &index)
            guard var entry = index.skills[id] else {
                throw SkillPathSafety.failure("Skill not found: \(id)")
            }
            var seen = Set<String>()
            entry.tags = Array(tags.compactMap { value -> String? in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 40, seen.insert(value).inserted else { return nil }
                return value
            }.prefix(32))
            index.skills[id] = entry
            try indexRepository.save(root: root, document: index)
            return try makeSkill(id: id, root: root, index: index)
        }
    }

    func withProcessLock<T>(_ operation: () throws -> T) throws -> T {
        try SkillsProcessOperationCoordinator.shared.perform(
            root: configuredRoot,
            fileManager: fileManager,
            operation: operation
        )
    }

    func ensureRoot() throws -> URL {
        try SkillPathSafety.ensureRoot(configuredRoot, fileManager: fileManager)
    }

    func reconcile(root: URL, index: inout SkillIndexDocument) throws -> Bool {
        var changed = false
        for (id, path) in try scanner.centralDirectories(root: root) where index.skills[id] == nil {
            index.skills[id] = SkillIndexEntry(
                sourceReference: path.path,
                updatedAtMilliseconds: scanner.modifiedMilliseconds(
                    at: path.appendingPathComponent("SKILL.md"),
                    now: now
                )
            )
            changed = true
        }
        return changed
    }

    func makeSnapshot(root: URL, index: SkillIndexDocument) throws -> SkillsSnapshot {
        let skills = try index.skills.keys.sorted().map { try makeSkill(id: $0, root: root, index: index) }
        return SkillsSnapshot(
            root: root,
            skills: skills,
            tools: SkillToolCatalog.tools(home: userHome, fileManager: fileManager)
        )
    }

    func makeSkill(id: String, root: URL, index: SkillIndexDocument) throws -> ManagedSkill {
        try SkillPathSafety.validateID(id)
        guard let metadata = index.skills[id] else {
            throw SkillPathSafety.failure("Skill not found: \(id)")
        }
        let path = root.appendingPathComponent(id, isDirectory: true)
        let physicalStatus = try centralStatus(path)
        let summary: (String, String?)
        let resolvedPhysicalStatus: String
        if physicalStatus == "ok" {
            do {
                let values = try scanner.manifestSummary(in: path)
                summary = (values.name, values.description)
                resolvedPhysicalStatus = "ok"
            } catch {
                summary = (id, nil)
                resolvedPhysicalStatus = "invalid"
            }
        } else {
            summary = (id, nil)
            resolvedPhysicalStatus = physicalStatus
        }
        var targets = metadata.targets
        for index in targets.indices where !fileManager.fileExists(atPath: targets[index].path.path) {
            targets[index].status = "missing"
        }
        let status: String
        if resolvedPhysicalStatus != "ok" {
            status = resolvedPhysicalStatus
        } else if targets.contains(where: { $0.status != "ok" }) {
            status = "sync_error"
        } else {
            status = metadata.status
        }
        return ManagedSkill(
            id: id,
            name: summary.0,
            description: summary.1,
            path: path,
            sourceType: metadata.sourceType,
            sourceReference: metadata.sourceReference,
            updatedAt: metadata.updatedAtMilliseconds > 0
                ? Date(timeIntervalSince1970: Double(metadata.updatedAtMilliseconds) / 1_000)
                : nil,
            tags: metadata.tags,
            targets: targets,
            status: status,
            sourceStatus: metadata.status
        )
    }

    private func centralStatus(_ path: URL) throws -> String {
        switch try SkillPathSafety.entryKind(at: path) {
        case .missing:
            return "missing"
        case .directory:
            return try SkillPathSafety.entryKind(at: path.appendingPathComponent("SKILL.md")) == .file
                ? "ok"
                : "invalid"
        case .file, .symlink, .other:
            return "invalid"
        }
    }
}
