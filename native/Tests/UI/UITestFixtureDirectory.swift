import Darwin
import Foundation

/// Keep fixtures inside the runner's system-provided temporary root: XCTest can deny fixed
/// locations such as /private/tmp even when a standalone command can write there. Each test gets
/// a unique, atomically created mode-0700 directory. Cross-process access still depends on the
/// test environment's existing sandbox and privacy authorization; this helper does not alter it.
enum UITestFixtureDirectory {
    static func make(named name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }) else { throw POSIXError(.EINVAL) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-ui-\(name)-XXXXXX", isDirectory: true)
        var template = Array(directory.path.utf8CString)
        return try template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw POSIXError(.EINVAL) }
            guard let created = Darwin.mkdtemp(base) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return URL(fileURLWithPath: String(cString: created), isDirectory: true)
        }
    }
}
