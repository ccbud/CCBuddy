import AppKit
import SwiftUI

struct ConversationListPane: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workbench: ConversationWorkbenchState
    @ObservedObject var columns: ColumnLayout
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
        // A bare identifier on a container propagates into its descendants, so the column matched
        // several elements at once and automation could not ask for its frame. Making the column an
        // accessibility element in its own right — still containing its rows — gives exactly one.
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
                .font(.ccTitle())
                .tracking(-0.35)
                .lineLimit(1)
            CCBadge(text: "\(flatSessions.count)")
            Spacer(minLength: 0)
            indexingStatus
            ColumnToggle(
                symbol: "sidebar.left",
                help: appLanguage.localized("隐藏会话列表"),
                identifier: "layout.toggle.stream"
            ) {
                columns.toggleStream()
            }
        }
        .padding(.horizontal, Space.lg)
        // The column carries the traffic-light band in its own material rather than the shell
        // painting a title strip across all three columns.
        .padding(.top, Metrics.titleBarHeight - Space.sm)
        .padding(.bottom, Space.sm + 2)
        .background(WindowDragRegion())
    }

    @ViewBuilder private var indexingStatus: some View {
        switch store.indexingState {
        case .idle:
            if case .unavailable(let message) = store.catalogWatcherState {
                Button { store.retryIndexing() } label: {
                    Label(appLanguage.localized("实时更新关闭"), systemImage: "exclamationmark.triangle")
                        .font(.ccLabel())
                        .foregroundStyle(Theme.danger)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(appLanguage.localized(message))
                .accessibilityLabel(appLanguage.localized("会话实时更新状态"))
                .accessibilityValue(appLanguage.localized(message))
                .accessibilityIdentifier("conversation.watcher.retry")
            }
        case .scanning(let completed, let total):
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(total > 0 ? "\(completed)/\(total)" : appLanguage.localized("正在更新…"))
                    .lineLimit(1)
            }
            .font(.ccLabel())
            .foregroundStyle(Theme.mutedForeground)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appLanguage.localized("正在更新会话索引"))
            .accessibilityValue(total > 0 ? "\(completed)/\(total)" : "")
            .accessibilityIdentifier("conversation.indexing.progress")
        case .incomplete(let message):
            Label(appLanguage.localized("部分会话已跳过"), systemImage: "exclamationmark.circle")
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .help(appLanguage.localized(message))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appLanguage.localized("会话索引状态"))
                .accessibilityValue(appLanguage.localized(message))
                .accessibilityIdentifier("conversation.indexing.incomplete")
        case .failed(let message):
            Label(appLanguage.localized("更新失败"), systemImage: "exclamationmark.triangle")
                .font(.ccLabel())
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
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
                            .foregroundStyle(Theme.mutedForeground)
                            .padding(12)
                        } else if let error = store.contentSearchError {
                            Label(
                                appLanguage.localized(error),
                                systemImage: "exclamationmark.triangle"
                            )
                                .font(.ccLabel())
                                .foregroundStyle(Theme.danger)
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
        workbench.filteredProjects(store.filteredProjects, historyActive: store.historyActive)
            .flatMap(\.sessions)
            .sorted { lhs, rhs in
                // Pinned sessions hold the top of the stream; everything else is by recency.
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
    }
}

/// Internal rather than private so the off-screen proof sheets can render it: this row is the most
/// repeated element in the application, and it is worth being able to look at without a GUI session.
struct ConversationSessionRow: View {
    @Environment(\.appLanguage) private var appLanguage

    let metadata: HistorySessionMetadata
    let selected: Bool
    let hit: HistorySearchHit?
    let searchQuery: String
    let action: () -> Void

    @State private var hovering = false

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
                            .fill(Theme.success)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("活跃会话")
                    }
                    if metadata.isSubagent {
                        // Once, at the head of the title: the row already carries the relationship
                        // there, and repeating it in the metadata line said nothing new.
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.mutedForeground)
                            .accessibilityLabel(appLanguage.localized("子代理"))
                            .help(appLanguage.localized("子代理"))
                    }
                    Text(metadata.title.isEmpty ? appLanguage.localized("无标题") : metadata.title)
                        .font(.ccBody(.medium))
                        .lineLimit(1)
                        .help(metadata.title)
                    if metadata.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: Typography.label))
                            .foregroundStyle(Theme.accentText)
                            .accessibilityLabel(appLanguage.localized("已置顶"))
                    }
                    if metadata.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: Typography.label))
                            .foregroundStyle(Theme.accentText)
                            .accessibilityLabel(appLanguage.localized("已收藏"))
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: Space.xs + 2) {
                    AgentBrandMark(source: metadata.source, size: 15)
                    Text(sourceName)
                        .lineLimit(1)
                    if !metadata.project.isEmpty {
                        Text(metadata.project)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.fill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
                    }
                    if metadata.imported {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Theme.accentText)
                    }
                    if metadata.deleted {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.danger)
                    }
                    Spacer(minLength: 0)
                    Text(activityRelative)
                        .help(appLanguage.localized("更新于 \(activityAbsolute)"))
                }
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)

                if let hit, !hit.snippet.isEmpty {
                    ConversationPlainHighlightedText(value: hit.snippet, query: searchQuery)
                        .font(.ccLabel())
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : (hovering ? Theme.hover : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .onHover { hovering = $0 }
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
                    Circle().fill(Theme.fill)
                    Image(systemName: symbol).font(.system(size: 20, weight: .light))
                }
                .frame(width: 48, height: 48)
            }
            Text(appLanguage.localized(title))
                .font(.ccBody(.medium))
                .foregroundStyle(Theme.foreground)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(appLanguage.localized(subtitle))
                    .font(.ccCaption())
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .foregroundStyle(Theme.mutedForeground)
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
