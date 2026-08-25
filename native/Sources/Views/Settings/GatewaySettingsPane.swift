import AppKit
import SwiftUI

struct GatewaySettingsPresentation {
    static func endpoint(port: Int) -> String {
        "http://localhost:\(port)"
    }

    static func claudeSettingsDisplayPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        let manager = CLIConnectionManager(environment: environment, fileManager: fileManager)
        let settingsPath = manager.claudeSettingsURL.standardizedFileURL.path
        let homeURL: URL
        if let configuredHome = environment["HOME"], !configuredHome.isEmpty {
            homeURL = URL(fileURLWithPath: configuredHome, isDirectory: true).standardizedFileURL
        } else {
            homeURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        }
        let homePath = homeURL.path
        guard settingsPath == homePath || settingsPath.hasPrefix(homePath + "/") else {
            return settingsPath
        }
        return "~" + settingsPath.dropFirst(homePath.count)
    }
}

struct GatewaySettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @State private var portText = ""
    @State private var copiedValue: String?

    var body: some View {
        VStack(spacing: 28) {
            SettingsCard("网关") {
                Text("本机 Bifrost 网关服务：接入的 CLI 都通过它转发请求。")
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)

                SettingsToggleRow(
                    "网关服务",
                    detail: "独立于接入配置的本机服务开关；停止后转发暂停，CLI 配置保持不变。",
                    isOn: Binding(
                        get: { model.config.gatewayEnabled },
                        set: { enabled in Task { await model.setGatewayEnabled(enabled) } }
                    ),
                    enabled: model.gatewayState != .starting && !model.cliRecoveryRequired
                )

                endpointRow
                codeBlock

                if let recovery = model.cliRecoveryState {
                    recoveryNotice(recovery)
                } else if let error = model.lastError, !error.isEmpty {
                    Text(appLanguage.localized(error))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.danger)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            SettingsCard("接入目标") {
                Text("开关会立即、原子地写入或恢复各 CLI 的配置文件。")
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                connectionRow(
                    title: "Claude Code",
                    connected: model.claudeConnected,
                    available: true,
                    target: CLIConnectionManager.claudeTarget
                )
                SettingsDivider()
                connectionRow(
                    title: "Codex",
                    connected: model.codexConnected,
                    available: model.codexAvailable,
                    target: CLIConnectionManager.codexTarget
                )
                if !model.codexAvailable {
                    Text("未检测到 Codex（~/.codex）。安装 Codex CLI 后可在此接入。")
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                }
            }

            SettingsCard("高级") {
                SettingsToggleRow(
                    "429 自动重试",
                    detail: "供应商限流时由 Bifrost 重试策略处理。",
                    isOn: Binding(
                        get: { model.config.retry429.enabled },
                        set: { enabled in Task { await model.setRetry429Enabled(enabled) } }
                    ),
                    enabled: !model.cliRecoveryRequired
                )
                SettingsDivider()
                SettingsToggleRow(
                    "忽略上游 TLS 证书校验",
                    detail: "会降低安全性；仅在自签名或企业代理证书导致连接失败时临时开启。",
                    isOn: Binding(
                        get: { model.config.insecureSkipVerify },
                        set: { enabled in Task { await model.setInsecureSkipVerify(enabled) } }
                    ),
                    enabled: !model.cliRecoveryRequired
                )
            }
        }
        .onAppear { portText = String(model.config.port) }
        .onChange(of: model.config.port) { portText = String($0) }
    }

    private var endpointRow: some View {
        HStack(spacing: 8) {
            // SwiftUI's localized interpolation formats integers with grouping separators.
            // Endpoints are protocol text, so render the exact byte-for-byte string instead.
            Text(verbatim: GatewaySettingsPresentation.endpoint(port: model.config.port))
                .font(.ccMono(Typography.caption))
                .foregroundStyle(Theme.foreground)
                .textSelection(.enabled)
                .padding(.horizontal, Space.sm + 2)
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .accessibilityIdentifier("settings.gateway.endpoint.value")
            Button(appLanguage.localized(copiedValue == "endpoint" ? "已复制 ✓" : "复制")) {
                copy(GatewaySettingsPresentation.endpoint(port: model.config.port), marker: "endpoint")
            }
            .buttonStyle(CompactActionButtonStyle())
            .accessibilityIdentifier("settings.gateway.endpoint.copy")
            Text("端口").font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
            TextField("端口", text: $portText)
                .textFieldStyle(.plain)
                .font(.ccMono(Typography.caption))
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
                .frame(width: 72)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .onSubmit { commitPort() }
                .disabled(model.cliRecoveryRequired)
                .accessibilityIdentifier("settings.gateway.port")
        }
    }

    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A black terminal panel is the one motif the design system rules out: it imports a
            // second visual world into a warm-paper settings page. The snippet is quiet monospace
            // on the ordinary fill instead, which reads as "text you can copy" without cosplay.
            Text(exportText)
                .font(.ccMono(Typography.caption))
                .foregroundStyle(Theme.foreground)
                .textSelection(.enabled)
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .accessibilityIdentifier("settings.gateway.exports.value")
            HStack {
                Button(appLanguage.localized(copiedValue == "exports" ? "已复制 ✓" : "复制 export")) {
                    copy(exportText, marker: "exports")
                }
                .buttonStyle(CompactActionButtonStyle())
                .accessibilityIdentifier("settings.gateway.exports.copy")
                Text(appLanguage.localized("Claude 配置：") + claudeSettingsPath)
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(CLIConnectionManager().claudeSettingsURL.path)
                    .accessibilityLabel(appLanguage.localized("Claude 配置："))
                    .accessibilityValue(claudeSettingsPath)
                    .accessibilityIdentifier("settings.gateway.claude-config.path")
            }
            Text("若曾在终端 export ANTHROPIC_BASE_URL，请删除旧值以免覆盖。")
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
        }
    }

    private var claudeSettingsPath: String {
        GatewaySettingsPresentation.claudeSettingsDisplayPath()
    }

    private var exportText: String {
        let token = model.config.requireToken && !model.config.gatewayToken.isEmpty
            ? model.config.gatewayToken : "ccbud-local"
        return "export ANTHROPIC_BASE_URL=http://localhost:\(model.config.port)/anthropic\n"
            + "export ANTHROPIC_AUTH_TOKEN=\(token)"
    }

    private func connectionRow(
        title: String,
        connected: Bool,
        available: Bool,
        target: String
    ) -> some View {
        HStack(spacing: 9) {
            Text(title).font(.ccBody())
            ConnectionBadge(connected: connected)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { connected },
                    set: { enabled in
                        Task { await model.setConnectTarget(target, enabled: enabled) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!available || model.cliRecoveryRequired)
        }
        .opacity(available ? 1 : 0.55)
    }

    private func recoveryNotice(_ recovery: AppModel.CLIRecoveryState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI 配置需要手动恢复")
                .font(.ccBody(.medium))
            Text("请按照恢复目录中的 journal.json 恢复原始文件，移除恢复目录后重新检查。")
                .font(.system(size: 11.5))
            ForEach(recovery.journalDirectories, id: \.path) { directory in
                Text(verbatim: directory.path)
                    .font(.ccMono(Typography.label))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(appLanguage.localized(recovery.detail))
                .font(.ccLabel())
                .textSelection(.enabled)
            Button("重新检查") {
                Task { await model.recheckCLIRecovery() }
            }
            .buttonStyle(CompactActionButtonStyle())
            .accessibilityIdentifier("settings.gateway.recovery.recheck")
        }
        .foregroundStyle(Theme.danger)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dangerSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.gateway.recovery")
    }

    private func commitPort() {
        guard let port = Int(portText), (1...65_535).contains(port) else {
            portText = String(model.config.port)
            return
        }
        Task { await model.setPort(port) }
    }

    private func copy(_ value: String, marker: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = marker
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedValue == marker { copiedValue = nil }
        }
    }
}
