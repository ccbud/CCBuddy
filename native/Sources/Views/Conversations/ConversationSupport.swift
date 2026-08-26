import Foundation
import SwiftUI

enum ConversationPresentation {
    static func sourceName(rawValue: String) -> String {
        switch rawValue {
        case "disk": return "Claude Code"
        case "codex": return "Codex"
        case "qoder": return "Qoder"
        case "grok": return "Grok"
        case "copilot": return "Copilot"
        case "antigravity": return "Antigravity"
        default: return rawValue.isEmpty ? "未知来源" : rawValue
        }
    }

    /// Sessions whose producer never recorded a working directory group together. The list still
    /// has to name that group; an empty row with only a folder icon and a count is unreadable.
    static func projectName(_ raw: String, language: AppLanguage? = nil) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty else { return value }
        return language?.localized("未归类") ?? "未归类"
    }

    static func sourceShortName(rawValue: String) -> String {
        rawValue == "disk" ? "Claude" : sourceName(rawValue: rawValue)
    }

    static func relativeDate(_ date: Date, language: AppLanguage? = nil) -> String {
        date.formatted(Date.RelativeFormatStyle(
            presentation: .numeric,
            unitsStyle: .abbreviated,
            locale: language?.locale ?? .current
        ))
    }

    static func absoluteDate(_ date: Date, language: AppLanguage? = nil) -> String {
        dateFormatter(dateStyle: .medium, timeStyle: .medium, language: language).string(from: date)
    }

    static func time(_ date: Date, language: AppLanguage? = nil) -> String {
        dateFormatter(dateStyle: .none, timeStyle: .short, language: language).string(from: date)
    }

    static func tokenCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }

    static func byteCount(_ value: UInt64, language: AppLanguage? = nil) -> String {
        Int64(clamping: value).formatted(
            .byteCount(style: .file).locale(language?.locale ?? .current)
        )
    }

    static func credits(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }

    static func messageAnchor(_ index: Int) -> String { "conversation.message.\(index)" }
    static let bottomAnchor = "conversation.timeline.bottom"

    private static func dateFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        language: AppLanguage?
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language?.locale ?? .current
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}

extension HistorySessionMetadata {
    /// Session IDs are producer-owned and can repeat across configured history roots. The
    /// normalized file path is the same identity the store uses for selection and search hits, so
    /// it remains stable across catalog refreshes without collapsing rows from different roots.
    var conversationListIdentity: String {
        ConversationFilter.fileKey(file)
    }

    /// Keep the public automation hook based on the producer's session ID for compatibility.
    var conversationRowAccessibilityIdentifier: String {
        "conversation.session.\(id)"
    }
}

struct ConversationIndexAccessibilityAnnouncement: Equatable {
    let message: String
    let isFailure: Bool
}

enum ConversationIndexAccessibility {
    /// Announces phase changes only. Individual progress events remain available as the status
    /// element's value, but do not repeatedly interrupt VoiceOver speech.
    static func announcement(
        from previous: ConversationIndexingState,
        to current: ConversationIndexingState,
        language: AppLanguage
    ) -> ConversationIndexAccessibilityAnnouncement? {
        switch current {
        case .scanning:
            guard !previous.isScanning else { return nil }
            return .init(
                message: language.localized("正在更新会话索引"),
                isFailure: false
            )

        case .failed(let message):
            guard previous != current else { return nil }
            return .init(message: language.localized(message), isFailure: true)

        case .incomplete(let message):
            // The catalog is usable, so this is spoken at ordinary priority rather than as a
            // failure that interrupts whatever VoiceOver is currently reading.
            guard previous != current else { return nil }
            return .init(message: language.localized(message), isFailure: false)

        case .idle:
            guard previous.isScanning else { return nil }
            return .init(
                message: language.localized("会话索引已更新"),
                isFailure: false
            )
        }
    }
}

extension HistoryValue {
    var conversationPrettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let value = String(data: data, encoding: .utf8) else { return jsonString }
        return value
    }
}

struct ConversationPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ConversationToolButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.mutedForeground)
            .frame(minWidth: 26, minHeight: 26)
            .background(configuration.isPressed ? Theme.accentSoft : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(configuration.isPressed ? Theme.accent.opacity(0.45) : Theme.separator)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

enum ConversationMarkdownAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

indirect enum ConversationMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, start: Int, items: [String])
    case blockquote([ConversationMarkdownBlock])
    case code(language: String?, value: String)
    case table(
        header: [String],
        alignments: [ConversationMarkdownAlignment],
        rows: [[String]]
    )
    case thematicBreak
}

enum ConversationMarkdownParser {
    static func parse(_ source: String) -> [ConversationMarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ConversationMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fence(in: lines[index]) {
                index += 1
                var body: [String] = []
                while index < lines.count, !closesFence(lines[index], fence: fence) {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: fence.language.isEmpty ? nil : fence.language,
                    value: body.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(in: lines[index]) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if quotedLine(lines[index]) != nil {
                var quoted: [String] = []
                while index < lines.count, let line = quotedLine(lines[index]) {
                    quoted.append(line)
                    index += 1
                }
                blocks.append(.blockquote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            if index + 1 < lines.count,
               let alignments = tableDelimiter(lines[index + 1]) {
                let header = tableCells(lines[index])
                if header.count == alignments.count, !header.isEmpty {
                    index += 2
                    var rows: [[String]] = []
                    while index < lines.count,
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                          lines[index].contains("|") {
                        var cells = tableCells(lines[index])
                        if cells.count < header.count {
                            cells.append(contentsOf: repeatElement("", count: header.count - cells.count))
                        } else if cells.count > header.count {
                            cells = Array(cells.prefix(header.count))
                        }
                        rows.append(cells)
                        index += 1
                    }
                    blocks.append(.table(header: header, alignments: alignments, rows: rows))
                    continue
                }
            }

            if let firstItem = listItem(lines[index]) {
                var items: [String] = []
                let ordered = firstItem.ordered
                let start = firstItem.start
                while index < lines.count, let item = listItem(lines[index]), item.ordered == ordered {
                    var value = item.text
                    index += 1
                    while index < lines.count,
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                          listItem(lines[index]) == nil,
                          !startsBlock(lines[index]) {
                        value += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                    }
                    items.append(value)
                }
                blocks.append(.list(ordered: ordered, start: start, items: items))
                continue
            }

            if isThematicBreak(lines[index]) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            var paragraph = [lines[index]]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines[index]) {
                if index + 1 < lines.count, tableDelimiter(lines[index + 1]) != nil { break }
                paragraph.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    private struct Fence {
        var marker: Character
        var length: Int
        var language: String
    }

    private struct ListItem {
        var ordered: Bool
        var start: Int
        var text: String
    }

    private static func contentAfterIndent(_ line: String) -> Substring {
        var value = line[...]
        var removed = 0
        while removed < 3, value.first == " " {
            value = value.dropFirst()
            removed += 1
        }
        return value
    }

    private static func fence(in line: String) -> Fence? {
        let value = contentAfterIndent(line)
        guard let marker = value.first, marker == "`" || marker == "~" else { return nil }
        let length = value.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let suffix = value.dropFirst(length).trimmingCharacters(in: .whitespaces)
        let language = suffix.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return Fence(marker: marker, length: length, language: language)
    }

    private static func closesFence(_ line: String, fence: Fence) -> Bool {
        let value = contentAfterIndent(line)
        guard value.first == fence.marker else { return false }
        let length = value.prefix(while: { $0 == fence.marker }).count
        return length >= fence.length
            && value.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let value = contentAfterIndent(line)
        let level = value.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let suffix = value.dropFirst(level)
        guard suffix.isEmpty || suffix.first?.isWhitespace == true else { return nil }
        var text = suffix.trimmingCharacters(in: .whitespaces)
        while text.last == "#" { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func quotedLine(_ line: String) -> String? {
        let value = contentAfterIndent(line)
        guard value.first == ">" else { return nil }
        var suffix = value.dropFirst()
        if suffix.first == " " { suffix = suffix.dropFirst() }
        return String(suffix)
    }

    private static func listItem(_ line: String) -> ListItem? {
        let value = contentAfterIndent(line)
        guard let separator = value.firstIndex(where: \.isWhitespace) else { return nil }
        let marker = String(value[..<separator])
        let text = value[separator...].trimmingCharacters(in: .whitespaces)
        if ["-", "+", "*"].contains(marker) {
            return ListItem(ordered: false, start: 1, text: text)
        }
        guard let final = marker.last, final == "." || final == ")",
              let start = Int(marker.dropLast()), start > 0 else { return nil }
        return ListItem(ordered: true, start: start, text: text)
    }

    private static func tableDelimiter(_ line: String) -> [ConversationMarkdownAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var result: [ConversationMarkdownAlignment] = []
        for rawCell in cells {
            let cell = rawCell.trimmingCharacters(in: .whitespaces)
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return result
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = contentAfterIndent(line).filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, ["-", "_", "*"].contains(marker) else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func startsBlock(_ line: String) -> Bool {
        fence(in: line) != nil
            || heading(in: line) != nil
            || quotedLine(line) != nil
            || listItem(line) != nil
            || isThematicBreak(line)
    }
}

/// Full block-Markdown conversation prose. Raw HTML is never interpreted: parsing produces only
/// native SwiftUI primitives, and inline markup is handled by Foundation's bounded inline parser.
struct ConversationHighlightedText: View {
    let value: String
    var query: String = ""
    var current = false
    var fontSize: CGFloat = 13
    var color: Color = Theme.foreground

    var body: some View {
        ConversationMarkdownBlocksView(
            blocks: ConversationMarkdownParser.parse(value),
            query: query,
            current: current,
            fontSize: fontSize,
            color: color
        )
        .textSelection(.enabled)
    }
}

struct ConversationPlainHighlightedText: View {
    let value: String
    var query: String = ""
    var current = false

    var body: some View {
        ConversationInlineMarkup.text(
            value,
            query: query,
            current: current,
            parsesMarkdown: false
        )
        .textSelection(.enabled)
    }
}

private struct ConversationMarkdownBlocksView: View {
    let blocks: [ConversationMarkdownBlock]
    let query: String
    let current: Bool
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: max(6, fontSize * 0.55)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func blockView(_ block: ConversationMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            inlineText(value)
                .font(.system(size: fontSize))
                .foregroundStyle(color)
                .lineSpacing(max(1, fontSize * 0.18))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let value):
            inlineText(value)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .tracking(level <= 2 ? -0.18 : -0.08)
                .foregroundStyle(color)
                .padding(.top, level <= 2 ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: max(3, fontSize * 0.24)) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(listMarker(item: item, ordered: ordered, number: start + offset))
                            .font(.system(size: fontSize, weight: .medium, design: ordered ? .monospaced : .default))
                            .foregroundStyle(Theme.mutedForeground)
                            .frame(width: ordered ? 24 : 15, alignment: .trailing)
                        inlineText(listText(item))
                            .font(.system(size: fontSize))
                            .foregroundStyle(color)
                            .lineSpacing(max(1, fontSize * 0.14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .blockquote(let quotedBlocks):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.separator)
                    .frame(width: 3)
                ConversationMarkdownBlocksView(
                    blocks: quotedBlocks,
                    query: query,
                    current: current,
                    fontSize: max(10.5, fontSize * 0.94),
                    color: Theme.mutedForeground
                )
            }
            .padding(.vertical, 2)

        case .code(let language, let value):
            ConversationMarkdownCodeBlock(value: value, language: language, fontSize: fontSize)

        case .table(let header, let alignments, let rows):
            ConversationMarkdownTable(
                header: header,
                alignments: alignments,
                rows: rows,
                query: query,
                current: current,
                fontSize: fontSize
            )

        case .thematicBreak:
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ value: String) -> Text {
        ConversationInlineMarkup.text(value, query: query, current: current, parsesMarkdown: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        let factors: [CGFloat] = [1.55, 1.35, 1.20, 1.10, 1.03, 1]
        return fontSize * factors[min(max(level - 1, 0), factors.count - 1)]
    }

    private func listMarker(item: String, ordered: Bool, number: Int) -> String {
        if ordered { return "\(number)." }
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[x]") || trimmed.hasPrefix("[X]") { return "☑" }
        if trimmed.hasPrefix("[ ]") { return "☐" }
        return "•"
    }

    private func listText(_ item: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[x]") || trimmed.hasPrefix("[X]") || trimmed.hasPrefix("[ ]") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return item
    }
}

private enum ConversationInlineMarkup {
    static func text(
        _ source: String,
        query: String,
        current: Bool,
        parsesMarkdown: Bool
    ) -> Text {
        let rendered: String
        let attributed: AttributedString?
        if parsesMarkdown {
            // Escaping '<' preserves literal transcript text and prevents Markdown's raw-HTML
            // grammar from swallowing or reinterpreting user/model output.
            let safeSource = source.replacingOccurrences(of: "<", with: "\\<")
            attributed = try? AttributedString(
                markdown: safeSource,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            rendered = attributed.map { String($0.characters) } ?? source
        } else {
            attributed = nil
            rendered = source
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            if let attributed { return Text(attributed) }
            return Text(rendered)
        }

        var output = Text("")
        var cursor = rendered.startIndex
        while cursor < rendered.endIndex,
              let range = rendered.range(
                  of: needle,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<rendered.endIndex,
                  locale: .current
              ) {
            output = output + Text(String(rendered[cursor..<range.lowerBound]))
            output = output + Text(String(rendered[range]))
                .bold()
                .foregroundColor(current ? Theme.accentText : Theme.accent)
            cursor = range.upperBound
        }
        return output + Text(String(rendered[cursor...]))
    }
}

private struct ConversationMarkdownCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String
    let language: String?
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: max(10, fontSize * 0.88), design: .monospaced))
            .lineSpacing(max(1, fontSize * 0.18))
            .padding(.vertical, 9)
            .fixedSize(horizontal: true, vertical: true)
        }
        .background(codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator))
        .overlay(alignment: .topTrailing) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(codeBackground.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(5)
            }
        }
    }

    private var lineNumbers: String {
        let count = max(1, value.components(separatedBy: "\n").count)
        return (1...count).map(String.init).joined(separator: "\n")
    }

    private var codeBackground: Color {
        colorScheme == .dark ? Color(red: 0.047, green: 0.055, blue: 0.071) : Color(red: 0.965, green: 0.973, blue: 0.98)
    }

    private var codeForeground: Color {
        colorScheme == .dark ? Color(red: 0.91, green: 0.93, blue: 0.96) : Color(red: 0.14, green: 0.16, blue: 0.18)
    }
}

private struct ConversationMarkdownTable: View {
    let header: [String]
    let alignments: [ConversationMarkdownAlignment]
    let rows: [[String]]
    let query: String
    let current: Bool
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.separator))
    }

    private func tableRow(_ values: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(header.indices), id: \.self) { column in
                ConversationInlineMarkup.text(
                    values.indices.contains(column) ? values[column] : "",
                    query: query,
                    current: current,
                    parsesMarkdown: true
                )
                .font(.system(size: max(10.5, fontSize * 0.96), weight: isHeader ? .semibold : .regular))
                .foregroundStyle(Theme.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(
                    minWidth: 76,
                    maxWidth: 240,
                    alignment: swiftUIAlignment(alignments[column])
                )
                .background(isHeader ? Theme.foreground.opacity(0.05) : Color.clear)
                .overlay(Rectangle().stroke(Theme.separator, lineWidth: 0.5))
            }
        }
    }

    private func swiftUIAlignment(_ alignment: ConversationMarkdownAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

struct ConversationRailMaterial: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Theme.list)
    }
}

extension View {
    func conversationRailMaterial() -> some View {
        modifier(ConversationRailMaterial())
    }
}
