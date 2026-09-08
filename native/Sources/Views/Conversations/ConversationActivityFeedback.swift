import SwiftUI

/// Describes work the store actually reports. No elapsed-time guesses, simulated stages or
/// percentages: an exact prefix is useful before the rest of the search has finished.
enum ConversationActivityStage: Equatable {
    case openingSession
    case searchingMessages
    case preparingSearch
    case refiningSearch

    static func searchStage(for phase: ConversationSearchProgress.Phase?) -> Self? {
        switch phase {
        case .completed: return nil
        case .refiningResults: return .refiningSearch
        case .preparingCandidates, nil: return .preparingSearch
        }
    }

    var titleKey: String {
        switch self {
        case .openingSession: return "正在读取会话…"
        case .searchingMessages: return "正在搜索消息内容…"
        case .preparingSearch: return "正在查找候选会话…"
        case .refiningSearch: return "正在核对匹配内容…"
        }
    }

    func messageKey(hasVerifiedResults: Bool = false) -> String {
        switch self {
        case .openingSession:
            return "正在本机整理消息与工具记录，可随时切换其他会话。"
        case .searchingMessages:
            return "可继续输入或清空搜索。"
        case .preparingSearch, .refiningSearch:
            return hasVerifiedResults
                ? "已找到的结果可先打开，也可继续输入。"
                : "可继续输入或清空搜索。"
        }
    }
}

/// The native indeterminate indicator animates itself. This view has no timer or changing state,
/// and never observes ConversationStore, so motion cannot invalidate a long transcript per frame.
struct ConversationActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var controlSize: ControlSize = .small

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(controlSize)
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct ConversationActivityFeedback: View {
    let stage: ConversationActivityStage
    var prominent = false
    var hasVerifiedResults = false
    @Environment(\.appLanguage) private var language

    var body: some View {
        Group {
            if prominent {
                VStack(spacing: Space.lg) {
                    ConversationActivityIndicator(controlSize: .regular)
                        .frame(width: 56, height: 56)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.panel))
                        .accessibilityHidden(true)
                    VStack(spacing: Space.sm) {
                        Text(language.localized(stage.titleKey))
                            .font(.ccHeading(.medium))
                            .foregroundStyle(Theme.foreground)
                        explanation
                    }
                    .multilineTextAlignment(.center)
                }
            } else {
                HStack(alignment: .top, spacing: Space.sm) {
                    ConversationActivityIndicator()
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(language.localized(stage.titleKey))
                            .font(.ccCaption(.medium))
                            .foregroundStyle(Theme.foreground)
                        explanation
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var explanation: some View {
        Text(language.localized(stage.messageKey(hasVerifiedResults: hasVerifiedResults)))
            .font(.ccCaption())
            .foregroundStyle(Theme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The caller controls visibility with isSearchingContent. Passing only snapshots keeps this
/// lightweight feedback independent of the search worker and the transcript's observation graph.
struct ConversationSearchActivityFeedback: View {
    let phase: ConversationSearchProgress.Phase?
    var hasVerifiedResults = false

    var body: some View {
        if let stage = ConversationActivityStage.searchStage(for: phase) {
            ConversationActivityFeedback(stage: stage, hasVerifiedResults: hasVerifiedResults)
                .accessibilityIdentifier("conversation.search.activity")
        }
    }
}
