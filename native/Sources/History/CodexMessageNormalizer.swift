import Foundation

struct CodexNormalizedTranscript: Sendable {
    var lines: [CodexLine]
    var messages: [HistoryMessage]
    var totals: HistoryTotals
    var model: String?
    var cwd: String?
    var version: String?
    var gitBranch: String?
    var identity: CodexIdentity
    var firstEventUserTitle: String
    var firstRecordTimestamp: Date?
    var inlineMetadata: CodexInlineMetadata?
}

struct CodexInlineMetadata: Sendable {
    var title: String?
    var tags: [String]
    var deleted: Bool
}

struct CodexStreamingNormalizationResult: Sendable {
    var transcript: CodexNormalizedTranscript
    var metrics: HistoryJSONLStreamMetrics
}

enum CodexMessageNormalizer {
    /// Wake's presentation budgets. The producer-owned JSONL remains untouched and is still used
    /// for raw export and replay; only the in-memory Codex detail/index representation is clipped.
    static let maximumMessageTextBytes = 32 * 1_024
    static let maximumToolValueBytes = 16 * 1_024

    private struct NormalizationState {
        var lines: [CodexLine] = []
        var messages: [HistoryMessage] = []
        var totals = HistoryTotals()
        var model: String?
        var cwd: String?
        var version: String?
        var gitBranch: String?
        var identity = CodexIdentity()
        var sawSessionMetadata = false
        var firstEventUserTitle = ""
        var firstRecordTimestamp: Date?
        var inlineMetadata: CodexInlineMetadata?
        let retainLines: Bool
        let boundedPresentation: Bool

        var transcript: CodexNormalizedTranscript {
            CodexNormalizedTranscript(
                lines: lines,
                messages: messages,
                totals: totals,
                model: model,
                cwd: cwd,
                version: version,
                gitBranch: gitBranch,
                identity: identity,
                firstEventUserTitle: firstEventUserTitle,
                firstRecordTimestamp: firstRecordTimestamp,
                inlineMetadata: inlineMetadata
            )
        }
    }

    static func normalize(_ records: [[String: HistoryValue]]) -> CodexNormalizedTranscript {
        var state = NormalizationState(retainLines: true, boundedPresentation: false)
        for record in records {
            consume(record, state: &state)
        }
        return state.transcript
    }

    /// Parses a rollout incrementally. The returned transcript never owns raw source records and
    /// retains only presentation-bounded message/tool fields.
    static func normalizeStreaming(from file: URL) throws -> CodexStreamingNormalizationResult {
        var state = NormalizationState(retainLines: false, boundedPresentation: true)
        let metrics = try HistoryJSONLStreamReader.scan(from: file) { record in
            consume(record, state: &state)
            return true
        }
        return CodexStreamingNormalizationResult(transcript: state.transcript, metrics: metrics)
    }

    static func firstEventUserTitle(_ lines: [CodexLine]) -> String {
        for line in lines {
            let title = eventUserTitle(line)
            if !title.isEmpty { return title }
        }
        return ""
    }

    private static func consume(
        _ record: [String: HistoryValue],
        state: inout NormalizationState
    ) {
        let line = CodexRecord.split(record)
        if state.retainLines { state.lines.append(line) }
        if state.firstRecordTimestamp == nil {
            state.firstRecordTimestamp = HistoryDateParser.parse(line.timestampText)
        }
        if state.inlineMetadata == nil, let custom = record["__ccbud__"]?.objectValue {
            state.inlineMetadata = inlineMetadata(
                custom,
                bounded: state.boundedPresentation
            )
        }
        if state.firstEventUserTitle.isEmpty {
            state.firstEventUserTitle = eventUserTitle(line)
        }

        let firstNewMessage = state.messages.count
        switch line.kind {
        case "session_meta":
            if !state.sawSessionMetadata {
                state.sawSessionMetadata = true
                state.identity = CodexRecord.canonicalIdentity(line.payload)
                if state.boundedPresentation {
                    state.identity = boundedIdentity(state.identity)
                }
            }
            if state.identity.rootSessionID == nil {
                let value = line.payload["session_id"]?.stringValue
                    ?? line.payload["id"]?.stringValue
                state.identity.rootSessionID = state.boundedPresentation
                    ? value.map { clipped($0, maximumUTF8Bytes: 1_024) }
                    : value
            }
            if state.cwd == nil {
                state.cwd = metadataString(
                    line.payload["cwd"]?.stringValue,
                    bounded: state.boundedPresentation,
                    maximumUTF8Bytes: 4 * 1_024
                )
            }
            if state.version == nil {
                state.version = metadataString(
                    line.payload["cli_version"]?.stringValue,
                    bounded: state.boundedPresentation
                )
            }
            if state.gitBranch == nil {
                state.gitBranch = metadataString(
                    line.payload["git"]?["branch"]?.stringValue,
                    bounded: state.boundedPresentation
                )
            }
        case "turn_context":
            if let value = line.payload["model"]?.stringValue {
                state.model = metadataString(value, bounded: state.boundedPresentation)
            }
            if state.cwd == nil {
                state.cwd = metadataString(
                    line.payload["cwd"]?.stringValue,
                    bounded: state.boundedPresentation,
                    maximumUTF8Bytes: 4 * 1_024
                )
            }
        case "compacted":
            if let text = nonempty(line.payload["message"]?.stringValue) {
                state.messages.append(message(
                    role: "user",
                    blocks: [.init(type: "text", text: text)],
                    line: line
                ))
            }
        case "event_msg":
            handleEvent(line, messages: &state.messages, totals: &state.totals)
        case "response_item":
            handleResponseItem(line, model: state.model, messages: &state.messages)
        default:
            break
        }

        if state.boundedPresentation, firstNewMessage < state.messages.count {
            for index in firstNewMessage..<state.messages.count {
                state.messages[index] = boundedMessage(state.messages[index])
            }
        }
    }

    private static func eventUserTitle(_ line: CodexLine) -> String {
        guard line.kind == "event_msg",
              line.payload["type"]?.stringValue == "user_message" else { return "" }
        let messageText = line.payload["message"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imageCount = min(
            32,
            (line.payload["images"]?.arrayValue?.count ?? 0)
                + (line.payload["local_images"]?.arrayValue?.count ?? 0)
        )
        let labels = imageCount > 0
            ? (1...imageCount).map { "[Image #\($0)]" }.joined(separator: " ")
            : ""
        let title = [labels, messageText].filter { !$0.isEmpty }.joined(separator: " ")
        return title.isEmpty ? "" : String(title.prefix(90))
    }

    private static func handleEvent(
        _ line: CodexLine,
        messages: inout [HistoryMessage],
        totals: inout HistoryTotals
    ) {
        switch line.payload["type"]?.stringValue ?? "" {
        case "token_count":
            guard let usageObject = line.payload["info"]?["last_token_usage"]?.objectValue else { return }
            let input = usageObject["input_tokens"]?.integerValue ?? 0
            let cached = usageObject["cached_input_tokens"]?.integerValue ?? 0
            let output = usageObject["output_tokens"]?.integerValue ?? 0
            guard input + cached + output > 0 else { return }
            let usage = HistoryUsage(
                inputTokens: max(0, input - cached),
                outputTokens: output,
                cacheRead: cached
            )
            totals.add(usage)
            if let index = messages.indices.reversed().first(where: {
                messages[$0].role == "assistant" && messages[$0].usage == nil
            }) {
                messages[index].usage = usage
            }
        case "turn_aborted":
            messages.append(message(
                role: "user",
                blocks: [.init(type: "text", text: "[Request interrupted by user]")],
                line: line
            ))
        default:
            return
        }
    }

    private static func handleResponseItem(
        _ line: CodexLine,
        model: String?,
        messages: inout [HistoryMessage]
    ) {
        let payload = line.payload
        switch payload["type"]?.stringValue ?? "" {
        case "message":
            handleMessage(payload, line: line, model: model, messages: &messages)
        case "reasoning":
            var text = joinedText(payload["summary"], kinds: ["summary_text", "text"])
            let detail = joinedText(payload["content"], kinds: ["reasoning_text", "text"])
            if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n\n" }
                text += detail
            }
            guard let text = nonempty(text) else { return }
            var value = message(role: "assistant", blocks: [.init(type: "thinking", thinking: text)], line: line)
            value.modelActual = model
            messages.append(value)
        case "function_call":
            let originalName = payload["name"]?.stringValue ?? "tool"
            let arguments = CodexToolMapper.parseArguments(payload["arguments"])
            let mapped = CodexToolMapper.map(name: originalName, arguments: arguments)
            appendToolUse(
                id: payload["call_id"]?.stringValue ?? payload["id"]?.stringValue ?? "",
                name: mapped.0,
                input: mapped.1,
                line: line,
                model: model,
                messages: &messages
            )
        case "local_shell_call":
            appendToolUse(
                id: payload["call_id"]?.stringValue ?? payload["id"]?.stringValue ?? "",
                name: "Bash",
                input: .object(["command": .string(CodexToolMapper.joinArguments(payload["action"]?["command"]))]),
                line: line,
                model: model,
                messages: &messages
            )
        case "custom_tool_call":
            let name = payload["name"]?.stringValue ?? "tool"
            let inputText = payload["input"]?.stringValue ?? ""
            let mapped: (String, HistoryValue) = name == "apply_patch"
                ? ("ApplyPatch", .object(["patch": .string(inputText)]))
                : (name == "exec" ? "Script" : name,
                   .object([name == "exec" ? "code" : "input": .string(inputText)]))
            appendToolUse(
                id: payload["call_id"]?.stringValue ?? payload["id"]?.stringValue ?? "",
                name: mapped.0,
                input: mapped.1,
                line: line,
                model: model,
                messages: &messages
            )
        case "function_call_output", "custom_tool_call_output":
            let shaped = shapeOutput(payload["output"])
            messages.append(message(
                role: "user",
                blocks: [.init(
                    type: "tool_result",
                    toolUseID: payload["call_id"]?.stringValue ?? "",
                    content: shaped.0,
                    isError: shaped.1 ? true : nil
                )],
                line: line
            ))
        case "web_search_call":
            appendToolUse(
                id: payload["id"]?.stringValue ?? payload["call_id"]?.stringValue ?? "",
                name: "WebSearch",
                input: .object(["query": .string(payload["action"]?["query"]?.stringValue ?? "")]),
                line: line,
                model: model,
                messages: &messages
            )
        default:
            return
        }
    }

    private static func handleMessage(
        _ payload: [String: HistoryValue],
        line: CodexLine,
        model: String?,
        messages: inout [HistoryMessage]
    ) {
        let role = payload["role"]?.stringValue ?? ""
        if role == "assistant" {
            guard let text = nonempty(joinedText(payload["content"], kinds: ["output_text", "text"])) else { return }
            var value = message(role: role, blocks: [.init(type: "text", text: text)], line: line)
            value.modelActual = model
            messages.append(value)
            return
        }
        guard role == "user" else { return }
        let text = joinedUserText(payload["content"])
        if let skill = skillBlock(text) {
            var value = message(role: role, blocks: [skill], line: line)
            value.isMetadata = true
            messages.append(value)
            return
        }
        guard !isInjectedMetadata(text) else { return }
        var blocks: [HistoryContentBlock] = []
        if let text = nonempty(text) { blocks.append(.init(type: "text", text: text)) }
        for item in payload["content"]?.arrayValue ?? [] where item["type"]?.stringValue == "input_image" {
            blocks.append(.init(type: "image", raw: item))
        }
        guard !blocks.isEmpty else { return }
        var value = message(role: role, blocks: blocks, line: line)
        value.isMetadata = isAgentsBootstrap(text)
        messages.append(value)
    }

    private static func shapeOutput(_ output: HistoryValue?) -> (HistoryValue, Bool) {
        guard let array = output?.arrayValue else { return CodexToolMapper.shapeOutput(output) }
        let text = array.compactMap { item -> String? in
            guard ["input_text", "output_text", "text"].contains(item["type"]?.stringValue ?? "") else {
                return nil
            }
            return item["text"]?.stringValue
        }.joined()
        let images = array.filter { $0["type"]?.stringValue == "input_image" }
        let failed = text.hasPrefix("Script failed")
            || text.hasPrefix("Exit code: ") && !text.hasPrefix("Exit code: 0")
        if images.isEmpty { return (.string(text), failed) }
        return (.array([.object(["type": .string("text"), "text": .string(text)])] + images), failed)
    }

    private static func appendToolUse(
        id: String,
        name: String,
        input: HistoryValue,
        line: CodexLine,
        model: String?,
        messages: inout [HistoryMessage]
    ) {
        let block = HistoryContentBlock(type: "tool_use", id: id, name: name, input: input)
        var value = message(role: "assistant", blocks: [block], line: line)
        value.modelActual = model
        messages.append(value)
    }

    private static func message(role: String, blocks: [HistoryContentBlock], line: CodexLine) -> HistoryMessage {
        HistoryMessage(
            role: role,
            content: blocks,
            timestamp: HistoryDateParser.parse(line.timestampText),
            timestampText: line.timestampText
        )
    }

    private static func joinedText(_ content: HistoryValue?, kinds: Set<String>) -> String {
        if let string = content?.stringValue { return string }
        return content?.arrayValue?.compactMap { item in
            kinds.contains(item["type"]?.stringValue ?? "") ? item["text"]?.stringValue : nil
        }.joined(separator: "\n") ?? ""
    }

    private static func joinedUserText(_ content: HistoryValue?) -> String {
        if let string = content?.stringValue { return string }
        let array = content?.arrayValue ?? []
        let hasImage = array.contains { $0["type"]?.stringValue == "input_image" }
        return array.compactMap { item -> String? in
            guard ["input_text", "text"].contains(item["type"]?.stringValue ?? ""),
                  let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
            if hasImage, text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "</image>" { return nil }
            if hasImage, text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<image") {
                return "[Image]"
            }
            return text
        }.joined(separator: "\n")
    }

    private static func isInjectedMetadata(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "<environment_context>", "<user_instructions>", "<permissions", "<ide_",
            "<turn_context", "<AGENTS", "<workspace_"
        ].contains(where: value.hasPrefix)
    }

    private static func isAgentsBootstrap(_ text: String?) -> Bool {
        guard let text else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("# agents.md instructions for ")
            && value.contains("<instructions") && value.contains("</instructions>")
    }

    private static func skillBlock(_ text: String) -> HistoryContentBlock? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("<skill>"), value.lowercased().hasSuffix("</skill>"),
              let name = enclosed(value, tag: "name"), !name.isEmpty,
              let path = enclosed(value, tag: "path"), !path.isEmpty else { return nil }
        let raw: HistoryValue = .object([
            "type": .string("skill_load"),
            "name": .string(name),
            "path": .string(path),
            "snapshot": .string(value)
        ])
        return HistoryContentBlock(type: "skill_load", name: name, raw: raw)
    }

    private static func enclosed(_ text: String, tag: String) -> String? {
        guard let start = text.range(of: "<\(tag)>", options: .caseInsensitive),
              let end = text.range(
                of: "</\(tag)>",
                options: .caseInsensitive,
                range: start.upperBound..<text.endIndex
              ) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inlineMetadata(
        _ custom: [String: HistoryValue],
        bounded: Bool
    ) -> CodexInlineMetadata {
        var title = custom["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { title = nil }
        var tags = custom["tagList"]?.arrayValue?.compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
        if bounded {
            title = title.map { clipped($0, maximumUTF8Bytes: 512) }
            tags = tags.prefix(64).map { clipped($0, maximumUTF8Bytes: 256) }
        }
        return CodexInlineMetadata(
            title: title,
            tags: tags,
            deleted: custom["delete"]?.boolValue ?? false
        )
    }

    private static func boundedIdentity(_ value: CodexIdentity) -> CodexIdentity {
        CodexIdentity(
            threadID: value.threadID.map { clipped($0, maximumUTF8Bytes: 1_024) },
            rootSessionID: value.rootSessionID.map { clipped($0, maximumUTF8Bytes: 1_024) },
            parentThreadID: value.parentThreadID.map { clipped($0, maximumUTF8Bytes: 1_024) },
            forkedFromID: value.forkedFromID.map { clipped($0, maximumUTF8Bytes: 1_024) },
            isSubagent: value.isSubagent,
            agentPath: value.agentPath.map { clipped($0, maximumUTF8Bytes: 4 * 1_024) },
            agentNickname: value.agentNickname.map { clipped($0, maximumUTF8Bytes: 512) },
            agentRole: value.agentRole.map { clipped($0, maximumUTF8Bytes: 512) },
            agentDepth: value.agentDepth
        )
    }

    private static func metadataString(
        _ value: String?,
        bounded: Bool,
        maximumUTF8Bytes: Int = 512
    ) -> String? {
        guard let value else { return nil }
        return bounded ? clipped(value, maximumUTF8Bytes: maximumUTF8Bytes) : value
    }

    private static func boundedMessage(_ original: HistoryMessage) -> HistoryMessage {
        var message = original
        message.content = original.content.map(boundedBlock)
        message.timestampText = original.timestampText.map {
            clipped($0, maximumUTF8Bytes: 128)
        }
        message.modelActual = original.modelActual.map {
            clipped($0, maximumUTF8Bytes: 512)
        }
        message.stopReason = original.stopReason.map {
            clipped($0, maximumUTF8Bytes: 512)
        }
        return message
    }

    private static func boundedBlock(_ original: HistoryContentBlock) -> HistoryContentBlock {
        var block = original
        let textLimit = original.type == "text"
            ? maximumMessageTextBytes
            : maximumToolValueBytes
        block.text = original.text.map { clipped($0, maximumUTF8Bytes: textLimit) }
        block.thinking = original.thinking.map {
            clipped($0, maximumUTF8Bytes: maximumToolValueBytes)
        }
        block.id = original.id.map { clipped($0, maximumUTF8Bytes: 1_024) }
        block.name = original.name.map { clipped($0, maximumUTF8Bytes: 512) }
        block.toolUseID = original.toolUseID.map { clipped($0, maximumUTF8Bytes: 1_024) }
        block.input = original.input.map {
            boundedValue($0, maximumUTF8Bytes: maximumToolValueBytes)
        }
        block.content = original.content.map {
            boundedValue($0, maximumUTF8Bytes: maximumToolValueBytes)
        }
        block.raw = original.raw.map {
            boundedValue($0, maximumUTF8Bytes: maximumToolValueBytes)
        }
        return block
    }

    private static func boundedValue(
        _ value: HistoryValue,
        maximumUTF8Bytes: Int
    ) -> HistoryValue {
        switch value {
        case .string(let string):
            return .string(clipped(string, maximumUTF8Bytes: maximumUTF8Bytes))
        case .number, .bool, .null:
            return value
        case .object(let object):
            guard !object.isEmpty else { return value }
            let keys = object.keys
                .filter { $0.utf8.count <= 256 }
                .sorted { lhs, rhs in
                    let left = valueKeyPriorities[lhs] ?? valueKeyPriorities.count
                    let right = valueKeyPriorities[rhs] ?? valueKeyPriorities.count
                    return left == right ? lhs < rhs : left < right
                }
            let retainedKeys = Array(keys.prefix(64))
            let omitted = object.count - retainedKeys.count
            let slots = retainedKeys.count + (omitted > 0 ? 1 : 0)
            let childBudget = max(
                64,
                (maximumUTF8Bytes - min(1_024, maximumUTF8Bytes / 4)) / max(1, slots)
            )
            var projected: [String: HistoryValue] = [:]
            for key in retainedKeys {
                guard let child = object[key] else { continue }
                projected[key] = boundedValue(child, maximumUTF8Bytes: childBudget)
            }
            if omitted > 0 {
                projected["_ccbuddy_omitted"] = .string("\(omitted) fields")
            }
            return fittedContainer(.object(projected), maximumUTF8Bytes: maximumUTF8Bytes)
        case .array(let values):
            guard !values.isEmpty else { return value }
            let retainedCount = min(64, values.count)
            let omitted = values.count - retainedCount
            let slots = retainedCount + (omitted > 0 ? 1 : 0)
            let childBudget = max(
                64,
                (maximumUTF8Bytes - min(1_024, maximumUTF8Bytes / 4)) / max(1, slots)
            )
            var projected = values.prefix(retainedCount).map {
                boundedValue($0, maximumUTF8Bytes: childBudget)
            }
            if omitted > 0 { projected.append(.string("… \(omitted) values omitted")) }
            return fittedContainer(.array(projected), maximumUTF8Bytes: maximumUTF8Bytes)
        }
    }

    /// Only the already-projected container is encoded here. This final check accounts for JSON
    /// punctuation and escaping without ever serializing the producer's unbounded original value.
    private static func fittedContainer(
        _ value: HistoryValue,
        maximumUTF8Bytes: Int
    ) -> HistoryValue {
        let encoded = value.jsonString
        guard encoded.utf8.count > maximumUTF8Bytes else { return value }
        return .string(clipped(encoded, maximumUTF8Bytes: maximumUTF8Bytes))
    }

    private static func clipped(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        let marker = "\n… (truncated)"
        let prefixLimit = max(0, maximumUTF8Bytes - marker.utf8.count)
        var used = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let bytes = value[end..<next].utf8.count
            guard used + bytes <= prefixLimit else { break }
            used += bytes
            end = next
        }
        return String(value[..<end]) + marker
    }

    private static let valueKeyPriorities: [String: Int] = Dictionary(
        uniqueKeysWithValues: [
            "command", "cmd", "file_path", "path", "patch", "query", "code", "input",
            "output", "content", "text", "type", "name", "id", "call_id", "status",
        ].enumerated().map { ($0.element, $0.offset) }
    )

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
