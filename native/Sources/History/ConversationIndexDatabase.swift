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

/// FTS is deliberately only a candidate generator. The caller performs its normal Foundation
/// string match on `document.text`, then uses the spans to produce snippets and exact navigation.
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
/// The catalog stores one aggregate document per transcript, so `search_text` is by far the
/// largest column in the database — hundreds of megabytes on a normal multi-month library.
/// Selecting it for every candidate made one query cost the size of the whole library rather than
/// the size of the result: SQLite had to hold every matching row to satisfy the ordering, and the
/// caller then materialized the same text again as Swift strings. Candidates are therefore located
/// by identity first, and only the documents actually needed are read back, one at a time.
struct ConversationIndexDocumentReference: Equatable, Sendable {
    var documentID: Int64
    var sessionPath: String
    var transcriptID: String
    var agentType: String?
    var sortOrder: Int
    var lastActivity: Date
}

struct ConversationIndexCandidateReferenceBatch: Equatable, Sendable {
    var references: [ConversationIndexDocumentReference]
    var usedFallback: Bool
}

struct ConversationIndexReconciliation: Equatable, Sendable {
    var removedPaths: [String]
    var generation: Int64
}

enum ConversationIndexDatabaseError: LocalizedError, Sendable {
    case invalidDatabaseURL(URL)
    case unsafeDatabaseFile(URL)
    case invalidRecord(String)
    case unsafeEmptyReconciliation(String)
    case sqlite(operation: String, code: Int32, detail: String)
    case corruptRow(String)

    var errorDescription: String? {
        switch self {
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
    /// Version 2 preserves the warm derived index while adding bounded deferred-maintenance
    /// markers. Version 1 could retain gigabytes of obsolete FTS segments after replacement.
    /// Version 3 adds `starred` and `pinned` to the encoded session metadata. Synthesized `Decodable` does not
    /// fall back to a property's default value for a missing key, so blobs written by version 2
    /// would fail to decode; the catalog is disposable and is simply rebuilt instead.
    static let schemaVersion: Int32 = 4

    let file: URL

    private let lock = NSLock()
    private let readLock = NSLock()
    private let maintenanceStateLock = NSLock()
    private let connection: OpaquePointer
    private var readConnection: OpaquePointer?
    private var maintenanceToken: UUID?
    private let metadataEncoder: JSONEncoder
    private let metadataDecoder: JSONDecoder
    private var trigramFTSAvailable = false

    /// Decoded metadata keyed by row identity. Every list refresh — and the scope counts beside
    /// it — decodes the metadata blob of every session row; while an agent is appending, those
    /// refreshes arrive continuously and only the live session's row has actually changed. A row
    /// is rewritten exclusively through the upsert in `replace`/`replaceMetadata`, which always
    /// stamps a fresh `indexed_at`, so (path, indexed_at) proves the cached decode is current.
    private let metadataDecodeCacheLock = NSLock()
    private var metadataDecodeCache: [String: (indexedAt: Double, metadata: HistorySessionMetadata)] = [:]
    private static let metadataDecodeCacheLimit = 20_000

    init(file: URL) throws {
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
        connection = handle
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        metadataEncoder = encoder
        metadataDecoder = JSONDecoder()

        do {
            try configureConnection()
            trigramFTSAvailable = probeTrigramFTS()
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
        withLock { trigramFTSAvailable }
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
            let ftsWasDirty = try int64Value(
                "SELECT fts_dirty FROM conversation_catalog_state WHERE singleton = 1"
            ) != 0
            let preserveDirtyFTS = !trigramFTSAvailable || ftsWasDirty

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
                    let spans = try metadataEncoder.encode(document.messageSpans)
                    try execute(
                        """
                        INSERT INTO conversation_documents (
                            session_path, transcript_id, agent_type, sort_order,
                            search_text, message_spans_json
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(path),
                            .text(document.transcriptID),
                            document.agentType.map(SQLiteValue.text) ?? .null,
                            .integer(Int64(document.sortOrder)),
                            .text(document.text),
                            .blob(spans),
                        ]
                    )
                    if trigramFTSAvailable {
                        try execute(
                            "INSERT INTO conversation_documents_fts(rowid, search_text) VALUES (?, ?)",
                            bindings: [.integer(sqlite3_last_insert_rowid(connection)), .text(document.text)]
                        )
                    }
                }
                try markFTSState(dirty: preserveDirtyFTS)
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
            let preserveDirtyFTS = try shouldKeepFTSDirty()
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
                    try markFTSState(dirty: preserveDirtyFTS)
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

            let preserveDirtyFTS = try shouldKeepFTSDirty()
            let nextGeneration = try transaction {
                for path in removedPaths {
                    try removeDocuments(for: path)
                    try execute(
                        "DELETE FROM conversation_sessions WHERE source_path = ? AND scope = ?",
                        bindings: [.text(path), .text(scope)]
                    )
                }
                try markFTSState(dirty: preserveDirtyFTS)
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
    func document(id: Int64) throws -> ConversationIndexDocument? {
        try withReadLock { connection in
            let statement = try prepare(
                Self.documentSelect + " WHERE d.id = ? LIMIT 1",
                bindings: [.integer(id)],
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw sqliteError("read document", status, connection: connection)
            }
            do {
                return try decodeDocument(statement, offset: 0)
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
                    result.append(try decodeDocument(statement, offset: 0))
                } catch ConversationIndexDatabaseError.corruptRow(_) {
                    continue
                }
            }
        }
    }

    /// Returns the identity of documents which may contain a literal query. FTS safely narrows
    /// queries whose every whitespace-delimited segment is at least three characters; short
    /// queries and hosts without the trigram tokenizer use a bound `instr` expression instead.
    ///
    /// Callers read the transcripts they still need through `document(id:)`. That keeps peak
    /// memory at one transcript instead of the entire matching corpus.
    func candidateDocumentReferences(
        for rawQuery: String,
        scope: String? = nil,
        source: HistorySource? = nil,
        deleted: Bool? = false
    ) throws -> ConversationIndexCandidateReferenceBatch {
        try withReadLock { connection in
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return ConversationIndexCandidateReferenceBatch(
                    references: [],
                    usedFallback: false
                )
            }

            let segments = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let ftsIsReady = try int64Value(
                "SELECT fts_dirty FROM conversation_catalog_state WHERE singleton = 1",
                connection: connection
            ) == 0
            let canUseFTS = trigramFTSAvailable
                && ftsIsReady
                && !segments.isEmpty
                && segments.allSatisfy { $0.count >= 3 }
                && !query.unicodeScalars.contains(where: { $0.value == 0 })
            if canUseFTS {
                do {
                    return ConversationIndexCandidateReferenceBatch(
                        references: try queryCandidateReferences(
                            query: query,
                            scope: scope,
                            source: source,
                            deleted: deleted,
                            useFTS: true,
                            connection: connection
                        ),
                        usedFallback: false
                    )
                } catch {
                    // A copied database can contain an FTS table unsupported by the current
                    // SQLite runtime. The ordinary document table is always a safe fallback.
                }
            }
            return ConversationIndexCandidateReferenceBatch(
                references: try queryCandidateReferences(
                    query: query,
                    scope: scope,
                    source: source,
                    deleted: deleted,
                    useFTS: false,
                    connection: connection
                ),
                usedFallback: true
            )
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
                  let document = try document(id: reference.documentID) else { continue }
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

    /// Invalidates canonical list projection without touching transcript documents or FTS rows.
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

            // FTS rebuild and compaction can temporarily need another database-sized copy.
            // Low disk is a normal condition for a disposable cache: leave the retry marker
            // set and keep serving bounded fallback search instead of risking ENOSPC.
            guard hasCapacityForMaintenance() else { return }

            if trigramFTSAvailable {
                let dirty = try int64Value(
                    "SELECT fts_dirty FROM conversation_catalog_state WHERE singleton = 1"
                ) != 0
                if dirty {
                    try executeCancellableMaintenance(
                        "INSERT INTO conversation_documents_fts(conversation_documents_fts) "
                            + "VALUES ('rebuild')",
                        cancellation: cancellation
                    )
                    try markFTSState(dirty: false)
                    try cancellation.check()
                }
            }

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
                    try execute("VACUUM")
                }
                try execute(
                    "UPDATE conversation_catalog_state SET one_time_compaction_pending = 0 "
                        + "WHERE singleton = 1"
                )
                try cancellation.check()
            }

            if trigramFTSAvailable {
                try executeCancellableMaintenance(
                    "INSERT INTO conversation_documents_fts(conversation_documents_fts) "
                        + "VALUES ('optimize')",
                    cancellation: cancellation
                )
                try cancellation.check()
            }
            try executeCancellableMaintenance(
                "PRAGMA optimize",
                cancellation: cancellation
            )
            try cancellation.check()
            // This also reclaims pages freed by the FTS optimize which follows a successful
            // one-time VACUUM. It is bounded on every subsequent maintenance pass.
            try executeCancellableMaintenance(
                "PRAGMA incremental_vacuum(8192)",
                cancellation: cancellation
            )
            try cancellation.check()
            guard try checkpointWALTruncating(cancellation: cancellation) else {
                try cancellation.check()
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

    /// Schedules cache-only cleanup after the interactive scan has gone idle. Rescheduling is a
    /// cancellation signal for an older pass; list/search reads continue on their own connection.
    func scheduleDeferredMaintenance(after delay: TimeInterval = 8) {
        let token = UUID()
        maintenanceStateLock.lock()
        maintenanceToken = token
        maintenanceStateLock.unlock()
        Self.deferredMaintenanceQueue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self, self.isMaintenanceCurrent(token) else { return }
            try? self.finishFullScanMaintenance { [weak self] in
                self?.isMaintenanceCurrent(token) != true
            }
            self.maintenanceStateLock.lock()
            if self.maintenanceToken == token { self.maintenanceToken = nil }
            self.maintenanceStateLock.unlock()
        }
    }

    func cancelDeferredMaintenance() {
        maintenanceStateLock.lock()
        maintenanceToken = nil
        maintenanceStateLock.unlock()
    }

    /// Clears only derived catalog/search data. Producer files are never opened or modified.
    @discardableResult
    func rebuild() throws -> Int64 {
        try withLock {
            let generation = try transaction {
                if trigramFTSAvailable {
                    try execute("DELETE FROM conversation_documents_fts")
                }
                try execute("DELETE FROM conversation_documents")
                try execute("DELETE FROM conversation_sessions")
                try markFTSState(dirty: !trigramFTSAvailable)
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
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        // Not MEMORY. Every temporary b-tree, sorter overflow and VACUUM working copy is sized by
        // the catalog, and this one is gigabytes on a normal library — holding any of that in RAM
        // trades a disposable cache for the user's memory. Spilling only starts above the page
        // cache, so ordinary reads are unaffected.
        try execute("PRAGMA temp_store = FILE")
    }

    private func initializeSchema() throws {
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        // BEGIN IMMEDIATE is the cross-process migration lock. Version and column inspection must
        // happen after it is acquired: another process may have completed v1 -> v2 while this
        // connection was waiting, in which case this connection simply observes version 2.
        try transaction {
            let version = try int64Value("PRAGMA user_version")
            if version == 1 {
                try migrateVersionOneSchema()
            } else if version != Int64(Self.schemaVersion) {
                if trigramFTSAvailable {
                    try execute("DROP TABLE IF EXISTS conversation_documents_fts")
                }
                try execute("DROP TABLE IF EXISTS conversation_documents")
                try execute("DROP TABLE IF EXISTS conversation_sessions")
                try execute("DROP TABLE IF EXISTS conversation_catalog_state")
                try createBaseSchema()
                if version != 0 {
                    try execute(
                        "UPDATE conversation_catalog_state SET maintenance_pending = 1, "
                            + "one_time_compaction_pending = 1 WHERE singleton = 1"
                    )
                }
                try execute("PRAGMA user_version = \(Self.schemaVersion)")
            } else {
                try createBaseSchema()
            }
        }

        guard trigramFTSAvailable else {
            try markFTSState(dirty: true)
            return
        }
        let hadFTSTable = try int64Value(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master "
                + "WHERE type = 'table' AND name = 'conversation_documents_fts')"
        ) != 0
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS conversation_documents_fts USING fts5(
                search_text,
                content = 'conversation_documents',
                content_rowid = 'id',
                tokenize = 'trigram case_sensitive 0'
            )
            """
        )
        let dirty = try int64Value(
            "SELECT fts_dirty FROM conversation_catalog_state WHERE singleton = 1"
        ) != 0
        if !hadFTSTable || dirty {
            let documentCount = try int64Value(
                "SELECT COUNT(*) FROM conversation_documents"
            )
            // Opening the app must never synchronously rebuild a potentially multi-gigabyte FTS
            // table. An empty catalog is already complete; otherwise ordinary `instr` search is
            // the safe fallback until explicitly deferred maintenance gets idle time.
            try markFTSState(dirty: documentCount > 0)
            if documentCount > 0 { try markMaintenancePending() }
        }
    }

    private func migrateVersionOneSchema() throws {
        // Called only while initializeSchema() owns BEGIN IMMEDIATE. Keeping these reads beside
        // their ALTER statements prevents two processes from acting on the same stale schema.
        let hasMaintenancePending = try tableHasColumn(
            "maintenance_pending",
            in: "conversation_catalog_state"
        )
        let hasOneTimeCompactionPending = try tableHasColumn(
            "one_time_compaction_pending",
            in: "conversation_catalog_state"
        )
        if !hasMaintenancePending {
            try execute(
                "ALTER TABLE conversation_catalog_state ADD COLUMN maintenance_pending "
                    + "INTEGER NOT NULL DEFAULT 1 CHECK (maintenance_pending IN (0, 1))"
            )
        }
        if !hasOneTimeCompactionPending {
            try execute(
                "ALTER TABLE conversation_catalog_state ADD COLUMN "
                    + "one_time_compaction_pending INTEGER NOT NULL DEFAULT 1 "
                    + "CHECK (one_time_compaction_pending IN (0, 1))"
            )
        }
        try execute(
            "UPDATE conversation_catalog_state SET maintenance_pending = 1, "
                + "one_time_compaction_pending = 1 WHERE singleton = 1"
        )
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
        try createBaseSchema()
    }

    private func createBaseSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_catalog_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                generation INTEGER NOT NULL,
                fts_dirty INTEGER NOT NULL CHECK (fts_dirty IN (0, 1)),
                maintenance_pending INTEGER NOT NULL CHECK (maintenance_pending IN (0, 1)),
                one_time_compaction_pending INTEGER NOT NULL
                    CHECK (one_time_compaction_pending IN (0, 1))
            )
            """
        )
        try execute(
            "INSERT OR IGNORE INTO conversation_catalog_state("
                + "singleton, generation, fts_dirty, maintenance_pending, "
                + "one_time_compaction_pending) VALUES (1, 0, 0, 0, 0)"
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
                search_text TEXT NOT NULL,
                message_spans_json BLOB NOT NULL,
                UNIQUE(session_path, transcript_id)
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_documents_session_order "
                + "ON conversation_documents(session_path, sort_order, transcript_id)"
        )
    }

    private func probeTrigramFTS() -> Bool {
        try? execute("DROP TABLE IF EXISTS temp.ccbud_trigram_probe")
        do {
            try execute(
                "CREATE VIRTUAL TABLE temp.ccbud_trigram_probe "
                    + "USING fts5(value, tokenize = 'trigram case_sensitive 0')"
            )
            try execute("DROP TABLE temp.ccbud_trigram_probe")
            return true
        } catch {
            try? execute("DROP TABLE IF EXISTS temp.ccbud_trigram_probe")
            return false
        }
    }

    // MARK: - Queries

    private static let entrySelect = """
        SELECT source_path, scope, file_mtime, file_size, dependency_fingerprint,
               metadata_json, indexed_at
        FROM conversation_sessions
        """

    private static let documentSelect = """
        SELECT d.transcript_id, d.agent_type, d.sort_order, d.search_text, d.message_spans_json
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

    /// Deliberately selects no transcript text and imposes no ordering.
    ///
    /// `search_text` is the one unbounded column in the catalog, and an `ORDER BY` over it forces
    /// SQLite to hold every matching row at once — on a real library that is hundreds of megabytes
    /// for a single keystroke, and the caller re-sorts the candidates anyway. Rows here are small
    /// and fixed size, so the whole candidate set costs a few hundred kilobytes.
    private func queryCandidateReferences(
        query: String,
        scope: String?,
        source: HistorySource?,
        deleted: Bool?,
        useFTS: Bool,
        connection: OpaquePointer
    ) throws -> [ConversationIndexDocumentReference] {
        var bindings: [SQLiteValue] = []
        var conditions: [String] = []
        let from: String
        if useFTS {
            from = """
                FROM conversation_documents_fts
                JOIN conversation_documents d ON d.id = conversation_documents_fts.rowid
                JOIN conversation_sessions s ON s.source_path = d.session_path
                """
            let expression = query
                .split(whereSeparator: \.isWhitespace)
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND ")
            conditions.append("conversation_documents_fts MATCH ?")
            bindings.append(.text(expression))
        } else {
            from = """
                FROM conversation_documents d
                JOIN conversation_sessions s ON s.source_path = d.session_path
                """
            conditions.append("instr(lower(d.search_text), lower(?)) > 0")
            bindings.append(.text(query))
        }
        if let scope {
            conditions.append("s.scope = ?")
            bindings.append(.text(scope))
        }
        if let source {
            conditions.append("s.source = ?")
            bindings.append(.text(source.rawValue))
        }
        if let deleted {
            conditions.append("s.deleted = ?")
            bindings.append(.integer(deleted ? 1 : 0))
        }

        let sql = """
            SELECT d.id, d.session_path, d.transcript_id, d.agent_type, d.sort_order,
                   s.last_activity
            \(from)
            WHERE \(conditions.joined(separator: " AND "))
            """
        let statement = try prepare(sql, bindings: bindings, connection: connection)
        defer { sqlite3_finalize(statement) }
        var result: [ConversationIndexDocumentReference] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw sqliteError(
                    useFTS ? "search FTS" : "search documents",
                    status,
                    connection: connection
                )
            }
            guard let sessionPath = try? textColumn(statement, 1, field: "session_path"),
                  let transcriptID = try? textColumn(statement, 2, field: "transcript_id") else {
                continue
            }
            result.append(ConversationIndexDocumentReference(
                documentID: sqlite3_column_int64(statement, 0),
                sessionPath: sessionPath,
                transcriptID: transcriptID,
                agentType: optionalTextColumn(statement, 3),
                sortOrder: Int(sqlite3_column_int64(statement, 4)),
                lastActivity: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            ))
        }
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
                metadata = try metadataDecoder.decode(
                    HistorySessionMetadata.self,
                    from: metadataData
                )
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

    private func decodeDocument(
        _ statement: OpaquePointer,
        offset: Int32
    ) throws -> ConversationIndexDocument {
        let transcriptID = try textColumn(statement, offset, field: "transcript_id")
        let spanData = try blobColumn(statement, offset + 4, field: "message_spans_json")
        let spans: [ConversationIndexMessageSpan]
        do {
            spans = try metadataDecoder.decode([ConversationIndexMessageSpan].self, from: spanData)
        } catch {
            throw ConversationIndexDatabaseError.corruptRow(
                "message spans for \(transcriptID): \(error.localizedDescription)"
            )
        }
        return ConversationIndexDocument(
            transcriptID: transcriptID,
            agentType: optionalTextColumn(statement, offset + 1),
            sortOrder: Int(sqlite3_column_int64(statement, offset + 2)),
            text: try textColumn(statement, offset + 3, field: "search_text"),
            messageSpans: spans
        )
    }

    // MARK: - Mutations and validation

    private func removeDocuments(for path: String) throws {
        if trigramFTSAvailable {
            try execute(
                "DELETE FROM conversation_documents_fts WHERE rowid IN "
                    + "(SELECT id FROM conversation_documents WHERE session_path = ?)",
                bindings: [.text(path)]
            )
        }
        try execute(
            "DELETE FROM conversation_documents WHERE session_path = ?",
            bindings: [.text(path)]
        )
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

    private func markFTSState(dirty: Bool) throws {
        try execute(
            "UPDATE conversation_catalog_state SET fts_dirty = ? WHERE singleton = 1",
            bindings: [.integer(dirty ? 1 : 0)]
        )
    }

    private func shouldKeepFTSDirty() throws -> Bool {
        let wasDirty = try int64Value(
            "SELECT fts_dirty FROM conversation_catalog_state WHERE singleton = 1"
        ) != 0
        return !trigramFTSAvailable || wasDirty
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
        let values = try? file.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            // Capacity probes are advisory; unsupported filesystems should retain existing
            // cancellable behavior rather than permanently disabling maintenance.
            return true
        }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size])
            as? NSNumber)?.int64Value ?? 0
        let reserve = max(Int64(256 * 1_024 * 1_024), fileSize * 2)
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
        readLock.lock()
        defer { readLock.unlock() }
        guard let readConnection else {
            throw ConversationIndexDatabaseError.sqlite(
                operation: "open read connection",
                code: SQLITE_MISUSE,
                detail: "query-only connection is unavailable"
            )
        }
        return try body(readConnection)
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
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw sqliteError("execute statement", status)
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
