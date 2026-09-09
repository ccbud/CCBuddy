import XCTest
@testable import CCBuddy

final class ConversationProgressiveCountTests: XCTestCase {
    func testRawRewriteAttemptClearsOldPrefixWithoutCatalogRevisionChange() {
        var state = ConversationSearchProgressState()
        let old = UUID(), current = UUID()
        state.receive(.init(phase: .refiningResults, hits: [hit("old")], snapshotRevision: 9,
            snapshotIdentity: "catalog", snapshotAttempt: old), ordinal: 1)
        state.receive(.init(phase: .preparingCandidates, hits: [], snapshotRevision: 9,
            snapshotIdentity: "catalog", snapshotAttempt: current), ordinal: 2)
        XCTAssertTrue(state.hits.isEmpty)
        XCTAssertEqual(state.phase, .preparingCandidates)
        XCTAssertFalse(state.receive(.init(phase: .refiningResults, hits: [hit("old")], snapshotRevision: 9,
            snapshotIdentity: "catalog", snapshotAttempt: old), ordinal: 3))
        XCTAssertTrue(state.hits.isEmpty)
        state.receive(.init(phase: .refiningResults, hits: [hit("new")], snapshotRevision: 9,
            snapshotIdentity: "catalog", snapshotAttempt: current), ordinal: 4)
        XCTAssertEqual(state.hits, [hit("new")])
    }

    private func hit(_ name: String = "a", count: Int = 1, complete: Bool = false) -> HistorySearchHit {
        .init(sessionID: name, file: URL(fileURLWithPath: "/tmp/count-\(name).jsonl"), source: .claude,
              sequence: 7, snippet: "verified needle", count: count, isCountComplete: complete)
    }

    func testOldInitializersAndOldJSONKeepCompleteCountSemantics() throws {
        let original = HistorySearchHit(sessionID: "a", file: URL(fileURLWithPath: "/tmp/legacy-count.jsonl"),
                                        source: .claude, snippet: "needle", count: 4)
        XCTAssertTrue(original.isCountComplete)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "isCountComplete")
        let decoded = try JSONDecoder().decode(HistorySearchHit.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, original)
    }

    func testIncompleteCountRoundTripsWithoutChangingHitIdentityOrAnchor() throws {
        let initial = hit()
        let decoded = try JSONDecoder().decode(HistorySearchHit.self, from: JSONEncoder().encode(initial))
        XCTAssertEqual(decoded, initial)
        XCTAssertFalse(decoded.isCountComplete)
        var complete = decoded
        complete.count = 4
        complete.isCountComplete = true
        XCTAssertEqual(complete.id, initial.id)
        XCTAssertEqual(complete.sequence, initial.sequence)
        XCTAssertEqual(complete.snippet, initial.snippet)
    }

    func testSameLengthPrefixRefinesCountWithoutRegressingFinishedCountOrPhase() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .refiningResults, hits: [hit()]), ordinal: 1)
        XCTAssertFalse(state.hits[0].isCountComplete)
        state.receive(.init(phase: .countingOccurrences, hits: [hit(count: 5, complete: true)]), ordinal: 2)
        XCTAssertEqual(state.hits, [hit(count: 5, complete: true)])
        state.receive(.init(phase: .refiningResults, hits: [hit()]), ordinal: 3)
        XCTAssertEqual(state.hits, [hit(count: 5, complete: true)])
        XCTAssertEqual(state.phase, .countingOccurrences)
    }

    func testLateMainActorDeliveryCannotRestoreOldRevision() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .refiningResults, hits: [hit("new")], snapshotRevision: 20), ordinal: 2)
        XCTAssertFalse(state.receive(.init(phase: .countingOccurrences,
            hits: [hit("old", count: 9, complete: true)], snapshotRevision: 10), ordinal: 1))
        XCTAssertEqual(state.hits, [hit("new")])
        XCTAssertEqual(state.snapshotRevision, 20)
    }

    func testNewSnapshotReplacesPrefixInsteadOfUnioningOldHits() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .countingOccurrences, hits: [hit("old")], snapshotRevision: 10), ordinal: 1)
        state.receive(.init(phase: .preparingCandidates, hits: [], snapshotRevision: 11), ordinal: 2)
        XCTAssertTrue(state.hits.isEmpty)
        XCTAssertEqual(state.phase, .preparingCandidates)
        state.receive(.init(phase: .refiningResults, hits: [hit("new")], snapshotRevision: 11), ordinal: 3)
        XCTAssertEqual(state.hits, [hit("new")])
    }

    func testCompletionCallbackCannotPrematurelyFinishCounting() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .countingOccurrences, hits: [hit()]), ordinal: 1)
        XCTAssertFalse(state.receive(.init(phase: .completed, hits: [hit()]), ordinal: 2))
        XCTAssertEqual(state.phase, .countingOccurrences)
        XCTAssertFalse(state.hits[0].isCountComplete)
    }

    func testCountUpdateCannotReplaceAlreadyPublishedAnchorOrSnippet() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .refiningResults, hits: [hit()]), ordinal: 1)
        var changed = hit(count: 4, complete: true)
        changed.sequence = 99
        changed.snippet = "different anchor"
        state.receive(.init(phase: .countingOccurrences, hits: [changed]), ordinal: 2)
        XCTAssertEqual(state.hits, [hit()])
    }

    func testSlowSourceCanInsertBeforeHotResultsWithoutRegressingTheirCounts() {
        var state = ConversationSearchProgressState()
        let finished = hit("hot", count: 5, complete: true)
        state.receive(.init(phase: .refiningResults, hits: [finished, hit("later")]), ordinal: 1)
        state.receive(.init(phase: .refiningResults, hits: [hit("source"), hit("hot"),
            hit("later", count: 3, complete: true)]), ordinal: 2)
        XCTAssertEqual(state.hits, [hit("source"), finished, hit("later", count: 3, complete: true)])
    }

    func testSameSnapshotCanReorderIdentitiesWhileRefiningCounts() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .refiningResults, hits: [hit("b"), hit("a")]), ordinal: 1)
        state.receive(.init(phase: .countingOccurrences,
            hits: [hit("a", count: 4, complete: true), hit("b", count: 2)]), ordinal: 2)
        XCTAssertEqual(state.hits, [hit("a", count: 4, complete: true), hit("b", count: 2)])
    }

    func testSameIdentityPublishesDiscoveredChildNavigationWithoutRegressingExactCount() {
        var state = ConversationSearchProgressState()
        var original = hit("parent", count: 5, complete: true)
        let date = Date(timeIntervalSince1970: 100)
        original.sourceMetadata = .init(id: "parent", file: original.file, source: .claude,
            dirID: "fixture", dirLabel: "Fixture", sessionID: "parent", project: "Fixture",
            title: "Parent", autoTitle: "Parent", createdAt: date, lastActivity: date, sizeBytes: 100)
        state.receive(.init(phase: .refiningResults, hits: [original]), ordinal: 1)
        var refreshed = original
        refreshed.count = 1
        refreshed.isCountComplete = false
        refreshed.sourceMetadata?.subagentRefs = [.init(
            file: URL(fileURLWithPath: "/tmp/count-child.jsonl"), threadID: "child",
            title: "New child", messageCount: 2, lastActivity: date)]
        refreshed.sourceMetadata?.subagentCount = 1
        state.receive(.init(phase: .countingOccurrences, hits: [refreshed]), ordinal: 2)
        XCTAssertEqual(state.hits.first?.sourceMetadata, refreshed.sourceMetadata)
        XCTAssertEqual(state.hits.first?.count, 5)
        XCTAssertEqual(state.hits.first?.isCountComplete, true)
        XCTAssertEqual(state.hits.first?.sequence, original.sequence)
        XCTAssertEqual(state.hits.first?.snippet, original.snippet)
    }

    func testIncompleteSnapshotCannotWithdrawAnAlreadyVerifiedIdentity() {
        var state = ConversationSearchProgressState()
        let original = [hit("a"), hit("b")]
        state.receive(.init(phase: .refiningResults, hits: original), ordinal: 1)
        state.receive(.init(phase: .refiningResults, hits: [hit("b", count: 5)]), ordinal: 2)
        XCTAssertEqual(state.hits, original)
    }

    func testDuplicateIdentitiesAndUnverifiedInsertionsCannotCorruptCumulativeResults() {
        var state = ConversationSearchProgressState()
        state.receive(.init(phase: .refiningResults, hits: [hit("hot")]), ordinal: 1)
        state.receive(.init(phase: .refiningResults, hits: [hit("source"), hit("hot"), hit("source")]), ordinal: 2)
        XCTAssertEqual(state.hits, [hit("hot")])
        state.receive(.init(phase: .refiningResults, hits: [hit("source", count: 0), hit("hot")]), ordinal: 3)
        XCTAssertEqual(state.hits, [hit("hot")])
    }

    func testReorderingCannotChangeAnExistingSourcesIdentityOrAnchor() {
        let mutations: [(inout HistorySearchHit) -> Void] = [
            { $0.source = .codex }, { $0.sessionID = "replacement" },
            { $0.agentType = "replacement" }, { $0.sequence = 99 }, { $0.snippet = "replacement" },
        ]
        for mutate in mutations {
            var state = ConversationSearchProgressState()
            state.receive(.init(phase: .refiningResults, hits: [hit("hot")]), ordinal: 1)
            var changed = hit("hot", count: 7, complete: true)
            mutate(&changed)
            state.receive(.init(phase: .refiningResults, hits: [hit("source"), changed]), ordinal: 2)
            XCTAssertEqual(state.hits, [hit("hot")])
        }
    }

    func testKeyboardSelectionSurvivesCountUpdatesAppendsAndSemanticReordering() {
        var selection = ConversationSearchSelection()
        selection.reconcile(files: ["a", "b"])
        selection.move(by: 1, files: ["a", "b"])
        selection.reconcile(files: ["a", "b"])
        XCTAssertEqual(selection.file, "b")
        XCTAssertEqual(selection.index, 1)
        selection.reconcile(files: ["a", "b", "c"])
        XCTAssertEqual(selection.file, "b")
        selection.reconcile(files: ["c", "b", "a"])
        XCTAssertEqual(selection.file, "b")
        selection.reconcile(files: ["b", "c", "a"])
        XCTAssertEqual(selection.index, 0)
        selection.reset()
        selection.reconcile(files: ["new", "other"])
        XCTAssertEqual(selection.file, "new")
    }

    func testInitialHighlightedIdentityAlsoSurvivesSemanticReordering() {
        var selection = ConversationSearchSelection()
        selection.reconcile(files: ["a", "b"])
        selection.reconcile(files: ["b", "a"])
        XCTAssertEqual(selection.file, "a")
        XCTAssertEqual(selection.index, 1)
    }

    func testIncompleteCountPresentationNeverClaimsAnExactTotalOrActiveWork() {
        XCTAssertEqual(ConversationSearchCountPresentation.label(for: hit(), language: .english), "At least 1 match")
        XCTAssertEqual(ConversationSearchCountPresentation.label(for: hit(count: 5), language: .english), "At least 5 matches")
        XCTAssertEqual(ConversationSearchCountPresentation.label(for: hit(complete: true), language: .english), "1 match")
        XCTAssertEqual(ConversationSearchCountPresentation.label(for: hit(count: 5, complete: true), language: .english), "5 matches")
        for language in AppLanguage.allCases {
            XCTAssertNotEqual(ConversationSearchCountPresentation.label(for: hit(), language: language),
                              ConversationSearchCountPresentation.label(for: hit(complete: true), language: language))
        }
    }
}
