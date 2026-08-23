import AppKit
import SwiftUI

struct DataSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @State private var directoryStatistics: [String: HistoryDirectoryStatistic] = [:]

    var body: some View {
        SettingsCard("工作目录") {
            HStack(alignment: .top, spacing: 16) {
                Text("会话与用量统计的数据来源 —— 每个工作目录都会同时扫描 Claude Code 会话（projects/）与 Codex 会话（sessions/）。~/.claude 始终保留，检测到 Codex 时会自动加入 ~/.codex；若用 CLAUDE_CONFIG_DIR / CODEX_HOME 等指定了其他位置，在此添加，可在「会话」页切换查看。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccCaption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("选择目录…", action: chooseDirectory)
                    .buttonStyle(CompactActionButtonStyle(primary: true))
            }

            VStack(spacing: 8) {
                ForEach(model.config.historyDirs, id: \.self) { directory in
                    directoryRow(directory)
                }
            }
        }
        .task(id: model.config.historyDirs.joined(separator: "\u{0}")) {
            let statistics = await model.historyDirectoryStatistics()
            directoryStatistics = Dictionary(uniqueKeysWithValues: statistics.map { ($0.id, $0) })
        }
    }

    private func directoryRow(_ directory: String) -> some View {
        let statistic = directoryStatistics[directory]
        let exists = statistic?.exists ?? FileManager.default.fileExists(atPath: expanded(directory))
        return HStack(spacing: 12) {
            Text(directory)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(exists ? Color.ccForeground : Color.ccMuted)
                .lineLimit(1)
            Spacer()
            Text(appLanguage.localized(
                exists ? "\(statistic?.sessionCount ?? 0) 会话" : "目录不存在"
            ))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(exists ? Color.ccGreen : Color.ccRed)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(exists ? Color.ccGreenSoft : Color.ccRedSoft)
                .clipShape(Capsule())
            Button {
                Task { await model.removeHistoryDirectory(directory) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ccMuted)
            .disabled(directory == "~/.claude")
            .opacity(directory == "~/.claude" ? 0.25 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ccBorder))
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = appLanguage.localized("选择工作目录（含 projects/ 或 sessions/）")
        panel.prompt = appLanguage.localized("选择")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let selected = Self.historyRoot(for: url)
            Task { @MainActor in await model.addHistoryDirectory(selected.path) }
        }
    }

    static func historyRoot(for selectedURL: URL) -> URL {
        ["projects", "sessions"].contains(selectedURL.lastPathComponent)
            ? selectedURL.deletingLastPathComponent()
            : selectedURL
    }

    private func expanded(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(suffix).path
    }
}
