import AppKit
import SwiftUI

/// Where CC Buddy looks for sessions.
///
/// This used to live inside the Data pane under the heading "工作目录", which put storage
/// housekeeping and source configuration in the same list and left the sidebar duplicating the same
/// roots as a navigation group. Locations is now the single place roots are added, inspected and
/// removed; the sidebar groups by agent and project instead, which is what people actually browse by.
struct LocationsSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage

    @State private var statistics: [String: HistoryDirectoryStatistic] = [:]

    /// The one root the app cannot run without; removing it would leave Claude Code invisible.
    private static let protectedDirectory = "~/.claude"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                CCSectionHeader(appLanguage.localized("会话位置")) {
                    Button {
                        chooseDirectory()
                    } label: {
                        Label(appLanguage.localized("添加位置"), systemImage: "plus")
                    }
                    .buttonStyle(.ccSecondary)
                    .accessibilityIdentifier("settings.locations.add")
                }

                Text(appLanguage.localized("每个位置都会同时扫描 Claude Code 的 projects/ 与 Codex 的 sessions/，以及 Grok、Copilot、Antigravity、Qoder 的会话树。检测到对应 CLI 时其默认位置会自动加入；用 CLAUDE_CONFIG_DIR、CODEX_HOME 等指定过其他路径时在这里补上。"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 1) {
                ForEach(Array(model.config.historyDirs.enumerated()), id: \.element) { index, directory in
                    locationRow(directory, isFirst: index == 0, isLast: index == model.config.historyDirs.count - 1)
                }
            }
            .panelSurface(bordered: true)

            Text(appLanguage.localized("CC Buddy 只读取这些目录，不会修改各 CLI 写下的原始会话文件。停用某个位置会保留它的配置与已建索引，重新启用即可增量扫回。"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: model.config.historyDirs.joined(separator: "\u{0}")) {
            let values = await model.historyDirectoryStatistics()
            statistics = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        }
    }

    /// The path is the primary information; the session count is a muted aside. A missing root is
    /// stated in words next to the path rather than shouted with a red pill.
    private func locationRow(_ directory: String, isFirst: Bool, isLast: Bool) -> some View {
        let statistic = statistics[directory]
        let exists = statistic?.exists ?? FileManager.default.fileExists(atPath: Self.expanded(directory))
        let protected = directory == Self.protectedDirectory
        let enabled = model.config.isHistoryDirectoryEnabled(directory)

        return HStack(spacing: Space.md) {
            Image(systemName: exists ? "folder" : "folder.badge.questionmark")
                .font(.system(size: Typography.body))
                .foregroundStyle(exists ? Theme.mutedForeground : Theme.faintForeground)
                .frame(width: Rail.leadBox)

            VStack(alignment: .leading, spacing: 1) {
                Text(directory)
                    .font(.ccMono(Typography.caption))
                    .foregroundStyle(exists ? Theme.foreground : Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(exists: exists, enabled: enabled, statistic: statistic))
                    .font(.ccLabel())
                    .foregroundStyle(Theme.mutedForeground)
            }

            Spacer(minLength: Space.sm)

            Toggle("", isOn: Binding(
                get: { enabled },
                set: { value in Task { await model.setHistoryDirectoryEnabled(directory, value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(appLanguage.localized(enabled ? "停止扫描这个位置" : "重新扫描这个位置"))
            .accessibilityLabel(appLanguage.localized("启用会话位置"))
            .accessibilityIdentifier("settings.locations.toggle.\(SidebarIdentifier.stable(directory))")

            Menu {
                Button(appLanguage.localized("在访达中显示")) { reveal(directory) }
                if !protected {
                    Divider()
                    Button(appLanguage.localized("移除位置"), role: .destructive) {
                        Task { await model.removeHistoryDirectory(directory) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Typography.caption, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.mutedForeground)
            .help(appLanguage.localized(protected ? "默认位置不可移除" : "位置操作"))
            .accessibilityLabel(appLanguage.localized("位置操作"))
            .accessibilityIdentifier("settings.locations.menu.\(SidebarIdentifier.stable(directory))")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.separator).frame(height: 1) }
        }
        // A switched-off row recedes as a whole rather than repeating "Disabled" as a badge.
        .opacity(exists && enabled ? 1 : 0.55)
        .accessibilityIdentifier("settings.locations.row.\(SidebarIdentifier.stable(directory))")
    }

    private func subtitle(
        exists: Bool,
        enabled: Bool,
        statistic: HistoryDirectoryStatistic?
    ) -> String {
        guard exists else { return appLanguage.localized("目录不存在") }
        let count = appLanguage.localized("\(statistic?.sessionCount ?? 0) 个会话")
        return enabled ? count : "\(count) · \(appLanguage.localized("已停用"))"
    }

    private func reveal(_ directory: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.expanded(directory))
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = appLanguage.localized("选择会话位置（含 projects/ 或 sessions/）")
        panel.prompt = appLanguage.localized("选择")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let selected = Self.historyRoot(for: url)
            Task { @MainActor in await model.addHistoryDirectory(selected.path) }
        }
    }

    /// Picking the `projects/` or `sessions/` folder itself is the obvious mistake; accept it and
    /// register the parent, which is what the scanners expect.
    static func historyRoot(for selectedURL: URL) -> URL {
        ["projects", "sessions"].contains(selectedURL.lastPathComponent)
            ? selectedURL.deletingLastPathComponent()
            : selectedURL
    }

    static func expanded(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(suffix).path
    }
}
