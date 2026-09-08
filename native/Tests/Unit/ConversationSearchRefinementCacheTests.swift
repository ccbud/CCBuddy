import Foundation
import XCTest
@testable import CCBuddy

final class ConversationSearchRefinementCacheTests: XCTestCase {
    func testRepeatedQueryReusesExactAnswerAcrossScopesAndLimits() throws {
        let fixture = try makeFixture()
        try fixture.database.replace(fixture.session(text: "系统代理 needle needle", sequence: 7))
        let first = try fixture.repository.search(query: "needle", limit: 1)
        XCTAssertEqual(first.first?.count, 2)
        XCTAssertEqual(first.first?.sequence, 7)
        XCTAssertEqual(fixture.cache.statistics.stores, 1)
        XCTAssertEqual(try fixture.repository.scoped(to: fixture.scope.path)
            .search(query: "  needle\n", limit: 20), first)
        XCTAssertEqual(fixture.cache.statistics.stores, 1)
        XCTAssertEqual(fixture.cache.statistics.validatedHits, 1)
        XCTAssertTrue(try fixture.repository.scoped(to: fixture.otherScope.path)
            .search(query: "needle", limit: 20).isEmpty)
        XCTAssertTrue(try fixture.repository.scoped(to: "__trash__")
            .search(query: "needle", limit: 20).isEmpty)
    }

    func testContentReplacementAndDeleteReinsertCannotReuseOldRowAnswer() throws {
        let fixture = try makeFixture()
        let original = fixture.session(text: "needle original", sequence: 1)
        try fixture.database.replace(original)
        let reference = try fixture.reference(query: "needle")
        XCTAssertEqual(try fixture.repository.search(query: "needle").first?.count, 1)
        try fixture.database.replace(fixture.session(text: "needle changed needle", sequence: 8))
        let changed = try XCTUnwrap(fixture.repository.search(query: "needle").first)
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(changed.sequence, 8)
        XCTAssertTrue(changed.snippet.contains("changed"))
        try fixture.database.remove(files: [original.metadata.file])
        try fixture.database.replace(fixture.session(text: "needle recreated needle needle", sequence: 12))
        XCTAssertEqual(try fixture.reference(query: "needle").documentID, reference.documentID,
                       "Exercise SQLite row-ID reuse, not only changing IDs")
        let recreated = try XCTUnwrap(fixture.repository.search(query: "needle").first)
        XCTAssertEqual(recreated.count, 3)
        XCTAssertEqual(recreated.sequence, 12)
        XCTAssertTrue(recreated.snippet.contains("recreated"))
        XCTAssertEqual(fixture.cache.statistics.validatedHits, 0)

        try fixture.database.remove(files: [original.metadata.file])
        var other = fixture.session(text: "needle different path", sequence: 4)
        other.metadata.file = fixture.scope.appendingPathComponent("different.jsonl")
        try fixture.database.replace(other)
        XCTAssertEqual(try fixture.reference(query: "needle").documentID, reference.documentID)
        XCTAssertEqual(try fixture.repository.search(query: "needle").first?.file, other.metadata.file)
        XCTAssertEqual(try fixture.repository.search(query: "needle").first?.sequence, 4)
    }

    func testMetadataScopeAndTrashChangesRebindCurrentResultAndInvalidateConservatively() throws {
        let fixture = try makeFixture()
        var session = fixture.session(text: "needle retained contents")
        try fixture.database.replace(session)
        _ = try fixture.repository.search(query: "needle")
        session.metadata.sessionID = "renamed-session"
        session.metadata.source = .qoder
        session.metadata.dirID = fixture.otherScope.path
        session.scope = fixture.otherScope.path
        session.metadata.deleted = true
        try fixture.database.replaceMetadata([session])
        XCTAssertTrue(try fixture.repository.search(query: "needle").isEmpty)
        let trash = try XCTUnwrap(fixture.repository.scoped(to: "__trash__")
            .search(query: "needle", limit: 20).first)
        XCTAssertEqual(trash.sessionID, "renamed-session")
        XCTAssertEqual(trash.source, .qoder)
        XCTAssertEqual(trash.snippet, "needle retained contents")
        XCTAssertEqual(fixture.cache.statistics.stores, 2)
        XCTAssertEqual(fixture.cache.statistics.validatedHits, 0,
                       "Even metadata-only catalog generations conservatively invalidate")
        session.metadata.deleted = false
        try fixture.database.replaceMetadata([session])
        XCTAssertTrue(try fixture.repository.scoped(to: fixture.scope.path)
            .search(query: "needle", limit: 20).isEmpty)
        XCTAssertEqual(try fixture.repository.scoped(to: fixture.otherScope.path)
            .search(query: "needle", limit: 20).map(\.sessionID), ["renamed-session"])
    }

    func testFalsePositiveCandidatesCacheNoMatchWithoutInventingResults() throws {
        let fixture = try makeFixture()
        guard fixture.database.supportsTrigramSearch else { throw XCTSkip("SQLite trigram tokenizer unavailable") }
        try fixture.database.replace(fixture.session(text: "needle separated from phrase"))
        XCTAssertFalse(try fixture.database.candidateDocumentReferences(for: "needle phrase").references.isEmpty)
        XCTAssertTrue(try fixture.repository.search(query: "needle phrase").isEmpty)
        XCTAssertEqual(fixture.cache.statistics.stores, 1)
        XCTAssertTrue(try fixture.repository.search(query: "needle phrase").isEmpty)
        XCTAssertEqual(fixture.cache.statistics.validatedHits, 1)
        try fixture.database.replace(fixture.session(text: "needle phrase now exists"))
        XCTAssertEqual(try fixture.repository.search(query: "needle phrase").first?.count, 1)
    }

    func testSkinnySnapshotValidationSkipsDocumentAndRejectsWrongIdentity() throws {
        let fixture = try makeFixture()
        try fixture.database.replace(fixture.session(text: "needle generation one"))
        let reference = try fixture.reference(query: "needle")
        let first = try XCTUnwrap(fixture.database.refinementDocument(reference: reference, cachedGeneration: nil))
        guard case let .document(generation, document) = first else { return XCTFail("Expected cold document") }
        XCTAssertEqual(document.text, "needle generation one")
        let warm = try XCTUnwrap(fixture.database.refinementDocument(reference: reference, cachedGeneration: generation))
        guard case .unchanged(let reused) = warm else { return XCTFail("Warm read must not materialize a document") }
        XCTAssertEqual(reused, generation)
        var wrong = reference
        wrong.sessionPath += ".wrong"
        XCTAssertNil(try fixture.database.refinementDocument(reference: wrong, cachedGeneration: generation))
        wrong = reference
        wrong.transcriptID = "wrong"
        XCTAssertNil(try fixture.database.refinementDocument(reference: wrong, cachedGeneration: generation))
        try fixture.database.replace(fixture.session(text: "needle generation two"))
        let changed = try XCTUnwrap(fixture.database.refinementDocument(reference: reference, cachedGeneration: generation))
        guard case let .document(next, nextDocument) = changed else { return XCTFail("Revision requires document") }
        XCTAssertGreaterThan(next, generation)
        XCTAssertEqual(nextDocument.text, "needle generation two")
    }

    func testConcurrentReplacementKeepsGenerationAndTextInOneSnapshot() async throws {
        let fixture = try makeFixture()
        try fixture.database.replace(fixture.session(text: "needle revision 1"))
        let reference = try fixture.reference(query: "needle")
        let database = fixture.database
        let template = fixture.session(text: "needle revision 1")
        let permitWrite = RevisionGate()
        let didWrite = RevisionGate()
        let writer = Task.detached {
            do {
                for index in 2...24 {
                    await permitWrite.wait(for: index)
                    try Task.checkCancellation()
                    var replacement = template
                    replacement.documents[0].text = "needle revision \(index)"
                    replacement.documents[0].messageSpans = []
                    let generation = try database.replace(replacement)
                    XCTAssertEqual(generation, Int64(index))
                    await didWrite.advance(to: index)
                }
            } catch {
                await didWrite.open()
                throw error
            }
        }

        func checkSnapshot(expectedGeneration: Int64? = nil) throws {
            let read = try XCTUnwrap(database.refinementDocument(reference: reference, cachedGeneration: nil))
            guard case let .document(generation, document) = read else {
                XCTFail("Expected document")
                throw FixtureError.unexpectedRead
            }
            if let expectedGeneration { XCTAssertEqual(generation, expectedGeneration) }
            XCTAssertEqual(document.text, "needle revision \(generation)")
        }
        do {
            try checkSnapshot(expectedGeneration: 1)
            for index in 2...24 {
                // Permit only one revision at a time. This read can overlap its writer, and the
                // acknowledged read must observe that revision before another write can begin.
                await permitWrite.advance(to: index)
                try checkSnapshot()
                await didWrite.wait(for: index)
                try checkSnapshot(expectedGeneration: Int64(index))
            }
            try await writer.value
        } catch {
            writer.cancel()
            await permitWrite.open()
            await didWrite.open()
            _ = try? await writer.value
            throw error
        }
    }

    func testQueryByteIdentityOptionsLocaleAndAlgorithmAreDistinctKeys() throws {
        let fixture = try makeFixture()
        try fixture.database.replace(fixture.session(text: "needle"))
        let reference = try fixture.reference(query: "needle")
        let base = ConversationSearchRefinementCache.Key(reference: reference, query: "é")
        var algorithm = base
        algorithm.algorithmVersion += 1
        let keys = [base, .init(reference: reference, query: "e\u{301}"),
                    .init(reference: reference, query: "É"),
                    .init(reference: reference, query: "é", options: [.caseInsensitive, .diacriticInsensitive]),
                    .init(reference: reference, query: "é", localeIdentifier: "tr_TR"), algorithm]
        XCTAssertEqual(Set(keys).count, keys.count)
        for (index, key) in keys.enumerated() {
            try fixture.cache.store(.noMatch, for: key, generation: Int64(index))
        }
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(fixture.cache.lookup(key)?.generation, Int64(index))
        }
    }

    func testLRUEvictionAndOversizedQueryOrSnippetNeverChangeReturnedSearchResults() throws {
        let cache = ConversationSearchRefinementCache(maximumBytes: 1_024, maximumEntries: 2,
                                                     maximumEntryBytes: 700)
        // Fixed synthetic identities isolate LRU policy from the host's TMPDIR path length.
        let reference = ConversationIndexDocumentReference(documentID: 1, sessionPath: "/fixture",
            transcriptID: "main", agentType: nil, sortOrder: 0, lastActivity: .distantPast)
        let alpha = ConversationSearchRefinementCache.Key(reference: reference, query: "alpha")
        let bravo = ConversationSearchRefinementCache.Key(reference: reference, query: "bravo")
        let charlie = ConversationSearchRefinementCache.Key(reference: reference, query: "charlie")
        try cache.store(.noMatch, for: alpha, generation: 1)
        try cache.store(.noMatch, for: bravo, generation: 1)
        XCTAssertNotNil(cache.lookup(alpha))
        try cache.store(.noMatch, for: charlie, generation: 1)
        XCTAssertLessThanOrEqual(cache.statistics.retainedBytes, 1_024)
        XCTAssertLessThanOrEqual(cache.statistics.entries, 2)
        XCTAssertNotNil(cache.lookup(alpha))
        XCTAssertNil(cache.lookup(bravo))
        let fixture = try makeFixture(cache: cache)
        let full = String(repeating: "长", count: 1_000) + "完整尾巴"
        try fixture.database.replace(fixture.session(text: full))
        let first = try XCTUnwrap(fixture.repository.search(query: full).first)
        let second = try XCTUnwrap(fixture.repository.search(query: full).first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snippet, full)
        let largeReference = try fixture.reference(query: full)
        XCTAssertNil(cache.lookup(.init(reference: largeReference, query: full)))
        XCTAssertLessThanOrEqual(cache.statistics.retainedBytes, 1_024)
    }

    func testCancelledNegativeResultCannotPoisonLaterSearch() async throws {
        let fixture = try makeFixture()
        try fixture.database.replace(fixture.session(text: "needle really exists"))
        let key = ConversationSearchRefinementCache.Key(reference: try fixture.reference(query: "needle"), query: "needle")
        let cache = fixture.cache
        let generation = try fixture.database.generation()
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try cache.store(.noMatch, for: key, generation: generation)
        }
        do {
            try await worker.value
            XCTFail("Cancelled matching must not become a cached noMatch")
        } catch is CancellationError {}
        XCTAssertNil(cache.lookup(key))
        XCTAssertEqual(try fixture.repository.search(query: "needle").first?.count, 1)
    }

    func testDocumentLocalAnswerRebindsMetadataAndParentAgent() throws {
        let fixture = try makeFixture()
        let answer = ConversationSearchRefinement.hit(transcriptID: "main", agentType: "explore",
            sequence: 42, snippet: "complete snippet", count: 3)
        var metadata = fixture.session(text: "unused").metadata
        let original = try XCTUnwrap(answer.hit(for: metadata, agentOverride: nil))
        XCTAssertEqual(original.agent, "main")
        metadata.sessionID = "new-parent"
        metadata.file = fixture.scope.appendingPathComponent("new-parent.jsonl")
        metadata.source = .qoder
        let rebound = try XCTUnwrap(answer.hit(for: metadata, agentOverride: "child-thread"))
        XCTAssertEqual(rebound.sessionID, "new-parent")
        XCTAssertEqual(rebound.file, metadata.file)
        XCTAssertEqual(rebound.source, .qoder)
        XCTAssertEqual(rebound.agent, "child-thread")
        XCTAssertEqual(rebound.agentType, "explore")
        XCTAssertEqual(rebound.sequence, 42)
        XCTAssertEqual(rebound.count, 3)
        XCTAssertEqual(rebound.snippet, "complete snippet")
    }

    private enum FixtureError: Error {
        case unexpectedRead
    }

    private actor RevisionGate {
        private var revision = 1
        private var isOpen = false
        private var waiters: [(revision: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait(for requested: Int) async {
            guard !isOpen, revision < requested else { return }
            await withCheckedContinuation { waiters.append((requested, $0)) }
        }

        func advance(to next: Int) {
            revision = max(revision, next)
            let ready = waiters.filter { $0.revision <= revision }
            waiters.removeAll { $0.revision <= revision }
            for waiter in ready { waiter.continuation.resume() }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.continuation.resume() }
        }
    }

    private func makeFixture(cache: ConversationSearchRefinementCache = .init()) throws -> Fixture {
        let fixture = try Fixture(cache: cache)
        // Teardown runs after test locals and awaited task handles have released their DB copies.
        // Keep the fixture alive until then, close both owned connections, and only then unlink.
        addTeardownBlock { try fixture.cleanup() }
        return fixture
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let scope: URL
        let otherScope: URL
        private var databaseStorage: ConversationIndexDatabase?
        private var repositoryStorage: IndexedHistoryRepository?
        var database: ConversationIndexDatabase { databaseStorage! }
        var repository: IndexedHistoryRepository { repositoryStorage! }
        let cache: ConversationSearchRefinementCache

        init(cache: ConversationSearchRefinementCache = .init()) throws {
            root = try HistoryTestSupport.temporaryDirectory("exact-refinement-cache")
            scope = root.appendingPathComponent("history")
            otherScope = root.appendingPathComponent("other-history")
            self.cache = cache
            let database = try ConversationIndexDatabase(file: root.appendingPathComponent("index.sqlite3"),
                enableTgrep: false, searchRefinementCache: cache)
            databaseStorage = database
            repositoryStorage = IndexedHistoryRepository(configuration: .init(
                historyDirs: [scope.path, otherScope.path], homeDirectory: root,
                importsRoot: root.appendingPathComponent("imports")), database: database)
        }

        func cleanup() throws {
            repositoryStorage = nil
            databaseStorage = nil
            try FileManager.default.removeItem(at: root)
        }

        func reference(query: String) throws -> ConversationIndexDocumentReference {
            try XCTUnwrap(database.candidateDocumentReferences(for: query).references.first)
        }

        func session(text: String, sequence: Int = 0) -> ConversationIndexedSession {
            let metadata = HistorySessionMetadata(id: "session", file: scope.appendingPathComponent("session.jsonl"),
                source: .claude, dirID: scope.path, dirLabel: "History", sessionID: "session",
                cwd: "/fixture", project: "Fixture", title: "Fixture", autoTitle: "Fixture",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                lastActivity: Date(timeIntervalSince1970: 1_800_000_000), sizeBytes: UInt64(text.utf8.count))
            return ConversationIndexedSession(metadata: metadata,
                fingerprint: .init(modificationTime: metadata.lastActivity, sizeBytes: metadata.sizeBytes),
                documents: [.init(transcriptID: "main", sortOrder: 0, text: text, messageSpans: [
                    .init(sequence: sequence, messageIndex: sequence, utf16Location: 0,
                          utf16Length: text.utf16.count, role: "assistant"),
                ])])
        }
    }
}
