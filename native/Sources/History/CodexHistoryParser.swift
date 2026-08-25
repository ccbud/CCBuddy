import Foundation

enum CodexHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let normalized = CodexMessageNormalizer.normalize(context.document.records)
        let stem = context.candidate.file.deletingPathExtension().lastPathComponent
        let canonicalID = normalized.identity.threadID ?? normalized.identity.rootSessionID ?? stem
        let rootID = normalized.identity.rootSessionID ?? normalized.identity.threadID ?? stem
        var transcriptTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        if transcriptTitle.isEmpty {
            transcriptTitle = CodexMessageNormalizer.firstEventUserTitle(normalized.lines)
        }
        let agentTitle = subagentTitle(normalized.identity)
        let autoTitle = agentTitle.isEmpty ? transcriptTitle : agentTitle
        let custom: ConversationCustomMetadata
        if context.candidate.directory.id == "__imported__" {
            custom = HistoryParsingSupport.customMetadata(context.document.records)
        } else {
            custom = ForeignHistorySupport.codexMetadata(
                sessionKey: stem,
                appDataRoot: context.appDataRoot
            )
        }

        let metadata = HistorySessionMetadata(
            id: "codex:\(context.candidate.directory.id):\(stem)",
            file: context.candidate.file,
            source: .codex,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: canonicalID,
            threadID: normalized.identity.threadID,
            rootSessionID: rootID,
            parentThreadID: normalized.identity.parentThreadID,
            forkedFromID: normalized.identity.forkedFromID,
            canonicalThreadIDValid: HistoryParsingSupport.isCanonicalThreadID(normalized.identity.threadID),
            cwd: normalized.cwd,
            project: HistoryParsingSupport.projectName(cwd: normalized.cwd, encodedDirectory: nil),
            gitBranch: normalized.gitBranch,
            version: normalized.version,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: normalized.model,
            isSubagent: normalized.identity.isSubagent,
            agentPath: normalized.identity.agentPath,
            agentNickname: normalized.identity.agentNickname,
            agentRole: normalized.identity.agentRole,
            agentDepth: normalized.identity.agentDepth,
            imported: context.candidate.directory.id == "__imported__",
            deleted: custom.deleted,
            starred: custom.starred,
            createdAt: context.facts.createdAt,
            lastActivity: context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            totals: normalized.totals,
            messageCount: normalized.messages.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    private static func subagentTitle(_ identity: CodexIdentity) -> String {
        guard identity.isSubagent else { return "" }
        var path = identity.agentPath ?? ""
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasPrefix("root/") { path.removeFirst("root/".count) }
        let parts = [identity.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines), path]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? "Codex subagent" : parts.joined(separator: " · ")
    }
}
