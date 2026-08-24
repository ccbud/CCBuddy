import Foundation

enum ConversationMarkdownExportError: LocalizedError, Equatable, Sendable {
    case writeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let file, let detail):
            "无法写入 \(file.lastPathComponent)：\(detail)"
        }
    }
}

/// Wake-style, readable transcript export. Raw producer data remains available through the
/// existing JSONL/DB/ZIP path; this exporter is deliberately a normalized human-facing view.
struct ConversationMarkdownExporter: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func export(_ session: HistorySession, to destination: URL) throws {
        do {
            try SecureAtomicFile.write(
                Data(markdown(for: session).utf8),
                to: destination,
                fileManager: fileManager
            )
        } catch {
            throw ConversationMarkdownExportError.writeFailed(
                destination,
                String(describing: error)
            )
        }
    }

    func markdown(for session: HistorySession) -> String {
        var sections: [String] = [header(for: session)]
        sections.append(messages(session.messages))

        for key in session.subagents.keys.sorted() {
            guard let subagent = session.subagents[key], !subagent.messages.isEmpty else { continue }
            let descriptor = [subagent.type, subagent.description]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "agent" }
                .joined(separator: ": ")
            let title = descriptor.isEmpty ? subagent.agentID : descriptor
            sections.append("---\n\n## ⑂ Subagent: \(title)\n\n\(messages(subagent.messages))")
        }

        return sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func header(for session: HistorySession) -> String {
        let metadata = session.metadata
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = ConversationPresentation.sourceName(rawValue: metadata.source.rawValue)
        let project = metadata.project.isEmpty ? "(unknown)" : metadata.project
        var projectValue = project
        if let branch = metadata.gitBranch, !branch.isEmpty {
            projectValue += " (\(branch))"
        }
        let tokens = metadata.totals.inputTokens + metadata.totals.outputTokens
        var facts = [
            "**Agent**: \(agent)",
            "**Project**: \(projectValue)",
            "**Time**: \(timestamp(metadata.createdAt)) – \(timestamp(metadata.lastActivity))",
            "**Messages**: \(metadata.messageCount)",
        ]
        if tokens > 0 { facts.append("**Tokens**: \(formattedCount(tokens))") }
        if let credits = metadata.totals.credits {
            facts.append("**Credits**: \(String(format: "%.2f", credits))")
        }
        return "# \(title.isEmpty ? "Conversation" : title)\n\n> \(facts.joined(separator: " · "))\n\n---"
    }

    private func messages(_ values: [HistoryMessage]) -> String {
        values
            .filter { !$0.isMetadata }
            .map(message)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func message(_ value: HistoryMessage) -> String {
        var result = "### \(roleLabel(value.role))"
        if let date = value.timestamp {
            result += " · \(timestamp(date))"
        } else if let text = value.timestampText, !text.isEmpty {
            result += " · \(text)"
        }

        var blocks: [String] = []
        for block in value.content {
            switch block.type {
            case "text":
                append(block.text, to: &blocks)
            case "thinking":
                if let thinking = nonempty(block.thinking ?? block.text) {
                    blocks.append("<details><summary>🧠 Thinking</summary>\n\n\(thinking)\n\n</details>")
                }
            case "tool_use":
                let name = nonempty(block.name) ?? "tool"
                var body = "<details><summary>🔧 \(htmlEscaped(name))</summary>"
                if let input = block.input {
                    body += "\n\nInput:\n\n\(fenced(input.jsonString, language: "json"))"
                }
                body += "\n\n</details>"
                blocks.append(body)
            case "tool_result":
                guard let content = block.content else { continue }
                let output = content.stringValue ?? content.jsonString
                guard !output.isEmpty else { continue }
                let label = block.isError == true ? "Tool error" : "Tool result"
                blocks.append("<details><summary>\(label)</summary>\n\n\(fenced(output))\n\n</details>")
            case "skill_load":
                let name = nonempty(block.name) ?? "Skill"
                blocks.append("_Loaded skill: \(name)_")
            case "image":
                blocks.append("_[Image attachment]_" )
            default:
                if let text = nonempty(block.text ?? block.thinking) {
                    blocks.append(text)
                } else if let raw = block.raw, !raw.jsonString.isEmpty {
                    blocks.append(fenced(raw.jsonString, language: "json"))
                }
            }
        }

        guard !blocks.isEmpty else { return "" }
        return result + "\n\n" + blocks.joined(separator: "\n\n")
    }

    private func append(_ value: String?, to result: inout [String]) {
        if let value = nonempty(value) { result.append(value) }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func roleLabel(_ role: String) -> String {
        switch role.lowercased() {
        case "user": "👤 User"
        case "assistant": "🤖 Assistant"
        case "system": "⚙️ System"
        default: role.isEmpty ? "Message" : role.capitalized
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formattedCount(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: String(value)
        }
    }

    private func fenced(_ text: String, language: String = "") -> String {
        let longestRun = text.split(separator: "`", omittingEmptySubsequences: false)
            .dropLast()
            .reduce(into: (current: 0, longest: 0)) { state, component in
                if component.isEmpty {
                    state.current += 1
                    state.longest = max(state.longest, state.current)
                } else {
                    state.current = 1
                    state.longest = max(state.longest, state.current)
                }
            }.longest
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
