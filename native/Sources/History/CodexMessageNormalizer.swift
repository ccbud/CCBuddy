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
}

enum CodexMessageNormalizer {
    static func normalize(_ records: [[String: HistoryValue]]) -> CodexNormalizedTranscript {
        let lines = records.map(CodexRecord.split)
        var messages: [HistoryMessage] = []
        var totals = HistoryTotals()
        var model: String?
        var cwd: String?
        var version: String?
        var gitBranch: String?
        var identity = CodexIdentity()
        var sawSessionMetadata = false

        for line in lines {
            switch line.kind {
            case "session_meta":
                if !sawSessionMetadata {
                    sawSessionMetadata = true
                    identity = CodexRecord.canonicalIdentity(line.payload)
                }
                if identity.rootSessionID == nil {
                    identity.rootSessionID = line.payload["session_id"]?.stringValue
                        ?? line.payload["id"]?.stringValue
                }
                cwd = cwd ?? line.payload["cwd"]?.stringValue
                version = version ?? line.payload["cli_version"]?.stringValue
                gitBranch = gitBranch ?? line.payload["git"]?["branch"]?.stringValue
            case "turn_context":
                if let value = line.payload["model"]?.stringValue { model = value }
                cwd = cwd ?? line.payload["cwd"]?.stringValue
            case "compacted":
                if let text = nonempty(line.payload["message"]?.stringValue) {
                    messages.append(message(
                        role: "user",
                        blocks: [.init(type: "text", text: text)],
                        line: line
                    ))
                }
            case "event_msg":
                handleEvent(line, messages: &messages, totals: &totals)
            case "response_item":
                handleResponseItem(line, model: model, messages: &messages)
            default:
                continue
            }
        }
        return CodexNormalizedTranscript(
            lines: lines,
            messages: messages,
            totals: totals,
            model: model,
            cwd: cwd,
            version: version,
            gitBranch: gitBranch,
            identity: identity
        )
    }

    static func firstEventUserTitle(_ lines: [CodexLine]) -> String {
        for line in lines where line.kind == "event_msg"
            && line.payload["type"]?.stringValue == "user_message" {
            let messageText = line.payload["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let imageCount = (line.payload["images"]?.arrayValue?.count ?? 0)
                + (line.payload["local_images"]?.arrayValue?.count ?? 0)
            let labels = imageCount > 0
                ? (1...imageCount).map { "[Image #\($0)]" }.joined(separator: " ")
                : ""
            let title = [labels, messageText].filter { !$0.isEmpty }.joined(separator: " ")
            if !title.isEmpty { return String(title.prefix(90)) }
        }
        return ""
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

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
