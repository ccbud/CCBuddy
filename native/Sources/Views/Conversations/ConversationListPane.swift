import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationListPane: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage
    var historyDirectories: [String] = []
    var selectHistoryScope: (String) -> Void = { _ in }

    @State private var showingImporter = false
    @State private var previousIndexingState: ConversationIndexingState = .idle
    @State private var announcesIndexChanges = false

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            searchBar
            if showsScopeBar { scopeBar }
            listContent
        }
        .conversationRailMaterial()
        .onAppear {
            previousIndexingState = store.indexingState
            announcesIndexChanges = true
        }
        .onDisappear {
            announcesIndexChanges = false
        }
        .onChange(of: store.indexingState) { current in
            let previous = previousIndexingState
            previousIndexingState = current
            guard announcesIndexChanges,
                  let announcement = ConversationIndexAccessibility.announcement(
                    from: previous,
                    to: current,
                    language: appLanguage
                  ),
                  let application = NSApp else { return }
            NSAccessibility.post(
                element: application,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement.message,
                    .priority: (announcement.isFailure
                        ? NSAccessibilityPriorityLevel.high
                        : .medium).rawValue,
                ]
            )
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let files):
                Task { await store.importFiles(files) }
            case .failure(let error):
                store.reportActionError("导入失败：\(error.localizedDescription)")
            }
        }
        .accessibilityIdentifier("conversation.list")
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(scopeLabel)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.35)
                .lineLimit(1)
            Text("\(flatSessions.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ccCaption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.ccForeground.opacity(0.06))
                .clipShape(Capsule())
            Spacer(minLength: 0)
            indexingStatus
        }
        .padding(.horizontal, 16)
        // Match Wake's compact full-size-content header while retaining a drag surface.
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var indexingStatus: some View {
        switch store.indexingState {
        case .idle:
            EmptyView()
        case .scanning(let completed, let total):
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(total > 0 ? "\(completed)/\(total)" : appLanguage.localized("正在更新…"))
                    .lineLimit(1)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.ccCaption)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLanguage.localized("正在更新会话索引"))
            .accessibilityValue(total > 0 ? "\(completed)/\(total)" : "")
            .accessibilityIdentifier("conversation.indexing.progress")
        case .failed(let message):
            Label(appLanguage.localized("更新失败"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.ccRed)
                .lineLimit(1)
                .help(appLanguage.localized(message))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appLanguage.localized("会话索引状态"))
                .accessibilityValue(appLanguage.localized(message))
                .accessibilityIdentifier("conversation.indexing.failure")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.ccCaption)
                TextField(
                    "搜索项目 / 会话 / 内容…",
                    text: Binding(get: { store.listQuery }, set: { store.updateListQuery($0) })
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .accessibilityIdentifier("conversation.list.search")

                if !store.listQuery.isEmpty {
                    Button { store.updateListQuery("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ccCaption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                    .accessibilityIdentifier("conversation.list.search.clear")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color.ccConversationSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            if let progress = store.importProgress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
                    .help(appLanguage.localized("正在导入 \(progress.completed)/\(progress.total)"))
                    .accessibilityIdentifier("conversation.import.progress")
            } else {
                Button { showingImporter = true } label: {
                    Text("+")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(ConversationToolButtonStyle())
                .help(appLanguage.localized("导入 JSONL 或 ZIP"))
                .disabled(store.isMutating)
                .accessibilityLabel("导入会话")
                .accessibilityIdentifier("conversation.import")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(
                    appLanguage.localized("全部会话"),
                    value: "all",
                    symbol: "tray.full"
                )

                if showsDirectoryScopes {
                    ForEach(normalizedHistoryDirectories, id: \.self) { directory in
                        scopeChip(
                            directory,
                            value: directory,
                            symbol: "folder",
                            count: store.scopeSnapshot.sessionCounts[directory]
                        )
                    }
                    if importedIsSelectable {
                        scopeChip(
                            appLanguage.localized("已导入"),
                            value: "__imported__",
                            symbol: "square.and.arrow.down",
                            count: store.scopeSnapshot.importedCount
                        )
                    }
                }

                if trashIsSelectable {
                    scopeChip(
                        appLanguage.localized("回收站"),
                        value: "__trash__",
                        symbol: "trash",
                        count: store.scopeSnapshot.trashCount,
                        destructive: true
                    )
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 34)
        .background(Color.ccConversationList)
        .conversationAccessibilityContainerIdentifier(
            "conversation.scope",
            label: appLanguage.localized("会话范围：\(scopeLabel)")
        )
    }

    private func scopeChip(
        _ label: String,
        value: String,
        symbol: String,
        count: Int? = nil,
        destructive: Bool = false
    ) -> some View {
        let selected = store.historyActive == value
        return Button {
            selectHistoryScope(value)
        } label: {
            HStack(spacing: 5) {
                if value == "__imported__" || value == "__trash__" {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .medium))
                }
                Text(label)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((selected ? Color.white : Color.ccForeground).opacity(0.10))
                        .clipShape(Capsule())
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(
                selected
                    ? (destructive ? Color.ccRed : Color.ccForeground)
                    : Color.ccMuted
            )
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                selected
                    ? (destructive ? Color.ccRedSoft : Color.ccConversationSelection)
                    : Color.clear
            )
            .clipShape(Capsule())
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .help(label)
        .accessibilityIdentifier("conversation.scope.\(stableIdentifier(value))")
    }

    private var normalizedHistoryDirectories: [String] {
        ConversationScopePresentation.normalizedDirectories(historyDirectories)
    }

    private var importedIsSelectable: Bool {
        store.scopeSnapshot.importedCount > 0 || store.historyActive == "__imported__"
    }

    private var trashIsSelectable: Bool {
        store.scopeSnapshot.trashCount > 0 || store.historyActive == "__trash__"
    }

    private var showsDirectoryScopes: Bool {
        normalizedHistoryDirectories.count + (importedIsSelectable ? 1 : 0) > 1
    }

    private var showsScopeBar: Bool {
        ConversationScopePresentation.showsScopeBar(
            directories: historyDirectories,
            snapshot: store.scopeSnapshot,
            active: store.historyActive
        )
    }

    private var scopeLabel: String {
        switch store.historyActive {
        case "all": appLanguage.localized("全部会话")
        case "__imported__": appLanguage.localized("已导入")
        case "__trash__": appLanguage.localized("回收站")
        default: store.historyActive
        }
    }

    private var importTypes: [UTType] {
        [UTType(filenameExtension: "jsonl"), UTType.zip].compactMap { $0 }
    }

    @ViewBuilder private var listContent: some View {
        switch store.listState {
        case .idle where store.projects.isEmpty,
             .loading where store.projects.isEmpty:
            ConversationListState(
                symbol: "clock.arrow.circlepath",
                title: "正在读取本地会话…",
                showsProgress: true
            )
        case .failed(let message) where store.projects.isEmpty:
            ConversationListState(symbol: "exclamationmark.triangle", title: message) {
                Button("重试") { store.requestReload() }
                    .buttonStyle(ConversationToolButtonStyle())
                    .accessibilityIdentifier("conversation.list.retry")
            }
        default:
            if flatSessions.isEmpty {
                ConversationListState(
                    symbol: store.listQuery.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass",
                    title: emptyTitle,
                    subtitle: emptySubtitle,
                    showsProgress: store.isSearchingContent
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(flatSessions, id: \.conversationListIdentity) { session in
                            ConversationSessionRow(
                                metadata: session,
                                selected: store.selectedFile.map(ConversationFilter.fileKey)
                                    == ConversationFilter.fileKey(session.file),
                                hit: store.contentHit(for: session),
                                searchQuery: store.listQuery
                            ) {
                                Task {
                                    await store.select(
                                        session,
                                        searchHit: store.contentHit(for: session)
                                    )
                                }
                            }
                        }

                        if store.isSearchingContent {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.mini)
                                Text("正在搜索会话内容…")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ccCaption)
                            .padding(12)
                        } else if let error = store.contentSearchError {
                            Label(
                                appLanguage.localized(error),
                                systemImage: "exclamationmark.triangle"
                            )
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.ccRed)
                            .padding(12)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .accessibilityIdentifier("conversation.list.scroll")
            }
        }
    }

    private var emptyTitle: String {
        if !store.listQuery.isEmpty {
            return store.isSearchingContent ? "正在搜索会话内容…" : "没有匹配的会话"
        }
        return store.isTrash ? "回收站为空" : "没有可读取的本地会话"
    }

    private var emptySubtitle: String? {
        guard store.listQuery.isEmpty else { return nil }
        return store.isTrash ? "软删除的会话会出现在这里" : "请在设置中确认会话数据目录"
    }

    private var flatSessions: [HistorySessionMetadata] {
        store.filteredProjects
            .flatMap(\.sessions)
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
    }

    private func stableIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        })
    }
}

private struct ConversationSessionRow: View {
    @Environment(\.appLanguage) private var appLanguage

    let metadata: HistorySessionMetadata
    let selected: Bool
    let hit: HistorySearchHit?
    let searchQuery: String
    let action: () -> Void

    var body: some View {
        let activityRelative = ConversationPresentation.relativeDate(
            metadata.lastActivity,
            language: appLanguage
        )
        let activityAbsolute = ConversationPresentation.absoluteDate(
            metadata.lastActivity,
            language: appLanguage
        )
        let sourceName = ConversationPresentation.sourceName(rawValue: metadata.source.rawValue)

        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if ConversationStore.isLive(lastActivity: metadata.lastActivity) {
                        Circle()
                            .fill(Color.ccGreen)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("活跃会话")
                    }
                    if metadata.isSubagent {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.ccCaption)
                    }
                    Text(metadata.title.isEmpty ? appLanguage.localized("无标题") : metadata.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .help(metadata.title)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Image(systemName: sourceSymbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 13)
                    Text(sourceName)
                        .lineLimit(1)
                    if !metadata.project.isEmpty {
                        Text(metadata.project)
                            .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.ccForeground.opacity(0.055))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if metadata.isSubagent {
                        Image(systemName: "arrow.turn.down.right")
                            .help(appLanguage.localized("子代理"))
                    }
                    if metadata.imported {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Color.ccBrandStrong)
                    }
                    if metadata.deleted {
                        Image(systemName: "trash")
                            .foregroundStyle(Color.ccRed)
                    }
                    Spacer(minLength: 0)
                    Text(activityRelative)
                        .help(appLanguage.localized("更新于 \(activityAbsolute)"))
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.ccCaption)
                .lineLimit(1)

                if let hit, !hit.snippet.isEmpty {
                    ConversationPlainHighlightedText(value: hit.snippet, query: searchQuery)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ccMuted)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.ccConversationSelection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .accessibilityLabel("\(metadata.title)，\(sourceName)")
        .accessibilityIdentifier(metadata.conversationRowAccessibilityIdentifier)
    }

    private var sourceSymbol: String {
        switch metadata.source {
        case .claude: "sparkles"
        case .codex: "terminal"
        case .qoder: "q.square"
        case .grok: "bolt"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "atom"
        }
    }
}

private struct ConversationListState<Actions: View>: View {
    @Environment(\.appLanguage) private var appLanguage

    let symbol: String
    let title: String
    var subtitle: String?
    var showsProgress: Bool
    @ViewBuilder let actions: Actions

    init(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.showsProgress = showsProgress
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                ZStack {
                    Circle().fill(Color.ccForeground.opacity(0.055))
                    Image(systemName: symbol).font(.system(size: 20, weight: .light))
                }
                .frame(width: 48, height: 48)
            }
            Text(appLanguage.localized(title))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ccForeground)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(appLanguage.localized(subtitle))
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .foregroundStyle(Color.ccCaption)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("conversation.list.state")
    }
}

private extension ConversationListState where Actions == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil, showsProgress: Bool = false) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, showsProgress: showsProgress) {
            EmptyView()
        }
    }
}
