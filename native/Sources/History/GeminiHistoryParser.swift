import Foundation

private struct GeminiNormalizedTranscript {
    var sessionID: String?
    var createdAt: Date?
    var lastActivity: Date?
    var messages: [HistoryMessage] = []
    var model: String?
}

enum GeminiHistoryParser {
    static func parse(
        _ context: HistoryParseContext,
        projectsFile: URL? = nil
    ) -> HistorySession {
        let normalized = normalize(context.document.records)
        let nativeID = normalized.sessionID
            ?? context.candidate.nativeID
            ?? context.candidate.file.deletingPathExtension().lastPathComponent
        let cwd = projectPath(
            for: context.candidate.file,
            projectsFile: projectsFile
                ?? context.homeDirectory.appendingPathComponent(".gemini/projects.json")
        )
        let custom = ForeignHistorySupport.customMetadata(
            source: .gemini,
            sessionKey: nativeID,
            appDataRoot: context.appDataRoot
        )
        let autoTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let metadata = HistorySessionMetadata(
            id: "gemini:\(nativeID)",
            file: context.candidate.file,
            source: .gemini,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: nativeID,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: normalized.model,
            imported: false,
            deleted: custom.deleted,
            createdAt: normalized.createdAt ?? context.facts.createdAt,
            lastActivity: normalized.lastActivity ?? context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            messageCount: normalized.messages.lazy.filter { !$0.isMetadata }.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    private static func normalize(
        _ records: [[String: HistoryValue]]
    ) -> GeminiNormalizedTranscript {
        var result = GeminiNormalizedTranscript()
        var snapshot: [HistoryValue] = []
        for record in records {
            if let id = WakeHistoryAdapterSupport.nonempty(record["sessionId"]?.stringValue) {
                result.sessionID = id
                result.createdAt = WakeHistoryAdapterSupport.date(record["startTime"])
                    ?? result.createdAt
                result.lastActivity = WakeHistoryAdapterSupport.date(record["lastUpdated"])
                    ?? result.lastActivity
            }
            if let messages = record["$set"]?["messages"]?.arrayValue {
                snapshot = messages
            }
        }

        for rawMessage in snapshot {
            guard let envelope = rawMessage.objectValue,
                  let type = envelope["type"]?.stringValue else { continue }
            let role = type == "user" ? "user" : "assistant"
            let timestamp = WakeHistoryAdapterSupport.date(envelope["timestamp"])
            if result.createdAt == nil { result.createdAt = timestamp }
            if let timestamp, result.lastActivity.map({ timestamp > $0 }) ?? true {
                result.lastActivity = timestamp
            }
            let model = WakeHistoryAdapterSupport.nonempty(envelope["model"]?.stringValue)
                ?? WakeHistoryAdapterSupport.nonempty(envelope["modelId"]?.stringValue)
            if let model { result.model = model }
            let blocks = contentBlocks(envelope["content"])
            guard !blocks.isEmpty else { continue }
            result.messages.append(HistoryMessage(
                role: role,
                content: blocks,
                timestamp: timestamp,
                timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                modelActual: role == "assistant" ? model : nil
            ))
        }
        return result
    }

    private static func contentBlocks(_ value: HistoryValue?) -> [HistoryContentBlock] {
        if let text = WakeHistoryAdapterSupport.nonempty(value?.stringValue) {
            return [.init(type: "text", text: text, raw: value)]
        }
        return value?.arrayValue?.compactMap { raw in
            guard let object = raw.objectValue else { return nil }
            if let text = WakeHistoryAdapterSupport.nonempty(object["text"]?.stringValue) {
                if object["thought"]?.boolValue == true {
                    return .init(type: "thinking", thinking: text, raw: raw)
                }
                return .init(type: "text", text: text, raw: raw)
            }
            if let call = object["functionCall"]?.objectValue {
                return .init(
                    type: "tool_use",
                    id: call["id"]?.stringValue,
                    name: WakeHistoryAdapterSupport.nonempty(call["name"]?.stringValue) ?? "tool",
                    input: call["args"] ?? .object([:]),
                    raw: raw
                )
            }
            if let response = object["functionResponse"]?.objectValue {
                return .init(
                    type: "tool_result",
                    toolUseID: response["id"]?.stringValue,
                    content: response["response"] ?? .object(response),
                    raw: raw
                )
            }
            return nil
        } ?? []
    }

    private static func projectPath(for transcript: URL, projectsFile: URL) -> String? {
        guard let slug = transcript.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent.nilIfEmpty else { return nil }
        guard let root = ForeignHistorySupport.jsonObject(at: projectsFile),
              let mapping = root["projects"]?.objectValue else { return nil }
        return mapping.first { $0.value.stringValue == slug }?.key
    }
}

struct GeminiConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.gemini
    let format = HistoryTranscriptFormat.gemini

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".gemini/tmp")
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : root.deletingLastPathComponent()
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "Gemini CLI",
            baseURL: base,
            discoveryRoot: root
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        var result: [HistoryFileCandidate] = []
        for slug in WakeHistoryAdapterSupport.contents(of: root)
            where WakeHistoryAdapterSupport.ordinaryDirectory(slug) {
            let chats = slug.appendingPathComponent("chats", isDirectory: true)
            for file in WakeHistoryAdapterSupport.contents(of: chats) {
                let name = file.lastPathComponent
                guard name.hasPrefix("session-"), name.hasSuffix(".jsonl"),
                      WakeHistoryAdapterSupport.ordinaryFile(file) else { continue }
                result.append(HistoryFileCandidate(
                    file: file,
                    projectDirectoryName: slug.lastPathComponent,
                    directory: directory,
                    formatHint: format,
                    nativeID: file.deletingPathExtension().lastPathComponent
                ))
            }
        }
        return result
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".gemini/tmp")
        )
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        [
            .init(file: candidate.file, role: .primaryTranscript),
            .init(
                file: configuration.companionFile(
                    "projects",
                    for: source,
                    default: configuration.homeDirectory
                        .appendingPathComponent(".gemini/projects.json")
                ),
                role: .providerMetadata
            ),
            .init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return GeminiHistoryParser.parse(HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        ), projectsFile: input.configuration.companionFile(
            "projects",
            for: source,
            default: input.configuration.homeDirectory
                .appendingPathComponent(".gemini/projects.json")
        ))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
