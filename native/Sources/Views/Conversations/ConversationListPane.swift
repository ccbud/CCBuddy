import SwiftUI
import UniformTypeIdentifiers

struct ConversationListPane: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage
    let collapsed: Bool
    let toggleCollapsed: () -> Void
    var historyDirectories: [String] = []
    var selectHistoryScope: (String) -> Void = { _ in }

    @State private var collapsedProjects = Set<String>()
    @State private var showingImporter = false

    var body: some View {
        Group {
            if collapsed {
                Button(action: toggleCollapsed) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ccMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ConversationPressableButtonStyle())
                .help(appLanguage.localized("展开会话列表"))
                .accessibilityLabel(appLanguage.localized("展开会话列表"))
                .accessibilityIdentifier("conversation.list.expand")
            } else {
                VStack(spacing: 0) {
                    searchBar
                    if showsScopeBar { scopeBar }
                    listContent
                }
            }
        }
        .conversationRailMaterial()
        .overlay(alignment: .trailing) { Rectangle().fill(Color.ccBorder).frame(width: 1) }
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

    private var searchBar: some View {
        HStack(spacing: 5) {
            Button(action: toggleCollapsed) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(ConversationToolButtonStyle())
            .help(appLanguage.localized("收起会话列表"))
            .accessibilityLabel(appLanguage.localized("收起会话列表"))
            .accessibilityIdentifier("conversation.list.collapse")

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
            .frame(height: 27)
            .background(Color.ccInput)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))

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
        .padding(.horizontal, 8)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
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
        .background(Color.ccSidebar.opacity(0.2))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
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
                    ? (destructive ? Color.ccRed : Color.ccBrandStrong)
                    : Color.ccMuted
            )
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                selected
                    ? (destructive ? Color.ccRedSoft : Color.ccBrandSoft)
                    : Color.clear
            )
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(
                    selected
                        ? (destructive ? Color.ccRed.opacity(0.35) : Color.ccBrand.opacity(0.35))
                        : Color.ccBorder
                )
            }
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
            if store.filteredProjects.isEmpty {
                ConversationListState(
                    symbol: store.listQuery.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass",
                    title: emptyTitle,
                    subtitle: emptySubtitle,
                    showsProgress: store.isSearchingContent
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.filteredProjects) { project in
                            Section {
                                if !isCollapsed(project) {
                                    ForEach(project.sessions) { session in
                                        ConversationSessionRow(
                                            metadata: session,
                                            selected: store.selectedFile.map(ConversationFilter.fileKey)
                                                == ConversationFilter.fileKey(session.file),
                                            hit: store.contentHit(for: session),
                                            searchQuery: store.listQuery
                                        ) {
                                            Task { await store.select(session) }
                                        }
                                    }
                                }
                            } header: {
                                projectHeader(project)
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

    private func isCollapsed(_ project: HistoryProject) -> Bool {
        store.listQuery.isEmpty && collapsedProjects.contains(project.id)
    }

    private func projectHeader(_ project: HistoryProject) -> some View {
        Button {
            if collapsedProjects.contains(project.id) {
                collapsedProjects.remove(project.id)
            } else {
                collapsedProjects.insert(project.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed(project) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.ccCaption)
                    .frame(width: 10)
                Text(project.name.isEmpty ? appLanguage.localized("未知项目") : project.name)
                    .font(.system(size: 12.5, weight: .bold))
                    .tracking(-0.12)
                    .lineLimit(1)
                    .help(project.cwd)
                Spacer(minLength: 4)
                Text("\(project.sessions.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.ccMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.ccForeground.opacity(0.055))
                    .clipShape(Capsule())
            }
            .foregroundStyle(Color.ccForeground)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.ccSidebar.opacity(0.96))
            .contentShape(Rectangle())
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .accessibilityLabel(appLanguage.localized(
            "\(project.name)，\(project.sessions.count) 个会话"
        ))
        .accessibilityIdentifier("conversation.project.\(stableIdentifier(project.id))")
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
        let createdRelative = ConversationPresentation.relativeDate(
            metadata.createdAt,
            language: appLanguage
        )
        let createdAbsolute = ConversationPresentation.absoluteDate(
            metadata.createdAt,
            language: appLanguage
        )
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
                HStack(spacing: 5) {
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
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .help(metadata.title)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 5) {
                    if let model = metadata.model, !model.isEmpty {
                        Text(model).foregroundStyle(Color.ccBrandStrong)
                    }
                    Text(ConversationPresentation.sourceShortName(
                        rawValue: metadata.source.rawValue
                    ))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.ccForeground.opacity(0.055))
                        .clipShape(Capsule())
                    if metadata.isSubagent {
                        Text([appLanguage.localized("子代理"), metadata.agentNickname]
                            .compactMap { $0 }.joined(separator: " · "))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.ccForeground.opacity(0.055))
                            .clipShape(Capsule())
                    }
                    if metadata.imported {
                        Label("导入", systemImage: "square.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.ccBrandStrong)
                    }
                    if metadata.deleted {
                        Label("回收站", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.ccRed)
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.ccCaption)
                .lineLimit(1)

                if let hit, !hit.snippet.isEmpty {
                    ConversationPlainHighlightedText(value: hit.snippet, query: searchQuery)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ccMuted)
                        .lineLimit(2)
                }

                if !metadata.tags.isEmpty {
                    FlowTagRow(tags: metadata.tags)
                }

                HStack(spacing: 6) {
                    Text(createdRelative)
                        .help(appLanguage.localized("开始于 \(createdAbsolute)"))
                    if metadata.lastActivity.timeIntervalSince(metadata.createdAt) > 60 {
                        Text(appLanguage.localized("更新 \(activityRelative)"))
                            .help(appLanguage.localized("更新于 \(activityAbsolute)"))
                    }
                    Text(ConversationPresentation.byteCount(metadata.sizeBytes, language: appLanguage))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.ccCaption)
            }
            .padding(.leading, metadata.isSubagent ? 31 : 22)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.ccBrandSoft : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Color.ccBrand).frame(width: 2.5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
        .accessibilityLabel("\(metadata.title)，\(sourceName)")
        .accessibilityIdentifier("conversation.session.\(metadata.id)")
    }
}

private struct FlowTagRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.ccBrandStrong)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.ccBrandSoft)
                    .clipShape(Capsule())
            }
            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.ccCaption)
            }
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
        VStack(spacing: 9) {
            if showsProgress { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 18, weight: .light)) }
            Text(appLanguage.localized(title)).multilineTextAlignment(.center)
            if let subtitle {
                Text(appLanguage.localized(subtitle))
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .font(.system(size: 11.5))
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
