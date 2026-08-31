import Darwin
import Foundation

struct QoderFileStamp: Equatable, Sendable {
    let modifiedAt: Date
    let size: UInt64
}

protocol QoderFileAccessing: Sendable {
    func readData(at file: URL) throws -> Data
    func probeReadable(at file: URL) throws
    func stamp(of file: URL) throws -> QoderFileStamp
}

protocol QoderHelperResolving: Sendable {
    func trustedHelper(for dataRoot: URL) throws -> URL
}

protocol QoderHelperRunning: Sendable {
    func read(
        helper: URL,
        target: URL,
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> Data

    func readBatch(
        helper: URL,
        targets: [URL],
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> [URL: Data]
}

enum QoderFileReadError: LocalizedError, Equatable, Sendable {
    case invalidTarget(String)
    case fileTooLarge(Int)
    case helperTimedOut
    case helperOutputTooLarge
    case helperFailed(String)
    case helperUntrusted(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget(let reason):
            return "Qoder helper 读取目标无效：\(reason)"
        case .fileTooLarge(let limit):
            return "Qoder 数据文件超过 \(limit / 1_024 / 1_024) MiB 读取上限"
        case .helperTimedOut:
            return "Qoder CLI helper 读取超时"
        case .helperOutputTooLarge:
            return "Qoder CLI helper 输出超过安全上限"
        case .helperFailed(let reason):
            return "Qoder CLI helper 读取失败：\(reason)"
        case .helperUntrusted(let reason):
            return "Qoder CLI helper 未通过安全验证：\(reason)"
        }
    }
}

struct QoderValidatedTarget: Equatable, Sendable {
    let file: URL
    let dataRoot: URL
}

/// Reads Qoder-owned history without silently losing protected transcripts. Ordinary filesystem
/// access is always attempted first. A Qoder-installed CLI is used only after a permission denial,
/// and only for a canonical JSON/JSONL target proven to remain inside a direct
/// `.qoder/.qoderwork/projects` tree.
struct QoderFileReader: Sendable {
    static let maximumReadBytes = 256 * 1_024 * 1_024
    static let helperCacheBudget = 256 * 1_024 * 1_024
    static let helperTimeout: TimeInterval = 15
    static let helperBatchTimeout: TimeInterval = 45
    static let batchSize = 32
    static let shared = QoderFileReader()

    private let fileAccess: any QoderFileAccessing
    private let helperResolver: any QoderHelperResolving
    private let helperRunner: any QoderHelperRunning
    private let cache: QoderHelperCache
    private let maximumReadBytes: Int
    private let helperTimeout: TimeInterval
    private let helperBatchTimeout: TimeInterval

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            fileAccess: SystemQoderFileAccess(),
            helperResolver: SystemQoderHelperResolver(homeDirectory: homeDirectory),
            helperRunner: ProcessQoderHelperRunner(),
            cache: .shared
        )
    }

    init(
        fileAccess: any QoderFileAccessing,
        helperResolver: any QoderHelperResolving,
        helperRunner: any QoderHelperRunning,
        cache: QoderHelperCache = QoderHelperCache(),
        maximumReadBytes: Int = QoderFileReader.maximumReadBytes,
        helperTimeout: TimeInterval = QoderFileReader.helperTimeout,
        helperBatchTimeout: TimeInterval = QoderFileReader.helperBatchTimeout
    ) {
        self.fileAccess = fileAccess
        self.helperResolver = helperResolver
        self.helperRunner = helperRunner
        self.cache = cache
        self.maximumReadBytes = maximumReadBytes
        self.helperTimeout = helperTimeout
        self.helperBatchTimeout = helperBatchTimeout
    }

    func read(_ file: URL) throws -> Data {
        let qoderPath = Self.isQoderDataPath(file)
        if qoderPath, let stamp = try? fileAccess.stamp(of: file), stamp.size > maximumReadBytes {
            throw QoderFileReadError.fileTooLarge(maximumReadBytes)
        }

        do {
            let data = try fileAccess.readData(at: file)
            if qoderPath, data.count > maximumReadBytes {
                throw QoderFileReadError.fileTooLarge(maximumReadBytes)
            }
            return data
        } catch {
            guard qoderPath, Self.isPermissionDenied(error) else { throw error }
            return try readWithHelper(file, originalError: error)
        }
    }

    /// Batch-warms permission-protected Qoder files. Directly-readable and fresh-cached files are
    /// skipped. Failures remain per-file and fall back to the bounded single-read path on demand.
    func prefetch(_ files: [URL]) {
        struct Entry {
            let target: URL
            let stamp: QoderFileStamp
        }

        var grouped: [URL: [Entry]] = [:]
        var seen = Set<String>()
        for file in files where Self.isQoderDataPath(file) {
            guard let stamp = try? fileAccess.stamp(of: file),
                  stamp.size <= maximumReadBytes else { continue }
            let cacheKey = file.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(cacheKey.path).inserted,
                  cache.data(for: cacheKey, stamp: stamp) == nil else { continue }

            do {
                try fileAccess.probeReadable(at: file)
                continue
            } catch {
                guard Self.isPermissionDenied(error),
                      let validated = try? Self.validatedTarget(
                        file,
                        maximumReadBytes: maximumReadBytes
                      ) else { continue }
                grouped[validated.dataRoot, default: []].append(
                    Entry(target: validated.file, stamp: stamp)
                )
            }
        }

        for (root, entries) in grouped {
            guard let helper = try? helperResolver.trustedHelper(for: root) else { continue }
            var start = 0
            while start < entries.count {
                let end = min(start + Self.batchSize, entries.count)
                let chunk = Array(entries[start..<end])
                start = end
                guard let output = try? helperRunner.readBatch(
                    helper: helper,
                    targets: chunk.map(\.target),
                    outputLimit: maximumReadBytes,
                    timeout: helperBatchTimeout
                ) else { continue }

                for entry in chunk {
                    guard let data = output[entry.target], data.count <= maximumReadBytes,
                          let current = try? fileAccess.stamp(of: entry.target),
                          current == entry.stamp else { continue }
                    cache.insert(data, for: entry.target, stamp: entry.stamp)
                }
            }
        }
    }

    static func isQoderDataPath(_ file: URL) -> Bool {
        let fileExtension = file.pathExtension
        guard fileExtension == "json" || fileExtension == "jsonl" else { return false }
        var childName: String?
        var ancestor = file.deletingLastPathComponent()
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            let name = ancestor.lastPathComponent
            if (name == ".qoder" || name == ".qoderwork"), childName == "projects" {
                return true
            }
            childName = name
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            ancestor = parent
        }
        return false
    }

    static func validatedTarget(
        _ requested: URL,
        maximumReadBytes: Int = QoderFileReader.maximumReadBytes,
        fileManager: FileManager = .default
    ) throws -> QoderValidatedTarget {
        guard requested.isFileURL else {
            throw QoderFileReadError.invalidTarget("目标不是本地文件")
        }

        var projects: URL?
        var ancestor = requested.deletingLastPathComponent().standardizedFileURL
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            if ancestor.lastPathComponent == "projects" {
                let root = ancestor.deletingLastPathComponent()
                if root.lastPathComponent == ".qoder" || root.lastPathComponent == ".qoderwork" {
                    projects = ancestor
                    break
                }
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            ancestor = parent
        }
        guard let rawProjects = projects else {
            throw QoderFileReadError.invalidTarget("仅允许 .qoder/.qoderwork 的 projects 数据树")
        }

        let rawRoot = rawProjects.deletingLastPathComponent()
        let canonicalRoot = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalProjects = rawProjects.resolvingSymlinksInPath().standardizedFileURL
        let canonicalFile = requested.resolvingSymlinksInPath().standardizedFileURL

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw QoderFileReadError.invalidTarget("Qoder 数据根不存在")
        }
        guard fileManager.fileExists(atPath: canonicalProjects.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              canonicalProjects.deletingLastPathComponent() == canonicalRoot else {
            throw QoderFileReadError.invalidTarget("projects 目录逃逸数据根")
        }
        guard Self.isDescendant(canonicalFile, of: canonicalProjects) else {
            throw QoderFileReadError.invalidTarget("数据文件逃逸 projects 目录")
        }
        let fileExtension = canonicalFile.pathExtension
        guard fileExtension == "json" || fileExtension == "jsonl" else {
            throw QoderFileReadError.invalidTarget("仅允许 JSON 与 JSONL 文件")
        }
        let values = try canonicalFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw QoderFileReadError.invalidTarget("目标不是普通文件")
        }
        if values.fileSize ?? 0 > maximumReadBytes {
            throw QoderFileReadError.fileTooLarge(maximumReadBytes)
        }
        return QoderValidatedTarget(file: canonicalFile, dataRoot: canonicalRoot)
    }

    private func readWithHelper(_ file: URL, originalError: Error) throws -> Data {
        let validated = try Self.validatedTarget(file, maximumReadBytes: maximumReadBytes)
        let stamp = try? fileAccess.stamp(of: validated.file)
        if let stamp, let cached = cache.data(for: validated.file, stamp: stamp) {
            return cached
        }

        let helper: URL
        do {
            helper = try helperResolver.trustedHelper(for: validated.dataRoot)
        } catch {
            throw Self.permissionDeniedError(original: originalError, helperError: error)
        }
        let data = try helperRunner.read(
            helper: helper,
            target: validated.file,
            outputLimit: maximumReadBytes,
            timeout: helperTimeout
        )
        guard data.count <= maximumReadBytes else {
            throw QoderFileReadError.helperOutputTooLarge
        }
        if let stamp,
           let current = try? fileAccess.stamp(of: validated.file),
           current == stamp {
            cache.insert(data, for: validated.file, stamp: stamp)
        }
        return data
    }

    private static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return childComponents.count > rootComponents.count
            && childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(EACCES) || error.code == Int(EPERM) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    private static func permissionDeniedError(original: Error, helperError: Error) -> Error {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoPermission.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: original,
                NSLocalizedDescriptionKey:
                    "Qoder 数据不可直接读取，且其 CLI helper 不可用：\(helperError.localizedDescription)",
            ]
        )
    }
}

final class QoderHelperCache: @unchecked Sendable {
    static let shared = QoderHelperCache(budget: QoderFileReader.helperCacheBudget)

    private struct Entry {
        let stamp: QoderFileStamp
        let data: Data
    }

    private let budget: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var byteCount = 0

    init(budget: Int = QoderFileReader.helperCacheBudget) {
        self.budget = max(0, budget)
    }

    func data(for file: URL, stamp: QoderFileStamp) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let key = file.standardizedFileURL.path
        guard let entry = entries[key] else { return nil }
        guard entry.stamp == stamp else {
            entries.removeValue(forKey: key)
            byteCount = max(0, byteCount - entry.data.count)
            return nil
        }
        return entry.data
    }

    func insert(_ data: Data, for file: URL, stamp: QoderFileStamp) {
        guard data.count <= budget else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = file.standardizedFileURL.path
        if let prior = entries.removeValue(forKey: key) {
            byteCount = max(0, byteCount - prior.data.count)
        }
        if byteCount + data.count > budget {
            entries.removeAll(keepingCapacity: true)
            byteCount = 0
        }
        entries[key] = Entry(stamp: stamp, data: data)
        byteCount += data.count
    }
}

struct SystemQoderFileAccess: QoderFileAccessing {
    func readData(at file: URL) throws -> Data {
        try Data(contentsOf: file, options: [.mappedIfSafe])
    }

    func probeReadable(at file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        try handle.close()
    }

    func stamp(of file: URL) throws -> QoderFileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return QoderFileStamp(
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        )
    }
}

struct SystemQoderHelperResolver: QoderHelperResolving {
    private static let trustCache = QoderHelperTrustCache()
    let homeDirectory: URL

    func trustedHelper(for dataRoot: URL) throws -> URL {
        let candidates = [
            dataRoot.appendingPathComponent("bin/qodercli", isDirectory: true),
            homeDirectory.appendingPathComponent(".qoder/bin/qodercli", isDirectory: true),
        ]
        var lastError: Error?
        for installDirectory in candidates {
            do {
                let helper = try helper(in: installDirectory)
                try Self.trustCache.verify(helper, homeDirectory: homeDirectory)
                return helper
            } catch {
                lastError = error
            }
        }
        throw lastError ?? QoderFileReadError.helperFailed("未找到已安装的 Qoder CLI helper")
    }

    private func helper(in rawDirectory: URL) throws -> URL {
        let directory = rawDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else {
            throw QoderFileReadError.helperFailed("helper 安装目录不存在")
        }
        let versionFile = rawDirectory.appendingPathComponent("version.txt")
            .resolvingSymlinksInPath().standardizedFileURL
        guard versionFile.deletingLastPathComponent() == directory else {
            throw QoderFileReadError.helperUntrusted("version.txt 逃逸安装目录")
        }
        let version = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.utf8.count <= 64,
              version.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 46 || byte == 95 || byte == 45
              }) else {
            throw QoderFileReadError.helperUntrusted("version.txt 版本字符串无效")
        }
        let helper = rawDirectory.appendingPathComponent("qodercli-\(version)")
            .resolvingSymlinksInPath().standardizedFileURL
        guard helper.deletingLastPathComponent() == directory,
              try helper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw QoderFileReadError.helperUntrusted("helper 逃逸安装目录或不是普通文件")
        }
        return helper
    }
}

private final class QoderHelperTrustCache: @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [String: (stamp: QoderFileStamp, trusted: Bool)] = [:]

    func verify(_ helper: URL, homeDirectory: URL) throws {
        let stamp = try SystemQoderFileAccess().stamp(of: helper)
        lock.lock()
        let cached = verdicts[helper.path]
        lock.unlock()
        if let cached, cached.stamp == stamp {
            guard cached.trusted else {
                throw QoderFileReadError.helperUntrusted("此前的安全验证失败")
            }
            return
        }

        do {
            try verifyUncached(helper, homeDirectory: homeDirectory)
            lock.lock()
            verdicts[helper.path] = (stamp, true)
            lock.unlock()
        } catch {
            lock.lock()
            verdicts[helper.path] = (stamp, false)
            lock.unlock()
            throw error
        }
    }

    private func verifyUncached(_ helper: URL, homeDirectory: URL) throws {
        var helperStat = stat()
        var directoryStat = stat()
        var homeStat = stat()
        guard lstat(helper.path, &helperStat) == 0,
              lstat(helper.deletingLastPathComponent().path, &directoryStat) == 0,
              lstat(homeDirectory.path, &homeStat) == 0,
              helperStat.st_mode & S_IFMT == S_IFREG,
              directoryStat.st_mode & S_IFMT == S_IFDIR,
              homeStat.st_mode & S_IFMT == S_IFDIR else {
            throw QoderFileReadError.helperUntrusted("无法读取 helper 所有权信息")
        }
        for (name, information) in [("helper", helperStat), ("helper 目录", directoryStat)] {
            guard information.st_uid == homeStat.st_uid else {
                throw QoderFileReadError.helperUntrusted("\(name) 不属于当前用户")
            }
            guard information.st_mode & mode_t(0o022) == 0 else {
                throw QoderFileReadError.helperUntrusted("\(name) 可被 group/world 写入")
            }
        }

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", "--", helper.path]
        verify.standardInput = FileHandle.nullDevice
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw QoderFileReadError.helperUntrusted("helper 没有有效的严格代码签名")
        }

        let display = Process()
        let stderr = Pipe()
        display.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        display.arguments = ["-d", "--verbose=2", "--", helper.path]
        display.standardInput = FileHandle.nullDevice
        display.standardOutput = FileHandle.nullDevice
        display.standardError = stderr
        try display.run()
        display.waitUntilExit()
        let information = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile().prefix(64 * 1_024),
            as: UTF8.self
        )
        let hasTeamIdentifier = information.split(whereSeparator: \.isNewline).contains { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("TeamIdentifier=") && value != "TeamIdentifier=not set"
        }
        guard hasTeamIdentifier else {
            throw QoderFileReadError.helperUntrusted("helper 没有开发者 Team ID")
        }
    }
}

struct ProcessQoderHelperRunner: QoderHelperRunning {
    private static let readScript =
        #"const fs=require("fs");process.stdout.write(fs.readFileSync(process.argv[1]))"#
    private static let batchReadScript =
        #"const fs=require("fs");for(const p of process.argv.slice(1)){let line;try{line=JSON.stringify({p,b64:fs.readFileSync(p).toString("base64")})}catch(e){line=JSON.stringify({p,err:String(e&&e.code||e)})}process.stdout.write(line+"\n")}"#

    func read(
        helper: URL,
        target: URL,
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> Data {
        try run(
            helper: helper,
            arguments: ["-e", Self.readScript, target.path],
            outputLimit: outputLimit,
            timeout: timeout
        )
    }

    func readBatch(
        helper: URL,
        targets: [URL],
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> [URL: Data] {
        let output = try run(
            helper: helper,
            arguments: ["-e", Self.batchReadScript] + targets.map(\.path),
            outputLimit: outputLimit,
            timeout: timeout
        )
        var result: [URL: Data] = [:]
        for line in output.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let path = object["p"] as? String,
                  let encoded = object["b64"] as? String,
                  let data = Data(base64Encoded: encoded) else { continue }
            result[URL(fileURLWithPath: path).standardizedFileURL] = data
        }
        return result
    }

    private func run(
        helper: URL,
        arguments: [String],
        outputLimit: Int,
        timeout: TimeInterval
    ) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BUN_BE_BUN"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let outputBuffer = QoderBoundedBuffer(limit: outputLimit, terminateOnOverflow: true)
        let errorBuffer = QoderBoundedBuffer(limit: 8 * 1_024, terminateOnOverflow: false)
        let readers = DispatchGroup()
        Self.drain(
            stdout.fileHandleForReading,
            into: outputBuffer,
            process: process,
            group: readers
        )
        Self.drain(
            stderr.fileHandleForReading,
            into: errorBuffer,
            process: process,
            group: readers
        )

        let wait = completion.wait(timeout: .now() + timeout)
        if wait == .timedOut {
            Self.stop(process)
            Self.finishReaders(readers, stdout: stdout, stderr: stderr)
            throw QoderFileReadError.helperTimedOut
        }
        process.waitUntilExit()
        Self.finishReaders(readers, stdout: stdout, stderr: stderr)

        if let readError = outputBuffer.readError {
            throw QoderFileReadError.helperFailed(readError.localizedDescription)
        }
        guard !outputBuffer.exceededLimit else {
            throw QoderFileReadError.helperOutputTooLarge
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorBuffer.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw QoderFileReadError.helperFailed(
                detail.isEmpty ? "退出状态 \(process.terminationStatus)" : detail
            )
        }
        return outputBuffer.data
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: QoderBoundedBuffer,
        process: Process,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            do {
                while true {
                    guard let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty else {
                        break
                    }
                    if buffer.append(data), process.isRunning { process.terminate() }
                }
            } catch {
                buffer.record(error)
            }
        }
    }

    private static func finishReaders(_ readers: DispatchGroup, stdout: Pipe, stderr: Pipe) {
        if readers.wait(timeout: .now() + 1) == .timedOut {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 1)
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(10_000)
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

private final class QoderBoundedBuffer: @unchecked Sendable {
    private let limit: Int
    private let terminateOnOverflow: Bool
    private let lock = NSLock()
    private var storage = Data()
    private var overflow = false
    private var failure: Error?

    init(limit: Int, terminateOnOverflow: Bool) {
        self.limit = max(0, limit)
        self.terminateOnOverflow = terminateOnOverflow
        storage.reserveCapacity(min(limit, 8 * 1_024 * 1_024))
    }

    /// Returns true once when the owning process should be terminated.
    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - storage.count)
        if remaining > 0 { storage.append(data.prefix(remaining)) }
        guard data.count > remaining else { return false }
        let firstOverflow = !overflow
        overflow = true
        return firstOverflow && terminateOnOverflow
    }

    func record(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow
    }

    var readError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}
