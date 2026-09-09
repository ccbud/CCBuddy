import Darwin
import Foundation

/// These fixtures cross a process boundary: XCTest creates them and the tested app reads and
/// writes them. The runner's Foundation temporary directory can carry macOS AppData protection,
/// which blocks the app while opening its fixture SQLite database. Use the explicit shared
/// temporary location, retaining a unique, atomically created mode-0700 directory for each test.
/// This does not change either process's sandbox, signing identity, or privacy permissions.
enum UITestFixtureDirectory {
    static func make(named name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }) else { throw POSIXError(.EINVAL) }

        var template = Array("/private/tmp/ccbud-ui-\(name)-XXXXXX".utf8CString)
        return try template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw POSIXError(.EINVAL) }
            guard let created = Darwin.mkdtemp(base) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return URL(fileURLWithPath: String(cString: created), isDirectory: true)
        }
    }
}
