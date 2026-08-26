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

    func matches(_ identity: UsageHistoryFileIdentity) -> Bool {
        sizeBytes == identity.sizeBytes
            && abs(modifiedAt.timeIntervalSince(identity.modifiedAt)) < 0.000_5
    }
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
    static let version = 1

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var files: [String: UsageHistoryFileRecords] = [:]
    private var loaded = false
    private var dirty = false

    init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
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
        persistLocked()
        dirty = false
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
