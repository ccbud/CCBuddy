import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationTimelinePane: View {
    @ObservedObject var store: ConversationStore
    var fontSize: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var showingMetadataEditor = false
    @State private var confirmingPermanentDelete = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if store.transcriptTabs.count > 1 {
                transcriptTabs
            }
            detail
        }
        .background(Color.ccElevated)
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
        .conversationAccessibilityContainerIdentifier(
            "conversation.timeline",
            label: appLanguage.localized("会话时间线")
        )
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
        .padding(.horizontal, 15)
        .frame(height: 39)
        .background(Color.ccElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
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
                .font(.system(size: 9.5, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(selected ? Color.ccBrandStrong : Color.ccMuted)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Color.ccBrandSoft : Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.ccBrand.opacity(0.3) : Color.ccBorder)
        )
        .contentShape(Rectangle())
    }

    private func hierarchyPrefix(for depth: Int) -> String {
        guard depth > 1 else { return "" }
        return String(repeating: "› ", count: depth - 1)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.ccCaption)

            TextField(
                "搜索消息…",
                text: Binding(get: { store.detailQuery }, set: { store.updateDetailQuery($0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .padding(.horizontal, 8)
            .frame(minWidth: 120, maxWidth: .infinity, minHeight: 27)
            .background(Color.ccInput)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.ccBorder))
            .disabled(store.selectedSession == nil)
            .accessibilityIdentifier("conversation.detail.search")

            Text(store.detailSearchPositionText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.ccCaption)
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

            if store.selectedFile != nil {
                Divider().frame(height: 18)
                actionButtons
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
        .accessibilityIdentifier("conversation.toolbar")
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                labeledToolbarButton("sparkles", title: "Claude 分析", identifier: "conversation.action.replay.claude") {
                    store.replaySelected(in: .claude, language: appLanguage)
                }
                labeledToolbarButton("bubble.left.and.text.bubble.right", title: "ChatGPT 分析", identifier: "conversation.action.replay.chatgpt") {
                    store.replaySelected(in: .chatGPT, language: appLanguage)
                }
                labeledToolbarButton("pencil", title: "编辑", identifier: "conversation.action.edit") {
                    showingMetadataEditor = true
                }
                labeledToolbarButton("doc.on.doc", title: "复制路径", identifier: "conversation.action.copy-path") {
                    store.copySelectedPath()
                }
                labeledToolbarButton("folder", title: "Finder", identifier: "conversation.action.finder") {
                    store.revealSelectedInFinder()
                }
                labeledToolbarButton("square.and.arrow.down", title: "导出", identifier: "conversation.action.export") {
                    presentRawExportPanel()
                }
                labeledToolbarButton(
                    "doc.richtext",
                    title: "HTML",
                    identifier: "conversation.action.export-html"
                ) {
                    presentHTMLExportPanel()
                }
                if store.isTrash {
                    labeledToolbarButton("arrow.uturn.backward", title: "恢复", identifier: "conversation.action.restore") {
                        Task { await store.restoreSelected() }
                    }
                    if store.canPermanentlyDeleteSelected {
                        toolbarButton(
                            "trash.slash",
                            label: "永久删除",
                            identifier: "conversation.action.delete-permanently"
                        ) {
                            confirmingPermanentDelete = true
                        }
                    }
                } else {
                    toolbarButton("trash", label: "移入回收站", identifier: "conversation.action.delete") {
                        Task { await store.softDeleteSelected() }
                    }
                }
            }
            .disabled(store.isMutating)

            Menu {
                Button("用 Claude 分析会话") {
                    store.replaySelected(in: .claude, language: appLanguage)
                }
                Button("用 ChatGPT 分析会话") {
                    store.replaySelected(in: .chatGPT, language: appLanguage)
                }
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
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
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

    private func labeledToolbarButton(
        _ symbol: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(appLanguage.localized(title), systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 27)
        }
        .buttonStyle(ConversationToolButtonStyle())
        .help(appLanguage.localized(title))
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
                Text("标题").font(.system(size: 11, weight: .semibold))
                TextField("留空以使用自动标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("conversation.edit.title")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("标签").font(.system(size: 11, weight: .semibold))
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
        .padding(20)
        .frame(width: 390)
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
        VStack(spacing: 10) {
            if showsProgress { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 30, weight: .light)) }
            Text(appLanguage.localized(title)).multilineTextAlignment(.center)
            if let subtitle {
                Text(appLanguage.localized(subtitle))
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.ccMuted)
        .padding(24)
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
