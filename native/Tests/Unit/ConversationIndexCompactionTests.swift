import XCTest

@testable import CCBuddy

/// A catalog created before incremental auto-vacuum existed cannot be switched to it in place, so
/// `incremental_vacuum` reclaims nothing there and the freelist grows without bound — a real catalog
/// held 2.4 GB of free pages inside a 3.8 GB file. The one-time VACUUM that fixes it is expensive,
/// so the decision to run it is pinned here rather than left to a bare pragma.
final class ConversationIndexCompactionTests: XCTestCase {
    private let pageSize: Int64 = 4_096

    func testVacuumsWhenMostOfALargeFileIsFreelist() {
        // The observed case: 602,411 free pages of 985,853 total.
        XCTAssertTrue(ConversationIndexDatabase.shouldVacuum(
            freelistPages: 602_411,
            pageCount: 985_853,
            pageSize: pageSize
        ))
    }

    func testSkipsVacuumWhenLittleIsReclaimable() {
        // A young catalog can be proportionally very wasteful while owning almost nothing. Rewriting
        // the whole file to recover a few megabytes is not a trade worth an exclusive writer.
        XCTAssertFalse(ConversationIndexDatabase.shouldVacuum(
            freelistPages: 900,
            pageCount: 1_000,
            pageSize: pageSize
        ))
    }

    func testSkipsVacuumWhenWasteIsAThinSliceOfALargeFile() {
        // 40 MB of freelist inside a 4 GB catalog: absolutely sizeable, proportionally noise.
        XCTAssertFalse(ConversationIndexDatabase.shouldVacuum(
            freelistPages: 10_000,
            pageCount: 1_000_000,
            pageSize: pageSize
        ))
    }

    func testRequiresBothTheRatioAndTheAbsoluteFloor() {
        let ratioOnly = ConversationIndexDatabase.shouldVacuum(
            freelistPages: 5_000,
            pageCount: 10_000,
            pageSize: pageSize
        )
        XCTAssertFalse(ratioOnly, "20 MB reclaimable is below the floor even at a 50% ratio")

        let bothSatisfied = ConversationIndexDatabase.shouldVacuum(
            freelistPages: 20_000,
            pageCount: 40_000,
            pageSize: pageSize
        )
        XCTAssertTrue(bothSatisfied, "80 MB reclaimable at a 50% ratio clears both conditions")
    }

    func testDegenerateCountsNeverTriggerARewrite() {
        XCTAssertFalse(ConversationIndexDatabase.shouldVacuum(freelistPages: 0, pageCount: 0, pageSize: 0))
        XCTAssertFalse(ConversationIndexDatabase.shouldVacuum(freelistPages: 0, pageCount: 1_000, pageSize: pageSize))
        XCTAssertFalse(ConversationIndexDatabase.shouldVacuum(freelistPages: 500, pageCount: 0, pageSize: pageSize))
    }
}
