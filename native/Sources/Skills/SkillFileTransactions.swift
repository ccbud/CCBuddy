import CryptoKit
import Foundation

struct SkillTargetOwnership: Equatable {
    var identity: String
    var digest: String?
}

enum SkillExpectedTargetState: Equatable {
    case missing
    case present(identity: String)
}

final class SkillFileSwap {
    let actualMode: SkillSyncMode

    private let root: URL
    private let target: URL
    private let fileManager: FileManager
    private var backup: URL?
    private var backupIdentity: String?
    private let removeCurrent: Bool
    private let validateCurrent: (() throws -> Void)?
    private var rolledBack = false

    init(
        root: URL,
        target: URL,
        backup: URL?,
        backupIdentity: String? = nil,
        removeCurrent: Bool,
        actualMode: SkillSyncMode,
        fileManager: FileManager,
        validateCurrent: (() throws -> Void)? = nil
    ) {
        self.root = root
        self.target = target
        self.backup = backup
        self.backupIdentity = backupIdentity
        self.removeCurrent = removeCurrent
        self.actualMode = actualMode
        self.fileManager = fileManager
        self.validateCurrent = validateCurrent
    }

    func commit() {
        guard let backup,
              let backupIdentity,
              (try? SkillPathSafety.entryIdentity(at: backup)) == backupIdentity
        else { return }
        do {
            try SkillPathSafety.removeDirectChild(root: root, child: backup, fileManager: fileManager)
            self.backup = nil
            self.backupIdentity = nil
        } catch {}
    }

    func rollback() throws {
        guard !rolledBack else { return }
        if let backup {
            guard let backupIdentity,
                  try SkillPathSafety.entryIdentity(at: backup) == backupIdentity
            else {
                throw SkillPathSafety.failure("Backup changed before rollback: \(backup.path)")
            }
        }
        if removeCurrent {
            guard let validateCurrent else {
                throw SkillPathSafety.failure("Cannot verify target before rollback: \(target.path)")
            }
            try validateCurrent()
            try SkillPathSafety.removeDirectChild(root: root, child: target, fileManager: fileManager)
        } else if try SkillPathSafety.entryKind(at: target) != .missing {
            throw SkillPathSafety.failure("Target reappeared during rollback: \(target.path)")
        }
        if let backup {
            let expectedIdentity = backupIdentity
            do {
                try fileManager.moveItem(at: backup, to: target)
                guard let expectedIdentity,
                      try SkillPathSafety.entryIdentity(at: target) == expectedIdentity
                else {
                    throw SkillPathSafety.failure("Restored target identity changed: \(target.path)")
                }
                self.backup = nil
                backupIdentity = nil
            } catch {
                throw SkillPathSafety.failure("Cannot restore target \(target.path): \(error.localizedDescription)")
            }
        }
        rolledBack = true
    }
}

final class SkillFileTransaction {
    private var swaps: [SkillFileSwap] = []
    private var finished = false

    deinit {
        if !finished { try? rollbackInner() }
    }

    func append(_ swap: SkillFileSwap) {
        swaps.append(swap)
    }

    func commit() {
        swaps.forEach { $0.commit() }
        finished = true
    }

    func rollback() throws {
        try rollbackInner()
        finished = true
    }

    private func rollbackInner() throws {
        var failures: [String] = []
        for swap in swaps.reversed() {
            do {
                try swap.rollback()
            } catch {
                failures.append(skillErrorMessage(error))
            }
        }
        if !failures.isEmpty {
            throw SkillPathSafety.failure(failures.joined(separator: "; "))
        }
    }
}

struct SkillFileTransactions {
    private let fileManager: FileManager
    private let makeUUID: () -> UUID
    private let beforeMove: @Sendable (URL) throws -> Void
    private let maximumBytes: UInt64 = 512 * 1_024 * 1_024
    private let maximumEntries = 30_000

    init(
        fileManager: FileManager,
        makeUUID: @escaping () -> UUID,
        beforeMove: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileManager = fileManager
        self.makeUUID = makeUUID
        self.beforeMove = beforeMove
    }

    func validateSource(_ source: URL) throws -> URL {
        let source = try SkillPathSafety.realDirectory(source, label: "Skill source")
        let manifest = source.appendingPathComponent("SKILL.md")
        guard try SkillPathSafety.entryKind(at: manifest) == .file else {
            throw SkillPathSafety.failure("Missing regular SKILL.md in \(source.path)")
        }
        return source
    }

    func ownershipForInstalledTarget(
        source: URL,
        target: URL,
        mode: SkillSyncMode
    ) throws -> SkillTargetOwnership {
        let identity = try SkillPathSafety.entryIdentity(at: target)
        switch mode {
        case .copy:
            guard try SkillPathSafety.entryKind(at: target) == .directory else {
                throw unmanagedTarget(target)
            }
            let sourceDigest = try directoryDigest(source, ignoringGitDirectories: true)
            let targetDigest = try directoryDigest(target, ignoringGitDirectories: false)
            guard sourceDigest == targetDigest else { throw unmanagedTarget(target) }
            return SkillTargetOwnership(identity: identity, digest: targetDigest)
        case .symlink:
            guard try SkillPathSafety.entryKind(at: target) == .symlink,
                  try symbolicLink(at: target, pointsTo: source)
            else {
                throw unmanagedTarget(target)
            }
            return SkillTargetOwnership(identity: identity, digest: nil)
        case .auto:
            throw SkillPathSafety.failure("Managed target mode was not resolved")
        }
    }

    func validateManagedTarget(
        source: URL,
        target: URL,
        metadata: SkillTarget
    ) throws -> SkillExpectedTargetState {
        let kind = try SkillPathSafety.entryKind(at: target)
        guard kind != .missing else { return .missing }
        let identity = try SkillPathSafety.entryIdentity(at: target)
        if let expectedIdentity = metadata.managedIdentity, identity != expectedIdentity {
            throw unmanagedTarget(target)
        }

        switch kind {
        case .symlink:
            guard try symbolicLink(at: target, pointsTo: source) else {
                throw unmanagedTarget(target)
            }
        case .directory:
            let targetDigest = try directoryDigest(target, ignoringGitDirectories: false)
            if let expectedDigest = metadata.managedDigest, targetDigest != expectedDigest {
                throw unmanagedTarget(target)
            }
            if try SkillPathSafety.entryKind(at: source) == .directory {
                let sourceDigest = try directoryDigest(source, ignoringGitDirectories: true)
                guard sourceDigest == targetDigest else { throw unmanagedTarget(target) }
            } else if metadata.managedDigest == nil {
                throw SkillPathSafety.failure(
                    "Cannot verify legacy managed target while the central Skill is unavailable: \(target.path)"
                )
            }
        case .missing:
            return .missing
        case .file, .other:
            throw unmanagedTarget(target)
        }
        return .present(identity: identity)
    }

    func currentTargetState(at target: URL) throws -> SkillExpectedTargetState {
        switch try SkillPathSafety.entryKind(at: target) {
        case .missing:
            return .missing
        case .file, .directory, .symlink, .other:
            return .present(identity: try SkillPathSafety.entryIdentity(at: target))
        }
    }

    func availableID(root: URL, preferred: String) throws -> String {
        let base = slug(preferred)
        if try SkillPathSafety.entryKind(at: root.appendingPathComponent(base)) == .missing {
            return base
        }
        for suffix in 2..<10_000 {
            let candidate = "\(base)-\(suffix)"
            if try SkillPathSafety.entryKind(at: root.appendingPathComponent(candidate)) == .missing {
                return candidate
            }
        }
        return "\(base)-\(makeUUID().uuidString.lowercased())"
    }

    func prepareReplacement(
        source: URL,
        root: URL,
        target: URL,
        mode: SkillSyncMode,
        expectedState: SkillExpectedTargetState
    ) throws -> SkillFileSwap {
        guard target.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw SkillPathSafety.failure("Target is outside \(root.path)")
        }
        let source = try validateSource(source)
        let stage = try SkillPathSafety.uniqueHidden(root: root, kind: "sync-stage", makeUUID: makeUUID)
        let backup = try SkillPathSafety.uniqueHidden(root: root, kind: "sync-backup", makeUUID: makeUUID)
        let actualMode: SkillSyncMode
        do {
            actualMode = try createStaged(source: source, stage: stage, mode: mode)
        } catch {
            throw error
        }
        let stagedIdentity = try SkillPathSafety.entryIdentity(at: stage)
        let installedOwnership: SkillTargetOwnership
        do {
            installedOwnership = try ownershipForInstalledTarget(
                source: source,
                target: stage,
                mode: actualMode
            )
            guard installedOwnership.identity == stagedIdentity else {
                throw SkillPathSafety.failure("Transaction stage identity changed")
            }
        } catch {
            try? removeOwnedEntry(root: root, child: stage, identity: stagedIdentity)
            throw error
        }
        do {
            try beforeMove(target)
            try validateExpectedState(expectedState, at: target)
        } catch {
            try? removeOwnedEntry(root: root, child: stage, identity: stagedIdentity)
            throw error
        }
        let replacedIdentity: String?
        switch expectedState {
        case .missing:
            replacedIdentity = nil
        case .present(let identity):
            replacedIdentity = identity
        }
        let hadTarget = replacedIdentity != nil
        if hadTarget {
            do {
                try fileManager.moveItem(at: target, to: backup)
                guard let replacedIdentity,
                      try SkillPathSafety.entryIdentity(at: backup) == replacedIdentity
                else {
                    throw SkillPathSafety.failure("Backed-up target identity changed: \(target.path)")
                }
            } catch {
                try? removeOwnedEntry(
                    root: root,
                    child: stage,
                    identity: installedOwnership.identity
                )
                throw SkillPathSafety.failure("Cannot back up target \(target.path): \(error.localizedDescription)")
            }
        }
        do {
            try fileManager.moveItem(at: stage, to: target)
        } catch {
            var restoreMessage = ""
            if let replacedIdentity {
                do {
                    try restoreBackup(
                        backup,
                        identity: replacedIdentity,
                        to: target
                    )
                } catch {
                    restoreMessage = "; restore failed: \(error.localizedDescription)"
                }
            }
            try? removeOwnedEntry(
                root: root,
                child: stage,
                identity: installedOwnership.identity
            )
            throw SkillPathSafety.failure(
                "Cannot replace target \(target.path): \(error.localizedDescription)\(restoreMessage)"
            )
        }
        do {
            try validateInstalledTarget(
                target: target,
                mode: actualMode,
                ownership: installedOwnership
            )
        } catch {
            throw SkillPathSafety.failure(
                "Installed target identity changed before transaction commit: \(target.path)"
            )
        }
        return SkillFileSwap(
            root: root,
            target: target,
            backup: hadTarget ? backup : nil,
            backupIdentity: replacedIdentity,
            removeCurrent: true,
            actualMode: actualMode,
            fileManager: fileManager,
            validateCurrent: {
                try validateInstalledTarget(
                    target: target,
                    mode: actualMode,
                    ownership: installedOwnership
                )
            }
        )
    }

    func prepareRemoval(
        root: URL,
        target: URL,
        expectedState: SkillExpectedTargetState
    ) throws -> SkillFileSwap? {
        guard target.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw SkillPathSafety.failure("Target is outside \(root.path)")
        }
        try beforeMove(target)
        try validateExpectedState(expectedState, at: target)
        guard case .present(let targetIdentity) = expectedState else { return nil }
        let backup = try SkillPathSafety.uniqueHidden(root: root, kind: "remove-backup", makeUUID: makeUUID)
        do {
            try fileManager.moveItem(at: target, to: backup)
            guard try SkillPathSafety.entryIdentity(at: backup) == targetIdentity else {
                throw SkillPathSafety.failure("Staged removal identity changed: \(target.path)")
            }
        } catch {
            throw SkillPathSafety.failure("Cannot stage removal \(target.path): \(error.localizedDescription)")
        }
        return SkillFileSwap(
            root: root,
            target: target,
            backup: backup,
            backupIdentity: targetIdentity,
            removeCurrent: false,
            actualMode: .copy,
            fileManager: fileManager
        )
    }

    private func createStaged(source: URL, stage: URL, mode: SkillSyncMode) throws -> SkillSyncMode {
        if mode == .copy {
            try createCopiedStage(source: source, stage: stage)
            return .copy
        }
        do {
            try fileManager.createSymbolicLink(at: stage, withDestinationURL: source)
            return .symlink
        } catch {
            guard mode == .auto else {
                throw SkillPathSafety.failure("Cannot create symbolic link \(stage.path): \(error.localizedDescription)")
            }
            guard try SkillPathSafety.entryKind(at: stage) == .missing else {
                throw SkillPathSafety.failure(
                    "Cannot safely reuse transaction stage after symbolic-link failure"
                )
            }
            try createCopiedStage(source: source, stage: stage)
            return .copy
        }
    }

    private func symbolicLink(at target: URL, pointsTo source: URL) throws -> Bool {
        let rawDestination = try fileManager.destinationOfSymbolicLink(atPath: target.path)
        let destination: URL
        if NSString(string: rawDestination).isAbsolutePath {
            destination = URL(fileURLWithPath: rawDestination)
        } else {
            destination = target.deletingLastPathComponent().appendingPathComponent(rawDestination)
        }
        let expected = source.standardizedFileURL
        let actual = destination.standardizedFileURL
        if try SkillPathSafety.entryKind(at: expected) == .directory {
            return actual.resolvingSymlinksInPath().standardizedFileURL
                == expected.resolvingSymlinksInPath().standardizedFileURL
        }
        return actual.path == expected.path
    }

    private func validateInstalledTarget(
        target: URL,
        mode: SkillSyncMode,
        ownership: SkillTargetOwnership
    ) throws {
        guard try SkillPathSafety.entryKind(at: target) != .missing,
              try SkillPathSafety.entryIdentity(at: target) == ownership.identity
        else {
            throw unmanagedTarget(target)
        }
        switch mode {
        case .copy:
            guard try SkillPathSafety.entryKind(at: target) == .directory,
                  let expectedDigest = ownership.digest,
                  try directoryDigest(target, ignoringGitDirectories: false) == expectedDigest
            else {
                throw unmanagedTarget(target)
            }
        case .symlink:
            guard try SkillPathSafety.entryKind(at: target) == .symlink else {
                throw unmanagedTarget(target)
            }
        case .auto:
            throw SkillPathSafety.failure("Managed target mode was not resolved")
        }
    }

    private func validateExpectedState(
        _ expectedState: SkillExpectedTargetState,
        at target: URL
    ) throws {
        guard try currentTargetState(at: target) == expectedState else {
            throw unmanagedTarget(target)
        }
    }

    private func removeOwnedEntry(root: URL, child: URL, identity: String) throws {
        guard try SkillPathSafety.entryIdentity(at: child) == identity else {
            throw SkillPathSafety.failure("Transaction entry identity changed: \(child.path)")
        }
        try SkillPathSafety.removeDirectChild(root: root, child: child, fileManager: fileManager)
    }

    private func restoreBackup(_ backup: URL, identity: String, to target: URL) throws {
        guard try SkillPathSafety.entryKind(at: target) == .missing,
              try SkillPathSafety.entryIdentity(at: backup) == identity
        else {
            throw SkillPathSafety.failure("Cannot safely restore target \(target.path)")
        }
        try fileManager.moveItem(at: backup, to: target)
        guard try SkillPathSafety.entryIdentity(at: target) == identity else {
            throw SkillPathSafety.failure("Restored target identity changed: \(target.path)")
        }
    }

    private func directoryDigest(_ root: URL, ignoringGitDirectories: Bool) throws -> String {
        guard try SkillPathSafety.entryKind(at: root) == .directory else {
            throw SkillPathSafety.failure("Managed target is not a real directory: \(root.path)")
        }
        var hasher = SHA256()
        var entries = 0
        var bytes: UInt64 = 0
        try updateDigest(
            root: root,
            directory: root,
            depth: 0,
            ignoringGitDirectories: ignoringGitDirectories,
            entries: &entries,
            bytes: &bytes,
            hasher: &hasher
        )
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateDigest(
        root: URL,
        directory: URL,
        depth: Int,
        ignoringGitDirectories: Bool,
        entries: inout Int,
        bytes: inout UInt64,
        hasher: inout SHA256
    ) throws {
        guard depth <= 64 else {
            throw SkillPathSafety.failure("Skill directory nesting is too deep")
        }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            if ignoringGitDirectories, child.lastPathComponent == ".git" { continue }
            entries += 1
            guard entries <= maximumEntries else {
                throw SkillPathSafety.failure("Skill contains too many files")
            }
            let relative = String(child.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            switch try SkillPathSafety.entryKind(at: child) {
            case .directory:
                hasher.update(data: digestHeader(kind: "directory", path: relative, size: nil))
                try updateDigest(
                    root: root,
                    directory: child,
                    depth: depth + 1,
                    ignoringGitDirectories: ignoringGitDirectories,
                    entries: &entries,
                    bytes: &bytes,
                    hasher: &hasher
                )
            case .file:
                let attributes = try fileManager.attributesOfItem(atPath: child.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let (total, overflow) = bytes.addingReportingOverflow(size)
                guard !overflow, total <= maximumBytes else {
                    throw SkillPathSafety.failure("Skill is larger than 512 MiB")
                }
                bytes = total
                hasher.update(data: digestHeader(kind: "file", path: relative, size: size))
                let handle = try FileHandle(forReadingFrom: child)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            case .symlink:
                throw SkillPathSafety.failure("Skill contains a symbolic link: \(child.path)")
            case .missing, .other:
                throw SkillPathSafety.failure("Skill contains an unsupported entry: \(child.path)")
            }
        }
    }

    private func digestHeader(kind: String, path: String, size: UInt64?) -> Data {
        Data("\(kind)\u{0}\(path.utf8.count)\u{0}\(path)\u{0}\(size.map(String.init) ?? "-")\u{0}".utf8)
    }

    private func unmanagedTarget(_ target: URL) -> SkillsServiceError {
        SkillPathSafety.failure(
            "Target changed outside CC Buddy and will not be replaced or removed: \(target.path)"
        )
    }

    private func createCopiedStage(source: URL, stage: URL) throws {
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        let identity = try SkillPathSafety.entryIdentity(at: stage)
        var entries = 0
        var bytes: UInt64 = 0
        do {
            try copyTree(
                source: source,
                destination: stage,
                depth: 0,
                entries: &entries,
                bytes: &bytes
            )
            _ = try validateSource(stage)
        } catch {
            try? removeOwnedEntry(
                root: stage.deletingLastPathComponent(),
                child: stage,
                identity: identity
            )
            throw error
        }
    }

    private func copyTree(
        source: URL,
        destination: URL,
        depth: Int,
        entries: inout Int,
        bytes: inout UInt64
    ) throws {
        guard depth <= 64 else {
            throw SkillPathSafety.failure("Skill directory nesting is too deep")
        }
        for entry in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            if entry.lastPathComponent == ".git" { continue }
            entries += 1
            guard entries <= maximumEntries else {
                throw SkillPathSafety.failure("Skill contains too many files")
            }
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            switch try SkillPathSafety.entryKind(at: entry) {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                try copyTree(
                    source: entry,
                    destination: target,
                    depth: depth + 1,
                    entries: &entries,
                    bytes: &bytes
                )
            case .file:
                let attributes = try fileManager.attributesOfItem(atPath: entry.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let (total, overflow) = bytes.addingReportingOverflow(size)
                guard !overflow, total <= maximumBytes else {
                    throw SkillPathSafety.failure("Skill is larger than 512 MiB")
                }
                bytes = total
                try fileManager.copyItem(at: entry, to: target)
            case .symlink:
                throw SkillPathSafety.failure("Skill contains a symbolic link: \(entry.path)")
            case .missing, .other:
                throw SkillPathSafety.failure("Skill contains an unsupported entry: \(entry.path)")
            }
        }
    }

    private func slug(_ value: String) -> String {
        var result = ""
        var needsSeparator = false
        for character in value {
            if character.isLetter || character.isNumber {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.append(contentsOf: String(character).lowercased())
                needsSeparator = false
            } else {
                needsSeparator = true
            }
            if result.count >= 72 { break }
        }
        if result.isEmpty { return "skill" }
        while result.utf8.count > 96 { result.removeLast() }
        return result
    }
}
