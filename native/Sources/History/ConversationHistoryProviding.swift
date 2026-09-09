import Foundation

/// Read-only history contract shared by the native store and catalog tools.
protocol ConversationHistoryProviding: Sendable {
    func listProjects(limit: Int) throws -> [HistoryProject]
    /// Returns only finished exact results; every hit has isCountComplete == true.
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
/// They run on the caller's worker, never while holding a catalog publication lock.
protocol ConversationProgressiveHistoryProviding: ConversationHistoryProviding {
    func search(
        query: String,
        limit: Int,
        onProgress: @Sendable (ConversationSearchProgress) -> Void
    ) throws -> [HistorySearchHit]
}

struct ConversationSearchProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Catalog snapshot/candidate preparation only. Background index construction is
        /// independent; this phase does not imply a percentage of completion.
        case preparingCandidates
        /// Candidate verification may publish a first exact match before its total is counted.
        case refiningResults
        /// Candidate verification is finished; only exact occurrence totals remain in progress.
        case countingOccurrences
        /// Every returned occurrence count is complete. No later callback is allowed.
        case completed
    }

    var phase: Phase
    /// A cumulative activity-ordered set of verified result identities. Each hit already has
    /// an exact transcript/message anchor and snippet and can be opened immediately. Its count is
    /// a verified lower bound until isCountComplete becomes true. Later snapshots can update
    /// counts in place and insert/reorder stable identities, but never remove a hit or change its
    /// first anchor/snippet within the same snapshot attempt. Such changes explicitly retire the
    /// attempt before publishing a replacement. Complete counts cannot regress. A completed snapshot
    /// and the final return value must contain only complete counts.
    var hits: [HistorySearchHit]
    /// Candidate preparation measurements are available once refinement begins.
    var diagnostics: ConversationSearchDiagnostics? = nil
    /// Catalog snapshot used by this batch. A different non-nil revision restarts the prefix;
    /// hits from the prior revision must never be merged into this snapshot's results.
    var snapshotRevision: Int64? = nil
    /// Rebuilt file catalogs may start at the same revision; their instance identity is distinct.
    var snapshotIdentity: String? = nil
    /// A raw source may be rewritten before the catalog publishes a revision. Attempts that
    /// inspect authoritative sources need an independent identity to discard stale prefixes.
    var snapshotAttempt: UUID? = nil
}

struct ConversationScopeSnapshot: Equatable, Sendable {
    var sessionCounts: [String: Int] = [:]
    var trashCount = 0
    var isAuthoritative = false

    var importedCount: Int { sessionCounts["__imported__", default: 0] }
}
