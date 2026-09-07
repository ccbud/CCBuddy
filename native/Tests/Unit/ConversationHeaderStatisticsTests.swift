import Foundation
import XCTest
@testable import CCBuddy

final class ConversationHeaderStatisticsTests: XCTestCase {
    func testQuickCatalogRefreshCannotDowngradeLoadedTranscriptStatistics() {
        let exact = session(metadata(count: 565, input: 984_000, output: 21_000, credits: 8.5))
        let quick = metadata(count: 5, input: 11_000, output: 400, credits: 0.5)

        let result = ConversationHeaderStatistics.metadata(
            selectedMetadata: quick, loadedParent: exact, activeTranscript: exact
        )

        XCTAssertEqual(result.messageCount, exact.metadata.messageCount)
        XCTAssertEqual(result.totals, exact.metadata.totals)
    }

    func testCatalogEditsRemainAuthoritativeWhileOnlyStatisticsComeFromDetail() {
        let exact = session(metadata(count: 565, input: 984_000, output: 21_000))
        var refreshed = metadata(count: 5, input: 11_000, output: 400)
        refreshed.title = "Edited title"
        refreshed.tags = ["updated", "important"]
        refreshed.starred = true
        refreshed.pinned = true
        refreshed.lastActivity = refreshed.lastActivity.addingTimeInterval(60)
        refreshed.deleted = true
        refreshed.model = "updated-model"

        let result = ConversationHeaderStatistics.metadata(
            selectedMetadata: refreshed, loadedParent: exact, activeTranscript: exact
        )

        var expected = refreshed
        expected.messageCount = exact.metadata.messageCount
        expected.totals = exact.metadata.totals
        XCTAssertEqual(result, expected, "Only messageCount and totals may come from detail")
    }

    func testBeforeDetailLoadsStatisticsFallBackToSelectedCatalogRow() {
        let quick = metadata(count: 5, input: 11_000, output: 400)

        XCTAssertEqual(
            ConversationHeaderStatistics.metadata(
                selectedMetadata: quick, loadedParent: nil, activeTranscript: nil
            ),
            quick
        )
    }

    func testRefreshedDetailCanDecreaseStatisticsAfterActualTruncation() {
        let previous = metadata(count: 565, input: 984_000, output: 21_000, credits: 8.5)
        let truncated = session(metadata(count: 2, input: 20, output: 10, credits: 0.1))

        let result = ConversationHeaderStatistics.metadata(
            selectedMetadata: previous, loadedParent: truncated, activeTranscript: truncated
        )

        XCTAssertEqual(result.messageCount, 2)
        XCTAssertEqual(result.totals, truncated.metadata.totals)
    }

    func testStatisticsFollowMainAndChildTranscriptSelectionWithoutChangingHeaderIdentity() {
        let selected = metadata(count: 5, input: 11_000, output: 400)
        let parent = session(metadata(count: 565, input: 984_000, output: 21_000))
        let child = session(metadata(
            file: "/tmp/header-child.jsonl", count: 12, input: 2_000, output: 300, credits: 0.4
        ))

        for active in [parent, child, parent] {
            let result = ConversationHeaderStatistics.metadata(
                selectedMetadata: selected, loadedParent: parent, activeTranscript: active
            )
            XCTAssertEqual(result.messageCount, active.metadata.messageCount)
            XCTAssertEqual(result.totals, active.metadata.totals)
            XCTAssertEqual(result.file, selected.file)
            XCTAssertEqual(result.title, selected.title)
        }
    }

    func testChangedSelectionRejectsStaleDetailEvenWhenProducerSessionIDsMatch() {
        let selected = metadata(file: "/tmp/new-selection.jsonl", count: 3, input: 40, output: 20)
        let previous = session(metadata(count: 565, input: 984_000, output: 21_000))
        XCTAssertEqual(selected.sessionID, previous.metadata.sessionID)

        XCTAssertEqual(
            ConversationHeaderStatistics.metadata(
                selectedMetadata: selected, loadedParent: previous, activeTranscript: previous
            ),
            selected
        )
        XCTAssertEqual(
            ConversationHeaderStatistics.metadata(
                selectedMetadata: selected, loadedParent: nil, activeTranscript: previous
            ),
            selected,
            "An active transcript alone cannot establish ownership by the selected parent"
        )
    }

    func testMatchingNormalizedParentPathSuppliesStatisticsWithoutAnActiveProjection() {
        let selected = metadata(file: "/tmp/./header-parent.jsonl", count: 5, input: 10, output: 4)
        let parent = session(metadata(count: 565, input: 984_000, output: 21_000))

        let result = ConversationHeaderStatistics.metadata(
            selectedMetadata: selected, loadedParent: parent, activeTranscript: nil
        )

        XCTAssertEqual(result.messageCount, parent.metadata.messageCount)
        XCTAssertEqual(result.totals, parent.metadata.totals)
    }

    private func metadata(
        file: String = "/tmp/header-parent.jsonl",
        count: Int,
        input: Int,
        output: Int,
        credits: Double? = nil
    ) -> HistorySessionMetadata {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return HistorySessionMetadata(
            id: "shared-producer-id",
            file: URL(fileURLWithPath: file),
            source: .codex,
            dirID: "fixture",
            dirLabel: "Fixture",
            sessionID: "shared-producer-id",
            project: "fixture",
            title: "Catalog title",
            autoTitle: "Catalog title",
            createdAt: date,
            lastActivity: date,
            sizeBytes: 1_024,
            totals: HistoryTotals(inputTokens: input, outputTokens: output, credits: credits),
            messageCount: count
        )
    }

    private func session(_ metadata: HistorySessionMetadata) -> HistorySession {
        HistorySession(metadata: metadata, messages: [])
    }
}
