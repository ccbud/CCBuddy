import SwiftUI

struct SkillsBulkSyncSheet: View {
    let skills: [ManagedSkill]
    let tools: [SkillTool]
    let apply: ([String], SkillSyncMode) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKeys = Set<String>()
    @State private var mode = SkillSyncMode.auto

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(appLanguage.localized("同步所选")).font(.ccHeading())
                Text(appLanguage.localized("将同步 \(skills.count) 个 Skills"))
                    .font(.ccCaption()).foregroundStyle(Theme.mutedForeground).monospacedDigit()
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.list)
            .hairline(.bottom)

            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(appLanguage.localized("目标工具")).font(.ccBody(.medium))
                    if availableTools.isEmpty {
                        Text(appLanguage.localized("未检测到可用工具"))
                            .font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
                    } else {
                        FlowLayout(spacing: Space.sm) {
                            ForEach(availableTools) { tool in toolChoice(tool) }
                        }
                    }
                }
                HStack(spacing: Space.md) {
                    Text(appLanguage.localized("同步模式")).font(.ccBody(.medium))
                    Picker(appLanguage.localized("同步模式"), selection: $mode) {
                        Text(appLanguage.localized("自动")).tag(SkillSyncMode.auto)
                        Text(appLanguage.localized("符号链接")).tag(SkillSyncMode.symlink)
                        Text(appLanguage.localized("复制")).tag(SkillSyncMode.copy)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            }
            .padding(Space.xl)

            HStack(spacing: Space.sm) {
                Spacer()
                Button(appLanguage.localized("取消")) { dismiss() }
                    .buttonStyle(.ccSecondary)
                Button(appLanguage.localized("应用同步设置")) {
                    apply(Array(selectedKeys), mode)
                    dismiss()
                }
                .buttonStyle(.ccPrimary)
                .disabled(selectedKeys.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
            .background(Theme.list)
            .hairline(.top)
        }
        .frame(width: 520)
        .background(Theme.background)
        .onAppear { selectedKeys = Set(availableTools.map(\.key)) }
        .accessibilityContainerIdentifier(
            "skills.sync.sheet",
            label: appLanguage.localized("同步所选")
        )
    }

    private func toolChoice(_ tool: SkillTool) -> some View {
        let selected = selectedKeys.contains(tool.key)
        return Button {
            if !selectedKeys.insert(tool.key).inserted { selectedKeys.remove(tool.key) }
        } label: {
            Label(tool.label, systemImage: selected ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(selected ? .ccPrimary : .ccSecondary)
        .accessibilityValue(selected ? appLanguage.localized("已选择") : "")
    }

    private var availableTools: [SkillTool] {
        tools.filter { $0.detected && $0.enabled }
    }
}
