import SwiftUI

struct SkillsInstallOptionsView: View {
    let tools: [SkillTool]
    @Binding var tags: String
    @Binding var selectedToolKeys: Set<String>
    @Binding var syncMode: SkillSyncMode

    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(appLanguage.localized("添加标签"))
                    .font(.ccBody(.medium))
                TextField(appLanguage.localized("例如：开发、效率…"), text: $tags)
                    .textFieldStyle(.roundedBorder)
                    .font(.ccBody())
                    .accessibilityIdentifier("skills.add.tags")
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Text(appLanguage.localized("安装到工具"))
                    .font(.ccBody(.medium))
                if availableTools.isEmpty {
                    Text(appLanguage.localized("未检测到可用工具"))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                } else {
                    FlowLayout(spacing: Space.sm) {
                        ForEach(availableTools) { tool in
                            let selected = selectedToolKeys.contains(tool.key)
                            Button {
                                if !selectedToolKeys.insert(tool.key).inserted {
                                    selectedToolKeys.remove(tool.key)
                                }
                            } label: {
                                HStack(spacing: Space.xs + 2) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    Text(verbatim: tool.label).lineLimit(1)
                                }
                            }
                            .buttonStyle(selected ? .ccPrimary : .ccSecondary)
                            .accessibilityValue(selected ? appLanguage.localized("已选择") : "")
                        }
                    }
                }
            }

            HStack(spacing: Space.md) {
                Text(appLanguage.localized("同步模式"))
                    .font(.ccBody(.medium))
                Picker(appLanguage.localized("同步模式"), selection: $syncMode) {
                    Text(appLanguage.localized("自动")).tag(SkillSyncMode.auto)
                    Text(appLanguage.localized("符号链接")).tag(SkillSyncMode.symlink)
                    Text(appLanguage.localized("复制")).tag(SkillSyncMode.copy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .accessibilityIdentifier("skills.add.sync-mode")
            }
        }
    }

    private var availableTools: [SkillTool] {
        tools.filter { $0.detected && $0.enabled }
    }
}

extension String {
    var parsedSkillTags: [String] {
        var seen = Set<String>()
        return components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
