import SwiftUI

struct SkillsSyncPanel: View {
    let skill: ManagedSkill
    let tools: [SkillTool]
    let busy: Bool
    let apply: ([String], [String], SkillSyncMode) -> Void
    let removeAll: ([String]) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @State private var selectedKeys = Set<String>()
    @State private var mode = SkillSyncMode.auto

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(appLanguage.localized("同步设置")).font(.ccBody(.medium))
                Spacer()
                SkillsStatusBadge(style: skill.presentationStatus)
            }
            Text(appLanguage.localized("目标工具"))
                .font(.ccCaption(.medium))
                .foregroundStyle(Theme.mutedForeground)
            if visibleTools.isEmpty {
                Text(appLanguage.localized("未检测到可用工具"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.faintForeground)
            } else {
                FlowLayout(spacing: Space.sm) {
                    ForEach(visibleTools) { tool in toolChoice(tool) }
                }
            }
            HStack(spacing: Space.md) {
                Text(appLanguage.localized("同步模式"))
                    .font(.ccCaption(.medium))
                    .foregroundStyle(Theme.mutedForeground)
                Picker(appLanguage.localized("同步模式"), selection: $mode) {
                    Text(appLanguage.localized("自动")).tag(SkillSyncMode.auto)
                    Text(appLanguage.localized("符号链接")).tag(SkillSyncMode.symlink)
                    Text(appLanguage.localized("复制")).tag(SkillSyncMode.copy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            HStack(spacing: Space.sm) {
                Button(appLanguage.localized("应用同步设置")) {
                    apply(Array(keysToSync), Array(keysToRemove), mode)
                }
                .buttonStyle(.ccPrimary)
                .disabled(!canApply || busy)
                Button(appLanguage.localized("移除全部同步")) {
                    removeAll(skill.targets.map(\.key))
                }
                .buttonStyle(.ccSecondary)
                .disabled(skill.targets.isEmpty || busy)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .onAppear(perform: reset)
        .onChange(of: skill.targets.map(\.key)) { _ in reset() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.detail.sync")
    }

    private func toolChoice(_ tool: SkillTool) -> some View {
        let selected = selectedKeys.contains(tool.key)
        let available = tool.detected && tool.enabled
        let canToggle = Self.canToggle(tool, for: skill)
        return Button {
            guard canToggle else { return }
            if !selectedKeys.insert(tool.key).inserted { selectedKeys.remove(tool.key) }
        } label: {
            HStack(spacing: Space.xs + 2) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(verbatim: tool.label).lineLimit(1)
                if !available {
                    Text(appLanguage.localized("未检测到"))
                        .font(.ccLabel())
                        .foregroundStyle(Theme.faintForeground)
                }
            }
        }
        .buttonStyle(selected && available ? .ccPrimary : .ccSecondary)
        .disabled(!canToggle)
        .opacity(available ? 1 : 0.65)
        .accessibilityValue(selected ? appLanguage.localized("已选择") : "")
    }

    static func canToggle(_ tool: SkillTool, for skill: ManagedSkill) -> Bool {
        (tool.detected && tool.enabled) || skill.targets.contains { $0.key == tool.key }
    }

    private var visibleTools: [SkillTool] {
        let known = Dictionary(uniqueKeysWithValues: tools.map { ($0.key, $0) })
        var result = tools.filter { tool in
            (tool.detected && tool.enabled) || skill.targets.contains { $0.key == tool.key }
        }
        for target in skill.targets where known[target.key] == nil {
            result.append(SkillTool(
                key: target.key,
                label: target.key,
                path: target.path,
                detected: false,
                enabled: false,
                defaultSyncMode: target.syncMode,
                sharedKeys: [],
                projectPath: nil,
                sharedProjectKeys: []
            ))
        }
        return result.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var selectedAvailableKeys: Set<String> {
        let available = Set(tools.filter { $0.detected && $0.enabled }.map(\.key))
        return selectedKeys.intersection(available)
    }

    private var keysToSync: Set<String> {
        skill.isSourceUnavailable ? [] : selectedAvailableKeys
    }

    private var keysToRemove: Set<String> {
        Self.keysToRemove(for: skill, selectedKeys: selectedKeys)
    }

    static func keysToRemove(for skill: ManagedSkill, selectedKeys: Set<String>) -> Set<String> {
        Set(skill.targets.map(\.key)).subtracting(selectedKeys)
    }

    private var canApply: Bool { !keysToSync.isEmpty || !keysToRemove.isEmpty }

    private func reset() {
        selectedKeys = Set(skill.targets.map(\.key))
        mode = skill.targets.first?.syncMode ?? .auto
        if selectedKeys.isEmpty {
            selectedKeys = Set(tools.filter { $0.detected && $0.enabled }.map(\.key))
        }
    }
}
