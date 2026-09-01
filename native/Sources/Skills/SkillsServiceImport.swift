import Foundation

extension LiveSkillsService {
    func importLocal(from source: URL) throws -> ManagedSkill {
        try withProcessLock { try importLocalLocked(from: source) }
    }

    private func importLocalLocked(from source: URL) throws -> ManagedSkill {
        let root = try ensureRoot()
        let source = try transactions.validateSource(source)
        var index = try indexRepository.load(root: root)
        _ = try reconcile(root: root, index: &index)
        if let existingID = index.skills.keys.sorted().first(where: { id in
            guard let entry = index.skills[id],
                  entry.sourceType == "local",
                  entry.sourceReference == source.path
            else { return false }
            return (try? SkillPathSafety.entryKind(at: root.appendingPathComponent(id))) == .directory
        }) {
            return try makeSkill(id: existingID, root: root, index: index)
        }
        let summary = try scanner.manifestSummary(in: source)
        let id = try transactions.availableID(root: root, preferred: summary.name)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        let transaction = SkillFileTransaction()
        transaction.append(try transactions.prepareReplacement(
            source: source,
            root: root,
            target: destination,
            mode: .copy,
            expectedState: .missing
        ))
        index.skills[id] = SkillIndexEntry(
            sourceReference: source.path,
            updatedAtMilliseconds: scanner.modifiedMilliseconds(
                at: destination.appendingPathComponent("SKILL.md"),
                now: now
            )
        )
        do {
            try indexRepository.save(root: root, document: index)
        } catch {
            throw rollbackError(transaction, original: error)
        }
        transaction.commit()
        return try makeSkill(id: id, root: root, index: index)
    }

    func importGit(from source: String) throws -> [ManagedSkill] {
        try withProcessLock { try importGitLocked(from: source) }
    }

    private func importGitLocked(from source: String) throws -> [ManagedSkill] {
        let root = try ensureRoot()
        let source = try git.validateURL(source)
        let checkout = try git.cloneShallow(root: root, source: source)
        defer {
            try? SkillPathSafety.removeDirectChild(
                root: root,
                child: checkout.directory,
                fileManager: fileManager
            )
        }
        let candidates = try scanner.localCandidates(at: checkout.directory)
        guard !candidates.isEmpty else {
            throw SkillPathSafety.failure("Git repository does not contain SKILL.md")
        }
        var index = try indexRepository.load(root: root)
        _ = try reconcile(root: root, index: &index)
        let transaction = SkillFileTransaction()
        var ids: [String] = []
        do {
            for candidate in candidates {
                let subdirectory = try relativeSubdirectory(root: checkout.directory, child: candidate.path)
                if let existingID = index.skills.keys.sorted().first(where: { id in
                    guard let entry = index.skills[id],
                          entry.sourceType == "git",
                          entry.sourceReference == source,
                          entry.sourceSubdirectory == subdirectory
                    else { return false }
                    return (try? SkillPathSafety.entryKind(at: root.appendingPathComponent(id))) == .directory
                }) {
                    ids.append(existingID)
                    continue
                }
                let id = try transactions.availableID(root: root, preferred: candidate.name)
                let destination = root.appendingPathComponent(id, isDirectory: true)
                transaction.append(try transactions.prepareReplacement(
                    source: candidate.path,
                    root: root,
                    target: destination,
                    mode: .copy,
                    expectedState: .missing
                ))
                index.skills[id] = SkillIndexEntry(
                    sourceType: "git",
                    sourceReference: source,
                    sourceSubdirectory: subdirectory,
                    sourceRevision: checkout.revision,
                    updatedAtMilliseconds: scanner.modifiedMilliseconds(
                        at: destination.appendingPathComponent("SKILL.md"),
                        now: now
                    )
                )
                ids.append(id)
            }
            try indexRepository.save(root: root, document: index)
        } catch {
            throw rollbackError(transaction, original: error)
        }
        transaction.commit()
        return try ids.map { try makeSkill(id: $0, root: root, index: index) }
    }

    func update(id: String) throws -> ManagedSkill {
        try withProcessLock { try updateLocked(id: id) }
    }

    private func updateLocked(id: String) throws -> ManagedSkill {
        let root = try ensureRoot()
        try SkillPathSafety.validateID(id)
        var index = try indexRepository.load(root: root)
        _ = try reconcile(root: root, index: &index)
        guard var metadata = index.skills[id] else {
            throw SkillPathSafety.failure("Skill not found: \(id)")
        }

        var checkout: SkillGitCheckout?
        defer {
            if let checkout {
                try? SkillPathSafety.removeDirectChild(
                    root: root,
                    child: checkout.directory,
                    fileManager: fileManager
                )
            }
        }
        let source: URL
        switch metadata.sourceType {
        case "git":
            let value = try git.cloneShallow(root: root, source: metadata.sourceReference)
            checkout = value
            source = try gitSkillDirectory(
                checkout: value.directory,
                subdirectory: metadata.sourceSubdirectory
            )
        case "local":
            guard !metadata.sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkillPathSafety.failure("Local source_ref is empty")
            }
            guard NSString(string: metadata.sourceReference).isAbsolutePath else {
                throw SkillPathSafety.failure("Local source_ref must be an absolute path")
            }
            source = try transactions.validateSource(URL(fileURLWithPath: metadata.sourceReference))
            guard !SkillPathSafety.isInside(source, root: root) else {
                throw SkillPathSafety.failure("Managed copy has no external local source to update from")
            }
        default:
            throw SkillPathSafety.failure("Unsupported source_type: \(metadata.sourceType)")
        }
        if checkout != nil, try SkillPathSafety.entryKind(at: source) != .directory {
            throw SkillPathSafety.failure("Git skill source must be a real directory")
        }
        let validatedSource = try transactions.validateSource(source)
        if let checkout, !SkillPathSafety.isInside(validatedSource, root: checkout.directory) {
            throw SkillPathSafety.failure("Git skill escaped checkout directory")
        }
        let destination = root.appendingPathComponent(id, isDirectory: true)
        let validatedTargetPaths = validateTargetsBeforeUpdate(
            source: destination,
            id: id,
            targets: metadata.targets
        )
        let centralTransaction = SkillFileTransaction()
        let centralExpectedState = try transactions.currentTargetState(at: destination)
        centralTransaction.append(try transactions.prepareReplacement(
            source: validatedSource,
            root: root,
            target: destination,
            mode: .copy,
            expectedState: centralExpectedState
        ))
        if let checkout { metadata.sourceRevision = checkout.revision }
        metadata.updatedAtMilliseconds = scanner.modifiedMilliseconds(
            at: destination.appendingPathComponent("SKILL.md"),
            now: now
        )
        metadata.status = "ok"
        let targetTransaction = resyncAll(
            source: destination,
            id: id,
            targets: &metadata.targets,
            validatedPaths: validatedTargetPaths
        )
        index.skills[id] = metadata
        do {
            try indexRepository.save(root: root, document: index)
        } catch {
            var message = skillErrorMessage(error)
            do { try targetTransaction.rollback() } catch {
                message += "; target rollback failed: \(skillErrorMessage(error))"
            }
            do { try centralTransaction.rollback() } catch {
                message += "; central rollback failed: \(skillErrorMessage(error))"
            }
            throw SkillPathSafety.failure(message)
        }
        targetTransaction.commit()
        centralTransaction.commit()
        return try makeSkill(id: id, root: root, index: index)
    }

    func rollbackError(_ transaction: SkillFileTransaction, original: Error) -> SkillsServiceError {
        var message = skillErrorMessage(original)
        do {
            try transaction.rollback()
        } catch {
            message += "; rollback failed: \(skillErrorMessage(error))"
        }
        return SkillPathSafety.failure(message)
    }

    private func relativeSubdirectory(root: URL, child: URL) throws -> String {
        let root = root.standardizedFileURL.path
        let child = child.standardizedFileURL.path
        guard child == root || child.hasPrefix(root + "/") else {
            throw SkillPathSafety.failure("Git skill escaped checkout directory")
        }
        return child == root ? "" : String(child.dropFirst(root.count + 1))
    }

    private func gitSkillDirectory(checkout: URL, subdirectory: String) throws -> URL {
        if subdirectory.isEmpty { return checkout }
        guard !subdirectory.hasPrefix("/") else {
            throw SkillPathSafety.failure("Invalid Git skill subdirectory")
        }
        let pieces = subdirectory.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SkillPathSafety.failure("Invalid Git skill subdirectory")
        }
        var result = checkout
        pieces.forEach { result.appendPathComponent(String($0)) }
        guard SkillPathSafety.isInside(result, root: checkout) else {
            throw SkillPathSafety.failure("Invalid Git skill subdirectory")
        }
        return result
    }
}
