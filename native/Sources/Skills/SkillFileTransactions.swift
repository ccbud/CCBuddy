import CryptoKit
import Darwin
import Foundation

private func moveSkillEntryExclusively(from source: URL, to destination: URL) throws {
    guard Darwin.renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct SkillTargetOwnership: Equatable {
    var identity: String
    var digest: String?
}

struct SkillTargetFingerprint: Equatable {
    var identity: String
    var kind: String
    var contentDigest: String

    var token: String {
        let value = Data("\(identity)\u{0}\(kind)\u{0}\(contentDigest)".utf8)
        return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

enum SkillExpectedTargetState: Equatable {
    case missing
    case present(SkillTargetFingerprint)
}

final class SkillFileSwap {
    let actualMode: SkillSyncMode

    private let root: URL
    private let target: URL
    private let fileManager: FileManager
    private var backup: URL?
    private var backupIdentity: String?
    private let commitCleanupQuarantine: URL?
    private let rollbackQuarantine: URL?
    private let removeCurrent: Bool
    private let validateBackup: ((URL) throws -> Void)?
    private let validateCurrent: ((URL) throws -> Void)?
    private let validateRestored: (() throws -> Void)?
    private var rolledBack = false

    init(
        root: URL,
        target: URL,
        backup: URL?,
        backupIdentity: String? = nil,
        commitCleanupQuarantine: URL? = nil,
        rollbackQuarantine: URL? = nil,
        removeCurrent: Bool,
        actualMode: SkillSyncMode,
        fileManager: FileManager,
        validateBackup: ((URL) throws -> Void)? = nil,
        validateCurrent: ((URL) throws -> Void)? = nil,
        validateRestored: (() throws -> Void)? = nil
    ) {
        self.root = root
        self.target = target
        self.backup = backup
        self.backupIdentity = backupIdentity
        self.commitCleanupQuarantine = commitCleanupQuarantine
        self.rollbackQuarantine = rollbackQuarantine
        self.removeCurrent = removeCurrent
        self.actualMode = actualMode
        self.fileManager = fileManager
        self.validateBackup = validateBackup
        self.validateCurrent = validateCurrent
        self.validateRestored = validateRestored
    }

    func validateCommit() throws {
        if let backup {
            guard let backupIdentity,
                  try SkillPathSafety.entryIdentity(at: backup) == backupIdentity
            else {
                throw SkillPathSafety.failure("Backup changed before commit: \(backup.path)")
            }
            try validateBackup?(backup)
        }
        if removeCurrent {
            guard let validateCurrent else {
                throw SkillPathSafety.failure("Cannot verify target before commit: \(target.path)")
            }
            try validateCurrent(target)
        } else if try SkillPathSafety.entryKind(at: target) != .missing {
            throw SkillPathSafety.failure("Target reappeared before commit: \(target.path)")
        }
    }

    func finalizeCommit() {
        guard let backup,
              let backupIdentity,
              let commitCleanupQuarantine
        else { return }
        do {
            try moveSkillEntryExclusively(from: backup, to: commitCleanupQuarantine)
        } catch {
            return
        }

        do {
            guard try SkillPathSafety.entryIdentity(at: commitCleanupQuarantine) == backupIdentity else {
                throw SkillPathSafety.failure(
                    "Backup changed before cleanup: \(commitCleanupQuarantine.path)"
                )
            }
            try validateBackup?(commitCleanupQuarantine)
        } catch {
            try? moveSkillEntryExclusively(from: commitCleanupQuarantine, to: backup)
            return
        }

        do {
            guard try SkillPathSafety.entryIdentity(at: commitCleanupQuarantine) == backupIdentity else {
                return
            }
            try SkillPathSafety.removeDirectChild(
                root: root,
                child: commitCleanupQuarantine,
                fileManager: fileManager
            )
            self.backup = nil
            self.backupIdentity = nil
        } catch {
            // The file transaction is already committed. Preserve the quarantined backup when
            // cleanup cannot be proven safe instead of attempting an incomplete rollback.
        }
    }

    func rollback() throws {
        guard !rolledBack else { return }
        if let backup {
            guard let backupIdentity,
                  try SkillPathSafety.entryIdentity(at: backup) == backupIdentity
            else {
                throw SkillPathSafety.failure("Backup changed before rollback: \(backup.path)")
            }
            try validateBackup?(backup)
        }
        var quarantinedCurrent: (url: URL, identity: String)?
        if removeCurrent {
            guard let validateCurrent, let rollbackQuarantine else {
                throw SkillPathSafety.failure("Cannot verify target before rollback: \(target.path)")
            }
            var movedToQuarantine = false
            do {
                try moveSkillEntryExclusively(from: target, to: rollbackQuarantine)
                movedToQuarantine = true
                let identity = try SkillPathSafety.entryIdentity(at: rollbackQuarantine)
                quarantinedCurrent = (rollbackQuarantine, identity)
                try validateCurrent(rollbackQuarantine)
            } catch {
                let originalError = error
                if movedToQuarantine {
                    do {
                        try moveSkillEntryExclusively(
                            from: rollbackQuarantine,
                            to: target
                        )
                    } catch {
                        throw SkillPathSafety.failure(
                            "\(skillErrorMessage(originalError)); cannot restore changed target: "
                                + skillErrorMessage(error)
                        )
                    }
                }
                throw originalError
            }
        } else if try SkillPathSafety.entryKind(at: target) != .missing {
            throw SkillPathSafety.failure("Target reappeared during rollback: \(target.path)")
        }
        if let backup {
            let expectedIdentity = backupIdentity
            do {
                try moveSkillEntryExclusively(from: backup, to: target)
                guard let expectedIdentity,
                      try SkillPathSafety.entryIdentity(at: target) == expectedIdentity
                else {
                    throw SkillPathSafety.failure("Restored target identity changed: \(target.path)")
                }
                try validateRestored?()
                self.backup = nil
                backupIdentity = nil
            } catch {
                throw SkillPathSafety.failure("Cannot restore target \(target.path): \(error.localizedDescription)")
            }
        }
        if let quarantinedCurrent {
            guard try SkillPathSafety.entryIdentity(at: quarantinedCurrent.url)
                == quarantinedCurrent.identity
            else {
                throw SkillPathSafety.failure(
                    "Rollback quarantine changed: \(quarantinedCurrent.url.path)"
                )
            }
            try SkillPathSafety.removeDirectChild(
                root: root,
                child: quarantinedCurrent.url,
                fileManager: fileManager
            )
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

    func validateCommit() throws {
        for swap in swaps { try swap.validateCommit() }
    }

    func finalizeCommit() {
        swaps.forEach { $0.finalizeCommit() }
        finished = true
    }

    func commit() throws {
        try validateCommit()
        finalizeCommit()
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
        let fingerprint = try targetFingerprint(at: target)
        guard fingerprint.identity == identity else { throw unmanagedTarget(target) }
        return .present(fingerprint)
    }

    func currentTargetState(at target: URL) throws -> SkillExpectedTargetState {
        switch try SkillPathSafety.entryKind(at: target) {
        case .missing:
            return .missing
        case .file, .directory, .symlink:
            return .present(try targetFingerprint(at: target))
        case .other:
            throw SkillPathSafety.failure("Target has an unsupported filesystem type: \(target.path)")
        }
    }

    func fingerprintToken(for state: SkillExpectedTargetState) -> String? {
        guard case .present(let fingerprint) = state else { return nil }
        return fingerprint.token
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
        let commitCleanupQuarantine = try SkillPathSafety.uniqueHidden(
            root: root,
            kind: "commit-cleanup",
            makeUUID: makeUUID
        )
        let rollbackQuarantine = try SkillPathSafety.uniqueHidden(
            root: root,
            kind: "rollback-current",
            makeUUID: makeUUID
        )
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
            try validateExpectedState(expectedState, at: target)
            try beforeMove(target)
        } catch {
            try? removeOwnedEntry(root: root, child: stage, identity: stagedIdentity)
            throw error
        }
        let replacedFingerprint: SkillTargetFingerprint?
        switch expectedState {
        case .missing:
            replacedFingerprint = nil
        case .present(let fingerprint):
            replacedFingerprint = fingerprint
        }
        let replacedIdentity = replacedFingerprint?.identity
        let hadTarget = replacedFingerprint != nil
        if hadTarget {
            var movedToBackup = false
            var movedBackupIdentity: String?
            do {
                try moveSkillEntryExclusively(from: target, to: backup)
                movedToBackup = true
                movedBackupIdentity = try SkillPathSafety.entryIdentity(at: backup)
                try validateExpectedState(expectedState, at: backup)
            } catch {
                let originalMessage = error.localizedDescription
                var restoreMessage = ""
                if movedToBackup {
                    do {
                        guard let movedBackupIdentity else {
                            throw SkillPathSafety.failure("Cannot identify the moved target")
                        }
                        try restoreMovedEntry(
                            backup,
                            identity: movedBackupIdentity,
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
                    "Cannot back up target \(target.path): \(originalMessage)\(restoreMessage)"
                )
            }
        }
        do {
            try moveSkillEntryExclusively(from: stage, to: target)
        } catch {
            var restoreMessage = ""
            if replacedFingerprint != nil {
                do {
                    try restoreBackup(
                        backup,
                        expectedState: expectedState,
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
            commitCleanupQuarantine: hadTarget ? commitCleanupQuarantine : nil,
            rollbackQuarantine: rollbackQuarantine,
            removeCurrent: true,
            actualMode: actualMode,
            fileManager: fileManager,
            validateBackup: replacedFingerprint == nil ? nil : { candidate in
                try validateExpectedState(expectedState, at: candidate)
            },
            validateCurrent: { candidate in
                try validateInstalledTarget(
                    target: candidate,
                    mode: actualMode,
                    ownership: installedOwnership
                )
            },
            validateRestored: replacedFingerprint == nil ? nil : {
                try validateExpectedState(expectedState, at: target)
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
        try validateExpectedState(expectedState, at: target)
        try beforeMove(target)
        guard case .present(let targetFingerprint) = expectedState else { return nil }
        let backup = try SkillPathSafety.uniqueHidden(root: root, kind: "remove-backup", makeUUID: makeUUID)
        let commitCleanupQuarantine = try SkillPathSafety.uniqueHidden(
            root: root,
            kind: "commit-cleanup",
            makeUUID: makeUUID
        )
        var movedToBackup = false
        var movedBackupIdentity: String?
        do {
            try moveSkillEntryExclusively(from: target, to: backup)
            movedToBackup = true
            movedBackupIdentity = try SkillPathSafety.entryIdentity(at: backup)
            try validateExpectedState(expectedState, at: backup)
        } catch {
            let originalMessage = error.localizedDescription
            var restoreMessage = ""
            if movedToBackup {
                do {
                    guard let movedBackupIdentity else {
                        throw SkillPathSafety.failure("Cannot identify the moved target")
                    }
                    try restoreMovedEntry(
                        backup,
                        identity: movedBackupIdentity,
                        to: target
                    )
                } catch {
                    restoreMessage = "; restore failed: \(error.localizedDescription)"
                }
            }
            throw SkillPathSafety.failure(
                "Cannot stage removal \(target.path): \(originalMessage)\(restoreMessage)"
            )
        }
        return SkillFileSwap(
            root: root,
            target: target,
            backup: backup,
            backupIdentity: targetFingerprint.identity,
            commitCleanupQuarantine: commitCleanupQuarantine,
            removeCurrent: false,
            actualMode: .copy,
            fileManager: fileManager,
            validateBackup: { candidate in
                try validateExpectedState(expectedState, at: candidate)
            },
            validateRestored: {
                try validateExpectedState(expectedState, at: target)
            }
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

    private func restoreBackup(
        _ backup: URL,
        expectedState: SkillExpectedTargetState,
        to target: URL
    ) throws {
        guard try SkillPathSafety.entryKind(at: target) == .missing,
              case .present = expectedState
        else {
            throw SkillPathSafety.failure("Cannot safely restore target \(target.path)")
        }
        try validateExpectedState(expectedState, at: backup)
        try moveSkillEntryExclusively(from: backup, to: target)
        try validateExpectedState(expectedState, at: target)
    }

    private func restoreMovedEntry(_ backup: URL, identity: String, to target: URL) throws {
        let backupParent = backup.deletingLastPathComponent().standardizedFileURL
        let targetParent = target.deletingLastPathComponent().standardizedFileURL
        guard backupParent == targetParent,
              try SkillPathSafety.entryKind(at: target) == .missing,
              try SkillPathSafety.entryIdentity(at: backup) == identity
        else {
            throw SkillPathSafety.failure("Cannot safely restore moved target \(target.path)")
        }
        try moveSkillEntryExclusively(from: backup, to: target)
        guard try SkillPathSafety.entryIdentity(at: target) == identity else {
            throw SkillPathSafety.failure("Restored target identity changed: \(target.path)")
        }
    }

    private func targetFingerprint(at target: URL) throws -> SkillTargetFingerprint {
        let kind = try SkillPathSafety.entryKind(at: target)
        guard kind == .directory || kind == .file || kind == .symlink else {
            throw SkillPathSafety.failure("Target cannot be safely fingerprinted: \(target.path)")
        }
        let identity = try SkillPathSafety.entryIdentity(at: target)
        let kindName: String
        let contentDigest: String
        switch kind {
        case .directory:
            kindName = "directory"
            contentDigest = try directoryFingerprintDigest(target)
        case .file:
            kindName = "file"
            contentDigest = try fileFingerprintDigest(target)
        case .symlink:
            kindName = "symlink"
            let destination = try fileManager.destinationOfSymbolicLink(atPath: target.path)
            contentDigest = digest(Data(destination.utf8))
        case .missing, .other:
            throw SkillPathSafety.failure("Target cannot be safely fingerprinted: \(target.path)")
        }
        guard try SkillPathSafety.entryKind(at: target) == kind,
              try SkillPathSafety.entryIdentity(at: target) == identity
        else {
            throw unmanagedTarget(target)
        }
        return SkillTargetFingerprint(
            identity: identity,
            kind: kindName,
            contentDigest: contentDigest
        )
    }

    private func directoryFingerprintDigest(_ root: URL) throws -> String {
        guard try SkillPathSafety.entryKind(at: root) == .directory else {
            throw SkillPathSafety.failure("Target is not a real directory: \(root.path)")
        }
        var hasher = SHA256()
        var entries = 0
        var bytes: UInt64 = 0
        try updateFingerprintDigest(
            root: root,
            directory: root,
            depth: 0,
            entries: &entries,
            bytes: &bytes,
            hasher: &hasher
        )
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateFingerprintDigest(
        root: URL,
        directory: URL,
        depth: Int,
        entries: inout Int,
        bytes: inout UInt64,
        hasher: inout SHA256
    ) throws {
        guard depth <= 64 else {
            throw SkillPathSafety.failure("Target directory nesting is too deep")
        }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            entries += 1
            guard entries <= maximumEntries else {
                throw SkillPathSafety.failure("Target contains too many files")
            }
            let relative = String(
                child.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
            )
            let kind = try SkillPathSafety.entryKind(at: child)
            let identity = try SkillPathSafety.entryIdentity(at: child)
            switch kind {
            case .directory:
                hasher.update(data: digestHeader(kind: "directory", path: relative, size: nil))
                try updateFingerprintDigest(
                    root: root,
                    directory: child,
                    depth: depth + 1,
                    entries: &entries,
                    bytes: &bytes,
                    hasher: &hasher
                )
            case .file:
                let attributes = try fileManager.attributesOfItem(atPath: child.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let (total, overflow) = bytes.addingReportingOverflow(size)
                guard !overflow, total <= maximumBytes else {
                    throw SkillPathSafety.failure("Target is larger than 512 MiB")
                }
                bytes = total
                hasher.update(data: digestHeader(kind: "file", path: relative, size: size))
                try updateFileBytes(child, hasher: &hasher)
            case .symlink:
                let destination = try fileManager.destinationOfSymbolicLink(atPath: child.path)
                let data = Data(destination.utf8)
                let (total, overflow) = bytes.addingReportingOverflow(UInt64(data.count))
                guard !overflow, total <= maximumBytes else {
                    throw SkillPathSafety.failure("Target is larger than 512 MiB")
                }
                bytes = total
                hasher.update(data: digestHeader(
                    kind: "symlink",
                    path: relative,
                    size: UInt64(data.count)
                ))
                hasher.update(data: data)
            case .missing, .other:
                throw SkillPathSafety.failure("Target contains an unsupported entry: \(child.path)")
            }
            guard try SkillPathSafety.entryKind(at: child) == kind,
                  try SkillPathSafety.entryIdentity(at: child) == identity
            else {
                throw unmanagedTarget(child)
            }
        }
    }

    private func fileFingerprintDigest(_ file: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= maximumBytes else {
            throw SkillPathSafety.failure("Target is larger than 512 MiB")
        }
        var hasher = SHA256()
        hasher.update(data: digestHeader(kind: "file", path: "", size: size))
        try updateFileBytes(file, hasher: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateFileBytes(_ file: URL, hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
