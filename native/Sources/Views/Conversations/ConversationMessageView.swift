import Foundation
import SwiftUI

struct ConversationMessageView: View {
    @Environment(\.appLanguage) private var appLanguage

    let message: HistoryMessage
    let messageIndex: Int
    let sourceRawValue: String
    let toolResults: [String: HistoryContentBlock]
    let pairedToolResultIDs: Set<String>
    let searchQuery: String
    let isCurrentSearchMatch: Bool
    let fontSize: CGFloat

    static func isVisible(_ message: HistoryMessage, pairedToolResultIDs: Set<String>) -> Bool {
        message.content.contains { block in
            if block.type == "tool_result",
               let id = block.toolUseID,
               pairedToolResultIDs.contains(id) {
                return false
            }
            switch block.type {
            case "text":
                let value = message.role == "user"
                    ? ConversationVisibleText.stripInjected(block.text ?? "")
                    : (block.text ?? "")
                return !value.isEmpty
            case "thinking": return !(block.thinking ?? "").isEmpty
            case "tool_use", "skill_load", "image": return true
            case "tool_result": return block.content != nil
            default: return block.raw != nil || block.text != nil || block.thinking != nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            roleHeader
            messageBody
            messageMetadata
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(isCurrentSearchMatch ? Theme.accentSoft.opacity(0.48) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isCurrentSearchMatch {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.accent.opacity(0.35))
            }
        }
        .accessibilityIdentifier("conversation.message.\(messageIndex)")
    }

    /// Who is speaking, said plainly.
    ///
    /// The assistant is identified by its own brand mark rather than by a decorative "✦", which is
    /// the same rule the rest of the app follows; the bullets used here were Unicode glyphs standing
    /// in for icons. Names are no longer upper-cased either: it does nothing to Chinese and turns
    /// "Claude Code" into shouting.
    private var roleHeader: some View {
        HStack(spacing: Space.xs + 2) {
            roleMark
            Text(localizedRoleName)
            if message.isSidechain {
                Text("子代理")
                    .font(.system(size: max(9, fontSize * 0.72), weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: max(10, fontSize * 0.82), weight: .medium))
        .foregroundStyle(Theme.mutedForeground)
    }

    @ViewBuilder private var roleMark: some View {
        let size = max(12, fontSize * 0.95)
        if message.isMetadata {
            Image(systemName: "info.circle")
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        } else if message.role == "user" {
            Image(systemName: "person.crop.circle")
                .font(.system(size: size * 0.9))
                .frame(width: size, height: size)
        } else if message.role == "assistant", let source = HistorySource(rawValue: sourceRawValue) {
            AgentBrandMark(source: source, size: size)
        } else {
            Image(systemName: "circle")
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder private var messageBody: some View {
        let blocks = message.content.filter { block in
            guard block.type == "tool_result", let id = block.toolUseID else { return true }
            return !pairedToolResultIDs.contains(id)
        }

        if message.role == "user" && !message.isMetadata {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ConversationBlockView(
                        block: block,
                        result: block.id.flatMap { toolResults[$0] },
                        role: message.role,
                        searchQuery: searchQuery,
                        isCurrentSearchMatch: isCurrentSearchMatch,
                        fontSize: fontSize
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.separator))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ConversationBlockView(
                        block: block,
                        result: block.id.flatMap { toolResults[$0] },
                        role: message.role,
                        searchQuery: searchQuery,
                        isCurrentSearchMatch: isCurrentSearchMatch,
                        fontSize: fontSize
                    )
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.separator).frame(width: 2)
            }
        }
    }

    @ViewBuilder private var messageMetadata: some View {
        let chips = metadataChips
        if !chips.isEmpty {
            // Each chip keeps its own width. Left to shrink, a narrow column broke them mid-word
            // — "gpt-5.6-sol" came out as four stacked fragments — which is unreadable in a way
            // that losing the tail of the row is not.
            HStack(spacing: 4) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.system(size: max(9, fontSize * 0.73), design: .monospaced))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.foreground.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .help(chips.joined(separator: " · "))
            .padding(.leading, message.role == "user" ? 0 : 12)
        }
    }

    private var metadataChips: [String] {
        var values: [String] = []
        if let timestamp = message.timestamp {
            values.append(ConversationPresentation.time(timestamp, language: appLanguage))
        }
        else if let timestampText = message.timestampText, !timestampText.isEmpty { values.append(timestampText) }
        if let model = message.modelActual, !model.isEmpty { values.append(model) }
        if let usage = message.usage {
            values.append(appLanguage.localized(
                "输入 \(ConversationPresentation.tokenCount(usage.inputTokens))"
            ))
            values.append(appLanguage.localized(
                "输出 \(ConversationPresentation.tokenCount(usage.outputTokens))"
            ))
            if usage.cacheRead > 0 {
                values.append(appLanguage.localized(
                    "缓存读取 \(ConversationPresentation.tokenCount(usage.cacheRead))"
                ))
            }
            if usage.cacheCreation > 0 {
                values.append(appLanguage.localized(
                    "缓存写入 \(ConversationPresentation.tokenCount(usage.cacheCreation))"
                ))
            }
            if let credits = usage.credits { values.append("Credits \(ConversationPresentation.credits(credits))") }
            if let original = usage.originalCredits {
                values.append(appLanguage.localized(
                    "原始 Credits \(ConversationPresentation.credits(original))"
                ))
            }
            if let ratio = usage.contextUsageRatio {
                values.append(appLanguage.localized("上下文 \(Int((ratio * 100).rounded()))%"))
            }
        }
        if let stopReason = message.stopReason, !stopReason.isEmpty { values.append(stopReason) }
        return values
    }

    private var localizedRoleName: String {
        if message.isMetadata { return appLanguage.localized("上下文") }
        if message.role == "user" { return appLanguage.localized("你") }
        if message.role == "assistant" {
            return appLanguage.localized(
                ConversationPresentation.sourceName(rawValue: sourceRawValue)
            )
        }
        return message.role.isEmpty ? appLanguage.localized("消息") : message.role
    }

}

private struct ConversationBlockView: View {
    let block: HistoryContentBlock
    let result: HistoryContentBlock?
    let role: String
    let searchQuery: String
    let isCurrentSearchMatch: Bool
    let fontSize: CGFloat

    @ViewBuilder var body: some View {
        switch block.type {
        case "text":
            let value = role == "user"
                ? ConversationVisibleText.stripInjected(block.text ?? "")
                : (block.text ?? "")
            if !value.isEmpty {
                ConversationHighlightedText(
                    value: value,
                    query: searchQuery,
                    current: isCurrentSearchMatch,
                    fontSize: fontSize,
                    color: Theme.foreground
                )
            }
        case "thinking":
            if let thinking = block.thinking, !thinking.isEmpty {
                ConversationThinkingView(
                    thinking: thinking,
                    searchQuery: searchQuery,
                    isCurrentSearchMatch: isCurrentSearchMatch,
                    fontSize: fontSize
                )
            }
        case "tool_use":
            ConversationToolCard(
                block: block,
                result: result,
                searchQuery: searchQuery,
                isCurrentSearchMatch: isCurrentSearchMatch,
                fontSize: fontSize
            )
        case "tool_result":
            ConversationStandaloneToolResult(
                block: block,
                searchQuery: searchQuery,
                isCurrentSearchMatch: isCurrentSearchMatch,
                fontSize: fontSize
            )
        case "skill_load":
            ConversationSkillCard(block: block, fontSize: fontSize)
        case "image":
            ConversationRawBlock(
                title: "图片",
                value: block.raw?.conversationPrettyJSON ?? "",
                fontSize: fontSize,
                localizesTitle: true
            )
        default:
            ConversationRawBlock(
                title: block.type.isEmpty ? "未知内容" : block.type,
                value: block.raw?.conversationPrettyJSON ?? block.text ?? block.thinking ?? "",
                fontSize: fontSize,
                localizesTitle: block.type.isEmpty
            )
        }
    }
}

private struct ConversationThinkingView: View {
    let thinking: String
    let searchQuery: String
    let isCurrentSearchMatch: Bool
    let fontSize: CGFloat
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ConversationHighlightedText(
                value: thinking,
                query: searchQuery,
                current: isCurrentSearchMatch,
                fontSize: max(10.5, fontSize * 0.88),
                color: Theme.mutedForeground
            )
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: max(10, fontSize * 0.82)))
                Text("思考")
                Text("· \(thinking.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")")
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
            }
            .font(.system(size: max(10, fontSize * 0.84), weight: .medium))
            .foregroundStyle(Theme.warning)
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 10)
        .background(Theme.warning.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.warning.opacity(0.15)))
        .accessibilityIdentifier("conversation.thinking")
    }
}

struct ConversationToolPresentation: Equatable, Sendable {
    enum Category: Equatable, Sendable {
        case execution
        case read
        case write
        case search
        case task
        case network
        case todo
        case mcp
        case other
    }

    enum Body: Equatable, Sendable {
        case none
        case code(String)
        case diff(old: String, new: String)
        case note(String)
        case todos([Todo])
    }

    struct Todo: Equatable, Sendable {
        var text: String
        var status: String
    }

    /// An SF Symbol name. Emoji used to stand in here, which broke the rule that interface
    /// icons are monoline symbols and made every tool row a different weight and colour.
    var symbol: String
    var label: String
    var target: String
    var body: Body
    var category: Category

    static func make(name rawName: String?, input: HistoryValue?) -> Self {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "tool"
        let object = input?.objectValue ?? [:]

        switch name {
        case "Bash":
            return .init(
                symbol: "terminal",
                label: "Bash",
                target: string("description", in: object),
                body: codeBody(string("command", in: object)),
                category: .execution
            )
        case "Script":
            return .init(
                symbol: "scroll",
                label: "Script",
                target: "",
                body: codeBody(string("code", in: object)),
                category: .execution
            )
        case "Read":
            return .init(
                symbol: "doc.text",
                label: "Read",
                target: shortPath(string("file_path", in: object)),
                body: .none,
                category: .read
            )
        case "Edit":
            return .init(
                symbol: "pencil.line",
                label: "Edit",
                target: shortPath(string("file_path", in: object)),
                body: .diff(
                    old: string("old_string", in: object),
                    new: string("new_string", in: object)
                ),
                category: .write
            )
        case "Write":
            return .init(
                symbol: "square.and.pencil",
                label: "Write",
                target: shortPath(string("file_path", in: object)),
                body: codeBody(string("content", in: object)),
                category: .write
            )
        case "ApplyPatch":
            let patch = string("patch", in: object)
            return .init(
                symbol: "pencil.line",
                label: "ApplyPatch",
                target: patchTarget(patch),
                body: codeBody(patch),
                category: .write
            )
        case "Grep":
            let path = string("path", in: object)
            return .init(
                symbol: "magnifyingglass",
                label: "Grep",
                target: string("pattern", in: object),
                body: path.isEmpty ? .none : .note("in \(path)"),
                category: .search
            )
        case "Glob":
            return .init(
                symbol: "magnifyingglass",
                label: "Glob",
                target: string("pattern", in: object),
                body: .none,
                category: .search
            )
        case "TodoWrite":
            let todos = object["todos"]?.arrayValue?.map { item in
                Todo(
                    text: item["content"]?.stringValue ?? item["activeForm"]?.stringValue ?? "",
                    status: item["status"]?.stringValue ?? "pending"
                )
            } ?? []
            return .init(
                symbol: "checklist",
                label: "Todos",
                target: "",
                body: todos.isEmpty ? .none : .todos(todos),
                category: .todo
            )
        case "Task":
            let agent = string("subagent_type", in: object)
            let description = string("description", in: object)
            let prompt = string("prompt", in: object)
            let body = [description, prompt].filter { !$0.isEmpty }.joined(separator: "\n")
            return .init(
                symbol: "cpu",
                label: "Task",
                target: agent.isEmpty ? "→ agent" : "→ \(agent)",
                body: codeBody(body),
                category: .task
            )
        case "WebSearch":
            return .init(
                symbol: "globe",
                label: "WebSearch",
                target: string("query", in: object),
                body: .none,
                category: .network
            )
        case "WebFetch":
            return .init(
                symbol: "globe",
                label: "WebFetch",
                target: string("url", in: object),
                body: .none,
                category: .network
            )
        case _ where name.hasPrefix("mcp__"):
            return .init(
                symbol: "puzzlepiece.extension",
                label: "MCP · \(String(name.dropFirst(5)))",
                target: "",
                body: object.isEmpty ? .none : .code(input?.conversationPrettyJSON ?? ""),
                category: .mcp
            )
        default:
            return .init(
                symbol: "wrench.adjustable",
                label: name,
                target: "",
                body: object.isEmpty ? .none : .code(input?.conversationPrettyJSON ?? ""),
                category: .other
            )
        }
    }

    static func resultSummary(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let bytes = value.utf8.count
        if bytes < 1_024 { return "\(bytes) B" }
        return String(format: "%.1f KB", Double(bytes) / 1_024)
    }

    private static func string(_ key: String, in object: [String: HistoryValue]) -> String {
        object[key]?.stringValue ?? ""
    }

    private static func codeBody(_ value: String) -> Body {
        value.isEmpty ? .none : .code(String(value.prefix(12_000)))
    }

    private static func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 3 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private static func patchTarget(_ patch: String) -> String {
        let files = patch.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "]
                where value.hasPrefix(prefix) {
                return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        if files.count == 1 { return shortPath(files[0]) }
        return files.isEmpty ? "" : "\(files.count) files"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct ConversationToolCard: View {
    let block: HistoryContentBlock
    let result: HistoryContentBlock?
    let searchQuery: String
    let isCurrentSearchMatch: Bool
    let fontSize: CGFloat

    private var presentation: ConversationToolPresentation {
        .make(name: block.name, input: block.input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: max(10, fontSize * 0.82)))
                    .frame(width: max(13, fontSize))
                    .font(.system(size: max(10, fontSize * 0.84), weight: .semibold))
                    .frame(minWidth: 12)
                Text(presentation.label)
                    .font(.system(size: max(10, fontSize * 0.84), weight: .semibold, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                if !presentation.target.isEmpty {
                    Text(presentation.target)
                        .font(.system(size: max(9.5, fontSize * 0.80), design: .monospaced))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 29)
            .background(Theme.foreground.opacity(0.045))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            toolInput

            if let result {
                ConversationToolResultDisclosure(
                    result: result,
                    searchQuery: searchQuery,
                    isCurrentSearchMatch: isCurrentSearchMatch,
                    fontSize: fontSize
                )
            } else {
                Text("暂无工具结果")
                    .font(.system(size: max(9.5, fontSize * 0.8)))
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(toolAccent).frame(width: 3)
        }
        .accessibilityIdentifier("conversation.tool.\(block.name ?? "unknown")")
    }

    @ViewBuilder private var toolInput: some View {
        switch presentation.body {
        case .none:
            EmptyView()
        case .code(let value):
            ConversationCodeBlock(value: value, fontSize: fontSize)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        case .diff(let old, let new):
            ConversationDiffBlock(old: old, new: new, fontSize: fontSize)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        case .note(let value):
            Text(value)
                .font(.system(size: max(10, fontSize * 0.84)))
                .foregroundStyle(Theme.mutedForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        case .todos(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.status == "completed" ? "☑" : item.status == "in_progress" ? "◐" : "☐")
                        Text(item.text)
                            .strikethrough(item.status == "completed")
                    }
                    .foregroundStyle(item.status == "in_progress" ? Theme.accentText : Theme.mutedForeground)
                }
            }
            .font(.system(size: max(10.5, fontSize * 0.88)))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var toolAccent: Color {
        switch presentation.category {
        case .execution: return .orange
        case .read: return .blue
        case .write: return Theme.success
        case .search: return .purple
        case .task: return .pink
        case .network: return .cyan
        case .todo: return .indigo
        case .mcp: return .teal
        case .other: return Theme.separator
        }
    }
}

private struct ConversationToolResultDisclosure: View {
    @Environment(\.appLanguage) private var appLanguage

    let result: HistoryContentBlock
    let searchQuery: String
    let isCurrentSearchMatch: Bool
    let fontSize: CGFloat
    @State private var expanded: Bool

    init(
        result: HistoryContentBlock,
        searchQuery: String,
        isCurrentSearchMatch: Bool,
        fontSize: CGFloat
    ) {
        self.result = result
        self.searchQuery = searchQuery
        self.isCurrentSearchMatch = isCurrentSearchMatch
        self.fontSize = fontSize
        _expanded = State(initialValue: result.isError == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(result.isError == true ? "✗" : "✓")
                    Text(appLanguage.localized(result.isError == true ? "工具失败" : "结果"))
                    Spacer(minLength: 0)
                    if !resultSummary.isEmpty {
                        Text(resultSummary)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.foreground.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                .font(.system(size: max(9.5, fontSize * 0.8), weight: .semibold))
                .foregroundStyle(result.isError == true ? Theme.danger : Theme.success)
                .padding(.horizontal, 10)
                .frame(minHeight: 27)
                .contentShape(Rectangle())
            }
            .buttonStyle(ConversationPressableButtonStyle())
            .accessibilityValue(expanded ? "已展开" : "已折叠")

            if expanded, let value = resultText, !value.isEmpty {
                ConversationCodeBlock(value: value, fontSize: fontSize)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private var resultText: String? {
        ConversationVisibleText.toolResultText(result.content)
    }

    private var resultSummary: String {
        ConversationToolPresentation.resultSummary(resultText)
    }
}

private struct ConversationStandaloneToolResult: View {
    @Environment(\.appLanguage) private var appLanguage

    let block: HistoryContentBlock
    let searchQuery: String
    let isCurrentSearchMatch: Bool
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                appLanguage.localized(
                    block.isError == true ? "未配对的工具失败" : "未配对的工具结果"
                ),
                systemImage: "wrench.and.screwdriver"
            )
                .font(.system(size: max(9.5, fontSize * 0.8), weight: .semibold))
                .foregroundStyle(block.isError == true ? Theme.danger : Theme.success)
            if let value = ConversationVisibleText.toolResultText(block.content) {
                ConversationPlainHighlightedText(value: value, query: searchQuery, current: isCurrentSearchMatch)
                    .font(.system(size: max(10, fontSize * 0.84), design: .monospaced))
            }
        }
        .padding(10)
        .background(Theme.foreground.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator))
    }
}

private struct ConversationSkillCard: View {
    let block: HistoryContentBlock
    let fontSize: CGFloat
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                if let path = block.raw?["path"]?.stringValue, !path.isEmpty {
                    Text(path)
                        .font(.system(size: max(9.5, fontSize * 0.78), design: .monospaced))
                        .foregroundStyle(Theme.mutedForeground)
                }
                if let snapshot = block.raw?["snapshot"]?.stringValue, !snapshot.isEmpty {
                    ConversationCodeBlock(value: snapshot, fontSize: fontSize)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        } label: {
            Label(block.name ?? "Skill", systemImage: "diamond")
                .font(.system(size: max(10, fontSize * 0.82), weight: .semibold, design: .monospaced))
                .padding(.vertical, 7)
        }
        .padding(.horizontal, 10)
        .background(Theme.foreground.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator))
    }
}

private struct ConversationRawBlock: View {
    @Environment(\.appLanguage) private var appLanguage

    let title: String
    let value: String
    let fontSize: CGFloat
    var localizesTitle = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if !value.isEmpty { ConversationCodeBlock(value: value, fontSize: fontSize).padding(.bottom, 8) }
        } label: {
            Text(localizesTitle ? appLanguage.localized(title) : title)
                .font(.system(size: max(10, fontSize * 0.82), weight: .semibold, design: .monospaced))
                .padding(.vertical, 6)
        }
        .padding(.horizontal, 10)
        .background(Theme.foreground.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator))
    }
}

private struct ConversationCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                Text(lineNumbers)
                    .foregroundStyle(Theme.mutedForeground.opacity(0.78))
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1)
                Text(value)
                    .foregroundStyle(codeForeground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
            }
            .font(.system(size: max(10, fontSize * 0.84), design: .monospaced))
            .lineSpacing(max(1, fontSize * 0.16))
            .padding(.vertical, 9)
            .fixedSize(horizontal: true, vertical: true)
        }
        .background(codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator))
    }

    private var lineNumbers: String {
        let count = max(1, value.components(separatedBy: "\n").count)
        return (1...count).map(String.init).joined(separator: "\n")
    }

    private var codeBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.047, green: 0.055, blue: 0.071)
            : Color(red: 0.965, green: 0.973, blue: 0.98)
    }

    private var codeForeground: Color {
        colorScheme == .dark
            ? Color(red: 0.91, green: 0.93, blue: 0.96)
            : Color(red: 0.14, green: 0.16, blue: 0.18)
    }
}

private struct ConversationDiffBlock: View {
    let old: String
    let new: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(old.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                diffLine("- \(line)", foreground: Theme.danger, background: Theme.dangerSoft)
            }
            ForEach(Array(new.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                diffLine("+ \(line)", foreground: Theme.success, background: Theme.successSoft)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.separator))
    }

    private func diffLine(_ value: String, foreground: Color, background: Color) -> some View {
        Text(value)
            .font(.system(size: max(10, fontSize * 0.81), design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
