import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: model.sidebarCollapsed ? 52 : 196)
            Divider().overlay(Color.ccBorder)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ccAppBackground)
        .foregroundStyle(Color.ccForeground)
        .tint(Color.ccBrandStrong)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.ccBorder, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("CC Buddy")
                .accessibilityIdentifier("app.shell")
                .allowsHitTesting(false)
        }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22), value: model.sidebarCollapsed)
    }

    @ViewBuilder private var content: some View {
        switch model.selected {
        case .providers: ProvidersView()
        case .plugins: PluginsView()
        case .conversations:
            ConversationsView(
                store: model.conversationStore,
                fontSize: model.config.convFontPx,
                historyDirectories: model.config.historyDirs,
                selectHistoryScope: { scope in Task { await model.setHistoryActive(scope) } }
            )
        case .monitor:
            MonitorView(
                store: model.monitorStore,
                port: model.config.port,
                gatewayRunning: model.gatewayState.isRunning,
                activeProvider: model.activeProvider
            )
        case .settings: SettingsView()
        }
    }
}
