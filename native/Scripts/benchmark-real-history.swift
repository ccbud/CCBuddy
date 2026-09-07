import Darwin
import Foundation

/// Compiled with the production History sources by benchmark-real-history.sh.
/// This executable has no UI, gateway, config-store, or history-mutation code.
@main
enum RealHistoryBenchmark {
    static let producerRoots: [(String, String)] = [
        ("Claude", ".claude"), ("Claude XDG", ".config/claude"),
        ("Codex", ".codex"), ("Qoder", ".qoder"), ("QoderWork", ".qoderwork"),
        ("Grok", ".grok"), ("Copilot", ".copilot"),
        ("Antigravity", ".gemini/antigravity-cli"),
    ]

    static func main() throws {
        let arguments = Set(CommandLine.arguments.dropFirst())
        guard arguments.contains("--inventory") || arguments.contains("--largest") || arguments.contains("--run") || arguments.contains("--queries") else {
            print("Usage: benchmark-real-history.sh --inventory|--largest|--run [--show-roots]; --queries --catalog <private benchmark.sqlite3> [--baseline-fts|--repository]")
            return
        }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let scratch = ProcessInfo.processInfo.environment["CCBUD_BENCHMARK_SCRATCH"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? manager.temporaryDirectory
        let temporary = scratch.appendingPathComponent("ccbuddy-real-history-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let roots = producerRoots.map { home.appendingPathComponent($0.1).path }
        if arguments.contains("--queries") {
            guard let argument = CommandLine.arguments.firstIndex(of: "--catalog"),
                  CommandLine.arguments.indices.contains(argument + 1) else { throw BenchmarkFailure.invalidCatalog }
            let file = URL(fileURLWithPath: CommandLine.arguments[argument + 1]).standardizedFileURL
            // Reuse only this benchmark's explicitly named derived snapshot,
            // never a producer database or the live application's catalog.
            guard file.lastPathComponent == "benchmark.sqlite3",
                  file.deletingLastPathComponent().lastPathComponent.hasPrefix("ccbuddy-query-benchmark."),
                  manager.fileExists(atPath: file.path) else { throw BenchmarkFailure.invalidCatalog }
            let database = try ConversationIndexDatabase(file: file)
            guard TgrepSearchIndex.isAvailable else { throw BenchmarkFailure.engineUnavailable }
            let queryStart = ContinuousClock.now
            if arguments.contains("--repository") {
                let configuration = HistoryConfiguration(historyDirs: roots, homeDirectory: home,
                    importsRoot: temporary.appendingPathComponent("imports"))
                let repository = IndexedHistoryRepository(configuration: configuration, database: database)
                let listStarted = ContinuousClock.now
                let listed = try repository.listSessions(limit: ConversationCatalogLimits.searchScan)
                emit(["phase": "repository_session_list", "elapsed_ms": milliseconds(since: listStarted),
                    "visible_canonical_sessions": listed.count, "process_peak_rss_bytes": peakRSS()])
                // Deliberately do not start indexing, watching, or reconciliation. Only the
                // explicitly supplied private derived snapshot is queried. The production
                // facade still performs real scope filtering, canonical session ordering,
                // exact full counts, message-span lookup, and snippet extraction.
                for (index, query) in ["error", "搜索", "工具", "代码", "performance", "Swift"].enumerated() {
                    try measureRepositoryQuery(repository, sessions: listed, query: query,
                        phase: index == 0 ? "repository_first_query" : "repository_warm_query")
                }
                for query in ["搜索", "performance", "Swift"] {
                    try measureRepositoryQuery(repository, sessions: listed, query: query, phase: "repository_repeat_query")
                }
                emit(["phase": "complete", "elapsed_ms": milliseconds(since: queryStart), "process_peak_rss_bytes": peakRSS()])
                return
            }
            if arguments.contains("--baseline-fts") {
                let baseline = try ConversationIndexDatabase(file: file, enableTgrep: false)
                for query in ["error", "Swift", "performance"] {
                    try measureQuery(baseline, query: query, phase: "sqlite_fts_baseline")
                    try measureQuery(database, query: query, phase: "tgrep_comparison")
                }
                emit(["phase": "complete", "elapsed_ms": milliseconds(since: queryStart), "process_peak_rss_bytes": peakRSS()])
                return
            }
            for (index, query) in ["error", "搜索", "工具", "代码", "performance", "Swift"].enumerated() {
                try measureQuery(database, query: query, phase: index == 0 ? "first_query" : "warm_query")
            }
            for query in ["搜索", "工具", "代码"] { try measureQuery(database, query: query, phase: "repeat_query") }
            emit(["phase": "complete", "elapsed_ms": milliseconds(since: queryStart), "process_peak_rss_bytes": peakRSS()])
            return
        }
        let configuration = HistoryConfiguration(historyDirs: roots, homeDirectory: home,
            importsRoot: temporary.appendingPathComponent("imports"))
        let loader = HistorySessionLoader(configuration: configuration)
        let discoveryStart = ContinuousClock.now
        let candidates = loader.discoverCandidates(activeOnly: false)
        let discoveryMS = milliseconds(since: discoveryStart)
        let sized = candidates.map { candidate in
            (candidate, (try? candidate.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var inventory: [[String: Any]] = []
        for (label, suffix) in producerRoots {
            let root = home.appendingPathComponent(suffix).resolvingSymlinksInPath().standardizedFileURL
            let files = sized.filter { $0.0.directory.baseURL == root }
            var row: [String: Any] = [
                "producer": label,
                "exists": manager.fileExists(atPath: root.path),
                "session_files": files.count,
                "total_bytes": files.reduce(0) { $0 + $1.1 },
                "largest_file_bytes": files.map(\.1).max() ?? 0,
            ]
            if arguments.contains("--show-roots") { row["root"] = root.path }
            inventory.append(row)
        }
        emit(["phase": "inventory", "roots": inventory, "discovery_ms": discoveryMS,
            "session_files": candidates.count, "total_bytes": sized.reduce(0) { $0 + $1.1 },
            "tgrep_available": TgrepSearchIndex.isAvailable,
            "process_peak_rss_bytes": peakRSS()])
        guard !arguments.contains("--inventory") else { return }
        guard let largest = sized.max(by: { $0.1 < $1.1 }) else { return }

        if arguments.contains("--largest") {
            let before = peakRSS()
            let started = ContinuousClock.now
            do {
                let loaded = try loader.load(largest.0, consistency: .bestEffort)
                emit(["phase": "largest_session", "file_bytes": largest.1,
                    "source": loaded.session.metadata.source.rawValue,
                    "messages": loaded.session.messages.count,
                    "subagents": loaded.session.subagents.count,
                    "visible_search_bytes": loaded.projection.threads.reduce(0) { $0 + $1.searchText.utf8.count },
                    "parse_ms": milliseconds(since: started),
                    "baseline_peak_rss_bytes": before, "process_peak_rss_bytes": peakRSS()])
            } catch {
                emit(["phase": "largest_session", "file_bytes": largest.1,
                    "failed": true, "error_type": String(describing: type(of: error)),
                    "parse_ms": milliseconds(since: started), "process_peak_rss_bytes": peakRSS()])
                throw BenchmarkFailure.parse
            }
            return
        }

        let database = try ConversationIndexDatabase(file: temporary.appendingPathComponent("index.sqlite3"))
        guard TgrepSearchIndex.isAvailable else { throw BenchmarkFailure.engineUnavailable }
        let scanner = ConversationIndexScanner(configuration: configuration, database: database,
            loader: loader, reparseSpacing: .immediate)
        let coldStart = ContinuousClock.now
        let scan = try scanner.scanAll(onProgress: { result in
            if result.completed > 0, result.completed.isMultiple(of: 100) {
                emit(["phase": "index_progress", "completed": result.completed,
                    "discovered": result.discovered, "failed": result.failed,
                    "elapsed_ms": milliseconds(since: coldStart), "process_peak_rss_bytes": peakRSS()])
            }
        })
        let entries = try database.listEntries(deleted: nil, limit: .max)
        let sourceCounts = Dictionary(grouping: entries, by: { $0.metadata.source.rawValue }).mapValues(\.count)
        emit(["phase": "cold_catalog", "elapsed_ms": milliseconds(since: coldStart),
            "discovered": scan.discovered, "parsed": scan.parsed, "failed": scan.failed,
            "metadata_published": scan.metadataPublished, "by_source": sourceCounts,
            "catalog_bytes": fileBytes(database.file), "process_peak_rss_bytes": peakRSS()])

        // Fixed public queries avoid deriving or emitting terms from private content.
        let queries = ["error", "Swift", "performance", "model", "搜索", "ANE", "authentication", "TypeScript", "read file", "provider"]
        for (index, query) in queries.enumerated() {
            try measureQuery(database, query: query, phase: index == 0 ? "first_query" : "warm_query")
        }
        for query in queries { try measureQuery(database, query: query, phase: "repeat_query") }

        // Compare the same real corpus and public two-character CJK queries
        // with the prior literal fallback, without another raw-history parse.
        let literalDatabase = try ConversationIndexDatabase(file: database.file, enableTgrep: false)
        for query in ["搜索", "工具", "代码"] {
            try measureQuery(literalDatabase, query: query, phase: "cjk_literal_baseline")
            try measureQuery(database, query: query, phase: "cjk_tgrep_comparison")
        }

        let unchangedStart = ContinuousClock.now
        let unchanged = try scanner.scanAll()
        emit(["phase": "reconciliation", "elapsed_ms": milliseconds(since: unchangedStart),
            "unchanged": unchanged.unchanged, "parsed": unchanged.parsed, "failed": unchanged.failed,
            "deferred": unchanged.deferred, "removed": unchanged.removed,
            "process_peak_rss_bytes": peakRSS()])
        try measureQuery(database, query: "performance", phase: "after_reconciliation")
        emit(["phase": "complete", "elapsed_ms": milliseconds(since: coldStart),
            "process_peak_rss_bytes": peakRSS()])
    }

    static func measureQuery(_ database: ConversationIndexDatabase, query: String, phase: String) throws {
        let started = ContinuousClock.now
        do {
            let result = try database.candidateDocumentReferences(for: query)
            let diagnostics = database.searchDiagnostics
            let matcher = ConversationLiteralSearch(query: query)
            var matchedSessions = Set<String>()
            var verifiedDocuments = 0
            var documentReadMS: Double = 0
            var literalMatchMS: Double = 0
            var fastFirstMatchMS: Double = 0
            var completeMatchMS: Double = 0
            var exactOccurrences = 0
            var verifiedTextBytes = 0
            var decodedMessageSpans = 0
            for reference in result.references.sorted(by: ConversationIndexDatabase.referenceComesFirst) {
                if matchedSessions.contains(reference.sessionPath) { continue }
                let documentStart = ContinuousClock.now
                guard let document = try database.document(id: reference.documentID,
                    expectedSessionPath: reference.sessionPath, expectedTranscriptID: reference.transcriptID) else { continue }
                documentReadMS += milliseconds(since: documentStart)
                verifiedDocuments += 1
                verifiedTextBytes += document.text.utf8.count
                decodedMessageSpans += document.messageSpans.count
                let matchStart = ContinuousClock.now
                let originalRange = document.text.range(of: query, options: [.caseInsensitive])
                if originalRange != nil {
                    matchedSessions.insert(reference.sessionPath)
                }
                literalMatchMS += milliseconds(since: matchStart)
                let fastStart = ContinuousClock.now
                let fastRange = matcher.firstMatch(in: document.text)
                fastFirstMatchMS += milliseconds(since: fastStart)
                let completeStart = ContinuousClock.now
                let complete = matcher.match(in: document.text)
                completeMatchMS += milliseconds(since: completeStart)
                guard originalRange == fastRange, originalRange == complete?.range else {
                    throw BenchmarkFailure.literalParity
                }
                exactOccurrences += complete?.count ?? 0
                if matchedSessions.count == 200 { break }
            }
            emit(["phase": phase, "query": query, "engine": diagnostics.engine,
                "candidate_ms": diagnostics.queryMilliseconds,
                "with_literal_verification_ms": diagnostics.queryMilliseconds + documentReadMS + literalMatchMS,
                "with_fast_verification_ms": diagnostics.queryMilliseconds + documentReadMS + fastFirstMatchMS,
                "with_complete_match_count_ms": diagnostics.queryMilliseconds + documentReadMS + completeMatchMS,
                "indexed_documents": diagnostics.indexedDocuments, "incremental_documents": diagnostics.incrementallyIndexedDocuments,
                "normalization_ms": diagnostics.cumulativeNormalizationMilliseconds,
                "trigram_build_ms": diagnostics.cumulativeTrigramBuildMilliseconds,
                "candidates": diagnostics.candidateCount, "verified_documents": verifiedDocuments,
                "document_read_ms": documentReadMS, "literal_match_ms": literalMatchMS,
                "fast_first_match_ms": fastFirstMatchMS, "complete_match_count_ms": completeMatchMS,
                "exact_occurrences": exactOccurrences, "first_match_parity": true,
                "restored_from_cache": diagnostics.restoredFromCache,
                "verified_text_bytes": verifiedTextBytes, "decoded_message_spans": decodedMessageSpans,
                "matched_sessions_capped_at_200": matchedSessions.count, "used_fallback": diagnostics.usedFallback,
                "process_peak_rss_bytes": peakRSS()])
        } catch {
            emit(["phase": phase, "query": query, "failed": true,
                "error_type": String(describing: type(of: error)), "elapsed_ms": milliseconds(since: started)])
            throw error
        }
    }

    static func measureRepositoryQuery(_ repository: IndexedHistoryRepository, sessions: [HistorySessionMetadata], query: String, phase: String) throws {
        let started = ContinuousClock.now
        let hits = try repository.search(query: query, limit: ConversationCatalogLimits.searchHits)
        let elapsed = milliseconds(since: started)
        let diagnostics = repository.database.searchDiagnostics
        guard hits.allSatisfy({ $0.count > 0 && !$0.snippet.isEmpty }) else {
            throw BenchmarkFailure.invalidRepositoryHit
        }
        // Independent Foundation checks on bounded real documents run after the timed search.
        // Large transcripts remain fully searched/counted by production; only this expensive
        // differential oracle is sampled. No private text, identity, or path is emitted.
        let verified = try verifySmallRepositoryHits(hits, query: query, sessions: sessions, database: repository.database)
        emit(["phase": phase, "query": query, "engine": diagnostics.engine,
            "repository_search_ms": elapsed, "candidate_ms": diagnostics.queryMilliseconds,
            "matched_sessions_capped_at_200": hits.count,
            "exact_occurrences": hits.reduce(0) { $0 + $1.count },
            "located_message_spans": hits.filter { $0.sequence != nil }.count,
            "nonempty_snippets": hits.filter { !$0.snippet.isEmpty }.count,
            "nested_transcript_hits": hits.filter { $0.agent != "main" }.count,
            "foundation_count_snippet_anchor_parity_samples": verified,
            "restored_from_cache": diagnostics.restoredFromCache,
            "used_fallback": diagnostics.usedFallback,
            "process_peak_rss_bytes": peakRSS()])
    }

    static func verifySmallRepositoryHits(_ hits: [HistorySearchHit], query: String,
        sessions: [HistorySessionMetadata], database: ConversationIndexDatabase) throws -> Int {
        let references = try database.candidateDocumentReferences(for: query).references
        let refs = Dictionary(grouping: references, by: { $0.sessionPath })
        let rows = Dictionary(uniqueKeysWithValues: sessions.map { (ConversationIndexDatabase.normalizedPath($0.file), $0) })
        var verified = 0
        for hit in hits {
            let parentPath = ConversationIndexDatabase.normalizedPath(hit.file)
            var path = parentPath
            var transcript = hit.agent
            if let child = rows[parentPath]?.subagentRefs.first(where: { $0.threadID == hit.agent }) {
                path = ConversationIndexDatabase.normalizedPath(child.file)
                transcript = "main"
            }
            guard let reference = refs[path]?.first(where: { $0.transcriptID == transcript }),
                  let entry = try database.entry(forPath: path), entry.metadata.sizeBytes <= 131_072,
                  let document = try database.document(id: reference.documentID,
                    expectedSessionPath: path, expectedTranscriptID: transcript),
                  document.text.utf8.count <= 131_072 else { continue }
            var cursor = document.text.startIndex
            var count = 0
            var first: Range<String.Index>?
            while cursor < document.text.endIndex,
                  let range = document.text.range(of: query, options: .caseInsensitive, range: cursor..<document.text.endIndex) {
                if first == nil { first = range }
                count += 1
                cursor = range.upperBound
            }
            guard let first, count == hit.count else { throw BenchmarkFailure.literalParity }
            let start = document.text.index(first.lowerBound, offsetBy: -56, limitedBy: document.text.startIndex) ?? document.text.startIndex
            let end = document.text.index(first.upperBound, offsetBy: 56, limitedBy: document.text.endIndex) ?? document.text.endIndex
            let snippet = (start > document.text.startIndex ? "…" : "")
                + document.text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                + (end < document.text.endIndex ? "…" : "")
            let offset = first.lowerBound.utf16Offset(in: document.text)
            let span = document.messageSpans.first { offset >= $0.utf16Location && offset < $0.utf16Location + max(1, $0.utf16Length) }
                ?? document.messageSpans.first { $0.utf16Location >= offset } ?? document.messageSpans.last
            guard snippet == hit.snippet, span?.sequence == hit.sequence else { throw BenchmarkFailure.invalidRepositoryHit }
            verified += 1
            if verified == 3 { break }
        }
        return verified
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    static func peakRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss) // Darwin reports bytes, unlike Linux's KiB.
    }

    static func fileBytes(_ file: URL) -> Int {
        [file.path, file.path + "-wal", file.path + "-shm"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    static func emit(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    enum BenchmarkFailure: Error { case parse, engineUnavailable, invalidCatalog, literalParity, invalidRepositoryHit }
}
