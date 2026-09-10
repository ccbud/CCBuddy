import Foundation

/// Complements the immutable catalog snapshot with authorized sources it cannot yet cover.
/// This reads file facts and provider-aware metadata (bounded previews, then the first complete
/// decoded record for otherwise unidentified ordinary JSONL).
/// Exact message verification belongs to `ConversationSourceSearch`, outside the catalog lock
/// and without publishing a new pack. Qoder keeps its existing permission-aware reader.
struct ConversationSourceSearchCoverage: Sendable {
    struct Source: Sendable {
        var candidate: HistoryFileCandidate
        var metadata: HistorySessionMetadata
        var manifest: ConversationDependencyManifest
        var dependencySnapshot: ConversationDependencySnapshot
    }

    var metadata: [HistorySessionMetadata]
    var sourcesByPath: [String: Source]
    /// Current proofs for reusable packs, including children skipped by the first-hit gate.
    /// The repository validates only the catalog sources it actually examines for this query.
    var catalogSourcesByPath: [String: Source] = [:]
    /// Includes refreshed annotation-only sources whose immutable body remains searchable.
    /// Revalidate these too: a second sidecar edit can change trash/ownership during the query.
    var validationSources: [Source] = []

    /// A narrow first-result gate: validate only a prepared candidate's authoritative owner.
    /// It never discovers or parses unrelated sources, nor treats a quick sentinel as a pack.
    static func verifiedCatalogSource(
        loader: HistorySessionLoader, entry: ConversationIndexEntry
    ) throws -> Source? {
        try Task.checkCancellation()
        guard entry.scope == entry.metadata.dirID,
              let candidate = try? loader.pathResolver.validatedCandidate(for: entry.metadata.file),
              candidate.directory.id == entry.scope,
              let manifest = try? loader.adapters.manifest(for: candidate,
                format: format(for: entry.metadata.source), configuration: loader.configuration)
        else { return nil }
        let snapshot = manifest.snapshot()
        guard let current = fingerprint(manifest: manifest, snapshot: snapshot),
              current.matchesSourceRevision(entry.fingerprint) else { return nil }
        return Source(candidate: candidate, metadata: entry.metadata, manifest: manifest,
                      dependencySnapshot: snapshot)
    }

    static func snapshot(
        loader: HistorySessionLoader,
        entries: [ConversationIndexEntry],
        scope: String?,
        deleted: Bool
    ) throws -> Self {
        try Task.checkCancellation()
        let resolver = loader.pathResolver
        let allowedScopes = Set(resolver.directories().map(\.id))
        if let scope, !allowedScopes.contains(scope) {
            return Self(metadata: [], sourcesByPath: [:])
        }
        func includesScope(_ candidateScope: String) -> Bool {
            allowedScopes.contains(candidateScope) && (scope == nil || scope == candidateScope)
        }

        // Include other currently authorized scopes/trash rows, but not a revoked scope alias.
        // A root changed from ~/… to its equivalent absolute path must be rediscovered under
        // its new scope ID even while the catalog still carries the old ID for the same file.
        let authorizedEntries = entries.filter {
            allowedScopes.contains($0.scope) && $0.metadata.dirID == $0.scope
        }
        let knownPaths = Set(authorizedEntries.map {
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path
        })
        let entriesByPath = Dictionary(authorizedEntries.map {
            (URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path, $0)
        }, uniquingKeysWith: { _, newer in newer })
        var metadataByPath: [String: HistorySessionMetadata] = [:]
        var sourcesByPath: [String: Source] = [:]
        var catalogSourcesByPath: [String: Source] = [:]
        var validationByPath: [String: Source] = [:]
        for entry in entries {
            try Task.checkCancellation()
            guard includesScope(entry.scope), entry.metadata.dirID == entry.scope else { continue }
            let path = URL(fileURLWithPath: entry.sourcePath).standardizedFileURL.path
            // An unavailable raw file does not invalidate an already committed catalog snapshot.
            // It simply cannot participate in the query-priority raw-source fallback.
            metadataByPath[path] = entry.metadata
            guard let candidate = try? resolver.validatedCandidate(
                for: URL(fileURLWithPath: entry.sourcePath)
            ), candidate.directory.id == entry.scope else { continue }
            let format = format(for: entry.metadata.source)
            guard let manifest = try? loader.adapters.manifest(
                for: candidate, format: format, configuration: loader.configuration
            ) else { continue }
            let dependencySnapshot = manifest.snapshot()
            guard let current = fingerprint(manifest: manifest, snapshot: dependencySnapshot) else { continue }
            let source = Source(candidate: candidate, metadata: entry.metadata,
                manifest: manifest, dependencySnapshot: dependencySnapshot)
            if current.matchesSourceRevision(entry.fingerprint) {
                catalogSourcesByPath[path] = source
            } else {
                sourcesByPath[path] = source
            }
        }

        // Scoped repositories reuse their original loader. Derive discovery's active scope
        // explicitly instead of trusting loader.configuration.active from its initial owner.
        var discoveryConfiguration = loader.configuration
        discoveryConfiguration.active = scope ?? (deleted ? "__trash__" : "all")
        let discovered = loader.adapters.discoverCandidates(
            configuration: discoveryConfiguration, activeOnly: true
        )
        try Task.checkCancellation()
        let unknown = discovered.filter {
            includesScope($0.directory.id) && !knownPaths.contains($0.file.standardizedFileURL.path)
        }
        // Refresh dirty identity/custom metadata before filtering trash. A source can be moved
        // into/out of trash, reparented, or atomically replaced while its old pack is still valid
        // as a committed snapshot. Do not force a detector-based path to its old producer format.
        var refreshPaths = Set<String>()
        let refresh = (sourcesByPath.sorted { $0.key < $1.key }.map(\.value.candidate) + unknown)
            .filter { refreshPaths.insert($0.file.standardizedFileURL.path).inserted }
        // Keep Codex state metadata batched, but let a replaced/cancelled query stop between
        // small batches rather than waiting for an entire newly discovered history tree.
        let batchSize = 32
        for start in stride(from: 0, to: refresh.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = refresh[start..<min(start + batchSize, refresh.count)].filter {
                guard let validated = try? resolver.validatedCandidate(for: $0.file) else { return false }
                return validated.directory.id == $0.directory.id && includesScope($0.directory.id)
            }
            let primaryBeforeRead = Dictionary(uniqueKeysWithValues: batch.map { candidate in
                let dependency = ConversationSourceDependency(file: candidate.file,
                    role: candidate.formatHint == .antigravity ? .primaryDatabase : .primaryTranscript)
                return (candidate.file.standardizedFileURL.path, ConversationDependencyStamp.read(dependency))
            })
            let dependenciesBeforeRead = Dictionary(batch.compactMap { candidate in
                let path = candidate.file.standardizedFileURL.path
                return sourcesByPath[path].map { (path, ($0.manifest.source, $0.manifest.snapshot())) }
            }, uniquingKeysWith: { _, newer in newer })
            let quickMetadata = try loader.loadSearchMetadata(batch)
            try Task.checkCancellation()
            for quick in quickMetadata {
                let path = quick.candidate.file.standardizedFileURL.path
                guard let primary = quick.manifest.primary,
                      let before = primaryBeforeRead[path],
                      quick.dependencySnapshot.stamp(for: primary.file, role: primary.role) == before
                else { throw ConversationCatalogError.staleRevision }
                if let before = dependenciesBeforeRead[path], before.0 == quick.manifest.source,
                   before.1 != quick.dependencySnapshot {
                    throw ConversationCatalogError.staleRevision
                }
                guard includesScope(quick.candidate.directory.id),
                      quick.metadata.dirID == quick.candidate.directory.id,
                      let validated = try? resolver.validatedCandidate(for: quick.candidate.file),
                      validated.directory.id == quick.candidate.directory.id,
                      fingerprint(manifest: quick.manifest, snapshot: quick.dependencySnapshot) != nil
                else { continue }
                let metadata = refreshedMetadata(quick.metadata, previous: metadataByPath[path])
                metadataByPath[path] = metadata
                let source = Source(candidate: quick.candidate, metadata: metadata,
                    manifest: quick.manifest, dependencySnapshot: quick.dependencySnapshot)
                validationByPath[path] = source
                if let previous = entriesByPath[path],
                   previous.scope == quick.candidate.directory.id,
                   previous.metadata.deleted == metadata.deleted,
                   ConversationIndexFingerprint.hasSameContentOwner(previous.metadata, metadata),
                   let body = previous.fingerprint.searchContentFingerprint,
                   body == ConversationIndexFingerprint.contentFingerprint(
                    manifest: quick.manifest, snapshot: quick.dependencySnapshot) {
                    // The sidecar changed annotations, not normalized text. Keep its current
                    // metadata/visibility while reusing the already verified immutable pack.
                    sourcesByPath.removeValue(forKey: path)
                    catalogSourcesByPath[path] = source
                } else {
                    sourcesByPath[path] = source
                }
            }
        }
        try Task.checkCancellation()
        for (path, source) in sourcesByPath where validationByPath[path] == nil {
            validationByPath[path] = source
        }
        return Self(metadata: metadataByPath.sorted { $0.key < $1.key }.map(\.value)
                        .filter { $0.deleted == deleted },
                    sourcesByPath: sourcesByPath.filter { $0.value.metadata.deleted == deleted },
                    catalogSourcesByPath: catalogSourcesByPath.filter { $0.value.metadata.deleted == deleted },
                    validationSources: validationByPath.sorted { $0.key < $1.key }.map(\.value)
                        .filter { $0.metadata.deleted == deleted })
    }

    private static func refreshedMetadata(
        _ quick: HistorySessionMetadata,
        previous: HistorySessionMetadata?
    ) -> HistorySessionMetadata {
        guard let previous, previous.source == quick.source,
              previous.sessionID == quick.sessionID, previous.threadID == quick.threadID,
              previous.rootSessionID == quick.rootSessionID,
              previous.parentThreadID == quick.parentThreadID,
              previous.forkedFromID == quick.forkedFromID else { return quick }
        var metadata = quick
        // Prefix metadata is not a full statistics pass. Keep the committed counts and child
        // identities until a complete parse replaces them; never carry them across a new owner.
        metadata.messageCount = previous.messageCount
        metadata.totals = previous.totals
        metadata.subagentCount = previous.subagentCount
        metadata.subagentRefs = previous.subagentRefs
        metadata.summary = quick.summary ?? previous.summary
        metadata.model = quick.model ?? previous.model
        return metadata
    }

    /// Identical source-revision facts to the scanner, including all normalized dependencies.
    /// A quick row needs separate evidence for a previously committed pack before body reuse.
    private static func fingerprint(
        manifest: ConversationDependencyManifest,
        snapshot: ConversationDependencySnapshot
    ) -> ConversationIndexFingerprint? {
        guard let primary = manifest.primary,
              let stamp = snapshot.stamp(for: primary.file, role: primary.role),
              stamp.kind == .regularFile,
              let nanoseconds = stamp.modifiedAtNanoseconds,
              let sizeBytes = stamp.sizeBytes else { return nil }
        return ConversationIndexFingerprint(
            modificationTime: Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000),
            sizeBytes: sizeBytes,
            dependencyFingerprint: snapshot.fingerprint
        )
    }

    private static func format(for source: HistorySource) -> HistoryTranscriptFormat {
        switch source {
        case .claude: .claude
        case .codex: .codex
        case .qoder: .qoder
        case .grok: .grok
        case .copilot: .copilot
        case .antigravity: .antigravity
        }
    }
}
