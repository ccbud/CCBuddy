import Foundation

struct HistoryParseContext: Sendable {
    var candidate: HistoryFileCandidate
    var document: HistoryJSONLDocument
    var facts: HistoryFileFacts
    var homeDirectory: URL
    var appDataRoot: URL
}

enum HistoryTranscriptFormat: Equatable, Sendable {
    case claude
    case codex
    case qoder
    case grok
    case copilot
    case antigravity

    static func detect(_ records: [[String: HistoryValue]]) -> HistoryTranscriptFormat? {
        if records.contains(where: isQoderRecord) { return .qoder }
        if records.prefix(8).contains(where: isCodexRecord) { return .codex }
        if records.contains(where: { record in
            guard let type = record["type"]?.stringValue else { return false }
            return (type == "user" || type == "assistant") && record["message"]?.objectValue != nil
        }) {
            return .claude
        }
        return nil
    }

    private static func isQoderRecord(_ record: [String: HistoryValue]) -> Bool {
        switch record["type"]?.stringValue ?? "" {
        case "agent-setting", "ai-title", "custom-title", "last-prompt",
             "workspace-directories", "runtime-config":
            return true
        case "attachment":
            return record["attachment"]?["type"]?.stringValue == "queued_command"
        default:
            return false
        }
    }

    private static func isCodexRecord(_ record: [String: HistoryValue]) -> Bool {
        let type = record["type"]?.stringValue ?? ""
        switch type {
        case "session_meta", "turn_context", "event_msg", "compacted": return true
        case "response_item": return record["payload"] != nil
        case "message", "function_call", "function_call_output", "reasoning", "local_shell_call":
            return record["message"] == nil
        default: return record["record_type"] != nil
        }
    }
}

enum HistoryParsingSupport {
    static func blocks(from value: HistoryValue?) -> [HistoryContentBlock] {
        guard let value else { return [] }
        if let string = value.stringValue {
            return string.isEmpty ? [] : [HistoryContentBlock(type: "text", text: string, raw: value)]
        }
        guard let array = value.arrayValue else { return [] }
        return array.compactMap(block(from:))
    }

    static func block(from value: HistoryValue) -> HistoryContentBlock? {
        guard let object = value.objectValue else { return nil }
        let type = object["type"]?.stringValue ?? "unknown"
        switch type {
        case "text", "input_text", "output_text":
            return HistoryContentBlock(type: "text", text: object["text"]?.stringValue, raw: value)
        case "thinking", "reasoning":
            return HistoryContentBlock(
                type: "thinking",
                thinking: object["thinking"]?.stringValue ?? object["text"]?.stringValue,
                raw: value
            )
        case "tool_use":
            return HistoryContentBlock(
                type: type,
                id: object["id"]?.stringValue,
                name: object["name"]?.stringValue,
                input: object["input"],
                raw: value
            )
        case "tool_result":
            return HistoryContentBlock(
                type: type,
                toolUseID: object["tool_use_id"]?.stringValue,
                content: object["content"],
                isError: object["is_error"]?.boolValue,
                raw: value
            )
        default:
            return HistoryContentBlock(
                type: type,
                text: object["text"]?.stringValue,
                thinking: object["thinking"]?.stringValue,
                id: object["id"]?.stringValue,
                name: object["name"]?.stringValue,
                toolUseID: object["tool_use_id"]?.stringValue,
                input: object["input"],
                content: object["content"],
                isError: object["is_error"]?.boolValue,
                raw: value
            )
        }
    }

    static func usage(from value: HistoryValue?) -> HistoryUsage? {
        guard let object = value?.objectValue else { return nil }
        return HistoryUsage(
            inputTokens: object["input_tokens"]?.integerValue ?? 0,
            outputTokens: object["output_tokens"]?.integerValue ?? 0,
            cacheRead: object["cache_read_input_tokens"]?.integerValue ?? 0,
            cacheCreation: object["cache_creation_input_tokens"]?.integerValue ?? 0,
            credits: object["credits"]?.numberValue,
            originalCredits: object["original_credits"]?.numberValue,
            contextUsageRatio: object["context_usage_ratio"]?.numberValue
        )
    }

    static func firstUserTitle(in messages: [HistoryMessage]) -> String {
        var commandFallback = ""
        for message in messages where message.role == "user" && !message.isMetadata {
            let raw = message.content.compactMap(plainText).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            if raw.hasPrefix("<") {
                if commandFallback.isEmpty { commandFallback = commandLabel(raw) }
                continue
            }
            let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if collapsed.hasPrefix("[Request interrupted") || collapsed.hasPrefix("Caveat:") { continue }
            return String(collapsed.prefix(90))
        }
        return String(commandFallback.prefix(90))
    }

    static func plainText(_ block: HistoryContentBlock) -> String? {
        switch block.type {
        case "text": return block.text
        case "thinking": return block.thinking
        case "skill_load":
            return [block.name, block.raw?["path"]?.stringValue, block.raw?["snapshot"]?.stringValue]
                .compactMap { $0 }.joined(separator: "\n")
        case "tool_use":
            return [block.name, block.input?.jsonString].compactMap { $0 }.joined(separator: " ")
        case "tool_result":
            return searchableToolResult(block.content)
        default: return block.text ?? block.thinking
        }
    }

    static func searchableToolResult(_ content: HistoryValue?) -> String? {
        guard let content else { return nil }
        if let string = content.stringValue { return string }
        if let array = content.arrayValue {
            return array.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        }
        return content.jsonString
    }

    static func projectName(cwd: String?, encodedDirectory: String?) -> String {
        if let cwd, !cwd.isEmpty { return HistoryPathResolver.baseName(of: cwd) }
        guard let encodedDirectory,
              let decoded = HistoryPathResolver.decodeProjectDirectoryName(encodedDirectory) else { return "" }
        return HistoryPathResolver.baseName(of: decoded)
    }

    static func customMetadata(_ records: [[String: HistoryValue]]) -> (String?, [String], Bool) {
        guard let custom = records.lazy.compactMap({ $0["__ccbud__"]?.objectValue }).first else {
            return (nil, [], false)
        }
        let title = custom["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = custom["tagList"]?.arrayValue?.compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
        return (title?.isEmpty == false ? title : nil, tags, custom["delete"]?.boolValue ?? false)
    }

    static func isCanonicalThreadID(_ value: String?) -> Bool {
        guard let value else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        let hyphens = Set([8, 13, 18, 23])
        return bytes.enumerated().allSatisfy { index, byte in
            hyphens.contains(index) ? byte == 45 : byte.isASCIIHexDigit
        }
    }

    private static func commandLabel(_ raw: String) -> String {
        guard let name = enclosedValue(in: raw, tag: "command-name"), !name.isEmpty else { return "" }
        let arguments = enclosedValue(in: raw, tag: "command-args") ?? ""
        return "\(name) \(arguments)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func enclosedValue(in text: String, tag: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"),
              let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
