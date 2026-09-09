import SwiftUI

/// Only inputs that change transcript presentation or navigation belong in this snapshot.
/// Projection identity is the content revision, just as it is for ConversationBlockRenderVersion;
/// comparing a session, its messages or its tool-result dictionary would walk the whole log.
struct ConversationTimelineReaderInputs: Equatable {
    var projection: ConversationStore.TranscriptProjection
    var scope: ConversationScrollInputScope
    var sourceRawValue: String
    var query: String
    var currentMatch: Int?
    var fontSize: CGFloat
    var layoutRequest: ConversationScrollLayoutRequest?
    var jumpLayoutRequest: ConversationScrollLayoutRequest?
    var isFollowingLatest: Bool
    var followLatestRevision: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projection === rhs.projection
            && lhs.scope == rhs.scope
            && lhs.sourceRawValue == rhs.sourceRawValue
            && lhs.query == rhs.query
            && lhs.currentMatch == rhs.currentMatch
            && lhs.fontSize == rhs.fontSize
            && lhs.layoutRequest == rhs.layoutRequest
            && lhs.jumpLayoutRequest == rhs.jumpLayoutRequest
            && lhs.isFollowingLatest == rhs.isFollowingLatest
            && lhs.followLatestRevision == rhs.followLatestRevision
    }
}

/// The shell observes the Store; the reader deliberately does not. Search progress, metadata and
/// header focus changes cannot rebuild a transcript-sized view tree. Only the native viewport's
/// available rows host message views, while every source row remains accessible and navigable.
struct ConversationTimelineReader: View, Equatable {
    let messages: [HistoryMessage]
    let inputs: ConversationTimelineReaderInputs
    let store: ConversationStore

    @Environment(\.appLanguage) private var appLanguage

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.inputs == rhs.inputs
    }

    var body: some View {
        ConversationNativeTimelineView(messages: messages, inputs: inputs, store: store)
            .background(ConversationScrollInputObserver(scope: inputs.scope) { scope in
                guard store.activeTranscriptFile == scope.file,
                      store.activeTranscriptID == scope.transcriptID else { return }
                store.pauseFollowingLatestFromUserScroll()
            }.accessibilityHidden(true))
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.md)
    }
}
