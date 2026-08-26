import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library rail.
///
/// One navigation model, not three. The rail used to stack an application list, a second compact
/// icon strip, a source-directory group and a library tree on top of each other, so the same
/// session was reachable four ways and counted differently each time.
///
/// What remains is the library itself, always listed, with the gateway destinations above it.
/// Configured history roots are no longer a navigation group: they are storage locations and live
/// in Settings, where they can actually be added, edited and disabled.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var conversationWorkbench: ConversationWorkbenchState

    var body: some View {
        VStack(spacing: 0) {
            WindowDragRegion()
                .frame(height: Metrics.titleBarHeight)

            wordmark
                .padding(.bottom, Space.md)

            SidebarSearchRow(store: model.conversationStore)
                .padding(.horizontal, Space.xs)
                .padding(.bottom, Space.md)

            VStack(spacing: 2) {
                ForEach(SidebarView.destinations) { destination in
                    destinationRow(destination)
                }
            }

            ConversationLibraryNavigation(
                store: model.conversationStore,
                workbench: conversationWorkbench,
                browsing: model.selected == .conversations,
                selectHistoryScope: { scope in
                    model.selected = .conversations
                    Task { await model.setHistoryActive(scope) }
                }
            )
            .padding(.top, Space.md)

            SidebarFooter(workbench: conversationWorkbench)
        }
        .padding(.horizontal, Rail.edge)
        .padding(.bottom, Space.sm)
        .background(Theme.sidebar)
    }

    /// Sessions are absent for the opposite reason to Settings: the library below *is* the session
    /// destination, always on screen, so a row that only re-selected it was a second door into the
    /// room you were already standing in. Settings is a scene reached from the footer gear and ⌘,.
    static let destinations: [AppModel.Destination] = [
        .providers, .monitor, .plugins,
    ]

    private var wordmark: some View {
        HStack(spacing: Space.sm) {
            AppLogo().frame(width: 20, height: 20)
            Text(verbatim: "CC Buddy")
                .font(.ccHeading())
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Rail.titleInset - Rail.edge + Space.xs)
    }

    private func destinationRow(_ destination: AppModel.Destination) -> some View {
        let selected = model.selected == destination
        return SidebarRow(
            lead: .symbol(destination.symbol, size: 15),
            title: appLanguage.localized(destination.title),
            selected: selected,
            identifier: "sidebar.\(destination.rawValue)"
        ) {
            model.selected = destination
        }
    }
}

// MARK: - Rows

/// Every rail row carries a leading element. The slot is a fixed width so titles all start at the
/// same x, and the element is centered inside it so it lands on the traffic-light axis.
enum SidebarRowLead {
    case symbol(String, size: CGFloat)
    case brand(HistorySource)
}

struct SidebarRow: View {
    let lead: SidebarRowLead
    let title: String
    var count: Int?
    var selected: Bool
    var nested: Bool = false
    var destructive: Bool = false
    let identifier: String
    let action: () -> Void

    @State private var hovering = false

    init(
        lead: SidebarRowLead,
        title: String,
        count: Int? = nil,
        selected: Bool,
        nested: Bool = false,
        destructive: Bool = false,
        identifier: String,
        action: @escaping () -> Void
    ) {
        self.lead = lead
        self.title = title
        self.count = count
        self.selected = selected
        self.nested = nested
        self.destructive = destructive
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                leadView.frame(width: Rail.leadBox, height: Rail.leadBox)
                Text(title)
                    .font(.system(
                        size: nested ? Typography.caption : Typography.body,
                        weight: selected ? .medium : .regular
                    ))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.xs)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.ccLabel())
                        .foregroundStyle(Theme.mutedForeground)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(titleColor)
            .padding(.leading, Rail.leadInset)
            .padding(.trailing, Space.sm)
            .frame(maxWidth: .infinity, minHeight: nested ? Metrics.subRowHeight : Metrics.rowHeight)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
            .padding(.leading, nested ? Rail.subIndent : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var leadView: some View {
        switch lead {
        case .symbol(let name, let size):
            Image(systemName: name)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
        case .brand(let source):
            AgentBrandMark(source: source, size: nested ? 15 : 18)
        }
    }

    private var titleColor: Color {
        if destructive && selected { return Theme.danger }
        return selected ? Theme.foreground : Theme.mutedForeground
    }

    private var rowBackground: Color {
        if selected { return destructive ? Theme.dangerSoft : Theme.sidebarAccent }
        return hovering ? Theme.hover : .clear
    }
}

/// Collapsible group head. Body step at regular weight in the muted ink: same size as the rows it
/// governs, distinguished only by color and by having no leading element. Emboldening it would make
/// the head outweigh its own rows.
private struct SidebarGroupHead: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs + 2) {
                Text(title).font(.ccBody())
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.mutedForeground)
            .padding(.leading, Rail.groupHeadInset)
            .padding(.trailing, Space.sm)
            .frame(height: Metrics.rowHeight - 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

/// The rail owns the single full-text entry point.
///
/// It is a row that opens the ⌘K panel, not an inline field: an inline field here searched the
/// whole library from a control that looked like it filtered the column next to it, and once the
/// panel existed the two were two ways to do the same thing. When a query is active the row shows
/// it, which is what explains why the stream is filtered.
///
/// The row must not overflow: the label is elastic and the badge is pinned, because a bare text
/// child locks its own minimum width and would push the shortcut past the rail's edge.
private struct SidebarSearchRow: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage

    @State private var hovering = false

    private var query: String {
        store.listQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            Button {
                NotificationCenter.default.post(name: .ccbudFocusSearch, object: nil)
            } label: {
                HStack(spacing: Space.xs + 2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: Typography.caption, weight: .medium))
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(width: 14)
                        .fixedSize()
                    Text(query.isEmpty ? appLanguage.localized("搜索会话") : query)
                        .font(.ccCaption())
                        .foregroundStyle(query.isEmpty ? Theme.mutedForeground : Theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if query.isEmpty {
                        CCKeyBadge(keys: "⌘K")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.list.search")

            if !query.isEmpty {
                Button { store.updateListQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Typography.caption))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(appLanguage.localized("清空搜索"))
                .accessibilityIdentifier("conversation.list.search.clear")
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(height: Metrics.rowHeight)
        .background(hovering ? Theme.hover : Theme.fill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .onHover { hovering = $0 }
        .help(appLanguage.localized("搜索全部会话"))
    }
}

/// Menu commands live on the scene, so they reach the app through notifications rather than by
/// threading a binding down to whichever column happens to own the control.
extension Notification.Name {
    static let ccbudFocusSearch = Notification.Name("dev.ccbud.focus-search")
    static let ccbudRefreshCatalog = Notification.Name("dev.ccbud.refresh-catalog")
    static let ccbudOpenSettings = Notification.Name("dev.ccbud.open-settings")
}

// MARK: - Library

private struct ConversationLibraryNavigation: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workbench: ConversationWorkbenchState
    @Environment(\.appLanguage) private var appLanguage

    /// The library is always listed, but a scope only reads as *current* while it is the thing on
    /// screen; highlighting a row from the gateway pages would claim a selection that is not there.
    let browsing: Bool
    let selectHistoryScope: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                SidebarRow(
                    lead: .symbol("tray.full", size: 15),
                    title: appLanguage.localized("全部会话"),
                    count: totalSessionCount,
                    selected: browsing && store.historyActive == "all" && workbench.selection == .all,
                    identifier: "conversation.library.all"
                ) {
                    workbench.showAll()
                    selectHistoryScope("all")
                }

                SidebarRow(
                    lead: .symbol("star", size: 14),
                    title: appLanguage.localized("收藏"),
                    count: starredCount,
                    selected: browsing && store.historyActive == "all" && workbench.selection == .starred,
                    identifier: "conversation.library.starred"
                ) {
                    workbench.showStarred()
                    selectHistoryScope("all")
                }

                if store.scopeSnapshot.importedCount > 0 || store.historyActive == "__imported__" {
                    SidebarRow(
                        lead: .symbol("square.and.arrow.down", size: 14),
                        title: appLanguage.localized("已导入"),
                        count: store.scopeSnapshot.importedCount,
                        selected: browsing && store.historyActive == "__imported__",
                        identifier: "conversation.library.imported"
                    ) {
                        workbench.showAll()
                        selectHistoryScope("__imported__")
                    }
                }

                if store.scopeSnapshot.trashCount > 0 || store.historyActive == "__trash__" {
                    SidebarRow(
                        lead: .symbol("trash", size: 14),
                        title: appLanguage.localized("回收站"),
                        count: store.scopeSnapshot.trashCount,
                        selected: browsing && store.historyActive == "__trash__",
                        destructive: true,
                        identifier: "conversation.library.trash"
                    ) {
                        workbench.showAll()
                        selectHistoryScope("__trash__")
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    SidebarGroupHead(
                        title: appLanguage.localized("工具"),
                        expanded: workbench.agentsExpanded
                    ) {
                        workbench.agentsExpanded.toggle()
                    }
                    if workbench.agentsExpanded {
                        ForEach(agentCounts, id: \.source.rawValue) { item in
                            SidebarRow(
                                lead: .brand(item.source),
                                title: ConversationPresentation.sourceName(rawValue: item.source.rawValue),
                                count: item.count,
                                selected: browsing && store.historyActive == "all"
                                    && workbench.selection == .agent(item.source),
                                nested: true,
                                identifier: "conversation.library.agent.\(item.source.rawValue)"
                            ) {
                                workbench.select(agent: item.source)
                                selectHistoryScope("all")
                            }
                        }
                    }

                    SidebarGroupHead(
                        title: appLanguage.localized("项目"),
                        expanded: workbench.projectsExpanded
                    ) {
                        workbench.projectsExpanded.toggle()
                    }
                    if workbench.projectsExpanded {
                        ForEach(store.projects) { project in
                            SidebarRow(
                                lead: .symbol("folder", size: 14),
                                title: ConversationPresentation.projectName(
                                    project.name,
                                    language: appLanguage
                                ),
                                count: project.sessions.count,
                                selected: browsing && store.historyActive == "all"
                                    && workbench.selection == .project(project.cwd),
                                nested: true,
                                identifier: "conversation.library.project.\(SidebarIdentifier.stable(project.cwd))"
                            ) {
                                workbench.select(project: project.cwd)
                                selectHistoryScope("all")
                            }
                        }
                    }
                }
                .padding(.top, Space.xs)
                .padding(.bottom, Space.sm)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Prefer the index's authoritative tally. Counting the loaded stream instead would report the
    /// truncation cap rather than the size of the library.
    private var totalSessionCount: Int {
        let snapshot = store.scopeSnapshot
        if snapshot.isAuthoritative {
            let live = snapshot.sessionCounts
                .filter { $0.key != "__imported__" }
                .values
                .reduce(0, +)
            let imported = snapshot.importedCount
            if live + imported > 0 { return live + imported }
        }
        return store.projects.reduce(0) { $0 + $1.sessions.count }
    }

    private var starredCount: Int {
        store.projects.reduce(0) { $0 + $1.sessions.lazy.filter(\.starred).count }
    }

    private var agentCounts: [(source: HistorySource, count: Int)] {
        let preferredOrder: [HistorySource] = [
            .claude, .codex, .qoder, .grok, .copilot, .antigravity,
        ]
        let sessions = store.projects.flatMap(\.sessions)
        return preferredOrder.compactMap { source in
            let count = sessions.lazy.filter { $0.source == source }.count
            return count > 0 ? (source, count) : nil
        }
    }
}

enum SidebarIdentifier {
    static func stable(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        })
    }
}

// MARK: - Footer

/// Always present, quiet by construction: a status line that stays silent unless it has something
/// to report, and a right-aligned strip of secondary actions that never competes with the selected
/// navigation row.
private struct SidebarFooter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var workbench: ConversationWorkbenchState

    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                CCStatusLabel(
                    text: model.gatewayState.isRunning
                        ? appLanguage.localized("网关运行中")
                        : appLanguage.localized("网关未启动"),
                    tint: model.gatewayState.isRunning ? Theme.success : Theme.mutedForeground
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Rail.leadInset)
            .frame(height: 18)

            HStack(spacing: 2) {
                // Resident, like the library they act on: importing a transcript or refreshing the
                // catalog should not require first navigating back to a particular page.
                footerButton("square.and.arrow.down", "导入 JSONL 或 ZIP", "conversation.import") {
                    showingImporter = true
                }
                .disabled(model.conversationStore.isMutating)

                footerButton("arrow.clockwise", "更新会话索引", "conversation.library.refresh") {
                    model.conversationStore.retryIndexing()
                }
                .disabled(model.conversationStore.indexingState.isScanning)

                Spacer(minLength: 0)

                footerButton(
                    model.themeMode == .dark ? "sun.max" : "moon",
                    model.themeMode == .dark ? "切换到浅色模式" : "切换到深色模式",
                    "sidebar.theme"
                ) {
                    model.toggleTheme()
                }

                footerButton("gearshape", "设置", "sidebar.settings") {
                    model.selected = .settings
                }
            }
        }
        .padding(.top, Space.sm)
        .hairline(.top)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "jsonl"), .zip].compactMap { $0 },
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let files):
                Task { await model.conversationStore.importFiles(files) }
            case .failure(let error):
                model.conversationStore.reportActionError("导入失败：\(error.localizedDescription)")
            }
        }
    }

    private func footerButton(
        _ symbol: String,
        _ label: String,
        _ identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if identifier == "conversation.library.refresh",
               model.conversationStore.indexingState.isScanning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(CCIconButtonStyle(size: 26, symbolSize: Typography.caption))
        .help(appLanguage.localized(label))
        .accessibilityLabel(appLanguage.localized(label))
        .accessibilityIdentifier(identifier)
    }
}

struct AppLogo: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(Theme.accentSoft)
                Image(systemName: "command").foregroundStyle(Theme.accentText)
            }
        }
    }
}
