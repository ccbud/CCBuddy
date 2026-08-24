import Foundation

private struct PiNormalizedTranscript {
    var sessionID: String?
    var cwd: String?
    var version: String?
    var producerTitle: String?
    var createdAt: Date?
    var lastActivity: Date?
    var messages: [HistoryMessage] = []
    var totals = HistoryTotals()
    var model: String?
}

/// Normalizes Pi's append-only session JSONL into the conversation model used by CC Buddy.
///
/// Oh My Pi is a format-compatible fork, so `OMPHistoryParser` delegates to the same core and
/// changes only the source identity. Keeping the core shared is important: tool results are
/// correlated with their calls and consecutive assistant entries remain one agentic turn in both
/// producers, matching Wake's adapter contract.
enum PiHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        parse(context, source: .pi)
    }

    static func parse(
        _ context: HistoryParseContext,
        source: HistorySource
    ) -> HistorySession {
        let normalized = normalize(context.document.records)
        let nativeID = normalized.sessionID ?? nativeID(from: context.candidate.file)
        let custom: (title: String?, tags: [String], deleted: Bool)
        if context.candidate.directory.id == "__imported__" {
            let inline = HistoryParsingSupport.customMetadata(context.document.records)
            custom = (inline.0, inline.1, inline.2)
        } else {
            let sidecar = ForeignHistorySupport.customMetadata(
                source: source,
                sessionKey: nativeID,
                appDataRoot: context.appDataRoot
            )
            custom = (sidecar.title, sidecar.tags, sidecar.deleted)
        }

        let inferredTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let autoTitle = normalized.producerTitle ?? inferredTitle
        let cwd = normalized.cwd
            ?? context.candidate.projectDirectoryName.flatMap(
                HistoryPathResolver.decodeProjectDirectoryName
            )
        let metadata = HistorySessionMetadata(
            id: "\(source.rawValue):\(nativeID)",
            file: context.candidate.file,
            source: source,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: nativeID,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(
                cwd: cwd,
                encodedDirectory: context.candidate.projectDirectoryName
            ),
            version: normalized.version,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: normalized.model,
            imported: context.candidate.directory.id == "__imported__",
            deleted: custom.deleted,
            createdAt: normalized.createdAt ?? context.facts.createdAt,
            lastActivity: normalized.lastActivity ?? context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            totals: normalized.totals,
            messageCount: normalized.messages.lazy.filter { !$0.isMetadata }.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    private static func normalize(
        _ records: [[String: HistoryValue]]
    ) -> PiNormalizedTranscript {
        var result = PiNormalizedTranscript()
        var toolMessageIndex: [String: Int] = [:]

        for record in records {
            let type = record["type"]?.stringValue ?? ""
            switch type {
            case "session":
                result.sessionID = nonempty(record["id"]?.stringValue) ?? result.sessionID
                result.cwd = nonempty(record["cwd"]?.stringValue) ?? result.cwd
                result.version = versionString(record["version"]) ?? result.version
                result.producerTitle = nonempty(record["title"]?.stringValue)
                    ?? result.producerTitle
                if let timestamp = timestamp(record["timestamp"]) {
                    result.createdAt = timestamp.date
                }

            case "title", "title_change", "session_info":
                if let title = nonempty(record["title"]?.stringValue)
                    ?? nonempty(record["name"]?.stringValue) {
                    result.producerTitle = title
                }

            case "model_change":
                result.model = nonempty(record["modelId"]?.stringValue)
                    ?? nonempty(record["model"]?.stringValue)
                    ?? result.model

            case "message":
                guard let envelope = record["message"]?.objectValue else { continue }
                let eventTimestamp = messageTimestamp(record: record, envelope: envelope)
                if let date = eventTimestamp.date {
                    if result.lastActivity.map({ date > $0 }) ?? true {
                        result.lastActivity = date
                    }
                }
                let sidechain = record["isSidechain"]?.boolValue
                    ?? envelope["isSidechain"]?.boolValue
                    ?? false

                switch envelope["role"]?.stringValue ?? "" {
                case "user":
                    let blocks = contentBlocks(envelope["content"], permitsTools: false)
                    guard !blocks.isEmpty else { continue }
                    let metadata = blocks.compactMap(HistoryParsingSupport.plainText)
                        .contains(where: isInjectedUserContent)
                    result.messages.append(HistoryMessage(
                        role: "user",
                        content: blocks,
                        timestamp: eventTimestamp.date,
                        timestampText: eventTimestamp.text,
                        isSidechain: sidechain,
                        isMetadata: metadata
                    ))

                case "assistant":
                    let blocks = contentBlocks(envelope["content"], permitsTools: true)
                    guard !blocks.isEmpty else { continue }
                    let model = nonempty(envelope["model"]?.stringValue) ?? result.model
                    if let model { result.model = model }
                    let usage = usage(envelope["usage"])
                    if let usage { result.totals.add(usage) }

                    let messageIndex: Int
                    if let lastIndex = result.messages.indices.last,
                       result.messages[lastIndex].role == "assistant",
                       result.messages[lastIndex].isSidechain == sidechain {
                        messageIndex = lastIndex
                        result.messages[lastIndex].content.append(contentsOf: blocks)
                        if let model { result.messages[lastIndex].modelActual = model }
                        if let usage { result.messages[lastIndex].usage = usage }
                        if let stopReason = nonempty(envelope["stopReason"]?.stringValue) {
                            result.messages[lastIndex].stopReason = stopReason
                        }
                    } else {
                        messageIndex = result.messages.count
                        result.messages.append(HistoryMessage(
                            role: "assistant",
                            content: blocks,
                            timestamp: eventTimestamp.date,
                            timestampText: eventTimestamp.text,
                            modelActual: model,
                            usage: usage,
                            stopReason: nonempty(envelope["stopReason"]?.stringValue),
                            isSidechain: sidechain
                        ))
                    }
                    for block in blocks where block.type == "tool_use" {
                        guard let id = nonempty(block.id) else { continue }
                        toolMessageIndex[id] = messageIndex
                    }

                case "toolResult":
                    guard let callID = nonempty(envelope["toolCallId"]?.stringValue),
                          let messageIndex = toolMessageIndex[callID],
                          result.messages.indices.contains(messageIndex) else { continue }
                    result.messages[messageIndex].content.append(HistoryContentBlock(
                        type: "tool_result",
                        toolUseID: callID,
                        content: envelope["content"] ?? .null,
                        isError: envelope["isError"]?.boolValue,
                        raw: .object(record)
                    ))

                default:
                    continue
                }

            default:
                continue
            }
        }
        return result
    }

    private static func contentBlocks(
        _ content: HistoryValue?,
        permitsTools: Bool
    ) -> [HistoryContentBlock] {
        if let text = nonempty(content?.stringValue) {
            return [.init(type: "text", text: text, raw: content)]
        }
        return content?.arrayValue?.compactMap { raw in
            guard let object = raw.objectValue else { return nil }
            switch object["type"]?.stringValue ?? "" {
            case "text", "input_text", "output_text":
                guard let text = nonempty(object["text"]?.stringValue) else { return nil }
                return HistoryContentBlock(type: "text", text: text, raw: raw)
            case "thinking", "reasoning":
                guard let thinking = nonempty(
                    object["thinking"]?.stringValue ?? object["text"]?.stringValue
                ) else { return nil }
                return HistoryContentBlock(type: "thinking", thinking: thinking, raw: raw)
            case let type where permitsTools && ["toolCall", "tool_call", "tool-call"].contains(type):
                return HistoryContentBlock(
                    type: "tool_use",
                    id: object["id"]?.stringValue,
                    name: nonempty(object["name"]?.stringValue) ?? "tool",
                    input: object["arguments"] ?? object["input"] ?? .object([:]),
                    raw: raw
                )
            case "image":
                return HistoryContentBlock(type: "image", raw: raw)
            default:
                return HistoryParsingSupport.block(from: raw)
            }
        } ?? []
    }

    private static func usage(_ value: HistoryValue?) -> HistoryUsage? {
        guard let usage = value?.objectValue else { return nil }
        return HistoryUsage(
            inputTokens: integer(usage, keys: ["input", "input_tokens"]),
            outputTokens: integer(usage, keys: ["output", "output_tokens"]),
            cacheRead: integer(usage, keys: ["cacheRead", "cache_read_input_tokens"]),
            cacheCreation: integer(usage, keys: ["cacheWrite", "cache_creation_input_tokens"])
        )
    }

    private static func integer(
        _ object: [String: HistoryValue],
        keys: [String]
    ) -> Int {
        keys.lazy.compactMap { object[$0]?.integerValue }.first ?? 0
    }

    private static func nativeID(from file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let separator = stem.lastIndex(of: "_"), separator < stem.index(before: stem.endIndex) else {
            return stem
        }
        return String(stem[stem.index(after: separator)...])
    }

    private static func versionString(_ value: HistoryValue?) -> String? {
        if let string = nonempty(value?.stringValue) { return string }
        if let integer = value?.integerValue { return String(integer) }
        return nil
    }

    private static func messageTimestamp(
        record: [String: HistoryValue],
        envelope: [String: HistoryValue]
    ) -> (date: Date?, text: String?) {
        timestamp(record["timestamp"])
            ?? timestamp(envelope["timestamp"])
            ?? (nil, nil)
    }

    private static func timestamp(
        _ value: HistoryValue?
    ) -> (date: Date?, text: String?)? {
        if let text = nonempty(value?.stringValue) {
            return (HistoryDateParser.parse(text), text)
        }
        guard let number = value?.numberValue, number.isFinite, number > 0 else { return nil }
        let seconds = number >= 1_000_000_000_000 ? number / 1_000 : number
        return (Date(timeIntervalSince1970: seconds), nil)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func isInjectedUserContent(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "<recommended_plugins", "<environment_context", "<user_instructions",
            "<permissions", "<workspace", "<system-", "<context ",
            "<session_context", "IMPORTANT: Do NOT read",
            "Caveat: The messages below", "# Files pasted by the user",
        ]
        return prefixes.contains(where: value.hasPrefix)
            || value.contains("/.codex/plugins/")
            || value.contains("/plugins/cache/") && value.contains("SKILL.md")
    }
}
