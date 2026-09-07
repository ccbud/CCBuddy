import Foundation
import XCTest
@testable import CCBuddy

final class SemanticWordPieceTokenizerTests: XCTestCase {
    func testBundledVocabularyMatchesUpstreamTokenizerIncludingAccentsAndCode() throws {
        let tokenizer = try SemanticWordPieceTokenizer(vocabularyURL: vocabularyURL())
        // Golden IDs from AutoTokenizer at the pinned upstream revision in manifest.json.
        let samples: [(String, [Int32])] = [
            ("Hello, WORLD!", [101, 7592, 1010, 2088, 999, 102]),
            ("Café authentication.refresh_token()", [101, 7668, 27280, 1012, 25416, 21898, 1035, 19204, 1006, 1007, 102]),
            ("修复 API 错误", [101, 100, 100, 17928, 100, 100, 102]),
            ("hello\tworld\u{0000}!", [101, 7592, 2088, 999, 102]),
            ("Straße naïve résumé", [101, 2358, 27807, 15743, 13746, 102]),
        ]
        for (text, expected) in samples {
            let encoded = tokenizer.encode(text)
            XCTAssertEqual(Array(encoded.inputIDs.prefix(expected.count)), expected, text)
            XCTAssertEqual(encoded.inputIDs.count, 128)
            XCTAssertEqual(encoded.attentionMask.filter { $0 == 1 }.count, expected.count)
            XCTAssertTrue(encoded.inputIDs.dropFirst(expected.count).allSatisfy { $0 == 0 })
        }
    }

    func testOversizedInputTruncatesAndRetainsEndToken() throws {
        let tokenizer = try SemanticWordPieceTokenizer(vocabularyURL: vocabularyURL())
        let encoded = tokenizer.encode(String(repeating: "hello ", count: 10_000))
        XCTAssertEqual(encoded.inputIDs.count, 128)
        XCTAssertEqual(encoded.inputIDs.first, 101)
        XCTAssertEqual(encoded.inputIDs.last, 102)
        XCTAssertEqual(encoded.attentionMask, Array(repeating: 1, count: 128))
        let unknown = tokenizer.encode(String(repeating: "x", count: 101))
        XCTAssertEqual(Array(unknown.inputIDs.prefix(3)), [101, 100, 102])
    }

    private func vocabularyURL() throws -> URL {
        let base = try XCTUnwrap(Bundle.main.resourceURL)
        return try XCTUnwrap([
            base.appendingPathComponent("minilm-vocab.txt"),
            base.appendingPathComponent("SemanticSearch/minilm-vocab.txt"),
        ].first { FileManager.default.fileExists(atPath: $0.path) }, "The shipped tokenizer must be in the application bundle")
    }
}

final class LocalSemanticSearchTests: XCTestCase {
    private let candidates = [
        SemanticSearchCandidate(id: "appearance", text: "Arrange the sidebar icons and change the background color."),
        SemanticSearchCandidate(id: "authentication", text: "Renew credentials to restore access to the service."),
        SemanticSearchCandidate(id: "database", text: "Investigate slow database queries and reduce response latency."),
    ]
    private let query = "Fix authentication errors when the API key expires."

    func testBundledRealModelRanksByMeaningAndReusesEmbeddings() async throws {
        let service = LocalSemanticSearch()
        let first = try await service.rank(query: query, candidates: candidates)
        XCTAssertEqual(first.diagnostics.state, .ready, "A missing or unusable shipping model must fail this test")
        XCTAssertEqual(first.orderedIDs.first, "authentication", "Credential renewal matches expired keys without literal word overlap")
        XCTAssertEqual(Set(first.orderedIDs), Set(candidates.map(\.id)))
        XCTAssertEqual(first.diagnostics.embeddedCount, 4)
        XCTAssertEqual(first.diagnostics.cacheHitCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(first.scores["authentication"]), 0.3)
        let cached = try await service.rank(query: query, candidates: candidates)
        XCTAssertEqual(cached.orderedIDs, first.orderedIDs)
        XCTAssertEqual(cached.scores, first.scores)
        XCTAssertEqual(cached.diagnostics.embeddedCount, 0)
        XCTAssertEqual(cached.diagnostics.cacheHitCount, 4)
        XCTAssertEqual(cached.diagnostics.cachedEmbeddingCount, 4)

        let changed = [SemanticSearchCandidate(id: "appearance", text: "Renew expired authentication credentials.")]
        let refreshed = try await service.rank(query: query, candidates: changed)
        XCTAssertEqual(refreshed.diagnostics.embeddedCount, 1, "An unchanged ID with changed content must invalidate its vector")
        XCTAssertGreaterThan(try XCTUnwrap(refreshed.scores["appearance"]), try XCTUnwrap(first.scores["appearance"]))
    }

    func testCPUFallbackProducesSameSemanticOrderAndComparableScores() async throws {
        let preferred = try await LocalSemanticSearch().rank(query: query, candidates: candidates)
        let cpu = try await LocalSemanticSearch(forceCPU: true).rank(query: query, candidates: candidates)
        XCTAssertEqual(cpu.diagnostics.state, .ready)
        XCTAssertEqual(cpu.diagnostics.computePolicy, .cpuOnly)
        XCTAssertEqual(cpu.orderedIDs, preferred.orderedIDs)
        for candidate in candidates {
            XCTAssertEqual(try XCTUnwrap(cpu.scores[candidate.id]), try XCTUnwrap(preferred.scores[candidate.id]), accuracy: 0.01)
        }
        if #available(macOS 14.4, *) {
            XCTAssertEqual(cpu.diagnostics.neuralEnginePreferredOperationCount, 0)
            XCTAssertGreaterThan(try XCTUnwrap(cpu.diagnostics.totalPlannedOperationCount), 0)
        }
    }

    func testUnavailableModelPreservesAllKeywordResults() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/ccbuddy-semantic-model-\(UUID().uuidString)")
        let result = try await LocalSemanticSearch(resourceDirectory: missing).rank(query: query, candidates: candidates)
        XCTAssertEqual(result.orderedIDs, candidates.map(\.id))
        XCTAssertEqual(result.scores, [:])
        XCTAssertEqual(result.diagnostics.state, .unavailable)
    }

    func testUnsupportedLanguagesDoNotLoadModelOrChangeKeywordOrder() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/ccbuddy-semantic-model-\(UUID().uuidString)")
        let service = LocalSemanticSearch(resourceDirectory: missing)
        for query in ["修复 API 错误", "認証の修正", "인증 오류", "12345", " "] {
            let result = try await service.rank(query: query, candidates: candidates)
            XCTAssertEqual(result.orderedIDs, candidates.map(\.id))
            XCTAssertEqual(result.diagnostics.state, .unsupportedLanguage)
            XCTAssertEqual(result.diagnostics.embeddedCount, 0)
        }
    }

    func testRerankingBoundsWorkAndRetainsUnrankedTail() async throws {
        let service = LocalSemanticSearch(forceCPU: true)
        let many = (0..<40).map { SemanticSearchCandidate(id: "\($0)", text: "Renew credentials to restore access to the service.") }
        let result = try await service.rank(query: query, candidates: many)
        XCTAssertEqual(result.diagnostics.state, .ready)
        XCTAssertEqual(result.orderedIDs, many.map(\.id), "Ties and the unranked tail preserve retrieval order")
        XCTAssertEqual(result.scores.count, LocalSemanticSearch.candidateLimit)
        XCTAssertEqual(result.diagnostics.embeddedCount, 2)
        XCTAssertEqual(result.diagnostics.cacheHitCount, LocalSemanticSearch.candidateLimit - 1)
    }

    func testCancelledWorkThrowsBeforeLoadingModel() async throws {
        let service = LocalSemanticSearch(resourceDirectory: URL(fileURLWithPath: "/nonexistent/semantic"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.rank(query: query, candidates: candidates)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled semantic work must not publish a fallback result")
        } catch is CancellationError {
            // Expected; ConversationStore uses cancellation to prevent stale UI updates.
        }
    }
}
