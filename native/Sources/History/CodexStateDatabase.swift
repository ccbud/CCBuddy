import Foundation

struct CodexThreadQuickMetadata: Equatable, Sendable {
    var id: String
    var rolloutPath: URL
    var cwd: String?
    var title: String?
    var name: String?
    var model: String?
    var tokensUsed: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var archived: Bool
    var gitBranch: String?
    var source: String?
}

/// Resolves Codex's completed state database and asks it for the authoritative physical rollout
/// belonging to a canonical thread id. Every failure is intentionally a cache miss: JSONL
/// metadata and deterministic candidate ordering remain the fallback.
enum CodexStateDatabase {
    /// Reads every relevant state database once and returns rows keyed by a standardized rollout
    /// path. Optional columns are selected only when present so producer schema evolution cannot
    /// turn an otherwise useful batch into an all-or-nothing failure.
    static func quickMetadata(
        for candidates: [URL],
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: CodexThreadQuickMetadata] {
        var byCodexHome: [String: (home: URL, candidates: [URL])] = [:]
        for candidate in candidates {
            guard let home = codexHome(for: candidate) else { continue }
            let key = home.standardizedFileURL.path
            if byCodexHome[key] == nil { byCodexHome[key] = (home, []) }
            byCodexHome[key]?.candidates.append(candidate.standardizedFileURL)
        }

        var grouped: [String: (database: URL, candidates: [URL])] = [:]
        for homeGroup in byCodexHome.values {
            let database = stateDatabaseFile(
                codexHome: homeGroup.home,
                homeDirectory: homeDirectory,
                environment: environment
            )
            let key = database.standardizedFileURL.path
            if grouped[key] == nil { grouped[key] = (database, []) }
            grouped[key]?.candidates.append(contentsOf: homeGroup.candidates)
        }

        var result: [String: CodexThreadQuickMetadata] = [:]
        for group in grouped.values.sorted(by: { $0.database.path < $1.database.path }) {
            guard let database = HistorySQLiteDatabase(group.database),
                  database.textValue("SELECT status FROM backfill_state WHERE id = 1")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "complete" else { continue }
            let columns = Set(database.rows("PRAGMA table_info(threads)").compactMap {
                $0["name"]?.stringValue
            })
            guard columns.contains("rollout_path") else { continue }

            let preferred = [
                "id", "rollout_path", "cwd", "title", "name", "tokens_used", "archived",
                "git_branch", "model", "source", "thread_source", "created_at_ms",
                "updated_at_ms", "created_at", "updated_at",
            ].filter(columns.contains)
            let rawPaths = Array(Set(group.candidates.map(\.path))).sorted()
            for chunkStart in stride(from: 0, to: rawPaths.count, by: 400) {
                let chunk = Array(rawPaths[chunkStart..<min(chunkStart + 400, rawPaths.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = "SELECT \(preferred.joined(separator: ", ")) FROM threads "
                    + "WHERE rollout_path IN (\(placeholders))"
                for row in database.rows(sql, bindings: chunk) {
                    guard let rawPath = nonempty(row["rollout_path"]?.stringValue) else { continue }
                    let rollout = URL(fileURLWithPath: rawPath).standardizedFileURL
                    let key = rollout.path
                    let metadata = CodexThreadQuickMetadata(
                        id: nonempty(row["id"]?.stringValue) ?? "",
                        rolloutPath: rollout,
                        cwd: nonempty(row["cwd"]?.stringValue),
                        title: nonempty(row["title"]?.stringValue),
                        name: nonempty(row["name"]?.stringValue),
                        model: nonempty(row["model"]?.stringValue),
                        tokensUsed: nonnegativeInt(row["tokens_used"]),
                        createdAt: date(
                            milliseconds: row["created_at_ms"],
                            fallback: row["created_at"]
                        ),
                        updatedAt: date(
                            milliseconds: row["updated_at_ms"],
                            fallback: row["updated_at"]
                        ),
                        archived: boolean(row["archived"]),
                        gitBranch: nonempty(row["git_branch"]?.stringValue),
                        source: nonempty(row["source"]?.stringValue)
                            ?? nonempty(row["thread_source"]?.stringValue)
                    )
                    if let current = result[key],
                       (current.updatedAt ?? .distantPast) > (metadata.updatedAt ?? .distantPast) {
                        continue
                    }
                    result[key] = metadata
                }
            }
        }
        return result
    }

    static func preferredRolloutPath(
        for candidate: URL,
        threadID: String,
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard !threadID.isEmpty,
              let databaseFile = stateDatabaseFile(
                for: candidate,
                homeDirectory: homeDirectory,
                environment: environment
              ) else { return nil }
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

    private static func stateDatabaseFile(
        for candidate: URL,
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL? {
        guard let codexHome = codexHome(for: candidate) else { return nil }
        return stateDatabaseFile(
            codexHome: codexHome,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    private static func stateDatabaseFile(
        codexHome: URL,
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        let sqliteHome = configuredSQLiteHome(codexHome: codexHome, homeDirectory: homeDirectory)
            ?? environment["CODEX_SQLITE_HOME"].flatMap {
                resolveSQLiteHome($0, codexHome: codexHome, homeDirectory: homeDirectory)
            }
            ?? codexHome
        return sqliteHome.appendingPathComponent("state_5.sqlite").standardizedFileURL
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

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func nonnegativeInt(_ value: HistorySQLiteValue?) -> Int? {
        guard let raw = value?.int64Value, raw >= 0, raw <= Int64(Int.max) else { return nil }
        return Int(raw)
    }

    private static func boolean(_ value: HistorySQLiteValue?) -> Bool {
        if let integer = value?.int64Value { return integer != 0 }
        switch value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes": return true
        default: return false
        }
    }

    private static func date(
        milliseconds: HistorySQLiteValue?,
        fallback: HistorySQLiteValue?
    ) -> Date? {
        if let milliseconds = milliseconds?.doubleValue, milliseconds.isFinite, milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        if let raw = fallback?.doubleValue, raw.isFinite, raw > 0 {
            let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        return HistoryDateParser.parse(nonempty(fallback?.stringValue))
    }
}
