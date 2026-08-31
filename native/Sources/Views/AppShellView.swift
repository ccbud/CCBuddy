import SwiftUI

/// The window shell: the library rail plus one destination, with a rule between them you can move.
///
/// The rail is structural rather than an inspector, but "structural" was taken too far: it was
/// pinned at one width and could not be put away at all, which is worse than either on a laptop
/// screen. It now remembers its width and whether it is showing, and every destination owns its own
/// title-bar inset so each column carries the drag strip in its own material.
struct AppShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var conversationWorkbench = ConversationWorkbenchState()
    @StateObject private var columns = ColumnLayout()
    @State private var searchPaletteVisible = false

    var body: some View {
        HStack(spacing: 0) {
            if columns.railVisible {
                SidebarView(conversationWorkbench: conversationWorkbench, columns: columns)
                    .frame(width: columns.railWidth)
                ColumnDivider(
                    column: ColumnLayout.rail,
                    width: $columns.railWidth,
                    onCommit: { columns.resize(ColumnLayout.rail, to: $0) },
                    identifier: "layout.divider.rail"
                )
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A destination used to be replaced between one frame and the next, which reads as
                // a jolt rather than a change of place. A short crossfade is enough to connect the
                // two; anything longer would put the interface between the user and their click.
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.16),
                    value: model.selected
                )
                // With the rail away the traffic lights sit over the destination, so the control
                // that brings it back waits just past them — the same edge it left from.
                .overlay(alignment: .topLeading) {
                    if !columns.railVisible {
                        ColumnToggle(
                            symbol: "sidebar.leading",
                            help: appLanguage.localized("显示侧栏"),
                            identifier: "layout.toggle.rail"
                        ) {
                            columns.toggleRail()
                        }
                        .padding(.leading, Metrics.trafficLightClearance)
                        .padding(.top, 5)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        // The marker rides the background layer because that is the one that genuinely spans the
        // window: hung off the outer chain it was placed against the safe area instead, reporting
        // the shell as starting a title bar's height below the window's top edge.
        .background(
            Theme.background
                .ignoresSafeArea()
                .accessibilityContainerIdentifier("app.shell", label: "CC Buddy")
        )
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
    }

    @ViewBuilder private var content: some View {
        switch model.selected {
        case .conversations:
            ConversationsView(
                store: model.conversationStore,
                workbench: conversationWorkbench,
                columns: columns,
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
        case .timeline:
            TimelineView(store: model.conversationStore)
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
