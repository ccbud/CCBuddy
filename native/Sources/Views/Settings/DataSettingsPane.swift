import AppKit
import SwiftUI

/// What CC Buddy itself stores on disk.
///
/// Source directories moved to Locations; this pane now answers the two questions people actually
/// come here with — where does my data live, and how big has the index grown. Both are stated, and
/// the only actions are the two that follow from them.
struct DataSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage

    @State private var indexBytes: Int64?
    @State private var sessionCount: Int?

    private var storageDirectory: URL {
        ConfigRepository.defaultConfigURL().deletingLastPathComponent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                CCSectionHeader(appLanguage.localized("本地存储")) {
                    Button(appLanguage.localized("在访达中显示")) {
                        NSWorkspace.shared.selectFile(
                            nil,
                            inFileViewerRootedAtPath: storageDirectory.path
                        )
                    }
                    .buttonStyle(.ccSecondary)
                    .accessibilityIdentifier("settings.data.reveal")
                }

                Text(appLanguage.localized("设置、会话元数据与可重建的搜索索引都保存在这里。重装应用不会丢失它们。"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 1) {
                infoRow(appLanguage.localized("位置"), value: storageDirectory.path, monospaced: true)
                infoRow(
                    appLanguage.localized("会话索引"),
                    value: indexBytes.map(Self.formatBytes) ?? appLanguage.localized("正在统计…")
                )
                infoRow(
                    appLanguage.localized("已收录会话"),
                    value: sessionCount.map { appLanguage.localized("\($0) 个会话") }
                        ?? appLanguage.localized("正在统计…"),
                    isLast: true
                )
            }
            .panelSurface(bordered: true)

            VStack(alignment: .leading, spacing: Space.sm) {
                CCSectionHeader(appLanguage.localized("索引")) {
                    Button(appLanguage.localized("重建索引")) {
                        model.conversationStore.retryIndexing()
                    }
                    .buttonStyle(.ccSecondary)
                    .disabled(model.conversationStore.indexingState.isScanning)
                    .accessibilityIdentifier("settings.data.reindex")
                }

                Text(appLanguage.localized("索引只是原始会话文件的一份可重建副本。删除它不会影响任何 CLI 写下的会话；下次启动会重新扫描。"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refresh() }
        .task(id: model.conversationStore.indexingState) { await refresh() }
    }

    private func infoRow(
        _ title: String,
        value: String,
        monospaced: Bool = false,
        isLast: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(title)
                .font(.ccBody())
                .foregroundStyle(Theme.foreground)
            Spacer(minLength: Space.sm)
            Text(value)
                .font(monospaced ? .ccMono(Typography.caption) : .ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.separator).frame(height: 1) }
        }
    }

    private func refresh() async {
        let directory = storageDirectory
        let bytes = await Task.detached(priority: .utility) { () -> Int64 in
            let manager = FileManager.default
            let names = [
                "conversation-index-v1.sqlite3",
                "conversation-index-v1.sqlite3-wal",
                "conversation-index-v1.sqlite3-shm",
            ]
            return names.reduce(into: Int64(0)) { total, name in
                let path = directory.appendingPathComponent(name).path
                let size = (try? manager.attributesOfItem(atPath: path)[.size]) as? NSNumber
                total += size?.int64Value ?? 0
            }
        }.value
        indexBytes = bytes

        let statistics = await model.historyDirectoryStatistics()
        sessionCount = statistics.reduce(0) { $0 + $1.sessionCount }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
