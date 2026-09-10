import SwiftUI

/// Lazy rows need the complete rendering input as their ForEach value. Reading a hit from
/// a store captured by an unchanged metadata-only row closure can leave an already mounted
/// row displaying its first lower bound even after the store has published final counts.
/// Identity stays file-based; count, snippet, query, selection and language are value changes.
struct ConversationSearchRowSnapshot: Equatable, Identifiable {
    let metadata: HistorySessionMetadata
    let hit: HistorySearchHit?
    let query: String
    let selected: Bool
    let language: AppLanguage
    let index: Int

    var id: String { metadata.conversationListIdentity }

    static func make(sessions: [HistorySessionMetadata], hits: [String: HistorySearchHit],
                     query: String, selectedID: String?, language: AppLanguage) -> [Self] {
        sessions.enumerated().map { index, session in
            let id = session.conversationListIdentity
            return Self(metadata: session, hit: hits[id], query: query,
                selected: id == selectedID, language: language, index: index)
        }
    }
}

enum ConversationSearchCountPresentation {
    static func label(for hit: HistorySearchHit, language: AppLanguage) -> String {
        language.localized(hit.isCountComplete ? "\(hit.count) 处匹配" : "至少 \(hit.count) 处匹配")
    }

    static func explanation(for hit: HistorySearchHit, language: AppLanguage) -> String {
        language.localized(hit.isCountComplete ? "匹配次数统计完成。" : "已确认匹配，完整次数尚未统计完成。")
    }
}

struct ConversationSearchCountLabel: View {
    let hit: HistorySearchHit
    @Environment(\.appLanguage) private var language

    var body: some View {
        Text(ConversationSearchCountPresentation.label(for: hit, language: language))
            .font(.ccLabel())
            .monospacedDigit()
            .fixedSize()
            .help(ConversationSearchCountPresentation.explanation(for: hit, language: language))
    }
}

/// Counts are not selection identity. Preserve the chosen file through count refinements,
/// appended results and semantic reorderings; reset only for new user input or a removed result.
struct ConversationSearchSelection {
    private(set) var index = 0
    private(set) var file: String?

    mutating func reset() { index = 0; file = nil }

    mutating func reconcile(files: [String]) {
        if let file, let position = files.firstIndex(of: file) {
            index = position
        } else {
            index = min(index, max(0, files.count - 1))
            file = files.indices.contains(index) ? files[index] : nil
        }
    }

    mutating func move(by offset: Int, files: [String]) {
        guard !files.isEmpty else { return }
        index = min(max(0, index + offset), files.count - 1)
        file = files[index]
    }
}
