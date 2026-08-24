import Foundation

private struct KimiSidecar {
    var title: String?
    var cwd: String?
    var createdAt: Date?
    var updatedAt: Date?
}

enum KimiHistoryParser {
    static func parse(
        _ context: HistoryParseContext,
        indexFile: URL? = nil
    ) -> HistorySession {
        let nativeID = context.candidate.nativeID
            ?? sessionDirectory(for: context.candidate.file)?.lastPathComponent
            ?? context.candidate.file.deletingPathExtension().lastPathComponent
        let sidecar = readSidecar(
            transcript: context.candidate.file,
            nativeID: nativeID,
            indexFile: indexFile
                ?? context.homeDirectory.appendingPathComponent(
                    ".kimi-code/session_index.jsonl"
                )
        )
        let messages = normalize(context.document.records)
        let custom = ForeignHistorySupport.customMetadata(
            source: .kimi,
            sessionKey: nativeID,
            appDataRoot: context.appDataRoot
        )
        let producerTitle = sidecar.title == "New Session" ? nil : sidecar.title
        let autoTitle = producerTitle ?? HistoryParsingSupport.firstUserTitle(in: messages)
        let firstTimestamp = ForeignHistorySupport.firstTimestamp(in: messages)
        let lastTimestamp = ForeignHistorySupport.lastTimestamp(in: messages)
        let metadata = HistorySessionMetadata(
            id: "kimi:\(nativeID)",
            file: context.candidate.file,
            source: .kimi,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: nativeID,
            cwd: sidecar.cwd,
            project: HistoryParsingSupport.projectName(cwd: sidecar.cwd, encodedDirectory: nil),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            imported: false,
            deleted: custom.deleted,
            createdAt: sidecar.createdAt ?? firstTimestamp ?? context.facts.createdAt,
            lastActivity: sidecar.updatedAt ?? lastTimestamp ?? context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            messageCount: messages.lazy.filter { !$0.isMetadata }.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: messages)
    }

    private static func normalize(
        _ records: [[String: HistoryValue]]
    ) -> [HistoryMessage] {
        var messages: [HistoryMessage] = []
        for record in records {
            let type = record["type"]?.stringValue ?? ""
            let timestamp = WakeHistoryAdapterSupport.date(
                record["timestamp"] ?? record["time"]
            )
            switch type {
            case "turn.prompt", "turn.steer":
                let blocks = contentBlocks(record["input"])
                guard !blocks.isEmpty else { continue }
                messages.append(HistoryMessage(
                    role: "user",
                    content: blocks,
                    timestamp: timestamp,
                    timestampText: WakeHistoryAdapterSupport.timestampText(timestamp)
                ))
            case "context.append_message":
                guard let envelope = record["message"]?.objectValue,
                      envelope["role"]?.stringValue == "assistant" else { continue }
                let blocks = contentBlocks(envelope["content"])
                guard !blocks.isEmpty else { continue }
                let model = WakeHistoryAdapterSupport.nonempty(envelope["model"]?.stringValue)
                messages.append(HistoryMessage(
                    role: "assistant",
                    content: blocks,
                    timestamp: timestamp,
                    timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                    modelActual: model
                ))
            case "metadata", "config.update", "tools.set_active_tools",
                 "context.append_loop_event":
                continue
            default:
                if type.hasPrefix("turn.") { continue }
            }
        }
        return messages
    }

    private static func contentBlocks(_ value: HistoryValue?) -> [HistoryContentBlock] {
        if let text = WakeHistoryAdapterSupport.nonempty(value?.stringValue) {
            return [.init(type: "text", text: text, raw: value)]
        }
        return value?.arrayValue?.compactMap { raw in
            if let text = WakeHistoryAdapterSupport.nonempty(raw.stringValue) {
                return .init(type: "text", text: text, raw: raw)
            }
            guard let object = raw.objectValue else { return nil }
            let type = object["type"]?.stringValue ?? "text"
            switch type {
            case "text":
                guard let text = WakeHistoryAdapterSupport.nonempty(object["text"]?.stringValue) else {
                    return nil
                }
                return .init(type: "text", text: text, raw: raw)
            case "thinking", "reasoning":
                guard let text = WakeHistoryAdapterSupport.nonempty(object["text"]?.stringValue) else {
                    return nil
                }
                return .init(type: "thinking", thinking: text, raw: raw)
            case "tool_use", "tool-call":
                return .init(
                    type: "tool_use",
                    id: object["id"]?.stringValue,
                    name: WakeHistoryAdapterSupport.nonempty(object["name"]?.stringValue) ?? "tool",
                    input: object["input"] ?? object["arguments"] ?? .object([:]),
                    raw: raw
                )
            case "tool_result", "tool-result":
                return .init(
                    type: "tool_result",
                    toolUseID: object["toolUseId"]?.stringValue
                        ?? object["toolCallId"]?.stringValue,
                    content: object["content"],
                    isError: object["isError"]?.boolValue,
                    raw: raw
                )
            default:
                return nil
            }
        } ?? []
    }

    private static func readSidecar(
        transcript: URL,
        nativeID: String,
        indexFile: URL
    ) -> KimiSidecar {
        var result = KimiSidecar()
        if let directory = sessionDirectory(for: transcript),
           let root = ForeignHistorySupport.jsonObject(
             at: directory.appendingPathComponent("state.json")
           ) {
            result.title = WakeHistoryAdapterSupport.nonempty(root["title"]?.stringValue)
            result.createdAt = WakeHistoryAdapterSupport.date(root["createdAt"])
            result.updatedAt = WakeHistoryAdapterSupport.date(root["updatedAt"])
        }
        if let document = try? HistoryJSONLDocument.read(from: indexFile) {
            for record in document.records
                where record["sessionId"]?.stringValue == nativeID {
                result.cwd = WakeHistoryAdapterSupport.nonempty(record["workDir"]?.stringValue)
                    ?? result.cwd
            }
        }
        return result
    }

    fileprivate static func sessionDirectory(for transcript: URL) -> URL? {
        let directory = transcript.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return directory.lastPathComponent.hasPrefix("session_") ? directory : nil
    }
}

struct KimiConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.kimi
    let format = HistoryTranscriptFormat.kimi

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".kimi-code/sessions")
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : root.deletingLastPathComponent()
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "Kimi Code",
            baseURL: base,
            discoveryRoot: root
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        var result: [HistoryFileCandidate] = []
        for workspace in WakeHistoryAdapterSupport.contents(of: root)
            where WakeHistoryAdapterSupport.ordinaryDirectory(workspace) {
            for session in WakeHistoryAdapterSupport.contents(of: workspace)
                where WakeHistoryAdapterSupport.ordinaryDirectory(session)
                    && session.lastPathComponent.hasPrefix("session_") {
                let transcript = session.appendingPathComponent("agents/main/wire.jsonl")
                guard WakeHistoryAdapterSupport.ordinaryFile(transcript) else { continue }
                result.append(HistoryFileCandidate(
                    file: transcript,
                    projectDirectoryName: workspace.lastPathComponent,
                    directory: directory,
                    formatHint: format,
                    nativeID: session.lastPathComponent
                ))
            }
        }
        return result
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".kimi-code/sessions")
        )
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        var result: [ConversationSourceDependency] = [
            .init(file: candidate.file, role: .primaryTranscript),
            .init(
                file: configuration.companionFile(
                    "index",
                    for: source,
                    default: configuration.homeDirectory.appendingPathComponent(
                        ".kimi-code/session_index.jsonl"
                    )
                ),
                role: .providerMetadata
            ),
            .init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
        if let directory = KimiHistoryParser.sessionDirectory(for: candidate.file) {
            result.append(.init(
                file: directory.appendingPathComponent("state.json"),
                role: .providerMetadata
            ))
        }
        return result
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return KimiHistoryParser.parse(HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        ), indexFile: input.configuration.companionFile(
            "index",
            for: source,
            default: input.configuration.homeDirectory.appendingPathComponent(
                ".kimi-code/session_index.jsonl"
            )
        ))
    }
}
