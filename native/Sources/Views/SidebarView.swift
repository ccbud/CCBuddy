import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var conversationWorkbench: ConversationWorkbenchState

    var body: some View {
        VStack(spacing: 0) {
            WindowDragRegion()
                .frame(height: 38)
                .background(Color.ccSidebar)

            brand
                .padding(.horizontal, compact ? 5 : 8)
                .padding(.bottom, model.selected == .conversations ? 12 : 18)

            if model.selected == .conversations {
                compactApplicationNavigation
                    .padding(.bottom, 12)
                ConversationLibraryNavigation(
                    store: model.conversationStore,
                    workbench: conversationWorkbench,
                    historyDirectories: model.config.historyDirs,
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
        .background(Color.ccSidebar)
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

    private var compactApplicationNavigation: some View {
        HStack(spacing: 5) {
            ForEach(AppModel.Destination.allCases) { destination in
                let selected = model.selected == destination
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.selected = destination }
                } label: {
                    Image(systemName: destination.symbol)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.ccForeground : Color.ccMuted)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(selected ? Color.ccSidebarSelection : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .help(appLanguage.localized(destination.title))
                .accessibilityLabel(appLanguage.localized(destination.title))
                .accessibilityIdentifier("sidebar.\(destination.rawValue)")
            }
        }
    }

    private func navButton(_ destination: AppModel.Destination) -> some View {
        let selected = model.selected == destination
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { model.selected = destination }
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

            VStack(spacing: 3) {
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

    let historyDirectories: [String]
    let selectHistoryScope: (String) -> Void

    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            searchToolbar

            VStack(spacing: 2) {
                libraryRow(
                    symbol: "square.stack.3d.up",
                    title: appLanguage.localized("全部会话"),
                    count: totalSessionCount,
                    selected: store.historyActive == "all"
                        && workbench.selection == .all,
                    identifier: "conversation.library.all"
                ) {
                    workbench.showAll()
                    selectHistoryScope("all")
                }

                if store.scopeSnapshot.importedCount > 0 || store.historyActive == "__imported__" {
                    libraryRow(
                        symbol: "square.and.arrow.down",
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
                        symbol: "trash",
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
                    if historyDirectories.count > 1 {
                        groupHeading(appLanguage.localized("来源"), expanded: true, action: {})
                        ForEach(historyDirectories, id: \.self) { directory in
                            libraryRow(
                                symbol: "externaldrive",
                                title: URL(fileURLWithPath: directory).lastPathComponent,
                                count: store.scopeSnapshot.sessionCounts[directory],
                                selected: store.historyActive == directory,
                                identifier: "conversation.library.root.\(stableIdentifier(directory))",
                                sublevel: true
                            ) {
                                workbench.showAll()
                                selectHistoryScope(directory)
                            }
                        }
                    }

                    groupHeading(
                        appLanguage.localized("代理"),
                        expanded: workbench.agentsExpanded
                    ) {
                        workbench.agentsExpanded.toggle()
                    }
                    if workbench.agentsExpanded {
                        ForEach(agentCounts, id: \.source.rawValue) { item in
                            libraryRow(
                                symbol: sourceSymbol(item.source),
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
                                symbol: "folder",
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
    }

    private var searchToolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
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
                .accessibilityIdentifier("conversation.list.search")
                if !store.listQuery.isEmpty {
                    Button { store.updateListQuery("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
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
                    symbol: "plus",
                    label: "导入 JSONL 或 ZIP",
                    identifier: "conversation.import"
                ) {
                    showingImporter = true
                }
                .disabled(store.isMutating)
            }

            libraryToolButton(
                symbol: "arrow.clockwise",
                label: "更新会话索引",
                identifier: "conversation.library.refresh"
            ) {
                store.retryIndexing()
            }
            .disabled(store.indexingState.isScanning)
        }
        .padding(.bottom, 12)
    }

    private func libraryToolButton(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if identifier == "conversation.library.refresh", store.indexingState.isScanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
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
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.ccMuted)
            .padding(.horizontal, 9)
            .frame(height: 29)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func libraryRow(
        symbol: String,
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
                Image(systemName: symbol)
                    .font(.system(size: sublevel ? 11.5 : 13, weight: .medium))
                    .frame(width: 18)
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

    private func sourceSymbol(_ source: HistorySource) -> String {
        switch source {
        case .claude: "sparkles"
        case .codex: "terminal"
        case .qoder: "q.square"
        case .grok: "bolt"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "atom"
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
