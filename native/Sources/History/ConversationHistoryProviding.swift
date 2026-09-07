import Foundation

/// Read-only history contract shared by the native store and catalog tools.
protocol ConversationHistoryProviding: Sendable {
    func listProjects(limit: Int) throws -> [HistoryProject]
    func search(query: String, limit: Int) throws -> [HistorySearchHit]
    func getSession(file: URL) throws -> HistorySession
    func conversationScopeSnapshot() -> ConversationScopeSnapshot?
}

extension ConversationHistoryProviding {
    /// Lightweight fakes and embedders can omit scope statistics. The store then derives the
    /// currently visible counts, while the production repository supplies an authoritative view.
    func conversationScopeSnapshot() -> ConversationScopeSnapshot? { nil }
}

struct ConversationScopeSnapshot: Equatable, Sendable {
    var sessionCounts: [String: Int] = [:]
    var trashCount = 0
    var isAuthoritative = false

    var importedCount: Int { sessionCounts["__imported__", default: 0] }
}
