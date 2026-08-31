import AppKit
import SwiftUI

/// Wake's ⌘K panel: one command-level way into the whole library.
///
/// It reuses the store's existing full-text search rather than opening a second search path, so
/// there is one loading state, one error path and one set of hits. That also means the session
/// stream stays filtered to the same query after the panel closes — the sidebar field still shows
/// it, which is what explains the filtered list.
struct ConversationSearchPalette: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage

    let dismiss: () -> Void

    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var keyMonitor: Any?

    private static let width: CGFloat = 680
    private static let topInset: CGFloat = 72
    private static let quietHeight: CGFloat = 250
    private static let resultsHeight: CGFloat = 460

    private var results: [HistorySessionMetadata] {
        store.filteredProjects
            .flatMap(\.sessions)
            .sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // A scrim, not a blur: the library stays legible behind the panel so the search reads
            // as a layer over the app rather than a separate screen.
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            panel
                .frame(width: Self.width)
                .padding(.top, Self.topInset)
        }
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .accessibilityIdentifier("conversation.search.palette")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(Theme.separator).frame(height: 1)
            content
            Rectangle().fill(Theme.separator).frame(height: 1)
            footer
        }
        .floatingSurface()
    }

    private var field: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Typography.heading, weight: .light))
                .foregroundStyle(Theme.mutedForeground)
            TextField(
                appLanguage.localized("搜索全部会话"),
                text: Binding(
                    get: { store.listQuery },
                    set: { value in
                        store.updateListQuery(value)
                        highlighted = 0
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: Typography.heading))
            .focused($focused)
            .onSubmit(openHighlighted)
            .accessibilityIdentifier("conversation.search.palette.field")

            if store.isSearchingContent {
                ProgressView().controlSize(.small)
            } else if !store.listQuery.isEmpty {
                Button { store.updateListQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appLanguage.localized("清空搜索"))
            }
        }
        .padding(.horizontal, Space.xl)
        .frame(height: 60)
    }

    @ViewBuilder private var content: some View {
        if store.listQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CCEmptyState(
                symbol: "magnifyingglass",
                title: appLanguage.localized("搜索全部会话"),
                message: appLanguage.localized("输入几个词，跨全部代理和项目查找。"),
                compact: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: Self.quietHeight)
        } else if results.isEmpty {
            CCEmptyState(
                symbol: "questionmark.circle",
                title: appLanguage.localized("没有匹配的会话"),
                message: store.contentSearchError.map { appLanguage.localized($0) }
                    ?? appLanguage.localized("换个说法，或删掉几个词再试。"),
                showsProgress: store.isSearchingContent,
                compact: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: Self.quietHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.conversationListIdentity) { index, session in
                            row(session, index: index)
                                .id(index)
                        }
                    }
                    .padding(Space.sm)
                }
                .frame(height: Self.resultsHeight)
                .onChange(of: highlighted) { index in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func row(_ session: HistorySessionMetadata, index: Int) -> some View {
        let hit = store.contentHit(for: session)
        let selected = index == highlighted
        return Button {
            open(session)
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                AgentBrandMark(source: session.source, size: 15)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(session.title.isEmpty ? appLanguage.localized("无标题") : session.title)
                        .font(.ccBody(.medium))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                    HStack(spacing: Space.xs + 2) {
                        Text(ConversationPresentation.projectName(session.project, language: appLanguage))
                        Text(verbatim: "·")
                        Text(ConversationPresentation.relativeDate(session.lastActivity, language: appLanguage))
                        Spacer(minLength: 0)
                    }
                    .font(.ccLabel())
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    if let hit, !hit.snippet.isEmpty {
                        ConversationPlainHighlightedText(value: hit.snippet, query: store.listQuery)
                            .font(.ccCaption())
                            .foregroundStyle(Theme.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation.search.result.\(index)")
    }

    private var footer: some View {
        HStack(spacing: Space.sm) {
            Text(appLanguage.localized("搜索范围：全部会话"))
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
            Spacer(minLength: Space.sm)
            CCKeyBadge(keys: "↑↓")
            CCKeyBadge(keys: "↩")
            CCKeyBadge(keys: "esc")
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 36)
    }

    // MARK: - Keyboard

    /// The deployment target predates `onKeyPress`, and a focused text field swallows arrow keys
    /// before a `keyboardShortcut` would ever see them. A local monitor lets the field keep first
    /// responder — so typing still works — while the list is driven from the keyboard.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: moveHighlight(by: -1); return nil   // up
            case 125: moveHighlight(by: 1); return nil    // down
            case 36, 76: openHighlighted(); return nil    // return, enter
            case 53: dismiss(); return nil                // escape
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func moveHighlight(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = min(max(0, highlighted + offset), count - 1)
    }

    func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        open(results[highlighted])
    }

    private func open(_ session: HistorySessionMetadata) {
        Task { await store.select(session, searchHit: store.contentHit(for: session)) }
        dismiss()
    }
}
