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
    var userMetadata: ConversationUserMetadata = .init()
}

/// Durable, app-owned facts layered over a producer-derived conversation projection.
///
/// Optional fields distinguish "the user has not overridden this" from explicit values such as
/// restoring a producer-marked deleted session or clearing all tags. Stars and pins default to
/// false, matching Wake's `user_data` table.
struct ConversationUserMetadata: Equatable, Sendable {
    var title: String?
    var tags: [String]?
    var deleted: Bool?
    var starred: Bool
    var pinned: Bool
    var updatedAt: Date?

    init(
        title: String? = nil,
        tags: [String]? = nil,
        deleted: Bool? = nil,
        starred: Bool = false,
        pinned: Bool = false,
        updatedAt: Date? = nil
    ) {
        self.title = title
        self.tags = tags
        self.deleted = deleted
        self.starred = starred
        self.pinned = pinned
        self.updatedAt = updatedAt
    }

    func applying(to producer: HistorySessionMetadata) -> HistorySessionMetadata {
        var projected = producer
        if let title { projected.title = title }
        if let tags { projected.tags = tags }
        if let deleted { projected.deleted = deleted }
        projected.starred = starred
        projected.pinned = pinned
        return projected
    }
}

struct ConversationUserMetadataPatch: Equatable, Sendable {
    var title: String?
    var tags: [String]?
    var deleted: Bool?
    var starred: Bool?
    var pinned: Bool?

    init(
        title: String? = nil,
        tags: [String]? = nil,
        deleted: Bool? = nil,
        starred: Bool? = nil,
        pinned: Bool? = nil
    ) {
        self.title = title
        self.tags = tags
        self.deleted = deleted
        self.starred = starred
        self.pinned = pinned
    }

    var isEmpty: Bool {
        title == nil && tags == nil && deleted == nil && starred == nil && pinned == nil
    }
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
/// from detached tasks. Wake's split-connection model is preserved here: one lock/connection owns
/// mutations while an independent query-only connection keeps list/detail reads responsive during
/// indexing. WAL provides the snapshot boundary between them.
final class ConversationIndexDatabase: @unchecked Sendable {
    /// Version 3 adds non-rebuildable app-owned conversation metadata beside the derived catalog.
    /// Version 2 added bounded deferred-maintenance markers; version 1 could retain gigabytes of
    /// obsolete FTS segments after replacement.
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

    private static func validSessionLocation(
        _ location: ConversationSessionLocation
    ) throws -> ConversationSessionLocation {
        let raw = location.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.count <= 16_384,
              (raw as NSString).isAbsolutePath, !raw.utf8.contains(0) else {
            throw ConversationIndexDatabaseError.invalidRecord(
                "session location must be an absolute local path"
            )
        }
        return ConversationSessionLocation(
            source: location.source,
            path: normalizedPath(raw)
        )
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

    /// Applies one user action without touching the producer-derived session row. The user table
    /// intentionally has no foreign key: a temporary source disappearance or a full index rebuild
    /// must not erase stars, pins, titles, tags, or trash state.
    @discardableResult
    func updateUserMetadata(
        for file: URL,
        patch: ConversationUserMetadataPatch
    ) throws -> Int64 {
        try withLock {
            guard !patch.isEmpty else { return try currentGeneration() }
            let path = Self.normalizedPath(file)
            let normalizedTitle: String?
            if let title = patch.title {
                let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count <= 4_096 else {
                    throw ConversationIndexDatabaseError.invalidRecord("title is too long")
                }
                normalizedTitle = value.isEmpty ? nil : value
            } else {
                normalizedTitle = nil
            }

            let normalizedTags: [String]?
            if let tags = patch.tags {
                var values: [String] = []
                for raw in tags {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.count <= 512 else {
                        throw ConversationIndexDatabaseError.invalidRecord("tag is too long")
                    }
                    if !value.isEmpty, !values.contains(value) { values.append(value) }
                    guard values.count <= 256 else {
                        throw ConversationIndexDatabaseError.invalidRecord("too many tags")
                    }
                }
                normalizedTags = values
            } else {
                normalizedTags = nil
            }
            let tagsJSON = try normalizedTags.map { tags -> String in
                let data = try metadataEncoder.encode(tags)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ConversationIndexDatabaseError.invalidRecord("tags are not UTF-8")
                }
                return text
            }
            let updatedAt = Date()
            let generation = try transaction {
                try execute(
                    """
                    INSERT INTO conversation_user_metadata (
                        session_path, title, tags_json, deleted, starred, pinned, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_path) DO UPDATE SET
                        title = CASE WHEN ? THEN excluded.title
                                     ELSE conversation_user_metadata.title END,
                        tags_json = CASE WHEN ? THEN excluded.tags_json
                                        ELSE conversation_user_metadata.tags_json END,
                        deleted = CASE WHEN ? THEN excluded.deleted
                                      ELSE conversation_user_metadata.deleted END,
                        starred = CASE WHEN ? THEN excluded.starred
                                      ELSE conversation_user_metadata.starred END,
                        pinned = CASE WHEN ? THEN excluded.pinned
                                     ELSE conversation_user_metadata.pinned END,
                        updated_at = excluded.updated_at
                    """,
                    bindings: [
                        .text(path),
                        normalizedTitle.map(SQLiteValue.text) ?? .null,
                        tagsJSON.map(SQLiteValue.text) ?? .null,
                        patch.deleted.map { .integer($0 ? 1 : 0) } ?? .null,
                        .integer(patch.starred == true ? 1 : 0),
                        .integer(patch.pinned == true ? 1 : 0),
                        .double(updatedAt.timeIntervalSince1970),
                        .integer(patch.title == nil ? 0 : 1),
                        .integer(patch.tags == nil ? 0 : 1),
                        .integer(patch.deleted == nil ? 0 : 1),
                        .integer(patch.starred == nil ? 0 : 1),
                        .integer(patch.pinned == nil ? 0 : 1),
                    ]
                )
                return try advanceGeneration()
            }
            try hardenPermissions()
            return generation
        }
    }

    func userMetadata(for file: URL) throws -> ConversationUserMetadata {
        try withReadLock { connection in
            let statement = try prepare(
                """
                SELECT title, tags_json, deleted, starred, pinned, updated_at
                FROM conversation_user_metadata WHERE session_path = ? LIMIT 1
                """,
                bindings: [.text(Self.normalizedPath(file))],
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return .init() }
            guard status == SQLITE_ROW else {
                throw sqliteError("read user metadata", status, connection: connection)
            }
            return try decodeUserMetadata(statement, offset: 0)
        }
    }

    /// Session-location copies share one logical producer conversation even though the catalog
    /// and user metadata remain path-addressed. Mirror the most recently edited metadata row to
    /// every replica so an mtime-driven winner change cannot lose titles, tags, trash, stars, or
    /// pins. Imported library snapshots are excluded by discovery before this method is called.
    @discardableResult
    func synchronizeUserMetadata(for files: [URL]) throws -> Int64? {
        try withLock {
            let paths = Array(Set(files.map(Self.normalizedPath))).sorted()
            guard paths.count > 1 else { return nil }

            let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
            let statement = try prepare(
                """
                SELECT session_path, title, tags_json, deleted, starred, pinned, updated_at
                FROM conversation_user_metadata
                WHERE session_path IN (\(placeholders))
                ORDER BY updated_at DESC, session_path ASC
                """,
                bindings: paths.map(SQLiteValue.text)
            )
            defer { sqlite3_finalize(statement) }

            var rows: [String: ConversationUserMetadata] = [:]
            var canonical: ConversationUserMetadata?
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read replica user metadata", status)
                }
                let path = try textColumn(statement, 0, field: "session_path")
                let metadata = try decodeUserMetadata(statement, offset: 1)
                if canonical == nil { canonical = metadata }
                rows[path] = metadata
            }
            guard let canonical,
                  paths.contains(where: { rows[$0] != canonical }) else { return nil }

            let tagsJSON = try canonical.tags.map { tags -> String in
                let data = try metadataEncoder.encode(tags)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ConversationIndexDatabaseError.invalidRecord("tags are not UTF-8")
                }
                return text
            }
            let updatedAt = canonical.updatedAt ?? Date()
            let generation = try transaction {
                for path in paths where rows[path] != canonical {
                    try execute(
                        """
                        INSERT INTO conversation_user_metadata (
                            session_path, title, tags_json, deleted, starred, pinned, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(session_path) DO UPDATE SET
                            title = excluded.title,
                            tags_json = excluded.tags_json,
                            deleted = excluded.deleted,
                            starred = excluded.starred,
                            pinned = excluded.pinned,
                            updated_at = excluded.updated_at
                        """,
                        bindings: [
                            .text(path),
                            canonical.title.map(SQLiteValue.text) ?? .null,
                            tagsJSON.map(SQLiteValue.text) ?? .null,
                            canonical.deleted.map { .integer($0 ? 1 : 0) } ?? .null,
                            .integer(canonical.starred ? 1 : 0),
                            .integer(canonical.pinned ? 1 : 0),
                            .double(updatedAt.timeIntervalSince1970),
                        ]
                    )
                }
                return try advanceGeneration()
            }
            try hardenPermissions()
            return generation
        }
    }

    // MARK: - Session locations

    /// User-managed locations live beside stars and pins rather than in the rebuildable catalog.
    /// A full index reconciliation therefore cannot forget a custom root or re-enable a removed
    /// producer default.
    func sessionLocationOverrides() throws -> ConversationSessionLocationOverrides {
        try withReadLock { connection in
            let customStatement = try prepare(
                "SELECT source, path FROM conversation_custom_roots ORDER BY added_at, path",
                bindings: [],
                connection: connection
            )
            defer { sqlite3_finalize(customStatement) }
            var custom: [ConversationSessionLocation] = []
            while true {
                let status = sqlite3_step(customStatement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read custom session locations", status, connection: connection)
                }
                guard let source = try? textColumn(customStatement, 0, field: "source"),
                      let value = HistorySource(rawValue: source),
                      let path = try? textColumn(customStatement, 1, field: "path") else {
                    continue
                }
                custom.append(.init(source: value, path: path))
            }

            let removedStatement = try prepare(
                "SELECT source FROM conversation_removed_default_roots ORDER BY source",
                bindings: [],
                connection: connection
            )
            defer { sqlite3_finalize(removedStatement) }
            var removed = Set<HistorySource>()
            while true {
                let status = sqlite3_step(removedStatement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw sqliteError("read removed session locations", status, connection: connection)
                }
                if let raw = try? textColumn(removedStatement, 0, field: "source"),
                   let source = HistorySource(rawValue: raw) {
                    removed.insert(source)
                }
            }
            return ConversationSessionLocationOverrides(
                custom: custom,
                removedDefaults: removed
            )
        }
    }

    func addCustomSessionLocation(_ location: ConversationSessionLocation) throws {
        let normalized = try Self.validSessionLocation(location)
        try withLock {
            try execute(
                "INSERT OR IGNORE INTO conversation_custom_roots(source, path, added_at) "
                    + "VALUES (?, ?, ?)",
                bindings: [
                    .text(normalized.source.rawValue),
                    .text(normalized.path),
                    .double(Date().timeIntervalSince1970),
                ]
            )
            try hardenPermissions()
        }
    }

    /// Atomically edits either a custom row or a producer default. Editing a default suppresses
    /// that producer's canonical adapter and appends the replacement as a custom instance.
    func replaceSessionLocation(
        oldSource: HistorySource,
        oldCustomPath: String?,
        with replacement: ConversationSessionLocation
    ) throws {
        let normalized = try Self.validSessionLocation(replacement)
        try withLock {
            try transaction {
                if let oldCustomPath {
                    try execute(
                        "DELETE FROM conversation_custom_roots WHERE source = ? AND path = ?",
                        bindings: [
                            .text(oldSource.rawValue),
                            .text(Self.normalizedPath(oldCustomPath)),
                        ]
                    )
                } else {
                    try execute(
                        "INSERT OR IGNORE INTO conversation_removed_default_roots"
                            + "(source, removed_at) VALUES (?, ?)",
                        bindings: [
                            .text(oldSource.rawValue),
                            .double(Date().timeIntervalSince1970),
                        ]
                    )
                }
                try execute(
                    "INSERT OR IGNORE INTO conversation_custom_roots(source, path, added_at) "
                        + "VALUES (?, ?, ?)",
                    bindings: [
                        .text(normalized.source.rawValue),
                        .text(normalized.path),
                        .double(Date().timeIntervalSince1970),
                    ]
                )
            }
            try hardenPermissions()
        }
    }

    func removeCustomSessionLocation(source: HistorySource, path: String) throws {
        try withLock {
            try execute(
                "DELETE FROM conversation_custom_roots WHERE source = ? AND path = ?",
                bindings: [.text(source.rawValue), .text(Self.normalizedPath(path))]
            )
            try hardenPermissions()
        }
    }

    func removeDefaultSessionLocation(source: HistorySource) throws {
        try withLock {
            try execute(
                "INSERT OR IGNORE INTO conversation_removed_default_roots(source, removed_at) "
                    + "VALUES (?, ?)",
                bindings: [.text(source.rawValue), .double(Date().timeIntervalSince1970)]
            )
            try hardenPermissions()
        }
    }

    func restoreDefaultSessionLocations() throws {
        try withLock {
            try transaction {
                try execute("DELETE FROM conversation_custom_roots")
                try execute("DELETE FROM conversation_removed_default_roots")
            }
            try hardenPermissions()
        }
    }

    /// Replaces the complete user-managed location state in one transaction. The conversation
    /// store uses this only to roll back a mutation when a new runtime roster cannot be created;
    /// the previous repository can then safely resume because disk and runtime still agree.
    func replaceSessionLocationOverrides(
        _ overrides: ConversationSessionLocationOverrides
    ) throws {
        let custom = try overrides.custom.map(Self.validSessionLocation)
        try withLock {
            try transaction {
                try execute("DELETE FROM conversation_custom_roots")
                try execute("DELETE FROM conversation_removed_default_roots")
                let timestamp = Date().timeIntervalSince1970
                for (index, location) in custom.enumerated() {
                    try execute(
                        "INSERT INTO conversation_custom_roots(source, path, added_at) VALUES (?, ?, ?)",
                        bindings: [
                            .text(location.source.rawValue),
                            .text(location.path),
                            .double(timestamp + Double(index) / 1_000_000),
                        ]
                    )
                }
                for source in overrides.removedDefaults.sorted(by: {
                    $0.rawValue < $1.rawValue
                }) {
                    try execute(
                        "INSERT INTO conversation_removed_default_roots(source, removed_at) "
                            + "VALUES (?, ?)",
                        bindings: [.text(source.rawValue), .double(timestamp)]
                    )
                }
            }
            try hardenPermissions()
        }
    }

    /// Counts each physical session under the first matching `(source, data root)` pair. The
    /// boundary check is shared with adapter routing so `/sessions-old` cannot leak into
    /// `/sessions`, and a custom root nested beneath another root wins when callers order longest
    /// paths first.
    func sessionCounts(
        for locations: [(source: HistorySource, root: URL)]
    ) throws -> [Int] {
        try withReadLock { connection in
            let statement = try prepare(
                "SELECT source, source_path FROM conversation_sessions",
                bindings: [],
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            var result = Array(repeating: 0, count: locations.count)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else {
                    throw sqliteError("count session locations", status, connection: connection)
                }
                guard let raw = try? textColumn(statement, 0, field: "source"),
                      let source = HistorySource(rawValue: raw),
                      let path = try? textColumn(statement, 1, field: "source_path") else {
                    continue
                }
                if let index = locations.firstIndex(where: { location in
                    location.source == source
                        && ConversationSessionLocationLayout.pathOwns(
                            root: location.root.standardizedFileURL.path,
                            path: ConversationFileInspector.storageFile(
                                for: URL(fileURLWithPath: path)
                            ).path
                        )
                }) {
                    result[index] += 1
                }
            }
        }
    }

    /// Used only after an app-owned imported transcript was permanently removed.
    @discardableResult
    func removeUserMetadata(for file: URL) throws -> Int64 {
        try withLock {
            let generation = try transaction {
                try execute(
                    "DELETE FROM conversation_user_metadata WHERE session_path = ?",
                    bindings: [.text(Self.normalizedPath(file))]
                )
                guard sqlite3_changes(connection) > 0 else { return try currentGeneration() }
                return try advanceGeneration()
            }
            try hardenPermissions()
            return generation
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
            let sql = Self.entrySelect + " WHERE s.source_path = ? LIMIT 1"
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
        starred: Bool? = nil,
        limit: Int = 400,
        offset: Int = 0
    ) throws -> [ConversationIndexEntry] {
        try withReadLock { connection in
            guard limit > 0, offset >= 0 else { return [] }
            var conditions: [String] = []
            var bindings: [SQLiteValue] = []
            if let scope {
                conditions.append("s.scope = ?")
                bindings.append(.text(scope))
            }
            if let source {
                conditions.append("s.source = ?")
                bindings.append(.text(source.rawValue))
            }
            if let deleted {
                conditions.append("COALESCE(u.deleted, s.deleted) = ?")
                bindings.append(.integer(deleted ? 1 : 0))
            }
            if let starred {
                conditions.append("COALESCE(u.starred, 0) = ?")
                bindings.append(.integer(starred ? 1 : 0))
            }
            var sql = Self.entrySelect
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY COALESCE(u.pinned, 0) DESC, s.last_activity DESC, "
                + "s.created_at DESC, s.source_path DESC"
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
                SELECT s.scope, COUNT(*), MAX(s.last_activity)
                FROM conversation_sessions s
                LEFT JOIN conversation_user_metadata u ON u.session_path = s.source_path
                """
            var bindings: [SQLiteValue] = []
            if let deleted {
                sql += " WHERE COALESCE(u.deleted, s.deleted) = ?"
                bindings.append(.integer(deleted ? 1 : 0))
            }
            sql += " GROUP BY s.scope ORDER BY MAX(s.last_activity) DESC, s.scope"
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

    /// Returns documents which may contain a literal query. FTS safely narrows queries whose
    /// every whitespace-delimited segment is at least three characters; short queries and hosts
    /// without the trigram tokenizer use a bound `instr` expression instead.
    func candidateDocuments(
        for rawQuery: String,
        scope: String? = nil,
        source: HistorySource? = nil,
        deleted: Bool? = false,
        limit: Int? = nil,
        isCancelled: @escaping ConversationIndexScanCancellation = { Task.isCancelled }
    ) throws -> ConversationIndexCandidateBatch {
        try withReadLock { connection in
            let cancellation = SQLiteCancellationContext(isCancelled: isCancelled)
            try cancellation.check()
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, limit.map({ $0 > 0 }) ?? true else {
                return ConversationIndexCandidateBatch(documents: [], usedFallback: false)
            }

            let segments = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let ftsIsReady = try int64Value(
                "SELECT fts_dirty FROM conversation_catalog_state WHERE singleton = 1",
                connection: connection
            ) == 0
            try cancellation.check()
            let canUseFTS = trigramFTSAvailable
                && ftsIsReady
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
                            useFTS: true,
                            connection: connection,
                            cancellation: cancellation
                        ),
                        usedFallback: false
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A copied database can contain an FTS table unsupported by the current
                    // SQLite runtime. The ordinary document table is always a safe fallback.
                }
            }
            try cancellation.check()
            return ConversationIndexCandidateBatch(
                documents: try queryCandidateDocuments(
                    query: query,
                    scope: scope,
                    source: source,
                    deleted: deleted,
                    limit: limit,
                    useFTS: false,
                    connection: connection,
                    cancellation: cancellation
                ),
                usedFallback: true
            )
        }
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
                // Never run a full VACUUM automatically. It takes an exclusive writer and may
                // require a complete second copy of a large catalog. New catalogs already use
                // incremental auto-vacuum; legacy files simply transition to bounded cleanup.
                try execute("PRAGMA auto_vacuum = INCREMENTAL")
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
        try execute("PRAGMA temp_store = MEMORY")
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
            } else if version == 2 {
                try migrateVersionTwoSchema()
            } else if version == 3 {
                try migrateVersionThreeSchema()
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

    private func migrateVersionTwoSchema() throws {
        // The producer-derived rows and their FTS documents remain warm. `createBaseSchema`
        // installs only the new user table/indexes under the same cross-process migration lock.
        try createBaseSchema()
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func migrateVersionThreeSchema() throws {
        // Location configuration is non-rebuildable user data. Install the two additive tables
        // without touching warm catalog rows, FTS documents, stars, pins, tags, or trash state.
        try createBaseSchema()
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
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
            CREATE TABLE IF NOT EXISTS conversation_user_metadata (
                session_path TEXT PRIMARY KEY NOT NULL,
                title TEXT,
                tags_json TEXT,
                deleted INTEGER CHECK (deleted IS NULL OR deleted IN (0, 1)),
                starred INTEGER NOT NULL DEFAULT 0 CHECK (starred IN (0, 1)),
                pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
                updated_at REAL NOT NULL
            ) WITHOUT ROWID
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_user_metadata_starred "
                + "ON conversation_user_metadata(starred, updated_at DESC)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS conversation_user_metadata_pinned "
                + "ON conversation_user_metadata(pinned, updated_at DESC)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_custom_roots (
                source TEXT NOT NULL,
                path TEXT NOT NULL,
                added_at REAL NOT NULL,
                PRIMARY KEY (source, path)
            ) WITHOUT ROWID
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversation_removed_default_roots (
                source TEXT PRIMARY KEY NOT NULL,
                removed_at REAL NOT NULL
            ) WITHOUT ROWID
            """
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
        SELECT s.source_path, s.scope, s.file_mtime, s.file_size, s.dependency_fingerprint,
               s.metadata_json, s.indexed_at, u.title, u.tags_json, u.deleted,
               COALESCE(u.starred, 0), COALESCE(u.pinned, 0), u.updated_at
        FROM conversation_sessions s
        LEFT JOIN conversation_user_metadata u ON u.session_path = s.source_path
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

    private func queryCandidateDocuments(
        query: String,
        scope: String?,
        source: HistorySource?,
        deleted: Bool?,
        limit: Int?,
        useFTS: Bool,
        connection: OpaquePointer,
        cancellation: SQLiteCancellationContext
    ) throws -> [ConversationIndexDocumentCandidate] {
        var bindings: [SQLiteValue] = []
        var conditions: [String] = []
        let from: String
        if useFTS {
            from = """
                FROM conversation_documents_fts
                JOIN conversation_documents d ON d.id = conversation_documents_fts.rowid
                JOIN conversation_sessions s ON s.source_path = d.session_path
                LEFT JOIN conversation_user_metadata u ON u.session_path = s.source_path
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
                LEFT JOIN conversation_user_metadata u ON u.session_path = s.source_path
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
            conditions.append("COALESCE(u.deleted, s.deleted) = ?")
            bindings.append(.integer(deleted ? 1 : 0))
        }

        let sql = """
            SELECT s.source_path, s.scope, s.file_mtime, s.file_size,
                   s.dependency_fingerprint, s.metadata_json, s.indexed_at,
                   u.title, u.tags_json, u.deleted, COALESCE(u.starred, 0),
                   COALESCE(u.pinned, 0), u.updated_at,
                   d.transcript_id, d.agent_type, d.sort_order, d.search_text,
                   d.message_spans_json
            \(from)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY COALESCE(u.pinned, 0) DESC, s.last_activity DESC,
                     d.sort_order, d.transcript_id
            """
        let statement = try prepare(sql, bindings: bindings, connection: connection)
        defer { sqlite3_finalize(statement) }
        return try withCancellableSQLiteQuery(
            connection: connection,
            cancellation: cancellation
        ) {
            var result: [ConversationIndexDocumentCandidate] = []
            while true {
                try cancellation.check()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                if status != SQLITE_ROW, cancellation.wasCancelled {
                    throw CancellationError()
                }
                guard status == SQLITE_ROW else {
                    throw sqliteError(
                        useFTS ? "search FTS" : "search documents",
                        status,
                        connection: connection
                    )
                }
                do {
                    result.append(ConversationIndexDocumentCandidate(
                        entry: try decodeEntry(statement, offset: 0),
                        document: try decodeDocument(statement, offset: 13)
                    ))
                    if let limit, result.count == limit { return result }
                } catch ConversationIndexDatabaseError.corruptRow(_) {
                    continue
                }
            }
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
        let producerMetadata: HistorySessionMetadata
        do {
            producerMetadata = try metadataDecoder.decode(HistorySessionMetadata.self, from: metadataData)
        } catch {
            throw ConversationIndexDatabaseError.corruptRow(
                "metadata JSON for \(path): \(error.localizedDescription)"
            )
        }
        let userMetadata = try decodeUserMetadata(statement, offset: offset + 7)
        return ConversationIndexEntry(
            sourcePath: path,
            metadata: userMetadata.applying(to: producerMetadata),
            scope: scope,
            fingerprint: ConversationIndexFingerprint(
                modificationTime: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, offset + 2)
                ),
                sizeBytes: UInt64(fileSize),
                dependencyFingerprint: optionalTextColumn(statement, offset + 4)
            ),
            indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 6)),
            userMetadata: userMetadata
        )
    }

    private func decodeUserMetadata(
        _ statement: OpaquePointer,
        offset: Int32
    ) throws -> ConversationUserMetadata {
        let tags: [String]?
        if let tagsJSON = optionalTextColumn(statement, offset + 1) {
            guard let data = tagsJSON.data(using: .utf8) else {
                throw ConversationIndexDatabaseError.corruptRow("user tags are not UTF-8")
            }
            do {
                tags = try metadataDecoder.decode([String].self, from: data)
            } catch {
                throw ConversationIndexDatabaseError.corruptRow(
                    "user tags JSON: \(error.localizedDescription)"
                )
            }
        } else {
            tags = nil
        }
        let deleted: Bool?
        if sqlite3_column_type(statement, offset + 2) == SQLITE_NULL {
            deleted = nil
        } else {
            deleted = sqlite3_column_int64(statement, offset + 2) != 0
        }
        let updatedAt: Date?
        if sqlite3_column_type(statement, offset + 5) == SQLITE_NULL {
            updatedAt = nil
        } else {
            updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 5))
        }
        return ConversationUserMetadata(
            title: optionalTextColumn(statement, offset),
            tags: tags,
            deleted: deleted,
            starred: sqlite3_column_int64(statement, offset + 3) != 0,
            pinned: sqlite3_column_int64(statement, offset + 4) != 0,
            updatedAt: updatedAt
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

    /// A cancelled Swift task must stop SQLite while it is scanning or sorting, not only after
    /// `sqlite3_step` eventually returns. The progress handler covers ordinary VM execution and
    /// the monitor supplies SQLite's documented cross-thread interruption path for long built-ins.
    private func withCancellableSQLiteQuery<T>(
        connection: OpaquePointer,
        cancellation: SQLiteCancellationContext,
        _ body: () throws -> T
    ) throws -> T {
        try cancellation.check()
        let pointer = Unmanaged.passUnretained(cancellation).toOpaque()
        sqlite3_progress_handler(
            connection,
            1_000,
            Self.maintenanceProgressHandler,
            pointer
        )
        defer { sqlite3_progress_handler(connection, 0, nil, nil) }
        do {
            let result = try withSQLiteInterruptionMonitor(
                connection: connection,
                cancellation: cancellation,
                body
            )
            try cancellation.check()
            return result
        } catch {
            if cancellation.wasCancelled { throw CancellationError() }
            throw error
        }
    }

    private func withSQLiteInterruptionMonitor<T>(
        connection interruptedConnection: OpaquePointer? = nil,
        cancellation: SQLiteCancellationContext,
        _ body: () throws -> T
    ) throws -> T {
        let operationFinished = DispatchSemaphore(value: 0)
        let monitorFinished = DispatchSemaphore(value: 0)
        let connection = interruptedConnection ?? self.connection
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
