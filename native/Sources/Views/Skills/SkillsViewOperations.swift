import SwiftUI

extension SkillsView {
    var library: some View {
        SkillsLibraryView(
            snapshot: store.snapshot,
            busyIDs: store.busySkillIDs,
            globallyBusy: store.isBusy,
            query: $query,
            statusFilter: $statusFilter,
            tagFilter: $tagFilter,
            sortOrder: $sortOrder,
            displayMode: $displayMode,
            bulkMode: $bulkMode,
            selectedIDs: $selectedIDs,
            refresh: {
                batchErrorMessage = nil
                Task { await store.refresh() }
            },
            add: { page = .add },
            openDetail: openDetail,
            editTags: openTags,
            update: update,
            sync: { syncContext = SkillsSyncContext(skills: $0) },
            unsync: { unsync($0, keys: $0.targets.map(\.key)) },
            delete: { deleteContext = SkillsDeleteContext(skills: $0) }
        )
    }

    var add: some View {
        SkillsAddView(
            snapshot: store.snapshot,
            globallyBusy: store.isBusy,
            scanLocal: scanLocal,
            installGit: installGit,
            installLocal: installLocal,
            completed: {
                selectedIDs.removeAll()
                bulkMode = false
                page = .library
            }
        )
    }

    var tags: some View {
        SkillsTagsView(
            skills: store.snapshot.skills,
            globallyBusy: store.isBusy,
            viewTag: viewTag,
            createTag: createTag,
            renameTag: renameTag,
            deleteTag: deleteTag
        )
    }

    var tools: some View {
        SkillsToolsView(
            snapshot: store.snapshot,
            globallyBusy: store.isBusy,
            syncAll: { tool, skills in
                syncNow(skills, keys: [tool.key], mode: tool.defaultSyncMode)
            },
            unsyncAll: { tool, skills in
                unsyncBatch(skills, keys: [tool.key])
            }
        )
    }

    var updates: some View {
        SkillsUpdatesView(
            skills: store.snapshot.skills,
            globallyBusy: store.isBusy,
            busyIDs: store.busySkillIDs,
            checkUpdates: checkUpdates,
            updateSkills: updateSkills
        )
    }

    func clearDetail() {
        let deferredAction = deferredDetailAction
        deferredDetailAction = nil
        detailSelection = nil
        Task { await store.select(id: nil) }
        switch deferredAction {
        case .editTags(let skill):
            openTags([skill])
        case .delete(let skill):
            deleteContext = SkillsDeleteContext(skills: [skill])
        case nil:
            break
        }
    }

    func deferTagEditingFromDetail(_ skill: ManagedSkill) {
        deferredDetailAction = .editTags(skill)
        detailSelection = nil
    }

    func deferDeletionFromDetail(_ skill: ManagedSkill) {
        deferredDetailAction = .delete(skill)
        detailSelection = nil
    }

    func openTags(_ skills: [ManagedSkill]) {
        guard !skills.isEmpty else { return }
        tagsContext = SkillsTagsContext(skills: skills)
    }

    func update(_ skill: ManagedSkill) {
        guard skill.canUpdateFromSource else { return }
        batchErrorMessage = nil
        Task {
            store.clearError()
            await store.update(id: skill.id)
        }
    }

    func syncNow(_ skills: [ManagedSkill], keys: [String], mode: SkillSyncMode) {
        let availableSkills = skills.filter { !$0.isSourceUnavailable }
        let toolKeys = uniqueValues(keys)
        guard !availableSkills.isEmpty, !toolKeys.isEmpty else { return }
        batchErrorMessage = nil
        Task {
            let plans = uniqueSkills(availableSkills).map {
                SkillsSyncPlan(skill: $0, syncKeys: toolKeys, removeKeys: [], mode: mode)
            }
            reportBatchErrors(await requestSync(plans))
        }
    }

    func queueBulkSync(
        _ skills: [ManagedSkill],
        keys: [String],
        mode: SkillSyncMode
    ) {
        deferredBulkSync = SkillsDeferredBulkSync(skills: skills, keys: keys, mode: mode)
    }

    func performDeferredBulkSync() {
        guard let request = deferredBulkSync else { return }
        deferredBulkSync = nil
        syncNow(request.skills, keys: request.keys, mode: request.mode)
    }

    func confirmOverwrite() {
        guard let context = overwriteContext else { return }
        overwriteContext = nil
        batchErrorMessage = nil
        Task {
            reportBatchErrors(await executeSync(
                context.plans,
                authorizing: context.conflicts
            ))
        }
    }

    func cancelOverwrite() {
        overwriteContext = nil
    }

    func applyDetailSyncSettings(
        _ skill: ManagedSkill,
        syncKeys: [String],
        removeKeys: [String],
        mode: SkillSyncMode
    ) {
        let syncKeys = uniqueValues(syncKeys)
        let removeKeys = uniqueValues(removeKeys)
        guard !syncKeys.isEmpty || !removeKeys.isEmpty else { return }
        batchErrorMessage = nil
        Task {
            reportBatchErrors(await requestSync([
                SkillsSyncPlan(
                    skill: skill,
                    syncKeys: syncKeys,
                    removeKeys: removeKeys,
                    mode: mode
                )
            ]))
        }
    }

    func unsync(_ skill: ManagedSkill, keys: [String]) {
        unsyncBatch([skill], keys: keys)
    }

    func commonTags(_ skills: [ManagedSkill]) -> [String] {
        guard let first = skills.first else { return [] }
        let common = skills.dropFirst().reduce(into: Set(first.tags)) { result, skill in
            result.formIntersection(skill.tags)
        }
        return first.tags.filter(common.contains)
    }

    func setTags(_ tags: [String], for skills: [ManagedSkill]) {
        let values = normalizedTags(tags)
        guard !skills.isEmpty else { return }
        let removedCommonTags = Set(commonTags(skills)).subtracting(values)
        batchErrorMessage = nil
        Task {
            _ = await runBatch(skills) { skill in
                var merged = skill.tags.filter { !removedCommonTags.contains($0) }
                var seen = Set(merged)
                merged.append(contentsOf: values.filter { seen.insert($0).inserted })
                await store.setTags(id: skill.id, tags: merged)
            }
        }
    }

    func confirmDelete() {
        guard let context = deleteContext, !context.skills.isEmpty else {
            deleteContext = nil
            return
        }
        let skills = context.skills
        let deletedIDs = Set(skills.map(\.id))
        deleteContext = nil
        batchErrorMessage = nil
        Task {
            _ = await runBatch(skills) { skill in
                await store.remove(id: skill.id)
            }
            let remainingIDs = Set(store.snapshot.skills.map(\.id))
            let removedIDs = deletedIDs.subtracting(remainingIDs)
            selectedIDs.subtract(removedIDs)
            if let detailID = detailSelection?.id, removedIDs.contains(detailID) {
                detailSelection = nil
                await store.select(id: nil)
            }
        }
    }

    var deleteMessage: String {
        guard let skills = deleteContext?.skills, !skills.isEmpty else { return "" }
        if skills.count == 1 {
            return appLanguage.localized(
                "确定删除“\(skills[0].name)”吗？由本应用管理的同步链接也会一并移除。"
            )
        }
        return appLanguage.localized(
            "确定删除所选的 \(skills.count) 个 Skills 吗？由本应用管理的同步链接也会一并移除。"
        )
    }
}

private extension SkillsView {
    func openDetail(_ skill: ManagedSkill) {
        detailSelection = SkillsDetailSelection(id: skill.id)
        Task { await store.select(id: skill.id) }
    }

    func scanLocal(_ root: URL) async throws -> [SkillLocalCandidate] {
        store.clearError()
        let candidates = await store.scanLocal(at: root)
        if let message = store.errorMessage { throw SkillsServiceError(message: message) }
        return candidates
    }

    func installGit(
        _ source: String,
        tags: [String],
        toolKeys: [String],
        mode: SkillSyncMode
    ) async -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIDs = Set(store.snapshot.skills.map(\.id))
        batchErrorMessage = nil
        store.clearError()
        await store.importGit(from: source)
        guard store.errorMessage == nil else { return false }

        let matching = store.snapshot.skills.filter {
            $0.sourceType.lowercased().contains("git") && $0.sourceReference == source
        }
        let installed = matching.isEmpty
            ? store.snapshot.skills.filter { !previousIDs.contains($0.id) }
            : matching
        guard !installed.isEmpty else { return false }
        let options = await applyInstallOptions(
            to: installed,
            tags: tags,
            toolKeys: toolKeys,
            mode: mode
        )
        reportBatchErrors(options)
        return true
    }

    func installLocal(
        _ sources: [URL],
        tags: [String],
        toolKeys: [String],
        mode: SkillSyncMode
    ) async -> Bool {
        guard !sources.isEmpty else { return false }
        batchErrorMessage = nil
        var installed: [ManagedSkill] = []
        var result = SkillsBatchResult(succeeded: 0, errors: [])

        for source in sources {
            let normalizedSource = source.standardizedFileURL.path
            let previousIDs = Set(store.snapshot.skills.map(\.id))
            store.clearError()
            await store.importLocal(from: source)
            if let message = store.errorMessage {
                result.errors.append("\(source.lastPathComponent): \(message)")
                continue
            }
            result.succeeded += 1

            if let matching = store.snapshot.skills.first(where: {
                $0.sourceType.lowercased() == "local"
                    && URL(fileURLWithPath: $0.sourceReference).standardizedFileURL.path
                        == normalizedSource
            }) {
                installed.append(matching)
            } else if let added = store.snapshot.skills.first(where: {
                !previousIDs.contains($0.id)
            }) {
                installed.append(added)
            }
        }

        let uniqueInstalled = uniqueSkills(installed)
        guard !uniqueInstalled.isEmpty else {
            reportBatchErrors(result)
            return false
        }
        let options = await applyInstallOptions(
            to: uniqueInstalled,
            tags: tags,
            toolKeys: toolKeys,
            mode: mode
        )
        result.succeeded += options.succeeded
        result.errors.append(contentsOf: options.errors)
        reportBatchErrors(result)
        return true
    }

    func applyInstallOptions(
        to skills: [ManagedSkill],
        tags: [String],
        toolKeys: [String],
        mode: SkillSyncMode
    ) async -> SkillsBatchResult {
        let tags = normalizedTags(tags)
        let toolKeys = uniqueValues(toolKeys)
        var combined = SkillsBatchResult(succeeded: 0, errors: [])

        if !tags.isEmpty {
            let result = await runBatch(skills, reportErrors: false) { skill in
                await store.setTags(id: skill.id, tags: tags)
            }
            combined.succeeded += result.succeeded
            combined.errors.append(contentsOf: result.errors)
        }
        if !toolKeys.isEmpty {
            let result = await requestSync(
                uniqueSkills(skills.filter { !$0.isSourceUnavailable }).map {
                    SkillsSyncPlan(
                        skill: $0,
                        syncKeys: toolKeys,
                        removeKeys: [],
                        mode: mode
                    )
                }
            )
            combined.succeeded += result.succeeded
            combined.errors.append(contentsOf: result.errors)
        }
        return combined
    }

    func createTag(_ name: String, for skill: ManagedSkill) {
        setTags(skill.tags + [name], for: [skill])
    }

    func renameTag(_ original: String, to replacement: String) {
        let affected = store.snapshot.skills.filter { $0.tags.contains(original) }
        guard !affected.isEmpty else { return }
        batchErrorMessage = nil
        Task {
            _ = await runBatch(affected) { skill in
                let tags = skill.tags.map { $0 == original ? replacement : $0 }
                await store.setTags(id: skill.id, tags: normalizedTags(tags))
            }
        }
    }

    func deleteTag(_ tag: String) {
        let affected = store.snapshot.skills.filter { $0.tags.contains(tag) }
        guard !affected.isEmpty else { return }
        batchErrorMessage = nil
        Task {
            _ = await runBatch(affected) { skill in
                await store.setTags(id: skill.id, tags: skill.tags.filter { $0 != tag })
            }
        }
    }

    func viewTag(_ tag: String) {
        query = ""
        statusFilter = .all
        tagFilter = tag
        page = .library
    }

    func unsyncBatch(_ skills: [ManagedSkill], keys: [String]) {
        let toolKeys = uniqueValues(keys)
        guard !skills.isEmpty, !toolKeys.isEmpty else { return }
        batchErrorMessage = nil
        Task {
            _ = await runBatch(skills) { skill in
                let currentKeys = Set(skill.targets.map(\.key))
                let relevantKeys = toolKeys.filter(currentKeys.contains)
                guard !relevantKeys.isEmpty else { return }
                await store.unsync(id: skill.id, toolKeys: relevantKeys)
            }
        }
    }

    func checkUpdates() async -> [ManagedSkill]? {
        batchErrorMessage = nil
        store.clearError()
        await store.refreshUpdates()
        guard store.errorMessage == nil else { return nil }
        return store.snapshot.skills
    }

    func updateSkills(_ skills: [ManagedSkill]) async -> SkillsBatchResult {
        batchErrorMessage = nil
        return await runBatch(skills.filter(\.canUpdateFromSource)) { skill in
            await store.update(id: skill.id)
        }
    }

    func runBatch(
        _ skills: [ManagedSkill],
        reportErrors: Bool = true,
        operation: (ManagedSkill) async -> Void
    ) async -> SkillsBatchResult {
        var result = SkillsBatchResult(succeeded: 0, errors: [])
        for skill in uniqueSkills(skills) {
            store.clearError()
            await operation(skill)
            if let message = store.errorMessage {
                result.errors.append("\(skill.name): \(message)")
            } else {
                result.succeeded += 1
            }
        }
        if reportErrors { reportBatchErrors(result) }
        return result
    }

    func requestSync(_ plans: [SkillsSyncPlan]) async -> SkillsBatchResult {
        let plans = normalizedSyncPlans(plans)
        guard !plans.isEmpty else { return SkillsBatchResult(succeeded: 0, errors: []) }
        var ready: [SkillsSyncPlan] = []
        var conflicts: [SkillSyncConflict] = []
        var result = SkillsBatchResult(succeeded: 0, errors: [])

        for plan in plans {
            if !plan.syncKeys.isEmpty {
                store.clearError()
                guard let found = await store.syncConflicts(
                    id: plan.skill.id,
                    toolKeys: plan.syncKeys
                ) else {
                    result.errors.append(
                        "\(plan.skill.name): \(store.errorMessage ?? appLanguage.localized("无法检查同步目标"))"
                    )
                    continue
                }
                conflicts.append(contentsOf: found)
            }
            ready.append(plan)
        }

        let uniqueConflicts = uniqueSyncConflicts(conflicts)
        if !uniqueConflicts.isEmpty {
            overwriteContext = SkillsOverwriteContext(
                plans: ready,
                conflicts: uniqueConflicts
            )
            return result
        }

        let executed = await executeSync(ready, authorizing: [])
        result.succeeded += executed.succeeded
        result.errors.append(contentsOf: executed.errors)
        return result
    }

    func executeSync(
        _ plans: [SkillsSyncPlan],
        authorizing conflicts: [SkillSyncConflict]
    ) async -> SkillsBatchResult {
        var result = SkillsBatchResult(succeeded: 0, errors: [])
        var pendingPlans: [SkillsSyncPlan] = []
        var pendingConflicts: [SkillSyncConflict] = []

        for plan in normalizedSyncPlans(plans) {
            if !plan.syncKeys.isEmpty {
                store.clearError()
                switch await store.sync(
                    id: plan.skill.id,
                    toolKeys: plan.syncKeys,
                    mode: plan.mode,
                    authorizing: conflicts
                ) {
                case .succeeded:
                    result.succeeded += 1
                case .confirmationRequired(let updatedConflicts):
                    pendingPlans.append(plan)
                    pendingConflicts.append(contentsOf: updatedConflicts)
                    continue
                case .failed:
                    result.errors.append(
                        "\(plan.skill.name): \(store.errorMessage ?? appLanguage.localized("同步失败"))"
                    )
                    continue
                }
            }

            if !plan.removeKeys.isEmpty {
                store.clearError()
                await store.unsync(id: plan.skill.id, toolKeys: plan.removeKeys)
                if let message = store.errorMessage {
                    result.errors.append("\(plan.skill.name): \(message)")
                } else {
                    result.succeeded += 1
                }
            }
        }

        let uniquePendingConflicts = uniqueSyncConflicts(pendingConflicts)
        if !uniquePendingConflicts.isEmpty {
            overwriteContext = SkillsOverwriteContext(
                plans: pendingPlans,
                conflicts: uniquePendingConflicts
            )
        }
        return result
    }

    func reportBatchErrors(_ result: SkillsBatchResult) {
        guard let firstError = result.errors.first else { return }
        let summary = appLanguage.localized(
            "成功 \(result.succeeded) 项，失败 \(result.errors.count) 项。"
        )
        batchErrorMessage = "\(summary) \(firstError)"
    }

    func normalizedTags(_ tags: [String]) -> [String] {
        uniqueValues(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { !$0.isEmpty }
    }

    func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    func uniqueSkills(_ skills: [ManagedSkill]) -> [ManagedSkill] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.id).inserted }
    }

    func normalizedSyncPlans(_ plans: [SkillsSyncPlan]) -> [SkillsSyncPlan] {
        var seen = Set<String>()
        return plans.compactMap { plan in
            guard seen.insert(plan.skill.id).inserted else { return nil }
            let syncKeys = uniqueValues(plan.syncKeys)
            let syncing = Set(syncKeys)
            let removeKeys = uniqueValues(plan.removeKeys).filter { !syncing.contains($0) }
            guard !syncKeys.isEmpty || !removeKeys.isEmpty else { return nil }
            return SkillsSyncPlan(
                skill: plan.skill,
                syncKeys: syncKeys,
                removeKeys: removeKeys,
                mode: plan.mode
            )
        }
    }

    func uniqueSyncConflicts(_ conflicts: [SkillSyncConflict]) -> [SkillSyncConflict] {
        var seen = Set<String>()
        return conflicts.filter {
            seen.insert("\($0.skillID)\u{0}\($0.path.standardizedFileURL.path)").inserted
        }
    }
}
