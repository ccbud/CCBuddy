import Foundation

private struct OpenCodeSessionRow {
    var id: String
    var directory: String
    var title: String
    var createdAt: Date?
    var updatedAt: Date?
    var model: String?
    var tokenCount: Int
    var archived: Bool
    var version: String?
    var contentLength: UInt64
    var isV2: Bool
}

private struct OpenCodeNormalizedTranscript {
    var messages: [HistoryMessage] = []
    var totals = HistoryTotals()
    var model: String?
    var diagnostics = HistoryReadDiagnostics()
}

enum OpenCodeHistoryParser {
    /// Wake treats the current database schema as a distinct `opencode2` source for resume.
    /// CC Buddy keeps one public source enum and stores the discriminator in metadata.version.
    static let v2VersionMarker = "opencode2"

    static func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        let databaseFile = input.candidate.primaryStorageFile
        guard let database = HistorySQLiteDatabase(databaseFile) else {
            throw HistoryError.unreadableFile(databaseFile, "无法只读打开 OpenCode 数据库")
        }
        let nativeID = WakeHistoryAdapterSupport.nativeID(input.candidate)
        guard let row = OpenCodeStore.sessionRows(database: database, id: nativeID).first else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        let normalized = row.isV2
            ? normalizeV2(database: database, sessionID: nativeID)
            : normalizeV1(database: database, sessionID: nativeID)
        let custom = ForeignHistorySupport.customMetadata(
            source: .opencode,
            sessionKey: nativeID,
            appDataRoot: input.configuration.appDataRoot
        )
        let producerTitle = WakeHistoryAdapterSupport.nonempty(row.title)
        let inferredTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let autoTitle = producerTitle ?? inferredTitle
        let model = normalized.model ?? row.model
        let createdAt = row.createdAt
            ?? ForeignHistorySupport.firstTimestamp(in: normalized.messages)
            ?? input.facts.createdAt
        let lastActivity = row.updatedAt
            ?? ForeignHistorySupport.lastTimestamp(in: normalized.messages)
            ?? input.facts.modifiedAt
        let metadata = HistorySessionMetadata(
            id: "opencode:\(nativeID)",
            file: input.candidate.file,
            source: .opencode,
            dirID: input.candidate.directory.id,
            dirLabel: input.candidate.directory.label,
            sessionID: nativeID,
            cwd: WakeHistoryAdapterSupport.nonempty(row.directory),
            project: HistoryParsingSupport.projectName(cwd: row.directory, encodedDirectory: nil),
            version: versionMetadata(producerVersion: row.version, isV2: row.isV2),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: model,
            imported: false,
            deleted: custom.deleted,
            createdAt: createdAt,
            lastActivity: lastActivity,
            sizeBytes: row.contentLength,
            totals: normalized.totals,
            messageCount: normalized.messages.lazy.filter { !$0.isMetadata }.count,
            diagnostics: normalized.diagnostics
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    private static func versionMetadata(producerVersion: String?, isV2: Bool) -> String? {
        guard isV2 else { return WakeHistoryAdapterSupport.nonempty(producerVersion) }
        guard let producerVersion = WakeHistoryAdapterSupport.nonempty(producerVersion) else {
            return v2VersionMarker
        }
        return "\(v2VersionMarker):\(producerVersion)"
    }

    private static func normalizeV1(
        database: HistorySQLiteDatabase,
        sessionID: String
    ) -> OpenCodeNormalizedTranscript {
        var result = OpenCodeNormalizedTranscript()
        var partsByMessage: [String: [HistoryValue]] = [:]
        for row in database.rows(
            "SELECT message_id, data FROM part WHERE session_id = ?1 ORDER BY message_id, id",
            bindings: [sessionID]
        ) {
            guard let messageID = row["message_id"]?.stringValue,
                  let value = WakeHistoryAdapterSupport.historyValue(json: row["data"]?.stringValue) else {
                result.diagnostics.malformedLines += 1
                continue
            }
            partsByMessage[messageID, default: []].append(value)
        }

        let messageColumns = database.columnNames(in: "message")
        let timeOrder = messageColumns.contains("time_created") ? "time_created, id" : "id"
        for row in database.rows(
            "SELECT id, data FROM message WHERE session_id = ?1 ORDER BY \(timeOrder)",
            bindings: [sessionID]
        ) {
            guard let messageID = row["id"]?.stringValue,
                  let envelope = WakeHistoryAdapterSupport.historyValue(
                    json: row["data"]?.stringValue
                  )?.objectValue else {
                result.diagnostics.malformedLines += 1
                continue
            }
            result.diagnostics.decodedLines += 1
            let role = envelope["role"]?.stringValue ?? "system"
            let model = modelID(in: envelope) ?? result.model
            if let model { result.model = model }
            let timestamp = WakeHistoryAdapterSupport.date(envelope["time"]?["created"])
            let blocks = normalizeBlocks(partsByMessage.removeValue(forKey: messageID) ?? [])
            guard !blocks.content.isEmpty else { continue }
            let usage = usage(envelope["tokens"])
            if let usage { result.totals.add(usage) }
            result.messages.append(HistoryMessage(
                role: normalizedRole(role),
                content: blocks.content,
                timestamp: timestamp,
                timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                modelActual: normalizedRole(role) == "assistant" ? model : nil,
                usage: usage,
                stopReason: envelope["finish"]?.stringValue,
                isMetadata: blocks.onlySynthetic
            ))
        }
        return result
    }

    private static func normalizeV2(
        database: HistorySQLiteDatabase,
        sessionID: String
    ) -> OpenCodeNormalizedTranscript {
        var result = OpenCodeNormalizedTranscript()
        for row in database.rows(
            "SELECT type, data FROM session_message WHERE session_id = ?1 ORDER BY seq",
            bindings: [sessionID]
        ) {
            guard let type = row["type"]?.stringValue,
                  let envelope = WakeHistoryAdapterSupport.historyValue(
                    json: row["data"]?.stringValue
                  )?.objectValue else {
                result.diagnostics.malformedLines += 1
                continue
            }
            result.diagnostics.decodedLines += 1
            let timestamp = WakeHistoryAdapterSupport.date(envelope["time"]?["created"])
            switch type {
            case "user", "synthetic":
                guard let text = WakeHistoryAdapterSupport.nonempty(envelope["text"]?.stringValue) else {
                    continue
                }
                result.messages.append(HistoryMessage(
                    role: "user",
                    content: [.init(type: "text", text: text)],
                    timestamp: timestamp,
                    timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                    isMetadata: type == "synthetic"
                ))
            case "assistant":
                let model = modelID(in: envelope) ?? result.model
                if let model { result.model = model }
                let blocks = normalizeBlocks(envelope["content"]?.arrayValue ?? [])
                guard !blocks.content.isEmpty else { continue }
                let usage = usage(envelope["tokens"] ?? envelope["usage"])
                if let usage { result.totals.add(usage) }
                result.messages.append(HistoryMessage(
                    role: "assistant",
                    content: blocks.content,
                    timestamp: timestamp,
                    timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                    modelActual: model,
                    usage: usage,
                    stopReason: envelope["finish"]?.stringValue
                ))
            default:
                result.diagnostics.malformedLines += 1
            }
        }
        return result
    }

    private static func normalizeBlocks(
        _ values: [HistoryValue]
    ) -> (content: [HistoryContentBlock], onlySynthetic: Bool) {
        var content: [HistoryContentBlock] = []
        var ordinaryText = false
        var syntheticText = false
        for value in values {
            guard let object = value.objectValue else { continue }
            switch object["type"]?.stringValue ?? "" {
            case "text":
                guard let text = WakeHistoryAdapterSupport.nonempty(object["text"]?.stringValue) else {
                    continue
                }
                if object["synthetic"]?.boolValue == true {
                    syntheticText = true
                } else {
                    ordinaryText = true
                }
                content.append(.init(type: "text", text: text, raw: value))
            case "reasoning":
                guard let text = WakeHistoryAdapterSupport.nonempty(object["text"]?.stringValue) else {
                    continue
                }
                content.append(.init(type: "thinking", thinking: text, raw: value))
            case "tool":
                let state = object["state"]?.objectValue ?? [:]
                let callID = object["callID"]?.stringValue
                let output = state["output"] ?? state["error"]
                content.append(.init(
                    type: "tool_use",
                    id: callID,
                    name: WakeHistoryAdapterSupport.nonempty(object["tool"]?.stringValue) ?? "tool",
                    input: state["input"] ?? .object([:]),
                    raw: value
                ))
                if output != nil {
                    content.append(.init(
                        type: "tool_result",
                        toolUseID: callID,
                        content: output,
                        isError: state["status"]?.stringValue == "error",
                        raw: value
                    ))
                }
            case "step-start", "step-finish", "snapshot", "patch", "file":
                continue
            default:
                continue
            }
        }
        return (content, !ordinaryText && syntheticText)
    }

    private static func usage(_ value: HistoryValue?) -> HistoryUsage? {
        guard let object = value?.objectValue else { return nil }
        let cache = object["cache"]?.objectValue ?? [:]
        let result = HistoryUsage(
            inputTokens: object["input"]?.integerValue
                ?? object["input_tokens"]?.integerValue
                ?? 0,
            outputTokens: (object["output"]?.integerValue ?? 0)
                + (object["reasoning"]?.integerValue ?? 0),
            cacheRead: cache["read"]?.integerValue
                ?? object["cache_read_input_tokens"]?.integerValue
                ?? 0,
            cacheCreation: cache["write"]?.integerValue
                ?? object["cache_creation_input_tokens"]?.integerValue
                ?? 0
        )
        return result.inputTokens == 0 && result.outputTokens == 0
            && result.cacheRead == 0 && result.cacheCreation == 0 ? nil : result
    }

    private static func modelID(in envelope: [String: HistoryValue]) -> String? {
        WakeHistoryAdapterSupport.nonempty(envelope["modelID"]?.stringValue)
            ?? WakeHistoryAdapterSupport.nonempty(envelope["model"]?["id"]?.stringValue)
            ?? WakeHistoryAdapterSupport.nonempty(envelope["model"]?["modelID"]?.stringValue)
    }

    private static func normalizedRole(_ value: String) -> String {
        switch value {
        case "user", "assistant": return value
        default: return "system"
        }
    }
}

private enum OpenCodeStore {
    static func sessionRows(
        database: HistorySQLiteDatabase,
        id: String? = nil
    ) -> [OpenCodeSessionRow] {
        var result: [OpenCodeSessionRow] = []
        var seen = Set<String>()
        if database.tableExists("session_v2") {
            for row in rows(database: database, table: "session_v2", v2: true, id: id)
                where seen.insert(row.id).inserted {
                result.append(row)
            }
        }
        if database.tableExists("session") {
            for row in rows(database: database, table: "session", v2: false, id: id)
                where seen.insert(row.id).inserted {
                result.append(row)
            }
        }
        return result
    }

    private static func rows(
        database: HistorySQLiteDatabase,
        table: String,
        v2: Bool,
        id: String?
    ) -> [OpenCodeSessionRow] {
        let columns = database.columnNames(in: table)
        guard columns.contains("id") else { return [] }
        func expression(_ column: String, fallback: String = "NULL") -> String {
            columns.contains(column) ? "s.\(column)" : fallback
        }
        let contentTable = v2 ? "session_message" : "part"
        let contentExpression: String
        if database.tableExists(contentTable) {
            contentExpression = "(SELECT COALESCE(SUM(LENGTH(c.data)), 0) FROM \(contentTable) c WHERE c.session_id = s.id)"
        } else {
            contentExpression = "0"
        }
        let tokenExpression: String
        if columns.isSuperset(of: ["tokens_input", "tokens_output", "tokens_reasoning"]) {
            tokenExpression = "COALESCE(s.tokens_input,0) + COALESCE(s.tokens_output,0) + COALESCE(s.tokens_reasoning,0)"
        } else {
            tokenExpression = "0"
        }
        var predicates: [String] = []
        var bindings: [String] = []
        if columns.contains("parent_id") { predicates.append("s.parent_id IS NULL") }
        if let id {
            predicates.append("s.id = ?1")
            bindings.append(id)
        }
        let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let sql = """
        SELECT s.id AS id,
               \(expression("directory", fallback: "''")) AS directory,
               \(expression("title", fallback: "''")) AS title,
               \(expression("time_created", fallback: "0")) AS time_created,
               \(expression("time_updated", fallback: "0")) AS time_updated,
               \(expression("model", fallback: "NULL")) AS model,
               \(tokenExpression) AS token_count,
               \(expression("time_archived", fallback: "NULL")) AS time_archived,
               \(expression("version", fallback: "NULL")) AS version,
               \(contentExpression) AS content_length
        FROM \(table) s\(whereClause)
        """
        return database.rows(sql, bindings: bindings).compactMap { row in
            guard let id = WakeHistoryAdapterSupport.nonempty(row["id"]?.stringValue) else {
                return nil
            }
            let model = WakeHistoryAdapterSupport.historyValue(json: row["model"]?.stringValue)
                .flatMap { WakeHistoryAdapterSupport.nonempty($0["id"]?.stringValue) }
            let contentLength = max(0, row["content_length"]?.int64Value ?? 0)
            return OpenCodeSessionRow(
                id: id,
                directory: row["directory"]?.stringValue ?? "",
                title: row["title"]?.stringValue ?? "",
                createdAt: WakeHistoryAdapterSupport.date(
                    milliseconds: row["time_created"]?.int64Value ?? 0
                ),
                updatedAt: WakeHistoryAdapterSupport.date(
                    milliseconds: row["time_updated"]?.int64Value ?? 0
                ),
                model: model,
                tokenCount: WakeHistoryAdapterSupport.integer(row["token_count"]),
                archived: row["time_archived"]?.int64Value != nil,
                version: WakeHistoryAdapterSupport.nonempty(row["version"]?.stringValue),
                contentLength: UInt64(contentLength),
                isV2: v2
            )
        }
    }
}

struct OpenCodeConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.opencode
    let format = HistoryTranscriptFormat.opencode

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let databaseFile = configuration.primaryDataRoot(
            for: source,
            default: configuration.openCodeDefaultDatabase
        )
        guard WakeHistoryAdapterSupport.ordinaryFile(databaseFile),
              (configuration.activeSessionLocation?.source == source
                || databaseFile.standardizedFileURL
                    == configuration.openCodeDefaultDatabase.standardizedFileURL
                || WakeHistoryAdapterSupport.isContainedInHome(
                    databaseFile,
                    homeDirectory: configuration.homeDirectory
                )),
              let database = HistorySQLiteDatabase(databaseFile) else { return [] }
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "OpenCode",
            baseURL: databaseFile.deletingLastPathComponent()
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        return OpenCodeStore.sessionRows(database: database).compactMap { row in
            guard row.contentLength > 0 else { return nil }
            return HistoryFileCandidate(
                file: WakeHistoryAdapterSupport.virtualSessionURL(
                    database: databaseFile,
                    nativeID: row.id
                ),
                projectDirectoryName: nil,
                directory: directory,
                formatHint: format,
                nativeID: row.id,
                backingFile: databaseFile
            )
        }
    }

    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument? {
        nil
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.openCodeDefaultDatabase
        ).deletingLastPathComponent()
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        sqliteDependencies(candidate.primaryStorageFile) + [
            .init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        try OpenCodeHistoryParser.parse(input)
    }

    private func sqliteDependencies(_ database: URL) -> [ConversationSourceDependency] {
        [
            .init(file: database, role: .primaryDatabase),
            .init(
                file: URL(fileURLWithPath: database.path + "-wal"),
                role: .sqliteWriteAheadLog
            ),
            .init(
                file: URL(fileURLWithPath: database.path + "-shm"),
                role: .sqliteSharedMemory,
                contributesToFingerprint: false
            ),
        ]
    }
}
