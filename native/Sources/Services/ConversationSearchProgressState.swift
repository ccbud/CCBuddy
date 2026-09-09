import Foundation

/// Serial repository callbacks are assigned an ordinal before hopping to the main actor.
/// Snapshot revisions describe data identity, not callback delivery order.
final class ConversationSearchProgressSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var ordinal: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock { ordinal += 1; return ordinal }
    }
}

struct ConversationSearchProgressState {
    private(set) var hits: [HistorySearchHit] = []
    private(set) var phase: ConversationSearchProgress.Phase = .preparingCandidates
    private(set) var snapshotRevision: Int64?
    private var lastOrdinal: UInt64 = 0

    @discardableResult
    mutating func receive(_ progress: ConversationSearchProgress, ordinal: UInt64) -> Bool {
        guard ordinal > lastOrdinal else { return false }
        lastOrdinal = ordinal
        if let revision = progress.snapshotRevision, revision != snapshotRevision {
            snapshotRevision = revision
            hits = []
            phase = .preparingCandidates
        }
        // A completed callback is advisory; the Store only finishes after the final API returns.
        guard progress.phase != .completed else { return false }
        if Self.stageOrder(progress.phase) >= Self.stageOrder(phase) { phase = progress.phase }
        let sharedCount = min(hits.count, progress.hits.count)
        guard zip(hits.prefix(sharedCount), progress.hits.prefix(sharedCount)).allSatisfy({ old, new in
            old.id == new.id && old.sequence == new.sequence && old.snippet == new.snippet
        }) else { return true }
        for index in 0..<sharedCount {
            let new = progress.hits[index]
            guard !hits[index].isCountComplete, new.count >= hits[index].count else { continue }
            hits[index].count = new.count
            hits[index].isCountComplete = new.isCountComplete
        }
        if progress.hits.count > hits.count {
            let additional = progress.hits.dropFirst(hits.count)
            guard additional.allSatisfy({ $0.count > 0 }) else { return true }
            hits.append(contentsOf: additional)
        }
        return true
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
