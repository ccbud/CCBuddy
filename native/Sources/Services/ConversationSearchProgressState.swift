import Foundation

/// Serial repository callbacks are assigned an ordinal before hopping to the main actor.
/// Snapshot revisions describe data identity, not callback delivery order.
final class ConversationSearchProgressSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var ordinal: UInt64 = 0
    private var diagnostics: ConversationSearchDiagnostics?

    func next(diagnostics: ConversationSearchDiagnostics? = nil) -> UInt64 {
        lock.withLock {
            if let diagnostics { self.diagnostics = diagnostics }
            ordinal += 1
            return ordinal
        }
    }

    var latestDiagnostics: ConversationSearchDiagnostics? { lock.withLock { diagnostics } }
}

struct ConversationSearchProgressState {
    private(set) var hits: [HistorySearchHit] = []
    private(set) var phase: ConversationSearchProgress.Phase = .preparingCandidates
    private(set) var snapshotRevision: Int64?
    private(set) var snapshotIdentity: String?
    private(set) var snapshotAttempt: UUID?
    private(set) var hasRestartedSourceSnapshot = false
    private var retiredAttempts = Set<UUID>()
    private var lastOrdinal: UInt64 = 0

    @discardableResult
    mutating func receive(_ progress: ConversationSearchProgress, ordinal: UInt64) -> Bool {
        guard ordinal > lastOrdinal else { return false }
        if let attempt = progress.snapshotAttempt, retiredAttempts.contains(attempt) { return false }
        lastOrdinal = ordinal
        if (progress.snapshotRevision != nil && progress.snapshotRevision != snapshotRevision)
            || (progress.snapshotIdentity != nil && progress.snapshotIdentity != snapshotIdentity)
            || (progress.snapshotAttempt != nil && progress.snapshotAttempt != snapshotAttempt) {
            if let previous = snapshotAttempt, previous != progress.snapshotAttempt {
                retiredAttempts.insert(previous)
                hasRestartedSourceSnapshot = true
            }
            snapshotRevision = progress.snapshotRevision
            snapshotIdentity = progress.snapshotIdentity
            snapshotAttempt = progress.snapshotAttempt
            hits = []
            phase = .preparingCandidates
        }
        // A completed callback is advisory; the Store only finishes after the final API returns.
        guard progress.phase != .completed else { return false }
        if Self.stageOrder(progress.phase) >= Self.stageOrder(phase) { phase = progress.phase }
        // Hot catalog matches arrive before slower changed sources. A cumulative snapshot may
        // insert those later-verified identities anywhere in canonical order; array-prefix
        // equality would silently discard them. Counts and anchors remain monotonic per ID.
        guard progress.hits.allSatisfy({ $0.count > 0 }),
              Set(progress.hits.map(\.id)).count == progress.hits.count else { return true }
        let incoming = Dictionary(uniqueKeysWithValues: progress.hits.map { ($0.id, $0) })
        guard hits.allSatisfy({ old in
            guard let new = incoming[old.id] else { return false }
            return old.file == new.file && old.sessionID == new.sessionID && old.source == new.source
                && old.agent == new.agent && old.agentType == new.agentType
                && old.sequence == new.sequence && old.snippet == new.snippet
        }) else { return true }
        let previous = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) })
        hits = progress.hits.map { new in
            guard var old = previous[new.id] else { return new }
            // Coverage may discover child navigation after the first verified hot hit.
            // Keep that query-local metadata current without replacing its stable anchor.
            old.sourceMetadata = new.sourceMetadata
            if !old.isCountComplete, new.count >= old.count {
                old.count = new.count
                old.isCountComplete = new.isCountComplete
            }
            return old
        }
        return true
    }

    func canPublish(preservingExistingResults: Bool) -> Bool {
        !preservingExistingResults || hasRestartedSourceSnapshot
    }

    private static func stageOrder(_ phase: ConversationSearchProgress.Phase) -> Int {
        switch phase {
        case .preparingCandidates: return 0
        case .refiningResults: return 1
        case .countingOccurrences: return 2
        case .completed: return 3
        }
    }
}
