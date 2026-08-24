import Foundation

private struct AntigravityNormalizedTranscript {
    var messages: [HistoryMessage] = []
    var totals = HistoryTotals()
    var cwd: String?
    var firstStepTimestamp: Date?
}

private struct AntigravitySummary {
    var title: String
    var preview: String
    var cwd: String?
}

struct AntigravitySQLiteSummaryRow: Sendable {
    var id: String
    var title: String
    var preview: String
    var stepCount: Int
    var modifiedAt: Date?
    var cwd: String?

    var contentLength: UInt64 {
        UInt64(title.utf8.count) + UInt64(preview.utf8.count)
    }
}

enum AntigravityHistoryParser {
    static func parse(
        candidate: HistoryFileCandidate,
        facts: HistoryFileFacts,
        appDataRoot: URL
    ) -> HistorySession {
        if candidate.backingFile != nil {
            return parseSummaryDatabase(
                candidate: candidate,
                facts: facts,
                appDataRoot: appDataRoot
            )
        }
        let uuid = candidate.file.deletingPathExtension().lastPathComponent
        let summary = summary(for: candidate.file, uuid: uuid)
        var normalized = normalizeDatabase(candidate.file)
        normalized.cwd = summary?.cwd ?? normalized.cwd ?? fallbackCWD(candidate.file)
        let custom = ForeignHistorySupport.customMetadata(
            source: .antigravity,
            sessionKey: uuid,
            appDataRoot: appDataRoot
        )
        let summaryTitle = summary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = summary?.preview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let autoTitle: String
        if !summaryTitle.isEmpty {
            autoTitle = summaryTitle
        } else if !preview.isEmpty {
            autoTitle = String(preview.prefix(90))
        } else {
            autoTitle = fallbackTitle.isEmpty ? uuid : fallbackTitle
        }

        let metadata = HistorySessionMetadata(
            id: "antigravity:\(uuid)",
            file: candidate.file,
            source: .antigravity,
            dirID: candidate.directory.id,
            dirLabel: candidate.directory.label,
            sessionID: uuid,
            cwd: normalized.cwd,
            project: HistoryParsingSupport.projectName(cwd: normalized.cwd, encodedDirectory: nil),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            imported: false,
            deleted: custom.deleted,
            createdAt: normalized.firstStepTimestamp ?? facts.createdAt,
            lastActivity: walAwareModifiedAt(candidate.file, fallback: facts.modifiedAt),
            sizeBytes: facts.sizeBytes,
            totals: normalized.totals,
            messageCount: normalized.messages.count
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    static func sqliteSummaryRows(
        database: HistorySQLiteDatabase,
        id: String? = nil
    ) -> [AntigravitySQLiteSummaryRow] {
        guard database.tableExists("conversation_summaries") else { return [] }
        let idPredicate = id == nil ? "" : "AND conversation_id = ?1"
        return database.rows(
            """
            SELECT conversation_id, title, preview, step_count, last_modified_time,
                   workspace_uris
            FROM conversation_summaries
            WHERE parent_conversation_id = '' AND nesting_depth = 0 \(idPredicate)
            """,
            bindings: id.map { [$0] } ?? []
        ).compactMap { row in
            guard let nativeID = WakeHistoryAdapterSupport.nonempty(
                row["conversation_id"]?.stringValue
            ) else { return nil }
            let rawStepCount = max(0, row["step_count"]?.int64Value ?? 0)
            return AntigravitySQLiteSummaryRow(
                id: nativeID,
                title: row["title"]?.stringValue ?? "",
                preview: row["preview"]?.stringValue ?? "",
                stepCount: rawStepCount > Int64(Int.max) ? Int.max : Int(rawStepCount),
                modifiedAt: WakeHistoryAdapterSupport.sqliteDate(
                    row["last_modified_time"]?.stringValue
                ),
                cwd: firstWorkspace(row["workspace_uris"]?.stringValue)
            )
        }
    }

    private static func parseSummaryDatabase(
        candidate: HistoryFileCandidate,
        facts: HistoryFileFacts,
        appDataRoot: URL
    ) -> HistorySession {
        let databaseFile = candidate.primaryStorageFile
        let nativeID = WakeHistoryAdapterSupport.nativeID(candidate)
        guard let database = HistorySQLiteDatabase(databaseFile),
              let row = sqliteSummaryRows(database: database, id: nativeID).first else {
            let custom = ForeignHistorySupport.customMetadata(
                source: .antigravity,
                sessionKey: nativeID,
                appDataRoot: appDataRoot
            )
            let metadata = HistorySessionMetadata(
                id: "antigravity:\(nativeID)",
                file: candidate.file,
                source: .antigravity,
                dirID: candidate.directory.id,
                dirLabel: candidate.directory.label,
                sessionID: nativeID,
                project: "",
                title: custom.title ?? nativeID,
                autoTitle: nativeID,
                tags: custom.tags,
                imported: false,
                deleted: custom.deleted,
                createdAt: facts.createdAt,
                lastActivity: facts.modifiedAt,
                sizeBytes: facts.sizeBytes
            )
            return HistorySession(metadata: metadata, messages: [])
        }

        let preview = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = preview
        if !detail.isEmpty { detail += "\n\n" }
        detail += "Antigravity stores conversation content encrypted — only this summary is available in CC Buddy."
        let timestampText = WakeHistoryAdapterSupport.timestampText(row.modifiedAt)
        let messages = [HistoryMessage(
            role: "system",
            content: [.init(type: "text", text: detail)],
            timestamp: row.modifiedAt,
            timestampText: timestampText,
            isMetadata: true
        )]
        let custom = ForeignHistorySupport.customMetadata(
            source: .antigravity,
            sessionKey: nativeID,
            appDataRoot: appDataRoot
        )
        let producerTitle = WakeHistoryAdapterSupport.nonempty(row.title)
            ?? WakeHistoryAdapterSupport.nonempty(preview)
            .map { String($0.prefix(90)) }
        let autoTitle = producerTitle ?? nativeID
        let timestamp = row.modifiedAt ?? facts.modifiedAt
        let metadata = HistorySessionMetadata(
            id: "antigravity:\(nativeID)",
            file: candidate.file,
            source: .antigravity,
            dirID: candidate.directory.id,
            dirLabel: candidate.directory.label,
            sessionID: nativeID,
            cwd: row.cwd,
            project: HistoryParsingSupport.projectName(cwd: row.cwd, encodedDirectory: nil),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            imported: false,
            deleted: custom.deleted,
            createdAt: timestamp,
            lastActivity: timestamp,
            sizeBytes: row.contentLength,
            messageCount: row.stepCount
        )
        return HistorySession(metadata: metadata, messages: messages)
    }

    private static func normalizeDatabase(_ file: URL) -> AntigravityNormalizedTranscript {
        var result = AntigravityNormalizedTranscript()
        guard let database = HistorySQLiteDatabase(file) else { return result }
        let payloads = database.dataColumn("SELECT step_payload FROM steps ORDER BY idx")
        if let first = payloads.first,
           let root = AntigravityWireMessage.decode(first),
           let timestamp = root.message(5)?.timestamp(1) {
            result.firstStepTimestamp = HistoryDateParser.parse(timestamp)
        }
        for payload in payloads { pushStep(payload, into: &result) }
        return result
    }

    private static func pushStep(_ payload: Data, into transcript: inout AntigravityNormalizedTranscript) {
        guard let root = AntigravityWireMessage.decode(payload) else { return }
        let metadata = root.message(5)
        let timestampText = metadata?.timestamp(1)

        if let user = root.message(19) {
            var blocks: [HistoryContentBlock] = []
            if let text = user.string(2), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.init(type: "text", text: text))
            }
            for attachment in user.messages(9) {
                let mime = attachment.string(1) ?? ""
                if let data = attachment.bytes(2), mime.hasPrefix("image/"), data.count <= 8_000_000 {
                    let raw: HistoryValue = .object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string(mime),
                            "data": .string(data.base64EncodedString()),
                        ]),
                    ])
                    blocks.append(.init(type: "image", raw: raw))
                } else if let path = attachment.string(5) {
                    blocks.append(.init(type: "text", text: "[attachment: \(path)]"))
                }
            }
            if !blocks.isEmpty {
                transcript.messages.append(message(
                    role: "user",
                    blocks: blocks,
                    timestampText: timestampText
                ))
            }
            return
        }

        if let call = metadata?.message(4) {
            let originalName = call.string(2) ?? "tool"
            let arguments: HistoryValue
            if let json = call.string(3), let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(HistoryValue.self, from: data) {
                arguments = decoded
            } else {
                arguments = .object([:])
            }
            let mapped = mapTool(originalName, arguments: arguments)
            transcript.messages.append(message(
                role: "assistant",
                blocks: [.init(
                    type: "tool_use",
                    id: call.string(1) ?? "",
                    name: mapped.0,
                    input: mapped.1
                )],
                timestampText: timestampText
            ))
            return
        }

        let turn = root.message(20)
        guard let text = turn?.string(1) ?? turn?.string(8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var usage: HistoryUsage?
        if let stats = metadata?.message(9) {
            let input = boundedInt(stats.varint(2) ?? 0)
            let output = boundedInt(stats.varint(3) ?? 0)
            if input > 0 || output > 0 {
                let value = HistoryUsage(inputTokens: input, outputTokens: output)
                transcript.totals.add(value)
                usage = value
            }
        }
        var value = message(
            role: "assistant",
            blocks: [.init(type: "text", text: text)],
            timestampText: timestampText
        )
        value.usage = usage
        transcript.messages.append(value)
    }

    private static func message(
        role: String,
        blocks: [HistoryContentBlock],
        timestampText: String?
    ) -> HistoryMessage {
        HistoryMessage(
            role: role,
            content: blocks,
            timestamp: HistoryDateParser.parse(timestampText),
            timestampText: timestampText
        )
    }

    private static func summary(for file: URL, uuid: String) -> AntigravitySummary? {
        let summaryFile = file.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conversation_summaries.db")
        guard let database = HistorySQLiteDatabase(summaryFile),
              let row = database.textRow(
                "SELECT title, preview, workspace_uris FROM conversation_summaries WHERE conversation_id = ?1",
                bindings: [uuid]
              ), row.count == 3 else { return nil }
        let cwd: String?
        if let data = row[2].data(using: .utf8),
           let value = try? JSONDecoder().decode(HistoryValue.self, from: data),
           let uri = value.arrayValue?.first?.stringValue {
            cwd = workspacePath(uri)
        } else {
            cwd = nil
        }
        return AntigravitySummary(title: row[0], preview: row[1], cwd: cwd)
    }

    private static func fallbackCWD(_ file: URL) -> String? {
        guard let database = HistorySQLiteDatabase(file),
              let blob = database.dataColumn("SELECT data FROM trajectory_metadata_blob LIMIT 1").first,
              let uri = AntigravityWireSearch.firstString(in: blob, withPrefix: "file://") else {
            return nil
        }
        return workspacePath(uri)
    }

    private static func workspacePath(_ uri: String) -> String {
        let value = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
        return ForeignHistorySupport.percentDecode(value)
    }

    private static func firstWorkspace(_ rawValue: String?) -> String? {
        guard let value = WakeHistoryAdapterSupport.historyValue(json: rawValue),
              let uri = value.arrayValue?.first?.stringValue else { return nil }
        return WakeHistoryAdapterSupport.nonempty(workspacePath(uri))
    }

    private static func walAwareModifiedAt(_ file: URL, fallback: Date) -> Date {
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let modified: (URL) -> Date? = {
            guard ForeignHistorySupport.isOrdinaryFile($0) else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
        }
        return [modified(file), modified(wal), fallback].compactMap { $0 }.max() ?? fallback
    }

    private static func boundedInt(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func mapTool(_ name: String, arguments: HistoryValue) -> (String, HistoryValue) {
        var object = arguments.objectValue ?? [:]
        func string(_ key: String) -> String { object[key]?.stringValue ?? "" }
        switch name {
        case "run_command":
            var input: [String: HistoryValue] = ["command": .string(string("CommandLine"))]
            if !string("Cwd").isEmpty { input["description"] = .string(string("Cwd")) }
            return ("Bash", .object(input))
        case "view_file": return ("Read", .object(["file_path": .string(string("AbsolutePath"))]))
        case "list_dir": return ("LS", .object(["path": .string(string("DirectoryPath"))]))
        case "grep_search":
            var input: [String: HistoryValue] = ["pattern": .string(string("Query"))]
            if !string("SearchPath").isEmpty { input["path"] = .string(string("SearchPath")) }
            return ("Grep", .object(input))
        case "find_by_name":
            return ("Glob", .object([
                "pattern": .string(string("Pattern")),
                "path": .string(string("SearchDirectory")),
            ]))
        case "replace_file_content":
            return ("Edit", .object([
                "file_path": .string(string("TargetFile")),
                "old_string": .string(string("TargetContent")),
                "new_string": .string(string("ReplacementContent")),
            ]))
        case "write_to_file":
            return ("Write", .object([
                "file_path": .string(string("TargetFile")),
                "content": .string(string("CodeContent")),
            ]))
        case "read_url_content": return ("WebFetch", .object(["url": .string(string("Url"))]))
        case "search_web": return ("WebSearch", .object(["query": .string(string("query"))]))
        default:
            object.removeValue(forKey: "toolAction")
            object.removeValue(forKey: "toolSummary")
            return (name, .object(object))
        }
    }
}
