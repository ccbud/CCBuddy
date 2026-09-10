import Foundation
import XCTest
@testable import CCBuddy

final class ConversationFileCatalogSearchTests: XCTestCase {
    func testColdCandidatesNeverRestoreAndSearchWhileBackgroundRestoreIsBlocked() async throws {
        let fixture = try makeFixture()
        let entered = expectation(description: "background checkpoint restore entered")
        let barrier = DispatchSemaphore(value: 0)
        let attempts = LockedCounter()
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            _ = attempts.increment()
            entered.fulfill()
            guard barrier.wait(timeout: .now() + 10) == .success else {
                throw TgrepSearchIndex.Failure.operationFailed
            }
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        defer { barrier.signal(); catalog.cancelSearchIndexPreparation() }
        let text = String(repeating: "a", count: 32_766) + "系统代理 当前版本 Straße"
        try catalog.replace(session(root: fixture.root, id: "match", text: text))
        try catalog.replace(session(root: fixture.root, id: "unrelated", text: "entirely unrelated"))
        let cold = try catalog.candidateDocumentReferences(for: "系统代理")
        XCTAssertEqual(attempts.value, 0, "foreground lookup must not even open a checkpoint")
        XCTAssertTrue(cold.usedFallback)
        XCTAssertEqual(cold.references.count, 2)
        XCTAssertEqual(try counts(catalog, query: "系统代理"), ["match": 1])
        catalog.scheduleSearchIndexPreparation()
        await fulfillment(of: [entered], timeout: 3)
        // This is a functional barrier assertion, not a hardware-sensitive latency threshold:
        // the builder cannot finish until after the foreground query below has completed.
        XCTAssertEqual(try counts(catalog, query: "STRASSE"), ["match": 1])
        XCTAssertEqual(catalog.searchDiagnostics.fallbackReason, "indexRestoring")
        barrier.signal()
        await catalog.waitForSearchIndexPreparation()
        let prepared = try catalog.candidateDocumentReferences(for: "系统代理")
        XCTAssertFalse(prepared.usedFallback)
        XCTAssertEqual(prepared.references.count, 1)
        XCTAssertEqual(catalog.searchDiagnostics.engine, "tgrep")
    }

    func testGroupedPostingsPreserveFoundationMatchesAcrossStorageAndGroupBoundaries() async throws {
        XCTAssertTrue(TgrepSearchIndex.isAvailable)
        let fixture = try makeFixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog)
        defer { catalog.cancelSearchIndexPreparation() }
        let groupBytes = ConversationSearchChunk.targetBytes * ConversationFileCatalog.searchIndexGroupChunkCount
        for (literal, query) in [
            ("系统代理", "系统代理"), ("当前版本", "当前版本"), ("Straße", "STRASSE"),
            ("豈可搜索", "豈可搜索"), ("e\u{301}👩‍💻路径", "É👩‍💻路径"),
            ("before\0after", "e\0a"), ("ﬃxture", "ffi"),
        ] {
            for distance in [1, 5] {
                let text = String(repeating: "x", count: groupBytes - distance) + literal
                    + " suffix " + literal
                try catalog.replace(session(root: fixture.root, id: "unicode", text: text))
                catalog.scheduleSearchIndexPreparation()
                await catalog.waitForSearchIndexPreparation()
                let references = try catalog.candidateDocumentReferences(for: query)
                XCTAssertFalse(references.usedFallback, "\(query) / \(distance)")
                let expected = foundationCount(text, query: query)
                XCTAssertGreaterThan(expected, 0)
                XCTAssertEqual(try counts(catalog, query: query), ["unicode": expected],
                    "grouped postings lost a Foundation match: \(query) / \(distance)")
            }
        }
    }

    func testGroupFalsePositivesAreRefinedAndPostingsCountGroupsNotPhysicalChunks() async throws {
        let fixture = try makeFixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog)
        let text = "abc -- bcd -- cde -- def " + String(repeating: "x", count: 300_000)
        try catalog.replace(session(root: fixture.root, id: "false-positive", text: text))
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
        let batch = try catalog.candidateDocumentReferences(for: "abcdef")
        XCTAssertFalse(batch.usedFallback)
        XCTAssertEqual(batch.references.count, 1, "all query trigrams occur, but the full literal does not")
        XCTAssertEqual(catalog.searchDiagnostics.indexedDocuments, 2)
        XCTAssertEqual(batch.references.first?.candidateChunkIDs?.count, 8)
        XCTAssertEqual(try counts(catalog, query: "abcdef"), [:])
    }

    func testChangedAndMissingDocumentsUseExactScanWhileUnchangedGroupsStayIndexed() async throws {
        let fixture = try makeFixture()
        let entered = expectation(description: "replacement builder blocked")
        let barrier = DispatchSemaphore(value: 0)
        let attempts = LockedCounter()
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            if attempts.increment() == 2 {
                entered.fulfill()
                guard barrier.wait(timeout: .now() + 10) == .success else {
                    throw TgrepSearchIndex.Failure.operationFailed
                }
            }
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        defer { barrier.signal(); catalog.cancelSearchIndexPreparation() }
        try catalog.replace(session(root: fixture.root, id: "stable", text: "stable needle"))
        try catalog.replace(session(root: fixture.root, id: "changed", text: "obsolete contents"))
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
        try catalog.replace(session(root: fixture.root, id: "changed", text: "changed needle needle"))
        try catalog.replace(session(root: fixture.root, id: "new", text: "new needle"))
        catalog.scheduleSearchIndexPreparation()
        await fulfillment(of: [entered], timeout: 3)
        let references = try catalog.candidateDocumentReferences(for: "needle")
        XCTAssertTrue(references.usedFallback)
        XCTAssertEqual(references.references.filter { $0.candidateChunkIDs == nil }.count, 2)
        XCTAssertEqual(references.references.filter { $0.candidateChunkIDs != nil }.count, 1)
        XCTAssertEqual(try counts(catalog, query: "needle"), ["stable": 1, "changed": 2, "new": 1])
        XCTAssertEqual(try counts(catalog, query: "obsolete"), [:])
        barrier.signal()
        await catalog.waitForSearchIndexPreparation()
        XCTAssertFalse(try catalog.candidateDocumentReferences(for: "needle").usedFallback)
        XCTAssertEqual(try counts(catalog, query: "needle"), ["stable": 1, "changed": 2, "new": 1])
    }

    func testMetadataOnlyPreparationReusesReaderWithoutCheckpointRestore() async throws {
        let fixture = try makeFixture()
        let attempts = LockedCounter()
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            _ = attempts.increment()
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        var value = session(root: fixture.root, id: "metadata", text: "searchable needle")
        try catalog.replace(value)
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
        XCTAssertEqual(attempts.value, 1)
        value.metadata.title = "Updated title"
        try catalog.replaceMetadata([value])
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
        XCTAssertEqual(attempts.value, 1, "metadata-only changes must not reread the full checkpoint")
        XCTAssertEqual(try counts(catalog, query: "needle"), ["metadata": 1])
        XCTAssertEqual(catalog.searchDiagnostics.incrementallyIndexedDocuments, 0)
    }

    func testSameGenerationReplacementPreparesNewIdentityInsteadOfStayingOnLiteral() async throws {
        let fixture = try makeFixture()
        let attempts = LockedCounter()
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            _ = attempts.increment()
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        try catalog.replace(session(root: fixture.root, id: "same-path", text: "original retired needle"))
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
        let originalRevision = try catalog.searchIndexRevision()
        XCTAssertEqual(attempts.value, 1)

        let replacementRoot = fixture.root.appendingPathComponent("replacement", isDirectory: true)
        let replacement = try ConversationFileCatalog(file: replacementRoot, enableTgrep: false)
        try replacement.replace(session(root: fixture.root, id: "same-path", text: "replacement current needle"))
        let replacementRevision = try replacement.searchIndexRevision()
        XCTAssertEqual(originalRevision.generation, replacementRevision.generation)
        XCTAssertNotEqual(originalRevision.identity, replacementRevision.identity)
        // Install a complete replacement head/object set into this private test catalog only.
        // Its generation and numeric document IDs deliberately coincide with the old catalog.
        for object in try FileManager.default.contentsOfDirectory(at:
            replacementRoot.appendingPathComponent("objects"), includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: object, to: fixture.catalog.appendingPathComponent("objects")
                .appendingPathComponent(object.lastPathComponent))
        }
        try Data(contentsOf: replacementRoot.appendingPathComponent("manifest.json"))
            .write(to: fixture.catalog.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertEqual(try counts(catalog, query: "replacement"), ["same-path": 1])
        XCTAssertTrue(catalog.searchDiagnostics.usedFallback)
        catalog.scheduleSearchIndexPreparation()
        await catalog.waitForSearchIndexPreparation()
        XCTAssertEqual(attempts.value, 2, "same revision must not suppress preparation for a different identity")
        XCTAssertFalse(try catalog.candidateDocumentReferences(for: "replacement").usedFallback)
        XCTAssertEqual(try counts(catalog, query: "replacement"), ["same-path": 1])
        XCTAssertEqual(try counts(catalog, query: "retired"), [:])
    }

    func testWaitIncludesQueuedRestartAfterCancellationUntilSuccessorReallyFinishes() async throws {
        let fixture = try makeFixture()
        let firstStarted = expectation(description: "first builder blocked")
        let successorStarted = expectation(description: "successor builder blocked")
        let firstBarrier = DispatchSemaphore(value: 0)
        let successorBarrier = DispatchSemaphore(value: 0)
        let attempts = LockedCounter()
        let completions = LockedCounter()
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            let ordinal = attempts.increment()
            if ordinal == 1 {
                firstStarted.fulfill()
                guard firstBarrier.wait(timeout: .now() + 10) == .success else {
                    throw TgrepSearchIndex.Failure.operationFailed
                }
            } else if ordinal == 2 {
                successorStarted.fulfill()
                guard successorBarrier.wait(timeout: .now() + 10) == .success else {
                    throw TgrepSearchIndex.Failure.operationFailed
                }
            }
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        defer { firstBarrier.signal(); successorBarrier.signal(); catalog.cancelSearchIndexPreparation() }
        try catalog.replace(session(root: fixture.root, id: "restart", text: "successfully restarted search"))
        catalog.scheduleSearchIndexPreparation()
        await fulfillment(of: [firstStarted], timeout: 3)
        catalog.cancelSearchIndexPreparation()
        catalog.scheduleSearchIndexPreparation()
        let waiter = Task {
            await catalog.waitForSearchIndexPreparation()
            _ = completions.increment()
        }
        firstBarrier.signal()
        await fulfillment(of: [successorStarted], timeout: 3)
        XCTAssertEqual(completions.value, 0, "wait cannot finish in the old-task/successor handoff gap")
        successorBarrier.signal()
        await waiter.value
        XCTAssertEqual(completions.value, 1)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertFalse(try catalog.candidateDocumentReferences(for: "restarted").usedFallback)
        XCTAssertEqual(try counts(catalog, query: "restarted"), ["restart": 1])
    }

    func testDestroyingNeverStartedFacadeDoesNotCancelColdSearchPreparation() async throws {
        let fixture = try makeFixture()
        let started = expectation(description: "cold builder blocked")
        let barrier = DispatchSemaphore(value: 0)
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            started.fulfill()
            guard barrier.wait(timeout: .now() + 10) == .success else {
                throw TgrepSearchIndex.Failure.operationFailed
            }
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        defer { barrier.signal(); catalog.cancelSearchIndexPreparation() }
        try catalog.replace(session(root: fixture.root, id: "facade", text: "cold searchable needle"))
        catalog.scheduleSearchIndexPreparation()
        await fulfillment(of: [started], timeout: 3)
        var facade: IndexedHistoryRepository? = IndexedHistoryRepository(configuration: .init(
            historyDirs: ["scope"], homeDirectory: fixture.root,
            importsRoot: fixture.root.appendingPathComponent("imports")), database: catalog)
        XCTAssertEqual(try facade?.search(query: "needle").count, 1)
        facade = nil // deinit of its never-started coordinator is not a catalog stop request.
        barrier.signal()
        await catalog.waitForSearchIndexPreparation()
        XCTAssertFalse(try catalog.candidateDocumentReferences(for: "needle").usedFallback)
        XCTAssertEqual(catalog.searchDiagnostics.engine, "tgrep")
    }

    func testStoppingOneCatalogLifecycleDoesNotCancelAnotherOwnersBuilder() async throws {
        let fixture = try makeFixture()
        let started = expectation(description: "shared builder blocked")
        let barrier = DispatchSemaphore(value: 0)
        var runtime = ConversationFileCatalog.TgrepRuntime()
        runtime.makeIndex = { url in
            started.fulfill()
            guard barrier.wait(timeout: .now() + 10) == .success else {
                throw TgrepSearchIndex.Failure.operationFailed
            }
            return try TgrepSearchIndex(cacheDirectory: url)
        }
        let catalog = try ConversationFileCatalog(file: fixture.catalog, tgrepRuntime: runtime)
        let first = UUID()
        let second = UUID()
        defer {
            barrier.signal()
            catalog.unregisterIndexLifecycle(first)
            catalog.unregisterIndexLifecycle(second)
            catalog.cancelSearchIndexPreparation()
        }
        catalog.registerIndexLifecycle(first)
        catalog.registerIndexLifecycle(second)
        try catalog.replace(session(root: fixture.root, id: "shared", text: "shared owners needle"))
        catalog.scheduleSearchIndexPreparation()
        await fulfillment(of: [started], timeout: 3)
        catalog.unregisterIndexLifecycle(first)
        catalog.unregisterIndexLifecycle(first) // repeated stop cannot affect the remaining owner.
        barrier.signal()
        await catalog.waitForSearchIndexPreparation()
        XCTAssertFalse(try catalog.candidateDocumentReferences(for: "needle").usedFallback)
        XCTAssertEqual(try counts(catalog, query: "needle"), ["shared": 1])
    }

    private func makeFixture() throws -> (root: URL, catalog: URL) {
        let root = try HistoryTestSupport.temporaryDirectory("file-catalog-search")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("catalog", isDirectory: true))
    }

    private func session(root: URL, id: String, text: String) -> ConversationIndexedSession {
        let source = root.appendingPathComponent(id + ".jsonl")
        return .init(metadata: HistorySessionMetadata(id: "disk:" + id, file: source,
            source: .claude, dirID: "scope", dirLabel: "Scope", sessionID: id, project: "Project",
            title: id, autoTitle: id, createdAt: .now, lastActivity: .now, sizeBytes: UInt64(text.utf8.count)),
            fingerprint: .init(modificationTime: .now, sizeBytes: UInt64(text.utf8.count)),
            documents: [.init(transcriptID: "main", sortOrder: 0, text: text,
                messageSpans: [.init(sequence: 0, messageIndex: 0, utf16Location: 0,
                    utf16Length: text.utf16.count, role: "user")])])
    }

    private func counts(_ catalog: ConversationFileCatalog, query: String) throws -> [String: Int] {
        let matcher = ConversationLiteralSearch(query: query)
        var result: [String: Int] = [:]
        for reference in try catalog.candidateDocumentReferences(for: query).references {
            var cursor: ConversationIndexSearchCursor?
            var resume = 0
            var count = 0
            repeat {
                let batch = try catalog.searchChunkWindows(reference: reference, query: query,
                    cursor: cursor, limit: 3)
                for window in batch.windows {
                    if let match = matcher.match(in: window.text,
                        startingAtUTF16: max(0, resume - window.globalUTF16Start),
                        ownedUTF16Length: window.ownedUTF16Length) {
                        count += match.count
                        resume = window.globalUTF16Start + match.lastUTF16End
                    }
                }
                cursor = batch.nextCursor
            } while cursor != nil
            if count > 0 {
                result[URL(fileURLWithPath: reference.sessionPath).deletingPathExtension().lastPathComponent] = count
            }
        }
        return result
    }

    private func foundationCount(_ text: String, query: String) -> Int {
        var cursor = text.startIndex
        var count = 0
        while cursor < text.endIndex,
              let match = text.range(of: query, options: .caseInsensitive, range: cursor..<text.endIndex) {
            count += 1
            cursor = match.upperBound
        }
        return count
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}
