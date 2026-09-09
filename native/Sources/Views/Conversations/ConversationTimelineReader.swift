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
/// header focus changes must not rebuild a ForEach spanning tens of thousands of messages.
/// The ordinary Store reference is used only by actions to validate the current navigation intent.
struct ConversationTimelineReader: View, Equatable {
    let messages: [HistoryMessage]
    let inputs: ConversationTimelineReaderInputs
    let store: ConversationStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.inputs == rhs.inputs
    }

    var body: some View {
        let projection = inputs.projection
        let layoutRequest = inputs.layoutRequest

        return ScrollViewReader { proxy in
            let layoutObserver = ConversationScrollLayoutObserver(request: layoutRequest) { request in
                guard store.scrollLayoutRequest == request else { return }
                // Correct the still-active row's asynchronous height without replaying navigation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(request.scrollID, anchor: request.anchor)
                }
            }

            // Keep the complete projected transcript and the existing single ForEach identity.
            List {
                ForEach(projection.visibleMessageIndices, id: \.self) { index in
                    let anchor = ConversationPresentation.messageAnchor(index)
                    ConversationMessageView(
                        message: messages[index],
                        messageIndex: index,
                        sourceRawValue: inputs.sourceRawValue,
                        projection: projection,
                        searchQuery: inputs.query,
                        isCurrentSearchMatch: inputs.currentMatch == index,
                        fontSize: inputs.fontSize
                    )
                    .padding(.horizontal, Space.xl)
                    .padding(.top, index == projection.visibleMessageIndices.first ? Space.xxl : 0)
                    .padding(.bottom, Space.xxl)
                    .frame(maxWidth: Metrics.readingMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // The active native row supplies its scroll-view scope without nesting
                        // another scroll view inside the reader.
                        if layoutRequest?.anchorID == anchor { layoutObserver.accessibilityHidden(true) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("conversation.message.\(index)")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Color.clear.frame(height: 68)
                    .background {
                        if layoutRequest == nil || layoutRequest?.anchorID == ConversationPresentation.bottomAnchor {
                            layoutObserver.accessibilityHidden(true)
                        }
                    }
                    .id(ConversationPresentation.bottomAnchor)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .background(ConversationScrollInputObserver(scope: inputs.scope) { scope in
                guard store.activeTranscriptFile == scope.file,
                      store.activeTranscriptID == scope.transcriptID else { return }
                store.pauseFollowingLatestFromUserScroll()
            }.accessibilityHidden(true))
            .onAppear {
                if let request = store.scrollLayoutRequest {
                    proxy.scrollTo(request.scrollID, anchor: request.anchor)
                }
            }
            .onChange(of: inputs.jumpLayoutRequest) { request in
                guard let request, store.scrollLayoutRequest == request else { return }
                scroll(proxy, to: request.scrollID, anchor: request.anchor)
            }
            .onChange(of: inputs.followLatestRevision) { _ in
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

    private func scroll(_ proxy: ScrollViewProxy, to id: AnyHashable, anchor: UnitPoint) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: anchor)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: anchor) }
        }
    }
}
