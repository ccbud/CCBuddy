import AppKit
import Darwin
import SwiftUI

/// Count each regular inode once: immutable tgrep checkpoints may share hard-linked files.
/// Symlinks are not followed, and no transcript content is opened just to report storage usage.
enum ConversationStorageFootprint {
    static func bytes(in roots: [URL]) -> Int64 {
        struct Identity: Hashable { let device: Int32; let inode: UInt64 }
        var seen = Set<Identity>()
        var pending = roots
        var total: Int64 = 0
        while let file = pending.popLast(), !Task.isCancelled {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR,
                  seen.insert(.init(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
            if kind == S_IFDIR {
                pending.append(contentsOf: (try? FileManager.default.contentsOfDirectory(
                    at: file, includingPropertiesForKeys: nil)) ?? [])
            } else if info.st_size > 0, total <= Int64.max - info.st_size {
                total += info.st_size
            }
        }
        return total
    }
}

/// What CC Buddy itself stores on disk.
///
/// Source directories moved to Locations; this pane now answers the two questions people actually
/// come here with — where does my data live, and how big has the index grown. Both are stated, and
/// the only actions are the two that follow from them.
struct DataSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage

    @State private var indexBytes: Int64?
    @State private var legacyBytes: Int64 = 0
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
                if legacyBytes > 0 {
                    infoRow(appLanguage.localized("旧版缓存（未使用）"), value: Self.formatBytes(legacyBytes))
                }
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
        let sizes = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
            let legacyNames = [
                "conversation-index-v1.sqlite3",
                "conversation-index-v1.sqlite3-wal",
                "conversation-index-v1.sqlite3-shm",
                "conversation-index-v1.sqlite3.tgrep-v2",
                "conversation-index-v1.sqlite3.tgrep-chunks-v1",
            ]
            return (ConversationStorageFootprint.bytes(in: [directory.appendingPathComponent("conversation-catalog-v1")]),
                ConversationStorageFootprint.bytes(in: legacyNames.map { directory.appendingPathComponent($0) }))
        }.value
        guard !Task.isCancelled else { return }
        indexBytes = sizes.0
        legacyBytes = sizes.1

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
