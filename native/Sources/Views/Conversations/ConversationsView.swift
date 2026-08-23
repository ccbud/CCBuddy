import SwiftUI

struct ConversationsView: View {
    @ObservedObject var store: ConversationStore
    var fontSize: Int?
    var historyDirectories: [String] = []
    var selectHistoryScope: (String) -> Void = { _ in }

    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            ConversationListPane(
                store: store,
                historyDirectories: historyDirectories,
                selectHistoryScope: selectHistoryScope
            )
            .frame(width: 336)

            ConversationTimelinePane(store: store, fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ccConversationBackground)
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
