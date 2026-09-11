import Foundation

/// A least-recently-used cache with a byte budget.
///
/// Several caches in the app were keyed by session or file path and grew for the life of the
/// process: correct, and fine for a handful of sessions, but a library with tens of thousands of
/// them turns "remember everything we ever parsed" into hundreds of megabytes that are never
/// handed back. Each of those caches fronts something cheap to recompute — a header re-read, a
/// JSON decode — so a bound costs a little latency on a miss and nothing else.
///
/// Not thread-safe on its own; every current owner already serializes access under its own lock.
struct BoundedMemoryCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var clock: UInt64
    }

    /// Byte budget across all entries. Costs are estimates, so this is a shape control rather
    /// than an exact ceiling.
    let costLimit: Int
    /// Hard ceiling on entry count, so a cache of many tiny entries cannot grow without limit
    /// either.
    let countLimit: Int

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var totalCost = 0

    init(costLimit: Int, countLimit: Int = Int.max) {
        self.costLimit = max(0, costLimit)
        self.countLimit = max(0, countLimit)
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Reads a value and marks it most-recently-used.
    mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.clock = clock
        entries[key] = entry
        return entry.value
    }

    /// Reads without disturbing recency. Used where a lookup is bookkeeping rather than use.
    func peek(forKey key: Key) -> Value? { entries[key]?.value }

    mutating func setValue(_ value: Value, forKey key: Key, cost: Int) {
        let cost = max(0, cost)
        // An entry larger than the whole budget would evict everything and then sit there alone.
        guard cost <= costLimit, countLimit > 0 else {
            removeValue(forKey: key)
            return
        }
        clock &+= 1
        if let existing = entries[key] { totalCost -= existing.cost }
        entries[key] = Entry(value: value, cost: cost, clock: clock)
        totalCost += cost
        evictIfNeeded()
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        totalCost -= entry.cost
        return entry.value
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    /// Drops every entry whose key the predicate rejects. Used to follow an authoritative list
    /// (a manifest, the set of files still on disk) rather than to reclaim memory.
    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        // Snapshot first: the loop mutates the dictionary it is reading.
        for key in Array(entries.keys) where shouldRemove(key) {
            removeValue(forKey: key)
        }
    }

    /// Sheds entries until the cache holds at most `fraction` of its budget. Used to answer
    /// system memory pressure, where giving memory back promptly matters more than hit rate.
    mutating func shrink(toFraction fraction: Double) {
        let target = Int(Double(costLimit) * max(0, min(1, fraction)))
        evict(untilCostAtMost: target, countAtMost: max(1, countLimit / 4))
    }

    /// Eviction orders entries by recency, so shedding exactly one entry per insert would pay
    /// for that ordering on every insert once the cache is full — which is precisely what a walk
    /// over a whole library does. Shedding down to a low water mark instead amortises the cost
    /// across many inserts. A cache small enough that a tenth rounds to nothing sheds only what
    /// it must, so the bound stays exact for small limits.
    private var costLowWaterMark: Int { costLimit - costLimit / 10 }
    private var countLowWaterMark: Int { countLimit - countLimit / 10 }

    private mutating func evictIfNeeded() {
        guard totalCost > costLimit || entries.count > countLimit else { return }
        evict(untilCostAtMost: costLowWaterMark, countAtMost: countLowWaterMark)
    }

    private mutating func evict(untilCostAtMost cost: Int, countAtMost count: Int) {
        guard totalCost > cost || entries.count > count else { return }
        // Sorting once beats repeatedly scanning for a minimum: eviction runs when a budget is
        // already exceeded, which in a full-library walk is every insert.
        let ordered = entries.sorted { $0.value.clock < $1.value.clock }
        var index = 0
        while (totalCost > cost || entries.count > count) && index < ordered.count {
            removeValue(forKey: ordered[index].key)
            index += 1
        }
    }
}
