import SwiftUI

struct SkillsBatchResult {
    var succeeded: Int
    var errors: [String]
}

struct SkillsUpdateRunSummary: Equatable {
    var lastRun: Date?
    var checked = 0
    var updated = 0
    var failed = 0
    var errors: [String] = []

    mutating func beginCheck() {
        checked = 0
        updated = 0
        failed = 0
        errors = []
    }

    mutating func finishCheck(checked: Int, errors: [String], at date: Date) {
        self.checked = checked
        updated = 0
        failed = errors.count
        self.errors = errors
        lastRun = date
    }

    mutating func finishUpdate(checked: Int, result: SkillsBatchResult, at date: Date) {
        self.checked = checked
        updated = result.succeeded
        failed = result.errors.count
        errors = result.errors
        lastRun = date
    }
}

struct SkillsUpdatesView: View {
    let skills: [ManagedSkill]
    let globallyBusy: Bool
    let busyIDs: Set<String>
    let checkUpdates: () async -> [ManagedSkill]?
    let updateSkills: ([ManagedSkill]) async -> SkillsBatchResult

    @Environment(\.appLanguage) private var appLanguage
    @State private var running = false
    @State private var updateSummary = SkillsUpdateRunSummary()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                CCSectionHeader(appLanguage.localized("更新")) {
                    HStack(spacing: Space.sm) {
                        Button(appLanguage.localized("检查更新"), action: runCheck)
                            .buttonStyle(.ccSecondary)
                            .disabled(running || globallyBusy)
                            .accessibilityIdentifier("skills.updates.check")
                        Button(appLanguage.localized("全部更新"), action: updateAll)
                            .buttonStyle(.ccPrimary)
                            .disabled(updatableSkills.isEmpty || running || globallyBusy)
                            .accessibilityIdentifier("skills.updates.update-all")
                    }
                }
                Text(appLanguage.localized("检查 Git 来源的 Skills 是否有上游变更，并应用更新。"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.lg) {
                        updateList
                        runSummary.frame(width: 300)
                    }
                    VStack(spacing: Space.lg) {
                        updateList
                        runSummary
                    }
                }
            }
            .pageContent(measure: 1_080)
        }
    }

    private var updateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(appLanguage.localized("Git Skills"), systemImage: "arrow.triangle.branch")
                    .font(.ccBody(.medium))
                Spacer()
                CCBadge(text: "\(gitSkills.count)")
            }
            .padding(Space.lg)
            Divider()
            if gitSkills.isEmpty {
                CCEmptyState(
                    symbol: "arrow.triangle.2.circlepath",
                    title: appLanguage.localized("暂无可更新的 Git Skills。"),
                    message: appLanguage.localized("从 Git 仓库添加 Skill 后可在此检查更新。"),
                    compact: true
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xl)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(gitSkills) { skill in updateRow(skill) }
                }
            }
            Divider()
            Text(appLanguage.localized("本地 Skill · \(skills.count - gitSkills.count)"))
                .font(.ccLabel())
                .foregroundStyle(Theme.faintForeground)
                .padding(.horizontal, Space.lg)
                .frame(minHeight: 34, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .panelSurface()
    }

    private func updateRow(_ skill: ManagedSkill) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Theme.accentText)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: skill.name).font(.ccBody(.medium)).lineLimit(1)
                Text(verbatim: skill.sourceDisplay)
                    .font(.ccMono(Typography.label))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.md)
            SkillsStatusBadge(style: updateStatus(skill))
            Button(appLanguage.localized("skills.action.update")) { update([skill]) }
                .buttonStyle(.ccSecondary)
                .disabled(!skill.canUpdateFromSource || running || globallyBusy || busyIDs.contains(skill.id))
                .accessibilityLabel(appLanguage.localized("更新 Skill \(skill.name)"))
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) { Divider().padding(.leading, Space.lg) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.update.\(skill.id)")
    }

    private var runSummary: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text(appLanguage.localized("上次检查"))
                    .font(.ccCaption(.medium))
                    .foregroundStyle(Theme.mutedForeground)
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            Text(lastRunDescription)
                .font(.ccBody(.medium))
                .lineLimit(2)
            HStack(spacing: Space.sm) {
                summaryMetric("已检查", value: updateSummary.checked, danger: false)
                summaryMetric("已更新", value: updateSummary.updated, danger: false)
                summaryMetric("失败", value: updateSummary.failed, danger: updateSummary.failed > 0)
            }
            if !updateSummary.errors.isEmpty {
                Divider()
                Label(appLanguage.localized("需要处理"), systemImage: "exclamationmark.triangle")
                    .font(.ccCaption(.medium))
                    .foregroundStyle(Theme.danger)
                ForEach(Array(updateSummary.errors.prefix(4).enumerated()), id: \.offset) { _, error in
                    Text(verbatim: error)
                        .font(.ccMono(Typography.label))
                        .foregroundStyle(Theme.mutedForeground)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.updates.summary")
    }

    private func summaryMetric(_ title: String, value: Int, danger: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(appLanguage.localized(title)).font(.ccLabel()).foregroundStyle(Theme.mutedForeground)
            Text("\(value)")
                .font(.ccHeading())
                .foregroundStyle(danger ? Theme.danger : Theme.foreground)
                .monospacedDigit()
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    private var gitSkills: [ManagedSkill] {
        skills.filter { $0.sourceType.lowercased().contains("git") }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private var updatableSkills: [ManagedSkill] { gitSkills.filter(\.canUpdateFromSource) }

    private var lastRunDescription: String {
        guard let lastRun = updateSummary.lastRun else { return appLanguage.localized("尚未运行") }
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: lastRun)
    }

    private func updateStatus(_ skill: ManagedSkill) -> SkillsStatusStyle {
        let value = skill.sourceStatus.lowercased()
        if ["error", "fail", "missing", "invalid"].contains(where: value.contains) {
            return .init(title: "失败", tint: Theme.danger, backing: Theme.dangerSoft)
        }
        if ["update", "outdated", "behind"].contains(where: value.contains) {
            return .init(title: "有可用更新", tint: Theme.warning, backing: Theme.warningSoft)
        }
        return .init(title: "已是最新", tint: Theme.success, backing: Theme.successSoft)
    }

    private func runCheck() {
        running = true
        updateSummary.beginCheck()
        Task {
            if let refreshed = await checkUpdates() {
                let refreshedGit = refreshed.filter {
                    $0.sourceType.lowercased().contains("git")
                }
                let failures = refreshedGit.filter(isRefreshFailure)
                let errors = failures.map {
                    "\($0.name): \(appLanguage.localized("检查更新失败。"))"
                }
                updateSummary.finishCheck(checked: refreshedGit.count, errors: errors, at: Date())
            } else {
                updateSummary.finishCheck(
                    checked: gitSkills.count,
                    errors: [appLanguage.localized("检查更新失败。")],
                    at: Date()
                )
            }
            running = false
        }
    }

    private func isRefreshFailure(_ skill: ManagedSkill) -> Bool {
        let value = skill.sourceStatus.lowercased()
        return ["error", "fail", "missing", "invalid"].contains(where: value.contains)
    }

    private func updateAll() { update(updatableSkills) }

    private func update(_ selected: [ManagedSkill]) {
        guard !selected.isEmpty else { return }
        running = true
        Task {
            let result = await updateSkills(selected)
            updateSummary.finishUpdate(checked: selected.count, result: result, at: Date())
            running = false
        }
    }
}
