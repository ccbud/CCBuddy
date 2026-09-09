import CryptoKit
import Darwin
import Foundation

/// Rebuildable file catalog. The only publication point is a small, atomic manifest containing
/// immutable object references. Transcript bytes live in independently compressed pack blocks,
/// never in a JSON metadata snapshot. Source transcripts and the user's metadata sidecars remain
/// authoritative; this class never opens, changes, or deletes the preceding SQLite catalog.
final class ConversationFileCatalog: @unchecked Sendable {
    static let formatVersion = 1
    let file: URL
    let searchRefinementCache: ConversationSearchRefinementCache
    let enableTgrep: Bool
    let tgrepRuntime: TgrepRuntime
    let searchIndexState = ConversationFileSearchIndexState()

    struct SearchDocument: Sendable {
        var reference: ConversationIndexDocumentReference
        var contentToken: String
        var chunkIDs: [Int64]
    }

    struct SearchSnapshot: Sendable {
        var generation: Int64
        var identity: String
        var documents: [SearchDocument]
    }

    enum Failure: LocalizedError {
        case invalidLocation
        case unsafeFile
        case unsupportedVersion(Int)
        case corrupt(String)
        var errorDescription: String? {
            switch self {
            case .invalidLocation: return "The conversation catalog must be a local directory."
            case .unsafeFile: return "The conversation catalog contains an unsafe file."
            case .unsupportedVersion(let version): return "Unsupported conversation catalog version \(version)."
            case .corrupt(let reason): return "The conversation catalog needs rebuilding: \(reason)."
            }
        }
    }

    private struct ObjectReference: Codable, Equatable {
        var name: String
        var checksum: String
    }

    private struct Manifest: Codable {
        var version = ConversationFileCatalog.formatVersion
        var identity = UUID().uuidString.lowercased()
        var generation: Int64 = 0
        var nextDocumentID: Int64 = 1
        var nextChunkID: Int64 = 1
        var objects: [String: ObjectReference] = [:]
        /// Digest of the canonical manifest with this field omitted, including allocation
        /// counters. A syntactically valid JSON bit flip must not authorize numeric ID reuse.
        var checksum: String?
    }

    private struct Chunk: Codable {
        var id: Int64 = 0
        var ordinal: Int
        var utf16Location: Int
        var utf16Length: Int
        var offset: UInt64
        var storedBytes: Int
        var decodedBytes: Int
        var codec: Int
        var checksum: String
        var spans: [ConversationIndexMessageSpan]
    }

    private struct Document: Codable {
        var id: Int64 = 0
        var transcriptID: String
        var agentType: String?
        var sortOrder: Int
        /// Independent of metadata-only revisions; never reused even after a remove/re-add.
        var contentToken: String
        var chunks: [Chunk]
    }

    private struct Record: Codable {
        var version = ConversationFileCatalog.formatVersion
        var entry: ConversationIndexEntry
        var pack: String?
        var documents: [Document]
    }

    private struct Prepared {
        var temporaryPack: String
        var finalPack: String
        var documents: [Document]
        var descriptor: Int32
    }

    private struct MetadataSnapshot {
        var identity: String
        var records: [String: (reference: ObjectReference?, record: Record?)]
    }

    private struct PreparedHeader {
        var path: String
        var previous: ObjectReference?
        var reference: ObjectReference
        var record: Record
        var temporary: String
        var descriptor: Int32
    }

#if DEBUG
    /// Deterministic concurrency seam. Invoked with durable, leased partial headers and no
    /// catalog/state lock held; excluded from production builds.
    var metadataPreparationDidFinishForTesting: (@Sendable () throws -> Void)?
#endif

    private struct ReadPacket {
        var generation: Int64
        var document: Document
        var descriptor: Int32
        var packName: String?
    }

    private let rootDescriptor: Int32
    private let objectsDescriptor: Int32
    /// Every flock critical section is serialized per instance and opens its own lock FD. A
    /// reader can therefore never release another reader's process-owned file lock accidentally.
    private let stateLock = NSLock()
    private var cachedManifest: Manifest?
    private var cachedManifestIdentity: FileIdentity?
    private var cachedRecords: [String: (checksum: String, record: Record)] = [:]
    private var corruptRecordNames = Set<String>()
    private var corruptPackNames = Set<String>()
    private let maintenanceLock = NSLock()
    private var maintenanceToken: UUID?
    private var activityEpoch: UInt64 = 0
    private var maintenancePending = false

    private struct FileIdentity: Equatable {
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanos: Int
    }

    init(file: URL, enableTgrep: Bool = true, tgrepRuntime: TgrepRuntime = .init(),
         searchRefinementCache: ConversationSearchRefinementCache = .init()) throws {
        guard file.isFileURL else { throw Failure.invalidLocation }
        self.file = file.standardizedFileURL
        self.enableTgrep = enableTgrep
        self.tgrepRuntime = tgrepRuntime
        self.searchRefinementCache = searchRefinementCache
        try FileManager.default.createDirectory(at: self.file, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let root = Darwin.open(self.file.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unsafeFile }
        do {
            try Self.validateDescriptor(root, directory: true)
            guard fchmod(root, 0o700) == 0 else { throw Self.posixError() }
            if mkdirat(root, "objects", 0o700) != 0, errno != EEXIST { throw Self.posixError() }
            let objects = openat(root, "objects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard objects >= 0 else { throw Failure.unsafeFile }
            do {
                try Self.validateDescriptor(objects, directory: true)
                guard fchmod(objects, 0o700) == 0 else { throw Self.posixError() }
            } catch { close(objects); throw error }
            rootDescriptor = root
            objectsDescriptor = objects
        } catch { close(root); throw error }
        // All stored properties are now initialized. Swift runs deinit if this throws;
        // manually closing here would double-close FDs another concurrent opener can reuse.
        try withAccess(exclusive: true) { manifest in
            if manifest == nil { try publish(Manifest()) }
        }
    }

    convenience init(url: URL) throws { try self.init(file: url) }

    deinit {
        cancelSearchIndexPreparation()
        cancelDeferredMaintenance()
        close(objectsDescriptor)
        close(rootDescriptor)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func normalizedPath(_ file: URL) -> String { normalizedPath(file.path) }

    static func referenceComesFirst(_ lhs: ConversationIndexDocumentReference,
                                   _ rhs: ConversationIndexDocumentReference) -> Bool {
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.transcriptID != rhs.transcriptID { return lhs.transcriptID < rhs.transcriptID }
        return lhs.sessionPath < rhs.sessionPath
    }

    func generation() throws -> Int64 {
        try withManifest { $0.generation }
    }

    func catalogIdentity() throws -> String { try withManifest { $0.identity } }

    func searchIndexRevision() throws -> (identity: String, generation: Int64) {
        try withManifest { ($0.identity, $0.generation) }
    }

    func hasRows() throws -> Bool { try withManifest { !$0.objects.isEmpty } }

    /// A damaged derived row can be reparsed by the scanner without hiding unrelated sessions.
    /// Root-manifest corruption is different: it throws and is never silently treated as empty.
    var catalogCorruptRecordCount: Int { stateLock.withLock { corruptRecordNames.count } }

    /// Compression and pack I/O happen before acquiring the publication lock. List reads and
    /// searches remain available while even a very large replacement is being prepared.
    @discardableResult
    func replace(_ session: ConversationIndexedSession) throws -> Int64 {
        try validate(session)
        let prepared = try prepare(session)
        defer {
            close(prepared.descriptor)
            _ = unlinkat(objectsDescriptor, prepared.temporaryPack, 0)
        }
        return try mutate { manifest in
            var documents = prepared.documents
            for index in documents.indices {
                documents[index].id = try allocate(&manifest.nextDocumentID)
                for chunk in documents[index].chunks.indices {
                    documents[index].chunks[chunk].id = try allocate(&manifest.nextChunkID)
                }
            }
            guard renameat(objectsDescriptor, prepared.temporaryPack,
                           objectsDescriptor, prepared.finalPack) == 0 else { throw Self.posixError() }
            let path = Self.normalizedPath(session.metadata.file)
            let record = Record(entry: makeEntry(session), pack: prepared.finalPack,
                documents: documents)
            manifest.objects[path] = try writeRecord(record)
            return try advance(&manifest)
        }
    }

    /// The quick-metadata batch retains previously published transcript packs. It deliberately
    /// retains content tokens too, so tags/title/pin edits never rebuild text postings. Large
    /// immutable headers are encoded and flushed outside both locks. Publication compares only
    /// affected objects, so an unrelated session update does not restart this work.
    @discardableResult
    func replaceMetadata(_ sessions: [ConversationIndexedSession]) throws -> Int64 {
        for session in sessions { try validate(session) }
        guard !sessions.isEmpty else { return try generation() }
        var unique: [String: ConversationIndexedSession] = [:]
        for session in sessions { unique[Self.normalizedPath(session.metadata.file)] = session }
        while true {
            try Task.checkCancellation()
            let snapshot = try withManifest { manifest in
                var records: [String: (reference: ObjectReference?, record: Record?)] = [:]
                for path in unique.keys {
                    let reference = manifest.objects[path]
                    records[path] = (reference, try reference.flatMap {
                        try usableRecord($0, expectedPath: path)
                    })
                }
                return MetadataSnapshot(identity: manifest.identity, records: records)
            }
            var prepared: [PreparedHeader] = []
            defer {
                for header in prepared {
                    _ = unlinkat(objectsDescriptor, header.temporary, 0)
                    close(header.descriptor)
                }
            }
            for (path, session) in unique {
                let previous = snapshot.records[path]
                let record = Record(entry: makeEntry(session), pack: previous?.record?.pack,
                    documents: previous?.record?.documents ?? [])
                prepared.append(try prepareHeader(record, path: path, previous: previous?.reference))
            }
#if DEBUG
            try metadataPreparationDidFinishForTesting?()
#endif
            let committed: Int64? = try mutate { manifest in
                guard manifest.identity == snapshot.identity,
                      prepared.allSatisfy({ manifest.objects[$0.path] == $0.previous }) else {
                    return nil
                }
                try Task.checkCancellation()
                let generation = try advance(&manifest)
                for header in prepared {
                    guard renameat(objectsDescriptor, header.temporary,
                                   objectsDescriptor, header.reference.name) == 0 else {
                        throw Self.posixError()
                    }
                    manifest.objects[header.path] = header.reference
                    cachedRecords[header.reference.name] = (header.reference.checksum, header.record)
                }
                guard fsync(objectsDescriptor) == 0 else { throw Self.posixError() }
                return generation
            }
            if let committed { return committed }
            // A competing content replacement wins. Discard only this attempt's partials,
            // then snapshot the latest document IDs/content tokens before preparing again.
        }
    }

    @discardableResult
    func remove(paths: [String]) throws -> Int {
        try mutate { manifest in
            var removed = 0
            for path in Set(paths.map(Self.normalizedPath)) {
                if manifest.objects.removeValue(forKey: path) != nil { removed += 1 }
            }
            if removed > 0 { _ = try advance(&manifest) }
            return removed
        }
    }

    @discardableResult
    func remove(files: [URL]) throws -> Int { try remove(paths: files.map(Self.normalizedPath)) }

    func reconcile(scope: String, seenPaths: Set<String>, allowEmpty: Bool = false) throws
        -> ConversationIndexReconciliation {
        let seen = Set(seenPaths.map(Self.normalizedPath))
        guard allowEmpty || !seen.isEmpty else {
            throw ConversationCatalogError.unsafeEmptyReconciliation(scope)
        }
        return try mutate { manifest in
            var removed: [String] = []
            for (path, object) in manifest.objects where !seen.contains(path) {
                if try usableRecord(object, expectedPath: path)?.entry.scope == scope { removed.append(path) }
            }
            for path in removed { manifest.objects.removeValue(forKey: path) }
            if !removed.isEmpty { _ = try advance(&manifest) }
            return .init(removedPaths: removed.sorted(), generation: manifest.generation)
        }
    }

    func storedFingerprints(scope: String? = nil) throws -> [String: ConversationIndexFingerprint] {
        try withManifest { manifest in
            var result: [String: ConversationIndexFingerprint] = [:]
            for (path, object) in manifest.objects {
                guard let entry = try usableRecord(object, expectedPath: path)?.entry else { continue }
                if scope == nil || entry.scope == scope { result[path] = entry.fingerprint }
            }
            return result
        }
    }

    func entry(for file: URL) throws -> ConversationIndexEntry? { try entry(forPath: Self.normalizedPath(file)) }

    func entry(forPath path: String) throws -> ConversationIndexEntry? {
        let normalized = Self.normalizedPath(path)
        return try withManifest { manifest in
            try manifest.objects[normalized].flatMap { try usableRecord($0, expectedPath: normalized)?.entry }
        }
    }

    func loadAllMetadata() throws -> [HistorySessionMetadata] {
        try listEntries(deleted: nil, limit: .max).map(\.metadata)
    }

    func scannerEntries() throws -> [ConversationIndexEntry] {
        try listEntries(deleted: nil, limit: .max)
    }

    func listEntries(scope: String? = nil, source: HistorySource? = nil, deleted: Bool? = false,
                     limit: Int = 400, offset: Int = 0) throws -> [ConversationIndexEntry] {
        guard limit > 0, offset >= 0 else { return [] }
        let entries = try withManifest { manifest in
            try manifest.objects.compactMap { path, object -> ConversationIndexEntry? in
                guard let entry = try usableRecord(object, expectedPath: path)?.entry else { return nil }
                return matches(entry, scope: scope, source: source, deleted: deleted) ? entry : nil
            }
        }.sorted {
            if $0.metadata.lastActivity != $1.metadata.lastActivity {
                return $0.metadata.lastActivity > $1.metadata.lastActivity
            }
            if $0.metadata.createdAt != $1.metadata.createdAt {
                return $0.metadata.createdAt > $1.metadata.createdAt
            }
            return $0.sourcePath > $1.sourcePath
        }
        return Array(entries.dropFirst(offset).prefix(limit))
    }

    func scopeSummaries(deleted: Bool? = false) throws -> [ConversationIndexScopeSummary] {
        var result: [String: ConversationIndexScopeSummary] = [:]
        for entry in try listEntries(deleted: deleted, limit: .max) {
            if var summary = result[entry.scope] {
                summary.sessionCount += 1
                summary.lastActivity = max(summary.lastActivity, entry.metadata.lastActivity)
                result[entry.scope] = summary
            } else {
                result[entry.scope] = .init(scope: entry.scope, sessionCount: 1,
                    lastActivity: entry.metadata.lastActivity)
            }
        }
        return result.values.sorted {
            $0.lastActivity == $1.lastActivity ? $0.scope < $1.scope : $0.lastActivity > $1.lastActivity
        }
    }

    func catalogSearchSnapshot(scope: String? = nil, source: HistorySource? = nil,
                               deleted: Bool? = false) throws -> SearchSnapshot {
        try withManifest { manifest in
            var documents: [SearchDocument] = []
            for (path, object) in manifest.objects {
                try Task.checkCancellation()
                guard let record = try usableRecord(object, expectedPath: path) else { continue }
                guard matches(record.entry, scope: scope, source: source, deleted: deleted) else { continue }
                for document in record.documents {
                    documents.append(SearchDocument(reference: reference(document, record: record,
                        manifest: manifest), contentToken: document.contentToken,
                        chunkIDs: document.chunks.map(\.id)))
                }
            }
            documents.sort { Self.referenceComesFirst($0.reference, $1.reference) }
            return SearchSnapshot(generation: manifest.generation, identity: manifest.identity,
                documents: documents)
        }
    }

    func allDocumentReferences(scope: String? = nil, source: HistorySource? = nil,
                               deleted: Bool? = false) throws -> ConversationIndexCandidateReferenceBatch {
        .init(references: try catalogSearchSnapshot(scope: scope, source: source, deleted: deleted)
            .documents.map(\.reference), usedFallback: true)
    }

    func refinementGeneration(reference: ConversationIndexDocumentReference) throws -> Int64? {
        try withManifest { manifest in
            try checkIdentity(reference, manifest: manifest)
            try checkGeneration(reference.catalogGeneration, current: manifest.generation)
            return try lookup(reference, manifest: manifest) == nil ? nil : manifest.generation
        }
    }

    func searchChunkWindows(reference: ConversationIndexDocumentReference, query: String,
                            cursor: ConversationIndexSearchCursor? = nil, limit: Int = 1) throws
        -> ConversationIndexSearchWindowBatch {
        let packet = try packet(for: reference, expectedGeneration: cursor?.generation)
        guard let packet else {
            return .init(windows: [], nextCursor: nil, generation: try generation())
        }
        defer { close(packet.descriptor) }
        let first = max(0, cursor?.nextOrdinal ?? 0)
        let chunks = packet.document.chunks
        let pageLimit = max(1, limit)
        var page: [Int] = []
        var hasMore = false
        if first < chunks.count, let selected = reference.candidateChunkIDs {
            // The candidate producer emits IDs in document/ordinal order. Both ID sequences
            // are monotonic: binary seeks avoid rescanning a giant transcript on every page.
            var position = Self.lowerBound(selected, value: chunks[first].id)
            while position < selected.count {
                let id = selected[position]
                let ordinal = Self.chunkOrdinal(chunks, id: id)
                position += 1
                guard ordinal < chunks.count, chunks[ordinal].id == id, ordinal >= first else { continue }
                if page.count == pageLimit { hasMore = true; break }
                page.append(ordinal)
            }
        } else if first < chunks.count {
            let end = first + min(pageLimit, chunks.count - first)
            page = Array(first..<end)
            hasMore = end < chunks.count
        }
        var windows: [ConversationIndexSearchWindow] = []
        for ordinal in page {
            windows.append(try window(packet, ordinal: ordinal,
                lookahead: ConversationSearchChunk.lookaheadCharacters(for: query)))
        }
        var next: ConversationIndexSearchCursor?
        if hasMore, let last = page.last {
            next = ConversationIndexSearchCursor(nextOrdinal: last + 1, generation: packet.generation)
        }
        return .init(windows: windows, nextCursor: next, generation: packet.generation)
    }

    private static func lowerBound(_ values: [Int64], value: Int64) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] < value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private static func chunkOrdinal(_ chunks: [Chunk], id: Int64) -> Int {
        var lower = 0
        var upper = chunks.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if chunks[middle].id < id { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    /// A posting group shares one normalization/build operation, but physical refinement remains
    /// 32 KiB. The last block supplies right lookahead so group boundaries cannot lose a match.
    func searchIndexGroup(document: SearchDocument, firstOrdinal: Int, chunkCount: Int = 8,
                          generation: Int64) throws -> String {
        // Background indexing follows immutable content identity, not list revisions: a title
        // edit or another live session must not restart indexing an unchanged large pack.
        let packet = try withManifest { manifest -> ReadPacket? in
            guard let (record, stored) = try lookup(document.reference, manifest: manifest),
                  stored.contentToken == document.contentToken else { return nil }
            return ReadPacket(generation: manifest.generation, document: stored,
                descriptor: try openPack(record.pack), packName: record.pack)
        }
        guard let packet else {
            throw ConversationCatalogError.staleRevision
        }
        defer { close(packet.descriptor) }
        guard firstOrdinal >= 0, firstOrdinal < packet.document.chunks.count, chunkCount > 0 else {
            throw ConversationCatalogError.invalidRecord("invalid posting group")
        }
        let end = min(packet.document.chunks.count, firstOrdinal + chunkCount)
        var result = ""
        for ordinal in firstOrdinal..<end {
            let lookahead = ordinal == end - 1 ? ConversationSearchChunk.indexLookaheadCharacters : 0
            result.append(try window(packet, ordinal: ordinal, lookahead: lookahead).text)
        }
        return result
    }

    func searchChunkSnippet(reference: ConversationIndexDocumentReference, offsetUTF16: Int,
                            matchLengthUTF16: Int, context: Int = 56) throws -> String? {
        guard offsetUTF16 >= 0, matchLengthUTF16 > 0,
              matchLengthUTF16 <= Int.max - offsetUTF16,
              let packet = try packet(for: reference) else { return nil }
        defer { close(packet.descriptor) }
        let chunks = packet.document.chunks
        guard let ordinal = chunks.lastIndex(where: { $0.utf16Location <= offsetUTF16 }) else { return nil }
        let current = try window(packet, ordinal: ordinal, lookahead: 0)
        var text = current.text
        var globalStart = current.globalUTF16Start
        var hasMoreAfter = false
        let radius = max(0, context)
        var previous = ordinal - 1
        while previous >= 0 {
            let local = offsetUTF16 - globalStart
            guard local >= 0, local <= text.utf16.count else { return nil }
            let start = String.Index(utf16Offset: local, in: text)
            if text[..<start].count > radius { break }
            let part = try window(packet, ordinal: previous, lookahead: 0)
            let suffix = String(part.text.suffix(radius + 1))
            text = suffix + text
            globalStart -= suffix.utf16.count
            if suffix.utf16.count < part.ownedUTF16Length { break }
            previous -= 1
        }
        var next = ordinal + 1
        while true {
            let matchEnd = offsetUTF16 - globalStart + matchLengthUTF16
            if text.utf16.count >= matchEnd {
                let end = String.Index(utf16Offset: matchEnd, in: text)
                if text[end...].count > radius { hasMoreAfter = true; break }
            }
            guard next < chunks.count else { break }
            text.append(try window(packet, ordinal: next, lookahead: 0).text)
            next += 1
        }
        let local = offsetUTF16 - globalStart
        guard local >= 0, local <= text.utf16.count,
              matchLengthUTF16 <= text.utf16.count - local else { return nil }
        let lower = String.Index(utf16Offset: local, in: text)
        let upper = String.Index(utf16Offset: local + matchLengthUTF16, in: text)
        let start = text.index(lower, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(upper, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (globalStart > 0 || start > text.startIndex ? "…" : "") + body
            + (hasMoreAfter || end < text.endIndex ? "…" : "")
    }

    func documents(for file: URL) throws -> [ConversationIndexDocument] {
        try documents(forPath: Self.normalizedPath(file))
    }

    func documents(forPath path: String) throws -> [ConversationIndexDocument] {
        let normalized = Self.normalizedPath(path)
        let packets = try withManifest { manifest -> [ReadPacket] in
            guard let object = manifest.objects[normalized] else { return [] }
            guard let record = try usableRecord(object, expectedPath: normalized) else { return [] }
            var packets: [ReadPacket] = []
            do {
                for document in record.documents {
                    packets.append(ReadPacket(generation: manifest.generation, document: document,
                        descriptor: try openPack(record.pack), packName: record.pack))
                }
            } catch { for packet in packets { close(packet.descriptor) }; throw error }
            return packets
        }
        defer { for packet in packets { close(packet.descriptor) } }
        return try packets.map(decodeDocument)
    }

    func document(id: Int64, expectedSessionPath: String? = nil,
                  expectedTranscriptID: String? = nil) throws -> ConversationIndexDocument? {
        let packet = try withManifest { manifest -> ReadPacket? in
            for (path, object) in manifest.objects {
                if let expectedSessionPath, path != expectedSessionPath { continue }
                guard let record = try usableRecord(object, expectedPath: path) else { continue }
                guard let document = record.documents.first(where: {
                    $0.id == id && (expectedTranscriptID == nil || $0.transcriptID == expectedTranscriptID)
                }) else { continue }
                return ReadPacket(generation: manifest.generation, document: document,
                    descriptor: try openPack(record.pack), packName: record.pack)
            }
            return nil
        }
        guard let packet else { return nil }
        defer { close(packet.descriptor) }
        return try decodeDocument(packet)
    }

    func refinementDocument(reference: ConversationIndexDocumentReference,
                             cachedGeneration: Int64?) throws -> ConversationIndexRefinementRead? {
        guard let packet = try packet(for: reference) else { return nil }
        defer { close(packet.descriptor) }
        if cachedGeneration == packet.generation { return .unchanged(generation: packet.generation) }
        return .document(generation: packet.generation, try decodeDocument(packet))
    }

    @discardableResult
    func invalidateProjection() throws -> Int64 { try mutate { try advance(&$0) } }

    @discardableResult
    func rebuild() throws -> Int64 {
        try mutate { manifest in
            manifest.objects.removeAll()
            return try advance(&manifest)
        }
    }

    private func packet(for reference: ConversationIndexDocumentReference,
                        expectedGeneration: Int64? = nil) throws -> ReadPacket? {
        try withManifest { manifest in
            try checkIdentity(reference, manifest: manifest)
            try checkGeneration(reference.catalogGeneration, current: manifest.generation)
            try checkGeneration(expectedGeneration, current: manifest.generation)
            guard let (record, document) = try lookup(reference, manifest: manifest) else { return nil }
            return ReadPacket(generation: manifest.generation, document: document,
                descriptor: try openPack(record.pack), packName: record.pack)
        }
    }

    private func lookup(_ reference: ConversationIndexDocumentReference, manifest: Manifest) throws
        -> (Record, Document)? {
        guard let object = manifest.objects[reference.sessionPath] else { return nil }
        guard let record = try usableRecord(object, expectedPath: reference.sessionPath) else { return nil }
        guard let document = record.documents.first(where: {
            $0.id == reference.documentID && $0.transcriptID == reference.transcriptID
        }) else { return nil }
        return (record, document)
    }

    private func reference(_ document: Document, record: Record, manifest: Manifest)
        -> ConversationIndexDocumentReference {
        .init(documentID: document.id, sessionPath: record.entry.sourcePath,
            transcriptID: document.transcriptID, agentType: document.agentType,
            sortOrder: document.sortOrder, lastActivity: record.entry.metadata.lastActivity,
            catalogGeneration: manifest.generation, catalogIdentity: manifest.identity)
    }

    private func decodeDocument(_ packet: ReadPacket) throws -> ConversationIndexDocument {
        var text = ""
        var spans: [Int: ConversationIndexMessageSpan] = [:]
        for ordinal in packet.document.chunks.indices {
            let part = try window(packet, ordinal: ordinal, lookahead: 0)
            text.append(part.text)
            for span in part.messageSpans { spans[span.sequence] = span }
        }
        return .init(transcriptID: packet.document.transcriptID, agentType: packet.document.agentType,
            sortOrder: packet.document.sortOrder, text: text,
            messageSpans: spans.values.sorted { $0.utf16Location < $1.utf16Location })
    }

    private func window(_ packet: ReadPacket, ordinal: Int, lookahead: Int) throws
        -> ConversationIndexSearchWindow {
        try Task.checkCancellation()
        let chunks = packet.document.chunks
        guard chunks.indices.contains(ordinal) else { throw Failure.corrupt("block ordinal") }
        let first = chunks[ordinal]
        var text = try decodeChunk(first, packet: packet)
        var spans = Dictionary(first.spans.map { ($0.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining = max(0, lookahead)
        var next = ordinal + 1
        while remaining > 0, next < chunks.count {
            let suffix = try decodeChunk(chunks[next], packet: packet)
            let prefix = suffix.prefix(remaining)
            text.append(contentsOf: prefix)
            remaining -= prefix.count
            for span in chunks[next].spans { spans[span.sequence] = span }
            next += 1
        }
        return .init(chunkID: first.id, text: text, globalUTF16Start: first.utf16Location,
            ownedUTF16Length: first.utf16Length,
            messageSpans: ConversationSearchChunk.spans(spans.values.sorted { $0.utf16Location < $1.utf16Location },
                location: first.utf16Location, length: text.utf16.count), generation: packet.generation)
    }

    private func decodeChunk(_ chunk: Chunk, packet: ReadPacket) throws -> String {
        do { return try decodeChunkBytes(chunk, descriptor: packet.descriptor) }
        catch {
            let corrupt: Bool
            switch error {
            case Failure.corrupt, ConversationCatalogError.corruptRow: corrupt = true
            default: corrupt = false
            }
            if corrupt, let pack = packet.packName {
                stateLock.lock()
                corruptPackNames.insert(pack)
                stateLock.unlock()
            }
            throw error
        }
    }

    private func decodeChunkBytes(_ chunk: Chunk, descriptor: Int32) throws -> String {
        try Task.checkCancellation()
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0,
              chunk.offset <= UInt64(info.st_size), chunk.storedBytes >= 0,
              UInt64(chunk.storedBytes) <= UInt64(info.st_size) - chunk.offset else {
            throw Failure.corrupt("block extent")
        }
        let bytes = try Self.read(descriptor, count: chunk.storedBytes, offset: chunk.offset)
        guard Self.checksum(bytes) == chunk.checksum else { throw Failure.corrupt("block checksum") }
        let text = try ConversationSearchCompression.decode(bytes, codec: chunk.codec,
            decodedBytes: chunk.decodedBytes)
        guard text.utf16.count == chunk.utf16Length else { throw Failure.corrupt("block UTF-16 length") }
        return text
    }

    private func prepare(_ session: ConversationIndexedSession) throws -> Prepared {
        let identifier = UUID().uuidString.lowercased()
        let temporary = ".\(identifier).partial"
        let final = "\(identifier).pack"
        let descriptor = try createLeasedPartial(temporary)
        var completed = false
        defer {
            if !completed { close(descriptor); _ = unlinkat(objectsDescriptor, temporary, 0) }
        }
        var documents: [Document] = []
        var offset: UInt64 = 0
        for input in session.documents.sorted(by: {
            $0.sortOrder == $1.sortOrder ? $0.transcriptID < $1.transcriptID : $0.sortOrder < $1.sortOrder
        }) {
            var chunks: [Chunk] = []
            try ConversationSearchChunk.forEachPart(of: input.text) { part in
                try Task.checkCancellation()
                let encoded = ConversationSearchCompression.encode(part.text)
                try Self.write(encoded.bytes, descriptor: descriptor)
                chunks.append(Chunk(ordinal: chunks.count, utf16Location: part.utf16Location,
                    utf16Length: part.utf16Length, offset: offset, storedBytes: encoded.bytes.count,
                    decodedBytes: encoded.decodedBytes, codec: encoded.codec,
                    checksum: Self.checksum(encoded.bytes),
                    spans: ConversationSearchChunk.spans(input.messageSpans, location: part.utf16Location,
                        length: part.utf16Length)))
                offset += UInt64(encoded.bytes.count)
            }
            documents.append(Document(transcriptID: input.transcriptID, agentType: input.agentType,
                sortOrder: input.sortOrder, contentToken: UUID().uuidString.lowercased(), chunks: chunks))
        }
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
        completed = true
        return Prepared(temporaryPack: temporary, finalPack: final, documents: documents,
            descriptor: descriptor)
    }

    private func prepareHeader(_ record: Record, path: String,
                               previous: ObjectReference?) throws -> PreparedHeader {
        try Task.checkCancellation()
        let identifier = UUID().uuidString.lowercased()
        let temporary = ".\(identifier).partial"
        let descriptor = try createLeasedPartial(temporary)
        var completed = false
        defer {
            if !completed { _ = unlinkat(objectsDescriptor, temporary, 0); close(descriptor) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(record)
        try Self.write(bytes, descriptor: descriptor)
        let checksum = Self.checksum(bytes)
        try Task.checkCancellation()
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
        completed = true
        return PreparedHeader(path: path, previous: previous,
            reference: ObjectReference(name: identifier + ".header", checksum: checksum),
            record: record, temporary: temporary, descriptor: descriptor)
    }

    private func createLeasedPartial(_ name: String) throws -> Int32 {
        // Creation and taking the writer lease share the catalog's short read lock, closing
        // the create-before-flock race with orphan reclamation in another process. Keep this
        // descriptor open until publication/discard; GC must never unlink an active partial.
        try withManifest { _ -> Int32 in
            let descriptor = openat(objectsDescriptor, name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Self.posixError() }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let error = Self.posixError()
                _ = unlinkat(objectsDescriptor, name, 0)
                close(descriptor)
                throw error
            }
            return descriptor
        }
    }

    private func makeEntry(_ session: ConversationIndexedSession) -> ConversationIndexEntry {
        .init(sourcePath: Self.normalizedPath(session.metadata.file), metadata: session.metadata,
            scope: session.scope, fingerprint: session.fingerprint, indexedAt: .now)
    }

    private func matches(_ entry: ConversationIndexEntry, scope: String?, source: HistorySource?,
                         deleted: Bool?) -> Bool {
        (scope == nil || entry.scope == scope) && (source == nil || entry.metadata.source == source)
            && (deleted == nil || entry.metadata.deleted == deleted)
    }

    private func checkGeneration(_ expected: Int64?, current: Int64) throws {
        if let expected, expected != current { throw ConversationCatalogError.staleRevision }
    }

    private func checkIdentity(_ reference: ConversationIndexDocumentReference, manifest: Manifest) throws {
        if let identity = reference.catalogIdentity, identity != manifest.identity {
            throw ConversationCatalogError.staleRevision
        }
    }

    private func allocate(_ next: inout Int64) throws -> Int64 {
        guard next > 0, next < Int64.max else { throw Failure.corrupt("identifier exhaustion") }
        defer { next += 1 }
        return next
    }

    private func advance(_ manifest: inout Manifest) throws -> Int64 {
        guard manifest.generation < Int64.max else { throw Failure.corrupt("revision exhaustion") }
        manifest.generation += 1
        return manifest.generation
    }

    private func validate(_ session: ConversationIndexedSession) throws {
        guard session.metadata.file.isFileURL, !session.scope.isEmpty,
              session.fingerprint.sizeBytes <= UInt64(Int64.max),
              session.fingerprint.modificationTime.timeIntervalSince1970.isFinite,
              session.metadata.createdAt.timeIntervalSince1970.isFinite,
              session.metadata.lastActivity.timeIntervalSince1970.isFinite else {
            throw ConversationCatalogError.invalidRecord("invalid session metadata")
        }
        var identities = Set<String>()
        for document in session.documents {
            guard !document.transcriptID.isEmpty, identities.insert(document.transcriptID).inserted,
                  document.sortOrder >= 0 else {
                throw ConversationCatalogError.invalidRecord("invalid transcript identity")
            }
            let length = document.text.utf16.count
            var end = 0
            var sequences = Set<Int>()
            for span in document.messageSpans {
                guard span.sequence >= 0, sequences.insert(span.sequence).inserted, span.messageIndex >= 0,
                      span.utf16Location >= end, span.utf16Length >= 0,
                      span.utf16Location <= length, span.utf16Length <= length - span.utf16Location else {
                    throw ConversationCatalogError.invalidRecord("invalid message span")
                }
                end = span.utf16Location + span.utf16Length
            }
        }
    }

    // MARK: - Atomic publication and read snapshots

    private func withManifest<T>(_ body: (Manifest) throws -> T) throws -> T {
        try withAccess(exclusive: false) { manifest in
            guard let manifest else { throw Failure.corrupt("missing manifest") }
            return try body(manifest)
        }
    }

    private func mutate<T>(_ body: (inout Manifest) throws -> T) throws -> T {
        try withAccess(exclusive: true) { current in
            guard var manifest = current else { throw Failure.corrupt("missing manifest") }
            let result = try body(&manifest)
            if manifest.generation != current?.generation {
                try Task.checkCancellation()
                try publish(manifest)
                maintenanceLock.lock()
                maintenancePending = true
                maintenanceLock.unlock()
            }
            return result
        }
    }

    private func withAccess<T>(exclusive: Bool, isCancelled: () -> Bool = { false },
                               _ body: (Manifest?) throws -> T) throws -> T {
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
        while !stateLock.lock(before: Date(timeIntervalSinceNow: 0.01)) {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
        }
        defer { stateLock.unlock() }
        let descriptor = try openCatalogLock()
        defer { close(descriptor) }
        try Self.validateDescriptor(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw Self.posixError() }
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        while flock(descriptor, operation) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw Self.posixError() }
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
        return try body(loadManifest())
    }

    private func openCatalogLock() throws -> Int32 {
        while true {
            try Task.checkCancellation()
            let existing = openat(rootDescriptor, ".catalog.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if existing >= 0 { return existing }
            guard errno == ENOENT else { throw Failure.unsafeFile }
            // Darwin can reject simultaneous O_CREAT|O_NOFOLLOW lookups with a spurious
            // ELOOP. Separating ordinary lookup from exclusive creation closes that race
            // without ever weakening symlink protection.
            let created = openat(rootDescriptor, ".catalog.lock",
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            if created >= 0 { return created }
            guard errno == EEXIST else { throw Failure.unsafeFile }
        }
    }

    private func loadManifest() throws -> Manifest? {
        let descriptor = openat(rootDescriptor, "manifest.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Failure.unsafeFile
        }
        defer { close(descriptor) }
        try Self.validateDescriptor(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
        let identity = FileIdentity(inode: UInt64(info.st_ino), size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec)
        if identity == cachedManifestIdentity, let cachedManifest { return cachedManifest }
        let bytes = try Self.readFile(descriptor, maximumBytes: 64 * 1_024 * 1_024)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: bytes) }
        catch { throw Failure.corrupt("manifest encoding") }
        guard manifest.version == Self.formatVersion else { throw Failure.unsupportedVersion(manifest.version) }
        guard let expectedChecksum = manifest.checksum,
              try Self.manifestChecksum(manifest) == expectedChecksum else {
            throw Failure.corrupt("manifest checksum")
        }
        guard UUID(uuidString: manifest.identity) != nil,
              manifest.generation >= 0, manifest.nextDocumentID > 0, manifest.nextChunkID > 0,
              manifest.objects.keys.allSatisfy({ Self.normalizedPath($0) == $0 }) else {
            throw Failure.corrupt("manifest identities")
        }
        let retained = Set(manifest.objects.values.map(\.name))
        cachedRecords = cachedRecords.filter { retained.contains($0.key) }
        corruptRecordNames.formIntersection(retained)
        cachedManifest = manifest
        cachedManifestIdentity = identity
        return manifest
    }

    private func publish(_ manifest: Manifest) throws {
        var sealed = manifest
        sealed.checksum = try Self.manifestChecksum(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.atomicWrite(encoder.encode(sealed), name: "manifest.json", parent: rootDescriptor)
        cachedManifest = sealed
        cachedManifestIdentity = nil
    }

    private static func manifestChecksum(_ manifest: Manifest) throws -> String {
        var content = manifest
        content.checksum = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return checksum(try encoder.encode(content))
    }

    private func writeRecord(_ record: Record) throws -> ObjectReference {
        let name = UUID().uuidString.lowercased() + ".header"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(record)
        try Self.atomicWrite(bytes, name: name, parent: objectsDescriptor)
        let checksum = Self.checksum(bytes)
        cachedRecords[name] = (checksum, record)
        return ObjectReference(name: name, checksum: checksum)
    }

    private func readRecord(_ object: ObjectReference, expectedPath: String) throws -> Record {
        guard Self.isObjectName(object.name, suffix: ".header") else { throw Failure.unsafeFile }
        if let cached = cachedRecords[object.name], cached.checksum == object.checksum {
            let record = cached.record
            guard record.entry.sourcePath == expectedPath else { throw Failure.corrupt("session identity") }
            if let pack = record.pack, corruptPackNames.contains(pack) { throw Failure.corrupt("damaged pack") }
            return record
        }
        let descriptor = try openObject(object.name)
        defer { close(descriptor) }
        let bytes = try Self.readFile(descriptor, maximumBytes: 128 * 1_024 * 1_024)
        guard Self.checksum(bytes) == object.checksum else { throw Failure.corrupt("header checksum") }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: bytes) }
        catch { throw Failure.corrupt("header encoding") }
        guard record.version == Self.formatVersion, record.entry.sourcePath == expectedPath,
              Self.normalizedPath(record.entry.metadata.file) == expectedPath,
              !record.entry.scope.isEmpty else { throw Failure.corrupt("session header") }
        if let pack = record.pack, !Self.isObjectName(pack, suffix: ".pack") { throw Failure.unsafeFile }
        if let pack = record.pack, corruptPackNames.contains(pack) { throw Failure.corrupt("damaged pack") }
        guard record.documents.isEmpty || record.pack != nil else { throw Failure.corrupt("missing pack") }
        if let pack = record.pack {
            let descriptor = try openObject(pack)
            close(descriptor)
        }
        var ids = Set<Int64>()
        var transcripts = Set<String>()
        for document in record.documents {
            guard document.id > 0, ids.insert(document.id).inserted,
                  !document.transcriptID.isEmpty, transcripts.insert(document.transcriptID).inserted,
                  document.sortOrder >= 0, UUID(uuidString: document.contentToken) != nil else {
                throw Failure.corrupt("document identity")
            }
            var location = 0
            for (ordinal, chunk) in document.chunks.enumerated() {
                guard chunk.id > 0, chunk.ordinal == ordinal, chunk.utf16Location == location,
                      chunk.utf16Length >= 0, chunk.utf16Length <= Int.max - location,
                      chunk.storedBytes >= 0, chunk.decodedBytes >= 0,
                      chunk.codec == 0 || chunk.codec == 1 else { throw Failure.corrupt("block header") }
                location += chunk.utf16Length
            }
        }
        cachedRecords[object.name] = (object.checksum, record)
        return record
    }

    private func usableRecord(_ object: ObjectReference, expectedPath: String) throws -> Record? {
        do { return try readRecord(object, expectedPath: expectedPath) }
        catch Failure.corrupt {
            corruptRecordNames.insert(object.name)
            return nil
        }
    }

    private func openPack(_ name: String?) throws -> Int32 {
        guard let name, Self.isObjectName(name, suffix: ".pack") else { throw Failure.corrupt("pack identity") }
        return try openObject(name)
    }

    private func openObject(_ name: String) throws -> Int32 {
        // Type validation follows open, so nonblocking mode must be present even when a
        // malformed cache entry is a FIFO. Regular-file pread behavior is unchanged.
        let descriptor = openat(objectsDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw Failure.corrupt("missing object") }
            throw Failure.unsafeFile
        }
        do { try Self.validateDescriptor(descriptor) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private static func isObjectName(_ name: String, suffix: String) -> Bool {
        guard name.hasSuffix(suffix) else { return false }
        let stem = String(name.dropLast(suffix.count))
        return stem.count == 36 && UUID(uuidString: stem) != nil
    }

    private static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(".") && isObjectName(String(name.dropFirst()), suffix: ".partial")
    }

    private static func validateDescriptor(_ descriptor: Int32, directory: Bool = false) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw Failure.unsafeFile }
    }

    private static func atomicWrite(_ data: Data, name: String, parent: Int32) throws {
        let temporary = ".\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(parent, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); _ = unlinkat(parent, temporary, 0) }
        try write(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw posixError() }
        guard renameat(parent, temporary, parent, name) == 0 else { throw posixError() }
        guard fsync(parent) == 0 else { throw posixError() }
    }

    private static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    private static func readFile(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw Failure.corrupt("file size")
        }
        return try read(descriptor, count: Int(info.st_size), offset: 0)
    }

    private static func read(_ descriptor: Int32, count: Int, offset: UInt64) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0,
              UInt64(count) <= UInt64(Int64.max) - offset else { throw Failure.corrupt("file extent") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var copied = 0
            while copied < count {
                try Task.checkCancellation()
                let read = pread(descriptor, base.advanced(by: copied), count - copied, off_t(offset) + off_t(copied))
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw Failure.corrupt("truncated object") }
                copied += read
            }
        }
        return data
    }

    private static func checksum(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    // MARK: - Derived-object reclamation (no database maintenance)

    func maintenanceIsPending() throws -> Bool {
        maintenanceLock.lock()
        defer { maintenanceLock.unlock() }
        return maintenancePending
    }

    func finishFullScanMaintenance(shouldYield: @escaping ConversationIndexScanCancellation = { false },
                                   isCancelled: @escaping ConversationIndexScanCancellation = { false }) throws {
        if isCancelled() { throw CancellationError() }
        try Task.checkCancellation()
        if shouldYield() { return }
        var retained = Set<String>()
        var retainedGeneration: Int64?
        var retainedIdentity: String?
        try withAccess(exclusive: false, isCancelled: isCancelled) { current in
            guard let current else { throw Failure.corrupt("missing manifest") }
            retained = Set(current.objects.values.map(\.name))
            for (path, object) in current.objects {
                if let pack = try readRecord(object, expectedPath: path).pack { retained.insert(pack) }
            }
            retainedGeneration = current.generation
            retainedIdentity = current.identity
        }
        // Filtering published names once avoids repeatedly walking an unchanged live prefix
        // on every cooperative pass. Successfully unlinked orphans disappear from the next pass.
        let names = try objectNames().filter { !retained.contains($0) }
        maintenanceLock.lock()
        if !names.isEmpty { maintenancePending = true }
        maintenanceLock.unlock()
        let start = ContinuousClock.now
        for offset in stride(from: 0, to: names.count, by: 24) {
            if isCancelled() { throw CancellationError() }
            try Task.checkCancellation()
            if shouldYield() || start.duration(to: .now) >= .milliseconds(250) { return }
            var yielded = false
            try withAccess(exclusive: true, isCancelled: isCancelled) { current in
                guard let current else { throw Failure.corrupt("missing manifest") }
                if retainedGeneration != current.generation || retainedIdentity != current.identity {
                    retained = Set(current.objects.values.map(\.name))
                    for (path, object) in current.objects {
                        // Do not reclaim anything if a damaged header prevents proving its
                        // pack ownership. A later source reparse can replace the bad record.
                        if let pack = try readRecord(object, expectedPath: path).pack { retained.insert(pack) }
                    }
                    retainedGeneration = current.generation
                    retainedIdentity = current.identity
                }
                for name in names[offset..<min(names.count, offset + 24)] {
                    if isCancelled() { throw CancellationError() }
                    try Task.checkCancellation()
                    if shouldYield() { yielded = true; return }
                    guard !retained.contains(name), Self.isObjectName(name, suffix: ".header")
                        || Self.isObjectName(name, suffix: ".pack") || Self.isPartialName(name) else { continue }
                    let descriptor: Int32
                    do { descriptor = try openObject(name) }
                    catch Failure.corrupt { continue } // another successful GC already removed it
                    catch Failure.unsafeFile { continue } // never remove a foreign link or special file
                    defer { close(descriptor) }
                    if Self.isPartialName(name), flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                        if errno == EWOULDBLOCK || errno == EINTR { continue }
                        throw Self.posixError()
                    }
                    var opened = stat()
                    var current = stat()
                    guard fstat(descriptor, &opened) == 0,
                          fstatat(objectsDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
                          current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                          current.st_uid == getuid() else { continue }
                    // Readers opened their pack FD under a shared lock before GC acquired
                    // this exclusive lock. Unlink cannot invalidate those FDs; subsequent
                    // reads must validate the new generation before opening another pack.
                    guard unlinkat(objectsDescriptor, name, 0) == 0 else { throw Self.posixError() }
                    cachedRecords.removeValue(forKey: name)
                }
                guard fsync(objectsDescriptor) == 0 else { throw Self.posixError() }
            }
            if yielded { return }
        }
        try withAccess(exclusive: false, isCancelled: isCancelled) { current in
            maintenanceLock.lock()
            if current?.generation == retainedGeneration, current?.identity == retainedIdentity {
                maintenancePending = false
            }
            maintenanceLock.unlock()
        }
    }

    private func objectNames() throws -> [String] {
        // dup shares a directory stream offset. A new open-file description is required so a
        // second maintenance pass does not inherit EOF from the preceding readdir traversal.
        let duplicated = openat(objectsDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicated >= 0 else { throw Self.posixError() }
        guard let directory = fdopendir(duplicated) else { close(duplicated); throw Self.posixError() }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if Self.isObjectName(name, suffix: ".header") || Self.isObjectName(name, suffix: ".pack")
                || Self.isPartialName(name) {
                names.append(name)
            }
        }
        return names.sorted()
    }

    func scheduleDeferredMaintenance(after delay: TimeInterval = 8) {
        let token = UUID()
        maintenanceLock.lock()
        maintenanceToken = token
        let epoch = activityEpoch
        maintenanceLock.unlock()
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            do {
                try self.finishFullScanMaintenance(shouldYield: { [weak self] in
                    guard let self else { return true }
                    self.maintenanceLock.lock()
                    defer { self.maintenanceLock.unlock() }
                    return self.activityEpoch != epoch
                }, isCancelled: { [weak self] in
                    guard let self else { return true }
                    self.maintenanceLock.lock()
                    defer { self.maintenanceLock.unlock() }
                    return self.maintenanceToken != token
                })
            } catch {
                // A damaged header or a disk error prevents proving what can be reclaimed.
                // Keep the pending bit for a later successful scan, without a retry IO loop.
                return
            }
            self.maintenanceLock.lock()
            let needsAnotherPass = self.maintenanceToken == token && self.maintenancePending
            self.maintenanceLock.unlock()
            if needsAnotherPass { self.scheduleDeferredMaintenance(after: 2) }
        }
    }

    func cancelDeferredMaintenance() {
        maintenanceLock.lock()
        maintenanceToken = nil
        maintenanceLock.unlock()
    }

    func yieldDeferredMaintenanceForActivity() {
        maintenanceLock.lock()
        activityEpoch &+= 1
        maintenanceLock.unlock()
    }
}
