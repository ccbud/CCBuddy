import Darwin
import Foundation

enum SecureAtomicFile {
    static func write(
        _ data: Data,
        to destination: URL,
        permissions: mode_t = S_IRUSR | S_IWUSR,
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).ccbud-\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            permissions
        )
        guard descriptor >= 0 else { throw posixError() }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary { try? fileManager.removeItem(at: temporary) }
        }

        try data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixError() }
        shouldRemoveTemporary = false

        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
