import AppKit
import SwiftUI

struct PluginsView: View {
    private struct FormContext: Identifiable {
        let pluginID: String
        let action: PluginActionViewState
        let initialValues: [String: PluginJSONValue]
        var id: String { "\(pluginID):\(action.id)" }
    }

    private struct CallContext {
        let pluginID: String
        let action: PluginActionViewState
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @State private var showingGitImport = false
    @State private var formContext: FormContext?
    @State private var pendingCall: CallContext?
    @State private var pendingUninstall: PluginCatalogItem?

    private let documentationURL = URL(
        string: "https://github.com/ccbud/ccbud/blob/main/docs/plugin-system.md"
    )!

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(spacing: Space.md) {
                    toolbar
                    issues
                    pluginList
                }
                .pageContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task { await loadCatalogAndUpdates() }
        .sheet(isPresented: $showingGitImport) {
            PluginGitImportSheet { source in
                showingGitImport = false
                Task { await model.installPluginFromGit(source) }
            }
        }
        .sheet(item: $formContext) { context in
            PluginActionFormSheet(
                pluginID: context.pluginID,
                action: context.action,
                initialValues: context.initialValues
            )
            .environmentObject(model)
        }
        .confirmationDialog(
            pendingCall?.action.label ?? appLanguage.localized("运行插件操作"),
            isPresented: callConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(pendingCall?.action.label ?? appLanguage.localized("继续")) {
                guard let context = pendingCall else { return }
                pendingCall = nil
                Task { await runCall(context) }
            }
            Button("取消", role: .cancel) { pendingCall = nil }
        } message: {
            if let confirmation = pendingCall?.action.confirmation {
                Text(confirmation)
            } else {
                Text(appLanguage.localized("确定要继续吗？"))
            }
        }
        .confirmationDialog(
            "卸载插件",
            isPresented: uninstallConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("卸载", role: .destructive) {
                guard let item = pendingUninstall else { return }
                pendingUninstall = nil
                Task { await model.uninstallPlugin(item.id) }
            }
            Button("取消", role: .cancel) { pendingUninstall = nil }
        } message: {
            Text(appLanguage.localized(
                "将删除插件“\(pendingUninstall?.name ?? "")”及其已安装文件。此操作无法撤销。"
            ))
        }
        .alert(item: $model.pluginAlert) { alert in
            Alert(
                title: Text(alertTitle(alert.style)),
                message: Text(alert.localizesMessage
                    ? appLanguage.localized(alert.message)
                    : alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .overlay { globalBusyOverlay }
        .accessibilityContainerIdentifier("view.plugins", label: appLanguage.localized("插件"))
    }

    /// The page masthead, matching Providers: a title band on the list material that owns the
    /// window's drag strip, rather than a boxed card floating on the canvas.
    private var hero: some View {
        DestinationHeader(
            title: appLanguage.localized("插件"),
            subtitle: appLanguage.localized("复用第三方 coding agent 的本机登录态直连推理")
        ) {
            Button(appLanguage.localized("开发插件")) {
                NSWorkspace.shared.open(documentationURL)
            }
            .buttonStyle(.ccSecondary)
            .accessibilityIdentifier("plugins.documentation")
        }
        .background(Theme.list)
        .hairline(.bottom)
        .accessibilityContainerIdentifier(
            "plugins.hero",
            label: appLanguage.localized("插件管理")
        )
    }

    private var toolbar: some View {
        CCSectionHeader(appLanguage.localized("已安装")) {
            HStack(spacing: Space.sm) {
                if model.pluginCatalogLoading { ProgressView().controlSize(.small) }
                Button(appLanguage.localized("打开目录")) { openPluginsDirectory() }
                    .buttonStyle(.ccQuiet)
                    .disabled(model.pluginsDirectoryUnavailable || model.pluginGlobalOperation != nil)
                    .accessibilityIdentifier("plugins.open-directory")
                Button(appLanguage.localized("从 Git 添加")) { showingGitImport = true }
                    .buttonStyle(.ccSecondary)
                    .disabled(model.pluginsDirectoryUnavailable || model.pluginGlobalOperation != nil)
                    .accessibilityIdentifier("plugins.install-git")
                Button(appLanguage.localized("添加插件…")) { chooseLocalPlugin() }
                    .buttonStyle(.ccSecondary)
                    .disabled(model.pluginsDirectoryUnavailable || model.pluginGlobalOperation != nil)
                    .accessibilityIdentifier("plugins.install-local")
            }
        }
    }

    @ViewBuilder
    private var issues: some View {
        if !model.pluginIssues.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("部分插件无法载入", systemImage: "exclamationmark.triangle")
                    .font(.ccBody(.medium))
                    .foregroundStyle(Theme.danger)
                ForEach(Array(model.pluginIssues.enumerated()), id: \.offset) { _, issue in
                    Text("\(issue.location)：\(issue.message)")
                        .font(.ccMono(Typography.label))
                        .foregroundStyle(Theme.mutedForeground)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.dangerSoft)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row))
            .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Theme.danger.opacity(0.25)))
        }
    }

    @ViewBuilder
    private var pluginList: some View {
        if model.plugins.isEmpty && !model.pluginCatalogLoading {
            VStack(spacing: 9) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 23, weight: .light))
                Text("未发现插件。把插件目录放入插件目录后回到本页。")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Theme.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .overlay(RoundedRectangle(cornerRadius: Radius.panel).stroke(Theme.separator, style: .init(dash: [5])))
            .accessibilityContainerIdentifier(
                "plugins.empty",
                label: appLanguage.localized("未安装插件")
            )
        } else {
            LazyVStack(spacing: 8) {
                ForEach(model.plugins) { item in
                    PluginCard(
                        item: item,
                        busy: model.pluginBusyIDs.contains(item.id),
                        checkingUpdate: model.pluginCheckingUpdateIDs.contains(item.id),
                        actionSelected: { handleAction($0, plugin: item) },
                        uninstallSelected: { pendingUninstall = item }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var globalBusyOverlay: some View {
        if let operation = model.pluginGlobalOperation {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(appLanguage.localized(operation.message))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityContainerIdentifier(
                "plugins.global-busy",
                label: appLanguage.localized(operation.message)
            )
        }
    }

    private var callConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingCall != nil },
            set: { if !$0 { pendingCall = nil } }
        )
    }

    private var uninstallConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } }
        )
    }

    private func loadCatalogAndUpdates() async {
        await model.refreshPlugins()
        for item in model.plugins where item.hasSource {
            guard !Task.isCancelled else { return }
            await model.checkPluginUpdate(item.id)
        }
    }

    private func handleAction(_ action: PluginActionViewState, plugin: PluginCatalogItem) {
        switch action.kind {
        case .link:
            guard let url = action.externalURL else {
                model.pluginAlert = .init(message: "插件提供的链接无效", style: .error)
                return
            }
            NSWorkspace.shared.open(url)
        case .call:
            let context = CallContext(pluginID: plugin.id, action: action)
            if action.confirmation != nil {
                pendingCall = context
            } else {
                Task { await runCall(context) }
            }
        case .form:
            if action.loadsOnOpen {
                Task {
                    guard let response = await model.loadPluginAction(
                        pluginID: plugin.id,
                        actionID: action.id
                    ) else { return }
                    formContext = .init(
                        pluginID: plugin.id,
                        action: action,
                        initialValues: response.values
                    )
                }
            } else {
                formContext = .init(pluginID: plugin.id, action: action, initialValues: [:])
            }
        }
    }

    private func runCall(_ context: CallContext) async {
        _ = await model.submitPluginAction(
            pluginID: context.pluginID,
            actionID: context.action.id,
            values: [:]
        )
    }

    private func openPluginsDirectory() {
        Task {
            let directory = await model.pluginsDirectory()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }

    private func chooseLocalPlugin() {
        let panel = NSOpenPanel()
        panel.title = appLanguage.localized("选择插件目录")
        panel.message = appLanguage.localized("请选择包含 plugin.json 的目录")
        panel.prompt = appLanguage.localized("安装")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await model.installPlugin(from: directory) }
    }

    private func alertTitle(_ style: AppModel.PluginAlert.Style) -> String {
        let source = switch style {
        case .success: "完成"
        case .error: "插件操作失败"
        case .information: "提示"
        }
        return appLanguage.localized(source)
    }
}

private struct PluginCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage

    let item: PluginCatalogItem
    let busy: Bool
    let checkingUpdate: Bool
    let actionSelected: (PluginActionViewState) -> Void
    let uninstallSelected: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                title
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                status
                diagnostic
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                actions
                lifecycleActions
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .elevatedCard(radius: 13, border: item.isRunning ? Theme.success.opacity(0.32) : Theme.separator)
        .overlay {
            if busy {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Theme.surface.opacity(0.72))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .allowsHitTesting(!busy)
        .accessibilityContainerIdentifier("plugin.\(item.id)", label: item.name)
    }

    @ViewBuilder
    private var icon: some View {
        if let data = item.iconData, let image = NSImage(data: data) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row).fill(Color.clear)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        } else {
            ProviderIconView(name: item.name, icon: nil, size: 36)
        }
    }

    private var title: some View {
        HStack(spacing: 7) {
            Text(item.name)
                .font(.system(size: 14.5, weight: .semibold))
            if !item.version.isEmpty {
                Text("v\(item.version)")
                    .font(.ccMono(Typography.label))
                    .foregroundStyle(Theme.mutedForeground)
            }
            if item.isOfficialSource { badge("可信来源", color: Theme.accentText) }
            if item.updateAvailable {
                Button("↑ v\(item.latestVersion ?? "")") {
                    Task { await model.updatePlugin(item.id) }
                }
                .buttonStyle(.plain)
                .font(.ccLabel(.medium))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.11))
                .clipShape(Capsule())
                .help("更新后插件会保持停用")
                .accessibilityIdentifier("plugin.\(item.id).update")
            } else if checkingUpdate {
                ProgressView().controlSize(.mini)
            }
            if !item.protocolName.isEmpty { protocolBadge(item.protocolName) }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text("\(appLanguage.localized(item.lifecycleLabel)) · \(appLanguage.localized(item.authenticationLabel))")
                .font(.ccCaption())
                .foregroundStyle(authenticationColor)
        }
        .accessibilityContainerIdentifier(
            "plugin.\(item.id).status",
            label: "\(appLanguage.localized(item.lifecycleLabel)) · \(appLanguage.localized(item.authenticationLabel))"
        )
    }

    @ViewBuilder
    private var diagnostic: some View {
        if let failure = item.failureMessage, !failure.isEmpty {
            Text(failure)
                .font(.ccMono(Typography.label))
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        } else if let validation = item.validationMessages.first {
            Text(validation)
                .font(.ccMono(Typography.label))
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let actions = item.actions.map(PluginActionViewState.init(action:)).filter { !$0.id.isEmpty }
        if !actions.isEmpty {
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    let isAvailable = action.isAvailable(pluginRunning: item.isRunning)
                    Button(action.label) { actionSelected(action) }
                        .buttonStyle(CompactActionButtonStyle())
                        .disabled(!isAvailable)
                        .opacity(isAvailable ? 1 : 0.45)
                        .help(appLanguage.localized(
                            action.requiresRunning && !item.isRunning ? "请先启用插件" : ""
                        ))
                        .accessibilityIdentifier("plugin.\(item.id).action.\(action.id)")
                }
            }
        }
    }

    private var lifecycleActions: some View {
        HStack(spacing: 7) {
            if item.hasSource && !item.updateAvailable {
                Button {
                    Task { await model.checkPluginUpdate(item.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.ccLabel())
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .disabled(checkingUpdate)
                .help("检查更新")
            }

            Button(appLanguage.localized(item.isRunning ? "停用" : "启用")) {
                Task { await model.setPluginEnabled(item.id, enabled: !item.isRunning) }
            }
            .buttonStyle(PluginLifecycleButtonStyle(running: item.isRunning))
            .disabled(!item.isRunning && !item.canStart)
            .accessibilityIdentifier("plugin.\(item.id).toggle")

            Button(action: uninstallSelected) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mutedForeground)
            .help("卸载插件")
            .accessibilityIdentifier("plugin.\(item.id).uninstall")
        }
    }

    private var statusColor: Color {
        switch item.lifecycle {
        case .running: return Theme.success
        case .failed: return Theme.danger
        case .starting, .stopping: return .orange
        case .installed, .stopped: return Theme.separator
        }
    }

    private var authenticationColor: Color {
        guard item.isRunning else { return Theme.mutedForeground }
        switch item.authentication?.state {
        case .loggedIn: return Theme.success
        case .expired: return .orange
        case .loggedOut, .unknown, .none: return Theme.mutedForeground
        }
    }

    private func badge(_ text: String, color: Color, localizes: Bool = true) -> some View {
        Text(localizes ? appLanguage.localized(text) : text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private func protocolBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accentSoft)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(Theme.accent.opacity(0.3), lineWidth: 1)
            }
    }
}

private struct PluginLifecycleButtonStyle: ButtonStyle {
    let running: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(running ? Theme.danger : Theme.success)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(running ? Theme.dangerSoft : Theme.successSoft)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.button)
                    .stroke((running ? Theme.danger : Theme.success).opacity(0.18))
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct PluginGitImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @State private var source = ""
    let install: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("从 Git 添加")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            Divider().overlay(Theme.separator)

            VStack(alignment: .leading, spacing: 12) {
                Text("Git 仓库地址")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
                TextField("https://github.com/owner/repo", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onSubmit { submit() }
                    .accessibilityIdentifier("plugins.git-source")
                Label(
                    "导入会克隆并构建仓库代码，需要本机具备 Git 与对应构建工具链。请仅使用可信来源。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                        .buttonStyle(CompactActionButtonStyle())
                    Button("导入") { submit() }
                        .buttonStyle(CompactActionButtonStyle(primary: true))
                        .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("plugins.git-submit")
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .background(Theme.surface)
        .accessibilityContainerIdentifier(
            "plugins.git-sheet",
            label: appLanguage.localized("从 Git 添加")
        )
    }

    private func submit() {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        install(value)
    }
}
