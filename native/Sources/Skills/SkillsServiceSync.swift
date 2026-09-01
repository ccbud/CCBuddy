import Foundation

private struct SkillSyncOutcome {
    var mode: SkillSyncMode
    var ownership: SkillTargetOwnership
}

enum SkillRecordedTargetValidation {
    case valid(SkillExpectedTargetState)
    case invalid
}

extension LiveSkillsService {
    func sync(id: String, toolKeys: [String], mode: SkillSyncMode) throws -> ManagedSkill {
        try withProcessLock { try syncLocked(id: id, toolKeys: toolKeys, mode: mode) }
    }

    private func syncLocked(id: String, toolKeys: [String], mode: SkillSyncMode) throws -> ManagedSkill {
        guard !toolKeys.isEmpty else {
            throw SkillPathSafety.failure("Select at least one target tool")
        }
        let root = try ensureRoot()
        let source = try SkillPathSafety.existingSkillDirectory(root: root, id: id)
        var index = try indexRepository.load(root: root)
        _ = try reconcile(root: root, index: &index)
        guard var metadata = index.skills[id] else {
            throw SkillPathSafety.failure("Skill not found: \(id)")
        }
        let keys = orderedUniqueKeys(toolKeys)
        try preflightTargets(source: source, id: id, keys: keys, targets: metadata.targets)
        var outcomes: [String: SkillSyncOutcome] = [:]
        let transaction = SkillFileTransaction()
        do {
            for key in keys {
                let targetRoot = try resolvedTargetRoot(key: key, create: true)
                let target = targetRoot.appendingPathComponent(id, isDirectory: true)
                let pathKey = target.standardizedFileURL.path
                let outcome: SkillSyncOutcome
                if let existing = outcomes[pathKey] {
                    outcome = existing
                } else {
                    let recorded = metadata.targets.filter {
                        $0.path.standardizedFileURL.path == target.standardizedFileURL.path
                    }
                    let expectedState = try validatedTargetState(
                        source: source,
                        target: target,
                        recorded: recorded
                    )
                    let swap = try transactions.prepareReplacement(
                        source: source,
                        root: targetRoot,
                        target: target,
                        mode: key == "cursor" ? .copy : mode,
                        expectedState: expectedState
                    )
                    transaction.append(swap)
                    let ownership = try transactions.ownershipForInstalledTarget(
                        source: source,
                        target: target,
                        mode: swap.actualMode
                    )
                    outcome = SkillSyncOutcome(mode: swap.actualMode, ownership: ownership)
                    outcomes[pathKey] = outcome
                }
                for targetIndex in metadata.targets.indices where
                    metadata.targets[targetIndex].path.standardizedFileURL.path == pathKey
                {
                    metadata.targets[targetIndex].path = target
                    metadata.targets[targetIndex].syncMode = outcome.mode
                    metadata.targets[targetIndex].status = "ok"
                    metadata.targets[targetIndex].managedIdentity = outcome.ownership.identity
                    metadata.targets[targetIndex].managedDigest = outcome.ownership.digest
                }
                metadata.targets.removeAll { $0.key == key }
                metadata.targets.append(SkillTarget(
                    key: key,
                    path: target,
                    syncMode: outcome.mode,
                    status: "ok",
                    managedIdentity: outcome.ownership.identity,
                    managedDigest: outcome.ownership.digest
                ))
            }
            metadata.targets.sort { $0.key < $1.key }
            index.skills[id] = metadata
            try indexRepository.save(root: root, document: index)
        } catch {
            throw rollbackError(transaction, original: error)
        }
        transaction.commit()
        return try makeSkill(id: id, root: root, index: index)
    }

    func unsync(id: String, toolKeys: [String]) throws -> ManagedSkill {
        try withProcessLock { try unsyncLocked(id: id, toolKeys: toolKeys) }
    }

    private func unsyncLocked(id: String, toolKeys: [String]) throws -> ManagedSkill {
        let root = try ensureRoot()
        var index = try indexRepository.load(root: root)
        _ = try reconcile(root: root, index: &index)
        guard var metadata = index.skills[id] else {
            throw SkillPathSafety.failure("Skill not found: \(id)")
        }
        let wanted = Set(toolKeys)
        for key in wanted where SkillToolCatalog.spec(for: key) == nil {
            throw SkillPathSafety.failure("Unknown skill tool: \(key)")
        }
        let removed = metadata.targets.filter { wanted.contains($0.key) }
        let remaining = metadata.targets.filter { !wanted.contains($0.key) }
        let transaction = SkillFileTransaction()
        var seen = Set<String>()
        do {
            for target in removed {
                let path = target.path.standardizedFileURL.path
                if remaining.contains(where: { $0.path.standardizedFileURL.path == path }) || !seen.insert(path).inserted {
                    continue
                }
                for recorded in removed where recorded.path.standardizedFileURL.path == path {
                    _ = try validateRecordedTarget(
                        source: root.appendingPathComponent(id, isDirectory: true),
                        id: id,
                        target: recorded
                    )
                }
                if let swap = try prepareRecordedRemoval(
                    source: root.appendingPathComponent(id, isDirectory: true),
                    id: id,
                    target: target
                ) {
                    transaction.append(swap)
                }
            }
            metadata.targets = remaining
            index.skills[id] = metadata
            try indexRepository.save(root: root, document: index)
        } catch {
            throw rollbackError(transaction, original: error)
        }
        transaction.commit()
        return try makeSkill(id: id, root: root, index: index)
    }

    func remove(id: String) throws -> Bool {
        try withProcessLock { try removeLocked(id: id) }
    }

    private func removeLocked(id: String) throws -> Bool {
        let root = try ensureRoot()
        try SkillPathSafety.validateID(id)
        var index = try indexRepository.load(root: root)
        _ = try reconcile(root: root, index: &index)
        let central = root.appendingPathComponent(id, isDirectory: true)
        let existed = try SkillPathSafety.entryKind(at: central) != .missing || index.skills[id] != nil
        let targets = index.skills[id]?.targets ?? []
        let transaction = SkillFileTransaction()
        do {
            var seen = Set<String>()
            for target in targets where seen.insert(target.path.standardizedFileURL.path).inserted {
                let path = target.path.standardizedFileURL.path
                for recorded in targets where recorded.path.standardizedFileURL.path == path {
                    _ = try validateRecordedTarget(source: central, id: id, target: recorded)
                }
                if let swap = try prepareRecordedRemoval(source: central, id: id, target: target) {
                    transaction.append(swap)
                }
            }
            let centralExpectedState = try transactions.currentTargetState(at: central)
            if let swap = try transactions.prepareRemoval(
                root: root,
                target: central,
                expectedState: centralExpectedState
            ) {
                transaction.append(swap)
            }
            index.skills.removeValue(forKey: id)
            try indexRepository.save(root: root, document: index)
        } catch {
            throw rollbackError(transaction, original: error)
        }
        transaction.commit()
        return existed
    }

    func resyncAll(
        source: URL,
        id: String,
        targets: inout [SkillTarget],
        validatedPaths: [String: SkillRecordedTargetValidation]
    ) -> SkillFileTransaction {
        let transaction = SkillFileTransaction()
        var outcomes: [String: Result<SkillSyncOutcome, SkillsServiceError>] = [:]
        for index in targets.indices {
            let path = targets[index].path.standardizedFileURL.path
            if outcomes[path] == nil {
                guard case .valid(let expectedState)? = validatedPaths[path] else {
                    outcomes[path] = .failure(SkillPathSafety.failure("Managed target ownership changed"))
                    targets[index].status = "error"
                    continue
                }
                do {
                    let swap = try prepareRecordedReplacement(
                        source: source,
                        id: id,
                        target: targets[index],
                        expectedState: expectedState
                    )
                    let ownership: SkillTargetOwnership
                    do {
                        ownership = try transactions.ownershipForInstalledTarget(
                            source: source,
                            target: targets[index].path,
                            mode: swap.actualMode
                        )
                    } catch {
                        try? swap.rollback()
                        throw error
                    }
                    transaction.append(swap)
                    outcomes[path] = .success(SkillSyncOutcome(
                        mode: swap.actualMode,
                        ownership: ownership
                    ))
                } catch {
                    outcomes[path] = .failure(SkillPathSafety.failure(skillErrorMessage(error)))
                }
            }
            switch outcomes[path] {
            case .success(let outcome):
                targets[index].syncMode = outcome.mode
                targets[index].status = "ok"
                targets[index].managedIdentity = outcome.ownership.identity
                targets[index].managedDigest = outcome.ownership.digest
            case .failure:
                targets[index].status = "error"
            case nil:
                targets[index].status = "error"
            }
        }
        return transaction
    }

    func validateTargetsBeforeUpdate(
        source: URL,
        id: String,
        targets: [SkillTarget]
    ) -> [String: SkillRecordedTargetValidation] {
        var result: [String: SkillRecordedTargetValidation] = [:]
        for target in targets {
            let path = target.path.standardizedFileURL.path
            if case .invalid? = result[path] { continue }
            do {
                let state = try validateRecordedTarget(source: source, id: id, target: target)
                if case .valid(let existing)? = result[path], existing != state {
                    result[path] = .invalid
                } else {
                    result[path] = .valid(state)
                }
            } catch {
                result[path] = .invalid
            }
        }
        return result
    }

    private func orderedUniqueKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        let values = keys.filter { seen.insert($0).inserted }
        return values.contains("cursor")
            ? ["cursor"] + values.filter { $0 != "cursor" }
            : values
    }

    private func preflightTargets(
        source: URL,
        id: String,
        keys: [String],
        targets: [SkillTarget]
    ) throws {
        for key in keys {
            let root = try resolvedTargetRoot(key: key, create: false)
            let target = root.appendingPathComponent(id, isDirectory: true)
            let recorded = targets.filter {
                $0.path.standardizedFileURL.path == target.standardizedFileURL.path
            }
            if try SkillPathSafety.entryKind(at: target) != .missing {
                guard !recorded.isEmpty else {
                    throw SkillPathSafety.failure("Target already exists and is unmanaged: \(target.path)")
                }
                _ = try validatedTargetState(source: source, target: target, recorded: recorded)
            }
        }
    }

    private func resolvedTargetRoot(key: String, create: Bool) throws -> URL {
        guard let spec = SkillToolCatalog.spec(for: key) else {
            throw SkillPathSafety.failure("Unknown skill tool: \(key)")
        }
        guard userHome.isFileURL, NSString(string: userHome.path).isAbsolutePath else {
            throw SkillPathSafety.failure("User home must be an absolute path")
        }
        let requested = userHome.appendingPathComponent(spec.skillsPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: requested.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SkillPathSafety.failure("Tool skills path is not a directory: \(requested.path)")
            }
            let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
            guard try SkillPathSafety.entryKind(at: resolved) == .directory else {
                throw SkillPathSafety.failure("Tool skills path is not a real directory: \(requested.path)")
            }
            return resolved
        }
        guard try SkillPathSafety.entryKind(at: requested) == .missing else {
            throw SkillPathSafety.failure("Tool skills path is invalid: \(requested.path)")
        }
        if create {
            try fileManager.createDirectory(at: requested, withIntermediateDirectories: true)
            let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
            guard try SkillPathSafety.entryKind(at: resolved) == .directory else {
                throw SkillPathSafety.failure("Cannot create tool skills directory: \(requested.path)")
            }
            return resolved
        }
        return requested.resolvingSymlinksInPath().standardizedFileURL
    }

    private func prepareRecordedReplacement(
        source: URL,
        id: String,
        target: SkillTarget,
        expectedState: SkillExpectedTargetState
    ) throws -> SkillFileSwap {
        let expectedBeforeCreation = try resolvedTargetRoot(key: target.key, create: false)
            .appendingPathComponent(id, isDirectory: true)
        guard expectedBeforeCreation.standardizedFileURL.path == target.path.standardizedFileURL.path else {
            throw SkillPathSafety.failure("Refusing unsafe recorded target: \(target.path.path)")
        }
        let root = try resolvedTargetRoot(key: target.key, create: true)
        let expected = root.appendingPathComponent(id, isDirectory: true)
        guard expected.standardizedFileURL.path == target.path.standardizedFileURL.path else {
            throw SkillPathSafety.failure("Refusing unsafe recorded target: \(target.path.path)")
        }
        return try transactions.prepareReplacement(
            source: source,
            root: root,
            target: expected,
            mode: target.key == "cursor" ? .copy : target.syncMode,
            expectedState: expectedState
        )
    }

    private func validateRecordedTarget(
        source: URL,
        id: String,
        target: SkillTarget
    ) throws -> SkillExpectedTargetState {
        let root = try resolvedTargetRoot(key: target.key, create: false)
        let expected = root.appendingPathComponent(id, isDirectory: true)
        guard expected.standardizedFileURL.path == target.path.standardizedFileURL.path else {
            throw SkillPathSafety.failure("Refusing unsafe recorded target: \(target.path.path)")
        }
        return try transactions.validateManagedTarget(
            source: source,
            target: expected,
            metadata: target
        )
    }

    private func prepareRecordedRemoval(
        source: URL,
        id: String,
        target: SkillTarget
    ) throws -> SkillFileSwap? {
        let root = try resolvedTargetRoot(key: target.key, create: false)
        let expected = root.appendingPathComponent(id, isDirectory: true)
        guard expected.standardizedFileURL.path == target.path.standardizedFileURL.path else {
            throw SkillPathSafety.failure("Refusing unsafe recorded target: \(target.path.path)")
        }
        let expectedState = try transactions.validateManagedTarget(
            source: source,
            target: expected,
            metadata: target
        )
        return try transactions.prepareRemoval(
            root: root,
            target: expected,
            expectedState: expectedState
        )
    }

    private func validatedTargetState(
        source: URL,
        target: URL,
        recorded: [SkillTarget]
    ) throws -> SkillExpectedTargetState {
        guard !recorded.isEmpty else {
            let state = try transactions.currentTargetState(at: target)
            guard state == .missing else {
                throw SkillPathSafety.failure("Target already exists and is unmanaged: \(target.path)")
            }
            return state
        }
        var expectedState: SkillExpectedTargetState?
        for item in recorded {
            let state = try transactions.validateManagedTarget(
                source: source,
                target: target,
                metadata: item
            )
            if let expectedState, expectedState != state {
                throw SkillPathSafety.failure("Managed target ownership proofs disagree: \(target.path)")
            }
            expectedState = state
        }
        return expectedState ?? .missing
    }
}
