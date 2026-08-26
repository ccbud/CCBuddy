import SwiftUI

/// The window shell: a fixed library rail plus one destination.
///
/// The rail is structural, not an inspector, so it does not collapse — a rail that can vanish makes
/// the traffic lights float over whatever happens to be behind them and forces every destination to
/// reason about two layouts. Destinations own their own title-bar inset so each column can carry the
/// drag strip in its own material instead of the shell painting a band across all of them.
struct AppShellView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var conversationWorkbench = ConversationWorkbenchState()
    @State private var searchPaletteVisible = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(conversationWorkbench: conversationWorkbench)
                .frame(width: Metrics.sidebarWidth)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.foreground)
        .tint(Theme.accent)
        // The library rail is resident, so the catalog it lists has to be live regardless of which
        // destination is on screen; activating on the sessions page left the rail showing empty
        // agent and project groups everywhere else.
        .onAppear { model.conversationStore.activate() }
        .onDisappear { model.conversationStore.deactivate() }
        .overlay {
            if searchPaletteVisible {
                ConversationSearchPalette(store: model.conversationStore) {
                    withAnimation(.easeOut(duration: 0.12)) { searchPaletteVisible = false }
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccbudFocusSearch)) { _ in
            // Full-text search is a library-level command, so it carries you back to the library
            // rather than searching invisibly from the gateway pages, and it widens the scope to
            // the whole library — the panel's footer promises exactly that, and searching only the
            // agent or location you happened to be browsing would make the promise false.
            // Pressing the shortcut again dismisses the panel, the way every command palette does.
            guard !searchPaletteVisible else {
                withAnimation(.easeOut(duration: 0.12)) { searchPaletteVisible = false }
                return
            }
            model.selected = .conversations
            conversationWorkbench.showAll()
            if model.conversationStore.historyActive != "all" {
                Task { await model.setHistoryActive("all") }
            }
            withAnimation(.easeOut(duration: 0.12)) { searchPaletteVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccbudRefreshCatalog)) { _ in
            model.conversationStore.retryIndexing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccbudOpenSettings)) { _ in
            model.selected = .settings
        }
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("CC Buddy")
                .accessibilityIdentifier("app.shell")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.selected {
        case .conversations:
            ConversationsView(
                store: model.conversationStore,
                workbench: conversationWorkbench,
                fontSize: model.config.convFontPx,
                selectHistoryScope: { scope in Task { await model.setHistoryActive(scope) } }
            )
        case .providers:
            ProvidersView()
        case .monitor:
            MonitorView(
                store: model.monitorStore,
                port: model.config.port,
                gatewayRunning: model.gatewayState.isRunning,
                activeProvider: model.activeProvider
            )
        case .plugins:
            PluginsView()
        case .settings:
            SettingsView()
        }
    }
}

/// A destination header that owns the window's drag strip.
///
/// Every non-library destination starts with this so the traffic-light band belongs to the column's
/// own material and the page title sits on the same baseline as the session stream's context title.
struct DestinationHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ccTitle())
                    .tracking(-0.35)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.md)
            trailing
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Metrics.titleBarHeight - Space.sm)
        .padding(.bottom, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowDragRegion())
    }
}

extension DestinationHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
