import Foundation

private struct CopilotNormalizedTranscript {
    var messages: [HistoryMessage] = []
    var model: String?
    var cwd: String?
    var sessionID: String?
    var gitBranch: String?
    var version: String?
}

struct CopilotSQLiteSessionRow: Sendable {
    var id: String
    var cwd: String?
    var branch: String?
    var summary: String?
    var createdAt: Date?
    var updatedAt: Date?
    var contentLength: UInt64
    var turnCount: Int
}

enum CopilotHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let normalized = normalize(context.document.records)
        let workspace = workspaceMetadata(for: context.candidate.file)
        let uuid = sessionUUID(context.candidate.file)
        let custom = ForeignHistorySupport.customMetadata(
            source: .copilot,
            sessionKey: uuid,
            appDataRoot: context.appDataRoot
        )
        let workspaceTitle = workspace["name"].flatMap(nonempty)
        let autoTitle = workspaceTitle ?? HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let cwd = workspace["cwd"].flatMap(nonempty) ?? normalized.cwd
        let createdAt = workspace["created_at"].flatMap { HistoryDateParser.parse($0) }
            ?? ForeignHistorySupport.firstTimestamp(in: normalized.messages)
            ?? context.facts.createdAt

        let metadata = HistorySessionMetadata(
            id: "copilot:\(uuid)",
            file: context.candidate.file,
            source: .copilot,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: normalized.sessionID ?? uuid,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil),
            gitBranch: workspace["branch"].flatMap(nonempty) ?? normalized.gitBranch,
            version: normalized.version,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: normalized.model,
            imported: false,
            deleted: custom.deleted,
            createdAt: createdAt,
            lastActivity: context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            messageCount: normalized.messages.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    static func parseSQLite(_ input: ConversationSourceParseInput) throws -> HistorySession {
        let databaseFile = input.candidate.primaryStorageFile
        guard let database = HistorySQLiteDatabase(databaseFile) else {
            throw HistoryError.unreadableFile(databaseFile, "无法只读打开 Copilot 数据库")
        }
        let nativeID = WakeHistoryAdapterSupport.nativeID(input.candidate)
        guard let row = sqliteSessionRows(database: database, id: nativeID).first else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }

        var messages: [HistoryMessage] = []
        for turn in database.rows(
            """
            SELECT user_message, assistant_response, timestamp
            FROM turns WHERE session_id = ?1 ORDER BY turn_index
            """,
            bindings: [nativeID]
        ) {
            let timestampText = WakeHistoryAdapterSupport.nonempty(turn["timestamp"]?.stringValue)
            let timestamp = WakeHistoryAdapterSupport.sqliteDate(timestampText)
            if let text = WakeHistoryAdapterSupport.nonempty(turn["user_message"]?.stringValue) {
                messages.append(HistoryMessage(
                    role: "user",
                    content: [.init(type: "text", text: text)],
                    timestamp: timestamp,
                    timestampText: timestampText
                ))
            }
            if let text = WakeHistoryAdapterSupport.nonempty(
                turn["assistant_response"]?.stringValue
            ) {
                messages.append(HistoryMessage(
                    role: "assistant",
                    content: [.init(type: "text", text: text)],
                    timestamp: timestamp,
                    timestampText: timestampText
                ))
            }
        }

        let custom = ForeignHistorySupport.customMetadata(
            source: .copilot,
            sessionKey: nativeID,
            appDataRoot: input.configuration.appDataRoot
        )
        let cwd = WakeHistoryAdapterSupport.nonempty(row.cwd)
        let producerTitle = WakeHistoryAdapterSupport.nonempty(row.summary)
        let inferredTitle = HistoryParsingSupport.firstUserTitle(in: messages)
        let autoTitle = producerTitle ?? inferredTitle
        let createdAt = row.createdAt
            ?? ForeignHistorySupport.firstTimestamp(in: messages)
            ?? input.facts.createdAt
        let lastActivity = row.updatedAt
            ?? ForeignHistorySupport.lastTimestamp(in: messages)
            ?? input.facts.modifiedAt
        let metadata = HistorySessionMetadata(
            id: "copilot:\(nativeID)",
            file: input.candidate.file,
            source: .copilot,
            dirID: input.candidate.directory.id,
            dirLabel: input.candidate.directory.label,
            sessionID: nativeID,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil),
            gitBranch: WakeHistoryAdapterSupport.nonempty(row.branch),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            imported: false,
            deleted: custom.deleted,
            createdAt: createdAt,
            lastActivity: lastActivity,
            sizeBytes: row.contentLength,
            messageCount: messages.count
        )
        return HistorySession(metadata: metadata, messages: messages)
    }

    static func sqliteSessionRows(
        database: HistorySQLiteDatabase,
        id: String? = nil
    ) -> [CopilotSQLiteSessionRow] {
        guard database.tableExists("sessions"), database.tableExists("turns") else { return [] }
        let predicate = id == nil ? "" : "WHERE s.id = ?1"
        let rows = database.rows(
            """
            SELECT s.id AS id, s.cwd AS cwd, s.branch AS branch, s.summary AS summary,
                   s.created_at AS created_at, s.updated_at AS updated_at,
                   COALESCE(SUM(
                       LENGTH(COALESCE(t.user_message, ''))
                       + LENGTH(COALESCE(t.assistant_response, ''))
                   ), 0) AS content_length,
                   COUNT(t.id) AS turn_count
            FROM sessions s LEFT JOIN turns t ON t.session_id = s.id
            \(predicate)
            GROUP BY s.id
            """,
            bindings: id.map { [$0] } ?? []
        )
        return rows.compactMap { row in
            guard let nativeID = WakeHistoryAdapterSupport.nonempty(row["id"]?.stringValue) else {
                return nil
            }
            let rawLength = max(0, row["content_length"]?.int64Value ?? 0)
            let rawCount = max(0, row["turn_count"]?.int64Value ?? 0)
            return CopilotSQLiteSessionRow(
                id: nativeID,
                cwd: WakeHistoryAdapterSupport.nonempty(row["cwd"]?.stringValue),
                branch: WakeHistoryAdapterSupport.nonempty(row["branch"]?.stringValue),
                summary: WakeHistoryAdapterSupport.nonempty(row["summary"]?.stringValue),
                createdAt: WakeHistoryAdapterSupport.sqliteDate(row["created_at"]?.stringValue),
                updatedAt: WakeHistoryAdapterSupport.sqliteDate(row["updated_at"]?.stringValue),
                contentLength: UInt64(rawLength),
                turnCount: rawCount > Int64(Int.max) ? Int.max : Int(rawCount)
            )
        }
    }

    private static func normalize(_ records: [[String: HistoryValue]]) -> CopilotNormalizedTranscript {
        var result = CopilotNormalizedTranscript()
        for record in records {
            let type = record["type"]?.stringValue ?? ""
            let data = record["data"]?.objectValue ?? [:]
            let timestampText = record["timestamp"]?.stringValue
            switch type {
            case "session.start":
                result.sessionID = result.sessionID ?? data["sessionId"]?.stringValue
                result.version = result.version ?? data["copilotVersion"]?.stringValue
                result.cwd = result.cwd ?? data["context"]?["cwd"]?.stringValue
                result.gitBranch = result.gitBranch ?? data["context"]?["branch"]?.stringValue
            case "session.model_change":
                if let model = data["newModel"]?.stringValue { result.model = model }
            case "user.message":
                guard let text = data["content"]?.stringValue,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.messages.append(message(
                    role: "user",
                    blocks: [.init(type: "text", text: text)],
                    timestampText: timestampText
                ))
            case "assistant.message":
                if let model = data["model"]?.stringValue { result.model = model }
                var blocks: [HistoryContentBlock] = []
                if let text = data["content"]?.stringValue,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.init(type: "text", text: text))
                }
                for call in data["toolRequests"]?.arrayValue ?? [] {
                    let originalName = call["name"]?.stringValue ?? "tool"
                    let arguments = call["arguments"] ?? .object([:])
                    let mapped = mapTool(originalName, arguments: arguments)
                    blocks.append(.init(
                        type: "tool_use",
                        id: call["toolCallId"]?.stringValue ?? "",
                        name: mapped.0,
                        input: mapped.1,
                        raw: call
                    ))
                }
                if !blocks.isEmpty {
                    result.messages.append(message(
                        role: "assistant",
                        blocks: blocks,
                        timestampText: timestampText,
                        model: result.model
                    ))
                }
            case "tool.execution_complete":
                let content = data["result"]?["content"]?.stringValue ?? ""
                result.messages.append(message(
                    role: "user",
                    blocks: [.init(
                        type: "tool_result",
                        toolUseID: data["toolCallId"]?.stringValue ?? "",
                        content: .string(content),
                        isError: data["success"]?.boolValue == false ? true : nil,
                        raw: .object(record)
                    )],
                    timestampText: timestampText
                ))
            default:
                continue
            }
        }
        return result
    }

    private static func message(
        role: String,
        blocks: [HistoryContentBlock],
        timestampText: String?,
        model: String? = nil
    ) -> HistoryMessage {
        HistoryMessage(
            role: role,
            content: blocks,
            timestamp: HistoryDateParser.parse(timestampText),
            timestampText: timestampText,
            modelActual: model
        )
    }

    private static func sessionUUID(_ file: URL) -> String {
        file.lastPathComponent == "events.jsonl"
            ? file.deletingLastPathComponent().lastPathComponent
            : file.deletingPathExtension().lastPathComponent
    }

    private static func workspaceMetadata(for file: URL) -> [String: String] {
        guard file.lastPathComponent == "events.jsonl",
              let text = ForeignHistorySupport.textFile(
                at: file.deletingLastPathComponent().appendingPathComponent("workspace.yaml")
              ) else { return [:] }
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.hasPrefix("#"), !value.isEmpty else { continue }
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private static func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func mapTool(_ name: String, arguments: HistoryValue) -> (String, HistoryValue) {
        let object = arguments.objectValue ?? [:]
        func string(_ key: String) -> String { object[key]?.stringValue ?? "" }
        func kept() -> HistoryValue { .object(object) }

        switch name {
        case "bash":
            var input: [String: HistoryValue] = ["command": .string(string("command"))]
            if !string("description").isEmpty { input["description"] = .string(string("description")) }
            return ("Bash", .object(input))
        case "view": return ("Read", .object(["file_path": .string(string("path"))]))
        case "edit", "str_replace":
            return ("Edit", .object([
                "file_path": .string(string("path")),
                "old_string": .string(string("old_str")),
                "new_string": .string(string("new_str")),
            ]))
        case "create":
            return ("Write", .object([
                "file_path": .string(string("path")),
                "content": .string(string("file_text")),
            ]))
        case "rg":
            var input: [String: HistoryValue] = ["pattern": .string(string("pattern"))]
            if let paths = object["paths"] {
                if let array = paths.arrayValue {
                    input["path"] = .string(array.compactMap(\.stringValue).joined(separator: " "))
                } else {
                    input["path"] = paths
                }
            }
            if !string("glob").isEmpty { input["glob"] = .string(string("glob")) }
            return ("Grep", .object(input))
        case "glob":
            return ("Glob", .object([
                "pattern": .string(string("pattern")),
                "path": .string(string("paths")),
            ]))
        case "apply_patch": return ("ApplyPatch", .object(["patch": .string(string("str"))]))
        default: return (name, kept())
        }
    }
}
