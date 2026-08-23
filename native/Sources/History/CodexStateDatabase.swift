import Foundation

/// Resolves Codex's completed state database and asks it for the authoritative physical rollout
/// belonging to a canonical thread id. Every failure is intentionally a cache miss: JSONL
/// metadata and deterministic candidate ordering remain the fallback.
enum CodexStateDatabase {
    static func preferredRolloutPath(
        for candidate: URL,
        threadID: String,
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard !threadID.isEmpty, let codexHome = codexHome(for: candidate) else { return nil }
        let sqliteHome = configuredSQLiteHome(codexHome: codexHome, homeDirectory: homeDirectory)
            ?? environment["CODEX_SQLITE_HOME"].flatMap {
                resolveSQLiteHome($0, codexHome: codexHome, homeDirectory: homeDirectory)
            }
            ?? codexHome
        let databaseFile = sqliteHome.appendingPathComponent("state_5.sqlite")
        guard let database = HistorySQLiteDatabase(databaseFile),
              database.textValue("SELECT status FROM backfill_state WHERE id = 1") == "complete",
              let rollout = database.textValue(
                "SELECT rollout_path FROM threads WHERE id = ?1 AND archived = 0",
                bindings: [threadID]
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rollout.isEmpty else { return nil }
        let file = URL(fileURLWithPath: rollout).standardizedFileURL
        return ForeignHistorySupport.isOrdinaryFile(file) ? file : nil
    }

    static func codexHome(for rollout: URL) -> URL? {
        var cursor = rollout.deletingLastPathComponent().standardizedFileURL
        while cursor.pathComponents.count > 1 {
            if cursor.lastPathComponent == "sessions"
                || cursor.lastPathComponent == "archived_sessions" {
                return cursor.deletingLastPathComponent().standardizedFileURL
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            cursor = parent
        }
        return nil
    }

    private static func configuredSQLiteHome(
        codexHome: URL,
        homeDirectory: URL
    ) -> URL? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let text = ForeignHistorySupport.textFile(at: config),
              let raw = topLevelSQLiteHome(in: text) else { return nil }
        return resolveSQLiteHome(raw, codexHome: codexHome, homeDirectory: homeDirectory)
    }

    private static func resolveSQLiteHome(
        _ rawValue: String,
        codexHome: URL,
        homeDirectory: URL
    ) -> URL? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw == "~" { return homeDirectory.standardizedFileURL }
        if raw.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).standardizedFileURL
        }
        let path = URL(fileURLWithPath: raw)
        if (raw as NSString).isAbsolutePath { return path.standardizedFileURL }
        return codexHome.appendingPathComponent(raw).standardizedFileURL
    }

    /// Codex's `sqlite_home` is a top-level TOML string. This deliberately accepts only the two
    /// TOML string forms needed for a path; malformed config simply falls through to the
    /// environment/default location.
    private static func topLevelSQLiteHome(in text: String) -> String? {
        var insideTable = false
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                insideTable = true
                continue
            }
            guard !insideTable, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "sqlite_home" else { continue }
            let encoded = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard encoded.count >= 2 else { return nil }
            if encoded.first == "'", encoded.last == "'" {
                return String(encoded.dropFirst().dropLast())
            }
            if encoded.first == "\"", encoded.last == "\"",
               let data = encoded.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded
            }
            return nil
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
                continue
            }
            if character == "#", quote == nil { return String(line[..<index]) }
        }
        return line
    }
}
