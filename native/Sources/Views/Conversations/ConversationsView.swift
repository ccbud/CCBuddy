import SwiftUI

struct ConversationsView: View {
    @ObservedObject var store: ConversationStore
    var fontSize: Int?
    var historyDirectories: [String] = []
    var selectHistoryScope: (String) -> Void = { _ in }

    @State private var listCollapsed = false
    @State private var overviewCollapsed = false
    @State private var leftWidth: CGFloat = 248
    @State private var rightWidth: CGFloat = 220
    @State private var leftDragOrigin: CGFloat?
    @State private var rightDragOrigin: CGFloat?
    @State private var isDropTarget = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ConversationListPane(
                    store: store,
                    collapsed: listCollapsed,
                    toggleCollapsed: { listCollapsed.toggle() },
                    historyDirectories: historyDirectories,
                    selectHistoryScope: selectHistoryScope
                )
                .frame(width: listCollapsed ? 34 : leftWidth)

                if !listCollapsed {
                    resizeHandle(identifier: "conversation.resize.left") { translation, began in
                        if began { leftDragOrigin = leftWidth }
                        let origin = leftDragOrigin ?? leftWidth
                        let rightRail = store.selectedMetadata == nil ? 0 : (overviewCollapsed ? 34 : rightWidth)
                        let maximum = max(200, geometry.size.width - rightRail - 330)
                        leftWidth = min(maximum, max(200, origin + translation))
                    } ended: {
                        leftDragOrigin = nil
                    }
                }

                ConversationTimelinePane(store: store, fontSize: fontSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if store.selectedMetadata != nil {
                    if !overviewCollapsed {
                        resizeHandle(identifier: "conversation.resize.right") { translation, began in
                            if began { rightDragOrigin = rightWidth }
                            let origin = rightDragOrigin ?? rightWidth
                            let leftRail = listCollapsed ? 34 : leftWidth
                            let maximum = max(180, geometry.size.width - leftRail - 330)
                            rightWidth = min(maximum, max(180, origin - translation))
                        } ended: {
                            rightDragOrigin = nil
                        }
                    }

                    ConversationOverviewPane(
                        store: store,
                        collapsed: overviewCollapsed,
                        toggleCollapsed: { overviewCollapsed.toggle() }
                    )
                    .frame(width: overviewCollapsed ? 34 : rightWidth)
                }
            }
        }
        .background(Color.ccElevated)
        .overlay(alignment: .bottom) {
            if let message = store.actionMessage {
                ConversationNotice(
                    message: message,
                    isError: store.actionIsError,
                    dismiss: store.clearActionMessage
                )
                .padding(.bottom, 18)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.ccBrand, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.ccBrandSoft.opacity(0.72))
                    .overlay {
                        Label("松开以导入 JSONL / ZIP", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.ccBrandStrong)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { files, _ in
            let accepted = files.filter { ["jsonl", "zip"].contains($0.pathExtension.lowercased()) }
            guard !accepted.isEmpty else {
                store.reportActionError("仅支持导入 JSONL 或 ZIP")
                return false
            }
            Task { await store.importFiles(accepted) }
            return true
        } isTargeted: {
            isDropTarget = $0
        }
        .onAppear {
            store.requestHistoryScope = selectHistoryScope
            store.activate()
        }
        .onDisappear {
            store.requestHistoryScope = nil
            store.deactivate()
        }
        .conversationAccessibilityContainerIdentifier("conversations.view", label: "会话")
    }

    private func resizeHandle(
        identifier: String,
        changed: @escaping (_ translation: CGFloat, _ began: Bool) -> Void,
        ended: @escaping () -> Void
    ) -> some View {
        ConversationResizeHandle(identifier: identifier, changed: changed, ended: ended)
            .frame(width: 5)
    }
}

private struct ConversationResizeHandle: View {
    let identifier: String
    let changed: (_ translation: CGFloat, _ began: Bool) -> Void
    let ended: () -> Void

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                Capsule()
                    .fill(dragging || hovering ? Color.ccBrand : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let began = !dragging
                        dragging = true
                        changed(value.translation.width, began)
                    }
                    .onEnded { _ in
                        dragging = false
                        ended()
                    }
            )
            .accessibilityLabel("调整面板宽度")
            .accessibilityIdentifier(identifier)
    }
}

private struct ConversationNotice: View {
    @Environment(\.appLanguage) private var appLanguage

    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(appLanguage.localized(message)).lineLimit(2)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isError ? Color.white : Color.ccElevated)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isError ? Color.ccRed : Color.ccForeground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .accessibilityIdentifier("conversation.notice")
    }
}
