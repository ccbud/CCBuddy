import Foundation
import XCTest
@testable import CCBuddy

final class ConversationSourceSearchRepositoryTests: XCTestCase {
    func testSearchMetadataFallbackChecksCancellationBeforeReadingLargeFirstRecord() async throws {
        let fixture = try Fixture(lines: [])
        defer { fixture.remove() }
        try Data((message(String(repeating: "x", count: 600_000)) + "\n").utf8).write(to: fixture.file)
        let candidate = try fixture.loader.pathResolver.validatedCandidate(for: fixture.file)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.loader.loadSearchMetadata([candidate])
        }
        do { _ = try await worker.value; XCTFail("Cancelled metadata fallback cannot publish a source") }
        catch is CancellationError {}
    }

    func testSearchMetadataFallbackRejectsAnUnconfiguredCandidateBeforeItsPreview() throws {
        let fixture = try Fixture(lines: [])
        defer { fixture.remove() }
        var candidate = try fixture.loader.pathResolver.validatedCandidate(for: fixture.file)
        candidate.file = try HistoryTestSupport.write([message("outside-root-needle")],
            to: fixture.home.appendingPathComponent("not-configured/sessions/outside.jsonl"))
        XCTAssertThrowsError(try fixture.loader.loadSearchMetadata([candidate]))
    }

    func testUnknownCodexLargeFirstRecordWithoutStateOrMetadataHeaderIsSearchable() throws {
        let fixture = try Fixture(lines: [])
        defer { fixture.remove() }
        let line = message(String(repeating: "x", count: 600_000) + " firstrecordneedle")
        try Data((line + "\n").utf8).write(to: fixture.file, options: .atomic)
        let candidate = try fixture.loader.pathResolver.validatedCandidate(for: fixture.file)
        XCTAssertTrue(fixture.loader.loadQuickMetadata([candidate]).isEmpty,
            "This source intentionally cannot fit the scanner's bounded metadata preview")
        XCTAssertTrue(try fixture.database.listEntries(limit: .max).isEmpty)
        let hit = try XCTUnwrap(fixture.repository.search(query: "firstrecordneedle", limit: 20).first)
        XCTAssertEqual(hit.sequence, 0)
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit.file, fixture.file)
        XCTAssertEqual(hit.sessionID, try fixture.loader.getSession(file: fixture.file).metadata.sessionID)
    }

    func testUnknownClaudeLargeFirstRecordWithoutHeaderIsSearchableAndOpenable() throws {
        let home = try HistoryTestSupport.temporaryDirectory("claude-large-first-record")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude")
        let content = String(decoding: try JSONEncoder().encode(
            String(repeating: "x", count: 600_000) + " 系统代理 firstrecordneedle"), as: UTF8.self)
        let file = try HistoryTestSupport.write([
            #"{"type":"user","sessionId":"large-first-record","message":{"role":"user","content":\#(content)}}"#,
        ], to: root.appendingPathComponent("projects/-synthetic/large.jsonl"))
        let loader = HistorySessionLoader(historyDirs: [root.path], homeDirectory: home)
        let candidate = try loader.pathResolver.validatedCandidate(for: file)
        XCTAssertTrue(loader.loadQuickMetadata([candidate]).isEmpty)
        let database = try ConversationFileCatalog(file: home.appendingPathComponent("catalog"), enableTgrep: false)
        let repository = IndexedHistoryRepository(configuration: loader.configuration, database: database, loader: loader)
        let hit = try XCTUnwrap(repository.search(query: "系统代理", limit: 20).first)
        XCTAssertEqual(hit.file, file)
        XCTAssertEqual(hit.source, .claude)
        XCTAssertEqual(hit.sessionID, "large-first-record")
        XCTAssertEqual(hit.sequence, 0)
        XCTAssertEqual(hit.count, 1)
        XCTAssertNotNil(hit.sourceMetadata)
        XCTAssertEqual(try repository.getSession(file: file).messages.count, 1)
    }

    func testDirtySourceCountsAreDeferredUntilLaterCatalogHitHasBeenPublished() throws {
        let fixture = try Fixture(lines: [message("old needle")])
        defer { fixture.remove() }
        let hot = fixture.file.deletingLastPathComponent().appendingPathComponent("hot.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session_meta","payload":{"id":"hot-source"}}"#,
            message("catalog needle"),
        ], to: hot, modifiedAt: Date(timeIntervalSince1970: 10))
        _ = try fixture.scanner().scanAll()
        try fixture.write([message("needle " + String(repeating: "x", count: 320_000) + " needle")])
        let recorder = SourceSearchEvents()
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.append($0) }
        XCTAssertEqual(recorder.values.first(where: { !$0.hits.isEmpty })?.hits.map(\.file), [hot],
            "An older proven pack is usable before the newer dirty source's first-record scan")
        let firstBoth = try XCTUnwrap(recorder.values.first { $0.hits.count == 2 })
        XCTAssertEqual(firstBoth.hits.map(\.file), [fixture.file, hot])
        XCTAssertFalse(firstBoth.hits[0].isCountComplete,
            "A dirty source must not finish its entire count before subsequent catalog identities appear")
        XCTAssertEqual(firstBoth.hits[0].count, 1)
        XCTAssertEqual(hits.map(\.count), [2, 1])
        XCTAssertTrue(hits.allSatisfy(\.isCountComplete))
    }

    func testHotHitPublishesBeforeUnknownLargeFirstRecordMetadataIsRead() throws {
        let fixture = try Fixture(lines: [message("hot needle")])
        defer { fixture.remove() }
        _ = try fixture.scanner().scanAll()
        let unknown = fixture.file.deletingLastPathComponent().appendingPathComponent("unknown.jsonl")
        try Data((message(String(repeating: "x", count: 600_000)) + "\n").utf8).write(to: unknown)
        let replacement = Data((#"{"type":"session_meta","payload":{"id":"unknown-owner"}}"#
            + "\n" + message("unknown needle") + "\n").utf8)
        let recorder = SourceRewriteEvents(file: unknown, replacement: replacement)
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }
        XCTAssertEqual(recorder.values.first(where: { !$0.hits.isEmpty })?.hits.map(\.file), [fixture.file])
        XCTAssertEqual(Set(hits.map(\.file)), [fixture.file, unknown])
        XCTAssertEqual(Set(recorder.values.compactMap(\.snapshotAttempt)).count, 1,
            "Unknown metadata was sampled after the callback's rewrite, not before the first hot result")
        XCTAssertNil(recorder.writeError)
    }

    func testDiscoveryImmediatelyRetiresARewrittenFastAnchorBeforeRawVerification() throws {
        let fixture = try Fixture(lines: [message("old needle anchor")])
        defer { fixture.remove() }
        _ = try fixture.scanner().scanAll()
        let recorder = SourceRewriteEvents(file: fixture.file,
            replacement: fixture.encoded([message(String(repeating: "x", count: 600_000) + " new needle anchor")]))
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }
        let events = recorder.values
        let first = try XCTUnwrap(events.firstIndex { !$0.hits.isEmpty })
        XCTAssertTrue(events[first].hits[0].snippet.contains("old needle"))
        XCTAssertTrue(events.indices.contains(first + 1))
        XCTAssertEqual(events[first + 1].phase, .preparingCandidates)
        XCTAssertTrue(events[first + 1].hits.isEmpty,
            "A disproved fast anchor is revoked at discovery, not after reading a large replacement")
        XCTAssertNotEqual(events[first].snapshotAttempt, events[first + 1].snapshotAttempt)
        XCTAssertTrue(try XCTUnwrap(hits.first).snippet.contains("new needle"))
        XCTAssertEqual(Set(events.compactMap(\.snapshotAttempt)).count, 2)
        XCTAssertNil(recorder.writeError)
    }

    func testLateHigherRankSourceExplicitlyRetiresFastHitOutsideFinalResultLimit() throws {
        let fixture = try Fixture(lines: [message("dirty old needle")])
        defer { fixture.remove() }
        let hot = fixture.file.deletingLastPathComponent().appendingPathComponent("hot.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session_meta","payload":{"id":"hot-owner"}}"#,
            message("hot needle"),
        ], to: hot, modifiedAt: Date(timeIntervalSince1970: 10))
        _ = try fixture.scanner().scanAll()
        try fixture.write([message(String(repeating: "x", count: 160_000) + " dirty needle")])
        let recorder = SourceSearchEvents()
        let hits = try fixture.repository.search(query: "needle", limit: 1) { recorder.append($0) }
        XCTAssertEqual(recorder.values.first(where: { !$0.hits.isEmpty })?.hits.map(\.file), [hot])
        XCTAssertEqual(hits.map(\.file), [fixture.file])
        XCTAssertTrue(recorder.values.allSatisfy { $0.hits.count <= 1 })
        XCTAssertEqual(Set(recorder.values.compactMap(\.snapshotAttempt)).count, 2)
        var state = ConversationSearchProgressState()
        for (index, event) in recorder.values.enumerated() { state.receive(event, ordinal: UInt64(index + 1)) }
        XCTAssertEqual(state.hits.map(\.file), [fixture.file])
        XCTAssertEqual(hits, try fixture.repository.search(query: "needle", limit: 1))
    }

    func testRepeatedUnchangedRawQueryReusesOnlyCompletedBoundedAnswer() throws {
        let fixture = try Fixture(lines: [message("cacheneedle " + String(repeating: "x", count: 150_000)
            + " cacheneedle")])
        defer { fixture.remove() }
        let first = try fixture.repository.search(query: "cacheneedle", limit: 20)
        let initial = fixture.database.searchRefinementCache.statistics
        XCTAssertEqual(initial.stores, 1)
        let recorder = SourceSearchEvents()
        let second = try fixture.repository.search(query: "cacheneedle", limit: 20) { recorder.append($0) }
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.first?.count, 2)
        XCTAssertTrue(recorder.values.flatMap(\.hits).allSatisfy(\.isCountComplete))
        let cached = fixture.database.searchRefinementCache.statistics
        XCTAssertEqual(cached.stores, initial.stores)
        XCTAssertEqual(cached.validatedHits, initial.validatedHits + 1)
        XCTAssertLessThan(cached.retainedBytes, 16_384, "The answer cache does not retain transcript text")
    }

    func testAtomicSameSizeSameMtimeReplacementCannotReuseOldRawAnswer() throws {
        let fixture = try Fixture(lines: [message("cacheold")])
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.repository.search(query: "cacheold", limit: 20).count, 1)
        let original = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        let modified = try XCTUnwrap(original[.modificationDate] as? Date)
        try fixture.write([message("cachenew")])
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fixture.file.path)
        let replacement = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        XCTAssertEqual(original[.size] as? NSNumber, replacement[.size] as? NSNumber)
        XCTAssertNotEqual(original[.systemFileNumber] as? NSNumber, replacement[.systemFileNumber] as? NSNumber)
        XCTAssertTrue(try fixture.repository.search(query: "cacheold", limit: 20).isEmpty)
        XCTAssertEqual(try fixture.repository.search(query: "cachenew", limit: 20).count, 1)
        XCTAssertEqual(fixture.database.searchRefinementCache.statistics.validatedHits, 0)
    }

    func testMetadataSidecarChangeRebindsRawAnswerAndInvalidatesDependencyKey() throws {
        let fixture = try Fixture(lines: [message("cacheneedle")])
        defer { fixture.remove() }
        let first = try XCTUnwrap(fixture.repository.search(query: "cacheneedle", limit: 20).first)
        let sidecar = fixture.loader.configuration.appDataRoot.appendingPathComponent("codex-meta.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"main":{"title":"Updated synthetic title"}}"#.utf8).write(to: sidecar)
        let second = try XCTUnwrap(fixture.repository.search(query: "cacheneedle", limit: 20).first)
        XCTAssertEqual(second.count, first.count)
        XCTAssertEqual(second.sourceMetadata?.title, "Updated synthetic title")
        XCTAssertNotEqual(second.sourceMetadata?.title, first.sourceMetadata?.title)
        XCTAssertEqual(try fixture.database.generation(), 0, "Metadata changes did not need a catalog mutation")
        XCTAssertEqual(fixture.database.searchRefinementCache.statistics.validatedHits, 0)
        XCTAssertEqual(fixture.database.searchRefinementCache.statistics.stores, 2)
    }

    func testVisibleQuickRowIsSearchableWhileInitialFullParseIsBlocked() async throws {
        let fixture = try Fixture(lines: [message(String(repeating: "x", count: 350_000)),
            message("decoded 系统代理 after quick metadata prefix")])
        defer { fixture.remove() }
        let gate = SourceSearchLoaderGate(loader: fixture.loader)
        let scanner = ConversationIndexScanner(configuration: fixture.loader.configuration,
            database: fixture.database, loader: gate)
        let worker = Task.detached { try scanner.scanAll() }
        defer { gate.release.signal() }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try fixture.repository.listSessions(limit: 20).count, 1)
        let sentinel = try XCTUnwrap(fixture.database.entry(for: fixture.file))
        XCTAssertTrue(sentinel.fingerprint.dependencyFingerprint?.hasPrefix("quick:") == true)
        let recorder = SourceSearchEvents()
        let hits = try fixture.repository.search(query: "系统代理", limit: 20) { recorder.append($0) }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sequence, 1)
        XCTAssertEqual(hits.first?.count, 1)
        XCTAssertTrue(hits.allSatisfy(\.isCountComplete))
        XCTAssertEqual(recorder.values.last?.phase, .completed)
        XCTAssertEqual(recorder.values.last?.diagnostics?.fallbackReason, "sourceVerification")
        XCTAssertNotNil(hits.first?.sourceMetadata)
        XCTAssertEqual(try fixture.database.entry(for: fixture.file)?.fingerprint, sentinel.fingerprint,
            "Foreground verification does not publish or wait for a new body pack")
        gate.release.signal()
        _ = try await worker.value
    }

    func testDeferredLiveAppendSearchesFreshDecodedTextAndDoesNotDoubleCountOldPack() throws {
        let fixture = try Fixture(lines: [message("old sharedneedle")])
        defer { fixture.remove() }
        let scanner = ConversationIndexScanner(configuration: fixture.loader.configuration,
            database: fixture.database, reparseSpacing: .init(minimum: 60, maximum: 60, secondsPerByte: 0))
        _ = try scanner.scanAll()
        try append([message("new sharedneedle \u{7cfb}统代理 sharedneedle")], to: fixture.file)
        _ = try scanner.scan(changedPaths: [fixture.file])
        XCTAssertNotNil(scanner.deferredReparse, "This fixture intentionally keeps the old catalog body")
        XCTAssertEqual(try fixture.repository.search(query: "系统代理", limit: 20).first?.sequence, 1)
        XCTAssertEqual(try fixture.repository.search(query: "sharedneedle", limit: 20).first?.count, 3,
            "Raw verification replaces the old body, rather than adding the old pack count")
    }

    func testRawReplacementIsVerifiedEvenBeforeWatcherPublishesAnyCatalogRevision() throws {
        let fixture = try Fixture(lines: [message("removedneedle")])
        defer { fixture.remove() }
        _ = try fixture.scanner().scanAll()
        let revision = try fixture.database.generation()
        try fixture.write([message("replacementneedle")])
        XCTAssertTrue(try fixture.repository.search(query: "removedneedle", limit: 20).isEmpty)
        XCTAssertEqual(try fixture.repository.search(query: "replacementneedle", limit: 20).first?.count, 1)
        XCTAssertEqual(try fixture.database.generation(), revision)
    }

    func testRewriteDuringProgressRetriesWithoutOldPrefixOrFalseComplete() throws {
        let fixture = try Fixture(lines: [message("needle " + String(repeating: "x", count: 240_000))])
        defer { fixture.remove() }
        let recorder = SourceRewriteEvents(file: fixture.file,
            replacement: fixture.encoded([message("no matching content")]))
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }
        XCTAssertTrue(hits.isEmpty)
        let events = recorder.values
        XCTAssertTrue(events.contains { !$0.hits.isEmpty })
        XCTAssertEqual(events.filter { $0.phase == .completed }.count, 1)
        XCTAssertTrue(events.last?.hits.isEmpty == true)
        XCTAssertEqual(Set(events.compactMap(\.snapshotRevision)).count, 1)
        XCTAssertEqual(Set(events.compactMap(\.snapshotAttempt)).count, 2)
        var state = ConversationSearchProgressState()
        for (index, event) in events.enumerated() { state.receive(event, ordinal: UInt64(index + 1)) }
        XCTAssertTrue(state.hits.isEmpty, "A source rewrite with unchanged catalog revision retires the prefix")
        XCTAssertNil(recorder.writeError)
    }

    func testCancelledRawSourceSearchCannotPublishCompletedEvent() async throws {
        let fixture = try Fixture(lines: [message("needle " + String(repeating: "x", count: 240_000))])
        defer { fixture.remove() }
        let recorder = SourceSearchEvents()
        let worker = Task.detached {
            try fixture.repository.search(query: "needle", limit: 20) { event in
                recorder.append(event)
                if !event.hits.isEmpty { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await worker.value; XCTFail("Cancelled source search cannot finish") }
        catch is CancellationError {}
        XCTAssertFalse(recorder.values.contains { $0.phase == .completed })
        XCTAssertEqual(fixture.database.searchRefinementCache.statistics.stores, 0,
            "Cancellation never stores a partial count or a negative answer")
    }

    func testRepeatedRewritesRetireTheLastKnownInvalidPrefixBeforeTerminalFailure() throws {
        let fixture = try Fixture(lines: [message("needle original")])
        defer { fixture.remove() }
        let recorder = RepeatedSourceRewriteEvents(file: fixture.file,
            replacements: (1...3).map { fixture.encoded([message("needle replacement \($0)")]) })
        XCTAssertThrowsError(try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }) {
            guard case ConversationCatalogError.staleRevision = $0 else {
                return XCTFail("Expected terminal source revision invalidation, got \(type(of: $0))")
            }
        }
        let events = recorder.values
        XCTAssertEqual(recorder.writeCount, 3)
        XCTAssertNil(recorder.writeError)
        XCTAssertEqual(events.filter { $0.phase == .completed }.count, 0)
        XCTAssertEqual(Set(events.compactMap(\.snapshotAttempt)).count, 4,
            "Three failed reads must be followed by a distinct terminal retirement epoch")
        XCTAssertEqual(events.last?.phase, .preparingCandidates)
        XCTAssertTrue(events.last?.hits.isEmpty == true)
        XCTAssertTrue(events.contains { !$0.hits.isEmpty })
        var state = ConversationSearchProgressState()
        for (index, event) in events.enumerated() { state.receive(event, ordinal: UInt64(index + 1)) }
        XCTAssertTrue(state.hits.isEmpty, "Exhausted retries cannot leave a known-invalid anchor clickable")
    }

    func testRetryDropsCachedCatalogEntriesAndPrimitivesAfterGenerationChange() throws {
        let fixture = try Fixture(lines: [message("needle old generation")])
        defer { fixture.remove() }
        _ = try fixture.scanner().scanAll()
        let generation = try fixture.database.generation()
        let recorder = SourceRewriteEvents(file: fixture.file,
            replacement: fixture.encoded([message("needle new generation needle")]),
            triggerPhase: .countingOccurrences, afterReplacement: { _ = try fixture.scanner().scanAll() })
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.count, 2)
        XCTAssertTrue(hits.first?.snippet.contains("new generation") == true)
        XCTAssertGreaterThan(try fixture.database.generation(), generation)
        XCTAssertGreaterThanOrEqual(Set(recorder.values.compactMap(\.snapshotRevision)).count, 2)
        XCTAssertEqual(recorder.values.last?.hits, hits)
        XCTAssertNil(recorder.writeError)
    }

    func testRetryRechecksTrashSidecarWithoutReusingOldVisibleOwnerFromCachedEntries() throws {
        let fixture = try Fixture(lines: [message("needle trashed while counting")])
        defer { fixture.remove() }
        _ = try fixture.scanner().scanAll()
        let generation = try fixture.database.generation()
        let sidecar = fixture.loader.configuration.appDataRoot.appendingPathComponent("codex-meta.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recorder = SourceRewriteEvents(file: sidecar, replacement: Data(#"{"main":{"delete":true}}"#.utf8),
            triggerPhase: .countingOccurrences)
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }
        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(try fixture.database.generation(), generation)
        XCTAssertEqual(Set(recorder.values.compactMap(\.snapshotAttempt)).count, 2)
        XCTAssertTrue(recorder.values.last?.hits.isEmpty == true)
        XCTAssertNil(recorder.writeError)
        let trash = try XCTUnwrap(fixture.repository.scoped(to: "__trash__") as? IndexedHistoryRepository)
        XCTAssertEqual(try trash.search(query: "needle", limit: 20).first?.count, 1,
            "A query-local active-scope retry cache is never shared with a later trash search")
    }

    func testUnknownSourceSearchDiscoversOnlyConfiguredRootsAndReturnsOpenableMetadata() throws {
        let fixture = try Fixture(lines: [message("newsourceonly")])
        defer { fixture.remove() }
        try HistoryTestSupport.write([message("unconfiguredneedle")],
            to: fixture.home.appendingPathComponent("not-configured/sessions/private.jsonl"))
        XCTAssertTrue(try fixture.repository.listSessions(limit: 20).isEmpty)
        let hit = try XCTUnwrap(fixture.repository.search(query: "newsourceonly", limit: 20).first)
        XCTAssertEqual(hit.file, fixture.file)
        XCTAssertNotNil(hit.sourceMetadata)
        XCTAssertFalse(try fixture.repository.getSession(file: hit.file).messages.isEmpty)
        XCTAssertTrue(try fixture.repository.search(query: "unconfiguredneedle", limit: 20).isEmpty)
        XCTAssertTrue(try fixture.database.listEntries(limit: .max).isEmpty)
    }

    func testUnknownCodexChildHitIsOwnedByParentAndOpensExactLazyTab() throws {
        let parent = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let child = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let fixture = try Fixture(lines: [message("parent contents")], id: parent)
        defer { fixture.remove() }
        let file = fixture.file.deletingLastPathComponent().appendingPathComponent("child.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session_meta","payload":{"id":"\#(child)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1}}}}}"#,
            message("childonlyneedle"),
        ], to: file)
        let hit = try XCTUnwrap(fixture.repository.search(query: "childonlyneedle", limit: 20).first)
        XCTAssertEqual(hit.file, fixture.file)
        XCTAssertEqual(hit.agent, child)
        XCTAssertEqual(hit.sequence, 0)
        XCTAssertEqual(hit.sourceMetadata?.subagentRefs.map(\.file), [file])
    }

    func testCleanChildRewrittenAfterOwnedCatalogHitCannotCompleteWithStaleAnchor() throws {
        let parent = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let child = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let fixture = try Fixture(lines: [message("parent contents")], id: parent)
        defer { fixture.remove() }
        let file = fixture.file.deletingLastPathComponent().appendingPathComponent("child.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(child)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1}}}}}"#
        try HistoryTestSupport.write([header, message("old childonlyneedle")], to: file)
        _ = try fixture.scanner().scanAll()
        let recorder = SourceRewriteEvents(file: file,
            replacement: Data((header + "\n" + message("replacement with no old term") + "\n").utf8))
        let hits = try fixture.repository.search(query: "childonlyneedle", limit: 20) { recorder.receive($0) }
        let first = try XCTUnwrap(recorder.values.first(where: { !$0.hits.isEmpty })?.hits.first)
        XCTAssertEqual(first.file, fixture.file)
        XCTAssertEqual(first.agent, child)
        XCTAssertTrue(hits.isEmpty, "A clean child is also part of the final source proof set")
        XCTAssertEqual(Set(recorder.values.compactMap(\.snapshotAttempt)).count, 2)
        XCTAssertEqual(recorder.values.filter { $0.phase == .completed }.count, 1)
        XCTAssertTrue(recorder.values.last?.hits.isEmpty == true)
        XCTAssertNil(recorder.writeError)
    }

    func testPriorCatalogCallbackCannotExposeAChildWhoseCoverageProofWasRewritten() throws {
        let parent = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let child = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let fixture = try Fixture(lines: [message("parent contents")], id: parent)
        defer { fixture.remove() }
        let file = fixture.file.deletingLastPathComponent().appendingPathComponent("child.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(child)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1}}}}}"#
        try HistoryTestSupport.write([header, message("old child needle")], to: file)
        let other = fixture.file.deletingLastPathComponent().appendingPathComponent("other.jsonl")
        try HistoryTestSupport.write([
            #"{"type":"session_meta","payload":{"id":"other-owner"}}"#,
            message("other needle"),
        ], to: other, modifiedAt: Date(timeIntervalSince1970: 4_000_000_000))
        _ = try fixture.scanner().scanAll()
        // An unavailable source retains its committed catalog snapshot, but cannot pass the
        // fast source gate. Its first callback therefore runs AFTER full coverage collection.
        try FileManager.default.removeItem(at: other)
        let recorder = SourceRewriteEvents(file: file,
            replacement: Data((header + "\n" + message("replacement contents") + "\n").utf8))
        let hits = try fixture.repository.search(query: "needle", limit: 20) { recorder.receive($0) }
        XCTAssertEqual(hits.map(\.file), [other])
        XCTAssertTrue(recorder.values.flatMap(\.hits).allSatisfy { $0.file == other },
            "A child proof changed by an earlier callback must be checked before publishing that child")
        XCTAssertEqual(Set(recorder.values.compactMap(\.snapshotAttempt)).count, 2)
        XCTAssertNil(recorder.writeError)
    }

    func testNonStreamingAdapterFallbackUsesCompleteNormalizedProjection() throws {
        let home = try HistoryTestSupport.temporaryDirectory("source-grok-fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".grok")
        let file = try HistoryTestSupport.write([
            #"{"type":"user","content":"source fallbackneedle"}"#,
            #"{"type":"tool_result","tool_call_id":"synthetic","content":"fallbackneedle"}"#,
        ], to: root.appendingPathComponent("conversations/synthetic/chat_history.jsonl"))
        let loader = HistorySessionLoader(historyDirs: [root.path], homeDirectory: home)
        // Explicit candidate keeps this test about the adapter fallback, independent of a
        // producer's container-discovery naming convention.
        let candidate = HistoryFileCandidate(file: file, directory: try XCTUnwrap(loader.pathResolver.directories().first),
                                             formatHint: .grok)
        let loaded = try loader.load(candidate)
        let result = try ConversationSourceSearch.refine(candidate: candidate, metadata: loaded.session.metadata,
            loader: loader, query: "fallbackneedle", validate: {})
        guard case let .hit(_, _, sequence, _, count) = result else { return XCTFail("Expected fallback hit") }
        XCTAssertEqual(sequence, 0)
        XCTAssertEqual(count, 2)
    }

    private func message(_ text: String) -> String {
        let value = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":\#(value)}]}}"#
    }
    private func append(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private struct Fixture: Sendable {
        let home: URL
        let file: URL
        let loader: HistorySessionLoader
        let database: ConversationFileCatalog
        let id: String
        var repository: IndexedHistoryRepository { .init(configuration: loader.configuration, database: database, loader: loader) }
        init(lines: [String], id: String = "synthetic-source") throws {
            home = try HistoryTestSupport.temporaryDirectory("source-repository")
            let root = home.appendingPathComponent(".codex")
            file = root.appendingPathComponent("sessions/main.jsonl")
            self.id = id
            loader = HistorySessionLoader(historyDirs: [root.path], homeDirectory: home)
            database = try ConversationFileCatalog(file: home.appendingPathComponent("catalog"), enableTgrep: false)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(lines)
        }
        func encoded(_ lines: [String]) -> Data {
            let header = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/synthetic"}}"#
            return Data(([header] + lines).joined(separator: "\n").appending("\n").utf8)
        }
        func write(_ lines: [String]) throws { try encoded(lines).write(to: file, options: .atomic) }
        func scanner() -> ConversationIndexScanner {
            .init(configuration: loader.configuration, database: database, reparseSpacing: .immediate)
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}

private final class SourceSearchLoaderGate: HistorySessionLoading, @unchecked Sendable {
    let loader: HistorySessionLoader
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(loader: HistorySessionLoader) { self.loader = loader }
    func prefetch(_ candidates: [HistoryFileCandidate]) { loader.prefetch(candidates) }
    func loadQuickMetadata(_ candidates: [HistoryFileCandidate]) -> [QuickLoadedHistorySession] {
        loader.loadQuickMetadata(candidates)
    }
    func load(_ candidate: HistoryFileCandidate, consistency: HistorySessionLoadConsistency) throws -> LoadedHistorySession {
        started.signal()
        guard release.wait(timeout: .now() + 15) == .success else { throw CancellationError() }
        return try loader.load(candidate, consistency: consistency)
    }
}

private final class SourceSearchEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConversationSearchProgress] = []
    func append(_ event: ConversationSearchProgress) { lock.withLock { events.append(event) } }
    var values: [ConversationSearchProgress] { lock.withLock { events } }
}

private final class SourceRewriteEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConversationSearchProgress] = []
    private var replaced = false
    private var error: Error?
    let file: URL
    let replacement: Data
    let triggerPhase: ConversationSearchProgress.Phase?
    let afterReplacement: (@Sendable () throws -> Void)?
    init(file: URL, replacement: Data, triggerPhase: ConversationSearchProgress.Phase? = nil,
         afterReplacement: (@Sendable () throws -> Void)? = nil) {
        self.file = file
        self.replacement = replacement
        self.triggerPhase = triggerPhase
        self.afterReplacement = afterReplacement
    }
    func receive(_ event: ConversationSearchProgress) {
        lock.withLock {
            events.append(event)
            if !replaced, !event.hits.isEmpty, triggerPhase == nil || triggerPhase == event.phase {
                replaced = true
                do {
                    try replacement.write(to: file, options: .atomic)
                    try afterReplacement?()
                } catch { self.error = error }
            }
        }
    }
    var values: [ConversationSearchProgress] { lock.withLock { events } }
    var writeError: Error? { lock.withLock { error } }
}

private final class RepeatedSourceRewriteEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConversationSearchProgress] = []
    private var rewrittenAttempts = Set<UUID>()
    private var writes = 0
    private var error: Error?
    let file: URL
    let replacements: [Data]
    init(file: URL, replacements: [Data]) { self.file = file; self.replacements = replacements }
    func receive(_ event: ConversationSearchProgress) {
        lock.withLock {
            events.append(event)
            guard !event.hits.isEmpty, let attempt = event.snapshotAttempt,
                  rewrittenAttempts.insert(attempt).inserted, writes < replacements.count else { return }
            do {
                try replacements[writes].write(to: file, options: .atomic)
                writes += 1
            } catch { self.error = error }
        }
    }
    var values: [ConversationSearchProgress] { lock.withLock { events } }
    var writeCount: Int { lock.withLock { writes } }
    var writeError: Error? { lock.withLock { error } }
}
