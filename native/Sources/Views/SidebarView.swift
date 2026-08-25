import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var conversationWorkbench: ConversationWorkbenchState

    var body: some View {
        VStack(spacing: 0) {
            WindowDragRegion()
                .frame(height: 38)
                .background(Color.ccSidebar)

            brand
                .padding(.horizontal, compact ? 5 : 8)
                .padding(.bottom, 18)

            if model.selected == .conversations {
                ConversationLibraryNavigation(
                    store: model.conversationStore,
                    workbench: conversationWorkbench,
                    selectHistoryScope: { scope in
                        Task { await model.setHistoryActive(scope) }
                    }
                )
            } else {
                VStack(spacing: 2) {
                    ForEach(AppModel.Destination.allCases) { destination in
                        navButton(destination)
                    }
                }
                Spacer(minLength: 12)
            }

            footer
        }
        .padding(.horizontal, compact ? 5 : 10)
        .padding(.bottom, 14)
        .background(Color.ccSidebar.ignoresSafeArea())
    }

    private var compact: Bool {
        model.sidebarCollapsed && model.selected != .conversations
    }

    private var brand: some View {
        HStack(spacing: 9) {
            AppLogo().frame(width: 26, height: 26)
            if !compact {
                Text("CC Buddy")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func navButton(_ destination: AppModel.Destination) -> some View {
        let selected = model.selected == destination
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                model.selected = destination
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: destination.symbol).frame(width: 16, height: 16)
                if !compact {
                    Text(LocalizedStringKey(destination.title))
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.ccForeground : Color.ccMuted)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(selected ? Color.ccSidebarSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(appLanguage.localized(destination.title))
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.selected == .conversations {
                // Wake's library rail stays visually uninterrupted from the title bar through
                // Projects. CC Buddy's broader product navigation remains available at the foot
                // of the rail instead of inserting a second, translucent toolbar above Search.
                HStack(spacing: 4) {
                    ForEach(AppModel.Destination.allCases) { destination in
                        conversationDestinationButton(destination)
                    }
                }
            }

            HStack(spacing: 8) {
                if !compact {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.gatewayState.isRunning ? Color.ccGreen : Color.ccMuted)
                            .frame(width: 5, height: 5)
                        Text(LocalizedStringKey(model.gatewayState.isRunning ? "已接入" : "未接入"))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.gatewayState.isRunning ? Color.ccGreen : Color.ccMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        model.gatewayState.isRunning
                            ? Color.ccGreenSoft
                            : Color.ccForeground.opacity(0.05)
                    )
                    .clipShape(Capsule())
                    Spacer(minLength: 0)
                }

                if model.selected != .conversations {
                    footerButton(
                        symbol: model.sidebarCollapsed ? "chevron.right" : "chevron.left",
                        label: model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏",
                        identifier: "sidebar.collapse"
                    ) { model.toggleSidebar() }
                }
                footerButton(
                    symbol: model.themeMode == .dark ? "sun.max" : "moon",
                    label: model.themeMode == .dark ? "切换到浅色模式" : "切换到深色模式",
                    identifier: "sidebar.theme"
                ) { model.toggleTheme() }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
    }

    private func conversationDestinationButton(_ destination: AppModel.Destination) -> some View {
        let selected = model.selected == destination
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                model.selected = destination
            }
        } label: {
            Image(systemName: destination.symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.ccForeground : Color.ccMuted)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Color.ccSidebarSelection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(appLanguage.localized(destination.title))
        .accessibilityLabel(appLanguage.localized(destination.title))
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    private func footerButton(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ccMuted)
        .background(Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))
        .accessibilityLabel(appLanguage.localized(label))
        .accessibilityIdentifier(identifier)
    }
}

private struct ConversationLibraryNavigation: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workbench: ConversationWorkbenchState
    @Environment(\.appLanguage) private var appLanguage

    let selectHistoryScope: (String) -> Void

    @State private var showingImporter = false
    @State private var showingSessionLocations = false
    @State private var hoveringSessionLocations = false
    @State private var hoveringSessionRefresh = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchToolbar

            VStack(spacing: 2) {
                libraryRow(
                    icon: .layers,
                    title: appLanguage.localized("全部会话"),
                    count: totalSessionCount,
                    selected: store.historyActive == "all"
                        && workbench.selection == .all,
                    identifier: "conversation.library.all"
                ) {
                    workbench.showAll()
                    selectHistoryScope("all")
                }

                libraryRow(
                    icon: .star,
                    title: appLanguage.localized("已收藏"),
                    count: starredSessionCount,
                    selected: store.historyActive == "all"
                        && workbench.selection == .starred,
                    identifier: "conversation.library.starred"
                ) {
                    workbench.showStarred()
                    selectHistoryScope("all")
                }

                if store.scopeSnapshot.importedCount > 0 || store.historyActive == "__imported__" {
                    libraryRow(
                        icon: .inbox,
                        title: appLanguage.localized("已导入"),
                        count: store.scopeSnapshot.importedCount,
                        selected: store.historyActive == "__imported__",
                        identifier: "conversation.library.imported"
                    ) {
                        workbench.showAll()
                        selectHistoryScope("__imported__")
                    }
                }

                if store.scopeSnapshot.trashCount > 0 || store.historyActive == "__trash__" {
                    libraryRow(
                        icon: .trash,
                        title: appLanguage.localized("回收站"),
                        count: store.scopeSnapshot.trashCount,
                        selected: store.historyActive == "__trash__",
                        identifier: "conversation.library.trash",
                        destructive: true
                    ) {
                        workbench.showAll()
                        selectHistoryScope("__trash__")
                    }
                }
            }
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    groupHeading(
                        appLanguage.localized("代理"),
                        expanded: workbench.agentsExpanded
                    ) {
                        workbench.agentsExpanded.toggle()
                    }
                    if workbench.agentsExpanded {
                        ForEach(agentCounts, id: \.source.rawValue) { item in
                            libraryRow(
                                source: item.source,
                                title: ConversationPresentation.sourceName(rawValue: item.source.rawValue),
                                count: item.count,
                                selected: store.historyActive == "all"
                                    && workbench.selection == .agent(item.source),
                                identifier: "conversation.library.agent.\(item.source.rawValue)",
                                sublevel: true
                            ) {
                                workbench.select(agent: item.source)
                                selectHistoryScope("all")
                            }
                        }
                    }

                    groupHeading(
                        appLanguage.localized("项目"),
                        expanded: workbench.projectsExpanded
                    ) {
                        workbench.projectsExpanded.toggle()
                    }
                    if workbench.projectsExpanded {
                        ForEach(store.projects) { project in
                            libraryRow(
                                icon: .folder,
                                title: project.name,
                                count: project.sessions.count,
                                selected: store.historyActive == "all"
                                    && workbench.selection == .project(project.cwd),
                                identifier: "conversation.library.project.\(stableIdentifier(project.cwd))",
                                sublevel: true
                            ) {
                                workbench.select(project: project.cwd)
                                selectHistoryScope("all")
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            sessionLocationsFooter
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "jsonl"), .zip].compactMap { $0 },
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let files):
                Task { await store.importFiles(files) }
            case .failure(let error):
                store.reportActionError("导入失败：\(error.localizedDescription)")
            }
        }
        .onChange(of: workbench.searchFocusRevision) { _ in
            searchFocused = true
        }
        .sheet(isPresented: $showingSessionLocations) {
            ConversationSessionLocationsView(store: store)
        }
    }

    private var searchToolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                ConversationWorkbenchIcon(.search, size: 12)
                    .foregroundStyle(Color.ccCaption)
                TextField(
                    "搜索项目 / 会话 / 内容…",
                    text: Binding(
                        get: { store.listQuery },
                        set: { store.updateListQuery($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityIdentifier("conversation.list.search")
                if !store.listQuery.isEmpty {
                    Button { store.updateListQuery("") } label: {
                        ConversationWorkbenchIcon(.circleX, size: 12)
                            .foregroundStyle(Color.ccCaption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(appLanguage.localized("清空搜索"))
                    .accessibilityIdentifier("conversation.list.search.clear")
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Color.ccConversationSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let progress = store.importProgress {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(max(progress.total, 1))
                )
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .background(Color.ccConversationSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(appLanguage.localized(
                    "正在导入 \(progress.completed)/\(progress.total)"
                ))
                .accessibilityLabel(appLanguage.localized("正在导入会话"))
                .accessibilityValue("\(progress.completed)/\(progress.total)")
                .accessibilityIdentifier("conversation.import.progress")
            } else {
                libraryToolButton(
                    icon: .plus,
                    label: "导入 JSONL 或 ZIP",
                    identifier: "conversation.import"
                ) {
                    showingImporter = true
                }
                .disabled(store.isMutating)
            }

        }
        .padding(.bottom, 12)
    }

    private var sessionLocationsFooter: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button {
                showingSessionLocations = true
            } label: {
                ConversationWorkbenchIcon(.hardDrive, size: 14)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(
                        hoveringSessionLocations && !sessionLocationsBusy
                            ? Color.ccForeground
                            : Color.ccMuted
                    )
                    .background(
                        hoveringSessionLocations && !sessionLocationsBusy
                            ? Color.ccConversationSecondary
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(ConversationPressableButtonStyle())
            .onHover { hoveringSessionLocations = $0 }
            .help(appLanguage.localized("会话位置"))
            .accessibilityLabel(appLanguage.localized("会话位置"))
            .accessibilityIdentifier("conversation.locations.button")
            .disabled(sessionLocationsBusy)

            Button {
                store.retryIndexing()
            } label: {
                Group {
                    if store.indexingState.isScanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        ConversationWorkbenchIcon(.refreshCW, size: 13)
                    }
                }
                .frame(width: 30, height: 30)
                .foregroundStyle(
                    hoveringSessionRefresh && !sessionLocationsBusy
                        ? Color.ccForeground
                        : Color.ccMuted
                )
                .background(
                    hoveringSessionRefresh && !sessionLocationsBusy
                        ? Color.ccConversationSecondary
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(ConversationPressableButtonStyle())
            .onHover { hoveringSessionRefresh = $0 }
            .help(appLanguage.localized("更新会话索引"))
            .accessibilityLabel(appLanguage.localized("更新会话索引"))
            .accessibilityIdentifier("conversation.library.refresh")
            .disabled(sessionLocationsBusy)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.ccBorder).frame(height: 1)
        }
    }

    private var sessionLocationsBusy: Bool {
        store.indexingState.isScanning || store.isUpdatingSessionLocations
    }

    private func libraryToolButton(
        icon: ConversationWorkbenchIconName,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if identifier == "conversation.library.refresh", store.indexingState.isScanning {
                    ProgressView().controlSize(.mini)
                } else {
                    ConversationWorkbenchIcon(icon, size: 14)
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ccMuted)
        .background(Color.ccConversationSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(appLanguage.localized(label))
        .accessibilityLabel(appLanguage.localized(label))
        .accessibilityIdentifier(identifier)
    }

    private func groupHeading(
        _ title: String,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: .regular))
                Spacer(minLength: 0)
                ConversationWorkbenchIcon(expanded ? .chevronDown : .chevronRight, size: 11)
            }
            .foregroundStyle(Color.ccMuted)
            .padding(.horizontal, 9)
            .frame(height: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func libraryRow(
        icon: ConversationWorkbenchIconName? = nil,
        source: HistorySource? = nil,
        title: String,
        count: Int?,
        selected: Bool,
        identifier: String,
        sublevel: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let source {
                    ConversationSourceBrandIcon(source: source, size: sublevel ? 14 : 16)
                        .frame(width: 18)
                } else if let icon {
                    ConversationWorkbenchIcon(icon, size: sublevel ? 12 : 14)
                        .frame(width: 18)
                }
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 10.5, design: .rounded))
                }
            }
            .font(.system(size: sublevel ? 12 : 13.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(
                destructive && selected
                    ? Color.ccRed
                    : (selected ? Color.ccForeground : Color.ccMuted)
            )
            .padding(.leading, sublevel ? 18 : 8)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, minHeight: sublevel ? 27 : 32)
            .background(
                selected
                    ? (destructive ? Color.ccRedSoft : Color.ccSidebarSelection)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .help(title)
        .accessibilityIdentifier(identifier)
    }

    private var totalSessionCount: Int {
        store.projects.reduce(0) { $0 + $1.sessions.count }
    }

    private var starredSessionCount: Int {
        store.projects.lazy.flatMap(\.sessions).filter(\.starred).count
    }

    private var agentCounts: [(source: HistorySource, count: Int)] {
        let sessions = store.projects.flatMap(\.sessions)
        return ConversationPresentation.sourceOrder.compactMap { source in
            let count = sessions.lazy.filter { $0.source == source }.count
            return count > 0 ? (source, count) : nil
        }
    }

    private func stableIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        })
    }
}

private struct AppLogo: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.ccBrandSoft)
                Image(systemName: "command").foregroundStyle(Color.ccBrandStrong)
            }
        }
    }
}
