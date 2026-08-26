import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationTimelinePane: View {
    @ObservedObject var store: ConversationStore
    var fontSize: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var showingMetadataEditor = false
    @State private var showingOverview = false
    @State private var confirmingPermanentDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if let metadata = store.selectedMetadata {
                sessionHeader(metadata)
                if store.transcriptTabs.count > 1 {
                    transcriptTabs
                }
                toolbar
            } else {
                WindowDragRegion()
                    .frame(height: 52)
                    .background(Theme.background)
            }
            detail
        }
        .background(Theme.background)
        .sheet(isPresented: $showingMetadataEditor) {
            if let metadata = store.selectedMetadata {
                ConversationMetadataEditor(metadata: metadata) { title, tags in
                    Task { await store.updateSelectedMetadata(title: title, tags: tags) }
                }
            }
        }
        .alert("永久删除这个会话？", isPresented: $confirmingPermanentDelete) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) {
                Task { await store.permanentlyDeleteSelected() }
            }
        } message: {
            Text("主会话、导入记录与子代理文件都会被移除，此操作无法撤销。")
        }
        .accessibilityContainerIdentifier(
            "conversation.timeline",
            label: appLanguage.localized("会话时间线")
        )
    }

    /// Three bands, in Wake's order: who produced the session, what it is called and what you can
    /// do with it, then the facts about it.
    ///
    /// The last band is a tight 4pt group deliberately set 8pt below the title. Spreading those
    /// lines evenly makes them read as four unrelated blocks rather than one caption.
    private func sessionHeader(_ metadata: HistorySessionMetadata) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs + 2) {
                AgentBrandMark(source: metadata.source, size: 15)
                Text(ConversationPresentation.sourceName(rawValue: metadata.source.rawValue))
                if !metadata.project.isEmpty {
                    metadataBadge(metadata.project)
                }
                if let branch = metadata.gitBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.ccLabel())
            .foregroundStyle(Theme.mutedForeground)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.lg) {
                    sessionTitle(metadata)
                    Spacer(minLength: Space.sm)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    sessionTitle(metadata)
                    HStack {
                        Spacer(minLength: 0)
                        actionButtons
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                if let cwd = metadata.cwd, !cwd.isEmpty {
                    Label(cwd, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cwd)
                }

                HStack(spacing: Space.xs + 2) {
                    if let model = metadata.model, !model.isEmpty {
                        metadataBadge(model)
                    }
                    Text(headerStatistics(metadata).joined(separator: " · "))
                        .lineLimit(1)
                    if !metadata.tags.isEmpty {
                        ForEach(metadata.tags.prefix(2), id: \.self) { tag in
                            metadataBadge(tag)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(ConversationPresentation.relativeDate(metadata.lastActivity, language: appLanguage))
                        .help(ConversationPresentation.absoluteDate(metadata.lastActivity, language: appLanguage))
                }
            }
            .font(.ccLabel())
            .foregroundStyle(Theme.mutedForeground)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Metrics.titleBarHeight - Space.sm)
        .padding(.bottom, Space.md)
        .background(WindowDragRegion())
    }

    private func sessionTitle(_ metadata: HistorySessionMetadata) -> some View {
        Text(metadata.title.isEmpty ? appLanguage.localized("无标题") : metadata.title)
            .font(.ccTitle())
            .tracking(-0.35)
            .lineLimit(1)
            .help(metadata.title)
    }

    private func metadataBadge(_ value: String) -> some View {
        Text(value)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
    }

    private func headerStatistics(_ metadata: HistorySessionMetadata) -> [String] {
        var values = [appLanguage.localized("\(metadata.messageCount) 条消息")]
        let tokenCount = metadata.totals.inputTokens + metadata.totals.outputTokens
        if tokenCount > 0 {
            values.append("\(ConversationPresentation.tokenCount(tokenCount)) tokens")
        }
        if let credits = metadata.totals.credits {
            values.append("\(ConversationPresentation.credits(credits)) credits")
        }
        return values
    }

    private var transcriptTabs: some View {
        let tabs = store.transcriptTabs
        let subagents = Array(tabs.dropFirst())
        let activeSubagent = subagents.first(where: { $0.id == store.activeTranscriptID })

        return HStack(spacing: 6) {
            Button { store.selectTranscript(.main) } label: {
                transcriptTabLabel(
                    symbol: "person.fill",
                    title: appLanguage.localized("主会话"),
                    selected: store.activeTranscriptID == .main
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.transcript.main")

            Menu {
                ForEach(subagents) { tab in
                    Button { store.selectTranscript(tab.id) } label: {
                        HStack {
                            Image(systemName: tab.id == store.activeTranscriptID ? "checkmark" : "cpu")
                            Text("\(hierarchyPrefix(for: tab.depth))\(tab.title)")
                            Text(appLanguage.localized("\(tab.messageCount) 条"))
                        }
                    }
                    .help(tab.description)
                    .accessibilityIdentifier(
                        "conversation.transcript.\(tab.id.accessibilityComponent)"
                    )
                }
            } label: {
                transcriptTabLabel(
                    symbol: "cpu",
                    title: activeSubagent?.title
                        ?? "\(appLanguage.localized("子代理")) (\(subagents.count))",
                    selected: activeSubagent != nil,
                    showsDisclosure: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(activeSubagent?.description ?? appLanguage.localized("子代理"))
            .accessibilityIdentifier("conversation.transcript.subagents")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.sm)
        .accessibilityIdentifier("conversation.transcript.tabs")
    }

    private func transcriptTabLabel(
        symbol: String,
        title: String,
        selected: Bool,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(.ccCaption(.medium))
                .lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
        .padding(.horizontal, Space.sm + 2)
        .frame(height: Metrics.controlHeight)
        .background(selected ? Theme.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    private func hierarchyPrefix(for depth: Int) -> String {
        guard depth > 1 else { return "" }
        return String(repeating: "› ", count: depth - 1)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Typography.label, weight: .medium))
                    .foregroundStyle(Theme.mutedForeground)
                TextField(
                    "搜索消息…",
                    text: Binding(get: { store.detailQuery }, set: { store.updateDetailQuery($0) })
                )
                .textFieldStyle(.plain)
                .font(.ccCaption())
                .disabled(store.selectedSession == nil)
                .accessibilityIdentifier("conversation.detail.search")
            }
            .padding(.horizontal, Space.sm + 1)
            .frame(minWidth: 120, maxWidth: 260, minHeight: Metrics.controlHeight)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))

            Text(store.detailSearchPositionText)
                .font(.ccMono(Typography.label))
                .foregroundStyle(Theme.mutedForeground)
                .frame(minWidth: 32)
                .accessibilityIdentifier("conversation.detail.search.count")

            toolbarButton("arrow.up", label: "上一个匹配", identifier: "conversation.detail.search.previous") {
                store.previousDetailMatch()
            }
            .disabled(store.detailMatches.isEmpty)

            toolbarButton("arrow.down", label: "下一个匹配", identifier: "conversation.detail.search.next") {
                store.nextDetailMatch()
            }
            .disabled(store.detailMatches.isEmpty)

            if !store.detailQuery.isEmpty {
                toolbarButton("xmark", label: "清除消息搜索", identifier: "conversation.detail.search.clear") {
                    store.updateDetailQuery("")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.sm + 2)
        .accessibilityIdentifier("conversation.toolbar")
    }

    /// One primary action, two icon affordances, everything else in the overflow menu.
    ///
    /// "Continue in terminal" earns the primary slot because it is the reason to look a session up
    /// in the first place. The two analysis actions used to sit here as equally weighted labeled
    /// buttons, which left the header with three competing calls to action and no obvious next step.
    private var actionButtons: some View {
        HStack(spacing: Space.xs) {
            if let metadata = store.selectedMetadata,
               ConversationResume.isSupported(metadata.source),
               !store.isTrash {
                Button {
                    store.resumeSelected()
                } label: {
                    Label(appLanguage.localized("在终端继续"), systemImage: "terminal")
                }
                .buttonStyle(CCButtonStyle(role: .primary, size: 27))
                .help(appLanguage.localized(
                    "在 \(ConversationResume.preferredTerminal.displayName) 中继续这个会话"
                ))
                .accessibilityIdentifier("conversation.action.resume")
            }

            if store.isTrash {
                toolbarButton("arrow.uturn.backward", label: "恢复", identifier: "conversation.action.restore") {
                    Task { await store.restoreSelected() }
                }
            }
            if let metadata = store.selectedMetadata {
                Button {
                    Task { await store.toggleStarSelected() }
                } label: {
                    Image(systemName: metadata.starred ? "star.fill" : "star")
                }
                .buttonStyle(CCIconButtonStyle(
                    size: 27,
                    symbolSize: Typography.caption,
                    tint: metadata.starred ? Theme.accentText : Theme.mutedForeground
                ))
                .help(appLanguage.localized(metadata.starred ? "取消收藏" : "收藏会话"))
                .accessibilityLabel(appLanguage.localized(metadata.starred ? "取消收藏" : "收藏会话"))
                .accessibilityIdentifier("conversation.action.star")

                Button {
                    Task { await store.togglePinSelected() }
                } label: {
                    Image(systemName: metadata.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(CCIconButtonStyle(
                    size: 27,
                    symbolSize: Typography.caption,
                    tint: metadata.pinned ? Theme.accentText : Theme.mutedForeground
                ))
                .help(appLanguage.localized(metadata.pinned ? "取消置顶" : "置顶会话"))
                .accessibilityLabel(appLanguage.localized(metadata.pinned ? "取消置顶" : "置顶会话"))
                .accessibilityIdentifier("conversation.action.pin")
            }

            toolbarButton("sidebar.right", label: "会话概览", identifier: "conversation.action.overview") {
                showingOverview.toggle()
            }
            .popover(isPresented: $showingOverview, arrowEdge: .bottom) {
                ConversationOverviewPane(
                    store: store,
                    collapsed: false,
                    toggleCollapsed: { showingOverview = false }
                )
                .frame(width: 280, height: 520)
            }

            Menu {
                if let metadata = store.selectedMetadata,
                   ConversationResume.isSupported(metadata.source) {
                    ForEach(ConversationResume.installedTerminals) { terminal in
                        Button(appLanguage.localized("在 \(terminal.displayName) 中继续")) {
                            store.resumeSelected(in: terminal)
                        }
                    }
                    Divider()
                }
                Button("用 Claude 分析会话") {
                    store.replaySelected(in: .claude, language: appLanguage)
                }
                .accessibilityIdentifier("conversation.action.replay.claude")
                Button("用 ChatGPT 分析会话") {
                    store.replaySelected(in: .chatGPT, language: appLanguage)
                }
                .accessibilityIdentifier("conversation.action.replay.chatgpt")
                Divider()
                Button("编辑标题与标签…") { showingMetadataEditor = true }
                Button("复制会话路径") { store.copySelectedPath() }
                Button("在 Finder 中显示") { store.revealSelectedInFinder() }
                Divider()
                Button("导出原始会话…") { presentRawExportPanel() }
                Button("导出独立 HTML…") { presentHTMLExportPanel() }
                Divider()
                if store.isTrash {
                    Button("恢复会话") { Task { await store.restoreSelected() } }
                    if store.canPermanentlyDeleteSelected {
                        Button("永久删除…", role: .destructive) {
                            confirmingPermanentDelete = true
                        }
                    }
                } else {
                    Button("移入回收站", role: .destructive) {
                        Task { await store.softDeleteSelected() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(appLanguage.localized("会话操作"))
            .disabled(store.isMutating)
            .accessibilityIdentifier("conversation.action.more")
        }
        .disabled(store.isMutating)
    }

    @ViewBuilder private var detail: some View {
        switch store.detailState {
        case .idle:
            ConversationDetailState(
                symbol: "bubble.left.and.text.bubble.right",
                title: "选择左侧会话，查看完整对话历史",
                subtitle: "数据来自已配置的本地会话目录 · 活跃会话实时跟随"
            )
        case .loading:
            ConversationDetailState(symbol: "clock.arrow.circlepath", title: "正在读取会话…", showsProgress: true)
        case .failed(let message):
            ConversationDetailState(symbol: "exclamationmark.triangle", title: message) {
                Button("重试") { Task { await store.retrySelectedSession() } }
                    .buttonStyle(ConversationToolButtonStyle())
                    .accessibilityIdentifier("conversation.detail.retry")
            }
        case .loaded:
            if let session = store.activeTranscript {
                timeline(session)
            } else {
                ConversationDetailState(symbol: "bubble.left", title: "会话没有可显示的消息")
            }
        }
    }

    private func timeline(_ session: HistorySession) -> some View {
        let results = ConversationVisibleText.resultMap(in: session.messages)
        let pairedIDs = ConversationVisibleText.pairedToolResultIDs(in: session.messages)
        let currentMatch = store.detailMatchIndex >= 0 && store.detailMatchIndex < store.detailMatches.count
            ? store.detailMatches[store.detailMatchIndex].messageIndex
            : nil

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(session.messages.enumerated()), id: \.offset) { index, message in
                        if ConversationMessageView.isVisible(message, pairedToolResultIDs: pairedIDs) {
                            ConversationMessageView(
                                message: message,
                                messageIndex: index,
                                sourceRawValue: session.metadata.source.rawValue,
                                toolResults: results,
                                pairedToolResultIDs: pairedIDs,
                                searchQuery: store.detailQuery,
                                isCurrentSearchMatch: currentMatch == index,
                                fontSize: CGFloat(fontSize ?? 13)
                            )
                            .id(ConversationPresentation.messageAnchor(index))
                        }
                    }
                    Color.clear.frame(height: 1).id(ConversationPresentation.bottomAnchor)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onAppear {
                if store.isSelectedSessionLive {
                    proxy.scrollTo(ConversationPresentation.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.jumpRequest) { request in
                guard let request else { return }
                scroll(proxy, to: ConversationPresentation.messageAnchor(request.messageIndex), anchor: .center)
            }
            .onChange(of: store.followLatestRevision) { _ in
                scroll(proxy, to: ConversationPresentation.bottomAnchor, anchor: .bottom)
            }
            .accessibilityIdentifier("conversation.timeline.scroll")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: anchor)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    private func toolbarButton(
        _ symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ConversationToolButtonStyle())
            .help(appLanguage.localized(label))
            .accessibilityLabel(appLanguage.localized(label))
            .accessibilityIdentifier(identifier)
    }

    private func presentRawExportPanel() {
        guard store.selectedFile != nil else { return }
        let fileExtension = store.selectedRawExportExtension
        let panel = NSSavePanel()
        panel.title = appLanguage.localized("导出原始会话")
        panel.prompt = appLanguage.localized("导出")
        panel.nameFieldStringValue = "\(store.selectedExportBaseName).\(fileExtension)"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in await store.exportSelectedRaw(to: destination) }
        }
    }

    private func presentHTMLExportPanel() {
        guard store.selectedSession != nil else { return }
        let panel = NSSavePanel()
        panel.title = appLanguage.localized("导出独立 HTML")
        panel.prompt = appLanguage.localized("导出")
        panel.nameFieldStringValue = "\(store.selectedExportBaseName).html"
        panel.allowedContentTypes = [.html]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in await store.exportSelectedHTML(to: destination) }
        }
    }
}

private struct ConversationMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var tags: String
    let save: (String, [String]) -> Void

    init(metadata: HistorySessionMetadata, save: @escaping (String, [String]) -> Void) {
        _title = State(initialValue: metadata.title == metadata.autoTitle ? "" : metadata.title)
        _tags = State(initialValue: metadata.tags.joined(separator: ", "))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("标题").font(.ccCaption(.medium))
                TextField("留空以使用自动标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("conversation.edit.title")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("标签").font(.ccCaption(.medium))
                TextField("用逗号分隔", text: $tags)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("conversation.edit.tags")
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save(title, parsedTags)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("conversation.edit.save")
            }
        }
        .padding(Space.xl)
        .frame(width: 400)
        .accessibilityIdentifier("conversation.edit.sheet")
    }

    private var parsedTags: [String] {
        tags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ConversationDetailState<Actions: View>: View {
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
        VStack {
            CCEmptyState(
                symbol: symbol,
                title: appLanguage.localized(title),
                message: subtitle.map { appLanguage.localized($0) },
                showsProgress: showsProgress
            ) {
                actions
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("conversation.detail.state")
    }
}

private extension ConversationDetailState where Actions == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil, showsProgress: Bool = false) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, showsProgress: showsProgress) {
            EmptyView()
        }
    }
}
