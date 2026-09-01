import Foundation

enum SkillSyncMode: String, Codable, CaseIterable, Sendable {
    case auto
    case copy
    case symlink
}

struct SkillTarget: Identifiable, Codable, Equatable, Sendable {
    var id: String { key }
    var key: String
    var path: URL
    var syncMode: SkillSyncMode
    var status: String
    var managedIdentity: String?
    var managedDigest: String?

    private enum CodingKeys: String, CodingKey {
        case key, path, status
        case syncMode = "sync_mode"
        case managedIdentity = "managed_identity"
        case managedDigest = "managed_digest"
    }

    init(
        key: String,
        path: URL,
        syncMode: SkillSyncMode,
        status: String = "ok",
        managedIdentity: String? = nil,
        managedDigest: String? = nil
    ) {
        self.key = key
        self.path = path
        self.syncMode = syncMode
        self.status = status
        self.managedIdentity = managedIdentity
        self.managedDigest = managedDigest
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        path = URL(fileURLWithPath: try values.decode(String.self, forKey: .path))
        let rawMode = try values.decodeIfPresent(String.self, forKey: .syncMode) ?? "auto"
        syncMode = SkillSyncMode(rawValue: rawMode) ?? .auto
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        managedIdentity = try values.decodeIfPresent(String.self, forKey: .managedIdentity)
        managedDigest = try values.decodeIfPresent(String.self, forKey: .managedDigest)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(path.path, forKey: .path)
        try values.encode(syncMode.rawValue, forKey: .syncMode)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(managedIdentity, forKey: .managedIdentity)
        try values.encodeIfPresent(managedDigest, forKey: .managedDigest)
    }
}

struct ManagedSkill: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String?
    var path: URL
    var sourceType: String
    var sourceReference: String
    var updatedAt: Date?
    var tags: [String]
    var targets: [SkillTarget]
    var status: String
    var sourceStatus: String
}

struct SkillTool: Identifiable, Equatable, Sendable {
    var id: String { key }
    var key: String
    var label: String
    var path: URL
    var detected: Bool
    var enabled: Bool
    var defaultSyncMode: SkillSyncMode
    var sharedKeys: [String]
    var projectPath: String?
    var sharedProjectKeys: [String]
}

struct SkillFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var size: UInt64
}

struct SkillDetail: Equatable, Sendable {
    var skill: ManagedSkill
    var files: [SkillFile]
}

struct SkillLocalCandidate: Identifiable, Equatable, Sendable {
    var id: String { path.path }
    var name: String
    var description: String?
    var path: URL
}

struct SkillsSummary: Equatable, Sendable {
    var root: URL
    var total: Int
    var gitCount: Int
    var localCount: Int
    var syncedCount: Int
}

struct SkillsSnapshot: Equatable, Sendable {
    var root: URL
    var skills: [ManagedSkill]
    var tools: [SkillTool]

    var summary: SkillsSummary {
        SkillsSummary(
            root: root,
            total: skills.count,
            gitCount: skills.filter { $0.sourceType == "git" }.count,
            localCount: skills.filter { $0.sourceType != "git" }.count,
            syncedCount: skills.filter { !$0.targets.isEmpty }.count
        )
    }

    static func empty(root: URL) -> SkillsSnapshot {
        SkillsSnapshot(root: root, skills: [], tools: [])
    }
}

struct SkillsServiceError: Error, LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct SkillSyncConflict: Identifiable, Equatable, Hashable, Sendable {
    var id: String { "\(skillID):\(path.standardizedFileURL.path)" }

    let skillID: String
    let path: URL
    let toolKeys: [String]
    let fingerprintToken: String
}

struct SkillSyncConfirmationRequired: Error, LocalizedError, Equatable, Sendable {
    let conflicts: [SkillSyncConflict]

    var errorDescription: String? {
        guard let first = conflicts.first else {
            return "Sync requires confirmation"
        }
        if conflicts.count == 1 {
            return "Target already exists and requires confirmation before it can be replaced: \(first.path.path)"
        }
        return "\(conflicts.count) targets already exist and require confirmation before they can be replaced"
    }
}

struct SkillIndexDocument: Codable {
    var version: Int
    var skills: [String: SkillIndexEntry]

    init(version: Int = 1, skills: [String: SkillIndexEntry] = [:]) {
        self.version = version
        self.skills = skills
    }

    private enum CodingKeys: CodingKey { case version, skills }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        skills = try values.decodeIfPresent([String: SkillIndexEntry].self, forKey: .skills) ?? [:]
    }
}

struct SkillIndexEntry: Codable, Equatable {
    var sourceType: String
    var sourceReference: String
    var sourceSubdirectory: String
    var sourceRevision: String?
    var updatedAtMilliseconds: Int64
    var tags: [String]
    var targets: [SkillTarget]
    var status: String

    init(
        sourceType: String = "local",
        sourceReference: String = "",
        sourceSubdirectory: String = "",
        sourceRevision: String? = nil,
        updatedAtMilliseconds: Int64 = 0,
        tags: [String] = [],
        targets: [SkillTarget] = [],
        status: String = "ok"
    ) {
        self.sourceType = sourceType
        self.sourceReference = sourceReference
        self.sourceSubdirectory = sourceSubdirectory
        self.sourceRevision = sourceRevision
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.tags = tags
        self.targets = targets
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case tags, targets, status
        case sourceType = "source_type"
        case sourceReference = "source_ref"
        case sourceSubdirectory = "source_subdir"
        case sourceRevision = "source_revision"
        case updatedAtMilliseconds = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceType = try values.decodeIfPresent(String.self, forKey: .sourceType) ?? "local"
        sourceReference = try values.decodeIfPresent(String.self, forKey: .sourceReference) ?? ""
        sourceSubdirectory = try values.decodeIfPresent(String.self, forKey: .sourceSubdirectory) ?? ""
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        updatedAtMilliseconds = try values.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds) ?? 0
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        targets = try values.decodeIfPresent([SkillTarget].self, forKey: .targets) ?? []
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "ok"
    }
}

protocol SkillsManaging: Sendable {
    func snapshot() async throws -> SkillsSnapshot
    func detail(id: String) async throws -> SkillDetail
    func readFile(id: String, path: String) async throws -> String
    func scanLocal(at root: URL) async throws -> [SkillLocalCandidate]
    func importLocal(from source: URL) async throws -> ManagedSkill
    func importGit(from source: String) async throws -> [ManagedSkill]
    func refreshUpdates(id: String?) async throws -> SkillsSnapshot
    func update(id: String) async throws -> ManagedSkill
    func remove(id: String) async throws -> Bool
    func syncConflicts(id: String, toolKeys: [String]) async throws -> [SkillSyncConflict]
    func sync(
        id: String,
        toolKeys: [String],
        mode: SkillSyncMode,
        authorizing: [SkillSyncConflict]
    ) async throws -> ManagedSkill
    func unsync(id: String, toolKeys: [String]) async throws -> ManagedSkill
    func setTags(id: String, tags: [String]) async throws -> ManagedSkill
    func rootURL() async -> URL
}

extension SkillsManaging {
    func sync(id: String, toolKeys: [String], mode: SkillSyncMode) async throws -> ManagedSkill {
        try await sync(id: id, toolKeys: toolKeys, mode: mode, authorizing: [])
    }
}
