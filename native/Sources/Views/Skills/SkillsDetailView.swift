import SwiftUI

struct SkillsDetailView: View {
    let detail: SkillDetail?
    let tools: [SkillTool]
    let busy: Bool
    let close: () -> Void
    let readFile: (String, String) async throws -> String
    let editTags: (ManagedSkill) -> Void
    let update: (ManagedSkill) -> Void
    let applySyncSettings: (ManagedSkill, [String], [String], SkillSyncMode) -> Void
    let unsync: (ManagedSkill, [String]) -> Void
    let delete: (ManagedSkill) -> Void

    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(spacing: 0) {
            header
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: Space.lg) {
                                metadata(detail.skill)
                                syncPanel(detail.skill).frame(width: 410)
                            }
                            VStack(spacing: Space.lg) {
                                metadata(detail.skill)
                                syncPanel(detail.skill)
                            }
                        }
                        SkillsFilePreview(detail: detail) { path in
                            try await readFile(detail.skill.id, path)
                        }
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: 1_120)
                    .frame(maxWidth: .infinity)
                }
            } else {
                SkillsLoadingState(title: "正在加载…")
            }
        }
        .frame(minWidth: 720, idealWidth: 980, minHeight: 620, idealHeight: 760)
        .background(Theme.background)
        .accessibilityContainerIdentifier(
            "skills.detail",
            label: appLanguage.localized("Skill 详情")
        )
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            if let skill = detail?.skill {
                Image(systemName: skill.sourceSymbol)
                    .font(.ccHeading())
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 38, height: 38)
                    .background(Theme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: skill.name).font(.ccHeading()).lineLimit(1)
                    Text(skill.description ?? appLanguage.localized("暂无描述"))
                        .font(.ccCaption()).foregroundStyle(Theme.mutedForeground).lineLimit(1)
                }
                Spacer(minLength: Space.md)
                Button(appLanguage.localized("编辑标签")) { editTags(skill) }
                    .buttonStyle(.ccSecondary)
                    .disabled(busy)
                if skill.canUpdateFromSource {
                    Button(appLanguage.localized("skills.action.update")) { update(skill) }
                        .buttonStyle(.ccSecondary)
                        .disabled(busy)
                }
                Button(appLanguage.localized("删除")) { delete(skill) }
                    .buttonStyle(.ccDanger)
                    .disabled(busy)
            } else {
                Text(appLanguage.localized("Skill 详情")).font(.ccHeading())
                Spacer()
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.ccIcon)
                .keyboardShortcut(.cancelAction)
                .help(appLanguage.localized("关闭"))
                .accessibilityLabel(appLanguage.localized("关闭 Skill 详情"))
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(Theme.list)
        .hairline(.bottom)
    }

    private func metadata(_ skill: ManagedSkill) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(appLanguage.localized("详情")).font(.ccBody(.medium))
                Spacer()
                SkillsStatusBadge(style: skill.presentationStatus)
            }
            metadataRow("来源", value: skill.sourceDisplay, monospaced: true)
            metadataRow("位置", value: skill.path.path, monospaced: true)
            metadataRow("更新时间", value: skill.updatedDescription(locale: appLanguage.locale))
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(appLanguage.localized("标签"))
                    .font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
                if skill.tags.isEmpty {
                    Text(appLanguage.localized("无标签"))
                        .font(.ccCaption()).foregroundStyle(Theme.faintForeground)
                } else {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(skill.tags, id: \.self) { tag in CCBadge(text: tag) }
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }

    private func metadataRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(appLanguage.localized(title))
                .font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
            Text(verbatim: value)
                .font(monospaced ? .ccMono(Typography.caption) : .ccCaption())
                .foregroundStyle(Theme.foreground)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func syncPanel(_ skill: ManagedSkill) -> some View {
        SkillsSyncPanel(
            skill: skill,
            tools: tools,
            busy: busy,
            apply: { applySyncSettings(skill, $0, $1, $2) },
            removeAll: { unsync(skill, $0) }
        )
    }
}
