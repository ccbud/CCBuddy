import Foundation
import XCTest
@testable import CCBuddy

final class ConversationSourceSearchTests: XCTestCase {
    func testFirstMatchPassReturnsOnlyItsExactAnchorAndCountPassFinishesLater() throws {
        let fixture = try Fixture(lines: [message("needle " + String(repeating: "x", count: 240_000) + " needle")])
        defer { fixture.remove() }
        let first = try fixture.refine("needle", countingOccurrences: false)
        let complete = try fixture.refine("needle")
        guard case let .hit(firstAgent, _, firstSequence, firstSnippet, firstCount) = first,
              case let .hit(agent, _, sequence, snippet, count) = complete else { return XCTFail("Expected both passes") }
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(firstAgent, agent)
        XCTAssertEqual(firstSequence, sequence)
        XCTAssertEqual(firstSnippet, snippet)
    }

    func testStreamingCodexMatchesFullProjectionIncludingMetadataAndToolAnchors() throws {
        let fixture = try Fixture(lines: [
            codex("session_meta", #"{"id":"synthetic-source","cwd":"/synthetic"}"#),
            message("first"),
            message("<skill>\n<name>synthetic</name>\n<path>/synthetic/SKILL.md</path>\n</skill>"),
            message("<environment_context>invisible</environment_context>"),
            codex("response_item", #"{"type":"function_call","call_id":"synthetic-call","name":"exec_command","arguments":"{\"cmd\":\"echo toolneedle\"}"}"#),
            codex("response_item", #"{"type":"function_call_output","call_id":"synthetic-call","output":"decoded \u7cfb\u7edf\u4ee3\u7406 tail"}"#),
            codex("event_msg", #"{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":2}}}"#),
            codex("compacted", #"{"message":"compactedneedle"}"#),
            codex("event_msg", #"{"type":"turn_aborted"}"#),
            message("last"),
        ])
        defer { fixture.remove() }
        try assertOracle(fixture, queries: ["系统代理", "toolneedle", "compactedneedle", "first",
            "invisible", "Request interrupted", "tail\ncompacted", "last", "absentneedle"])
        let session = try fixture.loader.getSession(file: fixture.file)
        let result = try fixture.refine("系统代理")
        guard case let .hit(_, _, sequence, _, _) = result else { return XCTFail("Expected decoded match") }
        XCTAssertEqual(sequence, session.messages.firstIndex { $0.content.contains { $0.type == "tool_result" } })
    }

    func testStreamingClaudeMatchesFullProjectionAtRecordAndBlockBoundaries() throws {
        let fixture = try Fixture(lines: [
            claude("left"),
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"hidden"}}"#,
            claude(""),
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"right"},{"type":"text","text":"block"}]}}"#,
            claude("<system-reminder>notsearchable</system-reminder> visible"),
            claude("tail"),
        ], source: .claude)
        defer { fixture.remove() }
        try assertOracle(fixture, queries: ["left\nright", "\nright", "right\nblock", "hidden",
            "notsearchable", "visible\ntail", "block\nvisible"])
    }

    func testRollingWindowPreservesCanonicalUnicodeAndNonoverlapCounts() throws {
        let padding = String(repeating: "x", count: 65_400)
        let fixture = try Fixture(lines: [message(padding + " aaa café e\u{301} 丽 ﬁ Σς 👩‍💻 "
            + String(repeating: "a", count: 135_000) + " end"), message("following")])
        defer { fixture.remove() }
        try assertOracle(fixture, queries: ["aa", "CAFÉ", "é", "丽", "fi", "σσ", "👩‍💻",
            "end\nfollowing", String(repeating: "a", count: 65_600)])
    }

    func testVeryLargeSingleRecordPublishesBeforeItsEntireBodyIsCounted() throws {
        let fixture = try Fixture(lines: [message("needle " + String(repeating: "x", count: 200_000)
            + " needle " + String(repeating: "z", count: 80_000))])
        defer { fixture.remove() }
        var counts: [Int] = []
        let result = try fixture.refine("needle", onFirstMatch: { value in
            if case let .hit(_, _, _, _, count) = value { counts.append(count) }
        })
        XCTAssertEqual(counts, [1], "First exact callback is inside the giant message, not after its tail")
        guard case let .hit(_, _, _, _, count) = result else { return XCTFail("Expected match") }
        XCTAssertEqual(count, 2)
        try assertOracle(fixture, queries: ["needle"])
    }

    func testPartialFinalJSONRecordDoesNotBecomeARawGrepHit() throws {
        let fixture = try Fixture(lines: [message("complete")])
        defer { fixture.remove() }
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"partialneedle"}"#.utf8))
        try handle.close()
        XCTAssertEqual(try fixture.refine("partialneedle"), .noMatch)
        try assertOracle(fixture, queries: ["complete", "partialneedle"])
        try HistoryTestSupport.write([message("complete"), message("partialneedle")], to: fixture.file)
        XCTAssertNotEqual(try fixture.refine("partialneedle"), .noMatch)
    }

    func testDuplicateEmbeddedAgentKeyUsesSameLastWriterAsDetailParser() throws {
        let fixture = try Fixture(lines: [claude("main contents")], source: .claude)
        defer { fixture.remove() }
        let directory = fixture.file.deletingPathExtension().appendingPathComponent("subagents")
        for (name, text) in [("a", "hiddenoldneedle"), ("z", "currentchildneedle")] {
            try HistoryTestSupport.write([claude(text)], to: directory.appendingPathComponent("agent-\(name).jsonl"))
            try Data(#"{"toolUseId":"shared-key","agentType":"synthetic-worker"}"#.utf8)
                .write(to: directory.appendingPathComponent("agent-\(name).meta.json"))
        }
        try assertOracle(fixture, queries: ["hiddenoldneedle", "currentchildneedle"])
        guard case let .hit(agent, type, _, _, _) = try fixture.refine("currentchildneedle") else {
            return XCTFail("Expected final child")
        }
        XCTAssertEqual(agent, "shared-key")
        XCTAssertEqual(type, "synthetic-worker")
    }

    func testEmbeddedAgentWithoutSidecarUsesExactDetailFallbackKey() throws {
        let fixture = try Fixture(lines: [claude("main contents")], source: .claude)
        defer { fixture.remove() }
        try HistoryTestSupport.write([claude("childneedle")], to: fixture.file.deletingPathExtension()
            .appendingPathComponent("subagents/agent-child.jsonl"))
        try assertOracle(fixture, queries: ["childneedle"])
        guard case let .hit(agent, _, _, _, _) = try fixture.refine("childneedle") else {
            return XCTFail("Expected child")
        }
        XCTAssertEqual(agent, "agent:child")
    }

    func testCancellationInsideFirstVerifiedCallbackNeverReturnsCompleteResult() async throws {
        let fixture = try Fixture(lines: [message("needle " + String(repeating: "x", count: 240_000))])
        defer { fixture.remove() }
        let worker = Task.detached {
            try fixture.refine("needle", onFirstMatch: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await worker.value; XCTFail("Cancellation cannot return a finished count") }
        catch is CancellationError {}
    }

    func testAtomicReplacementDuringCallbackInvalidatesSourceResult() throws {
        let fixture = try Fixture(lines: [message("needle " + String(repeating: "x", count: 240_000))])
        defer { fixture.remove() }
        let dependency = ConversationSourceDependency(file: fixture.file, role: .primaryTranscript)
        let before = ConversationDependencyStamp.read(dependency)
        XCTAssertThrowsError(try fixture.refine("needle", validate: {
            guard ConversationDependencyStamp.read(dependency) == before else {
                throw ConversationCatalogError.staleRevision
            }
        }, onFirstMatch: { _ in
            try HistoryTestSupport.write([self.message("replacement")], to: fixture.file)
        })) { error in
            guard case ConversationCatalogError.staleRevision = error else { return XCTFail("Expected stale source") }
        }
    }

    func testVisitorCannotBypassProtectedQoderSourceReader() throws {
        let home = try HistoryTestSupport.temporaryDirectory("source-qoder-permission")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try HistoryTestSupport.write([claude("protectedneedle")],
            to: home.appendingPathComponent(".qoder/projects/-synthetic/session.jsonl"))
        XCTAssertThrowsError(try HistoryJSONLDocument.visitRecords(from: file) { _ in
            XCTFail("Protected bytes must not reach the raw JSONL visitor")
        })
    }

    func testPermissionDeniedSourceFallbackThrowsInsteadOfReturningCompletedNegative() throws {
        let home = try HistoryTestSupport.temporaryDirectory("source-qoder-denied")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".qoder")
        let file = try HistoryTestSupport.write([claude("protectedneedle")],
            to: root.appendingPathComponent("projects/-synthetic/session.jsonl"))
        let ordinary = HistorySessionLoader(historyDirs: [root.path], homeDirectory: home)
        let candidate = try ordinary.pathResolver.validatedCandidate(for: file)
        let metadata = try ordinary.load(candidate).session.metadata
        let reader = QoderFileReader(fileAccess: DeniedSourceAccess(), helperResolver: DeniedSourceHelper(),
                                     helperRunner: UnusedSourceHelperRunner())
        let denied = HistorySessionLoader(configuration: ordinary.configuration, qoderReader: reader)
        XCTAssertThrowsError(try ConversationSourceSearch.refine(candidate: candidate, metadata: metadata,
            loader: denied, query: "protectedneedle", validate: {})) { error in
            guard case HistoryError.unreadableFile = error else { return XCTFail("Expected source read failure") }
        }
    }

    func testVisitorRecordOrderAndDiagnosticsMatchRetainingReader() throws {
        let fixture = try Fixture(lines: [message("a"), "malformed", " ", message("b"), "[]"])
        defer { fixture.remove() }
        var records: [[String: HistoryValue]] = []
        let diagnostics = try HistoryJSONLDocument.visitRecords(from: fixture.file) { records.append($0) }
        let full = try HistoryJSONLDocument.read(from: fixture.file)
        XCTAssertEqual(records, full.records)
        XCTAssertEqual(diagnostics, full.diagnostics)
    }

    private func assertOracle(_ fixture: Fixture, queries: [String],
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let projection = try fixture.loader.load(file: fixture.file).projection
        for query in queries {
            var expected = ConversationSearchRefinement.noMatch
            for thread in projection.threads {
                let matcher = ConversationLiteralSearch(query: query)
                guard let match = matcher.match(in: thread.searchText) else { continue }
                let location = match.range.lowerBound.utf16Offset(in: thread.searchText)
                let span = thread.span(containingUTF16Offset: location)
                    ?? thread.messageSpans.first { $0.utf16Location >= location } ?? thread.messageSpans.last
                expected = .hit(transcriptID: thread.transcriptID, agentType: thread.agentType,
                    sequence: span?.sequence, snippet: ConversationSourceSearch.snippet(in: thread.searchText,
                        around: match.range), count: match.count)
                break
            }
            XCTAssertEqual(try fixture.refine(query), expected, "Full projection oracle", file: file, line: line)
        }
    }

    private func message(_ text: String) -> String {
        codex("response_item", #"{"type":"message","role":"user","content":[{"type":"input_text","text":\#(encoded(text))}]}"#)
    }
    private func codex(_ type: String, _ payload: String) -> String {
        #"{"type":"\#(type)","payload":\#(payload)}"#
    }
    private func claude(_ text: String) -> String {
        #"{"type":"user","sessionId":"synthetic-source","message":{"role":"user","content":\#(encoded(text))}}"#
    }
    private func encoded(_ value: String) -> String { String(decoding: try! JSONEncoder().encode(value), as: UTF8.self) }

    private struct Fixture: Sendable {
        let home: URL
        let file: URL
        let loader: HistorySessionLoader
        init(lines: [String], source: HistorySource = .codex) throws {
            home = try HistoryTestSupport.temporaryDirectory("source-search")
            let sourceRoot = home.appendingPathComponent(source == .codex ? ".codex" : ".claude")
            let prefix = source == .codex
                ? [#"{"type":"session_meta","payload":{"id":"synthetic-source","cwd":"/synthetic"}}"#]
                : []
            file = try HistoryTestSupport.write(prefix + lines, to: sourceRoot.appendingPathComponent(
                source == .codex ? "sessions/synthetic.jsonl" : "projects/-synthetic/synthetic.jsonl"))
            loader = HistorySessionLoader(historyDirs: [sourceRoot.path], homeDirectory: home)
        }
        func refine(_ query: String, countingOccurrences: Bool = true, validate: () throws -> Void = {},
                    onFirstMatch: ((ConversationSearchRefinement) throws -> Void)? = nil) throws
            -> ConversationSearchRefinement {
            let candidate = try loader.pathResolver.validatedCandidate(for: file)
            let metadata = try XCTUnwrap(loader.loadQuickMetadata([candidate]).first?.metadata)
            return try ConversationSourceSearch.refine(candidate: candidate, metadata: metadata,
                loader: loader, query: query, countingOccurrences: countingOccurrences,
                validate: validate, onFirstMatch: onFirstMatch)
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
    }
}

private struct DeniedSourceAccess: QoderFileAccessing {
    func readData(at file: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
    func probeReadable(at file: URL) throws { throw CocoaError(.fileReadNoPermission) }
    func stamp(of file: URL) throws -> QoderFileStamp { .init(modifiedAt: .distantPast, size: 1) }
}

private struct DeniedSourceHelper: QoderHelperResolving {
    func trustedHelper(for dataRoot: URL) throws -> URL {
        throw QoderFileReadError.helperUntrusted("synthetic denied helper")
    }
}

private struct UnusedSourceHelperRunner: QoderHelperRunning {
    func read(helper: URL, target: URL, outputLimit: Int, timeout: TimeInterval) throws -> Data {
        XCTFail("An untrusted helper must not be executed")
        throw CancellationError()
    }
    func readBatch(helper: URL, targets: [URL], outputLimit: Int, timeout: TimeInterval) throws -> [URL: Data] {
        XCTFail("An untrusted helper must not be executed")
        throw CancellationError()
    }
}
