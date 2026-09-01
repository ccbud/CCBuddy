import Foundation

extension ManagedSkill {
    var presentationStatus: SkillsStatusStyle {
        SkillsStatusStyle.resolve(
            skillStatus: status,
            targetStatuses: targets.map(\.status)
        )
    }

    var statusFilter: SkillsStatusFilter {
        switch presentationStatus.title {
        case "已同步": .synced
        case "部分同步": .partial
        case "异常": .issue
        default: .unsynced
        }
    }

    var isSourceUnavailable: Bool {
        let value = status.lowercased()
        return value.contains("missing") || value.contains("invalid")
            || value.contains("unavailable")
    }

    var canUpdateFromSource: Bool {
        let source = sourceReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return false }
        if sourceType.lowercased().contains("git") { return true }
        guard sourceType.lowercased() == "local" else { return false }
        let managed = path.standardizedFileURL.path
        let external = URL(fileURLWithPath: source).standardizedFileURL.path
        return managed != external
    }

    var sourceTitle: String {
        sourceType.lowercased().contains("git") ? "Git" : "本地"
    }

    var sourceSymbol: String {
        sourceType.lowercased().contains("git") ? "arrow.down.circle" : "folder"
    }

    var sourceDisplay: String {
        let source = sourceReference.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? path.path : source
    }

    func updatedDescription(locale: Locale) -> String {
        guard let updatedAt else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }
}

extension SkillTool {
    func syncedSkillCount(in skills: [ManagedSkill]) -> Int {
        skills.filter { skill in skill.targets.contains { $0.key == key } }.count
    }

    func target(for skill: ManagedSkill) -> SkillTarget? {
        skill.targets.first { $0.key == key }
    }
}

extension SkillFile {
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

extension Array where Element == ManagedSkill {
    var allSkillTags: [String] {
        Set(self.flatMap { $0.tags })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
