import Darwin
import CryptoKit
import Foundation

/// Observable measurements of candidate generation, without retaining the user's query.
struct ConversationSearchDiagnostics: Equatable, Sendable {
    var engine: String = "SQLite"
    var indexedDocuments: Int = 0
    var candidateCount: Int = 0
    var queryMilliseconds: Double = 0
    var incrementallyIndexedDocuments: Int = 0
    var usedFallback: Bool = false
    var cumulativeNormalizationMilliseconds: Double = 0
    var cumulativeTrigramBuildMilliseconds: Double = 0
    var restoredFromCache: Bool = false
}

/// The catalog owns this object and serializes all access with its read lock.
/// tgrep keeps a bounded live overlay and memory-mapped postings, never transcript copies.
final class TgrepSearchIndex {
    struct Stamp: Equatable {
        let path: String
        let transcript: String
        let indexedAt: Double

        var fingerprint: String {
            let identity = path + "\u{0}" + transcript + "\u{0}" + String(indexedAt.bitPattern)
            return Data(SHA256.hash(data: Data(identity.utf8))).base64EncodedString()
        }
    }

    private struct Manifest: Codable {
        var normalizationVersion: String
        var fingerprints: [Int64: String]
    }

    enum Failure: Error { case unavailable, operationFailed }

    private let symbols: Symbols
    private let handle: UnsafeMutableRawPointer
    private(set) var revision: Int64?
    private var fingerprints: [Int64: String] = [:]
    var documentCount: Int { fingerprints.count }
    private(set) var restoredFromCache = false
    private(set) var normalizationMilliseconds: Double = 0
    private(set) var trigramBuildMilliseconds: Double = 0

    static var isAvailable: Bool { Symbols.shared != nil }

    /// tgrep indexes byte trigrams. One CJK character already supplies three
    /// UTF-8 bytes, so inheriting FTS's three-character gate wastes the index
    /// for common Chinese/Japanese searches such as 搜索, 工具, and 設定.
    static func canIndex(_ query: String) -> Bool { normalized(query).utf8.count >= 3 }

    init(cacheDirectory: URL? = nil) throws {
        guard let symbols = Symbols.shared else { throw Failure.unavailable }
        let created: UnsafeMutableRawPointer?
        if let cacheDirectory {
            let path = Array(cacheDirectory.path.utf8)
            created = path.withUnsafeBufferPointer { symbols.createPersistent($0.baseAddress!, $0.count) }
        } else {
            created = symbols.create()
        }
        guard let handle = created else { throw Failure.unavailable }
        self.symbols = symbols
        self.handle = handle
        let size = symbols.copyManifest(handle, nil, 0)
        if size > 0, size <= 16 * 1_024 * 1_024 {
            var bytes = [UInt8](repeating: 0, count: size)
            let copied = bytes.withUnsafeMutableBufferPointer { symbols.copyManifest(handle, $0.baseAddress, $0.count) }
            if copied == size,
               let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(bytes)),
               manifest.normalizationVersion == Self.normalizationVersion {
                fingerprints = manifest.fingerprints
                restoredFromCache = true
            }
        }
        // Always reconcile lightweight identities on the first query after an
        // open. A copied/replaced SQLite database can reuse a generation number.
    }

    deinit { symbols.destroy(handle) }

    func contains(id: Int64, stamp: Stamp) -> Bool { fingerprints[id] == stamp.fingerprint }

    func upsert(id: Int64, text: String) throws {
        let normalizationStart = ContinuousClock.now
        let bytes = Array(Self.normalized(text).utf8)
        normalizationMilliseconds += Self.milliseconds(since: normalizationStart)
        // An empty Array can expose a nil pointer. A real sentinel keeps the ABI
        // valid while length zero correctly indexes an empty document.
        let buffer = bytes.isEmpty ? [UInt8(0)] : bytes
        let indexStart = ContinuousClock.now
        let status = buffer.withUnsafeBufferPointer {
            symbols.upsert(handle, id, $0.baseAddress!, bytes.count)
        }
        trigramBuildMilliseconds += Self.milliseconds(since: indexStart)
        guard status == 0 else { throw Failure.operationFailed }
    }

    func commit(revision: Int64, stamps: [Int64: Stamp]) throws {
        let nextFingerprints = stamps.mapValues(\.fingerprint)
        if nextFingerprints == fingerprints, self.revision != nil || restoredFromCache {
            // Reopen still checks every lightweight SQLite identity, but an
            // unchanged sealed index needs neither a merge nor a second full
            // integrity scan and identical checkpoint publication.
            self.revision = revision
            return
        }
        let ids = Array(stamps.keys)
        let indexStart = ContinuousClock.now
        let status = ids.withUnsafeBufferPointer {
            symbols.retain(handle, $0.baseAddress, $0.count)
        }
        trigramBuildMilliseconds += Self.milliseconds(since: indexStart)
        guard status == 0 else { throw Failure.operationFailed }
        fingerprints = nextFingerprints
        let data = try JSONEncoder().encode(Manifest(
            normalizationVersion: Self.normalizationVersion, fingerprints: fingerprints
        ))
        let persisted = data.withUnsafeBytes {
            symbols.persist(handle, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count)
        }
        guard persisted == 0 else { throw Failure.operationFailed }
        self.revision = revision
    }

    func candidates(for query: String) throws -> [Int64] {
        let bytes = Array(Self.normalized(query).utf8)
        guard !bytes.isEmpty else { return [] }
        // A normal query fits in one call. A broad query retries with exactly the
        // required capacity, bounded by the number of synchronized documents.
        var output = [Int64](repeating: 0, count: min(256, max(1, documentCount)))
        func execute(_ output: inout [Int64]) -> Int {
            bytes.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { result in
                    symbols.query(handle, input.baseAddress!, input.count, result.baseAddress, result.count)
                }
            }
        }
        var count = execute(&output)
        guard count >= 0, count <= documentCount else { throw Failure.operationFailed }
        if count > output.count {
            output = [Int64](repeating: 0, count: count)
            count = execute(&output)
        }
        guard count >= 0, count <= output.count else { throw Failure.operationFailed }
        return Array(output.prefix(count))
    }

    /// Foundation's case folding covers expansions (ß → ss), non-ASCII case,
    /// and canonical equivalence. The final hit still uses the original text,
    /// preserving original UTF-16 message anchors, snippets, and occurrence counts.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    private static var normalizationVersion: String {
        "foundation-casefold-nfc-v1:" + ProcessInfo.processInfo.operatingSystemVersionString
    }

    private final class Symbols: @unchecked Sendable {
        typealias Version = @convention(c) () -> UInt32
        typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
        typealias CreatePersistent = @convention(c) (UnsafePointer<UInt8>, Int) -> UnsafeMutableRawPointer?
        typealias CopyManifest = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>?, Int) -> Int
        typealias Persist = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, Int) -> Int32
        typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias Upsert = @convention(c) (UnsafeMutableRawPointer, Int64, UnsafePointer<UInt8>, Int) -> Int32
        typealias Retain = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<Int64>?, Int) -> Int32
        typealias Query = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, Int, UnsafeMutablePointer<Int64>?, Int) -> Int

        static let shared: Symbols? = {
            // Resolve only the signed app's Frameworks directory. PATH, working
            // directory, environment variables, and developer checkouts are ignored.
            guard let directory = Bundle.main.privateFrameworksURL else { return nil }
            return Symbols(url: directory.appendingPathComponent("libccbuddy_tgrep.dylib"))
        }()

        private let library: UnsafeMutableRawPointer
        let create: Create
        let createPersistent: CreatePersistent
        let copyManifest: CopyManifest
        let persist: Persist
        let destroy: Destroy
        let upsert: Upsert
        let retain: Retain
        let query: Query

        init?(url: URL) {
            guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
            func load<T>(_ name: String, as type: T.Type) -> T? {
                guard let symbol = dlsym(library, name) else { return nil }
                return unsafeBitCast(symbol, to: type)
            }
            guard let version = load("ccbuddy_tgrep_abi_version", as: Version.self), version() == 2,
                  let create = load("ccbuddy_tgrep_create", as: Create.self),
                  let createPersistent = load("ccbuddy_tgrep_create_persistent", as: CreatePersistent.self),
                  let copyManifest = load("ccbuddy_tgrep_copy_manifest", as: CopyManifest.self),
                  let persist = load("ccbuddy_tgrep_persist", as: Persist.self),
                  let destroy = load("ccbuddy_tgrep_destroy", as: Destroy.self),
                  let upsert = load("ccbuddy_tgrep_upsert", as: Upsert.self),
                  let retain = load("ccbuddy_tgrep_retain", as: Retain.self),
                  let query = load("ccbuddy_tgrep_query", as: Query.self) else {
                dlclose(library)
                return nil
            }
            self.library = library
            self.create = create
            self.createPersistent = createPersistent
            self.copyManifest = copyManifest
            self.persist = persist
            self.destroy = destroy
            self.upsert = upsert
            self.retain = retain
            self.query = query
        }

        deinit { dlclose(library) }
    }
}
