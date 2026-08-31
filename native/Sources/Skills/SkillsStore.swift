import Combine
import Foundation

@MainActor
final class SkillsStore: ObservableObject {
    @Published private(set) var snapshot: SkillsSnapshot
    @Published private(set) var selectedDetail: SkillDetail?
    @Published private(set) var isBusy = false
    @Published private(set) var busySkillIDs = Set<String>()
    @Published private(set) var errorMessage: String?

    let service: any SkillsManaging

    private var operationCount = 0
    private var busySkillCounts: [String: Int] = [:]
    private var snapshotGeneration = UUID()
    private var detailGeneration = UUID()

    init(
        service: any SkillsManaging = LiveSkillsService(),
        initialRoot: URL = LiveSkillsService.defaultRootURL
    ) {
        self.service = service
        snapshot = .empty(root: initialRoot)
    }

    func refresh() async {
        let generation = UUID()
        snapshotGeneration = generation
        beginOperation(skillID: nil)
        defer { endOperation(skillID: nil) }
        do {
            let value = try await service.snapshot()
            guard snapshotGeneration == generation else { return }
            snapshot = value
            errorMessage = nil
        } catch {
            guard snapshotGeneration == generation else { return }
            errorMessage = skillErrorMessage(error)
        }
    }

    func select(id: String?) async {
        let generation = UUID()
        detailGeneration = generation
        guard let id else {
            selectedDetail = nil
            return
        }
        do {
            let value = try await service.detail(id: id)
            guard detailGeneration == generation else { return }
            selectedDetail = value
            errorMessage = nil
        } catch {
            guard detailGeneration == generation else { return }
            selectedDetail = nil
            errorMessage = skillErrorMessage(error)
        }
    }

    func importLocal(from source: URL) async {
        await mutate(skillID: nil) { [service] in
            _ = try await service.importLocal(from: source)
        }
    }

    func scanLocal(at root: URL) async -> [SkillLocalCandidate] {
        beginOperation(skillID: nil)
        defer { endOperation(skillID: nil) }
        do {
            let candidates = try await service.scanLocal(at: root)
            errorMessage = nil
            return candidates
        } catch {
            errorMessage = skillErrorMessage(error)
            return []
        }
    }

    func importGit(from source: String) async {
        await mutate(skillID: nil) { [service] in
            _ = try await service.importGit(from: source)
        }
    }

    func refreshUpdates(id: String? = nil) async {
        let generation = UUID()
        snapshotGeneration = generation
        beginOperation(skillID: id)
        defer { endOperation(skillID: id) }
        do {
            let value = try await service.refreshUpdates(id: id)
            guard snapshotGeneration == generation else { return }
            snapshot = value
            errorMessage = nil
        } catch {
            guard snapshotGeneration == generation else { return }
            errorMessage = skillErrorMessage(error)
        }
    }

    func update(id: String) async {
        await mutate(skillID: id) { [service] in
            _ = try await service.update(id: id)
        }
    }

    func remove(id: String) async {
        let succeeded = await mutate(skillID: id) { [service] in
            _ = try await service.remove(id: id)
        }
        if succeeded, selectedDetail?.skill.id == id { selectedDetail = nil }
    }

    func sync(id: String, toolKeys: [String], mode: SkillSyncMode = .auto) async {
        await mutate(skillID: id) { [service] in
            _ = try await service.sync(id: id, toolKeys: toolKeys, mode: mode)
        }
    }

    func unsync(id: String, toolKeys: [String]) async {
        await mutate(skillID: id) { [service] in
            _ = try await service.unsync(id: id, toolKeys: toolKeys)
        }
    }

    func setTags(id: String, tags: [String]) async {
        await mutate(skillID: id) { [service] in
            _ = try await service.setTags(id: id, tags: tags)
        }
    }

    func readFile(id: String, path: String) async throws -> String {
        try await service.readFile(id: id, path: path)
    }

    func rootURL() async -> URL {
        await service.rootURL()
    }

    func clearError() {
        errorMessage = nil
    }

    @discardableResult
    private func mutate(
        skillID: String?,
        operation: () async throws -> Void
    ) async -> Bool {
        beginOperation(skillID: skillID)
        defer { endOperation(skillID: skillID) }
        do {
            try await operation()
            let value = try await service.snapshot()
            snapshotGeneration = UUID()
            snapshot = value
            errorMessage = nil
            if let selectedID = selectedDetail?.skill.id {
                detailGeneration = UUID()
                if value.skills.contains(where: { $0.id == selectedID }) {
                    do {
                        selectedDetail = try await service.detail(id: selectedID)
                    } catch {
                        selectedDetail = nil
                        errorMessage = skillErrorMessage(error)
                    }
                } else {
                    selectedDetail = nil
                }
            }
            return true
        } catch {
            errorMessage = skillErrorMessage(error)
            return false
        }
    }

    private func beginOperation(skillID: String?) {
        operationCount += 1
        isBusy = true
        if let skillID {
            busySkillCounts[skillID, default: 0] += 1
            busySkillIDs.insert(skillID)
        }
    }

    private func endOperation(skillID: String?) {
        operationCount = max(0, operationCount - 1)
        isBusy = operationCount > 0
        if let skillID {
            let remaining = max(0, (busySkillCounts[skillID] ?? 1) - 1)
            if remaining == 0 {
                busySkillCounts.removeValue(forKey: skillID)
                busySkillIDs.remove(skillID)
            } else {
                busySkillCounts[skillID] = remaining
            }
        }
    }
}
