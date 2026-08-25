import Foundation

enum GrokHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let summary = ForeignHistorySupport.jsonObject(
            at: context.candidate.file.deletingLastPathComponent().appendingPathComponent("summary.json")
        )
        let model = summary?["current_model_id"]?.stringValue
        var messages: [HistoryMessage] = []

        for record in context.document.records {
            switch record["type"]?.stringValue ?? "" {
            case "user":
                let blocks = userBlocks(record["content"])
                if !blocks.isEmpty { messages.append(message(role: "user", blocks: blocks)) }
            case "reasoning":
                let text = record["summary"]?.arrayValue?.compactMap {
                    $0["text"]?.stringValue
                }.joined(separator: "\n") ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(message(
                        role: "assistant",
                        blocks: [.init(type: "thinking", thinking: text)],
                        model: model
                    ))
                }
            case "assistant":
                var blocks: [HistoryContentBlock] = []
                if let text = record["content"]?.stringValue,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.init(type: "text", text: text))
                }
                for call in record["tool_calls"]?.arrayValue ?? [] {
                    let originalName = call["name"]?.stringValue ?? "tool"
                    let arguments = ForeignHistorySupport.decodeJSONObject(call["arguments"])
                    let mapped = mapTool(originalName, arguments: arguments)
                    blocks.append(.init(
                        type: "tool_use",
                        id: call["id"]?.stringValue ?? "",
                        name: mapped.0,
                        input: mapped.1,
                        raw: call
                    ))
                }
                if !blocks.isEmpty {
                    messages.append(message(role: "assistant", blocks: blocks, model: model))
                }
            case "tool_result":
                let text = record["content"]?.stringValue ?? ""
                let images: [HistoryContentBlock] = (record["images"]?.arrayValue ?? []).compactMap { item -> HistoryContentBlock? in
                    guard let url = item["url"]?.stringValue else { return nil }
                    return ForeignHistorySupport.imageBlock(fromDataURL: url)
                }
                let content: HistoryValue
                if images.isEmpty {
                    content = .string(text)
                } else {
                    content = .array(
                        [.object(["type": .string("text"), "text": .string(text)])]
                        + images.compactMap { $0.raw }
                    )
                }
                messages.append(message(
                    role: "user",
                    blocks: [.init(
                        type: "tool_result",
                        toolUseID: record["tool_call_id"]?.stringValue ?? "",
                        content: content,
                        raw: .object(record)
                    )]
                ))
            default:
                continue
            }
        }

        let uuid = context.candidate.file.deletingLastPathComponent().lastPathComponent
        let custom = ForeignHistorySupport.customMetadata(
            source: .grok,
            sessionKey: uuid,
            appDataRoot: context.appDataRoot
        )
        let summaryTitle = ForeignHistorySupport.trimmed(summary?["generated_title"])
            ?? ForeignHistorySupport.trimmed(summary?["session_summary"])
        let autoTitle = summaryTitle ?? HistoryParsingSupport.firstUserTitle(in: messages)
        let cwd = summary?["info"]?["cwd"]?.stringValue ?? fallbackCWD(context.candidate.file)
        let createdAt = HistoryDateParser.parse(summary?["created_at"]?.stringValue)
            ?? context.facts.createdAt
        let metadata = HistorySessionMetadata(
            id: "grok:\(uuid)",
            file: context.candidate.file,
            source: .grok,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: summary?["info"]?["id"]?.stringValue ?? uuid,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil),
            gitBranch: summary?["head_branch"]?.stringValue,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: model,
            imported: false,
            deleted: custom.deleted,
            starred: custom.starred,
            pinned: custom.pinned,
            createdAt: createdAt,
            lastActivity: context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            messageCount: messages.count,
            diagnostics: context.document.diagnostics
        )
        return HistorySession(metadata: metadata, messages: messages)
    }

    private static func message(
        role: String,
        blocks: [HistoryContentBlock],
        model: String? = nil
    ) -> HistoryMessage {
        HistoryMessage(role: role, content: blocks, modelActual: model)
    }

    private static func userBlocks(_ content: HistoryValue?) -> [HistoryContentBlock] {
        if let text = content?.stringValue {
            let value = unwrapUserQuery(text)
            guard !value.isEmpty, !isMetadataUserText(text) else { return [] }
            return [.init(type: "text", text: value)]
        }
        var result: [HistoryContentBlock] = []
        for block in content?.arrayValue ?? [] {
            switch block["type"]?.stringValue ?? "" {
            case "text":
                let raw = block["text"]?.stringValue ?? ""
                if isMetadataUserText(raw), !raw.contains("<user_query>") { continue }
                let text = unwrapUserQuery(raw)
                if !text.isEmpty { result.append(.init(type: "text", text: text, raw: block)) }
            case "image":
                if let url = block["url"]?.stringValue,
                   let image = ForeignHistorySupport.imageBlock(fromDataURL: url) {
                    result.append(image)
                }
            default:
                continue
            }
        }
        return result
    }

    private static func isMetadataUserText(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<user_info>", "<git_status>", "<system-reminder>", "<project_layout", "<workspace_"]
            .contains { value.hasPrefix($0) }
    }

    private static func unwrapUserQuery(_ text: String) -> String {
        guard let opening = text.range(of: "<user_query>") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rest = text[opening.upperBound...]
        let body = rest.range(of: "</user_query>").map { rest[..<$0.lowerBound] } ?? rest[...]
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackCWD(_ file: URL) -> String? {
        let encoded = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard HistoryPathResolver.isGrokCWDDirectoryName(encoded) else { return nil }
        return ForeignHistorySupport.percentDecode(encoded)
    }

    private static func mapTool(_ name: String, arguments: HistoryValue) -> (String, HistoryValue) {
        let object = arguments.objectValue ?? [:]
        func string(_ key: String) -> String { object[key]?.stringValue ?? "" }
        func kept() -> HistoryValue { .object(object) }

        switch name {
        case "run_terminal_command", "Shell":
            var input: [String: HistoryValue] = ["command": .string(string("command"))]
            if !string("description").isEmpty { input["description"] = .string(string("description")) }
            return ("Bash", .object(input))
        case "read_file", "Read":
            var input: [String: HistoryValue] = [
                "file_path": .string(string("target_file").isEmpty ? string("path") : string("target_file")),
            ]
            for key in ["offset", "limit"] where object[key] != nil && object[key] != .null {
                input[key] = object[key]
            }
            return ("Read", .object(input))
        case "grep", "Grep", "grep_search":
            var input: [String: HistoryValue] = [
                "pattern": .string(string("pattern").isEmpty ? string("query") : string("pattern")),
            ]
            if !string("path").isEmpty { input["path"] = .string(string("path")) }
            return ("Grep", .object(input))
        case "search_replace": return ("Edit", kept())
        case "StrReplace":
            return ("Edit", .object([
                "file_path": .string(string("path")),
                "old_string": .string(string("old_string")),
                "new_string": .string(string("new_string")),
            ]))
        case "write": return ("Write", kept())
        case "Write":
            return ("Write", .object([
                "file_path": .string(string("path")),
                "content": .string(string("contents")),
            ]))
        case "list_dir": return ("LS", .object(["path": .string(string("target_directory"))]))
        case "Glob":
            return ("Glob", .object([
                "pattern": .string(string("glob_pattern")),
                "path": .string(string("target_directory")),
            ]))
        case "todo_write", "TodoWrite": return ("TodoWrite", kept())
        case "web_fetch", "WebFetch": return ("WebFetch", .object(["url": .string(string("url"))]))
        case "WebSearch": return ("WebSearch", .object(["query": .string(string("search_term"))]))
        default: return (name, kept())
        }
    }
}
