import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationTimelinePane: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var columns: ColumnLayout
    var fontSize: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var showingMetadataEditor = false
    @State private var confirmingPermanentDelete = false
    @FocusState private var detailSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let metadata = store.selectedMetadata {
                sessionHeader(metadata)
                secondaryBar
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

    /// Two bands: the title with everything you can do to it, then one caption line of facts.
    ///
    /// It used to be four — provenance, title, folder, statistics — each on its own row, with the
    /// transcript tabs and the search field below that again. Six rows of chrome stood between
    /// opening a session and reading its first message, and on a narrow column the wrapping made it
    /// worse rather than better. The provenance now rides beside the title, and the folder joins the
    /// statistics on a single line that truncates in the middle rather than wrapping.
    private func sessionHeader(_ metadata: HistorySessionMetadata) -> some View {
        let statistics = headerStatistics(ConversationHeaderStatistics.metadata(
            selectedMetadata: metadata,
            loadedParent: store.selectedSession,
            activeTranscript: store.activeTranscript
        )).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: Space.xs + 2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.sm) {
                    AgentBrandMark(source: metadata.source, size: 20)
                    sessionTitle(metadata).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: Space.sm)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        AgentBrandMark(source: metadata.source, size: 20)
                        sessionTitle(metadata)
                        Spacer(minLength: 0)
                    }
                    actionButtons
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: Space.xs + 2) {
                if !metadata.project.isEmpty {
                    metadataBadge(metadata.project)
                }
                if let branch = metadata.gitBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if let model = metadata.model, !model.isEmpty {
                    metadataBadge(model)
                }
                if let cwd = metadata.cwd, !cwd.isEmpty {
                    Label(cwd, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cwd)
                }
                Text(statistics)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statistics)
                    .accessibilityIdentifier("conversation.statistics")
                ForEach(metadata.tags.prefix(2), id: \.self) { tag in
                    metadataBadge(tag)
                }
                Spacer(minLength: Space.xs)
                Text(ConversationPresentation.relativeDate(metadata.lastActivity, language: appLanguage))
                    .lineLimit(1)
                    .layoutPriority(2)
                    .help(ConversationPresentation.absoluteDate(metadata.lastActivity, language: appLanguage))
            }
            .font(.ccLabel())
            .foregroundStyle(Theme.mutedForeground)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Metrics.titleBarHeight - Space.sm)
        .padding(.bottom, Space.sm)
        .background(WindowDragRegion())
    }

    private func sessionTitle(_ metadata: HistorySessionMetadata) -> some View {
        Text(metadata.title.isEmpty ? appLanguage.localized("无标题") : metadata.title)
            .font(.ccTitle())
            .tracking(-0.65)
            .lineLimit(1)
            .help(metadata.title)
            .accessibilityIdentifier("conversation.title")
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

    /// Which transcript you are reading, and how to find something in it — one row, not two.
    ///
    /// These are the same kind of thing: neither acts on the session, both only change what the
    /// pane below shows. The tabs take the left because they name the thing; search takes the right
    /// because it is a tool, and it keeps the row when a session has no subagents to switch between.
    private var secondaryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) {
                if store.transcriptTabs.count > 1 { transcriptTabs }
                Spacer(minLength: Space.xs)
                searchControls
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                if store.transcriptTabs.count > 1 { transcriptTabs }
                searchControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .ccGlass(radius: Radius.row)
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.toolbar")
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
            .help(activeSubagent?.description ?? appLanguage.localized("子代理"))
            .accessibilityIdentifier("conversation.transcript.subagents")
        }
        .accessibilityElement(children: .contain)
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

    private var searchControls: some View {
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
                .focused($detailSearchFocused)
                .onSubmit { store.nextDetailMatch() }
                .disabled(store.selectedSession == nil)
                .accessibilityIdentifier("conversation.detail.search")
                if store.isSearchingDetail {
                    ConversationActivityIndicator(controlSize: .mini)
                        .help(appLanguage.localized(ConversationActivityStage.searchingMessages.titleKey))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(appLanguage.localized(ConversationActivityStage.searchingMessages.titleKey))
                        .accessibilityIdentifier("conversation.detail.search.progress")
                }
            }
            .padding(.horizontal, Space.sm + 1)
            .frame(minWidth: 110, idealWidth: 200, maxWidth: 260, minHeight: Metrics.controlHeight)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))

            Text(store.isSearchingDetail ? "…" : store.detailSearchPositionText)
                .font(.ccMono(Typography.label))
                .foregroundStyle(Theme.mutedForeground)
                .frame(minWidth: 32)
                .accessibilityLabel(store.isSearchingDetail
                    ? appLanguage.localized(ConversationActivityStage.searchingMessages.titleKey)
                    : store.detailSearchPositionText)
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
        }
        .background {
            Button("") { detailSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Two named actions, three affordances, everything else in the overflow.
    ///
    /// The pair a session is looked up for is "continue it" and "have something read it", so both
    /// are now controls you can see: the first as the clay primary, the second as a labelled menu
    /// beside it. Analysis used to be two unnamed lines buried in the overflow, which is why nobody
    /// noticed that its links had stopped working. Each of them carries its variants — which
    /// terminal, which reviewer — in an attached chevron rather than in the overflow, so the
    /// overflow is left holding only the things that act on the file.
    private var actionButtons: some View {
        HStack(spacing: Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs) {
                    resumeControl(compact: false)
                    analysisMenu(compact: false)
                }
                HStack(spacing: Space.xs) {
                    resumeControl(compact: true)
                    analysisMenu(compact: true)
                }
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

            Button {
                columns.toggleInspector()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(CCIconButtonStyle(
                size: 27,
                symbolSize: Typography.caption,
                tint: columns.inspectorVisible ? Theme.accentText : Theme.mutedForeground
            ))
            .help(appLanguage.localized("会话概览"))
            .accessibilityLabel(appLanguage.localized("会话概览"))
            .accessibilityIdentifier("conversation.action.overview")

            Menu {
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

    /// Resume in the preferred terminal, with the other installed terminals under the chevron.
    @ViewBuilder private func resumeControl(compact: Bool) -> some View {
        if let metadata = store.selectedMetadata,
           ConversationResume.isSupported(metadata.source),
           !store.isTrash {
            let terminal = ConversationResume.preferredTerminal
            HStack(spacing: 1) {
                Button {
                    store.resumeSelected()
                } label: {
                    if compact {
                        Image(systemName: "terminal")
                            .frame(width: 15)
                    } else {
                        Label(appLanguage.localized("在终端继续"), systemImage: "terminal")
                    }
                }
                .buttonStyle(CCButtonStyle(role: .primary, size: 27))
                .help(appLanguage.localized("在 \(terminal.displayName) 中继续这个会话"))
                .accessibilityLabel(appLanguage.localized("在终端继续"))
                .accessibilityIdentifier("conversation.action.resume")

                if ConversationResume.installedTerminals.count > 1 {
                    Menu {
                        ForEach(ConversationResume.installedTerminals) { candidate in
                            Button(appLanguage.localized("在 \(candidate.displayName) 中继续")) {
                                store.resumeSelected(in: candidate)
                            }
                        }
                    } label: {
                        splitChevron(tint: Theme.onAccent, background: Theme.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(appLanguage.localized("选择终端"))
                    .accessibilityIdentifier("conversation.action.resume.terminals")
                }
            }
        }
    }

    /// Hand the transcript — and every subagent transcript with it — to another agent to review.
    @ViewBuilder private func analysisMenu(compact: Bool) -> some View {
        if store.selectedMetadata != nil {
            Menu {
                Button("用 Claude 分析会话") {
                    store.replaySelected(in: .claude, language: appLanguage)
                }
                .accessibilityIdentifier("conversation.action.replay.claude")
                Button("用 ChatGPT 分析会话") {
                    store.replaySelected(in: .chatGPT, language: appLanguage)
                }
                .accessibilityIdentifier("conversation.action.replay.chatgpt")
                Divider()
                // Not every reviewer registers a URL scheme, and a link can only ever reach the two
                // that do. This one reaches the rest.
                Button("复制复盘提示词") {
                    store.copyReplayPrompt(for: .claude, language: appLanguage)
                }
                .accessibilityIdentifier("conversation.action.replay.copy")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: Typography.caption, weight: .medium))
                    if !compact {
                        Text(appLanguage.localized("分析"))
                            .font(.ccBody(.medium))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(Theme.foreground)
                .padding(.horizontal, compact ? Space.sm : Space.md)
                .frame(height: 27)
                .background(Theme.fillSubtle)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(appLanguage.localized("交给另一个 agent 复盘这段会话"))
            .accessibilityIdentifier("conversation.action.analyze")
        }
    }

    private func splitChevron(tint: Color, background: Color) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 27)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        switch store.detailState {
        case .idle:
            // Inviting a selection from an empty list put two competing empty states side by side,
            // one of them asking for something the other had just said does not exist. The list
            // keeps the explanation; this side simply stays quiet.
            if store.filteredSessionCount > 0 {
                ConversationDetailState(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "选择左侧会话，查看完整对话历史",
                    subtitle: "数据来自已配置的本地会话目录 · 活跃会话实时跟随"
                )
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .loading:
            loadingFeedback
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

    private var loadingFeedback: some View {
        VStack(spacing: Space.lg) {
            ConversationActivityFeedback(stage: .openingSession, prominent: true)
                .accessibilityIdentifier("conversation.detail.loading.status")
            if let metadata = store.selectedMetadata, metadata.sizeBytes > 0 {
                Label(ByteCountFormatter.string(fromByteCount: Int64(clamping: metadata.sizeBytes), countStyle: .file),
                      systemImage: "doc.text")
                    .font(.ccLabel())
                    .monospacedDigit()
                    .foregroundStyle(Theme.mutedForeground)
                    .help(metadata.file.lastPathComponent)
                    .accessibilityIdentifier("conversation.detail.loading.size")
            }
            Button(appLanguage.localized("取消打开")) { store.clearSelection() }
                .buttonStyle(CCButtonStyle())
                .accessibilityIdentifier("conversation.detail.loading.cancel")
        }
        .padding(Space.xxl)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.detail.loading")
    }

    private func timeline(_ session: HistorySession) -> some View {
        // Taken from the store, which computes them once per transcript. Rebuilding them here meant
        // walking every message on every redraw.
        let projection = store.transcriptProjection
        let currentMatch = store.detailMatchIndex >= 0 && store.detailMatchIndex < store.detailMatches.count
            ? store.detailMatches[store.detailMatchIndex].messageIndex
            : nil

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxl) {
                    // Indices, not `enumerated()`: the latter copies the whole message array into
                    // a fresh array of tuples every time the body runs.
                    ForEach(projection.visibleMessageIndices, id: \.self) { index in
                        let message = session.messages[index]
                        ConversationMessageView(
                                message: message,
                                messageIndex: index,
                                sourceRawValue: session.metadata.source.rawValue,
                                projection: projection,
                                searchQuery: store.detailQuery,
                                isCurrentSearchMatch: currentMatch == index,
                                fontSize: CGFloat(fontSize ?? 13)
                            )
                            .id(ConversationPresentation.messageAnchor(index))
                    }
                    Color.clear.frame(height: 1).id(ConversationPresentation.bottomAnchor)
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xxl)
                .padding(.bottom, 68)
                .frame(maxWidth: Metrics.readingMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onAppear {
                if let request = store.jumpRequest {
                    proxy.scrollTo(ConversationPresentation.messageAnchor(request.messageIndex), anchor: .center)
                } else if store.isFollowingLatest && store.isSelectedSessionLive {
                    proxy.scrollTo(ConversationPresentation.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: store.jumpRequest) { request in
                guard let request else { return }
                scroll(proxy, to: ConversationPresentation.messageAnchor(request.messageIndex), anchor: .center)
            }
            .onChange(of: store.followLatestRevision) { _ in
                guard store.isFollowingLatest else { return }
                scroll(proxy, to: ConversationPresentation.bottomAnchor, anchor: .bottom)
            }
            .accessibilityIdentifier("conversation.timeline.scroll")
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: Space.xs) {
                    Button {
                        NotificationCenter.default.post(name: .ccbudToggleFocusMode, object: nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.ccIcon)
                    .help(appLanguage.localized("专注阅读") + " · ⌘⇧S")
                    .accessibilityLabel(appLanguage.localized("专注阅读"))
                    .accessibilityIdentifier("conversation.focus")
                    Button {
                        store.jumpToLatest()
                    } label: {
                        Label(appLanguage.localized("最新消息"), systemImage: "arrow.down")
                            .font(.ccCaption(.medium))
                            .padding(.horizontal, Space.sm)
                            .frame(height: Metrics.controlHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("conversation.jump.latest")
                }
                .padding(Space.xs)
                .ccGlass(radius: Radius.panel, interactive: true)
                .padding(Space.md)
            }
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
