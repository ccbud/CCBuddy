import SwiftUI
import UniformTypeIdentifiers

struct ProvidersView: View {
    private struct PendingAction: Identifiable {
        enum Kind { case select, delete }
        let kind: Kind
        let provider: Provider
        var id: String { "\(kind)-\(provider.id)" }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @State private var editingProvider: Provider?
    @State private var showingEditor = false
    @State private var pendingAction: PendingAction?
    @State private var draggedProviderID: String?
    @State private var probeStates: [String: ProviderRowProbeState] = [:]
    @State private var probeMessage: String?
    @State private var probeMessageSucceeded = false

    var body: some View {
        VStack(spacing: 0) {
            ProviderHeroView()

            ScrollView {
                VStack(spacing: Space.md) {
                    if let pluginAlert = model.pluginAlert { pluginBanner(pluginAlert) }
                    if let probeMessage { probeBanner(probeMessage) }
                    toolbar
                    providerList
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .blur(radius: showingEditor ? 10 : 0)
        .sheet(isPresented: $showingEditor) {
            ProviderEditorView(provider: editingProvider) { provider in
                Task { await model.upsertProvider(provider) }
            }
        }
        .alert(item: $pendingAction) { action in
            switch action.kind {
            case .select:
                return Alert(
                    title: Text(appLanguage.localized("切换到“\(action.provider.name)”？")),
                    message: Text("网关正在运行；切换会让之后的新 CLI 会话立即改用这个服务。"),
                    primaryButton: .default(Text("切换")) {
                        Task { await model.setActiveProvider(action.provider.id) }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .delete:
                return Alert(
                    title: Text("删除服务？"),
                    message: Text(appLanguage.localized("将删除“\(action.provider.name)”及其模型映射。")),
                    primaryButton: .destructive(Text("删除")) {
                        Task { await model.deleteProvider(action.provider.id) }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .accessibilityIdentifier("view.providers")
    }

    private var toolbar: some View {
        CCSectionHeader(appLanguage.localized("服务商")) {
            HStack(spacing: Space.sm) {
                Text(appLanguage.localized("点选切换 · 拖动排序"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                Button(action: openNewProvider) {
                    Label(appLanguage.localized("添加"), systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.ccSecondary)
                .accessibilityIdentifier("providers.add")
            }
        }
    }

    @ViewBuilder private var providerList: some View {
        if model.config.providers.isEmpty {
            CCEmptyState(
                symbol: "tray",
                title: appLanguage.localized("尚未添加服务商"),
                message: appLanguage.localized("添加一个 Anthropic 或 OpenAI 兼容的服务，网关就能开始转发。"),
                compact: true
            ) {
                Button(appLanguage.localized("添加第一个服务"), action: openNewProvider)
                    .buttonStyle(.ccPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xxl)
        } else {
            LazyVStack(spacing: Space.xs + 2) {
                ForEach(model.config.providers) { provider in
                    ProviderRow(
                        provider: provider,
                        active: provider.id == model.config.activeProviderId,
                        pluginRunning: pluginRunning(for: provider),
                        probeState: probeStates[provider.id] ?? .idle,
                        dragProvider: {
                            draggedProviderID = provider.id
                            return NSItemProvider(object: provider.id as NSString)
                        },
                        select: { select(provider) },
                        test: { test(provider) },
                        edit: {
                            editingProvider = provider
                            showingEditor = true
                        },
                        delete: { pendingAction = .init(kind: .delete, provider: provider) }
                    )
                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                        guard let draggedProviderID, draggedProviderID != provider.id else {
                            self.draggedProviderID = nil
                            return false
                        }
                        Task { await model.reorderProvider(draggedProviderID, to: provider.id) }
                        self.draggedProviderID = nil
                        return true
                    }
                }
            }
        }
    }

    private func probeBanner(_ message: String) -> some View {
        Label(
            appLanguage.localized(message),
            systemImage: probeMessageSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
            .font(.ccCaption(.medium))
            .foregroundStyle(probeMessageSucceeded ? Theme.success : Theme.danger)
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(probeMessageSucceeded ? Theme.successSoft : Theme.dangerSoft)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .accessibilityIdentifier("providers.probe.result")
    }

    private func pluginBanner(_ alert: AppModel.PluginAlert) -> some View {
        HStack(spacing: 8) {
            Image(systemName: alert.style == .error ? "exclamationmark.circle.fill" : "info.circle.fill")
            Text(alert.localizesMessage
                ? appLanguage.localized(alert.message)
                : alert.message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.pluginAlert = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .font(.ccCaption(.medium))
        .foregroundStyle(alert.style == .error ? Theme.danger : Theme.accentText)
        .padding(.horizontal, Space.md)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(alert.style == .error ? Theme.dangerSoft : Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.plugin-alert")
    }

    private func openNewProvider() {
        editingProvider = nil
        showingEditor = true
    }

    private func select(_ provider: Provider) {
        guard provider.id != model.config.activeProviderId else { return }
        if provider.backend == .plugin, pluginRunning(for: provider) != true {
            model.pluginAlert = .init(
                message: "请先在插件页启用“\(provider.name)”对应的插件",
                style: .error
            )
            return
        }
        if model.gatewayState.isRunning {
            pendingAction = .init(kind: .select, provider: provider)
        } else {
            Task { await model.setActiveProvider(provider.id) }
        }
    }

    private func test(_ provider: Provider) {
        guard probeStates[provider.id] != .testing else { return }
        if provider.backend == .plugin, pluginRunning(for: provider) != true {
            model.pluginAlert = .init(
                message: "插件未运行，无法测试“\(provider.name)”",
                style: .error
            )
            return
        }
        probeStates[provider.id] = .testing
        probeMessage = nil
        Task {
            let result = await ProviderProbeService().test(
                provider,
                insecureSkipVerify: model.config.insecureSkipVerify
            )
            if result.succeeded, let migrated = result.migratedBaseURL {
                var updated = provider
                updated.baseUrl = migrated
                await model.upsertProvider(updated)
            }
            probeStates[provider.id] = result.succeeded ? .succeeded : .failed
            probeMessageSucceeded = result.succeeded
            if result.succeeded {
                probeMessage = "✓ \(provider.name) 连接成功 · \(result.model ?? provider.defaultModel)"
            } else {
                switch result.reason {
                case .baseURLEmpty: probeMessage = "✗ \(provider.name)：请填写 API 地址"
                case .baseURLInvalid: probeMessage = "✗ \(provider.name)：API 地址无效"
                case .timeout: probeMessage = "✗ \(provider.name)：连接超时"
                case nil: probeMessage = "✗ \(provider.name)：\(result.message ?? "连接失败")"
                }
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if probeStates[provider.id] != .testing { probeStates[provider.id] = .idle }
        }
    }

    private func pluginRunning(for provider: Provider) -> Bool? {
        guard provider.backend == .plugin, let pluginID = provider.pluginId else { return nil }
        return model.plugins.first(where: { $0.id == pluginID })?.isRunning ?? false
    }
}
