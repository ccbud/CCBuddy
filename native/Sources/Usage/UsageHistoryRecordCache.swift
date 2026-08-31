import Foundation

/// The usage records parsed out of one transcript, keyed by that file's identity on disk.
///
/// Only the assistant turns that reported token usage survive parsing, so this is orders of
/// magnitude smaller than the transcript it came from: a library measured at 14 GB reduces to a
/// few megabytes of records. Caching *records* rather than aggregated day buckets is what keeps
/// the result identical — deduplication runs across files (a message appears in both a parent
/// transcript and its subagent's), so it has to see every record, not per-file subtotals.
struct UsageHistoryFileRecords: Codable, Equatable, Sendable {
    var modifiedAt: Date
    var sizeBytes: Int64
    var claude: [UsageHistoryCachedClaudeRecord]
    var codex: [UsageHistoryCachedCodexEvent]
    /// Byte offset of the last newline-terminated line these records cover. When the file has
    /// only grown past this point and the bytes just before it are untouched, the scanner parses
    /// the appended region alone instead of re-reading the file — the difference between a few
    /// kilobytes and tens of megabytes for every append a live agent makes.
    var parsedBytes: Int64? = nil
    /// FNV-1a over the last 256 bytes before `parsedBytes`; the append-only proof.
    var tailChecksum: UInt64? = nil
    /// Codex's parser carries state across lines (current model, running totals, replay skip),
    /// so continuing mid-file requires resuming exactly where the previous parse stopped.
    var codexCarry: UsageHistoryCodexParseCarry? = nil

    func matches(_ identity: UsageHistoryFileIdentity) -> Bool {
        sizeBytes == identity.sizeBytes
            && abs(modifiedAt.timeIntervalSince(identity.modifiedAt)) < 0.000_5
    }
}

struct UsageHistoryCodexParseCarry: Codable, Equatable, Sendable {
    var skippingReplay: Bool
    var replaySecond: String?
    var currentModel: String?
    var previousTotals: UsageHistoryCachedCodexUsage?
}

struct UsageHistoryCachedCodexUsage: Codable, Equatable, Sendable {
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int
    var total: Int
}

struct UsageHistoryFileIdentity: Equatable, Sendable {
    var modifiedAt: Date
    var sizeBytes: Int64

    /// Nil for anything that is not an ordinary readable file; such a path is simply parsed.
    static func of(_ file: URL, fileManager: FileManager = .default) -> UsageHistoryFileIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
        return .init(modifiedAt: modifiedAt, sizeBytes: size)
    }
}

struct UsageHistoryCachedClaudeRecord: Codable, Equatable, Sendable {
    var id: String?
    var requestID: String?
    var sidechain: Bool
    var timestamp: Date
    var model: String?
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreation: Int
}

struct UsageHistoryCachedCodexEvent: Codable, Equatable, Sendable {
    var timestamp: Date
    var model: String
    var input: Int
    var cached: Int
    var output: Int
    var reasoning: Int
    var total: Int
}

/// A file-backed store of the above, so a relaunch re-reads only what changed.
///
/// It is a cache in the strict sense: losing or corrupting it costs a full rescan and nothing else,
/// so every failure path here is silent and falls back to parsing.
final class UsageHistoryRecordCache: @unchecked Sendable {
    private struct Document: Codable {
        var version: Int
        var files: [String: UsageHistoryFileRecords]
    }

    /// Bump when the parsed shape changes; old entries are then ignored rather than misread.
    /// Version 2 added the append-only continuation fields (`parsedBytes`, `tailChecksum`,
    /// `codexCarry`); version-1 entries lack them and would silently force full reparses forever.
    static let version = 2

    /// The serialized cache is tens of megabytes on a long-lived library, and `commit` used to
    /// rewrite all of it after every scan — while a live agent kept transcripts changing, that was
    /// a multi-megabyte encode and write several times a minute for data that is disposable by
    /// design. Persisting is therefore paced; an unpersisted window costs only re-parsing the few
    /// files that changed inside it on the next launch. `flush()` covers orderly shutdown.
    static let minimumPersistInterval: TimeInterval = 60

    private let file: URL
    private let fileManager: FileManager
    private let minimumPersistInterval: TimeInterval
    private let lock = NSLock()
    private var files: [String: UsageHistoryFileRecords] = [:]
    private var loaded = false
    private var dirty = false
    private var lastPersistedAt: Date?

    init(
        file: URL,
        fileManager: FileManager = .default,
        minimumPersistInterval: TimeInterval = UsageHistoryRecordCache.minimumPersistInterval
    ) {
        self.file = file
        self.fileManager = fileManager
        self.minimumPersistInterval = max(0, minimumPersistInterval)
    }

    convenience init?(applicationDataRoot: URL?, fileManager: FileManager = .default) {
        guard let applicationDataRoot else { return nil }
        self.init(
            file: applicationDataRoot.appendingPathComponent("usage-records-v1.json"),
            fileManager: fileManager
        )
    }

    func records(for file: URL, identity: UsageHistoryFileIdentity) -> UsageHistoryFileRecords? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard let cached = files[Self.key(for: file)], cached.matches(identity) else { return nil }
        return cached
    }

    /// The entry regardless of whether it still matches the file on disk. Callers use this to
    /// attempt an append-only continuation from `parsedBytes` before falling back to a full parse.
    func entry(for file: URL) -> UsageHistoryFileRecords? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        return files[Self.key(for: file)]
    }

    func store(_ records: UsageHistoryFileRecords, for file: URL) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        files[Self.key(for: file)] = records
        dirty = true
    }

    /// Drops entries for transcripts that no longer exist, so a long-lived cache cannot grow
    /// without bound as sessions are deleted.
    func commit(retaining visited: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        let before = files.count
        files = files.filter { visited.contains($0.key) }
        if files.count != before { dirty = true }
        guard dirty else { return }
        if let lastPersistedAt,
           Date().timeIntervalSince(lastPersistedAt) < minimumPersistInterval {
            return
        }
        persistLocked()
        dirty = false
        lastPersistedAt = Date()
    }

    /// Persists any deferred state immediately; called on orderly shutdown.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard loaded, dirty else { return }
        persistLocked()
        dirty = false
        lastPersistedAt = Date()
    }

    static func key(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    // MARK: - Storage

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.version else { return }
        files = document.files
    }

    private func persistLocked() {
        let document = Document(version: Self.version, files: files)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The cache is disposable, so a partial write is worse than no write: replace atomically
        // and leave the previous contents in place if that fails.
        try? data.write(to: file, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
