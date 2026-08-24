import Foundation

enum CodexHistoryParser {
    /// Matches Wake's producer identity for timestamped rollout filenames:
    /// `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl` is the logical `<uuid>` conversation.
    static func rolloutNativeID(fromStem stem: String) -> String {
        guard stem.hasPrefix("rollout-") else { return stem }
        let remainder = stem.dropFirst("rollout-".count)
        let bytes = Array(remainder.utf8)
        guard bytes.count > 20, bytes[10] == 0x54,
              let nativeID = String(bytes: bytes.dropFirst(20), encoding: .utf8) else {
            return stem
        }
        return nativeID
    }

    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let normalized = CodexMessageNormalizer.normalize(context.document.records)
        let inline = HistoryParsingSupport.customMetadata(context.document.records)
        return makeSession(
            candidate: context.candidate,
            facts: context.facts,
            appDataRoot: context.appDataRoot,
            normalized: normalized,
            diagnostics: context.document.diagnostics,
            importedMetadata: CodexInlineMetadata(
                title: inline.0,
                tags: inline.1,
                deleted: inline.2
            )
        )
    }

    /// Wake-style detail/index path: parse the rollout one JSONL record at a time and retain only
    /// bounded presentation fields. The original file remains the session's authoritative URL for
    /// raw export, replay, and Claude/ChatGPT analysis attachments.
    static func parseStreaming(
        candidate: HistoryFileCandidate,
        facts inputFacts: HistoryFileFacts,
        appDataRoot: URL
    ) throws -> HistorySession {
        let streamed = try CodexMessageNormalizer.normalizeStreaming(from: candidate.file)
        var facts = inputFacts
        if let createdAt = streamed.transcript.firstRecordTimestamp {
            facts.createdAt = createdAt
        }
        return makeSession(
            candidate: candidate,
            facts: facts,
            appDataRoot: appDataRoot,
            normalized: streamed.transcript,
            diagnostics: streamed.metrics.diagnostics,
            importedMetadata: streamed.transcript.inlineMetadata
        )
    }

    private static func makeSession(
        candidate: HistoryFileCandidate,
        facts: HistoryFileFacts,
        appDataRoot: URL,
        normalized: CodexNormalizedTranscript,
        diagnostics: HistoryReadDiagnostics,
        importedMetadata: CodexInlineMetadata?
    ) -> HistorySession {
        let stem = candidate.file.deletingPathExtension().lastPathComponent
        let canonicalID = normalized.identity.threadID ?? normalized.identity.rootSessionID ?? stem
        let rootID = normalized.identity.rootSessionID ?? normalized.identity.threadID ?? stem
        var transcriptTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        if transcriptTitle.isEmpty {
            transcriptTitle = normalized.firstEventUserTitle
        }
        let agentTitle = subagentTitle(normalized.identity)
        let autoTitle = agentTitle.isEmpty ? transcriptTitle : agentTitle
        let custom: (String?, [String], Bool)
        if candidate.directory.id == "__imported__" {
            custom = importedMetadata.map { ($0.title, $0.tags, $0.deleted) }
                ?? (nil, [], false)
        } else {
            let sidecar = ForeignHistorySupport.codexMetadata(
                sessionKey: stem,
                appDataRoot: appDataRoot
            )
            custom = (sidecar.title, sidecar.tags, sidecar.deleted)
        }

        let metadata = HistorySessionMetadata(
            id: "codex:\(candidate.directory.id):\(stem)",
            file: candidate.file,
            source: .codex,
            dirID: candidate.directory.id,
            dirLabel: candidate.directory.label,
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
            title: custom.0 ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.1,
            model: normalized.model,
            isSubagent: normalized.identity.isSubagent,
            agentPath: normalized.identity.agentPath,
            agentNickname: normalized.identity.agentNickname,
            agentRole: normalized.identity.agentRole,
            agentDepth: normalized.identity.agentDepth,
            imported: candidate.directory.id == "__imported__",
            deleted: custom.2,
            createdAt: facts.createdAt,
            lastActivity: facts.modifiedAt,
            sizeBytes: facts.sizeBytes,
            totals: normalized.totals,
            messageCount: normalized.messages.count,
            diagnostics: diagnostics
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
