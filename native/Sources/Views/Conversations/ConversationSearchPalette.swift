import AppKit
import SwiftUI

/// A keyboard-first search layer. Recent sessions make the empty query immediately useful;
/// live engine diagnostics and optional local semantic ranking share the store's search path.
struct ConversationSearchPalette: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let focusSession: ConversationSearchFocusSession
    let dismiss: (_ restoringFocus: Bool) -> Void

    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @State private var highlightedFile: String?
    @State private var windowNumber: Int?

    private static let width: CGFloat = 720
    private static let topInset: CGFloat = 56
    private static let quietHeight: CGFloat = 250
    private static let resultsHeight: CGFloat = 380

    private var results: [HistorySessionMetadata] {
        let sessions = store.orderedSearchSessions
        return store.listQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Array(sessions.prefix(6)) : sessions
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.20)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(true) }
                    .accessibilityHidden(true)

                panel
                    .frame(width: min(Self.width, max(320, geometry.size.width - 48)))
                    .frame(maxHeight: geometry.size.height - Self.topInset - Space.xxl)
                    .padding(.top, Self.topInset)
            }
        }
        .onAppear {
            windowNumber = NSApp.keyWindow?.windowNumber
            installKeyMonitor()
        }
        .onChange(of: results.map { ConversationFilter.fileKey($0.file) }) { files in
            if let highlightedFile, let index = files.firstIndex(of: highlightedFile) {
                highlighted = index
            } else {
                highlighted = min(highlighted, max(0, files.count - 1))
            }
        }
        .onDisappear(perform: removeKeyMonitor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.search.palette")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            SearchPerformanceView(store: store)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
            HStack {
                Text(appLanguage.localized(store.listQuery.isEmpty ? "最近会话" : "会话结果"))
                    .font(.ccLabel(.semibold))
                    .tracking(0.7)
                Spacer()
                if !store.listQuery.isEmpty {
                    Text("\(store.filteredSessionCount)")
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.sm)
            if !results.isEmpty, let error = store.contentSearchError {
                Label(appLanguage.localized("搜索未完成，当前显示部分结果。"), systemImage: "exclamationmark.triangle")
                    .font(.ccCaption())
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.sm)
                    .help(appLanguage.localized(error))
                    .accessibilityIdentifier("conversation.search.partial.error")
            }
            content.layoutPriority(-1)
            Rectangle().fill(Theme.separator).frame(height: 1)
            footer
        }
        .floatingSurface(radius: 26)
    }

    private var field: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Typography.title, weight: .medium))
                .foregroundStyle(Theme.accentText)
            ConversationPaletteSearchField(
                placeholder: appLanguage.localized("搜索全部会话"),
                text: Binding(
                    get: { store.listQuery },
                    set: { value in
                        store.updateListQuery(value)
                        highlighted = 0
                        highlightedFile = nil
                    }
                ),
                focusSession: focusSession,
                onSubmit: openHighlighted
            )

            if store.isSearchingContent || store.isRankingSearch {
                ProgressView().controlSize(.small)
            }
            if !store.listQuery.isEmpty {
                Button { store.updateListQuery("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appLanguage.localized("清空搜索"))
                .accessibilityIdentifier("conversation.search.clear")
            }
        }
        .padding(.horizontal, Space.xxl)
        .frame(height: 76)
    }

    @ViewBuilder private var content: some View {
        if store.listQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && results.isEmpty {
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
                symbol: store.isSearchingContent ? "magnifyingglass" : "questionmark.circle",
                title: appLanguage.localized(store.isSearchingContent ? "正在搜索会话内容…" : "没有匹配的会话"),
                message: store.isSearchingContent ? appLanguage.localized("可继续输入或清空搜索。")
                    : store.contentSearchError.map { appLanguage.localized($0) }
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
                .frame(minHeight: 120, maxHeight: Self.resultsHeight)
                .onChange(of: highlighted) { index in
                    withAnimation(reduceMotion ? nil : CCMotion.feedback) { proxy.scrollTo(index, anchor: .center) }
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
                AgentBrandMark(source: session.source, size: 22)
                    .frame(width: 36, height: 36)
                    .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: Radius.button))
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(session.title.isEmpty ? appLanguage.localized("无标题") : session.title)
                        .font(.ccBody(.semibold))
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
                if selected {
                    Image(systemName: "return")
                        .font(.ccCaption(.medium))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 24, height: 28)
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
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("conversation.search.result.\(index)")
    }

    private var footer: some View {
        HStack(spacing: Space.sm) {
            Label(appLanguage.localized("搜索范围：全部会话"), systemImage: "lock.shield")
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
            Spacer(minLength: Space.sm)
            CCKeyBadge(keys: "↑↓")
            Text(appLanguage.localized("选择")).font(.ccLabel())
            CCKeyBadge(keys: "↩")
            Text(appLanguage.localized("打开")).font(.ccLabel())
            CCKeyBadge(keys: "esc")
        }
        .padding(.horizontal, Space.lg)
        .foregroundStyle(Theme.mutedForeground)
        .frame(height: 42)
    }

    // MARK: - Keyboard

    /// The deployment target predates `onKeyPress`, and a focused text field swallows arrow keys
    /// before a `keyboardShortcut` would ever see them. A local monitor lets the field keep first
    /// responder — so typing still works — while the list is driven from the keyboard.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focusSession.isPresented,
                  event.window?.windowNumber == windowNumber else { return event }
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                focusSession.focusSearch()
                return nil
            }
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true
            else { return event }
            switch event.keyCode {
            case 126: moveHighlight(by: -1); return nil   // up
            case 125: moveHighlight(by: 1); return nil    // down
            case 116: moveHighlight(by: -8); return nil   // page up
            case 121: moveHighlight(by: 8); return nil    // page down
            case 36, 76: openHighlighted(); return nil    // return, enter
            case 53: dismiss(true); return nil            // escape
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
        highlightedFile = ConversationFilter.fileKey(results[highlighted].file)
    }

    func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        open(results[highlighted])
    }

    private func open(_ session: HistorySessionMetadata) {
        Task { await store.select(session, searchHit: store.contentHit(for: session)) }
        dismiss(false)
    }
}

/// An overlay is not a separate AppKit focus scope. Claim the real field editor only after the
/// palette's control belongs to its window, and remember the control (not the shared field editor)
/// so Escape returns to the prior insertion point without sending text into the hidden layer.
@MainActor
final class ConversationSearchFocusSession: ObservableObject {
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private weak var searchField: NSTextField?
    private var previousSelection: NSRange?
    private var presented = false
    private var presentationID = UUID()
    var isPresented: Bool { presented }

    func begin(in window: NSWindow?) {
        self.window = window
        presented = true
        presentationID = UUID()
        previousSelection = nil
        if let editor = window?.firstResponder as? NSTextView,
           editor.isFieldEditor, let control = editor.delegate as? NSControl {
            previousResponder = control
            previousSelection = editor.selectedRange()
        } else {
            previousResponder = window?.firstResponder
        }
    }

    func attach(_ field: NSTextField) {
        guard presented, searchField !== field, let window = field.window else { return }
        self.window = window
        searchField = field
        window.makeFirstResponder(field)
        field.selectText(nil)
        // SwiftUI may reconcile an older FocusState in this same mounting pass. Reassert after
        // that pass, without a timer or waiting for the visual entrance transition to finish.
        DispatchQueue.main.async { [weak self, weak field, weak window] in
            guard let self, let field, let window, self.presented,
                  self.searchField === field, field.window === window else { return }
            self.claim(field, in: window)
        }
    }

    func end(restoringFocus: Bool) {
        guard presented else { return }
        presented = false
        searchField = nil
        let selection = previousSelection
        let completedPresentation = presentationID
        defer {
            previousResponder = nil
            previousSelection = nil
        }
        guard let window else { return }
        window.makeFirstResponder(window.contentView)
        guard restoringFocus, let previousResponder else { return }
        // Wait for SwiftUI to remove .disabled from the covered workspace, not for the exit
        // animation. An older dismissal must never steal focus from a newer presentation.
        DispatchQueue.main.async { [weak self, weak window, weak previousResponder] in
            guard let self, let window, let previousResponder, !self.presented,
                  self.presentationID == completedPresentation,
                  (previousResponder as? NSView).map({ $0.window === window }) ?? true,
                  window.makeFirstResponder(previousResponder) else { return }
            if let selection, let control = previousResponder as? NSControl,
               let editor = control.currentEditor() as? NSTextView {
                let location = min(selection.location, editor.string.utf16.count)
                editor.setSelectedRange(NSRange(location: location,
                    length: min(selection.length, editor.string.utf16.count - location)))
            }
        }
    }

    func focusSearch() {
        guard presented, let field = searchField, let window = field.window else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func claim(_ field: NSTextField, in window: NSWindow) {
        if field.currentEditor() !== window.firstResponder {
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }
}

private struct ConversationPaletteSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let focusSession: ConversationSearchFocusSession
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.focusSession = focusSession
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Typography.title, weight: .medium)
        field.textColor = .labelColor
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("conversation.search.palette.field")
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
        // Also covers a rapid close/reopen whose outgoing transition reuses the native control.
        focusSession.attach(field)
    }

    final class Field: NSTextField {
        weak var focusSession: ConversationSearchFocusSession?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusSession?.attach(self)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConversationPaletteSearchField

        init(_ parent: ConversationPaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
