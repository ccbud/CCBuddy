import Foundation
import SQLite3

/// The source-file facts which decide whether a conversation must be parsed again.
///
/// `dependencyFingerprint` covers producer-owned sidecars which can change a parsed session
/// without changing the main transcript (for example Qoder metadata or a SQLite WAL).
struct ConversationIndexFingerprint: Codable, Equatable, Sendable {
    var modificationTime: Date
    var sizeBytes: UInt64
    var dependencyFingerprint: String?

    init(
        modificationTime: Date,
        sizeBytes: UInt64,
        dependencyFingerprint: String? = nil
    ) {
        self.modificationTime = modificationTime
        self.sizeBytes = sizeBytes
        self.dependencyFingerprint = dependencyFingerprint
    }
}

/// Maps part of an aggregate search document back to a stable message anchor.
///
/// Locations and lengths use UTF-16, matching `NSRange` and SwiftUI/AppKit search APIs. The
/// sequence is parser-stable; `messageIndex` remains available to the current timeline renderer.
struct ConversationIndexMessageSpan: Codable, Equatable, Sendable {
    var sequence: Int
    var messageIndex: Int
    var utf16Location: Int
    var utf16Length: Int
    var role: String
    var timestamp: Date?

    init(
        sequence: Int,
        messageIndex: Int,
        utf16Location: Int,
        utf16Length: Int,
        role: String,
        timestamp: Date? = nil
    ) {
        self.sequence = sequence
        self.messageIndex = messageIndex
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.role = role
        self.timestamp = timestamp
    }
}

/// One searchable transcript. A session has a `main` document and may have subagent documents.
struct ConversationIndexDocument: Codable, Equatable, Sendable {
    static let mainTranscriptID = "main"

    var transcriptID: String
    var agentType: String?
    var sortOrder: Int
    var text: String
    var messageSpans: [ConversationIndexMessageSpan]

    /// Compatibility with the existing history search vocabulary.
    var agent: String { transcriptID }

    init(
        transcriptID: String,
        agentType: String? = nil,
        sortOrder: Int,
        text: String,
        messageSpans: [ConversationIndexMessageSpan] = []
    ) {
        self.transcriptID = transcriptID
        self.agentType = agentType
        self.sortOrder = sortOrder
        self.text = text
        self.messageSpans = messageSpans
    }
}

/// Complete input for one atomic index replacement. Raw producer files remain authoritative.
struct ConversationIndexedSession: Equatable, Sendable {
    var metadata: HistorySessionMetadata
    var scope: String
    var fingerprint: ConversationIndexFingerprint
    var documents: [ConversationIndexDocument]

    init(
        metadata: HistorySessionMetadata,
        scope: String? = nil,
        fingerprint: ConversationIndexFingerprint,
        documents: [ConversationIndexDocument]
    ) {
        self.metadata = metadata
        self.scope = scope ?? metadata.dirID
        self.fingerprint = fingerprint
        self.documents = documents
    }

    init(
        projection: HistoryCatalogProjection,
        scope: String? = nil,
        fingerprint: ConversationIndexFingerprint
    ) {
        self.init(
            metadata: projection.metadata,
            scope: scope,
            fingerprint: fingerprint,
            documents: projection.threads.map { thread in
                ConversationIndexDocument(
                    transcriptID: thread.transcriptID,
                    agentType: thread.agentType,
                    sortOrder: thread.sortOrder,
                    text: thread.searchText,
                    messageSpans: thread.messageSpans.map { span in
                        ConversationIndexMessageSpan(
                            sequence: span.sequence,
                            messageIndex: span.messageIndex,
                            utf16Location: span.utf16Location,
                            utf16Length: span.utf16Length,
                            role: span.role,
                            timestamp: span.timestamp
                        )
                    }
                )
            }
        )
    }
}

/// A catalog row without its potentially large searchable documents.
struct ConversationIndexEntry: Equatable, Sendable {
    var sourcePath: String
    var metadata: HistorySessionMetadata
    var scope: String
    var fingerprint: ConversationIndexFingerprint
    var indexedAt: Date
}

struct ConversationIndexScopeSummary: Equatable, Sendable {
    var scope: String
    var sessionCount: Int
    var lastActivity: Date
}

/// Compatibility result for detail/non-hot callers. Search uses block references and performs
/// exact Foundation-compatible verification before publishing a match.
struct ConversationIndexDocumentCandidate: Equatable, Sendable {
    var entry: ConversationIndexEntry
    var document: ConversationIndexDocument
}

struct ConversationIndexCandidateBatch: Equatable, Sendable {
    var documents: [ConversationIndexDocumentCandidate]
    var usedFallback: Bool
}

/// A search candidate identified without reading the transcript it points at.
///
/// Logical transcript identity plus selected physical blocks. Candidate generation selects no
/// text: only independently compressed blocks needed by exact refinement are decoded afterwards.
struct ConversationIndexDocumentReference: Equatable, Sendable {
    var documentID: Int64
    var sessionPath: String
    var transcriptID: String
    var agentType: String?
    var sortOrder: Int
    var lastActivity: Date
    /// nil means scan every bounded block (short-query, unavailable engine, or migration).
    var candidateChunkIDs: [Int64]? = nil
    var catalogGeneration: Int64? = nil
}

struct ConversationIndexCandidateReferenceBatch: Equatable, Sendable {
    var references: [ConversationIndexDocumentReference]
    var usedFallback: Bool
}

/// A cache validation and its optional document are read from one SQLite snapshot.
enum ConversationIndexRefinementRead: Sendable {
    case unchanged(generation: Int64)
    case document(generation: Int64, ConversationIndexDocument)
}

struct ConversationIndexReconciliation: Equatable, Sendable {
    var removedPaths: [String]
    var generation: Int64
}

enum ConversationIndexDatabaseError: LocalizedError, Sendable {
    case staleRevision
    case invalidDatabaseURL(URL)
    case unsafeDatabaseFile(URL)
    case invalidRecord(String)
    case unsafeEmptyReconciliation(String)
    case sqlite(operation: String, code: Int32, detail: String)
    case corruptRow(String)

    var errorDescription: String? {
        switch self {
        case .staleRevision:
            return "Conversation index changed during search; retry the query."
        case .invalidDatabaseURL(let url):
            return "Conversation index is not a local file URL: \(url.absoluteString)"
        case .unsafeDatabaseFile(let url):
            return "Conversation index is not an ordinary private file: \(url.path)"
        case .invalidRecord(let detail):
            return "Invalid conversation index record: \(detail)"
        case .unsafeEmptyReconciliation(let scope):
            return "Refusing an empty conversation-index reconciliation for scope \(scope)"
        case .sqlite(let operation, let code, let detail):
            return "Conversation index \(operation) failed (SQLite \(code)): \(detail)"
        case .corruptRow(let detail):
            return "Conversation index contains an invalid row: \(detail)"
        }
    }
}

/// App-owned, rebuildable SQLite catalog for conversation list and search data.
///
/// The class intentionally exposes synchronous methods: the current history provider is invoked
/// from detached tasks. Wake's split-connection model is preserved here: one lock/connection owns
/// mutations while an independent query-only connection keeps list/detail reads responsive during
/// indexing. WAL provides the snapshot boundary between them.
final class ConversationIndexDatabase: @unchecked Sendable {
    /// Version 5 preserves metadata and migrates legacy whole-transcript text to independently
    /// compressed blocks. tgrep is the sole postings index; obsolete FTS is retired off-thread.
    static let schemaVersion: Int32 = 5

    let file: URL
    let searchRefinementCache: ConversationSearchRefinementCache

    private let lock = NSLock()
    private let readLock = NSLock()
    private let maintenanceStateLock = NSLock()
    private let connection: OpaquePointer
    private var readConnection: OpaquePointer?
    private var maintenanceToken: UUID?
    private var maintenanceActivityEpoch: UInt64 = 0
    private let metadataEncoder: JSONEncoder
    private let metadataDecoder: JSONDecoder
    private let enableTgrep: Bool
    private var tgrep: TgrepSearchIndex?
    private let tgrepRuntime: TgrepRuntime
    private var tgrepFailure: TgrepSearchIndex.Failure?
    private var tgrepRetryAfter: Date?
    private let diagnosticsLock = NSLock()
    private var storedSearchDiagnostics = ConversationSearchDiagnostics()
    private var latestSearchDiagnostics: ConversationSearchDiagnostics {
        get {
            diagnosticsLock.lock()
            defer { diagnosticsLock.unlock() }
            return storedSearchDiagnostics
        }
        set {
            diagnosticsLock.lock()
            defer { diagnosticsLock.unlock() }
            storedSearchDiagnostics = newValue
        }
    }

    /// Injectable resource/clock boundaries keep recovery tests deterministic. A short
    /// wall-clock cooldown retries even when no catalog revision changes after disk recovery.
    struct TgrepRuntime {
        var now: () -> Date = { Date() }
        var availableCapacity: (URL) -> Int64? = { directory in
            (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity.map(Int64.init)
        }
        var makeIndex: (URL) throws -> TgrepSearchIndex = { try TgrepSearchIndex(cacheDirectory: $0) }
        var retryInterval: TimeInterval = 30
    }

    /// Decoded metadata keyed by row identity. Every list refresh — and the scope counts beside
    /// it — decodes the metadata blob of every session row; while an agent is appending, those
    /// refreshes arrive continuously and only the live session's row has actually changed. A row
    /// is rewritten exclusively through the upsert in `replace`/`replaceMetadata`, which always
    /// stamps a fresh `indexed_at`, so (path, indexed_at) proves the cached decode is current.
    private let metadataDecodeCacheLock = NSLock()
    private var metadataDecodeCache: [String: (indexedAt: Double, metadata: HistorySessionMetadata)] = [:]
    private static let metadataDecodeCacheLimit = 20_000
    private let legacyHeaderCacheLock = NSLock()
    /// Legacy bodies/spans are immutable until removed; new writes are always storage_version=1.
    /// Retain at most one modest header, never transcript text or an unbounded collection.
    private var legacyHeaderCache: (id: Int64, header: LegacyHeader)?

    init(file: URL, enableTgrep: Bool = true, tgrepRuntime: TgrepRuntime = .init(),
         searchRefinementCache: ConversationSearchRefinementCache = .init()) throws {
        guard file.isFileURL else {
            throw ConversationIndexDatabaseError.invalidDatabaseURL(file)
        }
        let standardized = file.standardizedFileURL
        try Self.prepareLocation(standardized)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(standardized.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.flatMap(sqlite3_errmsg).map(String.init(cString:))
                ?? "unable to open database"
            if let handle { sqlite3_close(handle) }
            throw ConversationIndexDatabaseError.sqlite(
                operation: "open",
                code: status,
                detail: detail
            )
        }

        self.file = standardized
        self.searchRefinementCache = searchRefinementCache
        self.enableTgrep = enableTgrep
        self.tgrepRuntime = tgrepRuntime
        connection = handle
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        metadataEncoder = encoder
        metadataDecoder = JSONDecoder()

        do {
            try configureConnection()
            try initializeSchema()
            readConnection = try Self.openReadConnection(standardized)
            try hardenPermissions()
        } catch {
            if let readConnection { sqlite3_close(readConnection) }
            sqlite3_close(handle)
            throw error
        }
    }

    convenience init(url: URL) throws {
        try self.init(file: url)
    }

    deinit {
        cancelDeferredMaintenance()
        if let readConnection { sqlite3_close_v2(readConnection) }
        sqlite3_close_v2(connection)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func normalizedPath(_ file: URL) -> String {
        normalizedPath(file.path)
    }

    var supportsTrigramSearch: Bool {
        enableTgrep && TgrepSearchIndex.isAvailable
    }

    var searchDiagnostics: ConversationSearchDiagnostics {
        latestSearchDiagnostics
    }

    func generation() throws -> Int64 {
        try withReadLock { connection in
            try int64Value(
                "SELECT generation FROM conversation_catalog_state WHERE singleton = 1",
                connection: connection
            )
        }
    }

    func hasRows() throws -> Bool {
        try withReadLock { connection in
            try int64Value(
                "SELECT EXISTS(SELECT 1 FROM conversation_sessions LIMIT 1)",
                connection: connection
            ) != 0
        }
    }

    /// Atomically replaces metadata, fingerprint, and every main/subagent search document.
    @discardableResult
    func replace(_ session: ConversationIndexedSession) throws -> Int64 {
        try withLock {
            try validate(session)
            let path = Self.normalizedPath(session.metadata.file)
            let metadata = try metadataEncoder.encode(session.metadata)
            let fileSize = try sqliteInteger(session.fingerprint.sizeBytes, field: "file size")
            let indexedAt = Date()
            let result = try transaction {
                try execute(
                    """
                    INSERT INTO conversation_sessions (
                        source_path, scope, source, created_at, last_activity,
                        file_mtime, file_size, dependency_fingerprint,
                        metadata_json, indexed_at, deleted, imported
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_path) DO UPDATE SET
                        scope = excluded.scope,
                        source = excluded.source,
                        created_at = excluded.created_at,
                        last_activity = excluded.last_activity,
                        file_mtime = excluded.file_mtime,
                        file_size = excluded.file_size,
                        dependency_fingerprint = excluded.dependency_fingerprint,
                        metadata_json = excluded.metadata_json,
                        indexed_at = excluded.indexed_at,
                        deleted = excluded.deleted,
                        imported = excluded.imported
                    """,
                    bindings: [
                        .text(path),
                        .text(session.scope),
                        .text(session.metadata.source.rawValue),
                        .double(session.metadata.createdAt.timeIntervalSince1970),
                        .double(session.metadata.lastActivity.timeIntervalSince1970),
                        .double(session.fingerprint.modificationTime.timeIntervalSince1970),
                        .integer(fileSize),
                        session.fingerprint.dependencyFingerprint.map(SQLiteValue.text) ?? .null,
                        .blob(metadata),
                        .double(indexedAt.timeIntervalSince1970),
                        .integer(session.metadata.deleted ? 1 : 0),
                        .integer(session.metadata.imported ? 1 : 0),
                    ]
                )

                try removeDocuments(for: path)
                for document in session.documents.sorted(by: Self.documentComesFirst) {
                    try execute(
                        """
                        INSERT INTO conversation_documents (
                            session_path, transcript_id, agent_type, sort_order, storage_version
                        ) VALUES (?, ?, ?, ?, 1)
                        """,
                        bindings: [
                            .text(path),
                            .text(document.transcriptID),
                            document.agentType.map(SQLiteValue.text) ?? .null,
                            .integer(Int64(document.sortOrder)),
                        ]
                    )
                    let documentID = sqlite3_last_insert_rowid(connection)
                    var ordinal = 0
                    try ConversationSearchChunk.forEachPart(of: document.text) { part in
                        try Task.checkCancellation()
                        try insertChunk(documentID: documentID, ordinal: ordinal, part: part,
                            spans: document.messageSpans)
                        ordinal += 1
                    }
                }
                try markMaintenancePending()
                return try advanceGeneration()
            }
            try hardenPermissions()
            return result
        }
    }

    /// Publishes Wake-style quick metadata in one transaction while retaining any previously
    /// indexed documents. Callers deliberately supply a sentinel fingerprint so the subsequent
    /// full parse is never mistaken for an unchanged session; a failed parse therefore leaves a
    /// visible, retryable row instead of an empty list.
    @discardableResult
    func replaceMetadata(_ sessions: [ConversationIndexedSession]) throws -> Int64 {
        try withLock {
            var unique: [String: ConversationIndexedSession] = [:]
            for session in sessions {
                try validate(session)
                unique[Self.normalizedPath(session.metadata.file)] = session
            }
            guard !unique.isEmpty else { return try currentGeneration() }

            let indexedAt = Date()
            let generation = try transaction {
                for (path, session) in unique.sorted(by: { $0.key < $1.key }) {
                    let metadata = try metadataEncoder.encode(session.metadata)
                    let fileSize = try sqliteInteger(
                        session.fingerprint.sizeBytes,
                        field: "file size"
                    )
                    try execute(
                        """
                        INSERT INTO conversation_sessions (
                            source_path, scope, source, created_at, last_activity,
                            file_mtime, file_size, dependency_fingerprint,
                            metadata_json, indexed_at, deleted, imported
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(source_path) DO UPDATE SET
                            scope = excluded.scope,
                            source = excluded.source,
                            created_at = excluded.created_at,
                            last_activity = excluded.last_activity,
                            file_mtime = excluded.file_mtime,
                            file_size = excluded.file_size,
                            dependency_fingerprint = excluded.dependency_fingerprint,
                            metadata_json = excluded.metadata_json,
                            indexed_at = excluded.indexed_at,
                            deleted = excluded.deleted,
                            imported = excluded.imported
                        """,
                        bindings: [
                            .text(path),
                            .text(session.scope),
                            .text(session.metadata.source.rawValue),
                            .double(session.metadata.createdAt.timeIntervalSince1970),
                            .double(session.metadata.lastActivity.timeIntervalSince1970),
                            .double(session.fingerprint.modificationTime.timeIntervalSince1970),
                            .integer(fileSize),
                            session.fingerprint.dependencyFingerprint.map(SQLiteValue.text) ?? .null,
                            .blob(metadata),
                            .double(indexedAt.timeIntervalSince1970),
                            .integer(session.metadata.deleted ? 1 : 0),
                            .integer(session.metadata.imported ? 1 : 0),
                        ]
                    )
                }
                return try advanceGeneration()
            }
            try hardenPermissions()
            return generation
        }
    }

    /// Removes all rows for the supplied physical source paths in one transaction.
    @discardableResult
    func remove(paths: [String]) throws -> Int {
        try withLock {
            let paths = Array(Set(paths.map { Self.normalizedPath($0) })).sorted()
            guard !paths.isEmpty else { return 0 }
            let removed = try transaction {
                var removed = 0
                for path in paths {
                    try removeDocuments(for: path)
                    try execute(
                        "DELETE FROM conversation_sessions WHERE source_path = ?",
                        bindings: [.text(path)]
                    )
                    removed += Int(sqlite3_changes(connection))
                }
                if removed > 0 {
                    try markMaintenancePending()
                    _ = try advanceGeneration()
                }
                return removed
            }
            try hardenPermissions()
            return removed
        }
    }

    @discardableResult
    func remove(files: [URL]) throws -> Int {
        try remove(paths: files.map { Self.normalizedPath($0) })
    }

    /// Removes indexed rows in one directory scope which were absent from a completed discovery.
    /// Empty discoveries require an explicit opt-in so a transient filesystem failure cannot purge
    /// a valid warm index.
    @discardableResult
    func reconcile(
        scope: String,
        seenPaths: Set<String>,
        allowEmpty: Bool = false
    ) throws -> ConversationIndexReconciliation {
        try withLock {
            let normalized = Set(seenPaths.map { Self.normalizedPath($0) })
            guard allowEmpty || !normalized.isEmpty else {
                throw ConversationIndexDatabaseError.unsafeEmptyReconciliation(scope)
            }
            let indexed = try stringValues(
                "SELECT source_path FROM conversation_sessions WHERE scope = ?",
                bindings: [.text(scope)]
            )
            let removedPaths = indexed.filter { !normalized.contains($0) }.sorted()
            guard !removedPaths.isEmpty else {
                return ConversationIndexReconciliation(
                    removedPaths: [],
                    generation: try currentGeneration()
                )
            }

            let nextGeneration = try transaction {
                for path in removedPaths {
                    try removeDocuments(for: path)
                    try execute(
                        "DELETE FROM conversation_sessions WHERE source_path = ? AND scope = ?",
                        bindings: [.text(path), .text(scope)]
                    )
                }
                try markMaintenancePending()
                return try advanceGeneration()
            }
            try hardenPermissions()
            return ConversationIndexReconciliation(
                removedPaths: removedPaths,
                generation: nextGeneration
            )
        }
    }

    func storedFingerprints(scope: String? = nil) throws -> [String: ConversationIndexFingerprint] {
        try withReadLock { connection in
            var sql = """
                SELECT source_path, file_mtime, file_size, dependency_fingerprint
                FROM conversation_sessions
                """
            var bindings: [SQLiteValue] = []
            if let scope {
                sql += " WHERE scope = ?"
                bindings.append(.text(scope))
            }
            sql += " ORDER BY source_path"

            let statement = try prepare(sql, bindings: bindings, connection: connection)
            defer { sqlite3_finalize(statement) }
            var result: [String: ConversationIndexFingerprint] = [:]
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read fingerprints", status, connection: connection)
                }
                guard let path = try? textColumn(statement, 0, field: "source_path") else {
                    continue
                }
                let size = sqlite3_column_int64(statement, 2)
                guard size >= 0 else { continue }
                result[path] = ConversationIndexFingerprint(
                    modificationTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    sizeBytes: UInt64(size),
                    dependencyFingerprint: optionalTextColumn(statement, 3)
                )
            }
        }
    }

    func entry(for file: URL) throws -> ConversationIndexEntry? {
        try entry(forPath: Self.normalizedPath(file))
    }

    func entry(forPath path: String) throws -> ConversationIndexEntry? {
        try withReadLock { connection in
            let sql = Self.entrySelect + " WHERE source_path = ? LIMIT 1"
            let statement = try prepare(
                sql,
                bindings: [.text(Self.normalizedPath(path))],
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw sqliteError("read session", status, connection: connection)
            }
            do {
                return try decodeEntry(statement, offset: 0)
            } catch ConversationIndexDatabaseError.corruptRow(_) {
                return nil
            }
        }
    }

    func loadAllMetadata() throws -> [HistorySessionMetadata] {
        try listEntries(deleted: nil, limit: .max).map(\.metadata)
    }

    func listEntries(
        scope: String? = nil,
        source: HistorySource? = nil,
        deleted: Bool? = false,
        limit: Int = 400,
        offset: Int = 0
    ) throws -> [ConversationIndexEntry] {
        try withReadLock { connection in
            guard limit > 0, offset >= 0 else { return [] }
            var conditions: [String] = []
            var bindings: [SQLiteValue] = []
            if let scope {
                conditions.append("scope = ?")
                bindings.append(.text(scope))
            }
            if let source {
                conditions.append("source = ?")
                bindings.append(.text(source.rawValue))
            }
            if let deleted {
                conditions.append("deleted = ?")
                bindings.append(.integer(deleted ? 1 : 0))
            }
            var sql = Self.entrySelect
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY last_activity DESC, created_at DESC, source_path DESC"
            return try queryEntries(
                sql,
                bindings: bindings,
                connection: connection,
                validLimit: limit,
                validOffset: offset
            )
        }
    }

    func scopeSummaries(deleted: Bool? = false) throws -> [ConversationIndexScopeSummary] {
        try withReadLock { connection in
            var sql = """
                SELECT scope, COUNT(*), MAX(last_activity)
                FROM conversation_sessions
                """
            var bindings: [SQLiteValue] = []
            if let deleted {
                sql += " WHERE deleted = ?"
                bindings.append(.integer(deleted ? 1 : 0))
            }
            sql += " GROUP BY scope ORDER BY MAX(last_activity) DESC, scope"
            let statement = try prepare(sql, bindings: bindings, connection: connection)
            defer { sqlite3_finalize(statement) }
            var result: [ConversationIndexScopeSummary] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read scope summaries", status, connection: connection)
                }
                guard let scope = try? textColumn(statement, 0, field: "scope") else { continue }
                result.append(ConversationIndexScopeSummary(
                    scope: scope,
                    sessionCount: Int(sqlite3_column_int64(statement, 1)),
                    lastActivity: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ))
            }
        }
    }

    func documents(for file: URL) throws -> [ConversationIndexDocument] {
        try documents(forPath: Self.normalizedPath(file))
    }

    /// Reads one transcript located by `candidateDocumentReferences`. Search calls this per
    /// candidate and releases the result before moving on, so a query costs one transcript rather
    /// than every transcript that matched.
    func document(
        id: Int64,
        expectedSessionPath: String? = nil,
        expectedTranscriptID: String? = nil
    ) throws -> ConversationIndexDocument? {
        try withReadLock { connection in
            var predicate = " WHERE d.id = ?"
            var bindings: [SQLiteValue] = [.integer(id)]
            if let expectedSessionPath {
                predicate += " AND d.session_path = ?"
                bindings.append(.text(expectedSessionPath))
            }
            if let expectedTranscriptID {
                predicate += " AND d.transcript_id = ?"
                bindings.append(.text(expectedTranscriptID))
            }
            let statement = try prepare(
                Self.documentSelect + predicate + " LIMIT 1",
                bindings: bindings,
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw sqliteError("read document", status, connection: connection)
            }
            do {
                return try decodeDocument(statement, offset: 0, connection: connection)
            } catch ConversationIndexDatabaseError.corruptRow(_) {
                return nil
            }
        }
    }

    /// A warm exact-result cache needs only the catalog generation and row identity. On a miss,
    /// decode the document in that same short read transaction; a writer must never let new text
    /// be cached under an older generation. Matching and all progress callbacks happen afterwards.
    /// The conservative generation deliberately invalidates metadata-only/live catalog revisions
    /// too. Wall-clock content stamps alone cannot prove identity after row-ID reuse.
    func refinementDocument(
        reference: ConversationIndexDocumentReference,
        cachedGeneration: Int64?
    ) throws -> ConversationIndexRefinementRead? {
        try withReadLock { connection in
            let begin = sqlite3_exec(connection, "BEGIN DEFERRED", nil, nil, nil)
            guard begin == SQLITE_OK else {
                throw sqliteError("begin refinement snapshot", begin, connection: connection)
            }
            defer { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
            let bindings: [SQLiteValue] = [.integer(reference.documentID),
                .text(reference.sessionPath), .text(reference.transcriptID)]
            let predicate = " WHERE d.id = ? AND d.session_path = ? AND d.transcript_id = ? LIMIT 1"
            let identity = try prepare(
                "SELECT c.generation FROM conversation_documents d "
                    + "CROSS JOIN conversation_catalog_state c"
                    + " WHERE c.singleton = 1 AND d.id = ? AND d.session_path = ? AND d.transcript_id = ? LIMIT 1",
                bindings: bindings, connection: connection
            )
            defer { sqlite3_finalize(identity) }
            let identityStatus = sqlite3_step(identity)
            if identityStatus == SQLITE_DONE { return nil }
            guard identityStatus == SQLITE_ROW else {
                throw sqliteError("read refinement identity", identityStatus, connection: connection)
            }
            let generation = sqlite3_column_int64(identity, 0)
            if cachedGeneration == generation { return .unchanged(generation: generation) }
            try Task.checkCancellation()
            let statement = try prepare(Self.documentSelect + predicate,
                bindings: bindings, connection: connection)
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw sqliteError("read refinement document", status, connection: connection)
            }
            do {
                return .document(generation: generation, try decodeDocument(statement, offset: 0, connection: connection))
            } catch ConversationIndexDatabaseError.corruptRow(_) {
                return nil
            }
        }
    }

    func documents(forPath path: String) throws -> [ConversationIndexDocument] {
        try withReadLock { connection in
            let statement = try prepare(
                Self.documentSelect
                    + " WHERE d.session_path = ? ORDER BY d.sort_order, d.transcript_id",
                bindings: [.text(Self.normalizedPath(path))],
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            var result: [ConversationIndexDocument] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read documents", status, connection: connection)
                }
                do {
                    result.append(try decodeDocument(statement, offset: 0, connection: connection))
                } catch ConversationIndexDatabaseError.corruptRow(_) {
                    continue
                }
            }
        }
    }

    /// Validates a cached refinement without touching compressed text.
    func refinementGeneration(reference: ConversationIndexDocumentReference) throws -> Int64? {
        try withReadLock { connection in
            let statement = try prepare("""
                SELECT s.generation FROM conversation_documents d CROSS JOIN conversation_catalog_state s
                WHERE s.singleton = 1 AND d.id = ? AND d.session_path = ? AND d.transcript_id = ?
                """, bindings: [.integer(reference.documentID), .text(reference.sessionPath),
                    .text(reference.transcriptID)], connection: connection)
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw sqliteError("refinement generation", status, connection: connection)
            }
            let generation = sqlite3_column_int64(statement, 0)
            if let expected = reference.catalogGeneration, expected != generation {
                throw ConversationIndexDatabaseError.staleRevision
            }
            return generation
        }
    }

    /// A batch is one SQLite snapshot. Neither candidates nor a cursor may silently cross a
    /// writer revision; the repository can restart instead of publishing mixed-version counts.
    func searchChunkWindows(
        reference: ConversationIndexDocumentReference, query: String,
        cursor: ConversationIndexSearchCursor? = nil, limit: Int = 1
    ) throws -> ConversationIndexSearchWindowBatch {
        try withReadLock { connection in
            try Task.checkCancellation()
            guard sqlite3_exec(connection, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("begin chunk snapshot", sqlite3_errcode(connection), connection: connection)
            }
            defer { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
            let generation = try int64Value(
                "SELECT generation FROM conversation_catalog_state WHERE singleton = 1", connection: connection)
            for expected in [reference.catalogGeneration, cursor?.generation].compactMap({ $0 }) {
                guard expected == generation else { throw ConversationIndexDatabaseError.staleRevision }
            }
            let identity = try prepare("""
                SELECT storage_version FROM conversation_documents
                WHERE id = ? AND session_path = ? AND transcript_id = ?
                """, bindings: [.integer(reference.documentID), .text(reference.sessionPath),
                    .text(reference.transcriptID)], connection: connection)
            defer { sqlite3_finalize(identity) }
            let status = sqlite3_step(identity)
            if status == SQLITE_DONE {
                return ConversationIndexSearchWindowBatch(windows: [], nextCursor: nil, generation: generation)
            }
            guard status == SQLITE_ROW else {
                throw sqliteError("chunk identity", status, connection: connection)
            }
            var position = cursor ?? ConversationIndexSearchCursor()
            position.generation = generation
            let lookahead = ConversationSearchChunk.lookaheadCharacters(for: query)
            var windows: [ConversationIndexSearchWindow] = []
            if sqlite3_column_int(identity, 0) == 0 {
                let header = try legacyHeader(documentID: reference.documentID, connection: connection)
                while position.legacyByteOffset < header.bytes, windows.count < max(1, limit) {
                    try Task.checkCancellation()
                    let owned = try legacyPart(documentID: reference.documentID,
                        byteOffset: position.legacyByteOffset, totalBytes: header.bytes, connection: connection)
                    var text = owned
                    var suffixOffset = position.legacyByteOffset + owned.utf8.count
                    var remaining = lookahead
                    while remaining > 0, suffixOffset < header.bytes {
                        try Task.checkCancellation()
                        let suffix = try legacyPart(documentID: reference.documentID,
                            byteOffset: suffixOffset, totalBytes: header.bytes, connection: connection)
                        let prefix = suffix.prefix(remaining)
                        text.append(contentsOf: prefix)
                        remaining -= prefix.count
                        suffixOffset += suffix.utf8.count
                    }
                    windows.append(ConversationIndexSearchWindow(
                        chunkID: -Int64(position.nextOrdinal + 1), text: text,
                        globalUTF16Start: position.legacyUTF16Offset, ownedUTF16Length: owned.utf16.count,
                        messageSpans: ConversationSearchChunk.spans(header.spans,
                            location: position.legacyUTF16Offset, length: text.utf16.count), generation: generation))
                    position.nextOrdinal += 1
                    position.legacyByteOffset += owned.utf8.count
                    position.legacyUTF16Offset += owned.utf16.count
                }
                return ConversationIndexSearchWindowBatch(windows: windows,
                    nextCursor: position.legacyByteOffset < header.bytes ? position : nil, generation: generation)
            }
            let selected = reference.candidateChunkIDs.map(Set.init)
            let statement = try prepare("""
                SELECT id, ordinal FROM conversation_search_chunks
                WHERE document_id = ? AND ordinal >= ? ORDER BY ordinal
                """, bindings: [.integer(reference.documentID), .integer(Int64(position.nextOrdinal))],
                connection: connection)
            defer { sqlite3_finalize(statement) }
            var hasNext = false
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw sqliteError("chunk page", status, connection: connection)
                }
                let id = sqlite3_column_int64(statement, 0)
                let ordinal = Int(sqlite3_column_int64(statement, 1))
                if let selected, !selected.contains(id) { continue }
                if windows.count == max(1, limit) { hasNext = true; break }
                guard let window = try readStoredWindow(documentID: reference.documentID,
                    ordinal: ordinal, lookahead: lookahead, generation: generation,
                    connection: connection) else { continue }
                windows.append(window)
                position.nextOrdinal = ordinal + 1
            }
            return ConversationIndexSearchWindowBatch(windows: windows,
                nextCursor: hasNext ? position : nil, generation: generation)
        }
    }

    /// Only the first hit asks for surrounding text. Normal candidate pages never decode a
    /// preceding block just to build a snippet that may not be displayed.
    func searchChunkSnippet(reference: ConversationIndexDocumentReference, offsetUTF16: Int,
                            matchLengthUTF16: Int, context: Int = 56) throws -> String? {
        try withReadLock { connection in
            guard offsetUTF16 >= 0, matchLengthUTF16 > 0 else { return nil }
            guard sqlite3_exec(connection, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
                throw sqliteError("begin snippet snapshot", sqlite3_errcode(connection), connection: connection)
            }
            defer { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
            let generation = try int64Value(
                "SELECT generation FROM conversation_catalog_state WHERE singleton = 1", connection: connection)
            if let expected = reference.catalogGeneration, expected != generation {
                throw ConversationIndexDatabaseError.staleRevision
            }
            let identity = try prepare("""
                SELECT storage_version FROM conversation_documents
                WHERE id = ? AND session_path = ? AND transcript_id = ?
                """, bindings: [.integer(reference.documentID), .text(reference.sessionPath),
                    .text(reference.transcriptID)], connection: connection)
            defer { sqlite3_finalize(identity) }
            guard sqlite3_step(identity) == SQLITE_ROW else { return nil }
            var text = ""
            var globalStart = 0
            var hasMoreAfter = false
            let radius = max(0, context)
            if sqlite3_column_int(identity, 0) == 0 {
                let header = try legacyHeader(documentID: reference.documentID, connection: connection)
                var byteOffset = 0
                var utf16Offset = 0
                var tail = ""
                while byteOffset < header.bytes {
                    try Task.checkCancellation()
                    let part = try legacyPart(documentID: reference.documentID, byteOffset: byteOffset,
                        totalBytes: header.bytes, connection: connection)
                    byteOffset += part.utf8.count
                    if text.isEmpty, utf16Offset + part.utf16.count <= offsetUTF16 {
                        tail = String((tail + part).suffix(radius + 1))
                        utf16Offset += part.utf16.count
                        continue
                    }
                    if text.isEmpty {
                        globalStart = utf16Offset - tail.utf16.count
                        text = tail
                    }
                    text.append(part)
                    let matchEnd = offsetUTF16 - globalStart + matchLengthUTF16
                    if text.utf16.count >= matchEnd {
                        let end = String.Index(utf16Offset: matchEnd, in: text)
                        if text[end...].count > radius || byteOffset == header.bytes {
                            hasMoreAfter = byteOffset < header.bytes
                            break
                        }
                    }
                    utf16Offset += part.utf16.count
                }
            } else {
                let ordinal = try int64Value("""
                    SELECT COALESCE(MAX(ordinal), 0) FROM conversation_search_chunks
                    WHERE document_id = ? AND utf16_location <= ?
                    """, bindings: [.integer(reference.documentID), .integer(Int64(offsetUTF16))],
                    connection: connection)
                guard let current = try readStoredWindow(documentID: reference.documentID,
                    ordinal: Int(ordinal), lookahead: 0, generation: generation,
                    connection: connection) else { return nil }
                text = current.text
                globalStart = current.globalUTF16Start
                var previous = Int(ordinal) - 1
                while previous >= 0 {
                    let start = String.Index(utf16Offset: offsetUTF16 - globalStart, in: text)
                    if text[..<start].count > radius { break }
                    guard let part = try readStoredWindow(documentID: reference.documentID,
                        ordinal: previous, lookahead: 0, generation: generation,
                        connection: connection) else { break }
                    let suffix = String(part.text.suffix(radius + 1))
                    text = suffix + text
                    globalStart -= suffix.utf16.count
                    if suffix.utf16.count < part.ownedUTF16Length { break }
                    previous -= 1
                }
                var next = Int(ordinal) + 1
                while true {
                    let matchEnd = offsetUTF16 - globalStart + matchLengthUTF16
                    if text.utf16.count >= matchEnd {
                        let end = String.Index(utf16Offset: matchEnd, in: text)
                        if text[end...].count > radius { hasMoreAfter = true; break }
                    }
                    guard let part = try readStoredWindow(documentID: reference.documentID,
                        ordinal: next, lookahead: 0, generation: generation,
                        connection: connection) else { break }
                    text.append(part.text)
                    next += 1
                }
            }
            let localStart = offsetUTF16 - globalStart
            guard localStart >= 0, localStart + matchLengthUTF16 <= text.utf16.count else { return nil }
            let lower = String.Index(utf16Offset: localStart, in: text)
            let upper = String.Index(utf16Offset: localStart + matchLengthUTF16, in: text)
            let start = text.index(lower, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(upper, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
            let body = text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return (globalStart > 0 || start > text.startIndex ? "…" : "") + body
                + (hasMoreAfter || end < text.endIndex ? "…" : "")
        }
    }

    /// tgrep is the sole postings index. The exact fallback deliberately returns lightweight
    /// identities, not whole transcripts; callers verify only bounded, independently decoded blocks.
    func candidateDocumentReferences(
        for rawQuery: String,
        scope: String? = nil,
        source: HistorySource? = nil,
        deleted: Bool? = false
    ) throws -> ConversationIndexCandidateReferenceBatch {
        try withReadLock { connection in
            try Task.checkCancellation()
            let started = ContinuousClock.now
            defer {
                let elapsed = started.duration(to: .now).components
                latestSearchDiagnostics.queryMilliseconds = Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            }
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return ConversationIndexCandidateReferenceBatch(references: [], usedFallback: false)
            }
            guard sqlite3_exec(connection, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
                throw TgrepSearchIndex.Failure.operationFailed
            }
            defer { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
            let generation = try int64Value(
                "SELECT generation FROM conversation_catalog_state WHERE singleton = 1",
                connection: connection)
            let retryReady = tgrepRetryAfter.map { tgrepRuntime.now() >= $0 } ?? true
            if enableTgrep, retryReady, TgrepSearchIndex.canIndex(query) {
                do {
                    let updated = try synchronizeTgrep(connection: connection)
                    guard let tgrep else { throw TgrepSearchIndex.Failure.unavailable }
                    let ids = try tgrep.candidates(for: ConversationSearchChunk.candidatePrefix(query))
                    try Task.checkCancellation()
                    let references = try queryChunkCandidateReferences(scope: scope, source: source,
                        deleted: deleted, chunkIDs: ids, generation: generation, connection: connection)
                    latestSearchDiagnostics = ConversationSearchDiagnostics(
                        engine: "tgrep", indexedDocuments: tgrep.documentCount,
                        candidateCount: references.reduce(0) { $0 + ($1.candidateChunkIDs?.count ?? 1) },
                        incrementallyIndexedDocuments: updated, usedFallback: false,
                        cumulativeNormalizationMilliseconds: tgrep.normalizationMilliseconds,
                        cumulativeTrigramBuildMilliseconds: tgrep.trigramBuildMilliseconds,
                        restoredFromCache: tgrep.restoredFromCache)
                    tgrepFailure = nil
                    tgrepRetryAfter = nil
                    return ConversationIndexCandidateReferenceBatch(references: references, usedFallback: false)
                } catch is CancellationError {
                    tgrep = nil
                    throw CancellationError()
                } catch {
                    tgrep = nil
                    try Task.checkCancellation()
                    tgrepFailure = (error as? TgrepSearchIndex.Failure) ?? .operationFailed
                    tgrepRetryAfter = tgrepRuntime.now().addingTimeInterval(tgrepRuntime.retryInterval)
                }
            }
            let references = try queryChunkCandidateReferences(scope: scope, source: source,
                deleted: deleted, chunkIDs: nil, generation: generation, connection: connection)
            latestSearchDiagnostics = ConversationSearchDiagnostics(
                engine: "Literal", candidateCount: references.count, usedFallback: true,
                fallbackReason: tgrepFailure?.rawValue, tgrepRetryAfter: tgrepRetryAfter)
            return ConversationIndexCandidateReferenceBatch(references: references, usedFallback: true)
        }
    }

    /// Convenience over `candidateDocumentReferences` for callers which want whole documents in
    /// catalog order. Each transcript is read individually and a bad row is skipped without
    /// consuming the caller's budget, so `limit` still describes usable candidates.
    func candidateDocuments(
        for rawQuery: String,
        scope: String? = nil,
        source: HistorySource? = nil,
        deleted: Bool? = false,
        limit: Int? = nil
    ) throws -> ConversationIndexCandidateBatch {
        guard limit.map({ $0 > 0 }) ?? true else {
            return ConversationIndexCandidateBatch(documents: [], usedFallback: false)
        }
        let batch = try candidateDocumentReferences(
            for: rawQuery,
            scope: scope,
            source: source,
            deleted: deleted
        )
        var documents: [ConversationIndexDocumentCandidate] = []
        for reference in batch.references.sorted(by: Self.referenceComesFirst) {
            guard let entry = try entry(forPath: reference.sessionPath),
                  let document = try document(
                    id: reference.documentID,
                    expectedSessionPath: reference.sessionPath,
                    expectedTranscriptID: reference.transcriptID
                  ), ConversationLiteralSearch(query: rawQuery).firstMatch(in: document.text) != nil else { continue }
            documents.append(
                ConversationIndexDocumentCandidate(entry: entry, document: document)
            )
            if let limit, documents.count == limit { break }
        }
        return ConversationIndexCandidateBatch(
            documents: documents,
            usedFallback: batch.usedFallback
        )
    }

    /// Catalog order for search candidates, matching the ordering the query used to ask SQLite
    /// for: newest session first, then transcript order. The trailing path key only makes ties
    /// between distinct sessions deterministic; SQLite left that case unspecified.
    static func referenceComesFirst(
        _ lhs: ConversationIndexDocumentReference,
        _ rhs: ConversationIndexDocumentReference
    ) -> Bool {
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.transcriptID != rhs.transcriptID { return lhs.transcriptID < rhs.transcriptID }
        return lhs.sessionPath < rhs.sessionPath
    }

    /// Invalidates canonical list projection without touching transcript blocks.
    /// Codex's shared state database uses this when its preferred rollout mapping changes.
    @discardableResult
    func invalidateProjection() throws -> Int64 {
        try withLock {
            let generation = try transaction { try advanceGeneration() }
            try hardenPermissions()
            return generation
        }
    }

    /// Runs derived-index maintenance only after an idle delay. Passes are cancellable and avoid
    /// full VACUUM; pending bits make repeated unchanged scans no-ops, and maintenance never
    /// advances generation.
    func finishFullScanMaintenance(
        shouldYield: @escaping ConversationIndexScanCancellation = { false },
        isCancelled: @escaping ConversationIndexScanCancellation = { false }
    ) throws {
        try withLock {
            let cancellation = SQLiteCancellationContext(isCancelled: isCancelled)
            try cancellation.check()
            let maintenancePending = try int64Value(
                "SELECT maintenance_pending FROM conversation_catalog_state WHERE singleton = 1"
            ) != 0
            let oneTimeCompactionPending = try int64Value(
                "SELECT one_time_compaction_pending FROM conversation_catalog_state "
                    + "WHERE singleton = 1"
            ) != 0
            guard maintenancePending || oneTimeCompactionPending else { return }

            // Preserve useful progress before attempting a potentially long atomic DROP.
            // Activity yields only between committed blocks; lifecycle cancellation is separate.
            guard try migrateLegacyBlocks(cancellation: cancellation, shouldYield: shouldYield) else { return }
            // Retire the obsolete index off the main thread. DROP cannot commit piecemeal, so
            // activity does not repeatedly roll it back; only stop/lifecycle cancellation
            // interrupts it. The separate WAL reader remains available while writers queue.
            if try tableExists("conversation_documents_fts") {
                guard hasCapacityForMigration() else { return }
                try executeCancellableMaintenance("DROP TABLE conversation_documents_fts",
                    cancellation: cancellation)
                try cancellation.check()
                _ = try checkpointWALTruncating(cancellation: cancellation)
            }
            // VACUUM can temporarily need another database-sized copy. Migration itself only
            // needs bounded headroom, so low space never prevents already-free pages being reused.
            if oneTimeCompactionPending {
                // New catalogs are created with incremental auto-vacuum and reclaim pages on
                // every pass below. A catalog created before that, however, cannot be switched:
                // `PRAGMA auto_vacuum` is a documented no-op on an existing non-empty database,
                // which also makes `incremental_vacuum` inert there. The intended "transition to
                // bounded cleanup" therefore never happened on exactly the files it was written
                // for — a real catalog measured 2.4 GB of freelist inside a 3.8 GB file.
                //
                // VACUUM is the only operation that both rewrites the file and commits the new
                // mode. It is expensive, so it runs once, only when the waste is large enough to
                // be worth an exclusive writer, and only behind `hasCapacityForMaintenance()`,
                // which already reserves twice the file size for exactly this copy.
                try execute("PRAGMA auto_vacuum = INCREMENTAL")
                if try int64Value("PRAGMA auto_vacuum") == 0, try wastesEnoughToVacuum() {
                    guard hasCapacityForMaintenance() else { return }
                    try executeCancellableMaintenance("VACUUM", cancellation: cancellation)
                }
                try execute(
                    "UPDATE conversation_catalog_state SET one_time_compaction_pending = 0 "
                        + "WHERE singleton = 1"
                )
                try cancellation.check()
            }

            try executeCancellableMaintenance(
                "PRAGMA optimize",
                cancellation: cancellation
            )
            try cancellation.check()
            // Each micro-batch reaches SQLITE_DONE and commits before checking activity.
            // Repeated file events can therefore never roll back all reclamation progress.
            let reclaimStarted = ContinuousClock.now
            repeat {
                try executeCancellableMaintenance(
                    "PRAGMA incremental_vacuum(256)",
                    cancellation: cancellation
                )
                try cancellation.check()
                if shouldYield() { break }
            } while try int64Value("PRAGMA auto_vacuum") == 2
                && int64Value("PRAGMA freelist_count") > 0
                && reclaimStarted.duration(to: .now) < .milliseconds(250)
            try cancellation.check()
            guard try checkpointWALTruncating(cancellation: cancellation) else {
                try cancellation.check()
                return
            }

            // incremental_vacuum is a bounded pass, not proof that the freelist is empty.
            // Keep the durable retry bit until an incremental-mode catalog actually shrinks;
            // retiring a multi-GB old index must not stop after reclaiming its first micro-batch.
            if try int64Value("PRAGMA auto_vacuum") == 2,
               try int64Value("PRAGMA freelist_count") > 0 {
                return
            }

            try execute(
                "UPDATE conversation_catalog_state SET maintenance_pending = 0, "
                    + "one_time_compaction_pending = 0 WHERE singleton = 1"
            )
            do {
                guard try checkpointWALTruncating(cancellation: cancellation) else {
                    // An independent reader raced the final state write. Restore the retry
                    // marker; the next successful full scan can finish truncation.
                    try execute(
                        "UPDATE conversation_catalog_state SET maintenance_pending = 1, "
                            + "one_time_compaction_pending = 0 WHERE singleton = 1"
                    )
                    try cancellation.check()
                    return
                }
            } catch {
                // The completion marker itself may be in the WAL when truncation is cancelled
                // or fails. Restore the ordinary retry bit for every checkpoint error so a
                // transient I/O/locking failure cannot silently suppress future maintenance.
                let checkpointError = error
                try execute(
                    "UPDATE conversation_catalog_state SET maintenance_pending = 1, "
                        + "one_time_compaction_pending = 0 WHERE singleton = 1"
                )
                if checkpointError is CancellationError { throw CancellationError() }
                throw checkpointError
            }
            try hardenPermissions()
        }
    }

    private func hasCapacityForMigration() -> Bool {
        guard let available = tgrepRuntime.availableCapacity(file.deletingLastPathComponent()) else { return true }
        return available >= 16 * 1_024 * 1_024
    }

    func maintenanceIsPending() throws -> Bool {
        try withReadLock { connection in
            try int64Value("""
                SELECT maintenance_pending OR one_time_compaction_pending
                FROM conversation_catalog_state WHERE singleton = 1
                """, connection: connection) != 0
        }
    }

    /// A bounded pass commits progress per physical block. A cancellation never requires
    /// reprocessing a giant transcript and never deletes the only authoritative derived text.
    private func migrateLegacyBlocks(cancellation: SQLiteCancellationContext,
                                     shouldYield: ConversationIndexScanCancellation) throws -> Bool {
        guard try tableExists("conversation_documents_legacy") else { return true }
        guard hasCapacityForMigration() else { return false }
        let started = ContinuousClock.now
        var processed = 0
        while processed < 128, started.duration(to: .now) < .milliseconds(250) {
            try cancellation.check()
            let statement = try prepare("""
                SELECT id, migration_byte_offset, migration_utf16_offset, migration_ordinal
                FROM conversation_documents WHERE storage_version = 0 ORDER BY id LIMIT 1
                """, bindings: [])
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                sqlite3_finalize(statement)
                try executeCancellableMaintenance("DROP TABLE conversation_documents_legacy",
                    cancellation: cancellation)
                return true
            }
            guard status == SQLITE_ROW else {
                sqlite3_finalize(statement)
                throw sqliteError("migration identity", status)
            }
            let id = sqlite3_column_int64(statement, 0)
            let byteOffset = Int(sqlite3_column_int64(statement, 1))
            let utf16Offset = Int(sqlite3_column_int64(statement, 2))
            let ordinal = Int(sqlite3_column_int64(statement, 3))
            sqlite3_finalize(statement)
            let header = try legacyHeader(documentID: id, connection: connection)
            let text = try legacyPart(documentID: id, byteOffset: byteOffset,
                totalBytes: header.bytes, connection: connection)
            try cancellation.check()
            let nextByte = byteOffset + text.utf8.count
            let nextUTF16 = utf16Offset + text.utf16.count
            try migrationTransaction(cancellation: cancellation) {
                try cancellation.check()
                try insertChunk(documentID: id, ordinal: ordinal,
                    part: .init(text: text, utf16Location: utf16Offset, utf16Length: text.utf16.count),
                    spans: header.spans)
                if nextByte >= header.bytes {
                    try execute("UPDATE conversation_documents SET storage_version = 1 WHERE id = ?",
                        bindings: [.integer(id)])
                    try execute("DELETE FROM conversation_documents_legacy WHERE id = ?",
                        bindings: [.integer(id)])
                    try execute("UPDATE conversation_catalog_state SET storage_revision = storage_revision + 1 WHERE singleton = 1")
                } else {
                    try execute("""
                        UPDATE conversation_documents SET migration_byte_offset = ?,
                            migration_utf16_offset = ?, migration_ordinal = ? WHERE id = ?
                        """, bindings: [.integer(Int64(nextByte)), .integer(Int64(nextUTF16)),
                            .integer(Int64(ordinal + 1)), .integer(id)])
                }
                try cancellation.check()
            }
            processed += 1
            // Even an already-raised activity signal permits one bounded committed unit,
            // preventing a continuously active producer from starving physical conversion.
            if shouldYield() { return false }
            if processed % 16 == 0 {
                _ = try checkpointWALTruncating(cancellation: cancellation)
                guard hasCapacityForMigration() else { return false }
            }
        }
        return false
    }

    /// Schedules cache-only cleanup after an idle delay. Activity yields between committed units;
    /// lifecycle cancellation stops the pass. List/search reads use their own WAL connection.
    func scheduleDeferredMaintenance(after delay: TimeInterval = 8) {
        let token = UUID()
        maintenanceStateLock.lock()
        guard maintenanceToken == nil else { maintenanceStateLock.unlock(); return }
        maintenanceToken = token
        maintenanceStateLock.unlock()
        Self.deferredMaintenanceQueue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self, self.isMaintenanceCurrent(token) else { return }
            let activity = self.maintenanceActivitySnapshot()
            try? self.finishFullScanMaintenance(shouldYield: { [weak self] in
                self?.maintenanceActivitySnapshot() != activity
            }, isCancelled: { [weak self] in
                self?.isMaintenanceCurrent(token) != true
            })
            self.maintenanceStateLock.lock()
            let remainsCurrent = self.maintenanceToken == token
            if remainsCurrent { self.maintenanceToken = nil }
            self.maintenanceStateLock.unlock()
            // A bounded migration pass or unavailable headroom remains retryable without a
            // new filesystem event. Lifecycle cancellation never schedules its successor.
            if remainsCurrent, (try? self.maintenanceIsPending()) == true {
                self.scheduleDeferredMaintenance(after: 2)
            }
        }
    }

    func cancelDeferredMaintenance() {
        maintenanceStateLock.lock()
        maintenanceToken = nil
        maintenanceStateLock.unlock()
    }

    /// Interactive work asks a running pass to yield, without resetting its scheduled deadline.
    /// Per-block migration commits survive this yield, so frequent file events cannot repeatedly
    /// restart a giant transcript or postpone the maintenance timer forever.
    func yieldDeferredMaintenanceForActivity() {
        maintenanceStateLock.lock()
        maintenanceActivityEpoch &+= 1
        maintenanceStateLock.unlock()
    }

    private func maintenanceActivitySnapshot() -> UInt64 {
        maintenanceStateLock.lock()
        defer { maintenanceStateLock.unlock() }
        return maintenanceActivityEpoch
    }

    /// Clears only derived catalog/search data. Producer files are never opened or modified.
    @discardableResult
    func rebuild() throws -> Int64 {
        try withLock {
            let generation = try transaction {
                if try tableExists("conversation_documents_legacy") {
                    try execute("DELETE FROM conversation_documents_legacy")
                }
                try execute("DELETE FROM conversation_documents")
                try execute("DELETE FROM conversation_sessions")
                try markMaintenancePending()
                return try advanceGeneration()
            }
            try hardenPermissions()
            return generation
        }
    }

    // MARK: - Schema

    private func configureConnection() throws {
        sqlite3_extended_result_codes(connection, 1)
        let timeout = sqlite3_busy_timeout(connection, 3_000)
        guard timeout == SQLITE_OK else { throw sqliteError("set busy timeout", timeout) }
        try execute("PRAGMA busy_timeout = 3000")
        try execute("PRAGMA foreign_keys = ON")
        // WAL writes the initial database header even before tables exist. Select the
        // pointer-map layout first: setting auto_vacuum after journal_mode=WAL leaves a
        // fresh catalog in NONE mode, where every later incremental_vacuum is a no-op.
        // Existing non-incremental catalogs still use the deferred one-time migration.
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        // Not MEMORY. Every temporary b-tree, sorter overflow and VACUUM working copy is sized by
        // the catalog, and this one is gigabytes on a normal library — holding any of that in RAM
        // trades a disposable cache for the user's memory. Spilling only starts above the page
        // cache, so ordinary reads are unaffected.
        try execute("PRAGMA temp_store = FILE")
    }

    private func initializeSchema() throws {
        // Only schema/identity rows move at open. Multi-GB text conversion and obsolete
        // index removal belong to cancellable background maintenance, never the main thread.
        try transaction {
            let version = try int64Value("PRAGMA user_version")
            guard version <= Int64(Self.schemaVersion) else {
                throw ConversationIndexDatabaseError.invalidRecord("newer catalog schema")
            }
            if version > 0, version < Int64(Self.schemaVersion) {
                let generation = try currentGeneration()
                try execute("DROP TRIGGER IF EXISTS conversation_documents_content_stamp")
                try execute("DROP INDEX IF EXISTS conversation_documents_session_order")
                try execute("ALTER TABLE conversation_documents RENAME TO conversation_documents_legacy")
                try execute("DROP TABLE conversation_catalog_state")
                try createBaseSchema()
                try execute("""
                    INSERT INTO conversation_documents(id, session_path, transcript_id, agent_type,
                        sort_order, storage_version)
                    SELECT id, session_path, transcript_id, agent_type, sort_order, 0
                    FROM conversation_documents_legacy
                    """)
                try execute("""
                    UPDATE conversation_catalog_state SET generation = ?, maintenance_pending = 1,
                        one_time_compaction_pending = 1 WHERE singleton = 1
                    """, bindings: [.integer(generation)])
            } else {
                try createBaseSchema()
            }
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func createBaseSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_catalog_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                generation INTEGER NOT NULL,
                storage_revision INTEGER NOT NULL DEFAULT 0,
                maintenance_pending INTEGER NOT NULL CHECK (maintenance_pending IN (0, 1)),
                one_time_compaction_pending INTEGER NOT NULL
                    CHECK (one_time_compaction_pending IN (0, 1))
            )
            """
        )
        try execute(
            "INSERT OR IGNORE INTO conversation_catalog_state("
                + "singleton, generation, maintenance_pending, "
                + "one_time_compaction_pending) VALUES (1, 0, 0, 0)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_sessions (
                source_path TEXT PRIMARY KEY NOT NULL,
                scope TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_activity REAL NOT NULL,
                file_mtime REAL NOT NULL,
                file_size INTEGER NOT NULL CHECK (file_size >= 0),
                dependency_fingerprint TEXT,
                metadata_json BLOB NOT NULL,
                indexed_at REAL NOT NULL,
                deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
                imported INTEGER NOT NULL CHECK (imported IN (0, 1))
            ) WITHOUT ROWID
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_sessions_activity "
                + "ON conversation_sessions(last_activity DESC, created_at DESC)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_sessions_scope_activity "
                + "ON conversation_sessions(scope, deleted, last_activity DESC)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_sessions_source_activity "
                + "ON conversation_sessions(source, deleted, last_activity DESC)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_documents (
                id INTEGER PRIMARY KEY,
                session_path TEXT NOT NULL
                    REFERENCES conversation_sessions(source_path) ON DELETE CASCADE,
                transcript_id TEXT NOT NULL,
                agent_type TEXT,
                sort_order INTEGER NOT NULL,
                storage_version INTEGER NOT NULL DEFAULT 1 CHECK (storage_version IN (0, 1)),
                migration_byte_offset INTEGER NOT NULL DEFAULT 0,
                migration_utf16_offset INTEGER NOT NULL DEFAULT 0,
                migration_ordinal INTEGER NOT NULL DEFAULT 0,
                UNIQUE(session_path, transcript_id)
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_documents_session_order "
                + "ON conversation_documents(session_path, sort_order, transcript_id)"
        )
        try execute("""
            CREATE TABLE IF NOT EXISTS conversation_search_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id INTEGER NOT NULL REFERENCES conversation_documents(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                utf16_location INTEGER NOT NULL,
                utf16_length INTEGER NOT NULL,
                codec INTEGER NOT NULL,
                decoded_bytes INTEGER NOT NULL,
                body BLOB NOT NULL,
                message_spans_json BLOB NOT NULL,
                UNIQUE(document_id, ordinal)
            )
            """)
        // Additive v4 migration: this small side table snapshots the existing stamp
        // without rewriting multi-GB document rows. Matching legacy stamps retain a
        // warm checkpoint; a pre-migration metadata refresh may require one safe reindex.
        // Metadata-only refreshes change sessions.indexed_at, not transcript content.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_content_stamps (
                session_path TEXT PRIMARY KEY NOT NULL
                    REFERENCES conversation_sessions(source_path) ON DELETE CASCADE,
                indexed_at REAL NOT NULL
            ) WITHOUT ROWID
            """
        )
        try execute(
            "INSERT OR IGNORE INTO conversation_content_stamps(session_path, indexed_at) "
                + "SELECT source_path, indexed_at FROM conversation_sessions"
        )
        // Keeping the stamp at the SQL mutation boundary also covers writers from
        // earlier app builds which do not know about this additive metadata table.
        try execute(
            """
            CREATE TRIGGER IF NOT EXISTS conversation_documents_content_stamp
            AFTER INSERT ON conversation_documents BEGIN
                INSERT INTO conversation_content_stamps(session_path, indexed_at)
                SELECT source_path, indexed_at FROM conversation_sessions WHERE source_path = NEW.session_path
                ON CONFLICT(session_path) DO UPDATE SET indexed_at = excluded.indexed_at;
            END
            """
        )
    }

    // MARK: - Queries

    private static let entrySelect = """
        SELECT source_path, scope, file_mtime, file_size, dependency_fingerprint,
               metadata_json, indexed_at
        FROM conversation_sessions
        """

    private static let documentSelect = """
        SELECT d.transcript_id, d.agent_type, d.sort_order, d.id, d.storage_version
        FROM conversation_documents d
        """

    private func queryEntries(
        _ sql: String,
        bindings: [SQLiteValue],
        connection: OpaquePointer,
        validLimit: Int,
        validOffset: Int
    ) throws -> [ConversationIndexEntry] {
        let statement = try prepare(sql, bindings: bindings, connection: connection)
        defer { sqlite3_finalize(statement) }
        var result: [ConversationIndexEntry] = []
        var validRowsSeen = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw sqliteError("read sessions", status, connection: connection)
            }
            do {
                let entry = try decodeEntry(statement, offset: 0)
                defer { validRowsSeen += 1 }
                guard validRowsSeen >= validOffset else { continue }
                result.append(entry)
                if validLimit != .max, result.count == validLimit { return result }
            } catch ConversationIndexDatabaseError.corruptRow(_) {
                // A rebuildable cache row must not make every otherwise-valid session disappear.
                continue
            }
        }
    }

    private func queryChunkCandidateReferences(
        scope: String?, source: HistorySource?, deleted: Bool?, chunkIDs: [Int64]?,
        generation: Int64, connection: OpaquePointer
    ) throws -> [ConversationIndexDocumentReference] {
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        if let scope { conditions.append("s.scope = ?"); bindings.append(.text(scope)) }
        if let source { conditions.append("s.source = ?"); bindings.append(.text(source.rawValue)) }
        if let deleted { conditions.append("s.deleted = ?"); bindings.append(.integer(deleted ? 1 : 0)) }
        var byDocument: [Int64: ConversationIndexDocumentReference] = [:]
        func read(extra: [String], extraBindings: [SQLiteValue], joinsChunks: Bool) throws {
            let allConditions = conditions + extra
            let predicate = allConditions.isEmpty ? "" : " WHERE " + allConditions.joined(separator: " AND ")
            let sql = """
                SELECT d.id, d.session_path, d.transcript_id, d.agent_type, d.sort_order,
                    s.last_activity, d.storage_version,
                """ + (joinsChunks ? " c.id" : " NULL") + """
                 FROM conversation_documents d
                JOIN conversation_sessions s ON s.source_path = d.session_path
                """ + (joinsChunks ? " JOIN conversation_search_chunks c ON c.document_id = d.id" : "") + predicate
            let statement = try prepare(sql, bindings: bindings + extraBindings, connection: connection)
            defer { sqlite3_finalize(statement) }
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read chunk candidates", status, connection: connection)
                }
                let documentID = sqlite3_column_int64(statement, 0)
                let legacy = sqlite3_column_int(statement, 6) == 0
                if byDocument[documentID] == nil {
                    byDocument[documentID] = ConversationIndexDocumentReference(
                        documentID: documentID,
                        sessionPath: try textColumn(statement, 1, field: "session_path"),
                        transcriptID: try textColumn(statement, 2, field: "transcript_id"),
                        agentType: optionalTextColumn(statement, 3),
                        sortOrder: Int(sqlite3_column_int64(statement, 4)),
                        lastActivity: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                        candidateChunkIDs: legacy || chunkIDs == nil ? nil : [],
                        catalogGeneration: generation)
                }
                if joinsChunks { byDocument[documentID]?.candidateChunkIDs?.append(sqlite3_column_int64(statement, 7)) }
            }
        }
        if let chunkIDs {
            // Legacy text has no postings until its physical conversion completes.
            try read(extra: ["d.storage_version = 0"], extraBindings: [], joinsChunks: false)
            for offset in stride(from: 0, to: chunkIDs.count, by: 400) {
                let ids = Array(chunkIDs[offset..<min(chunkIDs.count, offset + 400)])
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                try read(extra: ["d.storage_version = 1", "c.id IN (\(placeholders))"],
                    extraBindings: ids.map(SQLiteValue.integer), joinsChunks: true)
            }
        } else {
            // Exact fallback needs one logical identity, not a scan of every block identity.
            try read(extra: [], extraBindings: [], joinsChunks: false)
        }
        return Array(byDocument.values)
    }

    /// Scans small document identities at a new catalog revision, reading text
    /// only for added/replaced transcripts. Warm queries read one generation
    /// integer, then go directly to tgrep's mmap postings. The caller owns an
    /// active SQLite snapshot and the read lock for this entire operation.
    private func synchronizeTgrep(connection: OpaquePointer) throws -> Int {
        let revision = try int64Value(
            "SELECT generation + storage_revision FROM conversation_catalog_state WHERE singleton = 1",
            connection: connection)
        if tgrep == nil {
            tgrep = try tgrepRuntime.makeIndex(file.deletingLastPathComponent()
                .appendingPathComponent(file.lastPathComponent + ".tgrep-chunks-v1", isDirectory: true))
        }
        guard let tgrep else { throw TgrepSearchIndex.Failure.unavailable }
        if tgrep.revision == revision { return 0 }
        if !tgrep.restoredFromCache, tgrep.documentCount == 0,
           let available = tgrepRuntime.availableCapacity(file.deletingLastPathComponent()) {
            let databaseBytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let required = 64 * 1_024 * 1_024 + min(Int64(databaseBytes), 512 * 1_024 * 1_024)
            guard available >= required else { throw TgrepSearchIndex.Failure.lowDiskSpace }
        }
        let statement = try prepare("""
            SELECT c.id, d.session_path, d.transcript_id, s.indexed_at, c.ordinal, d.id
            FROM conversation_search_chunks c
            JOIN conversation_documents d ON d.id = c.document_id
            JOIN conversation_content_stamps s ON s.session_path = d.session_path
            WHERE d.storage_version = 1
            """, bindings: [], connection: connection)
        defer { sqlite3_finalize(statement) }
        var stamps: [Int64: TgrepSearchIndex.Stamp] = [:]
        var updated = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw sqliteError("synchronize chunk identities", status, connection: connection)
            }
            let id = sqlite3_column_int64(statement, 0)
            let stamp = TgrepSearchIndex.Stamp(
                path: try textColumn(statement, 1, field: "session_path"),
                transcript: try textColumn(statement, 2, field: "transcript_id")
                    + ":chunk:" + String(id),
                indexedAt: sqlite3_column_double(statement, 3))
            stamps[id] = stamp
            guard !tgrep.contains(id: id, stamp: stamp) else { continue }
            let ordinal = Int(sqlite3_column_int64(statement, 4))
            let documentID = sqlite3_column_int64(statement, 5)
            guard let window = try readStoredWindow(documentID: documentID, ordinal: ordinal,
                lookahead: ConversationSearchChunk.indexLookaheadCharacters, generation: revision,
                connection: connection) else { throw TgrepSearchIndex.Failure.operationFailed }
            try tgrep.upsert(id: id, text: window.text)
            updated += 1
        }
        try tgrep.commit(revision: revision, stamps: stamps)
        return updated
    }

    private func decodeEntry(
        _ statement: OpaquePointer,
        offset: Int32
    ) throws -> ConversationIndexEntry {
        let path = try textColumn(statement, offset, field: "source_path")
        let scope = try textColumn(statement, offset + 1, field: "scope")
        let fileSize = sqlite3_column_int64(statement, offset + 3)
        guard fileSize >= 0 else {
            throw ConversationIndexDatabaseError.corruptRow("negative file size for \(path)")
        }
        let indexedAtSeconds = sqlite3_column_double(statement, offset + 6)
        let metadata: HistorySessionMetadata
        if let cached = cachedMetadata(path: path, indexedAt: indexedAtSeconds) {
            metadata = cached
        } else {
            let metadataData = try blobColumn(statement, offset + 5, field: "metadata_json")
            do {
                if let current = try? metadataDecoder.decode(HistorySessionMetadata.self, from: metadataData) {
                    metadata = current
                } else {
                    metadata = try metadataDecoder.decode(HistorySessionMetadata.self,
                        from: compatibleMetadataData(metadataData))
                }
            } catch {
                throw ConversationIndexDatabaseError.corruptRow(
                    "metadata JSON for \(path): \(error.localizedDescription)"
                )
            }
            storeCachedMetadata(metadata, path: path, indexedAt: indexedAtSeconds)
        }
        return ConversationIndexEntry(
            sourcePath: path,
            metadata: metadata,
            scope: scope,
            fingerprint: ConversationIndexFingerprint(
                modificationTime: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, offset + 2)
                ),
                sizeBytes: UInt64(fileSize),
                dependencyFingerprint: optionalTextColumn(statement, offset + 4)
            ),
            indexedAt: Date(timeIntervalSince1970: indexedAtSeconds)
        )
    }

    /// Older metadata encoded before these user-facing flags existed must remain readable.
    /// Existing values (including stars, pins and tags) are never overwritten or defaulted.
    private func compatibleMetadataData(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let defaults: [String: Any] = ["starred": false, "pinned": false, "subagentRefs": [],
            "canonicalThreadIDValid": false, "tags": [], "isSubagent": false, "subagentCount": 0,
            "imported": false, "deleted": false, "messageCount": 0,
            "diagnostics": ["decodedLines": 0, "malformedLines": 0]]
        var changed = false
        for (key, value) in defaults where object[key] == nil {
            object[key] = value
            changed = true
        }
        return changed ? try JSONSerialization.data(withJSONObject: object) : data
    }

    private func cachedMetadata(path: String, indexedAt: Double) -> HistorySessionMetadata? {
        metadataDecodeCacheLock.lock()
        defer { metadataDecodeCacheLock.unlock() }
        guard let cached = metadataDecodeCache[path], cached.indexedAt == indexedAt else {
            return nil
        }
        return cached.metadata
    }

    private func storeCachedMetadata(
        _ metadata: HistorySessionMetadata,
        path: String,
        indexedAt: Double
    ) {
        metadataDecodeCacheLock.lock()
        defer { metadataDecodeCacheLock.unlock() }
        if metadataDecodeCache.count >= Self.metadataDecodeCacheLimit {
            metadataDecodeCache.removeAll(keepingCapacity: true)
        }
        metadataDecodeCache[path] = (indexedAt, metadata)
    }

    private struct LegacyHeader {
        var bytes: Int
        var spans: [ConversationIndexMessageSpan]
    }

    private func legacyHeader(documentID: Int64, connection: OpaquePointer) throws -> LegacyHeader {
        legacyHeaderCacheLock.lock()
        let cached = legacyHeaderCache
        legacyHeaderCacheLock.unlock()
        if cached?.id == documentID, let cached { return cached.header }
        let blob = try openLegacyBlob(documentID: documentID, connection: connection)
        defer { sqlite3_blob_close(blob) }
        let byteCount = Int(sqlite3_blob_bytes(blob))
        let statement = try prepare("""
            SELECT message_spans_json
            FROM conversation_documents_legacy WHERE id = ?
            """, bindings: [.integer(documentID)], connection: connection)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ConversationIndexDatabaseError.corruptRow("missing legacy transcript")
        }
        let spanData = try blobColumn(statement, 0, field: "message_spans_json")
        let header = LegacyHeader(bytes: byteCount,
            spans: try metadataDecoder.decode([ConversationIndexMessageSpan].self,
                from: spanData))
        if spanData.count <= 4 * 1_024 * 1_024 {
            legacyHeaderCacheLock.lock()
            legacyHeaderCache = (documentID, header)
            legacyHeaderCacheLock.unlock()
        }
        return header
    }

    private func openLegacyBlob(documentID: Int64, connection: OpaquePointer) throws -> OpaquePointer {
        var blob: OpaquePointer?
        let status = sqlite3_blob_open(connection, "main", "conversation_documents_legacy",
            "search_text", documentID, 0, &blob)
        guard status == SQLITE_OK, let blob else {
            throw sqliteError("open legacy incremental blob", status, connection: connection)
        }
        return blob
    }

    /// SQLite's incremental blob API also reads TEXT columns, without OP_Column materializing
    /// the entire value for every substr. Keep the last decoded grapheme for the following read
    /// until its complete boundary is known.
    private func legacyPart(documentID: Int64, byteOffset: Int, totalBytes: Int,
                            connection: OpaquePointer) throws -> String {
        guard byteOffset < totalBytes else { return "" }
        let blob = try openLegacyBlob(documentID: documentID, connection: connection)
        defer { sqlite3_blob_close(blob) }
        var requested = min(totalBytes - byteOffset, ConversationSearchChunk.targetBytes + 4_096)
        while true {
            try Task.checkCancellation()
            var data = Data(count: requested)
            let status = data.withUnsafeMutableBytes {
                sqlite3_blob_read(blob, $0.baseAddress!, Int32(requested), Int32(byteOffset))
            }
            guard status == SQLITE_OK else {
                throw sqliteError("read legacy incremental blob", status, connection: connection)
            }
            var decoded = String(data: data, encoding: .utf8)
            for _ in 0..<3 where decoded == nil && !data.isEmpty {
                data.removeLast()
                decoded = String(data: data, encoding: .utf8)
            }
            guard let text = decoded else {
                throw ConversationIndexDatabaseError.corruptRow("legacy UTF-8")
            }
            let atEnd = byteOffset + requested >= totalBytes
            var cursor = text.startIndex
            var bytes = 0
            var end = cursor
            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                if !atEnd, next == text.endIndex { break }
                let width = text[cursor..<next].utf8.count
                if bytes > 0, bytes + width > ConversationSearchChunk.targetBytes { break }
                bytes += width
                end = next
                cursor = next
            }
            if end > text.startIndex { return String(text[..<end]) }
            if atEnd { return text }
            // Only an indivisible oversized grapheme may exceed the target, never an
            // ordinary long transcript. Double safely until a complete boundary is visible.
            let remaining = totalBytes - byteOffset
            requested = requested > remaining / 2 ? remaining : requested * 2
        }
    }

    private func insertChunk(documentID: Int64, ordinal: Int, part: ConversationSearchChunk.Part,
                             spans: [ConversationIndexMessageSpan]) throws {
        let encoded = ConversationSearchCompression.encode(part.text)
        let localSpans = ConversationSearchChunk.spans(spans, location: part.utf16Location,
            length: part.utf16Length)
        try execute("""
            INSERT INTO conversation_search_chunks(document_id, ordinal, utf16_location,
                utf16_length, codec, decoded_bytes, body, message_spans_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [.integer(documentID), .integer(Int64(ordinal)),
                .integer(Int64(part.utf16Location)), .integer(Int64(part.utf16Length)),
                .integer(Int64(encoded.codec)), .integer(Int64(encoded.decodedBytes)),
                .blob(encoded.bytes), .blob(try metadataEncoder.encode(localSpans))])
    }

    private func readStoredWindow(documentID: Int64, ordinal: Int, lookahead: Int,
                                  generation: Int64, connection: OpaquePointer)
        throws -> ConversationIndexSearchWindow? {
        let statement = try prepare("""
            SELECT id, ordinal, utf16_location, utf16_length, codec, decoded_bytes, body,
                message_spans_json
            FROM conversation_search_chunks WHERE document_id = ? AND ordinal >= ? ORDER BY ordinal
            """, bindings: [.integer(documentID), .integer(Int64(ordinal))], connection: connection)
        defer { sqlite3_finalize(statement) }
        var result: ConversationIndexSearchWindow?
        var remaining = max(0, lookahead)
        var spans: [Int: ConversationIndexMessageSpan] = [:]
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw sqliteError("read compressed chunk", status, connection: connection)
            }
            if result != nil, remaining == 0 { break }
            let text = try ConversationSearchCompression.decode(
                blobColumn(statement, 6, field: "chunk body"),
                codec: Int(sqlite3_column_int64(statement, 4)),
                decodedBytes: Int(sqlite3_column_int64(statement, 5)))
            let decodedSpans = try metadataDecoder.decode([ConversationIndexMessageSpan].self,
                from: blobColumn(statement, 7, field: "message_spans_json"))
            for span in decodedSpans { spans[span.sequence] = span }
            if result == nil {
                guard Int(sqlite3_column_int64(statement, 1)) == ordinal else { return nil }
                guard text.utf16.count == Int(sqlite3_column_int64(statement, 3)) else {
                    throw ConversationIndexDatabaseError.corruptRow("chunk UTF-16 size")
                }
                result = ConversationIndexSearchWindow(chunkID: sqlite3_column_int64(statement, 0),
                    text: text, globalUTF16Start: Int(sqlite3_column_int64(statement, 2)),
                    ownedUTF16Length: Int(sqlite3_column_int64(statement, 3)),
                    messageSpans: [], generation: generation)
            } else {
                let prefix = text.prefix(remaining)
                result?.text.append(contentsOf: prefix)
                remaining -= prefix.count
            }
        }
        if var value = result {
            value.messageSpans = ConversationSearchChunk.spans(spans.values.sorted {
                $0.utf16Location < $1.utf16Location
            },
                location: value.globalUTF16Start, length: value.text.utf16.count)
            return value
        }
        return nil
    }

    /// Compatibility/detail callers may reconstruct a logical transcript; search never uses it.
    private func decodeDocument(_ statement: OpaquePointer, offset: Int32,
                                connection: OpaquePointer) throws -> ConversationIndexDocument {
        let transcriptID = try textColumn(statement, offset, field: "transcript_id")
        let documentID = sqlite3_column_int64(statement, offset + 3)
        var text = ""
        var spans: [Int: ConversationIndexMessageSpan] = [:]
        if sqlite3_column_int(statement, offset + 4) == 0 {
            let header = try legacyHeader(documentID: documentID, connection: connection)
            for span in header.spans { spans[span.sequence] = span }
            var byteOffset = 0
            while byteOffset < header.bytes {
                let part = try legacyPart(documentID: documentID, byteOffset: byteOffset,
                    totalBytes: header.bytes, connection: connection)
                text.append(part)
                byteOffset += part.utf8.count
            }
        } else {
            var ordinal = 0
            while let part = try readStoredWindow(documentID: documentID, ordinal: ordinal,
                lookahead: 0, generation: 0, connection: connection) {
                text.append(part.text)
                for span in part.messageSpans { spans[span.sequence] = span }
                ordinal += 1
            }
        }
        return ConversationIndexDocument(transcriptID: transcriptID,
            agentType: optionalTextColumn(statement, offset + 1),
            sortOrder: Int(sqlite3_column_int64(statement, offset + 2)), text: text,
            messageSpans: spans.values.sorted { $0.utf16Location < $1.utf16Location })
    }

    // MARK: - Mutations and validation

    private func removeDocuments(for path: String) throws {
        if try tableExists("conversation_documents_legacy") {
            try execute("DELETE FROM conversation_documents_legacy WHERE session_path = ?",
                bindings: [.text(path)])
        }
        try execute("DELETE FROM conversation_documents WHERE session_path = ?", bindings: [.text(path)])
    }

    private func tableExists(_ table: String) throws -> Bool {
        try int64Value("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            bindings: [.text(table)]) != 0
    }

    private func validate(_ session: ConversationIndexedSession) throws {
        guard session.metadata.file.isFileURL else {
            throw ConversationIndexDatabaseError.invalidRecord("session source is not a file URL")
        }
        guard !session.scope.isEmpty else {
            throw ConversationIndexDatabaseError.invalidRecord("scope is empty")
        }
        guard session.fingerprint.modificationTime.timeIntervalSince1970.isFinite,
              session.metadata.createdAt.timeIntervalSince1970.isFinite,
              session.metadata.lastActivity.timeIntervalSince1970.isFinite else {
            throw ConversationIndexDatabaseError.invalidRecord("a timestamp is not finite")
        }
        _ = try sqliteInteger(session.fingerprint.sizeBytes, field: "file size")

        var transcriptIDs = Set<String>()
        for document in session.documents {
            guard !document.transcriptID.isEmpty else {
                throw ConversationIndexDatabaseError.invalidRecord("a transcript ID is empty")
            }
            guard transcriptIDs.insert(document.transcriptID).inserted else {
                throw ConversationIndexDatabaseError.invalidRecord(
                    "duplicate transcript ID \(document.transcriptID)"
                )
            }
            guard document.sortOrder >= 0 else {
                throw ConversationIndexDatabaseError.invalidRecord(
                    "negative sort order for \(document.transcriptID)"
                )
            }
            let textLength = document.text.utf16.count
            var previousEnd = 0
            for span in document.messageSpans {
                guard span.sequence >= 0, span.messageIndex >= 0,
                      span.utf16Location >= previousEnd, span.utf16Length >= 0,
                      span.utf16Location <= textLength,
                      span.utf16Length <= textLength - span.utf16Location else {
                    throw ConversationIndexDatabaseError.invalidRecord(
                        "invalid message span in \(document.transcriptID)"
                    )
                }
                previousEnd = span.utf16Location + span.utf16Length
            }
        }
    }

    private static func documentComesFirst(
        _ lhs: ConversationIndexDocument,
        _ rhs: ConversationIndexDocument
    ) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.transcriptID < rhs.transcriptID
    }

    private func currentGeneration() throws -> Int64 {
        try int64Value(
            "SELECT generation FROM conversation_catalog_state WHERE singleton = 1"
        )
    }

    private func advanceGeneration() throws -> Int64 {
        try execute(
            "UPDATE conversation_catalog_state SET generation = generation + 1 WHERE singleton = 1"
        )
        return try currentGeneration()
    }

    private func markMaintenancePending() throws {
        try execute(
            "UPDATE conversation_catalog_state SET maintenance_pending = 1 WHERE singleton = 1"
        )
    }

    /// Whether reclaiming the freelist justifies a full rewrite of the catalog.
    ///
    /// Both conditions matter: the ratio keeps a small file from being rewritten over a few stale
    /// pages, and the absolute floor keeps a mostly-empty new catalog — where the ratio is trivially
    /// high — from triggering a VACUUM that would save nothing worth having.
    static let vacuumFreelistRatio: Int64 = 4
    static let vacuumMinimumReclaimedBytes: Int64 = 64 * 1_024 * 1_024

    static func shouldVacuum(freelistPages: Int64, pageCount: Int64, pageSize: Int64) -> Bool {
        guard pageCount > 0, pageSize > 0, freelistPages > 0 else { return false }
        let reclaimable = freelistPages * pageSize
        return reclaimable >= vacuumMinimumReclaimedBytes
            && freelistPages * vacuumFreelistRatio >= pageCount
    }

    private func wastesEnoughToVacuum() throws -> Bool {
        Self.shouldVacuum(
            freelistPages: try int64Value("PRAGMA freelist_count"),
            pageCount: try int64Value("PRAGMA page_count"),
            pageSize: try int64Value("PRAGMA page_size")
        )
    }

    private func hasCapacityForMaintenance() -> Bool {
        guard let available = tgrepRuntime.availableCapacity(file.deletingLastPathComponent()) else {
            // Capacity probes are advisory; unsupported filesystems should retain existing
            // cancellable behavior rather than permanently disabling maintenance.
            return true
        }
        // VACUUM copies live pages, not the multi-GB freelist it is about to remove.
        let pages = (try? int64Value("PRAGMA page_count")) ?? 0
        let free = (try? int64Value("PRAGMA freelist_count")) ?? 0
        let pageSize = (try? int64Value("PRAGMA page_size")) ?? 4_096
        let reserve = max(Int64(256 * 1_024 * 1_024), max(0, pages - free) * pageSize * 2)
        return available > reserve
    }

    /// Returns false when an independent reader temporarily prevents truncation. That is benign:
    /// WAL auto-checkpointing remains enabled and the next mutating full scan will try again.
    private func checkpointWALTruncating(
        cancellation: SQLiteCancellationContext
    ) throws -> Bool {
        // A checkpoint is an optional space-recovery step, so never spend the connection's normal
        // busy timeout waiting for an unrelated reader. Leaving the pending marker set is safer
        // and keeps lifecycle cancellation latency bounded.
        let timeoutStatus = sqlite3_busy_timeout(connection, 0)
        guard timeoutStatus == SQLITE_OK else {
            throw sqliteError("disable checkpoint busy timeout", timeoutStatus)
        }
        defer { _ = sqlite3_busy_timeout(connection, 3_000) }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let status = try withSQLiteInterruptionMonitor(cancellation: cancellation) {
            sqlite3_wal_checkpoint_v2(
                connection,
                nil,
                SQLITE_CHECKPOINT_TRUNCATE,
                &logFrames,
                &checkpointedFrames
            )
        }
        if status != SQLITE_OK, cancellation.wasCancelled {
            throw CancellationError()
        }
        if status == SQLITE_BUSY { return false }
        guard status == SQLITE_OK else { throw sqliteError("truncate WAL checkpoint", status) }
        return true
    }

    // MARK: - SQLite primitives

    private final class SQLiteCancellationContext {
        let isCancelled: ConversationIndexScanCancellation
        private let stateLock = NSLock()
        private var cancelled = false

        init(isCancelled: @escaping ConversationIndexScanCancellation) {
            self.isCancelled = isCancelled
        }

        func check() throws {
            guard !poll() else { throw CancellationError() }
        }

        func poll() -> Bool {
            guard isCancelled() else { return false }
            stateLock.lock()
            cancelled = true
            stateLock.unlock()
            return true
        }

        var wasCancelled: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return cancelled
        }

        func retryBusy(priorCalls: Int32) -> Int32 {
            if poll() { return 0 }
            guard priorCalls < 300 else { return 0 }
            sqlite3_sleep(10)
            return 1
        }
    }

    private static let maintenanceProgressHandler:
        @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
            guard let pointer else { return 0 }
            let cancellation = Unmanaged<SQLiteCancellationContext>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            return cancellation.poll() ? 1 : 0
        }

    private static let maintenanceBusyHandler:
        @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { pointer, priorCalls in
            guard let pointer else { return 0 }
            let cancellation = Unmanaged<SQLiteCancellationContext>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            return cancellation.retryBusy(priorCalls: priorCalls)
        }

    /// VACUUM's internal page copy does not consistently invoke SQLite's progress callback on
    /// every supported macOS SQLite build. A separate monitor supplies the documented cross-thread
    /// sqlite3_interrupt path; executeCancellableMaintenance always joins it before returning.
    private static let maintenanceCancellationQueue = DispatchQueue(
        label: "dev.ccbud.conversation-index-maintenance-cancellation",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    private static let deferredMaintenanceQueue = DispatchQueue(
        label: "dev.ccbud.conversation-index-deferred-maintenance",
        qos: .background,
        autoreleaseFrequency: .workItem
    )

    private enum SQLiteValue {
        case null
        case integer(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func isMaintenanceCurrent(_ token: UUID) -> Bool {
        maintenanceStateLock.lock()
        defer { maintenanceStateLock.unlock() }
        return maintenanceToken == token
    }

    private func withReadLock<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        while !readLock.lock(before: Date(timeIntervalSinceNow: 0.01)) {
            try Task.checkCancellation()
        }
        defer { readLock.unlock() }
        try Task.checkCancellation()
        guard let readConnection else {
            throw ConversationIndexDatabaseError.sqlite(
                operation: "open read connection",
                code: SQLITE_MISUSE,
                detail: "query-only connection is unavailable"
            )
        }
        sqlite3_progress_handler(readConnection, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer {
            sqlite3_progress_handler(readConnection, 0, nil, nil)
            // Cancellation can interrupt even the transaction body's cleanup.
            // Never return a pooled reader to the next query with a stale snapshot.
            if sqlite3_get_autocommit(readConnection) == 0 {
                sqlite3_exec(readConnection, "ROLLBACK", nil, nil, nil)
            }
        }
        do {
            return try body(readConnection)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Keep cancellation responsive when a competing writer owns the transaction lock.
    /// Once acquired, one ordinary compressed block commits before activity is considered.
    private func migrationTransaction<T>(cancellation: SQLiteCancellationContext,
                                         _ body: () throws -> T) throws -> T {
        try executeCancellableMaintenance("BEGIN IMMEDIATE", cancellation: cancellation)
        do {
            let result = try body()
            try cancellation.check()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs a potentially long maintenance statement with cooperative cancellation both while
    /// SQLite executes virtual-machine instructions and while it waits for another connection.
    private func executeCancellableMaintenance(
        _ sql: String,
        cancellation: SQLiteCancellationContext
    ) throws {
        let pointer = Unmanaged.passUnretained(cancellation).toOpaque()
        sqlite3_progress_handler(
            connection,
            1_000,
            Self.maintenanceProgressHandler,
            pointer
        )
        let busyStatus = sqlite3_busy_handler(
            connection,
            Self.maintenanceBusyHandler,
            pointer
        )
        guard busyStatus == SQLITE_OK else {
            sqlite3_progress_handler(connection, 0, nil, nil)
            throw sqliteError("install cancellable maintenance busy handler", busyStatus)
        }
        defer {
            sqlite3_progress_handler(connection, 0, nil, nil)
            _ = sqlite3_busy_timeout(connection, 3_000)
        }
        do {
            try withSQLiteInterruptionMonitor(cancellation: cancellation) {
                try execute(sql)
            }
        } catch {
            if cancellation.wasCancelled { throw CancellationError() }
            throw error
        }
    }

    private func withSQLiteInterruptionMonitor<T>(
        cancellation: SQLiteCancellationContext,
        _ body: () throws -> T
    ) throws -> T {
        let operationFinished = DispatchSemaphore(value: 0)
        let monitorFinished = DispatchSemaphore(value: 0)
        let connection = self.connection
        Self.maintenanceCancellationQueue.async {
            defer { monitorFinished.signal() }
            while operationFinished.wait(timeout: .now() + 0.005) == .timedOut {
                guard cancellation.poll() else { continue }
                sqlite3_interrupt(connection)
                return
            }
        }

        let result: Result<T, Error>
        do {
            result = .success(try body())
        } catch {
            result = .failure(error)
        }
        operationFinished.signal()
        monitorFinished.wait()
        return try result.get()
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        // Some mutating PRAGMAs expose progress as result rows. In particular,
        // incremental_vacuum(N) reclaims one page per SQLITE_ROW; finalizing after
        // the first row silently turns an 8192-page pass into a one-page pass.
        // Maintenance's progress handler and cross-thread interrupt remain installed
        // for the entire loop, so consuming results does not weaken cancellation.
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else {
                throw sqliteError("execute statement", status)
            }
        }
    }

    private func prepare(
        _ sql: String,
        bindings: [SQLiteValue],
        connection requestedConnection: OpaquePointer? = nil
    ) throws -> OpaquePointer {
        let target = requestedConnection ?? connection
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(target, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw sqliteError("prepare statement", status, connection: target)
        }
        do {
            for (offset, value) in bindings.enumerated() {
                try bind(value, to: statement, at: Int32(offset + 1))
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func bind(
        _ value: SQLiteValue,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        let status: Int32
        switch value {
        case .null:
            status = sqlite3_bind_null(statement, index)
        case .integer(let value):
            status = sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            status = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            let bytes = Array(value.utf8)
            guard bytes.count <= Int(Int32.max) else {
                throw ConversationIndexDatabaseError.invalidRecord("text binding is too large")
            }
            status = bytes.withUnsafeBytes { buffer in
                sqlite3_bind_text(
                    statement,
                    index,
                    buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(buffer.count),
                    Self.sqliteTransient
                )
            }
        case .blob(let value):
            guard value.count <= Int(Int32.max) else {
                throw ConversationIndexDatabaseError.invalidRecord("blob binding is too large")
            }
            if value.isEmpty {
                status = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                status = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        Self.sqliteTransient
                    )
                }
            }
        }
        guard status == SQLITE_OK else { throw sqliteError("bind value", status) }
    }

    private func int64Value(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        connection requestedConnection: OpaquePointer? = nil
    ) throws -> Int64 {
        let target = requestedConnection ?? connection
        let statement = try prepare(sql, bindings: bindings, connection: target)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            throw sqliteError("read integer", status, connection: target)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func tableHasColumn(_ column: String, in table: String) throws -> Bool {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        return try int64Value(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('\(escapedTable)') WHERE name = ?)",
            bindings: [.text(column)]
        ) != 0
    }

    private func stringValues(
        _ sql: String,
        bindings: [SQLiteValue]
    ) throws -> [String] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw sqliteError("read strings", status) }
            result.append(try textColumn(statement, 0, field: "text value"))
        }
    }

    private func textColumn(
        _ statement: OpaquePointer,
        _ column: Int32,
        field: String
    ) throws -> String {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            throw ConversationIndexDatabaseError.corruptRow("NULL \(field)")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return "" }
        guard let pointer = sqlite3_column_text(statement, column) else {
            throw ConversationIndexDatabaseError.corruptRow("unreadable \(field)")
        }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: count)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func optionalTextColumn(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    private func blobColumn(
        _ statement: OpaquePointer,
        _ column: Int32,
        field: String
    ) throws -> Data {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            throw ConversationIndexDatabaseError.corruptRow("NULL \(field)")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else {
            throw ConversationIndexDatabaseError.corruptRow("unreadable \(field)")
        }
        return Data(bytes: pointer, count: count)
    }

    private func sqliteInteger(_ value: UInt64, field: String) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw ConversationIndexDatabaseError.invalidRecord("\(field) exceeds SQLite INTEGER")
        }
        return result
    }

    private func sqliteError(
        _ operation: String,
        _ status: Int32,
        connection requestedConnection: OpaquePointer? = nil
    ) -> Error {
        let target = requestedConnection ?? connection
        return ConversationIndexDatabaseError.sqlite(
            operation: operation,
            code: status,
            detail: String(cString: sqlite3_errmsg(target))
        )
    }

    private func hardenPermissions() throws {
        for candidate in [file.path, file.path + "-wal", file.path + "-shm"] {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            let url = URL(fileURLWithPath: candidate)
            guard ForeignHistorySupport.isOrdinaryFile(url) else {
                throw ConversationIndexDatabaseError.unsafeDatabaseFile(url)
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: candidate
                )
            } catch {
                throw ConversationIndexDatabaseError.sqlite(
                    operation: "set private permissions",
                    code: SQLITE_PERM,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private static func prepareLocation(_ file: URL) throws {
        let manager = FileManager.default
        let parent = file.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw ConversationIndexDatabaseError.sqlite(
                operation: "create parent directory",
                code: SQLITE_CANTOPEN,
                detail: error.localizedDescription
            )
        }
        for candidate in [file.path, file.path + "-wal", file.path + "-shm"] {
            if (try? manager.destinationOfSymbolicLink(atPath: candidate)) != nil {
                throw ConversationIndexDatabaseError.unsafeDatabaseFile(
                    URL(fileURLWithPath: candidate)
                )
            }
            guard manager.fileExists(atPath: candidate) else { continue }
            let url = URL(fileURLWithPath: candidate)
            guard ForeignHistorySupport.isOrdinaryFile(url) else {
                throw ConversationIndexDatabaseError.unsafeDatabaseFile(url)
            }
        }
    }

    private static func openReadConnection(_ file: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(file.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.flatMap(sqlite3_errmsg).map(String.init(cString:))
                ?? "unable to open query-only database"
            if let handle { sqlite3_close(handle) }
            throw ConversationIndexDatabaseError.sqlite(
                operation: "open read connection",
                code: status,
                detail: detail
            )
        }
        sqlite3_extended_result_codes(handle, 1)
        let timeout = sqlite3_busy_timeout(handle, 250)
        guard timeout == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw ConversationIndexDatabaseError.sqlite(
                operation: "configure read connection",
                code: timeout,
                detail: detail
            )
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let queryOnly = sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, &errorMessage)
        guard queryOnly == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            sqlite3_close(handle)
            throw ConversationIndexDatabaseError.sqlite(
                operation: "configure read connection",
                code: queryOnly,
                detail: detail
            )
        }
        return handle
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
