import SwiftUI

struct SkillsSkillCard: View {
    let skill: ManagedSkill
    let tools: [SkillTool]
    let displayMode: SkillsDisplayMode
    let bulkMode: Bool
    let selected: Bool
    let busy: Bool
    let toggleSelection: () -> Void
    let openDetail: () -> Void
    let filterTag: (String) -> Void
    let editTags: () -> Void
    let update: () -> Void
    let sync: () -> Void
    let unsync: () -> Void
    let delete: () -> Void

    @Environment(\.appLanguage) private var appLanguage
    @State private var hovering = false

    var body: some View {
        Group {
            if displayMode == .list { listBody } else { cardBody }
        }
        .padding(displayMode == .list ? Space.md : Space.lg)
        .frame(maxWidth: .infinity, minHeight: displayMode == .list ? 74 : 174, alignment: .leading)
        .background(selected ? Theme.selection : hovering ? Theme.hover : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.card.\(skill.id)")
    }

    private var listBody: some View {
        HStack(spacing: Space.md) {
            selectionControl
            sourceIcon
            identity.frame(maxWidth: .infinity, alignment: .leading)
            tags.frame(width: 150, alignment: .leading)
            targetSummary.frame(width: 112, alignment: .leading)
            SkillsStatusBadge(style: skill.presentationStatus)
            actions
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                selectionControl
                sourceIcon
                identity
                Spacer(minLength: Space.sm)
                SkillsStatusBadge(style: skill.presentationStatus)
            }
            tags
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: Space.sm) {
                targetSummary
                Spacer(minLength: Space.sm)
                actions
            }
        }
    }

    @ViewBuilder private var selectionControl: some View {
        if bulkMode {
            Button(action: toggleSelection) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Theme.accentText : Theme.mutedForeground)
            }
            .buttonStyle(CCIconButtonStyle(size: 24, symbolSize: Typography.body))
            .accessibilityLabel(appLanguage.localized(selected ? "取消选择 \(skill.name)" : "选择 \(skill.name)"))
            .accessibilityIdentifier("skills.select.\(skill.id)")
        }
    }

    private var sourceIcon: some View {
        Image(systemName: skill.sourceSymbol)
            .font(.ccBody(.medium))
            .foregroundStyle(Theme.accentText)
            .frame(width: 34, height: 34)
            .background(Theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .accessibilityHidden(true)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button(action: openDetail) {
                Text(verbatim: skill.name)
                    .font(.ccBody(.semibold))
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(appLanguage.localized("查看详情"))
            Text(skill.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? skill.description ?? ""
                : appLanguage.localized("暂无描述"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(displayMode == .list ? 1 : 2)
            Text(skill.updatedDescription(locale: appLanguage.locale))
                .font(.ccLabel())
                .foregroundStyle(Theme.faintForeground)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var tags: some View {
        if skill.tags.isEmpty {
            Text(appLanguage.localized("无标签"))
                .font(.ccLabel())
                .foregroundStyle(Theme.faintForeground)
        } else {
            FlowLayout(spacing: Space.xs) {
                ForEach(skill.tags.prefix(displayMode == .list ? 2 : 4), id: \.self) { tag in
                    Button(tag) { filterTag(tag) }
                        .buttonStyle(.plain)
                        .font(.ccLabel(.medium))
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(Theme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
                        .help(appLanguage.localized("筛选标签 \(tag)"))
                }
            }
        }
    }

    private var targetSummary: some View {
        HStack(spacing: -Space.xs) {
            ForEach(Array(skill.targets.prefix(4))) { target in
                let tool = tools.first { $0.key == target.key }
                SkillsToolMark(
                    label: tool?.label ?? target.key,
                    active: true,
                    issue: isIssue(target.status)
                )
            }
            if skill.targets.isEmpty {
                Text(appLanguage.localized("未同步"))
                    .font(.ccLabel())
                    .foregroundStyle(Theme.faintForeground)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLanguage.localized("同步目标"))
    }

    private var actions: some View {
        HStack(spacing: 0) {
            action("tag", label: "编辑标签", action: editTags)
            if skill.canUpdateFromSource {
                action("arrow.triangle.2.circlepath", label: "skills.action.update", action: update)
            }
            if !skill.targets.isEmpty {
                action("arrow.up.right.circle", label: "移除同步", tint: Theme.accentText, action: unsync)
            } else if !skill.isSourceUnavailable {
                action("arrow.triangle.2.circlepath.circle", label: "同步", tint: Theme.accentText, action: sync)
            }
            action("trash", label: "删除", tint: Theme.danger, action: delete)
        }
        .disabled(busy)
    }

    private func action(
        _ symbol: String,
        label: String,
        tint: Color = Theme.mutedForeground,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CCIconButtonStyle(tint: tint))
            .help(appLanguage.localized(label))
            .accessibilityLabel(accessibilityActionLabel(label))
    }

    private func accessibilityActionLabel(_ action: String) -> String {
        switch action {
        case "编辑标签": appLanguage.localized("编辑 \(skill.name) 的标签")
        case "skills.action.update": appLanguage.localized("更新 Skill \(skill.name)")
        case "同步": appLanguage.localized("同步 Skill \(skill.name)")
        case "移除同步": appLanguage.localized("移除 Skill \(skill.name) 的同步")
        case "删除": appLanguage.localized("删除 Skill \(skill.name)")
        default: appLanguage.localized(action)
        }
    }

    private func isIssue(_ status: String) -> Bool {
        let value = status.lowercased()
        return ["missing", "invalid", "error", "broken", "fail", "unavailable"]
            .contains { value.contains($0) }
    }
}
