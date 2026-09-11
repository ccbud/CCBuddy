import XCTest

@testable import CCBuddy

/// The bound is the whole point: these caches front work that is cheap to redo, and before this
/// they grew for the life of the process. A library with tens of thousands of sessions turned
/// "remember everything we ever parsed" into hundreds of megabytes the app never handed back,
/// which is what made a big history first slow the app and then the machine.
final class BoundedMemoryCacheTests: XCTestCase {
    func testTheLeastRecentlyUsedEntryIsTheOneEvicted() {
        var cache = BoundedMemoryCache<String, String>(costLimit: 100)
        cache.setValue("a", forKey: "a", cost: 40)
        cache.setValue("b", forKey: "b", cost: 40)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalCost, 80)

        XCTAssertEqual(cache.value(forKey: "a"), "a")
        cache.setValue("c", forKey: "c", cost: 40)

        XCTAssertEqual(cache.peek(forKey: "a"), "a", "a was used most recently")
        XCTAssertNil(cache.peek(forKey: "b"), "b was the least recently used")
        XCTAssertEqual(cache.peek(forKey: "c"), "c")
        XCTAssertLessThanOrEqual(cache.totalCost, cache.costLimit)
    }

    func testPeekDoesNotCountAsUse() {
        var cache = BoundedMemoryCache<String, Int>(costLimit: 20)
        cache.setValue(1, forKey: "a", cost: 10)
        cache.setValue(2, forKey: "b", cost: 10)
        _ = cache.peek(forKey: "a")
        cache.setValue(3, forKey: "c", cost: 10)
        XCTAssertNil(cache.peek(forKey: "a"), "peeking is bookkeeping, not use")
    }

    func testAnEntryLargerThanTheBudgetIsRefusedRatherThanEmptyingTheCache() {
        var cache = BoundedMemoryCache<String, String>(costLimit: 100)
        cache.setValue("a", forKey: "a", cost: 40)
        cache.setValue("b", forKey: "b", cost: 40)
        cache.setValue("huge", forKey: "huge", cost: 500)
        XCTAssertNil(cache.peek(forKey: "huge"))
        XCTAssertEqual(cache.count, 2, "one oversized value must not evict everything else")
    }

    func testCountIsBoundedEvenWhenEveryEntryIsTiny() {
        var cache = BoundedMemoryCache<Int, Int>(costLimit: 1_000_000, countLimit: 3)
        for value in 0..<10 { cache.setValue(value, forKey: value, cost: 1) }
        XCTAssertEqual(cache.count, 3)
        XCTAssertNotNil(cache.peek(forKey: 9))
        XCTAssertNil(cache.peek(forKey: 0))
    }

    func testShrinkingUnderPressureKeepsTheMostRecentEntries() {
        var cache = BoundedMemoryCache<Int, Int>(costLimit: 100)
        for value in 0..<10 { cache.setValue(value, forKey: value, cost: 10) }
        XCTAssertEqual(cache.totalCost, 100)

        cache.shrink(toFraction: 0.25)

        XCTAssertLessThanOrEqual(cache.totalCost, 25)
        XCTAssertNotNil(cache.peek(forKey: 9))
        XCTAssertNil(cache.peek(forKey: 0))
    }

    func testEntriesCanBeDroppedToFollowAnAuthoritativeList() {
        var cache = BoundedMemoryCache<String, Int>(costLimit: 100)
        cache.setValue(1, forKey: "kept", cost: 1)
        cache.setValue(2, forKey: "gone", cost: 1)
        cache.removeAll { $0 == "gone" }
        XCTAssertEqual(cache.peek(forKey: "kept"), 1)
        XCTAssertNil(cache.peek(forKey: "gone"))
        XCTAssertEqual(cache.totalCost, 1, "removal must return the entry's budget")
    }

    func testReplacingAnEntryDoesNotLeakItsOldCost() {
        var cache = BoundedMemoryCache<String, Int>(costLimit: 100)
        cache.setValue(1, forKey: "a", cost: 50)
        cache.setValue(2, forKey: "a", cost: 10)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalCost, 10)
        XCTAssertEqual(cache.peek(forKey: "a"), 2)
    }

    func testRemovingEverythingResetsTheBudget() {
        var cache = BoundedMemoryCache<String, Int>(costLimit: 100)
        cache.setValue(1, forKey: "a", cost: 50)
        cache.removeAll()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.totalCost, 0)
    }

    /// Eviction is amortised: a full cache sheds a batch rather than one entry per insert, so a
    /// walk over a whole library does not pay for recency ordering on every single insert.
    func testAFullCacheShedsABatchRatherThanOneEntryPerInsert() {
        var cache = BoundedMemoryCache<Int, Int>(costLimit: 1_000)
        for value in 0..<100 { cache.setValue(value, forKey: value, cost: 10) }
        XCTAssertEqual(cache.totalCost, 1_000)

        cache.setValue(100, forKey: 100, cost: 10)

        XCTAssertLessThanOrEqual(cache.totalCost, 900, "one insert must shed down to the mark")
        XCTAssertNotNil(cache.peek(forKey: 100))
        XCTAssertNil(cache.peek(forKey: 0), "the oldest entries go first")
    }

    /// A cache small enough that a tenth rounds to nothing must still hold exactly its limit.
    func testASmallCountLimitIsStillExact() {
        var cache = BoundedMemoryCache<Int, Int>(costLimit: 1_000_000, countLimit: 3)
        for value in 0..<10 { cache.setValue(value, forKey: value, cost: 1) }
        XCTAssertEqual(cache.count, 3)
    }
}
