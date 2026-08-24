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
                Text("本机 CC Buddy 网关服务：接入的 CLI 都通过它转发请求。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccCaption)

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
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ccRed)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.ccRedSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            SettingsCard("接入目标") {
                Text("开关会立即、原子地写入或恢复各 CLI 的配置文件。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccCaption)
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
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ccCaption)
                }
            }

            SettingsCard("高级") {
                SettingsToggleRow(
                    "网关故障转移",
                    detail: "当前服务不可用时，按顺序尝试备用服务。重试次数是整条队列的总预算。",
                    isOn: Binding(
                        get: { model.config.gatewayFailover.enabled },
                        set: { enabled in Task { await model.setGatewayFailoverEnabled(enabled) } }
                    ),
                    enabled: model.config.providers.count > 1 && !model.cliRecoveryRequired
                )
                if model.config.gatewayFailover.enabled {
                    failoverQueue
                    SettingsDivider()
                }
                SettingsToggleRow(
                    "429 自动重试",
                    detail: "供应商限流时由网关重试策略处理。",
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

    private var failoverQueue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("故障转移顺序")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ccCaption)

            ForEach(Array(queuedFailoverProviders.enumerated()), id: \.element.id) { index, provider in
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.ccMuted)
                        .frame(width: 18)
                    Text(provider.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if provider.id == model.config.activeProviderId {
                        Text("当前")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.ccBrandStrong)
                    }
                    Spacer()
                    Button {
                        Task { await model.moveGatewayFailoverProvider(provider.id, by: -1) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0 || model.cliRecoveryRequired)
                    .accessibilityLabel("上移备用服务")
                    Button {
                        Task { await model.moveGatewayFailoverProvider(provider.id, by: 1) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        index >= queuedFailoverProviders.count - 1 || model.cliRecoveryRequired
                    )
                    .accessibilityLabel("下移备用服务")
                    Button {
                        Task { await model.setGatewayFailoverProvider(provider.id, enabled: false) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        (model.config.gatewayFailover.enabled && queuedFailoverProviders.count == 1)
                            || model.cliRecoveryRequired
                    )
                    .accessibilityLabel("移出故障转移队列")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.ccInput)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))
            }

            if !unqueuedFailoverProviders.isEmpty {
                Menu("添加备用服务") {
                    ForEach(unqueuedFailoverProviders) { provider in
                        Button(provider.name) {
                            Task { await model.setGatewayFailoverProvider(provider.id, enabled: true) }
                        }
                    }
                }
                .disabled(model.cliRecoveryRequired)
            }
        }
    }

    private var queuedFailoverProviders: [Provider] {
        model.config.gatewayFailover.providerIds.compactMap { id in
            model.config.providers.first(where: { $0.id == id })
        }
    }

    private var unqueuedFailoverProviders: [Provider] {
        let queued = Set(model.config.gatewayFailover.providerIds)
        return model.config.providers.filter { !queued.contains($0.id) }
    }

    private var endpointRow: some View {
        HStack(spacing: 8) {
            // SwiftUI's localized interpolation formats integers with grouping separators.
            // Endpoints are protocol text, so render the exact byte-for-byte string instead.
            Text(verbatim: GatewaySettingsPresentation.endpoint(port: model.config.port))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.ccBrandStrong)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ccInput)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))
                .accessibilityIdentifier("settings.gateway.endpoint.value")
            Button(appLanguage.localized(copiedValue == "endpoint" ? "已复制 ✓" : "复制")) {
                copy(GatewaySettingsPresentation.endpoint(port: model.config.port), marker: "endpoint")
            }
            .buttonStyle(CompactActionButtonStyle())
            .accessibilityIdentifier("settings.gateway.endpoint.copy")
            Text("端口").font(.system(size: 12)).foregroundStyle(Color.ccMuted)
            TextField("端口", text: $portText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(width: 72)
                .background(Color.ccInput)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.ccBorder))
                .onSubmit { commitPort() }
                .disabled(model.cliRecoveryRequired)
                .accessibilityIdentifier("settings.gateway.port")
        }
    }

    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exportText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.91, green: 0.93, blue: 0.96))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.047, green: 0.055, blue: 0.071))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("settings.gateway.exports.value")
            HStack {
                Button(appLanguage.localized(copiedValue == "exports" ? "已复制 ✓" : "复制 export")) {
                    copy(exportText, marker: "exports")
                }
                .buttonStyle(CompactActionButtonStyle())
                .accessibilityIdentifier("settings.gateway.exports.copy")
                Text(appLanguage.localized("Claude 配置：") + claudeSettingsPath)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ccCaption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(CLIConnectionManager().claudeSettingsURL.path)
                    .accessibilityLabel(appLanguage.localized("Claude 配置："))
                    .accessibilityValue(claudeSettingsPath)
                    .accessibilityIdentifier("settings.gateway.claude-config.path")
            }
            Text("若曾在终端 export ANTHROPIC_BASE_URL，请删除旧值以免覆盖。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ccCaption)
        }
    }

    private var claudeSettingsPath: String {
        GatewaySettingsPresentation.claudeSettingsDisplayPath()
    }

    private var exportText: String {
        let token = model.config.requireToken && !model.config.gatewayToken.isEmpty
            ? model.config.gatewayToken : "ccbud-local"
        return "export ANTHROPIC_BASE_URL=http://localhost:\(model.config.port)\n"
            + "export ANTHROPIC_AUTH_TOKEN=\(token)"
    }

    private func connectionRow(
        title: String,
        connected: Bool,
        available: Bool,
        target: String
    ) -> some View {
        HStack(spacing: 9) {
            Text(title).font(.system(size: 12.5, weight: .medium))
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
                .font(.system(size: 12, weight: .semibold))
            Text("请按照恢复目录中的 journal.json 恢复原始文件，移除恢复目录后重新检查。")
                .font(.system(size: 11.5))
            ForEach(recovery.journalDirectories, id: \.path) { directory in
                Text(verbatim: directory.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(appLanguage.localized(recovery.detail))
                .font(.system(size: 11))
                .textSelection(.enabled)
            Button("重新检查") {
                Task { await model.recheckCLIRecovery() }
            }
            .buttonStyle(CompactActionButtonStyle())
            .accessibilityIdentifier("settings.gateway.recovery.recheck")
        }
        .foregroundStyle(Color.ccRed)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ccRedSoft)
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
