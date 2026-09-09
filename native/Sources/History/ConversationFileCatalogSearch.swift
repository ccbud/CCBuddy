import Foundation

private struct ConversationFileSearchRevision: Equatable, Sendable {
    let identity: String
    let generation: Int64
}

/// A published handle is immutable except for its one-way publisher-lease handoff.
/// Query serialization is entirely separate from both catalog I/O and the builder.
private final class ConversationPublishedSearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private let index: TgrepSearchIndex
    let generation: Int64
    let indexedGroups: Int
    let updatedGroups: Int
    let restored: Bool
    let normalizationMilliseconds: Double
    let trigramMilliseconds: Double

    init(index: TgrepSearchIndex, generation: Int64, updatedGroups: Int) {
        self.index = index
        self.generation = generation
        indexedGroups = index.documentCount
        self.updatedGroups = updatedGroups
        restored = index.restoredFromCache
        normalizationMilliseconds = index.normalizationMilliseconds
        trigramMilliseconds = index.trigramBuildMilliseconds
    }

    func relinquishPublication() throws {
        try lock.withLock { try index.relinquishPublication() }
    }

    func coversExactly(_ documents: [ConversationFileCatalog.SearchDocument]) throws -> Bool {
        try lock.withLock {
            var count = 0
            for document in documents {
                for ordinal in stride(from: 0, to: document.chunkIDs.count,
                    by: ConversationFileCatalog.searchIndexGroupChunkCount) {
                    try Task.checkCancellation()
                    count += 1
                    guard index.contains(id: document.chunkIDs[ordinal], stamp: ConversationFileCatalog.searchIndexStamp(
                        document: document, firstOrdinal: ordinal)) else { return false }
                }
            }
            return count == indexedGroups
        }
    }

    func candidates(query: String, documents: [ConversationFileCatalog.SearchDocument]) throws
        -> (references: [ConversationIndexDocumentReference], uncovered: Bool) {
        try lock.withLock {
            let matched = Set(try index.candidates(for: ConversationSearchChunk.candidatePrefix(query)))
            var references: [ConversationIndexDocumentReference] = []
            var uncovered = false
            for document in documents {
                try Task.checkCancellation()
                var selectedChunks: [Int64] = []
                var isCovered = true
                for ordinal in stride(from: 0, to: document.chunkIDs.count,
                    by: ConversationFileCatalog.searchIndexGroupChunkCount) {
                    let id = document.chunkIDs[ordinal]
                    guard index.contains(id: id, stamp: ConversationFileCatalog.searchIndexStamp(
                        document: document, firstOrdinal: ordinal)) else {
                        isCovered = false
                        break
                    }
                    if matched.contains(id) {
                        selectedChunks.append(contentsOf: document.chunkIDs[ordinal..<min(
                            document.chunkIDs.count, ordinal + ConversationFileCatalog.searchIndexGroupChunkCount)])
                    }
                }
                var reference = document.reference
                if !isCovered {
                    // A stale checkpoint is only an accelerator for unchanged groups. Missing
                    // and modified documents always get a full exact, bounded-block scan.
                    reference.candidateChunkIDs = nil
                    references.append(reference)
                    uncovered = true
                } else if !selectedChunks.isEmpty {
                    reference.candidateChunkIDs = selectedChunks
                    references.append(reference)
                }
            }
            return (references, uncovered)
        }
    }
}

/// Tiny coordination state only. Expensive restoration, checksum verification,
/// normalization, merging and checkpoint publication never run under this lock.
final class ConversationFileSearchIndexState: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var published: ConversationPublishedSearchIndex?
    fileprivate var task: Task<Void, Never>?
    fileprivate var token: UUID?
    fileprivate var restartRequested = false
    fileprivate var completedRevision: ConversationFileSearchRevision?
    fileprivate var phase = "indexPreparing"
    fileprivate var failure: TgrepSearchIndex.Failure?
    fileprivate var retryAfter: Date?
    fileprivate var diagnostics = ConversationSearchDiagnostics()
    fileprivate var lastIndexedGroups = 0
    fileprivate var lifecycleOwners = Set<UUID>()

    fileprivate func currentTask() -> Task<Void, Never>? { lock.withLock { task } }
}

extension ConversationFileCatalog {
    /// Eight independently compressed blocks share one postings identity. Storage and exact
    /// verification stay at 32 KiB; repeated trigrams are deduplicated over roughly 256 KiB.
    static let searchIndexGroupChunkCount = 8

    struct TgrepRuntime: @unchecked Sendable {
        var now: () -> Date = { Date() }
        var availableCapacity: (URL) -> Int64? = { directory in
            (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity.map(Int64.init)
        }
        var makeIndex: (URL) throws -> TgrepSearchIndex = { try TgrepSearchIndex(cacheDirectory: $0) }
        var retryInterval: TimeInterval = 30
    }

    var supportsTrigramSearch: Bool { enableTgrep && TgrepSearchIndex.isAvailable }

    var searchDiagnostics: ConversationSearchDiagnostics {
        searchIndexState.lock.withLock { searchIndexState.diagnostics }
    }

    /// This foreground path never opens an index, reads a checksum, normalizes corpus text,
    /// upserts a group or waits for a background builder. Cold search is usable immediately.
    func candidateDocumentReferences(for rawQuery: String, scope: String? = nil,
        source: HistorySource? = nil, deleted: Bool? = false) throws -> ConversationIndexCandidateReferenceBatch {
        let started = ContinuousClock.now
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !query.isEmpty else { return .init(references: [], usedFallback: false) }
        let snapshot = try catalogSearchSnapshot(scope: scope, source: source, deleted: deleted)
        let state = searchIndexState.lock.withLock {
            (searchIndexState.published, searchIndexState.phase,
             searchIndexState.failure, searchIndexState.retryAfter, searchIndexState.lastIndexedGroups)
        }
        var diagnostics: ConversationSearchDiagnostics
        let result: ConversationIndexCandidateReferenceBatch
        if enableTgrep, TgrepSearchIndex.canIndex(query), let published = state.0 {
            do {
                let selected = try published.candidates(query: query, documents: snapshot.documents)
                result = .init(references: selected.references, usedFallback: selected.uncovered)
                diagnostics = .init(engine: "tgrep", indexedDocuments: published.indexedGroups,
                    candidateCount: selected.references.reduce(0) { $0 + ($1.candidateChunkIDs?.count ?? 1) },
                    incrementallyIndexedDocuments: state.4, usedFallback: selected.uncovered,
                    cumulativeNormalizationMilliseconds: published.normalizationMilliseconds,
                    cumulativeTrigramBuildMilliseconds: published.trigramMilliseconds,
                    restoredFromCache: published.restored,
                    fallbackReason: selected.uncovered ? (state.2?.rawValue ?? state.1) : nil,
                    tgrepRetryAfter: selected.uncovered ? state.3 : nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An index error cannot turn into a false negative or take the catalog offline.
                result = .init(references: snapshot.documents.map(\.reference), usedFallback: true)
                diagnostics = .init(engine: "Literal", candidateCount: result.references.count,
                    usedFallback: true, fallbackReason: (error as? TgrepSearchIndex.Failure)?.rawValue
                        ?? TgrepSearchIndex.Failure.operationFailed.rawValue)
            }
        } else {
            result = .init(references: snapshot.documents.map(\.reference), usedFallback: true)
            diagnostics = .init(engine: "Literal", candidateCount: result.references.count,
                usedFallback: true,
                fallbackReason: enableTgrep && TgrepSearchIndex.canIndex(query)
                    ? (state.2?.rawValue ?? state.1) : nil,
                tgrepRetryAfter: state.3)
        }
        try Task.checkCancellation()
        guard try currentSearchRevision() == .init(identity: snapshot.identity, generation: snapshot.generation) else {
            throw ConversationCatalogError.staleRevision
        }
        let elapsed = started.duration(to: .now).components
        diagnostics.queryMilliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        searchIndexState.lock.withLock { searchIndexState.diagnostics = diagnostics }
        return result
    }

    /// Compatibility for small, explicit whole-document consumers. Production search uses the
    /// reference/window API above, so this convenience never materializes the matching corpus.
    func candidateDocuments(for rawQuery: String, scope: String? = nil, source: HistorySource? = nil,
        deleted: Bool? = false, limit: Int? = nil) throws -> ConversationIndexCandidateBatch {
        guard limit.map({ $0 > 0 }) ?? true else { return .init(documents: [], usedFallback: false) }
        let batch = try candidateDocumentReferences(for: rawQuery, scope: scope, source: source, deleted: deleted)
        let matcher = ConversationLiteralSearch(query: rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        var documents: [ConversationIndexDocumentCandidate] = []
        for reference in batch.references.sorted(by: Self.referenceComesFirst) {
            try Task.checkCancellation()
            guard let entry = try entry(forPath: reference.sessionPath),
                  let document = try document(id: reference.documentID,
                    expectedSessionPath: reference.sessionPath, expectedTranscriptID: reference.transcriptID),
                  matcher.firstMatch(in: document.text) != nil else { continue }
            documents.append(.init(entry: entry, document: document))
            if let limit, documents.count == limit { break }
        }
        try Task.checkCancellation()
        return .init(documents: documents, usedFallback: batch.usedFallback)
    }

    /// Called by catalog lifecycle/reconciliation, not by candidate lookup. Repeated scheduling
    /// coalesces into one utility worker; the published reader remains usable during rebuilding.
    func scheduleSearchIndexPreparation() {
        guard enableTgrep, let revision = try? currentSearchRevision() else { return }
        searchIndexState.lock.withLock {
            if let task = searchIndexState.task {
                if task.isCancelled { searchIndexState.restartRequested = true }
                return
            }
            guard searchIndexState.completedRevision != revision,
                  searchIndexState.retryAfter.map({ tgrepRuntime.now() >= $0 }) ?? true else { return }
            let token = UUID()
            searchIndexState.token = token
            searchIndexState.phase = "indexRestoring"
            searchIndexState.task = Task.detached(priority: .utility) { [weak self] in
                self?.prepareSearchIndex(token: token)
            }
        }
    }

    func cancelSearchIndexPreparation() {
        searchIndexState.lock.withLock {
            // Keep the slot occupied until cancellation has actually released the builder's
            // publisher lease. An immediate stop/start must not create a secondary writer.
            searchIndexState.task?.cancel()
            searchIndexState.restartRequested = false
        }
    }

    /// Coordinators register only when their watching lifecycle actually starts. Read-only
    /// repository facades must not acquire ownership merely by being constructed.
    func registerIndexLifecycle(_ owner: UUID) {
        searchIndexState.lock.withLock { _ = searchIndexState.lifecycleOwners.insert(owner) }
    }

    func unregisterIndexLifecycle(_ owner: UUID) {
        searchIndexState.lock.withLock {
            guard searchIndexState.lifecycleOwners.remove(owner) != nil,
                  searchIndexState.lifecycleOwners.isEmpty else { return }
            searchIndexState.task?.cancel()
            searchIndexState.restartRequested = false
            // Serialize the last-owner decision with a concurrent new owner's registration.
            // Deferred-maintenance state never acquires this search coordination lock.
            cancelDeferredMaintenance()
        }
    }

    /// Tests and explicit maintenance may await the real worker. Search never calls this.
    func waitForSearchIndexPreparation() async {
        while let task = searchIndexState.currentTask() { await task.value }
    }

    fileprivate static func searchIndexStamp(document: SearchDocument, firstOrdinal: Int) -> TgrepSearchIndex.Stamp {
        .init(path: document.reference.sessionPath,
            transcript: document.reference.transcriptID + ":group8:" + String(document.chunkIDs[firstOrdinal]),
            indexedAt: 0, contentIdentity: document.contentToken)
    }

    private func currentSearchRevision() throws -> ConversationFileSearchRevision {
        let revision = try searchIndexRevision()
        return .init(identity: revision.identity, generation: revision.generation)
    }

    private func prepareSearchIndex(token: UUID) {
        var builtRevision: ConversationFileSearchRevision?
        var shouldReschedule = false
        defer {
            searchIndexState.lock.withLock {
                guard searchIndexState.token == token else { return }
                if let builtRevision { searchIndexState.completedRevision = builtRevision }
                let restart = searchIndexState.restartRequested || (shouldReschedule && !Task.isCancelled)
                searchIndexState.restartRequested = false
                if restart {
                    // Install the actual successor before releasing the state lock: awaiters
                    // finishing the old task must observe this task, never an empty gap before
                    // a detached scheduling trampoline runs. The old builder's do/catch scope
                    // has ended, so its unpublished handle and publisher lease are released.
                    let nextToken = UUID()
                    searchIndexState.token = nextToken
                    searchIndexState.phase = "indexRestoring"
                    searchIndexState.task = Task.detached(priority: .utility) { [weak self] in
                        self?.prepareSearchIndex(token: nextToken)
                    }
                } else {
                    searchIndexState.task = nil
                    searchIndexState.token = nil
                    searchIndexState.phase = "indexPreparing"
                }
            }
        }
        do {
            try Task.checkCancellation()
            var snapshot = try catalogSearchSnapshot(scope: nil, source: nil, deleted: nil)
            let previous = searchIndexState.lock.withLock { searchIndexState.published }
            if try previous?.coversExactly(snapshot.documents) == true {
                // Titles, favorites, tags and list ordering do not change searchable bytes.
                // Reuse the existing reader without another full checksum or writer handoff.
                searchIndexState.lock.withLock {
                    searchIndexState.lastIndexedGroups = 0
                    searchIndexState.failure = nil
                    searchIndexState.retryAfter = nil
                }
                builtRevision = .init(identity: snapshot.identity, generation: snapshot.generation)
                shouldReschedule = (try? currentSearchRevision()) != builtRevision
                return
            }
            let chunkCount = snapshot.documents.reduce(0) { $0 + $1.chunkIDs.count }
            let required = Int64(64 * 1_024 * 1_024) + min(Int64(chunkCount) * 16_384, 512 * 1_024 * 1_024)
            try previous?.relinquishPublication()
            try Task.checkCancellation()
            // The expensive full-file checksum runs here on the utility worker, never before
            // the foreground's first verified hit. The previous mmap stays queryable throughout.
            let index = try tgrepRuntime.makeIndex(file.appendingPathComponent("tgrep-groups-v1", isDirectory: true))
            try Task.checkCancellation()
            searchIndexState.lock.withLock { searchIndexState.phase = "indexPreparing" }
            snapshot = try catalogSearchSnapshot(scope: nil, source: nil, deleted: nil)
            let capacity = tgrepRuntime.availableCapacity(file)
            var stamps: [Int64: TgrepSearchIndex.Stamp] = [:]
            var staged: [Int64: TgrepSearchIndex.Stamp] = [:]
            var updated = 0
            for attempt in 0..<3 {
                do {
                    stamps = [:]
                    for document in snapshot.documents {
                        for ordinal in stride(from: 0, to: document.chunkIDs.count, by: Self.searchIndexGroupChunkCount) {
                            try Task.checkCancellation()
                            let id = document.chunkIDs[ordinal]
                            let stamp = Self.searchIndexStamp(document: document, firstOrdinal: ordinal)
                            stamps[id] = stamp
                            guard staged[id] != stamp, !index.contains(id: id, stamp: stamp) else { continue }
                            if let capacity, capacity < required { throw TgrepSearchIndex.Failure.lowDiskSpace }
                            // A utility task can run for minutes without returning to a run loop.
                            // Drain Foundation decode/folding temporaries per bounded group; only
                            // the tiny identity/stamp and native postings escape this scope.
                            try autoreleasepool {
                                let text = try searchIndexGroup(document: document, firstOrdinal: ordinal,
                                    chunkCount: Self.searchIndexGroupChunkCount, generation: snapshot.generation)
                                try Task.checkCancellation()
                                try index.upsert(id: id, text: text)
                            }
                            staged[id] = stamp
                            updated += 1
                        }
                    }
                    break
                } catch ConversationCatalogError.staleRevision where attempt < 2 {
                    // A producer replaced a pack during this pass. Keep already-built immutable
                    // groups in this private builder and reconcile only changed/new identities.
                    snapshot = try catalogSearchSnapshot(scope: nil, source: nil, deleted: nil)
                }
            }
            try Task.checkCancellation()
            // A pure deletion also rewrites postings. An unchanged restored checkpoint, on the
            // other hand, remains useful even when there is insufficient room for rebuilding.
            if index.documentCount != stamps.count, let capacity, capacity < required {
                throw TgrepSearchIndex.Failure.lowDiskSpace
            }
            try index.commit(revision: snapshot.generation, stamps: stamps)
            try Task.checkCancellation()
            let published = ConversationPublishedSearchIndex(index: index,
                generation: snapshot.generation, updatedGroups: updated)
            searchIndexState.lock.withLock {
                guard searchIndexState.token == token else { return }
                searchIndexState.published = published
                searchIndexState.failure = nil
                searchIndexState.retryAfter = nil
                searchIndexState.lastIndexedGroups = updated
            }
            builtRevision = .init(identity: snapshot.identity, generation: snapshot.generation)
            shouldReschedule = (try? currentSearchRevision()) != builtRevision
        } catch is CancellationError {
            // Cancellation preserves the previous sealed reader and checkpoint. It is neither
            // a negative search result nor an engine failure, and does not install a cooldown.
        } catch ConversationCatalogError.staleRevision {
            // Never publish incomplete coverage as a complete snapshot. A subsequent catalog
            // refresh can schedule another worker; unchanged published groups remain useful.
            shouldReschedule = true
        } catch {
            searchIndexState.lock.withLock {
                searchIndexState.failure = (error as? TgrepSearchIndex.Failure) ?? .operationFailed
                searchIndexState.retryAfter = tgrepRuntime.now().addingTimeInterval(tgrepRuntime.retryInterval)
            }
        }
    }
}
