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

/// Optional progressive exact search. Plain providers retain the original final-result API.
/// Callbacks are synchronous, serial, and finish before this method returns or throws.
/// They run on the caller's worker, never while holding a catalog database lock.
protocol ConversationProgressiveHistoryProviding: ConversationHistoryProviding {
    func search(
        query: String,
        limit: Int,
        onProgress: @Sendable (ConversationSearchProgress) -> Void
    ) throws -> [HistorySearchHit]
}

struct ConversationSearchProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Includes catalog snapshot/candidate preparation, a cold index build,
        /// or an exact fallback scan; it does not imply a percentage of completion.
        case preparingCandidates
        case refiningResults
        case completed
    }

    var phase: Phase
    /// An activity-ordered prefix of the final results. Each hit already has its
    /// complete occurrence count, exact transcript/message anchor, and snippet.
    var hits: [HistorySearchHit]
    /// Candidate preparation measurements are available once refinement begins.
    var diagnostics: ConversationSearchDiagnostics? = nil
}

struct ConversationScopeSnapshot: Equatable, Sendable {
    var sessionCounts: [String: Int] = [:]
    var trashCount = 0
    var isAuthoritative = false

    var importedCount: Int { sessionCounts["__imported__", default: 0] }
}
