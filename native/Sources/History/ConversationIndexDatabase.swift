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
/// from detached tasks. A private lock serializes the single SQLite connection, while WAL keeps
/// independent diagnostic/read connections from blocking normal writes.
final class ConversationIndexDatabase: @unchecked Sendable {
    static let schemaVersion: Int32 = 1

    let file: URL

    private let lock = NSLock()
    private let connection: OpaquePointer
    private let metadataEncoder: JSONEncoder
    private let metadataDecoder: JSONDecoder
    private var trigramFTSAvailable = false

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
            try hardenPermissions()
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    convenience init(url: URL) throws {
        try self.init(file: url)
    }

    deinit {
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
        try withLock { try currentGeneration() }
    }

    func hasRows() throws -> Bool {
        try withLock {
            try int64Value("SELECT EXISTS(SELECT 1 FROM conversation_sessions LIMIT 1)") != 0
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
                try markFTSState(dirty: !trigramFTSAvailable)
                return try advanceGeneration()
            }
            try hardenPermissions()
            return result
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
                    try markFTSState(dirty: !trigramFTSAvailable)
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
                try markFTSState(dirty: !trigramFTSAvailable)
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
        try withLock {
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

            let statement = try prepare(sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }
            var result: [String: ConversationIndexFingerprint] = [:]
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError("read fingerprints", status) }
                let path = try textColumn(statement, 0, field: "source_path")
                let size = sqlite3_column_int64(statement, 2)
                guard size >= 0 else {
                    throw ConversationIndexDatabaseError.corruptRow("negative file size for \(path)")
                }
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
        try withLock {
            let sql = Self.entrySelect + " WHERE source_path = ? LIMIT 1"
            let statement = try prepare(sql, bindings: [.text(Self.normalizedPath(path))])
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw sqliteError("read session", status) }
            return try decodeEntry(statement, offset: 0)
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
        try withLock {
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
            if limit != .max {
                sql += " LIMIT ? OFFSET ?"
                bindings.append(.integer(Int64(limit)))
                bindings.append(.integer(Int64(offset)))
            }
            return try queryEntries(sql, bindings: bindings)
        }
    }

    func scopeSummaries(deleted: Bool? = false) throws -> [ConversationIndexScopeSummary] {
        try withLock {
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
            let statement = try prepare(sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }
            var result: [ConversationIndexScopeSummary] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError("read scope summaries", status) }
                result.append(ConversationIndexScopeSummary(
                    scope: try textColumn(statement, 0, field: "scope"),
                    sessionCount: Int(sqlite3_column_int64(statement, 1)),
                    lastActivity: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ))
            }
        }
    }

    func documents(for file: URL) throws -> [ConversationIndexDocument] {
        try documents(forPath: Self.normalizedPath(file))
    }

    func documents(forPath path: String) throws -> [ConversationIndexDocument] {
        try withLock {
            let statement = try prepare(
                Self.documentSelect
                    + " WHERE d.session_path = ? ORDER BY d.sort_order, d.transcript_id",
                bindings: [.text(Self.normalizedPath(path))]
            )
            defer { sqlite3_finalize(statement) }
            var result: [ConversationIndexDocument] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError("read documents", status) }
                result.append(try decodeDocument(statement, offset: 0))
            }
        }
    }

    /// Returns documents which may contain a literal query. FTS safely narrows queries whose
    /// every whitespace-delimited segment is at least three characters; short queries and hosts
    /// without the trigram tokenizer use a bound `instr` expression instead.
    func candidateDocuments(
        for rawQuery: String,
        scope: String? = nil,
        source: HistorySource? = nil,
        deleted: Bool? = false,
        limit: Int? = nil
    ) throws -> ConversationIndexCandidateBatch {
        try withLock {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, limit.map({ $0 > 0 }) ?? true else {
                return ConversationIndexCandidateBatch(documents: [], usedFallback: false)
            }

            let segments = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let canUseFTS = trigramFTSAvailable
                && !segments.isEmpty
                && segments.allSatisfy { $0.count >= 3 }
                && !query.unicodeScalars.contains(where: { $0.value == 0 })
            if canUseFTS {
                do {
                    return ConversationIndexCandidateBatch(
                        documents: try queryCandidateDocuments(
                            query: query,
                            scope: scope,
                            source: source,
                            deleted: deleted,
                            limit: limit,
                            useFTS: true
                        ),
                        usedFallback: false
                    )
                } catch {
                    // A copied database can contain an FTS table unsupported by the current
                    // SQLite runtime. The ordinary document table is always a safe fallback.
                }
            }
            return ConversationIndexCandidateBatch(
                documents: try queryCandidateDocuments(
                    query: query,
                    scope: scope,
                    source: source,
                    deleted: deleted,
                    limit: limit,
                    useFTS: false
                ),
                usedFallback: true
            )
        }
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
        try execute("PRAGMA temp_store = MEMORY")
    }

    private func initializeSchema() throws {
        let version = try int64Value("PRAGMA user_version")
        if version != Int64(Self.schemaVersion) {
            try transaction {
                if trigramFTSAvailable {
                    try execute("DROP TABLE IF EXISTS conversation_documents_fts")
                }
                try execute("DROP TABLE IF EXISTS conversation_documents")
                try execute("DROP TABLE IF EXISTS conversation_sessions")
                try execute("DROP TABLE IF EXISTS conversation_catalog_state")
                try createBaseSchema()
                try execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        } else {
            try createBaseSchema()
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
            try transaction {
                try execute(
                    "INSERT INTO conversation_documents_fts(conversation_documents_fts) "
                        + "VALUES ('rebuild')"
                )
                try markFTSState(dirty: false)
            }
        }
    }

    private func createBaseSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_catalog_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                generation INTEGER NOT NULL,
                fts_dirty INTEGER NOT NULL CHECK (fts_dirty IN (0, 1))
            )
            """
        )
        try execute(
            "INSERT OR IGNORE INTO conversation_catalog_state(singleton, generation, fts_dirty) "
                + "VALUES (1, 0, 0)"
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
        bindings: [SQLiteValue]
    ) throws -> [ConversationIndexEntry] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [ConversationIndexEntry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw sqliteError("read sessions", status) }
            result.append(try decodeEntry(statement, offset: 0))
        }
    }

    private func queryCandidateDocuments(
        query: String,
        scope: String?,
        source: HistorySource?,
        deleted: Bool?,
        limit: Int?,
        useFTS: Bool
    ) throws -> [ConversationIndexDocumentCandidate] {
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

        var sql = """
            SELECT s.source_path, s.scope, s.file_mtime, s.file_size,
                   s.dependency_fingerprint, s.metadata_json, s.indexed_at,
                   d.transcript_id, d.agent_type, d.sort_order, d.search_text,
                   d.message_spans_json
            \(from)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.last_activity DESC, d.sort_order, d.transcript_id
            """
        if let limit {
            sql += " LIMIT ?"
            bindings.append(.integer(Int64(limit)))
        }

        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [ConversationIndexDocumentCandidate] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw sqliteError(useFTS ? "search FTS" : "search documents", status)
            }
            result.append(ConversationIndexDocumentCandidate(
                entry: try decodeEntry(statement, offset: 0),
                document: try decodeDocument(statement, offset: 7)
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
        let metadataData = try blobColumn(statement, offset + 5, field: "metadata_json")
        let metadata: HistorySessionMetadata
        do {
            metadata = try metadataDecoder.decode(HistorySessionMetadata.self, from: metadataData)
        } catch {
            throw ConversationIndexDatabaseError.corruptRow(
                "metadata JSON for \(path): \(error.localizedDescription)"
            )
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
            indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 6))
        )
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

    // MARK: - SQLite primitives

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

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw sqliteError("execute statement", status)
        }
    }

    private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw sqliteError("prepare statement", status)
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
        bindings: [SQLiteValue] = []
    ) throws -> Int64 {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { throw sqliteError("read integer", status) }
        return sqlite3_column_int64(statement, 0)
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

    private func sqliteError(_ operation: String, _ status: Int32) -> Error {
        ConversationIndexDatabaseError.sqlite(
            operation: operation,
            code: status,
            detail: String(cString: sqlite3_errmsg(connection))
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

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
