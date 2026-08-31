import SwiftUI

struct SkillsTagsView: View {
    let skills: [ManagedSkill]
    let globallyBusy: Bool
    let viewTag: (String) -> Void
    let createTag: (String, ManagedSkill) -> Void
    let renameTag: (String, String) -> Void
    let deleteTag: (String) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @State private var newTag = ""
    @State private var selectedSkillID = ""
    @State private var tagToRename: TagSelection?
    @State private var tagToDelete: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                CCSectionHeader(appLanguage.localized("标签管理")) {
                    Text(appLanguage.localized("使用标签整理和筛选 Skills，不会改变同步行为。"))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.lg) {
                        tagList
                        createPanel.frame(width: 320)
                    }
                    VStack(spacing: Space.lg) {
                        tagList
                        createPanel
                    }
                }
            }
            .pageContent(measure: 1_080)
        }
        .onAppear { chooseDefaultSkill() }
        .onChange(of: skills.map(\.id)) { _ in chooseDefaultSkill() }
        .sheet(item: $tagToRename) { selection in
            SkillsRenameTagSheet(original: selection.name) { renameTag(selection.name, $0) }
        }
        .confirmationDialog(
            appLanguage.localized("删除标签？"),
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: { if !$0 { tagToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(appLanguage.localized("删除"), role: .destructive) {
                guard let tag = tagToDelete else { return }
                tagToDelete = nil
                deleteTag(tag)
            }
            Button(appLanguage.localized("取消"), role: .cancel) { tagToDelete = nil }
        } message: {
            Text(appLanguage.localized("Skills 本身不会被删除。"))
        }
    }

    private var tagList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(appLanguage.localized("标签"))
                    .font(.ccBody(.medium))
                Spacer()
                CCBadge(text: "\(tagRows.count)")
            }
            .padding(Space.lg)
            Divider()
            if tagRows.isEmpty {
                CCEmptyState(
                    symbol: "tag",
                    title: appLanguage.localized("暂无标签。"),
                    message: appLanguage.localized("在右侧创建标签，或从 Skill 卡片编辑标签。"),
                    compact: true
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xl)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(tagRows, id: \.name) { row in tagRow(row) }
                }
            }
            let untagged = skills.filter(\.tags.isEmpty).count
            if untagged > 0 {
                Divider()
                Button { viewTag("__untagged__") } label: {
                    HStack {
                        Label(appLanguage.localized("无标签"), systemImage: "tag.slash")
                        Spacer()
                        Text("\(untagged)").monospacedDigit()
                    }
                    .font(.ccCaption(.medium))
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(Space.lg)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .panelSurface()
    }

    private func tagRow(_ row: TagRow) -> some View {
        HStack(spacing: Space.md) {
            Button { viewTag(row.name) } label: { Text(verbatim: row.name) }
                .buttonStyle(.plain)
                .font(.ccBody(.medium))
                .foregroundStyle(Theme.accentText)
                .lineLimit(1)
            Spacer(minLength: Space.md)
            Text("\(row.count)")
                .font(.ccCaption()).foregroundStyle(Theme.mutedForeground).monospacedDigit()
            Text(row.updated)
                .font(.ccCaption()).foregroundStyle(Theme.mutedForeground).lineLimit(1)
            Button { tagToRename = TagSelection(name: row.name) } label: { Image(systemName: "pencil") }
                .buttonStyle(.ccIcon)
                .help(appLanguage.localized("重命名"))
                .accessibilityLabel(appLanguage.localized("重命名标签 \(row.name)"))
            Button { tagToDelete = row.name } label: { Image(systemName: "trash") }
                .buttonStyle(CCIconButtonStyle(tint: Theme.danger))
                .help(appLanguage.localized("删除"))
                .accessibilityLabel(appLanguage.localized("删除标签 \(row.name)"))
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Divider().padding(.leading, Space.lg) }
        .disabled(globallyBusy)
    }

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(appLanguage.localized("新建标签")).font(.ccBody(.medium))
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(appLanguage.localized("标签名称")).font(.ccCaption())
                TextField(appLanguage.localized("例如：开发…"), text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("skills.tags.new-name")
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(appLanguage.localized("分配给 Skills")).font(.ccCaption())
                Picker(appLanguage.localized("分配给 Skills"), selection: $selectedSkillID) {
                    ForEach(skills) { skill in Text(verbatim: skill.name).tag(skill.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(appLanguage.localized("创建标签"), action: submitNewTag)
                .buttonStyle(.ccPrimary)
                .disabled(trimmedNewTag.isEmpty || selectedSkill == nil || globallyBusy)
                .accessibilityIdentifier("skills.tags.create")
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private struct TagRow {
        let name: String
        let count: Int
        let updated: String
    }

    private struct TagSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    private var tagRows: [TagRow] {
        skills.allSkillTags.map { tag in
            let tagged = skills.filter { $0.tags.contains(tag) }
            let latest = tagged.compactMap(\.updatedAt).max()
            let display = latest.map { date in
                let formatter = DateFormatter()
                formatter.locale = appLanguage.locale
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                return formatter.string(from: date)
            } ?? "—"
            return TagRow(name: tag, count: tagged.count, updated: display)
        }
    }

    private var trimmedNewTag: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedSkill: ManagedSkill? { skills.first { $0.id == selectedSkillID } }

    private func chooseDefaultSkill() {
        if selectedSkill == nil { selectedSkillID = skills.first?.id ?? "" }
    }

    private func submitNewTag() {
        guard let skill = selectedSkill, !trimmedNewTag.isEmpty else { return }
        createTag(trimmedNewTag, skill)
        newTag = ""
    }
}
