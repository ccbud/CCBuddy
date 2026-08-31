import Foundation

enum ClaudeHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let records = context.document.records
        var messages: [HistoryMessage] = []
        var totals = HistoryTotals()
        var model: String?

        for record in records {
            let type = record["type"]?.stringValue ?? ""
            guard type == "user" || type == "assistant",
                  record["isMeta"]?.boolValue != true,
                  let envelope = record["message"]?.objectValue,
                  let role = envelope["role"]?.stringValue else { continue }

            let usage = type == "assistant" ? HistoryParsingSupport.usage(from: envelope["usage"]) : nil
            if let usage { totals.add(usage) }
            if type == "assistant", let actual = envelope["model"]?.stringValue { model = actual }
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
        let agentRecord = records.first(where: { $0["agentId"] != nil })
        let isSubagent = agentRecord != nil
        let stem = context.candidate.file.deletingPathExtension().lastPathComponent
        let baseSessionID = metadataRecord?["sessionId"]?.stringValue ?? stem
        let agentID = agentRecord?["agentId"]?.stringValue
        let sessionID = isSubagent && agentID != nil ? "\(baseSessionID)-\(agentID!)" : baseSessionID
        let cwd = metadataRecord?["cwd"]?.stringValue
            ?? context.candidate.projectDirectoryName.flatMap(HistoryPathResolver.decodeProjectDirectoryName)
        let autoTitle = HistoryParsingSupport.firstUserTitle(in: messages)
        let custom = HistoryParsingSupport.customMetadata(records)
        let summary = records.first(where: {
            $0["type"]?.stringValue == "summary" && $0["summary"] != nil
        })?["summary"]

        let metadata = HistorySessionMetadata(
            id: "disk:\(stem)\(isSubagent ? ":sub" : "")",
            file: context.candidate.file,
            source: .claude,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: sessionID,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(
                cwd: cwd,
                encodedDirectory: context.candidate.projectDirectoryName
            ),
            gitBranch: metadataRecord?["gitBranch"]?.stringValue,
            version: metadataRecord?["version"]?.stringValue,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            summary: summary,
            model: model,
            isSubagent: isSubagent,
            imported: context.candidate.directory.id == "__imported__",
            deleted: custom.deleted,
            starred: custom.starred,
            pinned: custom.pinned,
            createdAt: context.facts.createdAt,
            lastActivity: context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            totals: totals,
            messageCount: messages.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: messages)
    }
}
