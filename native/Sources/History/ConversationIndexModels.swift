import Foundation
/// The source-file facts which decide whether a conversation must be parsed again.
///
/// `dependencyFingerprint` covers producer-owned sidecars which can change a parsed session
/// without changing the main transcript (for example Qoder metadata or a SQLite WAL).
struct ConversationIndexFingerprint: Codable, Equatable, Sendable {
    var modificationTime: Date
    var sizeBytes: UInt64
    var dependencyFingerprint: String?
    /// Evidence for the immutable body pack, independent of Codex's shared annotation sidecar.
    /// Absent in older catalogs and in metadata-only rows which have never had a complete body.
    var searchContentFingerprint: String?

    init(
        modificationTime: Date,
        sizeBytes: UInt64,
        dependencyFingerprint: String? = nil,
        searchContentFingerprint: String? = nil
    ) {
        self.modificationTime = modificationTime
        self.sizeBytes = sizeBytes
        self.dependencyFingerprint = dependencyFingerprint
        self.searchContentFingerprint = searchContentFingerprint
    }

    /// Auxiliary body evidence does not make an otherwise unchanged producer revision dirty.
    func matchesSourceRevision(_ other: Self) -> Bool {
        modificationTime == other.modificationTime && sizeBytes == other.sizeBytes
            && dependencyFingerprint == other.dependencyFingerprint
    }

    static func contentFingerprint(
        manifest: ConversationDependencyManifest, snapshot: ConversationDependencySnapshot
    ) -> String {
        // Only Codex's app-owned annotation sidecar is known not to affect normalized messages.
        // All other providers/dependencies remain conservative, including child files and WALs.
        let stamps = snapshot.stamps.filter { manifest.source != .codex || $0.role != .customMetadata }
        return "body-v1:\(manifest.source.rawValue):"
            + ConversationDependencySnapshot(stamps: stamps).fingerprint
    }

    static func hasSameContentOwner(_ lhs: HistorySessionMetadata, _ rhs: HistorySessionMetadata) -> Bool {
        lhs.file.standardizedFileURL == rhs.file.standardizedFileURL && lhs.dirID == rhs.dirID
            && lhs.source == rhs.source && lhs.sessionID == rhs.sessionID
            && lhs.threadID == rhs.threadID && lhs.rootSessionID == rhs.rootSessionID
            && lhs.parentThreadID == rhs.parentThreadID && lhs.forkedFromID == rhs.forkedFromID
            && lhs.isSubagent == rhs.isSubagent
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
struct ConversationIndexEntry: Codable, Equatable, Sendable {
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
    /// Distinguishes a rebuilt/copied catalog even if its generation and numeric IDs coincide.
    var catalogIdentity: String? = nil
}

struct ConversationIndexCandidateReferenceBatch: Equatable, Sendable {
    var references: [ConversationIndexDocumentReference]
    var usedFallback: Bool
}

/// A cache validation and its optional document are read from one committed file snapshot.
enum ConversationIndexRefinementRead: Sendable {
    case unchanged(generation: Int64)
    case document(generation: Int64, ConversationIndexDocument)
}

struct ConversationIndexReconciliation: Equatable, Sendable {
    var removedPaths: [String]
    var generation: Int64
}

enum ConversationCatalogError: LocalizedError, Sendable {
    case staleRevision
    case invalidRecord(String)
    case unsafeEmptyReconciliation(String)
    case corruptRow(String)

    var errorDescription: String? {
        switch self {
        case .staleRevision:
            return "Conversation index changed during search; retry the query."
        case .invalidRecord(let detail):
            return "Invalid conversation index record: \(detail)"
        case .unsafeEmptyReconciliation(let scope):
            return "Refusing an empty conversation-index reconciliation for scope \(scope)"
        case .corruptRow(let detail):
            return "Conversation index contains an invalid row: \(detail)"
        }
    }
}
