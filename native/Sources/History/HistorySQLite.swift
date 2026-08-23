import Foundation
import SQLite3

/// Small read-only SQLite wrapper shared by history sources.
///
/// SQLite may consult a WAL, shared-memory file, or rollback journal even for a read-only
/// connection. Existing sidecars therefore have to be ordinary files before the database is
/// opened; a symlinked sidecar rejects the whole database.
final class HistorySQLiteDatabase {
    private var connection: OpaquePointer?

    init?(_ file: URL) {
        guard Self.databaseAndSidecarsAreSafe(file) else { return nil }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(file.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        connection = handle
        sqlite3_busy_timeout(handle, 400)
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    func dataColumn(_ sql: String, bindings: [String] = []) -> [Data] {
        guard let statement = prepare(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count >= 0 else { continue }
            if count == 0 {
                result.append(Data())
            } else if let pointer = sqlite3_column_blob(statement, 0) {
                result.append(Data(bytes: pointer, count: count))
            }
        }
        return result
    }

    func textRow(_ sql: String, bindings: [String] = []) -> [String]? {
        guard let statement = prepare(sql, bindings: bindings) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
    }

    func textValue(_ sql: String, bindings: [String] = []) -> String? {
        textRow(sql, bindings: bindings)?.first
    }

    private func prepare(_ sql: String, bindings: [String]) -> OpaquePointer? {
        guard let connection else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let status = value.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient)
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                return nil
            }
        }
        return statement
    }

    private static func databaseAndSidecarsAreSafe(_ file: URL) -> Bool {
        guard ForeignHistorySupport.isOrdinaryFile(file) else { return false }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            guard ForeignHistorySupport.isOrdinaryFile(sidecar) else { return false }
        }
        return true
    }
}
