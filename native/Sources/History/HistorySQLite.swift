import Foundation
import SQLite3

enum HistorySQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .null, .blob: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value):
            guard value.isFinite,
                  value >= Double(Int64.min),
                  value < Double(Int64.max) else { return nil }
            return Int64(value)
        case .text(let value):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .null, .blob: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .text(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .null, .blob: return nil
        }
    }
}

struct HistorySQLiteRow: Equatable, Sendable {
    private var values: [String: HistorySQLiteValue]

    init(values: [String: HistorySQLiteValue]) {
        self.values = values
    }

    subscript(_ column: String) -> HistorySQLiteValue? {
        return values[column]
    }
}

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

    /// Reads heterogeneous SQLite rows without assuming a producer's schema is frozen. Any busy,
    /// malformed, or mid-query failure is a cache miss; callers always retain their file fallback.
    func rows(_ sql: String, bindings: [String] = []) -> [HistorySQLiteRow] {
        guard let statement = prepare(sql, bindings: bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [HistorySQLiteRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return result
            case SQLITE_ROW:
                var values: [String: HistorySQLiteValue] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    guard let rawName = sqlite3_column_name(statement, column) else { continue }
                    values[String(cString: rawName)] = Self.value(statement, column: column)
                }
                result.append(HistorySQLiteRow(values: values))
            default:
                return []
            }
        }
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

    private static func value(
        _ statement: OpaquePointer,
        column: Int32
    ) -> HistorySQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, column) else { return .null }
            return .text(String(cString: pointer))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
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
