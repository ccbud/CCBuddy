import AppKit
import SwiftUI

struct AboutVersionPresentation: Equatable {
    static let bifrostVersion = "v1.6.11"

    let current: String
    let latest: String

    init(updateState: UpdateState, fallbackCurrentVersion: String) {
        current = switch updateState {
        case .idle(let version), .checking(let version), .upToDate(let version, _),
             .failed(let version, _): version
        default: fallbackCurrentVersion
        }
        latest = switch updateState {
        case .upToDate(let version, _): version
        case .available(let release), .downloading(let release):
            release.version.description
        case .staged(let staged), .installing(let staged):
            staged.release.version.description
        case .installed(let installed), .installedAwaitingRestart(let installed):
            installed.staged.release.version.description
        case .manualDownload(let release, _):
            release?.version.description ?? "—"
        default: "—"
        }
    }
}

struct AboutSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            identity
            updates
        }
    }

    /// Wake's About order: product mark, name, version, tagline, project link, a short rule, then
    /// the license and the author. A page titled "About" that only offered an update button never
    /// actually said what the application is.
    private var identity: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .center, spacing: Space.lg) {
                AppLogo().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "CC Buddy")
                        .font(.system(size: Typography.display, weight: .medium))
                    Text(verbatim: runningVersion)
                        .font(.ccMono(Typography.caption))
                        .foregroundStyle(Theme.mutedForeground)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("about.identity.version")
                }
                Spacer(minLength: 0)
            }

            Text(appLanguage.localized("管理并复盘本机 Coding Agent CLI 的会话，附带一个本地模型网关。"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            Button("github.com/ccbud/ccbud") { open("https://github.com/ccbud/ccbud") }
                .buttonStyle(.link)
                .font(.ccCaption())
                .accessibilityIdentifier("about.identity.repository")

            Rectangle()
                .fill(Theme.separator)
                .frame(width: 120, height: 1)
                .padding(.vertical, Space.xs)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "© 2026 loadchange · GPL-3.0")
                Text(appLanguage.localized("会话与网关数据只保存在本机。"))
            }
            .font(.ccLabel())
            .foregroundStyle(Theme.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updates: some View {
        SettingsCard("检查更新") {
            HStack(spacing: 36) {
                versionColumn(
                    "当前版本",
                    value: versions.current,
                    identifier: "about.version.current"
                )
                versionColumn(
                    "最新版本",
                    value: versions.latest,
                    identifier: "about.version.latest"
                )
                Spacer()
                if model.updateState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(primaryButtonTitle)
                }
                Button(primaryButtonTitle, action: primaryAction)
                    .buttonStyle(CompactActionButtonStyle(primary: true))
                    .disabled(model.updateState.isBusy || isRestartPending)
                    .accessibilityIdentifier("about.update.primary")
            }
            Text(statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(statusIsWarning ? Theme.danger : Theme.mutedForeground)
                .textSelection(.enabled)

            HStack(spacing: 5) {
                Text("Bifrost")
                Text(AboutVersionPresentation.bifrostVersion)
                    .fontDesign(.monospaced)
                    .accessibilityIdentifier("about.bifrost.version")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.mutedForeground)
            .accessibilityElement(children: .contain)

            if let notes = releaseNotes {
                Text(notes)
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            SettingsDivider()
            HStack(spacing: 26) {
                Toggle(
                    "自动检查更新",
                    isOn: Binding(
                        get: { model.config.autoUpdate.check },
                        set: { enabled in Task { await model.setAutoUpdate(check: enabled) } }
                    )
                )
                .toggleStyle(.switch).controlSize(.small)
                Toggle(
                    "自动下载",
                    isOn: Binding(
                        get: { model.config.autoUpdate.autoDownload },
                        set: { enabled in Task { await model.setAutoUpdate(autoDownload: enabled) } }
                    )
                )
                .toggleStyle(.switch).controlSize(.small)
            }
            Text("原生版本只会安装已签名并通过公证的完整更新。")
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)

            SettingsDivider()
            HStack(spacing: 10) {
                Button("项目主页") { open("https://github.com/ccbud/ccbud") }
                    .buttonStyle(.link)
                Text("·").foregroundStyle(Theme.mutedForeground)
                Button("发布记录") { open("https://github.com/ccbud/ccbud/releases") }
                    .buttonStyle(.link)
            }
            .font(.ccCaption())
        }
    }

    private var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var versions: AboutVersionPresentation {
        AboutVersionPresentation(
            updateState: model.updateState,
            fallbackCurrentVersion: runningVersion
        )
    }

    private var primaryButtonTitle: String {
        let source = switch model.updateState {
        case .checking: "正在检查…"
        case .available: "下载并验证"
        case .downloading: "正在下载…"
        case .staged: "安装并重启"
        case .installing: "正在安装…"
        case .installed: "正在重启…"
        case .installedAwaitingRestart: "立即重启更新"
        case .manualDownload: "前往完整下载"
        default: "检查更新"
        }
        return appLanguage.localized(source)
    }

    private var isRestartPending: Bool {
        if case .installed = model.updateState { return true }
        return false
    }

    private var statusIsWarning: Bool {
        switch model.updateState {
        case .manualDownload, .failed: true
        default: false
        }
    }

    private var statusMessage: String {
        let source = switch model.updateState {
        case .idle:
            "点击“检查更新”查看是否有新版本。"
        case .checking:
            "正在通过 HTTPS 获取发布元数据…"
        case .upToDate(_, let checkedAt):
            "已是最新版本 · \(formattedCheckedAt(checkedAt))"
        case .available(let release):
            "发现 v\(release.version)。下载后会先验证发布者签名、应用签名和公证。"
        case .downloading(let release):
            "正在下载并验证 v\(release.version)…"
        case .staged(let staged):
            "v\(staged.release.version) 已通过完整性、Developer ID 和随附公证验证。"
        case .installing(let staged):
            "正在以可回滚的原子替换方式安装 v\(staged.release.version)…"
        case .installed(let installed):
            "v\(installed.staged.release.version) 已安装，正在安全退出并重新打开。"
        case .installedAwaitingRestart:
            "已下载新版本，将在下次启动时生效。"
        case .manualDownload(_, let reason):
            "应用内安装已停止：\(reason) 请从发布页下载完整安装包。"
        case .failed(_, let message):
            message
        }
        return appLanguage.localized(source)
    }

    private var releaseNotes: String? {
        switch model.updateState {
        case .available(let release), .downloading(let release): release.notes
        case .staged(let staged), .installing(let staged): staged.release.notes
        case .installed(let installed), .installedAwaitingRestart(let installed):
            installed.staged.release.notes
        case .manualDownload(let release, _): release?.notes
        default: nil
        }
    }

    private func primaryAction() {
        switch model.updateState {
        case .available:
            Task { await model.downloadUpdate() }
        case .staged:
            Task { await model.installUpdateAndRelaunch() }
        case .installedAwaitingRestart:
            model.relaunchInstalledUpdate()
        case .manualDownload(let release, _):
            open((release?.releasePageURL.absoluteString)
                ?? "https://github.com/ccbud/ccbud/releases/latest")
        case .checking, .downloading, .installing, .installed:
            break
        default:
            Task { await model.checkForUpdates() }
        }
    }

    private func versionColumn(_ title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appLanguage.localized(title).uppercased())
                .font(.ccLabel(.medium))
                .tracking(0.4)
                .foregroundStyle(Theme.mutedForeground)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .accessibilityIdentifier(identifier)
        }
    }

    private func formattedCheckedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
