import Foundation
import XCTest
@testable import CCBuddy

final class ConversationSourceSearchCoverageTests: XCTestCase {
    func testSharedCodexAnnotationEditKeepsEveryUnchangedBodySearchableWithoutRawScan() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-annotation")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try ["first", "second", "third"].map { try writeCodexSession(root: root, name: $0) }
        let loader = makeLoader(root: root)
        let rows = try files.map { try entryWithBodyProof(file: $0, loader: loader) }
        try HistoryTestSupport.write([#"{"first":{"title":"Updated annotation","starred":true,"pinned":true}}"#],
            to: root.appendingPathComponent("codex-meta.json"))

        let coverage = try snapshot(loader, entries: rows)
        XCTAssertTrue(coverage.sourcesByPath.isEmpty, "One annotation edit must not raw-scan the whole corpus")
        XCTAssertEqual(coverage.validationSources.count, files.count)
        let first = try XCTUnwrap(coverage.metadata.first { $0.file == files[0] })
        XCTAssertEqual(first.title, "Updated annotation")
        XCTAssertTrue(first.starred)
        XCTAssertTrue(first.pinned)
        XCTAssertTrue(coverage.validationSources.allSatisfy { $0.manifest.snapshot() == $0.dependencySnapshot })
    }

    func testLegacyCatalogWithoutBodyProofRemainsConservativeAfterAnnotationEdit() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-legacy-proof")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeCodexSession(root: root, name: "legacy")
        let loader = makeLoader(root: root)
        let row = entry(try quickMetadata(file: file, loader: loader))
        XCTAssertNil(row.fingerprint.searchContentFingerprint)
        try HistoryTestSupport.write([#"{"legacy":{"title":"Changed annotation"}}"#],
            to: root.appendingPathComponent("codex-meta.json"))

        XCTAssertEqual(Set(try snapshot(loader, entries: [row]).sourcesByPath.keys), [file.path])
    }

    func testQuickMetadataPublicationPreservesOnlyItsPreviouslyCommittedBodyProof() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-quick-proof")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeCodexSession(root: root, name: "committed")
        let loader = makeLoader(root: root)
        let catalog = try ConversationFileCatalog(file: root.appendingPathComponent("catalog"), enableTgrep: false)
        let scanner = ConversationIndexScanner(configuration: loader.configuration, database: catalog,
            reparseSpacing: .init(minimum: 60, maximum: 60, secondsPerByte: 0))
        _ = try scanner.scanAll()
        let before = try XCTUnwrap(catalog.entry(for: file))
        XCTAssertNotNil(before.fingerprint.searchContentFingerprint)
        try HistoryTestSupport.write([#"{"committed":{"title":"Metadata-only revision"}}"#],
            to: root.appendingPathComponent("codex-meta.json"))
        _ = try scanner.scan(changedPaths: [file])
        let pending = try XCTUnwrap(catalog.entry(for: file))
        XCTAssertTrue(pending.fingerprint.dependencyFingerprint?.hasPrefix("quick:") == true)
        XCTAssertEqual(pending.fingerprint.searchContentFingerprint, before.fingerprint.searchContentFingerprint)
        XCTAssertNotNil(scanner.deferredReparse)
        let coverage = try snapshot(loader, entries: [pending])
        XCTAssertTrue(coverage.sourcesByPath.isEmpty)
        XCTAssertEqual(coverage.metadata.first?.title, "Metadata-only revision")
        XCTAssertEqual(coverage.validationSources.count, 1)
    }

    func testSameSizeSameMtimeAtomicBodyReplacementCannotUseAnnotationOnlyFastPath() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-body-replacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeCodexSession(root: root, name: "replace", text: "oldbody")
        let loader = makeLoader(root: root)
        let row = try entryWithBodyProof(file: file, loader: loader)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let beforeMtime = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let replacement = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "oldbody", with: "newbody")
        try Data(replacement.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: beforeMtime], ofItemAtPath: file.path)

        let coverage = try snapshot(loader, entries: [row])
        let source = try XCTUnwrap(coverage.sourcesByPath[file.path])
        XCTAssertNotEqual(ConversationIndexFingerprint.contentFingerprint(manifest: source.manifest,
            snapshot: source.dependencySnapshot), row.fingerprint.searchContentFingerprint)
    }

    func testAnnotationTrashChangeReusesOtherBodiesButVerifiesMovedRow() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-annotation-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = try writeCodexSession(root: root, name: "moved")
        let retained = try writeCodexSession(root: root, name: "retained")
        let loader = makeLoader(root: root)
        let rows = try [moved, retained].map { try entryWithBodyProof(file: $0, loader: loader) }
        try HistoryTestSupport.write([#"{"moved":{"delete":true}}"#],
            to: root.appendingPathComponent("codex-meta.json"))

        let active = try snapshot(loader, entries: rows)
        XCTAssertEqual(active.metadata.map(\.file), [retained])
        XCTAssertTrue(active.sourcesByPath.isEmpty)
        let trash = try snapshot(loader, entries: rows, deleted: true)
        XCTAssertEqual(trash.metadata.map(\.file), [moved])
        XCTAssertEqual(Set(trash.sourcesByPath.keys), [moved.path],
            "The old catalog's active-only candidate filter cannot supply a newly trashed body")
    }

    func testMatchingBodyProofCannotAuthorizeChangedOwner() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-body-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeCodexSession(root: root, name: "owner")
        let loader = makeLoader(root: root)
        var row = try entryWithBodyProof(file: file, loader: loader)
        row.metadata.parentThreadID = "old-parent"
        try HistoryTestSupport.write([#"{"owner":{"title":"Changed annotation"}}"#],
            to: root.appendingPathComponent("codex-meta.json"))

        let coverage = try snapshot(loader, entries: [row])
        XCTAssertNotNil(coverage.sourcesByPath[file.path])
        XCTAssertNil(coverage.metadata.first?.parentThreadID)
    }

    func testEquivalentRootScopeAliasDoesNotHideRediscoveredAuthorizedSource() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-scope-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history")
        let file = try writeSession(root: historyRoot, name: "alias")
        let oldLoader = HistorySessionLoader(historyDirs: ["~/history"], homeDirectory: root)
        let oldRow = entry(try quickMetadata(file: file, loader: oldLoader))
        let loader = HistorySessionLoader(historyDirs: [historyRoot.path], homeDirectory: root)

        for scope in [nil, historyRoot.path] as [String?] {
            let coverage = try snapshot(loader, entries: [oldRow], scope: scope)
            XCTAssertEqual(coverage.metadata.map(\.file), [file])
            XCTAssertEqual(coverage.metadata.first?.dirID, historyRoot.path)
            XCTAssertEqual(Set(coverage.sourcesByPath.keys), [file.path])
        }
        XCTAssertTrue(try snapshot(loader, entries: [oldRow], scope: "~/history").metadata.isEmpty)
    }

    func testBodyProofIsOptionalForOlderSerializedFingerprints() throws {
        let legacy = ConversationIndexFingerprint(modificationTime: .distantPast, sizeBytes: 42,
            dependencyFingerprint: "legacy")
        let decoded = try JSONDecoder().decode(ConversationIndexFingerprint.self,
            from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.searchContentFingerprint)
        var withProof = legacy
        withProof.searchContentFingerprint = "body-v1:codex:fixture"
        XCTAssertTrue(decoded.matchesSourceRevision(withProof))
        XCTAssertEqual(try JSONDecoder().decode(ConversationIndexFingerprint.self,
            from: JSONEncoder().encode(withProof)).searchContentFingerprint, withProof.searchContentFingerprint)
    }

    func testCleanCatalogSourcesNeedNoRawVerification() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-clean")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "clean")
        let loader = makeLoader(root: root)
        let quick = try quickMetadata(file: file, loader: loader)
        let coverage = try snapshot(loader, entries: [entry(quick)])

        XCTAssertEqual(coverage.metadata, [quick.metadata])
        XCTAssertTrue(coverage.sourcesByPath.isEmpty)
    }

    func testQuickSentinelAlwaysRequiresRawVerification() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-quick")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "quick")
        let loader = makeLoader(root: root)
        let quick = try quickMetadata(file: file, loader: loader)
        var row = entry(quick)
        row.fingerprint.modificationTime = Date(timeIntervalSince1970: 0)
        row.fingerprint.dependencyFingerprint = "quick:" + quick.dependencySnapshot.fingerprint

        let coverage = try snapshot(loader, entries: [row])
        let source = try XCTUnwrap(coverage.sourcesByPath[file.path])
        XCTAssertEqual(coverage.metadata, [quick.metadata])
        XCTAssertEqual(source.dependencySnapshot, quick.dependencySnapshot)
        XCTAssertEqual(source.candidate.file, file)
    }

    func testAppendDuringReparseSpacingRequiresRawVerification() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "live")
        let loader = makeLoader(root: root)
        let quick = try quickMetadata(file: file, loader: loader)
        let row = entry(quick)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(name: "live", text: "new tail 系统代理") + "\n").utf8))
        try handle.close()

        let coverage = try snapshot(loader, entries: [row])
        let source = try XCTUnwrap(coverage.sourcesByPath[file.path])
        XCTAssertNotEqual(source.dependencySnapshot, quick.dependencySnapshot)
        XCTAssertEqual(source.dependencySnapshot, source.manifest.snapshot())
        XCTAssertEqual(coverage.metadata.count, 1)
    }

    func testNewSubagentDependencyInvalidatesUnchangedMainTranscript() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "parent")
        let loader = makeLoader(root: root)
        let quick = try quickMetadata(file: file, loader: loader)
        let child = root.appendingPathComponent("projects/-coverage/parent/subagents/agent-child.jsonl")
        try HistoryTestSupport.write([line(name: "parent", text: "child tail 当前版本")], to: child)

        let coverage = try snapshot(loader, entries: [entry(quick)])
        let source = try XCTUnwrap(coverage.sourcesByPath[file.path])
        XCTAssertEqual(source.dependencySnapshot.stamp(for: file),
                       quick.dependencySnapshot.stamp(for: file))
        XCTAssertNotEqual(source.dependencySnapshot, quick.dependencySnapshot)
        XCTAssertTrue(source.manifest.dependencies.contains { $0.file == child })
        XCTAssertEqual(coverage.metadata.count, 1, "A sidecar is not a second main session")
    }

    func testUnknownAuthorizedSessionUsesBoundedMetadataWithoutFullProjection() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-coverage/new.jsonl")
        try HistoryTestSupport.write([
            line(name: "new", text: "short metadata prefix"),
            line(name: "new", text: String(repeating: "large body ", count: 60_000)),
        ], to: file)
        let loader = makeLoader(root: root)

        let coverage = try snapshot(loader)
        let source = try XCTUnwrap(coverage.sourcesByPath[file.path])
        XCTAssertEqual(coverage.metadata.map(\.file), [file])
        XCTAssertEqual(source.metadata.messageCount, 1, "Only the complete bounded prefix is parsed")
        XCTAssertGreaterThan(source.metadata.sizeBytes, UInt64(HistorySessionLoader.maximumQuickReadBytes))
        XCTAssertEqual(source.dependencySnapshot, source.manifest.snapshot())
    }

    func testExplicitScopeOverridesReusedLoadersOriginalActiveScope() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        let first = try writeSession(root: firstRoot, name: "first")
        let second = try writeSession(root: secondRoot, name: "second")
        let loader = HistorySessionLoader(configuration: HistoryConfiguration(
            historyDirs: [firstRoot.path, secondRoot.path], active: firstRoot.path,
            homeDirectory: root, importsRoot: root.appendingPathComponent("imports")
        ))
        let secondCoverage = try snapshot(loader, scope: secondRoot.path)
        XCTAssertEqual(secondCoverage.metadata.map(\.file), [second])
        XCTAssertEqual(Set(secondCoverage.sourcesByPath.keys), [second.path])

        let allCoverage = try snapshot(loader)
        XCTAssertEqual(Set(allCoverage.metadata.map(\.file)), [first, second])
        let revoked = try snapshot(loader, scope: root.appendingPathComponent("revoked").path)
        XCTAssertTrue(revoked.metadata.isEmpty)
        XCTAssertTrue(revoked.sourcesByPath.isEmpty)
    }

    func testKnownAndUnknownRowsRespectTrashFilter() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try writeSession(root: root, name: "active")
        let deleted = try writeSession(root: root, name: "deleted", deleted: true)
        let known = try writeSession(root: root, name: "known-deleted", deleted: true)
        let loader = makeLoader(root: root)
        var row = entry(try quickMetadata(file: known, loader: loader))
        row.fingerprint.dependencyFingerprint = "quick:pending"

        let activeCoverage = try snapshot(loader, entries: [row])
        XCTAssertEqual(activeCoverage.metadata.map(\.file), [active])
        XCTAssertEqual(Set(activeCoverage.sourcesByPath.keys), [active.path])
        let deletedCoverage = try snapshot(loader, entries: [row], deleted: true)
        XCTAssertEqual(Set(deletedCoverage.metadata.map(\.file)), [known, deleted])
        XCTAssertEqual(Set(deletedCoverage.sourcesByPath.keys), [known.path, deleted.path])
    }

    func testUnavailableKnownSourcePreservesCommittedMetadataWithoutRawFallback() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "missing")
        let loader = makeLoader(root: root)
        let quick = try quickMetadata(file: file, loader: loader)
        let row = entry(quick)
        try FileManager.default.removeItem(at: file)

        let coverage = try snapshot(loader, entries: [row])
        XCTAssertEqual(coverage.metadata, [quick.metadata])
        XCTAssertTrue(coverage.sourcesByPath.isEmpty)
    }

    func testDirtyKnownRowsRefreshTrashStateBeforeFiltering() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-dirty-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "moving")
        let loader = makeLoader(root: root)
        let activeRow = entry(try quickMetadata(file: file, loader: loader))
        try writeSession(root: root, name: "moving", deleted: true)

        XCTAssertTrue(try snapshot(loader, entries: [activeRow]).metadata.isEmpty)
        let trash = try snapshot(loader, entries: [activeRow], deleted: true)
        XCTAssertEqual(trash.metadata.map(\.file), [file])
        XCTAssertEqual(trash.sourcesByPath[file.path]?.metadata.deleted, true)

        let deletedRow = entry(try quickMetadata(file: file, loader: loader))
        try writeSession(root: root, name: "moving", deleted: false)
        XCTAssertTrue(try snapshot(loader, entries: [deletedRow], deleted: true).metadata.isEmpty)
        XCTAssertEqual(try snapshot(loader, entries: [deletedRow]).metadata.map(\.file), [file])
    }

    func testDirtyPrefixMetadataDoesNotReplaceCompleteStatistics() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-dirty-statistics")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "stable-owner")
        let loader = makeLoader(root: root)
        var row = entry(try quickMetadata(file: file, loader: loader))
        row.metadata.messageCount = 12_000
        row.metadata.totals = HistoryTotals(inputTokens: 900_000, turns: 600)
        row.metadata.subagentCount = 1
        row.metadata.subagentRefs = [childRef(file: file)]
        row.fingerprint.dependencyFingerprint = "quick:pending"

        let coverage = try snapshot(loader, entries: [row])
        let metadata = try XCTUnwrap(coverage.metadata.first)
        XCTAssertEqual(metadata.messageCount, 12_000)
        XCTAssertEqual(metadata.totals, row.metadata.totals)
        XCTAssertEqual(metadata.subagentRefs, row.metadata.subagentRefs)
        XCTAssertEqual(metadata.subagentCount, 1)
    }

    func testDirtyParentIdentityDoesNotKeepOldChildReferences() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-dirty-parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/child.jsonl")
        try HistoryTestSupport.write([codexMetadata(parent: "old-parent")], to: file)
        let loader = makeLoader(root: root)
        var row = entry(try quickMetadata(file: file, loader: loader))
        row.metadata.messageCount = 42
        row.metadata.subagentRefs = [childRef(file: file)]
        try HistoryTestSupport.write([codexMetadata(parent: "new-parent")], to: file)

        let coverage = try snapshot(loader, entries: [row])
        let metadata = try XCTUnwrap(coverage.metadata.first)
        XCTAssertEqual(metadata.parentThreadID, "new-parent")
        XCTAssertTrue(metadata.subagentRefs.isEmpty)
        XCTAssertEqual(metadata.messageCount, 0)
        XCTAssertEqual(coverage.sourcesByPath[file.path]?.metadata.parentThreadID, "new-parent")
    }

    func testDirtyDetectorBasedPathCanChangeProducerWithoutOldHint() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-dirty-producer")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession(root: root, name: "replaced")
        let loader = makeLoader(root: root)
        var row = entry(try quickMetadata(file: file, loader: loader))
        row.metadata.subagentRefs = [childRef(file: file)]
        try HistoryTestSupport.write([codexMetadata(parent: "new-parent")], to: file)

        let coverage = try snapshot(loader, entries: [row])
        let source = try XCTUnwrap(coverage.sourcesByPath[file.path])
        XCTAssertNil(source.candidate.formatHint, "The projects path must retain format detection")
        XCTAssertEqual(source.metadata.source, .codex)
        XCTAssertEqual(source.manifest.source, .codex)
        XCTAssertEqual(source.metadata.sessionID, "child-thread")
        XCTAssertTrue(source.metadata.subagentRefs.isEmpty)
        XCTAssertEqual(coverage.metadata.first?.source, .codex)
    }

    func testRevokedRootAndSymlinkCannotBecomeRawSources() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-permissions")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed")
        let revoked = root.appendingPathComponent("revoked")
        let actual = try writeSession(root: allowed, name: "actual")
        let revokedFile = try writeSession(root: revoked, name: "private")
        let originalLoader = HistorySessionLoader(historyDirs: [allowed.path, revoked.path],
                                                  homeDirectory: root)
        let revokedRow = entry(try quickMetadata(file: revokedFile, loader: originalLoader))
        let linked = allowed.appendingPathComponent("projects/-coverage/link.jsonl")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: revokedFile)
        let loader = HistorySessionLoader(historyDirs: [allowed.path], homeDirectory: root)

        let coverage = try snapshot(loader, entries: [revokedRow])
        XCTAssertEqual(coverage.metadata.map(\.file), [actual])
        XCTAssertEqual(Set(coverage.sourcesByPath.keys), [actual.path])
        XCTAssertNil(coverage.sourcesByPath[linked.path])
        XCTAssertNil(coverage.sourcesByPath[revokedFile.path])
    }

    func testPrecancelledCoverageDoesNotPublishAnEmptyCompletedSnapshot() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = makeLoader(root: root)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ConversationSourceSearchCoverage.snapshot(
                loader: loader, entries: [], scope: nil, deleted: false
            )
        }
        do {
            _ = try await worker.value
            XCTFail("Cancellation is not a completed no-match snapshot")
        } catch is CancellationError {}
    }

    func testRewriteDuringQuickMetadataDoesNotPairOldIdentityWithNewSourceStamp() throws {
        let root = try HistoryTestSupport.temporaryDirectory("source-coverage-metadata-rewrite")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, name: "before")
        let loader = HistorySessionLoader(configuration: HistoryConfiguration(
            historyDirs: [root.path], homeDirectory: root,
            importsRoot: root.appendingPathComponent("imports")
        ), adapters: ConversationSourceAdapterRegistry(adapters: [RewritingCoverageAdapter()]))

        XCTAssertThrowsError(try snapshot(loader)) {
            guard case ConversationCatalogError.staleRevision = $0 else {
                return XCTFail("Expected a retryable stale source snapshot, got \($0)")
            }
        }
    }

    private func makeLoader(root: URL) -> HistorySessionLoader {
        HistorySessionLoader(configuration: HistoryConfiguration(
            historyDirs: [root.path], homeDirectory: root,
            importsRoot: root.appendingPathComponent("imports")
        ), makeCatalogProjection: { session in
            XCTFail("Search coverage must not build a full catalog projection")
            return HistoryCatalogProjection(session: session)
        })
    }

    private func snapshot(
        _ loader: HistorySessionLoader,
        entries: [ConversationIndexEntry] = [],
        scope: String? = nil,
        deleted: Bool = false
    ) throws -> ConversationSourceSearchCoverage {
        try ConversationSourceSearchCoverage.snapshot(
            loader: loader, entries: entries, scope: scope, deleted: deleted
        )
    }

    private func quickMetadata(file: URL, loader: HistorySessionLoader) throws -> QuickLoadedHistorySession {
        let candidate = try loader.pathResolver.validatedCandidate(for: file)
        return try XCTUnwrap(loader.loadQuickMetadata([candidate]).first)
    }

    private func entry(_ quick: QuickLoadedHistorySession) -> ConversationIndexEntry {
        let primary = quick.manifest.primary!
        let stamp = quick.dependencySnapshot.stamp(for: primary.file, role: primary.role)!
        return ConversationIndexEntry(sourcePath: quick.candidate.file.path, metadata: quick.metadata,
            scope: quick.candidate.directory.id,
            fingerprint: ConversationIndexFingerprint(
                modificationTime: Date(timeIntervalSince1970: Double(stamp.modifiedAtNanoseconds!) / 1_000_000_000),
                sizeBytes: stamp.sizeBytes!, dependencyFingerprint: quick.dependencySnapshot.fingerprint
            ), indexedAt: Date())
    }

    private func entryWithBodyProof(file: URL, loader: HistorySessionLoader) throws -> ConversationIndexEntry {
        let quick = try quickMetadata(file: file, loader: loader)
        var result = entry(quick)
        result.fingerprint.searchContentFingerprint = ConversationIndexFingerprint.contentFingerprint(
            manifest: quick.manifest, snapshot: quick.dependencySnapshot)
        return result
    }

    private func writeCodexSession(root: URL, name: String, text: String = "body needle") throws -> URL {
        try HistoryTestSupport.write([
            #"{"type":"session_meta","payload":{"id":"\#(name)","cwd":"/coverage"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"#,
        ], to: root.appendingPathComponent("sessions/\(name).jsonl"))
    }

    @discardableResult
    private func writeSession(root: URL, name: String, deleted: Bool = false) throws -> URL {
        let file = root.appendingPathComponent("projects/-coverage/\(name).jsonl")
        var lines = [line(name: name, text: "metadata \(name)")]
        if deleted { lines.insert(#"{"__ccbud__":{"delete":true}}"#, at: 0) }
        return try HistoryTestSupport.write(lines, to: file)
    }

    private func childRef(file: URL) -> HistorySubagentRef {
        HistorySubagentRef(file: file.deletingLastPathComponent().appendingPathComponent("old-child.jsonl"),
            threadID: "old-child", title: "old child", messageCount: 3, lastActivity: .distantPast)
    }

    private func codexMetadata(parent: String) -> String {
        HistoryTestSupport.codexLine(timestamp: "2026-09-10T00:00:00Z", type: "session_meta",
            payload: #"{"id":"child-thread","session_id":"root-thread","parent_thread_id":"\#(parent)","thread_source":"subagent","cwd":"/coverage"}"#)
    }

    private func line(name: String, text: String) -> String {
        // These fixture strings contain no JSON control characters.
        HistoryTestSupport.claudeLine(type: "user", role: "user", contentJSON: "\"\(text)\"",
            sessionID: name, cwd: "/coverage", timestamp: "2026-09-10T00:00:00Z")
    }
}

private struct RewritingCoverageAdapter: ConversationSourceAdapter {
    let source = HistorySource.claude
    let format = HistoryTranscriptFormat.claude

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        [.init(file: candidate.file, role: .primaryTranscript)]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        let document = try XCTUnwrap(input.document)
        let session = ClaudeHistoryParser.parse(HistoryParseContext(candidate: input.candidate,
            document: document, facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot))
        try Data("replaced while its old metadata was being parsed\n".utf8)
            .write(to: input.candidate.file, options: .atomic)
        return session
    }
}
