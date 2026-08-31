import SwiftUI

struct SkillsLibraryView: View {
    let snapshot: SkillsSnapshot
    let busyIDs: Set<String>
    let globallyBusy: Bool

    @Binding var query: String
    @Binding var statusFilter: SkillsStatusFilter
    @Binding var tagFilter: String
    @Binding var sortOrder: SkillsSortOrder
    @Binding var displayMode: SkillsDisplayMode
    @Binding var bulkMode: Bool
    @Binding var selectedIDs: Set<String>

    let refresh: () -> Void
    let add: () -> Void
    let openDetail: (ManagedSkill) -> Void
    let editTags: ([ManagedSkill]) -> Void
    let update: (ManagedSkill) -> Void
    let sync: ([ManagedSkill]) -> Void
    let unsync: (ManagedSkill) -> Void
    let delete: ([ManagedSkill]) -> Void

    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                metrics
                sectionHeader
                SkillsFilterBar(
                    query: $query,
                    status: $statusFilter,
                    tag: $tagFilter,
                    sort: $sortOrder,
                    displayMode: $displayMode,
                    bulkMode: $bulkMode,
                    tags: snapshot.skills.allSkillTags
                )
                content
            }
            .pageContent(measure: 1_180)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bulkMode {
                SkillsSelectionBar(
                    count: selectedIDs.count,
                    total: visibleSkills.count,
                    selectAll: toggleAll,
                    editTags: { editTags(selectedSkills) },
                    sync: { sync(selectedSkills) },
                    delete: { delete(selectedSkills) },
                    clear: { selectedIDs.removeAll() }
                )
            }
        }
        .onChange(of: visibleSkills.map(\.id)) { visible in
            selectedIDs.formIntersection(visible)
        }
        .onChange(of: bulkMode) { enabled in
            if !enabled { selectedIDs.removeAll() }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.md)], spacing: Space.md) {
            SkillsMetricCard(title: "已管理", value: "\(snapshot.summary.total)")
            SkillsMetricCard(title: "Git", value: "\(snapshot.summary.gitCount)")
            SkillsMetricCard(title: "本地", value: "\(snapshot.summary.localCount)")
            SkillsMetricCard(
                title: "同步状态",
                value: "\(snapshot.summary.syncedCount)",
                status: overallStatus
            )
        }
    }

    private var sectionHeader: some View {
        CCSectionHeader(appLanguage.localized("全部 Skills")) {
            HStack(spacing: Space.sm) {
                Text("\(visibleSkills.count)")
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .monospacedDigit()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.ccIcon)
                    .disabled(globallyBusy)
                    .help(appLanguage.localized("刷新"))
                    .accessibilityLabel(appLanguage.localized("刷新 Skills"))
                    .accessibilityIdentifier("skills.refresh")
                Button(action: add) {
                    Label(appLanguage.localized("添加"), systemImage: "plus")
                }
                .buttonStyle(.ccPrimary)
                .disabled(globallyBusy)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("skills.add.shortcut")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if visibleSkills.isEmpty {
            CCEmptyState(
                symbol: query.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass",
                title: appLanguage.localized(query.isEmpty ? "暂无 Skills" : "没有匹配的 Skills"),
                message: appLanguage.localized(query.isEmpty
                    ? "从 Git 仓库或本地文件夹添加 Skill。"
                    : "调整搜索词或筛选条件后重试。"),
                compact: true
            ) {
                if query.isEmpty {
                    Button(appLanguage.localized("添加 Skill"), action: add)
                        .buttonStyle(.ccPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xxl)
        } else if displayMode == .cards {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 340), spacing: Space.md)],
                spacing: Space.md
            ) {
                skillCards
            }
        } else {
            LazyVStack(spacing: Space.sm) { skillCards }
        }
    }

    @ViewBuilder private var skillCards: some View {
        ForEach(visibleSkills) { skill in
            SkillsSkillCard(
                skill: skill,
                tools: snapshot.tools,
                displayMode: displayMode,
                bulkMode: bulkMode,
                selected: selectedIDs.contains(skill.id),
                busy: globallyBusy || busyIDs.contains(skill.id),
                toggleSelection: { toggle(skill.id) },
                openDetail: { openDetail(skill) },
                filterTag: { tagFilter = $0 },
                editTags: { editTags([skill]) },
                update: { update(skill) },
                sync: { sync([skill]) },
                unsync: { unsync(skill) },
                delete: { delete([skill]) }
            )
        }
    }

    private var visibleSkills: [ManagedSkill] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.skills.filter { skill in
            let matchesQuery = needle.isEmpty || [
                skill.name, skill.description ?? "", skill.sourceReference,
                skill.tags.joined(separator: " "),
            ].contains { $0.localizedCaseInsensitiveContains(needle) }
            let matchesStatus = statusFilter == .all || skill.statusFilter == statusFilter
            let matchesTag = tagFilter.isEmpty
                || (tagFilter == "__untagged__" ? skill.tags.isEmpty : skill.tags.contains(tagFilter))
            return matchesQuery && matchesStatus && matchesTag
        }.sorted(by: ordering)
    }

    private var selectedSkills: [ManagedSkill] {
        visibleSkills.filter { selectedIDs.contains($0.id) }
    }

    private var overallStatus: SkillsStatusStyle {
        if snapshot.skills.contains(where: { $0.statusFilter == .issue }) {
            return .init(title: "异常", tint: Theme.danger, backing: Theme.dangerSoft)
        }
        if snapshot.summary.syncedCount == 0 {
            return .init(title: "未同步", tint: Theme.mutedForeground, backing: Theme.fill)
        }
        return .init(title: "健康", tint: Theme.success, backing: Theme.successSoft)
    }

    private func ordering(_ left: ManagedSkill, _ right: ManagedSkill) -> Bool {
        switch sortOrder {
        case .name: left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        case .source: left.sourceType.localizedCaseInsensitiveCompare(right.sourceType) == .orderedAscending
        case .updated: (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
        }
    }

    private func toggle(_ id: String) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }

    private func toggleAll() {
        let visible = Set(visibleSkills.map(\.id))
        if selectedIDs.isSuperset(of: visible) { selectedIDs.subtract(visible) }
        else { selectedIDs.formUnion(visible) }
    }
}
