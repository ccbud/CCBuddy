import Darwin
import Foundation

/// Compiled with production History sources. No UI, gateway or history-mutation code is linked.
/// Every catalog write is confined to an explicitly supplied private benchmark directory.
@main
enum RealHistoryBenchmark {
    static let producerRoots: [(String, String)] = [
        ("Claude", ".claude"), ("Claude XDG", ".config/claude"),
        ("Codex", ".codex"), ("Qoder", ".qoder"), ("QoderWork", ".qoderwork"),
        ("Grok", ".grok"), ("Copilot", ".copilot"),
        ("Antigravity", ".gemini/antigravity-cli"),
    ]
    static let requiredQueries = ["系统代理", "当前版本"]
    // Public terms only: never extract or emit queries from private conversation content.
    static let catalogQueries = requiredQueries + [
        "native/Sources", "ConversationFileCatalog", "Swift 代码", "error", "搜索",
        "工具", "代码", "performance", "Swift",
    ]
    private static let postTimingParityFailures = PostTimingParityFailures()
    private static let transientQueryFailures = PostTimingParityFailures()

    private final class PostTimingParityFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    static func main() async {
        do {
            try await run()
            // A separate live-source comparison can differ after a valid timed snapshot.
            // Keep collecting subsequent query/preparation evidence, but never turn that
            // difference into a parity pass or a successful process exit.
            if transientQueryFailures.count != 0 { throw BenchmarkFailure.queryExecutionFailure }
            if postTimingParityFailures.count != 0 { throw BenchmarkFailure.progressiveParity }
        }
        catch {
            var row: [String: Any] = ["phase": "failed",
                "error_type": String(describing: type(of: error))]
            // Only value-free local reason codes are safe to describe. Cocoa/producer errors
            // can contain full paths or content and must never be serialized here.
            if let known = error as? BenchmarkFailure { row["reason"] = String(describing: known) }
            else if let reason = safeProductionFailureReason(error) { row["reason"] = reason }
            emit(row)
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") {
            print("""
            Usage:
              benchmark-real-history.sh --inventory|--largest|--detail
              benchmark-real-history.sh --source-search
              benchmark-real-history.sh --inventory --catalog <private directory>
              benchmark-real-history.sh --run --catalog <private directory> [--prepare-index]
              benchmark-real-history.sh --queries --catalog <private directory> [--prepare-index]
              benchmark-real-history.sh --restore --prepare-index --catalog <private directory>
            Query options: --repository | --progressive-repository | --fallback-repository
            Optional: --require-known-hits (require the two fixed public Chinese phrases).
            Narrow restored profiles: --only-primary-query, --only-required-queries, --only-broad-query, --core-queries.
            Stat-only coverage audit: --coverage-profile --catalog <private directory>.
            Post-timing parity differences are reported per query; measurements continue,
            then the process exits nonzero if any such comparison failed.
            Typed source-revision execution failures likewise remain failures while later
            measurement phases continue; other execution/invariant failures stop immediately.
            Compile only: benchmark-real-history.sh --compile-only
            A catalog must be named catalog inside a mode-0700, same-owner directory named
            native/build/ccbuddy-query-benchmark.<random>. Create its parent with mktemp -d.
            --run creates/updates only that explicit derived catalog and retains it for later runs.
            --queries first measures direct search without scheduling preparation; --prepare-index
            then prepares explicitly. Repository modes keep production's automatic background
            scheduling, so only the first query enters without an earlier benchmark query.
            --restore is a separate fresh-process measurement: no query/list/body prewarm occurs
            before explicit checkpoint preparation. OS filesystem caches are not flushed.
            --inventory/--largest/--detail never create or open a conversation catalog.
            --source-search verifies fixed public queries in the largest ordinary Codex/Claude
            JSONL; source fingerprints and a full-parser oracle are checked outside timings.
            Private source paths, titles, IDs, snippets and original text are never printed.
            Retired options: --migrate, --baseline-fts, --show-roots.
            """)
            return
        }
        guard !arguments.contains("--migrate"), !arguments.contains("--baseline-fts"),
              !arguments.contains("--migration-timeout-seconds") else {
            throw BenchmarkFailure.retiredStorageMode
        }
        guard !arguments.contains("--show-roots") else { throw BenchmarkFailure.privatePathOutputRetired }
        let fallback = arguments.contains("--fallback-repository")
        let progressive = arguments.contains("--progressive-repository")
        let finalRepository = arguments.contains("--repository")
        guard [fallback, progressive, finalRepository].filter({ $0 }).count <= 1 else {
            throw BenchmarkFailure.conflictingModes
        }
        let restore = arguments.contains("--restore")
        let prepareIndex = arguments.contains("--prepare-index")
        guard !restore || prepareIndex, !(fallback && (prepareIndex || restore)) else {
            throw BenchmarkFailure.conflictingModes
        }
        let inventory = arguments.contains("--inventory")
        let largest = arguments.contains("--largest")
        let detail = arguments.contains("--detail")
        let coverageProfile = arguments.contains("--coverage-profile")
        let sourceSearch = arguments.contains("--source-search")
        let scan = arguments.contains("--run")
        let queries = arguments.contains("--queries") || restore
            || (!scan && (fallback || progressive || finalRepository))
        guard [inventory, largest, detail, sourceSearch, coverageProfile, scan, queries].filter({ $0 }).count == 1 else {
            throw BenchmarkFailure.conflictingModes
        }
        let catalog = try catalogArgument()
        if let catalog {
            try validatePrivateCatalog(catalog, allowMissing: scan)
        } else if scan || queries || coverageProfile {
            throw BenchmarkFailure.invalidCatalog
        }
        if inventory, let catalog {
            emit(["phase": "catalog_inventory", "storage": try catalogInventory(catalog),
                "disk": diskFootprint(catalog), "opens_catalog": false, "producer_reads": false])
            return
        }
        if coverageProfile, let catalog {
            try profileCoverage(ConversationFileCatalog(file: catalog, enableTgrep: false))
            return
        }
        if let catalog, queries {
            let opened = ContinuousClock.now
            let database = try ConversationFileCatalog(file: catalog, enableTgrep: !fallback)
            emit(["phase": "catalog_open", "elapsed_ms": milliseconds(since: opened),
                "index_mode": "immutable_file_packs_grouped_tgrep",
                "metadata_or_body_prewarm": false, "checkpoint_preparation_started": false,
                "fresh_process_restore_requested": restore, "os_filesystem_cache_flushed": false])
            try await measureQueryPhases(database, arguments: arguments, freshProcessRestore: restore,
                producerScanPrewarmed: false)
            return
        }
        guard catalog == nil || scan else { throw BenchmarkFailure.conflictingModes }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let locations = sourceLocations(home: home)
        let scratch = ProcessInfo.processInfo.environment["CCBUD_BENCHMARK_SCRATCH"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? manager.temporaryDirectory
        let temporary = scratch.appendingPathComponent("ccbuddy-real-history-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        // Preserve the historic benchmark cohort: source trees, without importing the app's
        // own library. An empty isolated imports root also avoids reading app annotation sidecars.
        // A retained catalog's dependency identities must not refer to the launcher's disposable
        // scratch path. Reopening uses this same isolated annotation/import namespace.
        let importsRoot = catalog.map { $0.deletingLastPathComponent().appendingPathComponent("benchmark-app/imports") }
            ?? temporary.appendingPathComponent("imports")
        let configuration = HistoryConfiguration(historyDirs: locations.map(\.path), homeDirectory: home,
            importsRoot: importsRoot)
        let loader = HistorySessionLoader(configuration: configuration)
        let discoveryStart = ContinuousClock.now
        let candidates = loader.discoverCandidates(activeOnly: false)
        let discoveryMS = milliseconds(since: discoveryStart)
        let sized = candidates.map {
            ($0, (try? $0.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let inventoryRows: [[String: Any]] = locations.map { location in
            let files = sized.filter { $0.0.directory.baseURL == URL(fileURLWithPath: location.path) }
            return ["producer": location.label, "session_files": files.count,
                "exists": manager.fileExists(atPath: location.path),
                "total_bytes": files.reduce(0) { $0 + $1.1 },
                "largest_file_bytes": files.map(\.1).max() ?? 0]
        }
        emit(["phase": "inventory", "roots": inventoryRows, "discovery_ms": discoveryMS,
            "session_files": candidates.count, "total_bytes": sized.reduce(0) { $0 + $1.1 },
            "tgrep_available": TgrepSearchIndex.isAvailable, "settings_read_only": true,
            "imports_excluded": true, "app_annotation_sidecars_loaded": false,
            "process_peak_rss_bytes": peakRSS()])
        if inventory { return }
        if sourceSearch {
            let ordinary = sized.filter { item in
                item.0.file.pathExtension == "jsonl" && !QoderFileReader.isQoderDataPath(item.0.file)
            }.sorted { $0.1 > $1.1 }
            for item in ordinary {
                guard let quick = loader.loadQuickMetadata([item.0]).first,
                      quick.metadata.source == .codex || quick.metadata.source == .claude else { continue }
                try measureSourceQueries(quick, loader: loader, sourceBytes: item.1)
                return
            }
            throw BenchmarkFailure.emptyRepositoryScope
        }
        if largest || detail {
            guard let largestFile = sized.max(by: { $0.1 < $1.1 }) else { return }
            let before = peakRSS(), started = ContinuousClock.now
            if detail {
                let session = try loader.getSession(file: largestFile.0.file)
                emit(["phase": "largest_detail_session", "file_bytes": largestFile.1,
                    "source": session.metadata.source.rawValue, "messages": session.messages.count,
                    "subagents": session.subagents.count, "detail_load_ms": milliseconds(since: started),
                    "includes_catalog_projection": false, "includes_ui_projection": false,
                    "baseline_peak_rss_bytes": before, "process_peak_rss_bytes": peakRSS()])
            } else {
                let loaded = try loader.load(largestFile.0, consistency: .bestEffort)
                emit(["phase": "largest_session", "file_bytes": largestFile.1,
                    "source": loaded.session.metadata.source.rawValue,
                    "messages": loaded.session.messages.count, "subagents": loaded.session.subagents.count,
                    "visible_search_bytes": loaded.projection.threads.reduce(0) { $0 + $1.searchText.utf8.count },
                    "parse_ms": milliseconds(since: started), "baseline_peak_rss_bytes": before,
                    "process_peak_rss_bytes": peakRSS()])
            }
            return
        }
        guard let catalog else { throw BenchmarkFailure.invalidCatalog }
        let database = try ConversationFileCatalog(file: catalog, enableTgrep: !fallback)
        let observedLoader = ScanFailureProbe(loader: loader)
        let scanner = ConversationIndexScanner(configuration: configuration, database: database,
            loader: observedLoader, reparseSpacing: .immediate)
        let started = ContinuousClock.now
        let firstMetadata = FirstMetadataProbe()
        let result = try scanner.scanAll(onProgress: { progress in
            firstMetadata.record(progress, elapsed: milliseconds(since: started))
            if progress.completed > 0, progress.completed.isMultiple(of: 100) {
                emit(["phase": "catalog_scan_progress", "completed": progress.completed,
                    "discovered": progress.discovered, "failed": progress.failed,
                    "elapsed_ms": milliseconds(since: started), "process_peak_rss_bytes": peakRSS()])
            }
        })
        emit(["phase": "catalog_scan_complete", "elapsed_ms": milliseconds(since: started),
            "first_metadata_published_ms": firstMetadata.elapsed.map { $0 as Any } ?? NSNull(),
            "discovered": result.discovered, "parsed": result.parsed, "failed": result.failed,
            "failed_load_attempt_kinds": observedLoader.attemptKinds,
            "unresolved_source_failure_kinds": observedLoader.unresolvedKinds,
            "unclassified_failed_sources": max(0, result.failed - observedLoader.unresolvedCount),
            "unchanged": result.unchanged, "metadata_published": result.metadataPublished,
            "complete": result.failed == 0 && result.deferred == 0,
            "postings_preparation_started": false, "producer_transcripts_read_only": true,
            "disk": diskFootprint(catalog), "process_peak_rss_bytes": peakRSS()])
        try await measureQueryPhases(database, arguments: arguments, freshProcessRestore: false,
            producerScanPrewarmed: true)
    }

    private static func measureQueryPhases(_ database: ConversationFileCatalog, arguments: Set<String>,
        freshProcessRestore: Bool, producerScanPrewarmed: Bool) async throws {
        let started = ContinuousClock.now
        let prepareIndex = arguments.contains("--prepare-index")
        let fallback = arguments.contains("--fallback-repository")
        let repositoryMode = arguments.contains("--repository")
            || arguments.contains("--progressive-repository") || fallback
        // Opening and stat inventory do not prewarm metadata or body blocks. Repository mode
        // necessarily resolves canonical scopes before search; that cost is reported separately.
        if !freshProcessRestore {
            try queryPass(database, arguments: arguments, phase: "cold_entry",
                producerScanPrewarmed: producerScanPrewarmed, preparationPrewarmed: false,
                precedingQueryPass: false, repositoryMode: repositoryMode,
                queries: Array(catalogQueries.prefix(1)), includeRepeats: false)
        }
        if prepareIndex {
            // Keep one publisher lease for this process. Production repository search may have
            // already scheduled its background worker; this measures only the remaining wait.
            // Subsequent new terms have no exact-answer entry, while the first term is labeled
            // as an intentional repeat. Fresh-process restore has neither preceding queries nor
            // any other catalog instance/published mmap competing for its publisher lease.
            let preparationStarted = ContinuousClock.now
            database.scheduleSearchIndexPreparation()
            await database.waitForSearchIndexPreparation()
            emit(["phase": freshProcessRestore ? "restart_checkpoint_preparation" : "index_preparation",
                "elapsed_ms": milliseconds(since: preparationStarted),
                "timing_scope": repositoryMode && !freshProcessRestore
                    ? "remaining_wait_for_production_background_worker" : "explicit_preparation_to_worker_completion",
                "elapsed_since_query_sequence_started_ms": milliseconds(since: started),
                "before_any_query_or_list": freshProcessRestore,
                "preceding_first_query": !freshProcessRestore,
                "production_may_have_scheduled_background_before_wait": repositoryMode && !freshProcessRestore,
                "producer_scan_prewarmed": producerScanPrewarmed,
                "os_filesystem_cache_flushed": false, "foreground_query_includes_preparation": false,
                "single_catalog_publisher_instance": true,
                "disk": diskFootprint(database.file), "process_peak_rss_bytes": peakRSS()])
            try queryPass(database, arguments: arguments,
                phase: freshProcessRestore ? "restart_restored" : "after_preparation",
                producerScanPrewarmed: producerScanPrewarmed, preparationPrewarmed: true,
                precedingQueryPass: !freshProcessRestore, repositoryMode: repositoryMode,
                queries: freshProcessRestore ? catalogQueries : Array(catalogQueries.dropFirst()),
                includeRepeats: true)
        } else {
            try queryPass(database, arguments: arguments,
                phase: repositoryMode && !fallback ? "runtime_background_warming" : "unprepared_direct",
                producerScanPrewarmed: producerScanPrewarmed, preparationPrewarmed: false,
                precedingQueryPass: true, repositoryMode: repositoryMode,
                queries: Array(catalogQueries.dropFirst()), includeRepeats: true)
        }
        // A repository-mode query can start the real worker without --prepare-index. Drain it
        // before the launcher removes its ephemeral dylib/bundle; report this time separately.
        let drainStarted = ContinuousClock.now
        database.cancelSearchIndexPreparation()
        await database.waitForSearchIndexPreparation()
        emit(["phase": "background_shutdown", "elapsed_ms": milliseconds(since: drainStarted),
            "included_in_query_timings": false])
        emit(["phase": "complete", "elapsed_ms": milliseconds(since: started),
            "catalog_retained_for_next_process": true, "disk": diskFootprint(database.file),
            "measurements_complete": true,
            "validation_passed": postTimingParityFailures.count == 0 && transientQueryFailures.count == 0,
            "post_timing_parity_failures": postTimingParityFailures.count,
            "transient_query_execution_failures": transientQueryFailures.count,
            "process_peak_rss_bytes": peakRSS()])
    }

    private static func queryPass(_ database: ConversationFileCatalog, arguments: Set<String>,
        phase: String, producerScanPrewarmed: Bool, preparationPrewarmed: Bool,
        precedingQueryPass: Bool, repositoryMode: Bool, queries: [String], includeRepeats: Bool) throws {
        let queries = arguments.contains("--only-primary-query") ? queries.filter { $0 == requiredQueries[0] }
            : arguments.contains("--only-required-queries") ? queries.filter { requiredQueries.contains($0) }
            : arguments.contains("--only-broad-query") ? queries.filter { $0 == "error" }
            : arguments.contains("--core-queries") ? queries.filter { requiredQueries.contains($0) || $0 == "error" } : queries
        let includeRepeats = includeRepeats && !arguments.contains("--only-primary-query")
            && !arguments.contains("--only-required-queries")
            && !arguments.contains("--only-broad-query")
            && !arguments.contains("--core-queries")
        emit(["phase": phase + "_query_contract", "search_backend": repositoryMode ? "repository" : "direct_blocks",
            "metadata_cache_prewarmed_by_preparation": preparationPrewarmed,
            "body_os_cache_may_be_warm_from_prior_query_pass": precedingQueryPass,
            "producer_scan_prewarmed": producerScanPrewarmed,
            "exact_answer_cache_initially_empty": !precedingQueryPass,
            "nonrepeat_terms_have_no_prior_exact_answer": true,
            "repository_automatically_schedules_background": repositoryMode && !arguments.contains("--fallback-repository"),
            "os_filesystem_cache_flushed": false, "only_first_query_is_first_in_pass": true,
            "repeat_queries_and_post_timing_oracles_prewarm_later_queries": true,
            "producer_transcript_reads_possible": repositoryMode, "producer_metadata_reads_possible": repositoryMode,
            "includes_ui_first_paint": false])
        if repositoryMode {
            let setup = ContinuousClock.now
            let entries = try database.listEntries(deleted: nil, limit: .max)
            let scopes = Set(entries.compactMap { entry -> String? in
                let id = entry.metadata.dirID
                return !entry.scope.hasPrefix("__") && !id.hasPrefix("__")
                    && (id.hasPrefix("~/") || (id as NSString).isAbsolutePath) ? id : nil
            }).sorted()
            guard !scopes.isEmpty else { throw BenchmarkFailure.emptyRepositoryScope }
            let repository = IndexedHistoryRepository(configuration: .init(historyDirs: scopes,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                importsRoot: database.file.deletingLastPathComponent().appendingPathComponent("benchmark-app/imports")), database: database)
            let configuredRoots = Set(sourceLocations(home: repository.configuration.homeDirectory).map(\.path))
            let resolvedScopes = Set(scopes.map {
                HistoryPathResolver.expandTilde($0, homeDirectory: repository.configuration.homeDirectory)
                    .resolvingSymlinksInPath().standardizedFileURL.path
            })
            guard resolvedScopes.isSubset(of: configuredRoots) else {
                throw BenchmarkFailure.catalogConfigurationChanged
            }
            let listed = try repository.listSessions(limit: ConversationCatalogLimits.searchScan)
            // Match the independent source oracle's largest ordinary Codex/Claude source.
            // This stat-only selection runs outside query timing; its private identity is
            // retained solely for callback comparison and is never included in output.
            let target = entries.compactMap { entry -> QueryTarget? in
                guard entry.metadata.source == .codex || entry.metadata.source == .claude,
                      entry.metadata.file.pathExtension == "jsonl",
                      !QoderFileReader.isQoderDataPath(entry.metadata.file),
                      let bytes = try? entry.metadata.file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    return nil
                }
                return QueryTarget(path: ConversationFileCatalog.normalizedPath(entry.metadata.file), bytes: bytes)
            }.max { $0.bytes < $1.bytes }
            let physical = Set(entries.filter { !$0.scope.hasPrefix("__") }.map(\.sourcePath))
            guard listed.allSatisfy({ !$0.dirID.hasPrefix("__") && physical.contains($0.file.path) }) else {
                throw BenchmarkFailure.virtualRepositoryScope
            }
            emit(["phase": phase + "_repository_setup", "elapsed_ms": milliseconds(since: setup),
                "metadata_cache_prewarmed_for_scope_resolution": true,
                "visible_canonical_sessions": listed.count, "physical_scope_count": scopes.count,
                "catalog_scopes_still_authorized_by_current_configuration": true,
                "stable_isolated_imports_namespace": true,
                "persisted_body_proof_rows": entries.filter { $0.fingerprint.searchContentFingerprint != nil }.count,
                "legacy_rows_without_body_proof": entries.filter { $0.fingerprint.searchContentFingerprint == nil }.count])
            for (index, query) in queries.enumerated() {
                let label = phase + (index == 0 ? "_first_query" : "_subsequent_query")
                if arguments.contains("--progressive-repository") {
                    try measureProgressiveRepositoryQuery(repository, sessions: listed, query: query, phase: label,
                        target: target)
                } else {
                    try measureRepositoryQuery(repository, sessions: listed, query: query, phase: label,
                        requiringFallback: arguments.contains("--fallback-repository"))
                }
            }
            if includeRepeats {
                for query in requiredQueries {
                    try measureProgressiveRepositoryQuery(repository, sessions: listed, query: query,
                        phase: phase + "_repeat_query", target: target)
                }
            }
        } else {
            for (index, query) in queries.enumerated() {
                try measureQuery(database, query: query,
                    phase: phase + (index == 0 ? "_first_query" : "_subsequent_query"))
            }
            if includeRepeats {
                for query in requiredQueries { try measureQuery(database, query: query, phase: phase + "_repeat_query") }
            }
        }
    }

    private static func catalogArgument() throws -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--catalog") else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1),
              !CommandLine.arguments[index + 1].hasPrefix("--") else { throw BenchmarkFailure.invalidCatalog }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true).standardizedFileURL
    }

    /// Stat-only contributor audit. Codex state/config dependencies are event-only, so this
    /// deliberately does not read either file just to reconstruct their excluded event paths.
    private static func profileCoverage(_ database: ConversationFileCatalog) throws {
        let start = ContinuousClock.now
        let entries = try database.listEntries(deleted: nil, limit: .max)
        let metadataMS = milliseconds(since: start)
        let scopes = Array(Set(entries.map(\.scope).filter { !$0.hasPrefix("__") })).sorted()
        let configuration = HistoryConfiguration(historyDirs: scopes,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            importsRoot: database.file.deletingLastPathComponent().appendingPathComponent("benchmark-app/imports"))
        let loader = HistorySessionLoader(configuration: configuration)
        var validationMS = 0.0, manifestsMS = 0.0, statMS = 0.0, hashingMS = 0.0
        var invalidPaths = 0, changed = 0, changedPrimary = 0, changedBody = 0, annotationOnly = 0
        var changedBytes: UInt64 = 0, largestChangedBytes: UInt64 = 0
        var changedBySource: [String: Int] = [:], contributingRoles: [String: Int] = [:]
        var changedManifests: [(ConversationDependencyManifest, ConversationDependencySnapshot)] = []
        for entry in entries {
            let validating = ContinuousClock.now
            guard let candidate = try? loader.pathResolver.validatedCandidate(for: entry.metadata.file),
                  candidate.directory.id == entry.scope else {
                validationMS += milliseconds(since: validating); invalidPaths += 1; continue
            }
            validationMS += milliseconds(since: validating)
            let manifestStarted = ContinuousClock.now
            let manifest: ConversationDependencyManifest
            if entry.metadata.source == .codex {
                var dependencies: [ConversationSourceDependency] = [
                    .init(file: candidate.file, role: .primaryTranscript),
                ]
                if candidate.directory.id != "__imported__" {
                    dependencies.append(.init(file: configuration.appDataRoot.appendingPathComponent("codex-meta.json"),
                                              role: .customMetadata))
                }
                manifest = .init(candidate: candidate, source: .codex, dependencies: dependencies)
            } else {
                let format: HistoryTranscriptFormat
                switch entry.metadata.source {
                case .claude: format = .claude
                case .codex: format = .codex
                case .qoder: format = .qoder
                case .grok: format = .grok
                case .copilot: format = .copilot
                case .antigravity: format = .antigravity
                }
                manifest = try loader.adapters.manifest(for: candidate, format: format, configuration: configuration)
            }
            manifestsMS += milliseconds(since: manifestStarted)
            let statStarted = ContinuousClock.now
            let snapshot = manifest.snapshot()
            statMS += milliseconds(since: statStarted)
            let hashingStarted = ContinuousClock.now
            let full = snapshot.fingerprint
            let body = ConversationIndexFingerprint.contentFingerprint(manifest: manifest, snapshot: snapshot)
            hashingMS += milliseconds(since: hashingStarted)
            guard full != entry.fingerprint.dependencyFingerprint else { continue }
            changed += 1
            changedBySource[entry.metadata.source.rawValue, default: 0] += 1
            changedManifests.append((manifest, snapshot))
            if let primary = manifest.primary, let stamp = snapshot.stamp(for: primary.file, role: primary.role) {
                let bytes = stamp.sizeBytes ?? 0
                changedBytes += bytes; largestChangedBytes = max(largestChangedBytes, bytes)
                let oldNanoseconds = Int64((entry.fingerprint.modificationTime.timeIntervalSince1970 * 1_000_000_000).rounded())
                if stamp.sizeBytes != entry.fingerprint.sizeBytes || stamp.modifiedAtNanoseconds != oldNanoseconds {
                    changedPrimary += 1
                }
            }
            if entry.fingerprint.searchContentFingerprint == body { annotationOnly += 1 }
            else { changedBody += 1 }
            for stamp in snapshot.stamps { contributingRoles[stamp.role.rawValue, default: 0] += 1 }
        }
        let mutatedDuringAudit = changedManifests.filter { $0.0.snapshot() != $0.1 }.count
        emit(["phase": "coverage_stat_profile", "entries": entries.count,
            "metadata_list_ms": metadataMS, "path_validation_ms": validationMS,
            "contributing_manifest_ms": manifestsMS, "dependency_stat_ms": statMS,
            "fingerprint_hash_ms": hashingMS, "elapsed_ms": milliseconds(since: start),
            "invalid_or_unavailable_paths": invalidPaths, "source_revision_different": changed,
            "primary_size_or_mtime_different": changedPrimary, "body_proof_different_or_missing": changedBody,
            "proven_annotation_only_differences": annotationOnly,
            "changed_source_bytes": changedBytes, "largest_changed_source_bytes": largestChangedBytes,
            "changed_sources_by_producer": changedBySource,
            "changed_manifest_contributing_roles": contributingRoles,
            "changed_sources_mutated_again_during_audit": mutatedDuringAudit,
            "source_content_read": false, "codex_event_only_config_or_database_read": false,
            "metadata_discovery_performed": false, "tgrep_preparation_started": false,
            "process_peak_rss_bytes": peakRSS()])
    }

    static func validatePrivateCatalog(_ file: URL, allowMissing: Bool = false) throws {
        let parent = file.deletingLastPathComponent(), prefix = "ccbuddy-query-benchmark."
        guard let rawRoot = ProcessInfo.processInfo.environment["CCBUD_BENCHMARK_BUILD_ROOT"],
              file.lastPathComponent == "catalog", parent.lastPathComponent.hasPrefix(prefix),
              !parent.lastPathComponent.dropFirst(prefix.count).isEmpty,
              parent.deletingLastPathComponent() == URL(fileURLWithPath: rawRoot, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL,
              file.resolvingSymlinksInPath().standardizedFileURL == file else {
            throw BenchmarkFailure.invalidCatalog
        }
        var parentStat = stat()
        guard lstat(parent.path, &parentStat) == 0, parentStat.st_mode & S_IFMT == S_IFDIR,
              parentStat.st_mode & 0o077 == 0, parentStat.st_uid == geteuid() else {
            throw BenchmarkFailure.invalidCatalog
        }
        var metadata = stat()
        if lstat(file.path, &metadata) != 0 {
            guard allowMissing, errno == ENOENT else { throw BenchmarkFailure.invalidCatalog }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0,
              metadata.st_uid == geteuid() else { throw BenchmarkFailure.invalidCatalog }
    }

    /// Source settings are read for location discovery only. No values except aggregate counts
    /// and fixed producer labels escape this process; unknown configured roots get ordinal labels.
    private static func sourceLocations(home: URL) -> [(label: String, path: String)] {
        var locations = producerRoots.map { (label: $0.0, path: home.appendingPathComponent($0.1).path) }
        let configRoot = ProcessInfo.processInfo.environment["CCBUD_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".ccbud")
        var disabled = Set<String>()
        if let values = ForeignHistorySupport.jsonObject(at: configRoot.appendingPathComponent("config.json")) {
            disabled = Set((values["disabledHistoryDirs"]?.arrayValue ?? []).compactMap(\.stringValue).map {
                HistoryPathResolver.expandTilde($0, homeDirectory: home).resolvingSymlinksInPath().standardizedFileURL.path
            })
            for (index, raw) in (values["historyDirs"]?.arrayValue ?? []).compactMap(\.stringValue).enumerated() {
                locations.append(("Configured \(index + 1)",
                    HistoryPathResolver.expandTilde(raw, homeDirectory: home).path))
            }
        }
        var seen = Set<String>()
        return locations.compactMap { item in
            let path = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard !disabled.contains(path), seen.insert(path).inserted else { return nil }
            return (item.label, path)
        }
    }

    static func catalogInventory(_ file: URL) throws -> [String: Int64] {
        let manifest = file.appendingPathComponent("manifest.json")
        guard ForeignHistorySupport.isOrdinaryFile(manifest),
              let bytes = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= 64 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let version = object["version"] as? NSNumber,
              let generation = object["generation"] as? NSNumber,
              let objects = object["objects"] as? [String: Any] else { throw BenchmarkFailure.storageProbe }
        return ["format_version": version.int64Value, "generation": generation.int64Value,
            "session_records": Int64(objects.count)]
    }

    /// Stat-only inventory; hard links count once. No filename or content is emitted.
    /// Allocated bytes are inode block counts, not APFS clone-exclusive disk usage.
    static func diskFootprint(_ file: URL) -> [String: Int64] {
        var stack = [file], seen = Set<String>()
        var bytes: Int64 = 0, allocated: Int64 = 0, files: Int64 = 0, links: Int64 = 0
        var headers: Int64 = 0, packs: Int64 = 0
        while let item = stack.popLast() {
            var metadata = stat()
            guard lstat(item.path, &metadata) == 0 else { continue }
            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFLNK { links += 1; continue }
            guard seen.insert("\(metadata.st_dev):\(metadata.st_ino)").inserted else { continue }
            if kind == S_IFDIR {
                stack += (try? FileManager.default.contentsOfDirectory(at: item,
                    includingPropertiesForKeys: nil)) ?? []
            } else if kind == S_IFREG {
                files += 1; bytes += metadata.st_size; allocated += metadata.st_blocks * 512
                if item.pathExtension == "header" { headers += metadata.st_size }
                if item.pathExtension == "pack" { packs += metadata.st_size }
            }
        }
        return ["unique_inode_file_bytes": bytes, "unique_inode_allocated_bytes": allocated,
            "unique_regular_files": files, "metadata_header_bytes": headers, "packed_body_bytes": packs,
            "symlinks_skipped": links]
    }

    private final class FirstMetadataProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double?
        var elapsed: Double? { lock.lock(); defer { lock.unlock() }; return value }
        func record(_ progress: ConversationIndexScanResult, elapsed: Double) {
            guard progress.metadataPublished > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            if value == nil { value = elapsed }
        }
    }

    /// Only aggregate categories escape the process. Local keys let a successful dependency-
    /// retry remove its prior failure; raw error descriptions and source identities never print.
    private final class ScanFailureProbe: HistorySessionLoading, @unchecked Sendable {
        let loader: HistorySessionLoader
        private let lock = NSLock()
        private var unresolved: [String: String] = [:]
        private var attempts: [String: Int] = [:]
        init(loader: HistorySessionLoader) { self.loader = loader }
        func prefetch(_ candidates: [HistoryFileCandidate]) { loader.prefetch(candidates) }
        func loadQuickMetadata(_ candidates: [HistoryFileCandidate]) -> [QuickLoadedHistorySession] {
            loader.loadQuickMetadata(candidates)
        }
        func load(_ candidate: HistoryFileCandidate, consistency: HistorySessionLoadConsistency) throws -> LoadedHistorySession {
            do {
                let result = try loader.load(candidate, consistency: consistency)
                lock.withLock { _ = unresolved.removeValue(forKey: candidate.file.path) }
                return result
            } catch {
                let kind: String
                switch error {
                case HistorySessionLoadError.dependenciesChanged: kind = "source_changed_during_parse"
                case HistoryError.unsupportedTranscript: kind = "unsupported_transcript"
                case HistoryError.invalidPath, HistoryError.pathOutsideConfiguredRoots,
                     HistoryError.notARegularJSONLFile: kind = "invalid_or_unavailable_source"
                case HistoryError.unreadableFile: kind = "source_read_failed"
                case is QoderFileReadError: kind = "permission_aware_helper_failed"
                case is CancellationError: kind = "cancelled"
                default: kind = "other_parser_error"
                }
                lock.withLock {
                    unresolved[candidate.file.path] = kind
                    attempts[kind, default: 0] += 1
                }
                throw error
            }
        }
        var attemptKinds: [String: Int] { lock.withLock { attempts } }
        var unresolvedCount: Int { lock.withLock { unresolved.count } }
        var unresolvedKinds: [String: Int] {
            lock.withLock { unresolved.values.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        }
    }

    /// Direct bounded-block search separates first usable (verified snippet) from full counts.
    /// It does not eagerly materialize whole transcripts, or treat tgrep candidates as hits.
    static func measureQuery(_ database: ConversationFileCatalog, query: String, phase: String) throws {
        let started = ContinuousClock.now
        let candidates = try database.candidateDocumentReferences(for: query)
        let diagnostics = database.searchDiagnostics
        let matcher = ConversationLiteralSearch(query: query)
        var matchedPaths = Set<String>(), matches: [ConversationIndexDocumentReference] = []
        var firstUsable: Double?, firstComplete: Double?
        var windows = 0, decodedBytes = 0, count = 0
        for reference in candidates.references.sorted(by: ConversationFileCatalog.referenceComesFirst) {
            if matchedPaths.contains(reference.sessionPath) { continue }
            let result = try refine(database, reference: reference, query: query, matcher: matcher, counting: false)
            windows += result.windows; decodedBytes += result.bytes
            if result.count > 0 {
                if firstUsable == nil { firstUsable = milliseconds(since: started) }
                matchedPaths.insert(reference.sessionPath); matches.append(reference)
                if matches.count == ConversationCatalogLimits.searchHits { break }
            }
        }
        for reference in matches {
            let result = try refine(database, reference: reference, query: query, matcher: matcher, counting: true)
            guard result.count > 0 else { throw BenchmarkFailure.literalParity }
            windows += result.windows; decodedBytes += result.bytes; count += result.count
            if firstComplete == nil { firstComplete = milliseconds(since: started) }
        }
        if requiresKnownHits(query), matches.isEmpty { throw BenchmarkFailure.requiredQueryHasNoHits }
        emit(["phase": phase, "query": query, "engine": diagnostics.engine,
            "timing_scope": "direct_bounded_blocks_not_repository_or_ui",
            "first_usable_verified_snippet_ms": firstUsable.map { $0 as Any } ?? NSNull(),
            "first_complete_hit_ms": firstComplete.map { $0 as Any } ?? NSNull(),
            "full_count_complete_ms": milliseconds(since: started),
            "candidate_ms": diagnostics.queryMilliseconds,
            "indexed_posting_groups": diagnostics.indexedDocuments, "candidate_blocks": diagnostics.candidateCount,
            "last_preparation_updated_groups": diagnostics.incrementallyIndexedDocuments,
            "restored_from_cache": diagnostics.restoredFromCache, "used_fallback": diagnostics.usedFallback,
            "fallback_reason": diagnostics.fallbackReason.map { $0 as Any } ?? NSNull(),
            "decoded_windows_including_first_and_count_pass": windows,
            "decoded_window_bytes_including_lookahead": decodedBytes,
            "matched_sessions_capped_at_200": matches.count, "exact_occurrences": count,
            "query_does_not_prepare_index": true, "process_peak_rss_bytes": peakRSS()])
    }

    private static func refine(_ database: ConversationFileCatalog, reference: ConversationIndexDocumentReference,
        query: String, matcher: ConversationLiteralSearch, counting: Bool) throws -> (count: Int, windows: Int, bytes: Int) {
        var cursor: ConversationIndexSearchCursor?, resume = 0, count = 0, windows = 0, bytes = 0
        repeat {
            let batch = try database.searchChunkWindows(reference: reference, query: query, cursor: cursor,
                limit: counting || cursor != nil ? 8 : 1)
            for window in batch.windows {
                windows += 1; bytes += window.text.utf8.count
                guard let match = matcher.match(in: window.text, countingOccurrences: counting,
                    startingAtUTF16: max(0, resume - window.globalUTF16Start),
                    ownedUTF16Length: window.ownedUTF16Length) else { continue }
                if count == 0 {
                    let lower = match.range.lowerBound.utf16Offset(in: window.text)
                    let upper = match.range.upperBound.utf16Offset(in: window.text)
                    guard let snippet = try database.searchChunkSnippet(reference: reference,
                        offsetUTF16: window.globalUTF16Start + lower, matchLengthUTF16: upper - lower),
                        !snippet.isEmpty else { throw BenchmarkFailure.invalidRepositoryHit }
                }
                count += match.count
                resume = window.globalUTF16Start + match.lastUTF16End
                if !counting { return (count, windows, bytes) }
            }
            cursor = batch.nextCursor
        } while cursor != nil
        return (count, windows, bytes)
    }

    private static func requiresKnownHits(_ query: String) -> Bool {
        CommandLine.arguments.contains("--require-known-hits") && requiredQueries.contains(query)
    }

    static func measureSourceQueries(_ quick: QuickLoadedHistorySession,
        loader: HistorySessionLoader, sourceBytes: Int) throws {
        let validate = {
            try Task.checkCancellation()
            guard quick.manifest.snapshot() == quick.dependencySnapshot else {
                throw ConversationCatalogError.staleRevision
            }
        }
        try validate()
        var results: [String: ConversationSearchRefinement] = [:]
        for (ordinal, query) in requiredQueries.enumerated() {
            let started = ContinuousClock.now
            let baselineRSS = peakRSS()
            var firstMilliseconds: Double?
            var firstCount: Int?
            let result = try ConversationSourceSearch.refine(candidate: quick.candidate,
                metadata: quick.metadata, loader: loader, query: query, validate: validate,
                onFirstMatch: { value in
                    firstMilliseconds = milliseconds(since: started)
                    if case let .hit(_, _, _, _, count) = value { firstCount = count }
                })
            let elapsed = milliseconds(since: started)
            results[query] = result
            let count: Int
            let anchored: Bool
            if case let .hit(_, _, sequence, _, occurrences) = result {
                count = occurrences
                anchored = sequence != nil
            } else { count = 0; anchored = false }
            emit(["phase": "authoritative_source_search", "query": query,
                "query_ordinal": ordinal, "source": quick.metadata.source.rawValue,
                "source_bytes": sourceBytes, "first_verified_callback_ms": firstMilliseconds.map { $0 as Any } ?? NSNull(),
                "first_callback_count_lower_bound": firstCount.map { $0 as Any } ?? NSNull(),
                "completed_count_ms": elapsed, "exact_occurrences": count,
                "has_message_anchor": anchored, "source_fingerprint_unchanged": true,
                "catalog_opened": false, "tgrep_prepared": false, "includes_ui_first_paint": false,
                "bounded_prefix_metadata_prewarmed": true, "os_filesystem_cache_flushed": false,
                "baseline_peak_rss_bytes": baselineRSS, "process_peak_rss_bytes": peakRSS(),
                "memory_bound": "largest_json_record_plus_query_window"])
        }

        // Deliberately outside query timings and after their RSS samples: this oracle retains
        // the full production parser projection and uses independent whole-text Foundation
        // matching, not the streaming window or a potentially stale derived catalog.
        let oracleStart = ContinuousClock.now
        try validate()
        let loaded = try loader.load(quick.candidate, consistency: .dependencyStable)
        try validate()
        for query in requiredQueries {
            var expected = ConversationSearchRefinement.noMatch
            for thread in loaded.projection.threads {
                var cursor = thread.searchText.startIndex
                var count = 0
                var first: Range<String.Index>?
                while cursor < thread.searchText.endIndex,
                      let match = thread.searchText.range(of: query, options: .caseInsensitive,
                          range: cursor..<thread.searchText.endIndex) {
                    if first == nil { first = match }
                    count += 1
                    cursor = match.upperBound
                }
                guard let first else { continue }
                let offset = first.lowerBound.utf16Offset(in: thread.searchText)
                let span = thread.span(containingUTF16Offset: offset)
                    ?? thread.messageSpans.first { $0.utf16Location >= offset } ?? thread.messageSpans.last
                expected = .hit(transcriptID: thread.transcriptID, agentType: thread.agentType,
                    sequence: span?.sequence,
                    snippet: ConversationSourceSearch.snippet(in: thread.searchText, around: first), count: count)
                break
            }
            guard results[query] == expected else { throw BenchmarkFailure.literalParity }
        }
        try validate()
        emit(["phase": "authoritative_source_full_parser_oracle", "source_bytes": sourceBytes,
            "public_queries_verified": requiredQueries.count, "count_snippet_anchor_parity": true,
            "source_fingerprint_unchanged": true, "oracle_ms": milliseconds(since: oracleStart),
            "oracle_runs_outside_query_timing": true, "process_peak_rss_includes_full_oracle": true,
            "process_peak_rss_bytes": peakRSS()])
    }

    static func measureRepositoryQuery(_ repository: IndexedHistoryRepository,
        sessions: [HistorySessionMetadata], query: String, phase: String,
        requiringFallback: Bool = false) throws {
        let started = ContinuousClock.now
        let hits = try repository.search(query: query, limit: ConversationCatalogLimits.searchHits)
        let elapsed = milliseconds(since: started)
        let diagnostics = repository.database.searchDiagnostics
        guard !requiringFallback || (diagnostics.usedFallback
            && diagnostics.engine != "tgrep") else {
            throw BenchmarkFailure.expectedFallback
        }
        guard hits.allSatisfy({ $0.count > 0 && !$0.snippet.isEmpty }) else {
            throw BenchmarkFailure.invalidRepositoryHit
        }
        if requiresKnownHits(query), hits.isEmpty {
            emit(["phase": phase, "query": query, "failed": true,
                "reason": "required_query_has_no_hits", "engine": diagnostics.engine,
                "fallback_reason": diagnostics.fallbackReason.map { $0 as Any } ?? NSNull()])
            throw BenchmarkFailure.requiredQueryHasNoHits
        }
        // Independent Foundation checks on bounded real documents run after the timed search.
        // Large transcripts remain fully searched/counted by production; only this expensive
        // differential oracle is sampled. No private text, identity, or path is emitted.
        let verified = try verifySmallRepositoryHits(hits, query: query, sessions: sessions, database: repository.database)
        emit(["phase": phase, "query": query, "engine": diagnostics.engine,
            "timing_scope": "complete_repository_search",
            "fallback_reason": diagnostics.fallbackReason.map { $0 as Any } ?? NSNull(),
            "repository_search_ms": elapsed, "candidate_ms": diagnostics.queryMilliseconds,
            "matched_sessions_capped_at_200": hits.count,
            "exact_occurrences": hits.reduce(0) { $0 + $1.count },
            "located_message_spans": hits.filter { $0.sequence != nil }.count,
            "nonempty_snippets": hits.filter { !$0.snippet.isEmpty }.count,
            "nested_transcript_hits": hits.filter { $0.agent != "main" }.count,
            "foundation_count_snippet_anchor_parity_samples": verified,
            "independent_oracle_unverified_hit_count": hits.count - verified,
            "foundation_oracle_scope": "at_most_three_small_catalog_documents_not_all_hits",
            "query_local_owner_metadata_hits": hits.filter { $0.sourceMetadata != nil }.count,
            "catalog_oracle_requires_current_source_revision": true,
            "independent_authoritative_source_oracle_samples": 0,
            "restored_from_cache": diagnostics.restoredFromCache,
            "used_fallback": diagnostics.usedFallback,
            "process_peak_rss_bytes": peakRSS()])
    }

    struct QueryTarget {
        let path: String
        let bytes: Int

        func matches(_ hit: HistorySearchHit) -> Bool {
            if hit.agent == "main" { return ConversationFileCatalog.normalizedPath(hit.file) == path }
            guard let child = hit.sourceMetadata?.subagentRefs.first(where: { $0.threadID == hit.agent }) else {
                return false
            }
            return ConversationFileCatalog.normalizedPath(child.file) == path
        }
    }

    static func measureProgressiveRepositoryQuery(_ repository: IndexedHistoryRepository,
        sessions: [HistorySessionMetadata], query: String, phase: String, target: QueryTarget? = nil) throws {
        let started = ContinuousClock.now
        let probe = ProgressiveRepositoryProbe(started: started, target: target)
        let hits: [HistorySearchHit]
        do {
            hits = try repository.search(query: query, limit: ConversationCatalogLimits.searchHits) {
                probe.record($0)
            }
        } catch {
            let partial = probe.diagnosticSnapshot()
            emit(["phase": phase + "_query_execution_failure", "query": query,
                "reason": safeProductionFailureReason(error) ?? "unclassified_production_failure",
                "repository_search_ms": milliseconds(since: started),
                "repository_first_visible_hit_ms": partial.firstHitMilliseconds.map { $0 as Any } ?? NSNull(),
                "firstTargetMs": partial.firstTargetMilliseconds.map { $0 as Any } ?? NSNull(),
                "targetBytes": target.map { $0.bytes as Any } ?? NSNull(),
                "targetCount": NSNull(), "completed_progressive_snapshot": false,
                "snapshot_epochs": partial.attempts,
                "last_published_source_coverage_ms": partial.diagnostics?.sourceCoverageMilliseconds as Any? ?? NSNull(),
                "last_published_source_verification_ms": partial.diagnostics?.sourceVerificationMilliseconds as Any? ?? NSNull(),
                "callback_hit_counts": partial.callbackHitCounts])
            if recordTransientQueryFailure(error) { return }
            throw error
        }
        let elapsed = milliseconds(since: started)
        let progress = try probe.validatedSnapshot(finalHits: hits)
        let diagnostics = progress.diagnostics ?? repository.database.searchDiagnostics
        if requiresKnownHits(query), hits.isEmpty {
            emit(["phase": phase, "query": query, "failed": true,
                "reason": "required_query_has_no_hits", "engine": diagnostics.engine,
                "fallback_reason": diagnostics.fallbackReason.map { $0 as Any } ?? NSNull()])
            throw BenchmarkFailure.requiredQueryHasNoHits
        }
        // The final-only production API is the oracle for ordering, counts, snippets and anchors.
        // It runs AFTER the timed progressive call; no warm-up query precedes first-hit timing.
        let finalOnly: [HistorySearchHit]
        do {
            finalOnly = try repository.search(query: query, limit: ConversationCatalogLimits.searchHits)
        } catch {
            emit(["phase": phase + "_post_timing_query_execution_failure", "query": query,
                "reason": safeProductionFailureReason(error) ?? "unclassified_production_failure",
                "repository_search_ms": elapsed, "completed_progressive_snapshot": true,
                "firstTargetMs": progress.firstTargetMilliseconds.map { $0 as Any } ?? NSNull(),
                "targetBytes": target.map { $0.bytes as Any } ?? NSNull(),
                "targetCount": hits.first(where: { target?.matches($0) == true }).map { $0.count as Any } ?? NSNull()])
            if recordTransientQueryFailure(error) { return }
            throw error
        }
        guard finalOnly == hits else {
            let withoutMetadata: (HistorySearchHit) -> HistorySearchHit = { hit in
                var value = hit
                value.sourceMetadata = nil
                return value
            }
            emit(["phase": phase + "_post_timing_parity_failure", "query": query,
                "repository_first_visible_hit_ms": progress.firstHitMilliseconds.map { $0 as Any } ?? NSNull(),
                "repository_search_ms": elapsed, "search_attempts": progress.attempts,
                "query_local_owner_metadata_hits": hits.filter { $0.sourceMetadata != nil }.count,
                "owner_metadata_only_difference": finalOnly.map(withoutMetadata) == hits.map(withoutMetadata),
                "same_ordered_hit_identities": finalOnly.map(\.id) == hits.map(\.id),
                "progressive_hit_count": hits.count, "final_only_hit_count": finalOnly.count,
                "progressive_exact_occurrences": hits.reduce(0) { $0 + $1.count },
                "final_only_exact_occurrences": finalOnly.reduce(0) { $0 + $1.count },
                "targetBytes": target.map { $0.bytes as Any } ?? NSNull(),
                "firstTargetMs": progress.firstTargetMilliseconds.map { $0 as Any } ?? NSNull(),
                "targetCount": hits.first(where: { target?.matches($0) == true }).map { $0.count as Any } ?? NSNull(),
                "separate_live_source_snapshots_may_differ": true,
                "final_only_api_parity": false])
            postTimingParityFailures.record()
            return
        }
        let verified = try verifySmallRepositoryHits(hits, query: query, sessions: sessions,
                                                    database: repository.database)
        emit(["phase": phase, "query": query, "engine": diagnostics.engine,
            "timing_scope": "repository_progressive_delivery_not_ui_first_paint",
            "includes_ui_first_paint": false,
            "repository_first_visible_hit_ms": progress.firstHitMilliseconds.map { $0 as Any } ?? NSNull(),
            "final_attempt_first_visible_hit_ms": progress.finalAttemptFirstHitMilliseconds.map { $0 as Any } ?? NSNull(),
            "repository_first_complete_hit_ms": progress.firstCompleteHitMilliseconds.map { $0 as Any } ?? NSNull(),
            "repository_search_ms": elapsed,
            "targetBytes": target.map { $0.bytes as Any } ?? NSNull(),
            "firstTargetMs": progress.firstTargetMilliseconds.map { $0 as Any } ?? NSNull(),
            "targetCount": hits.first(where: { target?.matches($0) == true }).map { $0.count as Any } ?? NSNull(),
            "first_hit_phase": progress.firstHitPhase.map { $0 as Any } ?? NSNull(),
            "first_hit_count_complete": progress.firstHitCountComplete.map { $0 as Any } ?? NSNull(),
            "candidate_ms": diagnostics.queryMilliseconds,
            "source_coverage_ms": diagnostics.sourceCoverageMilliseconds,
            "source_verification_sources": diagnostics.sourceVerificationSourceCount,
            "source_verification_bytes": diagnostics.sourceVerificationBytes,
            "source_verification_ms": diagnostics.sourceVerificationMilliseconds,
            "indexed_posting_groups": diagnostics.indexedDocuments,
            "candidate_blocks": diagnostics.candidateCount,
            "normalization_ms": diagnostics.cumulativeNormalizationMilliseconds,
            "trigram_build_ms": diagnostics.cumulativeTrigramBuildMilliseconds,
            "fallback_reason": diagnostics.fallbackReason.map { $0 as Any } ?? NSNull(),
            "used_fallback": diagnostics.usedFallback,
            "restored_from_cache": diagnostics.restoredFromCache,
            "callback_count": progress.callbackHitCounts.count,
            "callback_hit_counts": progress.callbackHitCounts,
            "callback_validation_included_in_timing": true,
            "identity_anchor_snippet_stable_within_each_attempt": true,
            "counts_nondecreasing_within_each_attempt": true,
            "search_attempts": progress.attempts,
            "snapshot_retirements_including_canonical_reconciliation": max(0, progress.attempts - 1),
            "final_counts_complete": hits.allSatisfy(\.isCountComplete),
            "completed_callback_matches_returned_hits": true,
            "final_only_api_parity": true,
            "final_only_api_oracle_runs_outside_timing": 1,
            "final_only_api_may_reuse_exact_answer_cache": true,
            "final_only_api_is_not_an_independent_text_oracle": true,
            "matched_sessions_capped_at_200": hits.count,
            "exact_occurrences": hits.reduce(0) { $0 + $1.count },
            "located_message_spans": hits.filter { $0.sequence != nil }.count,
            "nested_transcript_hits": hits.filter { $0.agent != "main" }.count,
            "foundation_count_snippet_anchor_parity_samples": verified,
            "independent_oracle_unverified_hit_count": hits.count - verified,
            "foundation_oracle_scope": "at_most_three_small_catalog_documents_not_all_hits",
            "query_local_owner_metadata_hits": hits.filter { $0.sourceMetadata != nil }.count,
            "catalog_oracle_requires_current_source_revision": true,
            "independent_authoritative_source_oracle_samples": 0,
            "process_peak_rss_bytes": peakRSS()])
    }

    /// Retains only the latest cumulative prefix; prior callbacks contribute aggregate counts.
    /// No private hit text, identity or path is serialized by this probe or its output snapshot.
    private final class ProgressiveRepositoryProbe: @unchecked Sendable {
        struct Snapshot {
            let firstHitMilliseconds: Double?
            let firstTargetMilliseconds: Double?
            let finalAttemptFirstHitMilliseconds: Double?
            let firstCompleteHitMilliseconds: Double?
            let firstHitPhase: String?
            let firstHitCountComplete: Bool?
            let callbackHitCounts: [Int]
            let attempts: Int
            let diagnostics: ConversationSearchDiagnostics?
        }

        private struct Attempt: Equatable {
            var revision: Int64?
            var identity: String?
            var token: UUID?
        }

        private let lock = NSLock()
        private let started: ContinuousClock.Instant
        private let target: QueryTarget?
        private var latestHits: [HistorySearchHit] = []
        private var latestPhase: ConversationSearchProgress.Phase?
        private var callbackHitCounts: [Int] = []
        private var firstHitMilliseconds: Double?
        private var firstTargetMilliseconds: Double?
        private var finalAttemptFirstHitMilliseconds: Double?
        private var firstCompleteHitMilliseconds: Double?
        private var firstHitPhase: String?
        private var firstHitCountComplete: Bool?
        private var completedCallbacks = 0
        private var valid = true
        private var latestAttempt: Attempt?
        private var attempts = 0
        private var diagnostics: ConversationSearchDiagnostics?

        init(started: ContinuousClock.Instant, target: QueryTarget?) {
            self.started = started
            self.target = target
        }

        func record(_ progress: ConversationSearchProgress) {
            let elapsed = RealHistoryBenchmark.milliseconds(since: started)
            lock.lock()
            defer { lock.unlock() }
            let attempt = Attempt(revision: progress.snapshotRevision,
                identity: progress.snapshotIdentity, token: progress.snapshotAttempt)
            if latestAttempt != attempt {
                if completedCallbacks != 0 || progress.phase != .preparingCandidates || !progress.hits.isEmpty {
                    valid = false
                }
                latestAttempt = attempt
                attempts += 1
                latestHits = []
                latestPhase = nil
                finalAttemptFirstHitMilliseconds = nil
            }
            if let value = progress.diagnostics { diagnostics = value }
            if completedCallbacks != 0 || progress.hits.count < latestHits.count
                || !progress.hits.allSatisfy({ $0.count > 0 && !$0.snippet.isEmpty }) {
                valid = false
            }
            let currentByID = Dictionary(progress.hits.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            if currentByID.count != progress.hits.count { valid = false }
            for previous in latestHits {
                guard let current = currentByID[previous.id] else { valid = false; continue }
                var stableFields = previous
                stableFields.count = current.count
                stableFields.isCountComplete = current.isCountComplete
                stableFields.sourceMetadata = current.sourceMetadata
                if stableFields != current || current.count < previous.count
                    || (previous.isCountComplete && (!current.isCountComplete || current.count != previous.count)) {
                    valid = false
                }
            }
            if progress.phase == .preparingCandidates,
               latestPhase != nil || !progress.hits.isEmpty { valid = false }
            if firstHitMilliseconds == nil, !progress.hits.isEmpty {
                firstHitMilliseconds = elapsed
                firstHitPhase = progress.phase == .completed ? "completed" : "refiningResults"
                firstHitCountComplete = progress.hits.first?.isCountComplete
            }
            if firstTargetMilliseconds == nil, progress.hits.contains(where: { target?.matches($0) == true }) {
                firstTargetMilliseconds = elapsed
            }
            if finalAttemptFirstHitMilliseconds == nil, !progress.hits.isEmpty {
                finalAttemptFirstHitMilliseconds = elapsed
            }
            if firstCompleteHitMilliseconds == nil, progress.hits.first?.isCountComplete == true {
                firstCompleteHitMilliseconds = elapsed
            }
            if progress.phase == .completed {
                completedCallbacks += 1
                if !progress.hits.allSatisfy(\.isCountComplete) { valid = false }
            }
            latestHits = progress.hits
            latestPhase = progress.phase
            callbackHitCounts.append(progress.hits.count)
        }

        func validatedSnapshot(finalHits: [HistorySearchHit]) throws -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            guard valid, completedCallbacks == 1, latestPhase == .completed,
                  latestHits == finalHits, finalHits.allSatisfy(\.isCountComplete),
                  finalHits.isEmpty || (firstHitMilliseconds != nil && firstCompleteHitMilliseconds != nil) else {
                throw BenchmarkFailure.progressiveParity
            }
            return snapshotWithoutLock()
        }

        func diagnosticSnapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshotWithoutLock()
        }

        private func snapshotWithoutLock() -> Snapshot {
            return Snapshot(firstHitMilliseconds: firstHitMilliseconds,
                firstTargetMilliseconds: firstTargetMilliseconds,
                finalAttemptFirstHitMilliseconds: finalAttemptFirstHitMilliseconds,
                firstCompleteHitMilliseconds: firstCompleteHitMilliseconds, firstHitPhase: firstHitPhase,
                firstHitCountComplete: firstHitCountComplete, callbackHitCounts: callbackHitCounts,
                attempts: attempts, diagnostics: diagnostics)
        }
    }

    static func verifySmallRepositoryHits(_ hits: [HistorySearchHit], query: String,
        sessions: [HistorySessionMetadata], database: ConversationFileCatalog) throws -> Int {
        let references = try database.candidateDocumentReferences(for: query).references
        let refs = Dictionary(grouping: references, by: { $0.sessionPath })
        let rows = Dictionary(uniqueKeysWithValues: sessions.map { (ConversationFileCatalog.normalizedPath($0.file), $0) })
        var verified = 0
        let scopes = Array(Set(sessions.map(\.dirID)))
        let loader = HistorySessionLoader(configuration: .init(historyDirs: scopes,
            importsRoot: database.file.deletingLastPathComponent().appendingPathComponent("benchmark-app/imports")))
        // Query-local owner metadata is now present for hot hits too. Only a separately current
        // source-revision proof authorizes comparing a hit against a catalog pack.
        for hit in hits {
            let parentPath = ConversationFileCatalog.normalizedPath(hit.file)
            var path = parentPath
            var transcript = hit.agent
            if let child = (hit.sourceMetadata ?? rows[parentPath])?.subagentRefs.first(where: { $0.threadID == hit.agent }) {
                path = ConversationFileCatalog.normalizedPath(child.file)
                transcript = "main"
            }
            guard let reference = refs[path]?.first(where: { $0.transcriptID == transcript }),
                  let entry = try database.entry(forPath: path), entry.metadata.sizeBytes <= 131_072,
                  let source = try ConversationSourceSearchCoverage.verifiedCatalogSource(loader: loader, entry: entry),
                  let document = try boundedOracleDocument(database, reference: reference,
                    query: query) else { continue }
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
            guard source.manifest.snapshot() == source.dependencySnapshot else { throw ConversationCatalogError.staleRevision }
            verified += 1
            if verified == 3 { break }
        }
        return verified
    }

    /// A small parent can own a very large child transcript. Bound the oracle by actual block
    /// bytes as well as source metadata, never by a whole-document read followed by a size check.
    private static func boundedOracleDocument(_ database: ConversationFileCatalog,
        reference: ConversationIndexDocumentReference, query: String) throws -> ConversationIndexDocument? {
        var fullReference = reference
        fullReference.candidateChunkIDs = nil
        let batch = try database.searchChunkWindows(reference: fullReference, query: query, limit: 5)
        guard batch.nextCursor == nil else { return nil }
        var text = ""
        var spans: [ConversationIndexMessageSpan] = []
        for window in batch.windows {
            let end = String.Index(utf16Offset: window.ownedUTF16Length, in: window.text)
            text.append(contentsOf: window.text[..<end])
            guard text.utf8.count <= 131_072 else { return nil }
            for span in window.messageSpans where !spans.contains(span) { spans.append(span) }
        }
        return .init(transcriptID: reference.transcriptID, agentType: reference.agentType,
            sortOrder: reference.sortOrder, text: text, messageSpans: spans)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    private static func safeProductionFailureReason(_ error: Error) -> String? {
        switch error {
        case ConversationCatalogError.staleRevision: return "stale_revision"
        case ConversationCatalogError.invalidRecord: return "invalid_catalog_record"
        case ConversationCatalogError.unsafeEmptyReconciliation: return "unsafe_empty_reconciliation"
        case ConversationCatalogError.corruptRow: return "corrupt_catalog_row"
        case HistorySessionLoadError.dependenciesChanged: return "source_dependencies_changed"
        case is CancellationError: return "cancelled"
        default: return nil
        }
    }

    private static func recordTransientQueryFailure(_ error: Error) -> Bool {
        switch error {
        case ConversationCatalogError.staleRevision, HistorySessionLoadError.dependenciesChanged:
            transientQueryFailures.record()
            return true
        default: return false
        }
    }

    static func peakRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }

    static func residentBytes() -> UInt64? {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(information.resident_size) : nil
    }

    static func emit(_ row: [String: Any]) {
        var row = row
        // Sample current residency too: a lifetime high-water mark cannot establish that full
        // parsing objects are still retained when the later tgrep preparation phase starts.
        row["current_rss_bytes"] = residentBytes().map { $0 as Any } ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    enum BenchmarkFailure: Error {
        case engineUnavailable, invalidCatalog, literalParity, invalidRepositoryHit, expectedFallback
        case emptyRepositoryScope, virtualRepositoryScope, requiredQueryHasNoHits
        case conflictingModes, progressiveParity, retiredStorageMode, privatePathOutputRetired, storageProbe
        case catalogConfigurationChanged, queryExecutionFailure
    }
}
