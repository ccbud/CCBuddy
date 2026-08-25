import Foundation

enum QoderHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let records = normalize(context.document.records)
        var messages: [HistoryMessage] = []
        var totals = HistoryTotals()
        var assistantModel: String?

        for record in records {
            let type = record["type"]?.stringValue ?? ""
            guard type == "user" || type == "assistant",
                  record["isMeta"]?.boolValue != true,
                  let envelope = record["message"]?.objectValue,
                  let role = envelope["role"]?.stringValue else { continue }
            let usage = type == "assistant" ? HistoryParsingSupport.usage(from: envelope["usage"]) : nil
            if let usage { totals.add(usage) }
            if type == "assistant", let model = ForeignHistorySupport.trimmed(envelope["model"]) {
                assistantModel = model
            }
            let timestampText = record["timestamp"]?.stringValue
            messages.append(HistoryMessage(
                role: role,
                content: HistoryParsingSupport.blocks(from: envelope["content"]),
                timestamp: HistoryDateParser.parse(timestampText),
                timestampText: timestampText,
                modelActual: type == "assistant" ? envelope["model"]?.stringValue : nil,
                usage: usage,
                stopReason: type == "assistant" ? envelope["stop_reason"]?.stringValue : nil,
                isSidechain: record["isSidechain"]?.boolValue ?? false
            ))
        }

        let metadataRecord = records.first(where: { $0["cwd"] != nil })
            ?? records.first(where: { $0["sessionId"] != nil })
        let stem = context.candidate.file.deletingPathExtension().lastPathComponent
        let sessionID = metadataRecord?["sessionId"]?.stringValue ?? stem
        let inlineTitle = sessionTitle(from: context.document.records)
        let autoTitle = inlineTitle ?? HistoryParsingSupport.firstUserTitle(in: messages)
        let cwd = workingDirectory(from: context.document.records)
            ?? metadataRecord?["cwd"]?.stringValue
            ?? context.candidate.projectDirectoryName.flatMap(HistoryPathResolver.decodeProjectDirectoryName)
        let runtimeModel = latestInlineString(
            records: context.document.records,
            recordType: "runtime-config",
            field: "model"
        )
        let custom: ConversationCustomMetadata
        if context.candidate.directory.id == "__imported__" {
            custom = HistoryParsingSupport.customMetadata(context.document.records)
        } else {
            custom = ForeignHistorySupport.customMetadata(
                source: .qoder,
                sessionKey: stem,
                appDataRoot: context.appDataRoot
            )
        }
        let summary = records.first(where: {
            $0["type"]?.stringValue == "summary" && $0["summary"] != nil
        })?["summary"]
        let version = records.lazy.compactMap { $0["version"]?.stringValue }.first
        let gitBranch = records.lazy.compactMap { $0["gitBranch"]?.stringValue }.first

        let metadata = HistorySessionMetadata(
            id: "qoder:\(stem)",
            file: context.candidate.file,
            source: .qoder,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: sessionID,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(
                cwd: cwd,
                encodedDirectory: context.candidate.projectDirectoryName
            ),
            gitBranch: gitBranch,
            version: version,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            summary: summary,
            model: runtimeModel ?? assistantModel,
            imported: context.candidate.directory.id == "__imported__",
            deleted: custom.deleted,
            starred: custom.starred,
            createdAt: context.facts.createdAt,
            lastActivity: context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            totals: totals,
            messageCount: messages.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: messages)
    }

    static func normalize(_ records: [[String: HistoryValue]]) -> [[String: HistoryValue]] {
        var result: [[String: HistoryValue]] = []
        var assistantPositions: [String: Int] = [:]

        for record in records {
            if record["type"]?.stringValue == "attachment",
               record["attachment"]?["type"]?.stringValue == "queued_command" {
                var user = record
                user["type"] = .string("user")
                user["message"] = .object([
                    "role": .string("user"),
                    "content": .string(record["attachment"]?["prompt"]?.stringValue ?? ""),
                ])
                user.removeValue(forKey: "attachment")
                result.append(user)
                continue
            }
            guard record["type"]?.stringValue == "assistant" else {
                result.append(record)
                continue
            }

            var wrapper = record
            if var message = wrapper["message"]?.objectValue,
               let content = message["content"]?.arrayValue {
                message["content"] = .array(content.filter {
                    $0["type"]?.stringValue != "redacted_thinking"
                })
                wrapper["message"] = .object(message)
            }
            let messageID = wrapper["message"]?["id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let messageID, !messageID.isEmpty else {
                result.append(wrapper)
                continue
            }
            if let index = assistantPositions[messageID] {
                result[index] = merge(result[index], with: wrapper)
            } else {
                assistantPositions[messageID] = result.count
                result.append(wrapper)
            }
        }
        return result
    }

    private static func merge(
        _ targetRecord: [String: HistoryValue],
        with sourceRecord: [String: HistoryValue]
    ) -> [String: HistoryValue] {
        guard var targetMessage = targetRecord["message"]?.objectValue,
              let sourceMessage = sourceRecord["message"]?.objectValue else { return targetRecord }
        if let sourceContent = sourceMessage["content"]?.arrayValue {
            if let targetContent = targetMessage["content"]?.arrayValue {
                targetMessage["content"] = .array(targetContent + sourceContent)
            } else if targetMessage["content"] == nil || targetMessage["content"] == .null {
                targetMessage["content"] = .array(sourceContent)
            }
        }
        for field in ["model", "usage", "stop_reason"]
            where ForeignHistorySupport.meaningful(sourceMessage[field]) {
            targetMessage[field] = sourceMessage[field]
        }
        var target = targetRecord
        target["message"] = .object(targetMessage)
        return target
    }

    private static func sessionTitle(from records: [[String: HistoryValue]]) -> String? {
        latestInlineString(records: records, recordType: "custom-title", field: "customTitle")
            ?? latestInlineString(records: records, recordType: "ai-title", field: "aiTitle")
            ?? latestInlineString(records: records, recordType: "last-prompt", field: "lastPrompt")
            ?? summaryTitle(from: records)
            ?? firstUserText(from: records)
    }

    private static func latestInlineString(
        records: [[String: HistoryValue]],
        recordType: String,
        field: String
    ) -> String? {
        records.reversed().lazy.compactMap { record -> String? in
            guard record["type"]?.stringValue == recordType else { return nil }
            return ForeignHistorySupport.trimmed(record[field])
        }.first
    }

    private static func workingDirectory(from records: [[String: HistoryValue]]) -> String? {
        records.reversed().lazy.compactMap { record -> String? in
            guard record["type"]?.stringValue == "workspace-directories" else { return nil }
            return record["directories"]?.arrayValue?.lazy.compactMap {
                ForeignHistorySupport.trimmed($0)
            }.first
        }.first
    }

    private static func summaryTitle(from records: [[String: HistoryValue]]) -> String? {
        records.reversed().lazy.compactMap { record -> String? in
            guard record["type"]?.stringValue == "summary" else { return nil }
            return ForeignHistorySupport.trimmed(record["summary"])
                ?? record["content"].flatMap(textContent)
                ?? record["message"]?["content"].flatMap(textContent)
        }.first
    }

    private static func firstUserText(from records: [[String: HistoryValue]]) -> String? {
        for record in records {
            switch record["type"]?.stringValue ?? "" {
            case "user" where record["isMeta"]?.boolValue != true
                && record["isCompactSummary"]?.boolValue != true:
                if let text = record["message"]?["content"].flatMap(textContent) { return text }
            case "attachment" where record["attachment"]?["type"]?.stringValue == "queued_command":
                if let text = ForeignHistorySupport.trimmed(record["attachment"]?["prompt"]) { return text }
            default:
                continue
            }
        }
        return nil
    }

    private static func textContent(_ value: HistoryValue) -> String? {
        if let string = ForeignHistorySupport.trimmed(value) { return string }
        if let blocks = value.arrayValue {
            let parts = blocks.compactMap { block -> String? in
                if let string = ForeignHistorySupport.trimmed(block) { return string }
                guard ["text", "input_text"].contains(block["type"]?.stringValue ?? "") else { return nil }
                return ForeignHistorySupport.trimmed(block["text"])
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return ForeignHistorySupport.trimmed(value["text"])
    }
}
