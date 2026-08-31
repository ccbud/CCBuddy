import SwiftUI

struct SkillsToolsView: View {
    let snapshot: SkillsSnapshot
    let globallyBusy: Bool
    let syncAll: (SkillTool, [ManagedSkill]) -> Void
    let unsyncAll: (SkillTool, [ManagedSkill]) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @State private var showMissing = false
    @State private var pendingUnsync: ToolSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                metrics
                CCSectionHeader(appLanguage.localized("已配置工具")) {
                    Text(appLanguage.localized("选择哪些已检测工具可以接收 Skills。"))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                }
                configuredTools
                if !missingTools.isEmpty { missingSection }
            }
            .pageContent(measure: 1_120)
        }
        .confirmationDialog(
            appLanguage.localized("移除全部同步？"),
            isPresented: Binding(
                get: { pendingUnsync != nil },
                set: { if !$0 { pendingUnsync = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(appLanguage.localized("移除全部同步"), role: .destructive) {
                guard let selection = pendingUnsync else { return }
                pendingUnsync = nil
                unsyncAll(selection.tool, selection.skills)
            }
            Button(appLanguage.localized("取消"), role: .cancel) { pendingUnsync = nil }
        } message: {
            Text(appLanguage.localized("中心源副本会保留。"))
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.md)], spacing: Space.md) {
            SkillsMetricCard(title: "工具总数", value: "\(snapshot.tools.count)")
            SkillsMetricCard(title: "已启用", value: "\(snapshot.tools.filter(\.enabled).count)")
            SkillsMetricCard(title: "已检测", value: "\(snapshot.tools.filter(\.detected).count)")
            SkillsMetricCard(title: "已管理", value: "\(snapshot.skills.count)")
        }
    }

    @ViewBuilder private var configuredTools: some View {
        if configured.isEmpty {
            CCEmptyState(
                symbol: "wrench.and.screwdriver",
                title: appLanguage.localized("暂未检测到工具。"),
                message: appLanguage.localized("安装受支持的 coding agent 后刷新本页。"),
                compact: true
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xxl)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: Space.md)],
                spacing: Space.md
            ) {
                ForEach(configured) { tool in toolCard(tool) }
            }
        }
    }

    private var missingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showMissing.toggle()
            } label: {
                HStack {
                    Label(
                        appLanguage.localized("未检测到 \(missingTools.count) 个工具"),
                        systemImage: "questionmark.circle"
                    )
                    Spacer()
                    Image(systemName: showMissing ? "chevron.up" : "chevron.down")
                }
                .font(.ccBody(.medium))
                .foregroundStyle(Theme.mutedForeground)
                .padding(Space.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(appLanguage.localized(showMissing ? "已展开" : "已折叠"))
            if showMissing {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320), spacing: Space.md)],
                    spacing: Space.md
                ) {
                    ForEach(missingTools) { tool in toolCard(tool) }
                }
                .padding(Space.md)
            }
        }
        .panelSurface()
    }

    private func toolCard(_ tool: SkillTool) -> some View {
        let synced = syncedSkills(for: tool)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                SkillsToolMark(label: tool.label, active: tool.detected)
                    .scaleEffect(1.35)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: tool.label).font(.ccBody(.semibold)).lineLimit(1)
                    CCStatusLabel(
                        text: appLanguage.localized(tool.detected ? "已检测" : "未检测到"),
                        tint: tool.detected ? Theme.success : Theme.mutedForeground
                    )
                }
                Spacer(minLength: Space.sm)
                CCBadge(text: modeTitle(tool.defaultSyncMode))
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(appLanguage.localized("Skills 目录"))
                    .font(.ccLabel()).foregroundStyle(Theme.faintForeground)
                Text(verbatim: tool.path.path)
                    .font(.ccMono(Typography.caption))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Divider()
            HStack(spacing: Space.sm) {
                Text(appLanguage.localized("共享 \(synced.count) 个 Skills"))
                    .font(.ccCaption()).foregroundStyle(Theme.mutedForeground).monospacedDigit()
                Spacer(minLength: 0)
                Button(appLanguage.localized("移除全部同步")) {
                    pendingUnsync = ToolSelection(tool: tool, skills: synced)
                }
                .buttonStyle(.ccSecondary)
                .disabled(synced.isEmpty || globallyBusy)
                Button(appLanguage.localized("同步全部 Skills")) {
                    syncAll(tool, snapshot.skills.filter { !$0.isSourceUnavailable })
                }
                .buttonStyle(.ccPrimary)
                .disabled(!tool.detected || !tool.enabled || snapshot.skills.isEmpty || globallyBusy)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .opacity(tool.detected ? 1 : 0.72)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.tool.\(tool.key)")
    }

    private var configured: [SkillTool] {
        snapshot.tools.filter { $0.detected }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var missingTools: [SkillTool] {
        snapshot.tools.filter { !$0.detected }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func syncedSkills(for tool: SkillTool) -> [ManagedSkill] {
        snapshot.skills.filter { skill in skill.targets.contains { $0.key == tool.key } }
    }

    private func modeTitle(_ mode: SkillSyncMode) -> String {
        appLanguage.localized(mode == .auto ? "自动" : mode == .symlink ? "符号链接" : "复制")
    }

    private struct ToolSelection: Identifiable {
        let tool: SkillTool
        let skills: [ManagedSkill]
        var id: String { tool.key }
    }
}
