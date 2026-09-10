import Foundation
import XCTest
@testable import CCBuddy

final class ConversationHotSearchCoverageTests: XCTestCase {
    func testPreparedSearchFindsOpenableSessionBeyondVisibleLibraryLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let query = "archivecoverageneedle"
        let target = try fixture.writeSession(name: "old-target", text: "\(query) and \(query)")
        _ = try fixture.scanner.scanAll()
        let targetEntry = try XCTUnwrap(fixture.database.entry(for: target))
        XCTAssertNotNil(try ConversationSourceSearchCoverage.verifiedCatalogSource(
            loader: fixture.loader, entry: targetEntry))

        // These are legitimate metadata-only catalog rows with unique canonical identities.
        // No full parse or pack is needed to put the real target beyond the visible row budget.
        // Keep each publication below macOS's usual 256-descriptor soft limit: metadata
        // publication intentionally holds a leased descriptor for every prepared header.
        let fillerCount = ConversationCatalogLimits.searchScan + 1
        let fillers = (0..<fillerCount).map { ordinal -> ConversationIndexedSession in
            var metadata = targetEntry.metadata
            let identity = String(format: "00000000-0000-4000-8000-%012x", ordinal)
            metadata.file = fixture.root.appendingPathComponent("sessions/filler-\(ordinal).jsonl")
            metadata.id = "codex:\(fixture.root.path):filler-\(ordinal)"
            metadata.sessionID = identity
            metadata.threadID = identity
            metadata.rootSessionID = identity
            metadata.canonicalThreadIDValid = true
            metadata.title = "Synthetic metadata row \(ordinal)"
            metadata.autoTitle = metadata.title
            metadata.lastActivity = targetEntry.metadata.lastActivity.addingTimeInterval(Double(ordinal + 1))
            metadata.sizeBytes = 0
            metadata.messageCount = 0
            return ConversationIndexedSession(metadata: metadata,
                fingerprint: .init(modificationTime: metadata.lastActivity, sizeBytes: 0), documents: [])
        }
        for start in stride(from: 0, to: fillers.count, by: 64) {
            try fixture.database.replaceMetadata(Array(fillers[start..<min(start + 64, fillers.count)]))
        }
        let repository = fixture.repository
        let visible = try repository.listSessions(limit: ConversationCatalogLimits.searchScan)
        XCTAssertEqual(visible.count, ConversationCatalogLimits.searchScan)
        XCTAssertFalse(visible.contains { $0.file == target })
        XCTAssertEqual(try fixture.database.listEntries(limit: .max).count, fillerCount + 1)
        try await fixture.prepare(query: query, expectedPaths: [target])

        let events = HotSearchCoverageEvents()
        let hits = try repository.search(query: query, limit: 20) { events.append($0) }
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.file, target)
        XCTAssertEqual(hit.count, 2)
        XCTAssertTrue(hit.isCountComplete)
        XCTAssertEqual(events.values.last?.phase, .completed)
        XCTAssertEqual(events.values.last?.hits, hits)
        let firstVisible = try XCTUnwrap(events.values.first { !$0.hits.isEmpty }?.hits.first)
        XCTAssertEqual(firstVisible.file, target)
        XCTAssertNotNil(firstVisible.sourceMetadata,
            "A search-only row must be independently displayable before list hydration")
        let metadata = try XCTUnwrap(hit.sourceMetadata)
        XCTAssertEqual(metadata.file, target)
        XCTAssertEqual(metadata.sessionID, targetEntry.metadata.sessionID)
        XCTAssertEqual(try repository.getSession(file: metadata.file).metadata.sessionID, metadata.sessionID)
        XCTAssertEqual(try repository.search(query: query, limit: 20), hits,
            "Final-only search must not apply the visible library's 5,000-row limit either")
    }

    func testPreparedCandidatesNeverLeakIntoRevokedScopedOrTrashProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let query = "scopeguardneedle"
        let target = try fixture.writeSession(name: "authorized-target", text: query)
        _ = try fixture.scanner.scanAll()
        try await fixture.prepare(query: query, expectedPaths: [target])
        XCTAssertEqual(try fixture.repository.search(query: query, limit: 20).map(\.file), [target])

        var revokedConfiguration = fixture.loader.configuration
        revokedConfiguration.historyDirs = [fixture.otherRoot.path]
        let revoked = IndexedHistoryRepository(configuration: revokedConfiguration, database: fixture.database)
        let scoped = try XCTUnwrap(fixture.repository.scoped(to: fixture.otherRoot.path) as? IndexedHistoryRepository)
        let trash = try XCTUnwrap(fixture.repository.scoped(to: "__trash__") as? IndexedHistoryRepository)
        for (label, repository) in [("revoked root", revoked), ("other scope", scoped), ("trash", trash)] {
            let events = HotSearchCoverageEvents()
            let hits = try repository.search(query: query, limit: 20) { events.append($0) }
            XCTAssertTrue(hits.isEmpty, label)
            XCTAssertFalse(events.values.isEmpty, label)
            XCTAssertTrue(events.values.allSatisfy { $0.hits.isEmpty },
                "Even a temporary prepared candidate is a leak into \(label)")
            XCTAssertEqual(events.values.last?.phase, .completed, label)
            XCTAssertTrue(try repository.search(query: query, limit: 20).isEmpty, label)
        }
    }

    func testPreparedChildWaitsForUnknownParentAndNeverAppearsAsStandaloneHit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parentID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let childID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let query = "ownedchildneedle"
        let child = try fixture.writeSession(name: "child", id: childID, text: query, parentID: parentID)
        _ = try fixture.scanner.scanAll()
        let childEntry = try XCTUnwrap(fixture.database.entry(for: child))
        XCTAssertEqual(childEntry.metadata.parentThreadID, parentID)
        XCTAssertTrue(childEntry.metadata.isSubagent)
        try await fixture.prepare(query: query, expectedPaths: [child])

        // The child is already a hot posting candidate, but ownership can only be resolved
        // after source discovery sees this parent. No catalog revision is published here.
        let revision = try fixture.database.generation()
        let parent = try fixture.writeSession(name: "parent", id: parentID, text: "Parent conversation")
        XCTAssertNil(try fixture.database.entry(for: parent))
        XCTAssertNotNil(try ConversationSourceSearchCoverage.verifiedCatalogSource(
            loader: fixture.loader, entry: childEntry))
        let events = HotSearchCoverageEvents()
        let hits = try fixture.repository.search(query: query, limit: 20) { events.append($0) }
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.file, parent)
        XCTAssertEqual(hit.sessionID, parentID)
        XCTAssertEqual(hit.agent, childID)
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit.sequence, 0)
        let visibleHits = events.values.flatMap(\.hits)
        XCTAssertFalse(visibleHits.isEmpty)
        XCTAssertTrue(visibleHits.allSatisfy { $0.file == parent && $0.agent == childID },
            "A child cannot be exposed under its own row while its parent's metadata is discovered")
        let metadata = try XCTUnwrap(hit.sourceMetadata)
        XCTAssertEqual(metadata.file, parent)
        XCTAssertEqual(metadata.subagentRefs.map(\.file), [child])
        XCTAssertEqual(try fixture.repository.getSession(file: metadata.file).metadata.sessionID, parentID)
        XCTAssertEqual(try fixture.repository.getSession(file: child).metadata.sessionID, childID)
        XCTAssertEqual(events.values.last?.phase, .completed)
        XCTAssertEqual(events.values.last?.hits, hits)
        XCTAssertEqual(try fixture.database.generation(), revision,
            "Query-time parent discovery must not wait for or publish a catalog replacement")
        XCTAssertEqual(try fixture.repository.search(query: query, limit: 20), hits)
    }

    private struct Fixture: Sendable {
        let home: URL
        let root: URL
        let otherRoot: URL
        let loader: HistorySessionLoader
        let database: ConversationFileCatalog

        init() throws {
            home = try HistoryTestSupport.temporaryDirectory("hot-search-coverage")
            root = home.appendingPathComponent(".codex")
            otherRoot = home.appendingPathComponent("other-agent")
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            loader = HistorySessionLoader(historyDirs: [root.path, otherRoot.path], homeDirectory: home)
            database = try ConversationFileCatalog(file: home.appendingPathComponent("catalog"))
        }

        var repository: IndexedHistoryRepository {
            .init(configuration: loader.configuration, database: database, loader: loader)
        }

        var scanner: ConversationIndexScanner {
            .init(configuration: loader.configuration, database: database, loader: loader,
                  reparseSpacing: .immediate)
        }

        func writeSession(name: String, id: String = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                          text: String, parentID: String? = nil) throws -> URL {
            let content = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
            let ownership = parentID.map {
                #","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#($0)","depth":1}}}"#
            } ?? ""
            return try HistoryTestSupport.write([
                #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/synthetic"\#(ownership)}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":\#(content)}]}}"#,
            ], to: root.appendingPathComponent("sessions/\(name).jsonl"),
                modifiedAt: Date(timeIntervalSince1970: 1_000))
        }

        func prepare(query: String, expectedPaths: Set<URL>) async throws {
            XCTAssertTrue(TgrepSearchIndex.isAvailable, "Hot-path coverage requires the packaged tgrep library")
            database.scheduleSearchIndexPreparation()
            await database.waitForSearchIndexPreparation()
            let candidates = try database.candidateDocumentReferences(for: query)
            XCTAssertEqual(database.searchDiagnostics.engine, "tgrep")
            XCTAssertFalse(candidates.usedFallback)
            XCTAssertEqual(Set(candidates.references.map { URL(fileURLWithPath: $0.sessionPath) }), expectedPaths)
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}

private final class HotSearchCoverageEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConversationSearchProgress] = []
    func append(_ event: ConversationSearchProgress) { lock.withLock { events.append(event) } }
    var values: [ConversationSearchProgress] { lock.withLock { events } }
}
