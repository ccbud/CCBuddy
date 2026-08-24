import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var conversationWorkbench = ConversationWorkbenchState()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(conversationWorkbench: conversationWorkbench)
                .frame(width: sidebarWidth)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Conversation columns own their title-bar drag insets. Other destinations keep
                // their controls below native chrome while their semantic background fills it.
                .padding(.top, model.selected == .conversations ? 0 : 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        // Own the complete opaque window surface at the shell level. Child materials still paint
        // their ordinary bodies, while this three-segment backing guarantees that AppKit's native
        // title-bar safe area has the same Wake colors instead of exposing the desktop/window
        // fallback during first layout or destination transitions.
        .background(shellBackground.ignoresSafeArea())
        .foregroundStyle(Color.ccForeground)
        .tint(Color.ccBrandStrong)
        .overlay(alignment: .top) {
            if model.selected != .conversations {
                WindowDragRegion()
                    .frame(height: 30)
                    .padding(.leading, sidebarWidth)
            }
        }
        .animation(
            reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22),
            value: model.sidebarCollapsed
        )
    }

    private var sidebarWidth: CGFloat {
        // Wake's library rail is structural, not an optional inspector. Keep its reference width
        // while browsing sessions; the compact app rail remains available on other destinations.
        model.selected == .conversations ? 224 : (model.sidebarCollapsed ? 52 : 224)
    }

    @ViewBuilder private var shellBackground: some View {
        HStack(spacing: 0) {
            Color.ccSidebar
                .frame(width: sidebarWidth)
            if model.selected == .conversations {
                Color.ccConversationList
                    .frame(width: 336)
                Color.ccConversationBackground
            } else {
                Color.ccAppBackground
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.selected {
        case .providers: ProvidersView()
        case .plugins: PluginsView()
        case .conversations:
            ConversationsView(
                store: model.conversationStore,
                workbench: conversationWorkbench,
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
