import AppKit
import SwiftUI

struct ConversationListPane: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workbench: ConversationWorkbenchState
    @Environment(\.appLanguage) private var appLanguage

    @State private var previousIndexingState: ConversationIndexingState = .idle
    @State private var announcesIndexChanges = false

    var body: some View {
        VStack(spacing: 0) {
            listHeader
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
        // Make the rail itself a distinct accessibility container. Without `.contain`, SwiftUI
        // propagates this identifier to every child and XCUI cannot address the 336-point column.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.list")
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(workbench.contextTitle(
                projects: store.projects,
                historyActive: store.historyActive,
                language: appLanguage
            ))
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.35)
                .lineLimit(1)
                .layoutPriority(1)
            Text("\(flatSessions.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ccCaption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.ccForeground.opacity(0.06))
                .clipShape(Capsule())
            Spacer(minLength: 0)
            sortMenu
            indexingStatus
        }
        .padding(.horizontal, 16)
        // Match Wake's compact full-size-content header while retaining a drag surface.
        .padding(.top, 20)
        .padding(.bottom, 10)
        .background(WindowDragRegion())
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ConversationWorkbenchState.SortField.allCases, id: \.self) { field in
                Button {
                    if workbench.sortField == field {
                        workbench.sortAscending.toggle()
                    } else {
                        workbench.sortField = field
                        workbench.sortAscending = false
                    }
                } label: {
                    Label(
                        appLanguage.localized(sortTitle(field)),
                        systemImage: workbench.sortField == field
                            ? (workbench.sortAscending ? "arrow.up" : "arrow.down")
                            : "circle"
                    )
                }
            }
        } label: {
            Label(
                appLanguage.localized(sortTitle(workbench.sortField)),
                systemImage: workbench.sortAscending ? "arrow.up" : "arrow.down"
            )
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.ccMuted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(appLanguage.localized("会话排序"))
        .accessibilityIdentifier("conversation.list.sort")
    }

    private func sortTitle(_ field: ConversationWorkbenchState.SortField) -> String {
        switch field {
        case .updated: "更新时间"
        case .created: "创建时间"
        case .messages: "消息数量"
        }
    }

    @ViewBuilder private var indexingStatus: some View {
        switch store.indexingState {
        case .idle:
            if case .unavailable(let message) = store.catalogWatcherState {
                Button { store.retryIndexing() } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ccRed)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("\(appLanguage.localized("实时更新关闭"))：\(appLanguage.localized(message))")
                .accessibilityLabel(appLanguage.localized("会话实时更新状态"))
                .accessibilityValue(appLanguage.localized(message))
                .accessibilityIdentifier("conversation.watcher.retry")
            }
        case .scanning(let completed, let total):
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18, height: 18)
                .help(total > 0
                    ? "\(appLanguage.localized("正在更新会话索引")) \(completed)/\(total)"
                    : appLanguage.localized("正在更新会话索引"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLanguage.localized("正在更新会话索引"))
            .accessibilityValue(total > 0 ? "\(completed)/\(total)" : "")
            .accessibilityIdentifier("conversation.indexing.progress")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Color.ccRed)
                .frame(width: 18, height: 18)
                .help(appLanguage.localized(message))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appLanguage.localized("会话索引状态"))
                .accessibilityValue(appLanguage.localized(message))
                .accessibilityIdentifier("conversation.indexing.failure")
        }
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
                Button("重试") { store.retryIndexing() }
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
        workbench.sorted(
            workbench.filteredProjects(store.filteredProjects, historyActive: store.historyActive)
                .flatMap(\.sessions)
        )
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
                    if metadata.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.ccBrandStrong)
                            .accessibilityLabel(appLanguage.localized("已置顶"))
                    } else if metadata.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.ccOrange)
                            .accessibilityLabel(appLanguage.localized("已收藏"))
                    }
                    Text(metadata.title.isEmpty ? appLanguage.localized("无标题") : metadata.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .help(metadata.title)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    ConversationSourceBrandIcon(source: metadata.source, size: 12)
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
