import Combine
import Foundation
import XCTest
@testable import CCBuddy

@MainActor
final class ConversationSourceMutationSearchTests: XCTestCase {
    func testSoftDeleteRevokesSourceHitAndLateProgressWithoutBlankingOtherResults() async throws {
        try await verifySuccessfulMutation(.softDelete)
    }

    func testRestoreRevokesTrashSourceHitAndLateProgressWithoutBlankingOtherResults() async throws {
        try await verifySuccessfulMutation(.restore)
    }

    func testPermanentDeleteRevokesSourceHitAndLateProgressWithoutBlankingOtherResults() async throws {
        try await verifySuccessfulMutation(.permanentDelete)
    }

    func testFailedMutationsKeepTheVerifiedSourceHitsAndTheirCurrentSearch() async throws {
        for mutation in SourceMutationCase.allCases {
            let fixture = try SourceMutationSearchFixture(deleted: mutation != .softDelete)
            defer { fixture.cleanup() }
            let provider = SourceMutationSearchRepository(repository: fixture.repository)
            defer { provider.releaseAll() }
            let store = ConversationStore(repository: provider, mutationService: RejectedSourceMutations(),
                historyActive: fixture.active, searchDelayNanoseconds: 0)
            await store.reload()
            store.updateListQuery("needle")
            await waitUntil { store.contentHits.count == 2 }
            let before = store.contentHits
            let row = try XCTUnwrap(store.orderedSearchSessions.first { $0.file == fixture.target })
            await store.select(row, searchHit: store.contentHit(for: row))

            await mutation.perform(on: store)

            XCTAssertTrue(store.actionIsError)
            XCTAssertEqual(store.contentHits, before)
            XCTAssertEqual(store.selectedFile, fixture.target)
            XCTAssertTrue(store.isSearchingContent)
            XCTAssertEqual(provider.searchCount, 1, "A failed write must not replace the valid query generation")
            provider.releaseAll()
            await waitUntil { !store.isSearchingContent }
            XCTAssertEqual(store.contentHits, before)
        }
    }

    func testRenamingAnUncatalogedSourceKeepsItOpenAndRejectsOldMetadataCallbacks() async throws {
        try await verifySuccessfulAnnotation(.rename)
    }

    func testStarringAnUncatalogedSourceKeepsItOpenAndRejectsOldMetadataCallbacks() async throws {
        try await verifySuccessfulAnnotation(.star)
    }

    func testPinningAnUncatalogedSourceKeepsItOpenAndRejectsOldMetadataCallbacks() async throws {
        try await verifySuccessfulAnnotation(.pin)
    }

    func testFailedAnnotationsDoNotRevokeOrAlterAnUncatalogedSource() async throws {
        for annotation in SourceAnnotationCase.allCases {
            let fixture = try SourceMutationSearchFixture(deleted: false)
            defer { fixture.cleanup() }
            let provider = SourceMutationSearchRepository(repository: fixture.repository)
            defer { provider.releaseAll() }
            let store = ConversationStore(repository: provider, mutationService: RejectedSourceMutations(),
                searchDelayNanoseconds: 0)
            await store.reload()
            store.updateListQuery("needle")
            await waitUntil { store.contentHits.count == 2 }
            let row = try XCTUnwrap(store.orderedSearchSessions.first { $0.file == fixture.target })
            await store.select(row, searchHit: store.contentHit(for: row))
            let before = store.contentHits
            await annotation.perform(on: store)
            XCTAssertTrue(store.actionIsError)
            XCTAssertEqual(store.selectedFile, fixture.target)
            XCTAssertEqual(store.contentHits, before)
            XCTAssertTrue(store.isSearchingContent)
            XCTAssertEqual(provider.searchCount, 1)
        }
    }

    private func verifySuccessfulAnnotation(_ annotation: SourceAnnotationCase) async throws {
        let fixture = try SourceMutationSearchFixture(deleted: false)
        defer { fixture.cleanup() }
        let provider = SourceMutationSearchRepository(repository: fixture.repository)
        defer { provider.releaseAll() }
        let store = ConversationStore(repository: provider, mutationService: fixture.service,
            searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("needle")
        await waitUntil { store.contentHits.count == 2 }
        let row = try XCTUnwrap(store.orderedSearchSessions.first { $0.file == fixture.target })
        await store.select(row, searchHit: store.contentHit(for: row))
        await annotation.perform(on: store)
        XCTAssertFalse(store.actionIsError, store.actionMessage ?? "Annotation failed")
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(store.selectedFile, fixture.target)
        XCTAssertEqual(store.detailState, .loaded)
        let saved = try fixture.repository.getSession(file: fixture.target).metadata
        annotation.assertApplied(to: saved)
        annotation.assertApplied(to: try XCTUnwrap(store.selectedMetadata))
        let updated = try XCTUnwrap(store.orderedSearchSessions.first { $0.file == fixture.target })
        annotation.assertApplied(to: updated)
        XCTAssertEqual(store.contentHits.count, 2)
        await waitUntil { provider.searchCount == 2 }

        var staleMetadataReturned = false
        let observation = store.$contentHits.sink { hits in
            if let metadata = hits[ConversationFilter.fileKey(fixture.target)]?.sourceMetadata,
               !annotation.isApplied(to: metadata) { staleMetadataReturned = true }
        }
        defer { observation.cancel() }
        provider.releaseOriginal()
        await waitUntil { provider.didPublishLateOriginalProgress }
        provider.releaseReplacement()
        await waitUntil { !store.isSearchingContent }
        XCTAssertFalse(staleMetadataReturned, "A retired query must not undo committed annotations")
        XCTAssertEqual(store.selectedFile, fixture.target)
        annotation.assertApplied(to: try XCTUnwrap(store.orderedSearchSessions.first { $0.file == fixture.target }))
    }

    private func verifySuccessfulMutation(_ mutation: SourceMutationCase) async throws {
        let fixture = try SourceMutationSearchFixture(deleted: mutation != .softDelete)
        defer { fixture.cleanup() }
        let provider = SourceMutationSearchRepository(repository: fixture.repository)
        defer { provider.releaseAll() }
        let store = ConversationStore(repository: provider, mutationService: fixture.service,
            historyActive: fixture.active, searchDelayNanoseconds: 0)
        await store.reload()
        store.updateListQuery("needle")
        await waitUntil { store.contentHits.count == 2 }
        XCTAssertTrue(store.projects.isEmpty, "Both rows must exercise the query-local source overlay")
        let row = try XCTUnwrap(store.orderedSearchSessions.first { $0.file == fixture.target })
        await store.select(row, searchHit: store.contentHit(for: row))

        await mutation.perform(on: store)

        XCTAssertFalse(store.actionIsError, store.actionMessage ?? "Mutation failed")
        XCTAssertNil(store.selectedFile)
        XCTAssertNil(store.contentHits[ConversationFilter.fileKey(fixture.target)])
        XCTAssertEqual(store.orderedSearchSessions.map(\.file), [fixture.retained],
            "Keep the unrelated verified result while the new exact query is gated")
        await waitUntil { provider.searchCount == 2 }
        XCTAssertTrue(store.isSearchingContent)

        var revived = false
        let observation = store.$contentHits.sink { hits in
            if hits[ConversationFilter.fileKey(fixture.target)] != nil { revived = true }
        }
        defer { observation.cancel() }
        // This provider deliberately ignores cancellation and publishes the pre-mutation snapshot
        // again. The Store's generation guard, not a cooperative provider, must reject that event.
        provider.releaseOriginal()
        await waitUntil { provider.didPublishLateOriginalProgress }
        provider.releaseReplacement()
        await waitUntil { !store.isSearchingContent }
        XCTAssertFalse(revived, "No delayed prefix or final return may resurrect the changed source")
        XCTAssertEqual(store.orderedSearchSessions.map(\.file), [fixture.retained])
        XCTAssertEqual(store.contentHits.count, 1)
        XCTAssertEqual(store.contentSearchPhase, .completed)

        if mutation == .permanentDelete {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        } else {
            let metadata = try fixture.repository.getSession(file: fixture.target).metadata
            XCTAssertEqual(metadata.deleted, mutation == .softDelete)
        }
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(predicate(), "Expected mutation/search state was not published", file: file, line: line)
    }
}

private enum SourceAnnotationCase: CaseIterable {
    case rename, star, pin

    @MainActor func perform(on store: ConversationStore) async {
        switch self {
        case .rename: await store.updateSelectedMetadata(title: "  Renamed source  ", tags: [" tag ", "tag"])
        case .star: await store.toggleStarSelected()
        case .pin: await store.togglePinSelected()
        }
    }

    func isApplied(to metadata: HistorySessionMetadata) -> Bool {
        switch self {
        case .rename: metadata.title == "Renamed source" && metadata.tags == ["tag"]
        case .star: metadata.starred
        case .pin: metadata.pinned
        }
    }

    func assertApplied(to metadata: HistorySessionMetadata,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isApplied(to: metadata), "Committed source annotation must be visible", file: file, line: line)
    }
}

private enum SourceMutationCase: CaseIterable {
    case softDelete, restore, permanentDelete

    @MainActor func perform(on store: ConversationStore) async {
        switch self {
        case .softDelete: await store.softDeleteSelected()
        case .restore: await store.restoreSelected()
        case .permanentDelete: await store.permanentlyDeleteSelected()
        }
    }
}

private struct SourceMutationSearchFixture {
    let root: URL
    let target: URL
    let retained: URL
    let active: String
    let service: ConversationMutationService
    let repository: HistoryRepository

    init(deleted: Bool) throws {
        root = try HistoryTestSupport.temporaryDirectory("source-mutation-search")
        let history = root.appendingPathComponent("history", isDirectory: true)
        let project = history.appendingPathComponent("projects/-tmp-source-mutation", isDirectory: true)
        target = project.appendingPathComponent("target.jsonl")
        retained = project.appendingPathComponent("retained.jsonl")
        let configuration = ConversationMutationConfiguration(historyDirs: [history.path], homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports", isDirectory: true))
        service = ConversationMutationService(configuration: configuration)
        active = deleted ? "__trash__" : "all"
        repository = HistoryRepository(historyDirs: [history.path], active: active,
            homeDirectory: root, importsRoot: configuration.importsRoot)
        for (name, file) in [("target", target), ("retained", retained)] {
            try HistoryTestSupport.write([HistoryTestSupport.claudeLine(type: "user", role: "user",
                contentJSON: #""needle""#, sessionID: name, cwd: "/tmp/source-mutation",
                timestamp: "2026-06-01T00:00:00Z")], to: file)
            if deleted { try service.softDelete(repository.getSession(file: file).metadata) }
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class SourceMutationSearchRepository: ConversationProgressiveHistoryProviding, @unchecked Sendable {
    let repository: HistoryRepository
    private let condition = NSCondition()
    private var runs = 0
    private var originalReleased = false
    private var replacementReleased = false
    private var lateOriginalPublished = false

    init(repository: HistoryRepository) { self.repository = repository }
    var searchCount: Int { condition.withLock { runs } }
    var didPublishLateOriginalProgress: Bool { condition.withLock { lateOriginalPublished } }
    func listProjects(limit: Int) throws -> [HistoryProject] { [] }
    func getSession(file: URL) throws -> HistorySession { try repository.getSession(file: file) }

    func search(query: String, limit: Int) throws -> [HistorySearchHit] {
        try repository.search(query: query, limit: limit).map { hit in
            var result = hit
            result.sourceMetadata = try repository.getSession(file: hit.file).metadata
            return result
        }
    }

    func search(query: String, limit: Int,
                onProgress: @Sendable (ConversationSearchProgress) -> Void) throws -> [HistorySearchHit] {
        let run = condition.withLock { runs += 1; return runs }
        let attempt = UUID()
        if run == 1 {
            let hits = try search(query: query, limit: limit)
            let progress = ConversationSearchProgress(phase: .refiningResults, hits: hits,
                snapshotRevision: 1, snapshotIdentity: "mutation-fixture", snapshotAttempt: attempt)
            onProgress(progress)
            try waitForRelease(original: true)
            onProgress(progress)
            condition.withLock { lateOriginalPublished = true }
            return hits
        }
        try waitForRelease(original: false)
        let hits = try search(query: query, limit: limit)
        onProgress(.init(phase: .refiningResults, hits: hits, snapshotRevision: 2,
                         snapshotIdentity: "mutation-fixture", snapshotAttempt: attempt))
        return hits
    }

    func releaseOriginal() { condition.withLock { originalReleased = true; condition.broadcast() } }
    func releaseReplacement() { condition.withLock { replacementReleased = true; condition.broadcast() } }
    func releaseAll() { releaseOriginal(); releaseReplacement() }

    private func waitForRelease(original: Bool) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(6)
        while !(original ? originalReleased : replacementReleased), condition.wait(until: deadline) {}
        guard original ? originalReleased : replacementReleased else {
            throw HistoryError.unreadableFile(URL(fileURLWithPath: "/tmp/mutation-fixture"), "Fixture barrier timed out")
        }
    }
}

private struct RejectedSourceMutations: ConversationMutating {
    struct Rejected: Error {}
    func updateMetadata(for metadata: HistorySessionMetadata, patch: ConversationMetadataPatch) throws { throw Rejected() }
    func softDelete(_ metadata: HistorySessionMetadata) throws { throw Rejected() }
    func restore(_ metadata: HistorySessionMetadata) throws { throw Rejected() }
    func canPermanentlyDelete(_ metadata: HistorySessionMetadata) -> Bool { true }
    func permanentlyDelete(_ metadata: HistorySessionMetadata) throws { throw Rejected() }
    func importFile(_ source: URL) -> ConversationImportDisposition { .failed(source, "unused") }
    func exportRaw(_ metadata: HistorySessionMetadata, to destination: URL) throws -> ConversationRawExportResult {
        throw Rejected()
    }
}
