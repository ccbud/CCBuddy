import Foundation

enum ConversationHTMLExportError: LocalizedError, Equatable, Sendable {
    case invalidData
    case writeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidData: "无法构建会话导出数据"
        case .writeFailed(let file, let detail): "无法写入 \(file.lastPathComponent)：\(detail)"
        }
    }
}

struct ConversationHTMLExporter: @unchecked Sendable {
    private enum Cap {
        static let text = 24_000
        static let thinking = 16_000
        static let result = 24_000
        static let prompt = 9_000
        static let content = 14_000
        static let skillSnapshot = 131_072
        static let inlineImage = 600_000
    }

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    func export(_ session: HistorySession, to destination: URL) throws {
        let data = try Data(html(for: session).utf8)
        do { try SecureAtomicFile.write(data, to: destination, fileManager: fileManager) }
        catch {
            throw ConversationHTMLExportError.writeFailed(destination, String(describing: error))
        }
    }

    func html(for session: HistorySession) throws -> String {
        let exportData = dataObject(for: session)
        guard JSONSerialization.isValidJSONObject(exportData) else {
            throw ConversationHTMLExportError.invalidData
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: exportData,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard var json = String(data: encoded, encoding: .utf8) else {
            throw ConversationHTMLExportError.invalidData
        }
        // A transcript can contain `</script>` even when markdown HTML is disabled. Escaping every
        // opening angle bracket keeps the JSON inside its generator-owned script element.
        json = json.replacingOccurrences(of: "<", with: "\\u003c")

        let nonce = "ccbud-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let projectTitle = htmlEscaped(
            session.metadata.project.isEmpty ? "Conversation" : session.metadata.project
        )
        let version = htmlEscaped(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        )
        let csp = [
            "default-src 'none'",
            "script-src 'nonce-\(nonce)' https://www.clarity.ms https://*.clarity.ms",
            "connect-src https://*.clarity.ms https://c.bing.com",
            "style-src 'unsafe-inline'",
            "img-src data:",
            "base-uri 'none'",
            "object-src 'none'",
        ].joined(separator: "; ")

        return """
        <!doctype html><html lang="zh" data-theme="light"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(projectTitle) · CC Buddy</title>
        <style>\(ConversationExportAssets.skin)\n\(ConversationExportAssets.highlightCSS)</style>
        </head><body><div id="app" data-clarity-mask="true"></div>
        <script nonce="\(nonce)">\(ConversationExportAssets.marked)</script>
        <script nonce="\(nonce)">\(ConversationExportAssets.highlight)</script>
        <script nonce="\(nonce)">window.__CONV__=\(json);window.__CCBUD_VERSION__="\(version)";</script>
        <script nonce="\(nonce)">\(ConversationExportAssets.runtime)</script>
        </body></html>
        """
    }

    func suggestedBaseName(for session: HistorySession) -> String {
        let project = sanitizeName(
            session.metadata.project.isEmpty ? "conversation" : session.metadata.project
        )
        let conversationStart = Self.filenameDate.string(from: session.metadata.createdAt)
        let exportedAt = Self.filenameDate.string(from: now())
        return "\(project.isEmpty ? "conversation" : project)-\(conversationStart)-\(exportedAt)"
    }

    private func dataObject(for session: HistorySession) -> [String: Any] {
        let metadata = session.metadata
        var subagents: [String: Any] = [:]
        for key in session.subagents.keys.sorted() {
            guard let subagent = session.subagents[key] else { continue }
            subagents[key] = [
                "agentId": subagent.agentID,
                "file": subagent.file.path,
                "type": subagent.type,
                "description": subagent.description,
                "skill": subagent.skill ?? NSNull(),
                "count": subagent.count,
                "totals": totalsObject(subagent.totals),
                "messages": subagent.messages.map(messageObject),
            ]
        }
        return [
            "meta": [
                "title": metadata.title.isEmpty ? "(conversation)" : metadata.title,
                "assistant": ConversationPresentation.sourceName(rawValue: metadata.source.rawValue),
                "model": metadata.model ?? NSNull(),
                "project": metadata.project,
                "cwd": metadata.cwd ?? NSNull(),
                "branch": metadata.gitBranch ?? NSNull(),
                "sessionId": metadata.sessionID,
                "version": metadata.version ?? NSNull(),
                "count": session.messages.count,
                "turns": metadata.totals.turns,
                "inTok": metadata.totals.inputTokens,
                "outTok": metadata.totals.outputTokens,
                "cacheTok": metadata.totals.cacheRead,
                "credits": metadata.totals.credits ?? NSNull(),
                "tokenUsageAvailable": metadata.totals.tokenUsageAvailable ?? true,
                "subagentCount": subagents.count,
                "firstTs": timestamp(
                    session.messages.compactMap(\.timestamp).first ?? metadata.createdAt
                ),
                "lastTs": timestamp(
                    session.messages.compactMap(\.timestamp).last ?? metadata.lastActivity
                ),
            ],
            "messages": session.messages.map(messageObject),
            "subagents": subagents,
        ]
    }

    private func messageObject(_ message: HistoryMessage) -> [String: Any] {
        var result: [String: Any] = [
            "role": message.role,
            "content": message.content.map(blockObject),
            "ts": message.timestampText ?? message.timestamp.map(timestamp) ?? NSNull(),
            "meta": message.isMetadata,
        ]
        if let model = message.modelActual { result["model"] = model }
        if let usage = message.usage { result["usage"] = usageObject(usage) }
        if let stop = message.stopReason { result["stop"] = stop }
        return result
    }

    private func blockObject(_ block: HistoryContentBlock) -> Any {
        switch block.type {
        case "text":
            return ["type": "text", "text": capped(block.text ?? "", at: Cap.text)]
        case "thinking":
            return [
                "type": "thinking",
                "thinking": capped(block.thinking ?? "", at: Cap.thinking),
            ]
        case "skill_load":
            let result: [String: Any] = [
                "type": "skill_load",
                "name": block.name as Any? ?? NSNull(),
                "path": block.raw?["path"]?.stringValue as Any? ?? NSNull(),
                "snapshot": block.raw?["snapshot"]?.stringValue
                    .map { capped($0, at: Cap.skillSnapshot) } as Any? ?? NSNull(),
            ]
            return result
        case "tool_use":
            var input = foundation(block.input ?? .object([:]))
            if var object = input as? [String: Any] {
                for (field, limit) in [
                    ("prompt", Cap.prompt),
                    ("content", Cap.content),
                    ("patch", Cap.content),
                    ("code", Cap.content),
                ] {
                    if let value = object[field] as? String {
                        object[field] = capped(value, at: limit)
                    }
                }
                input = object
            }
            let result: [String: Any] = [
                "type": "tool_use",
                "id": block.id as Any? ?? NSNull(),
                "name": block.name as Any? ?? NSNull(),
                "input": input,
            ]
            return result
        case "tool_result":
            let result: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": block.toolUseID as Any? ?? NSNull(),
                "is_error": block.isError ?? false,
                "content": cappedResult(block.content),
            ]
            return result
        case "image":
            if let raw = block.raw {
                let value = foundation(raw)
                if let object = value as? [String: Any],
                   let source = object["source"] as? [String: Any],
                   let imageData = source["data"] as? String,
                   imageData.count > Cap.inlineImage {
                    return [
                        "type": "image",
                        "source": [
                            "media_type": source["media_type"] as? String ?? "image/png",
                            "oversized": true,
                        ],
                    ]
                }
                return value
            }
            return ["type": "image"]
        default:
            if let raw = block.raw { return foundation(raw) }
            var result: [String: Any] = ["type": block.type]
            if let text = block.text { result["text"] = capped(text, at: Cap.text) }
            if let thinking = block.thinking {
                result["thinking"] = capped(thinking, at: Cap.thinking)
            }
            return result
        }
    }

    private func cappedResult(_ value: HistoryValue?) -> Any {
        guard let value else { return NSNull() }
        if let string = value.stringValue { return capped(string, at: Cap.result) }
        if let array = value.arrayValue {
            return array.map { item -> Any in
                if item["type"]?.stringValue == "text" {
                    return [
                        "type": "text",
                        "text": capped(item["text"]?.stringValue ?? "", at: Cap.result),
                    ]
                }
                return foundation(item)
            }
        }
        return foundation(value)
    }

    private func usageObject(_ usage: HistoryUsage) -> [String: Any] {
        var result: [String: Any] = [
            "in": usage.inputTokens,
            "out": usage.outputTokens,
            "cacheRead": usage.cacheRead,
            "cacheCreation": usage.cacheCreation,
        ]
        if let value = usage.credits { result["credits"] = value }
        if let value = usage.originalCredits { result["originalCredits"] = value }
        if let value = usage.contextUsageRatio { result["contextUsageRatio"] = value }
        return result
    }

    private func totalsObject(_ totals: HistoryTotals) -> [String: Any] {
        var result: [String: Any] = [
            "in": totals.inputTokens,
            "out": totals.outputTokens,
            "cacheRead": totals.cacheRead,
            "cacheCreation": totals.cacheCreation,
            "turns": totals.turns,
            "tokenUsageAvailable": totals.tokenUsageAvailable ?? true,
        ]
        if let value = totals.credits { result["credits"] = value }
        return result
    }

    private func foundation(_ value: HistoryValue) -> Any {
        switch value {
        case .string(let value): return value
        case .number(let value): return value.isFinite ? value : 0
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(foundation)
        case .object(let values):
            return Dictionary(uniqueKeysWithValues: values.map { ($0.key, foundation($0.value)) })
        }
    }

    private func capped(_ value: String, at limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        let dropped = value.count - limit
        return String(value[..<end]) + "\n…[truncated \(dropped) chars]"
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(Self.iso8601)
    }

    private func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func sanitizeName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
            .union(.whitespacesAndNewlines)
        var result = ""
        var previousUnderscore = false
        for scalar in raw.unicodeScalars {
            if forbidden.contains(scalar) {
                if !previousUnderscore { result.append("_") }
                previousUnderscore = true
            } else {
                result.unicodeScalars.append(scalar)
                previousUnderscore = false
            }
        }
        return String(result.trimmingCharacters(in: CharacterSet(charactersIn: "_.-")).prefix(60))
    }

    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMddHHmm"
        return formatter
    }()
}
