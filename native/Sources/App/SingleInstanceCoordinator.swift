import Darwin
import Foundation

// Darwin also imports a `flock` structure, which shadows the POSIX function in Swift. Bind the
// libc symbol under an unambiguous Swift name.
@_silgen_name("flock")
private func ccbud_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class SingleInstanceLock {
    enum Acquisition: Equatable {
        case primary(token: String)
        case secondary(primaryToken: String?)
    }

    let url: URL
    private(set) var acquisition: Acquisition?
    private var descriptor: Int32 = -1
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    deinit {
        release()
    }

    func acquire() throws -> Acquisition {
        if let acquisition { return acquisition }

        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = Darwin.fchmod(fd, mode_t(0o600))

        if ccbud_flock(fd, LOCK_EX | LOCK_NB) == 0 {
            let token = UUID().uuidString.lowercased()
            do {
                try write(token: token, to: fd)
                descriptor = fd
                let result = Acquisition.primary(token: token)
                acquisition = result
                return result
            } catch {
                _ = ccbud_flock(fd, LOCK_UN)
                Darwin.close(fd)
                throw error
            }
        }

        let lockError = errno
        guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        // The primary writes immediately after acquiring the lock. A very small bounded retry
        // closes the launch-race without leaving a second application process running.
        var token: String?
        for attempt in 0..<10 {
            token = readToken(from: fd)
            if token != nil { break }
            if attempt < 9 { usleep(10_000) }
        }
        Darwin.close(fd)
        let result = Acquisition.secondary(primaryToken: token)
        acquisition = result
        return result
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = ccbud_flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
        acquisition = nil
    }

    private func write(token: String, to fd: Int32) throws {
        guard Darwin.ftruncate(fd, 0) == 0, Darwin.lseek(fd, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = Array(token.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: written), bytes.count - written)
            }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            written += count
        }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func readToken(from fd: Int32) -> String? {
        guard Darwin.lseek(fd, 0, SEEK_SET) >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.read(fd, base, buffer.count)
        }
        guard count > 0 else { return nil }
        let raw = String(decoding: bytes.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: raw) != nil else { return nil }
        return raw.lowercased()
    }
}

enum LegacyBundleNameMigrationResult: Equatable {
    case notNeeded
    case targetAlreadyExists
    case renameFailed
    case relaunchFailed(restoredLegacyName: Bool)
    case relaunched
}

/// Repairs application bundles installed by releases that used `ccbud.app` or `CCBuddy.app` as
/// the outer directory. The old updater replaced the bundle contents without renaming that
/// directory, which makes Finder and the Dock display the legacy folder name even though the
/// bundle metadata says “CC Buddy”. A successful rename is followed by a Launch Services relaunch;
/// if relaunching fails, the original directory name is restored before the current process keeps
/// running.
struct LegacyBundleNameMigrator {
    static let legacyNames = Set(["ccbud.app", "CCBuddy.app"])
    static let currentName = "CC Buddy.app"

    static func migrateCurrentProcess(
        fileManager: FileManager = .default,
        relaunch: (URL) -> Bool = relaunchApplication(at:)
    ) -> LegacyBundleNameMigrationResult {
        guard let executableURL = Bundle.main.executableURL else { return .notNeeded }
        return migrate(
            executableURL: executableURL,
            fileManager: fileManager,
            relaunch: relaunch
        )
    }

    static func migrate(
        executableURL: URL,
        fileManager: FileManager = .default,
        relaunch: (URL) -> Bool
    ) -> LegacyBundleNameMigrationResult {
        let bundleURL = executableURL
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // *.app
            .standardizedFileURL
        guard legacyNames.contains(bundleURL.lastPathComponent) else { return .notNeeded }

        let targetURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(currentName, isDirectory: true)
        guard !fileManager.fileExists(atPath: targetURL.path) else { return .targetAlreadyExists }

        do {
            try fileManager.moveItem(at: bundleURL, to: targetURL)
        } catch {
            return .renameFailed
        }

        guard relaunch(targetURL) else {
            let restored = (try? fileManager.moveItem(at: targetURL, to: bundleURL)) != nil
            return .relaunchFailed(restoredLegacyName: restored)
        }
        return .relaunched
    }

    private static func relaunchApplication(at applicationURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", applicationURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Owns the process-wide file lock and a per-lifetime distributed notification channel. The
/// random channel suffix is readable only from the mode-0600 lock file, so unrelated processes
/// cannot guess the activation notification used by this app lifetime.
@MainActor
final class ApplicationInstanceCoordinator {
    static let shared = ApplicationInstanceCoordinator()

    let isPrimaryInstance: Bool
    private let primaryToken: String?
    private let lock: SingleInstanceLock
    private let notificationCenter: DistributedNotificationCenter
    private var activationObserver: NSObjectProtocol?

    private init(
        lockURL: URL = ApplicationInstanceCoordinator.defaultLockURL(),
        notificationCenter: DistributedNotificationCenter = .default()
    ) {
        lock = SingleInstanceLock(url: lockURL)
        self.notificationCenter = notificationCenter

        do {
            switch try lock.acquire() {
            case .primary(let token):
                isPrimaryInstance = true
                primaryToken = token
            case .secondary(let token):
                isPrimaryInstance = false
                primaryToken = token
            }
        } catch {
            // A read-only or otherwise unusual home directory should not make the app impossible
            // to launch. The normal mode-0600 lock remains the enforced path whenever available.
            isPrimaryInstance = true
            primaryToken = nil
        }
    }

    func beginObservingActivation(_ handler: @escaping @MainActor @Sendable () -> Void) {
        guard isPrimaryInstance, activationObserver == nil, let name = activationNotificationName else { return }
        activationObserver = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
    }

    func notifyPrimaryInstance() {
        guard !isPrimaryInstance, let name = activationNotificationName else { return }
        notificationCenter.postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private var activationNotificationName: Notification.Name? {
        guard let primaryToken else { return nil }
        return Notification.Name("dev.ccbud.gateway.activate.\(primaryToken)")
    }

    nonisolated private static func defaultLockURL() -> URL {
        ConfigRepository.defaultConfigURL()
            .deletingLastPathComponent()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)
    }
}
