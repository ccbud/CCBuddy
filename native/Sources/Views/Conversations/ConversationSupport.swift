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

    /// Reused rather than rebuilt. Building a `DateFormatter` is expensive enough that one per row
    /// — the session stream asks for a tooltip date on every row it draws — shows up as stutter
    /// while scrolling.
    private static func dateFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        language: AppLanguage?
    ) -> DateFormatter {
        let locale = language?.locale ?? .current
        let key = "\(dateStyle.rawValue)-\(timeStyle.rawValue)-\(locale.identifier)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = formatterCache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatterCache[key] = formatter
        return formatter
    }

    private static let formatterLock = NSLock()
    private nonisolated(unsafe) static var formatterCache: [String: DateFormatter] = [:]
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
            .animation(reduceMotion ? nil : CCMotion.response, value: configuration.isPressed)
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
        (try? parseCancellable(source)) ?? []
    }

    static func parseCancellable(_ source: String) throws -> [ConversationMarkdownBlock] {
        try Task.checkCancellation()
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ConversationMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            try Task.checkCancellation()
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fence(in: lines[index]) {
                index += 1
                var body: [String] = []
                while index < lines.count, !closesFence(lines[index], fence: fence) {
                    try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    quoted.append(line)
                    index += 1
                }
                blocks.append(.blockquote(try parseCancellable(quoted.joined(separator: "\n"))))
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
                        try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    var value = item.text
                    index += 1
                    while index < lines.count,
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                          listItem(lines[index]) == nil,
                          !startsBlock(lines[index]) {
                        try Task.checkCancellation()
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
                try Task.checkCancellation()
                if index + 1 < lines.count, tableDelimiter(lines[index + 1]) != nil { break }
                paragraph.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        try Task.checkCancellation()
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

struct ConversationTextPreparationRequest: Equatable, Sendable {
    let source: String
    let query: String
    let current: Bool
    let parsesMarkdown: Bool

    init(source: String, query: String = "", current: Bool = false, parsesMarkdown: Bool = true) {
        self.source = source
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.current = current
        self.parsesMarkdown = parsesMarkdown
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Typing changes this cheap prefix. Never hash the entire Markdown body as a cache key.
        lhs.query == rhs.query && lhs.current == rhs.current
            && lhs.parsesMarkdown == rhs.parsesMarkdown && lhs.source == rhs.source
    }
}

struct ConversationPreparedInline: Sendable {
    let attributed: AttributedString
    let rendered: String
    var listMarker: String?

    static func make(_ source: String, parsesMarkdown: Bool, listMarker: String? = nil) throws -> Self {
        try Task.checkCancellation()
        let attributed: AttributedString
        if parsesMarkdown {
            // Literal HTML remains text, exactly as in the original inline renderer.
            let safeSource = source.replacingOccurrences(of: "<", with: "\\<")
            attributed = (try? AttributedString(markdown: safeSource,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        } else {
            attributed = AttributedString(source)
        }
        try Task.checkCancellation()
        return Self(attributed: attributed, rendered: String(attributed.characters), listMarker: listMarker)
    }

    func highlighting(query: String, current: Bool, locale: Locale = .current) throws -> AttributedString {
        guard !query.isEmpty else { return attributed }
        var result = attributed
        var cursor = rendered.startIndex
        // Bound no-hit Foundation scans as well as match loops. Keep complete graphemes and
        // enough canonical-fold overlap for a match crossing a window; no text is truncated.
        let overlap = max(1, query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .decomposedStringWithCanonicalMapping.unicodeScalars.count)
        while cursor < rendered.endIndex {
            try Task.checkCancellation()
            let chunkEnd = rendered.index(cursor, offsetBy: 16_384, limitedBy: rendered.endIndex) ?? rendered.endIndex
            let scanEnd = rendered.index(chunkEnd, offsetBy: overlap, limitedBy: rendered.endIndex) ?? rendered.endIndex
            while cursor < chunkEnd {
                try Task.checkCancellation()
                guard let range = rendered.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                    range: cursor..<scanEnd, locale: locale), range.lowerBound < chunkEnd else { break }
                guard !range.isEmpty else {
                    cursor = rendered.index(after: range.lowerBound)
                    continue
                }
                if let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    let attributedRange = lower..<upper
                    // Preserve links, emphasis and inline code even while highlighting. Applying
                    // bold per existing run avoids flattening differently formatted matched text.
                    let runs = result[attributedRange].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
                    for (run, intent) in runs {
                        try Task.checkCancellation()
                        result[run].inlinePresentationIntent = intent.union(.stronglyEmphasized)
                    }
                    result[attributedRange].foregroundColor = current ? Theme.accentText : Theme.accent
                }
                cursor = range.upperBound
            }
            cursor = max(cursor, chunkEnd)
        }
        try Task.checkCancellation()
        return result
    }
}

/// One source snapshot per prose view. Structural paths are tiny keys; source text is never used
/// as a hashed key, and no global cache retains conversations after their views are released.
final class ConversationPreparedTextBase: Sendable {
    let source: String
    let parsesMarkdown: Bool
    let blocks: [ConversationMarkdownBlock]
    let inlines: [[Int]: ConversationPreparedInline]
    let codeLineNumbers: [[Int]: String]

    private init(source: String, parsesMarkdown: Bool, blocks: [ConversationMarkdownBlock],
                 inlines: [[Int]: ConversationPreparedInline], codeLineNumbers: [[Int]: String] = [:]) {
        self.source = source
        self.parsesMarkdown = parsesMarkdown
        self.blocks = blocks
        self.inlines = inlines
        self.codeLineNumbers = codeLineNumbers
    }

    static func make(source: String, parsesMarkdown: Bool) throws -> ConversationPreparedTextBase {
        try Task.checkCancellation()
        guard parsesMarkdown else {
            return ConversationPreparedTextBase(source: source, parsesMarkdown: false, blocks: [],
                inlines: [[]: try .make(source, parsesMarkdown: false)])
        }
        let blocks = try ConversationMarkdownParser.parseCancellable(source)
        var inlines: [[Int]: ConversationPreparedInline] = [:]
        var codeLineNumbers: [[Int]: String] = [:]
        func visit(_ blocks: [ConversationMarkdownBlock], prefix: [Int]) throws {
            for index in blocks.indices {
                try Task.checkCancellation()
                let path = prefix + [index]
                switch blocks[index] {
                case .paragraph(let text), .heading(_, let text):
                    inlines[path] = try .make(text, parsesMarkdown: true)
                case .list(let ordered, let start, let items):
                    for offset in items.indices {
                        let trimmed = items[offset].trimmingCharacters(in: .whitespaces)
                        let checked = trimmed.hasPrefix("[x]") || trimmed.hasPrefix("[X]")
                        let task = checked || trimmed.hasPrefix("[ ]")
                        let text = task ? String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces) : items[offset]
                        let marker = ordered ? "\(start + offset)." : task ? (checked ? "☑" : "☐") : "•"
                        inlines[path + [offset]] = try .make(text, parsesMarkdown: true, listMarker: marker)
                    }
                case .blockquote(let children):
                    try visit(children, prefix: path)
                case .table(let header, _, let rows):
                    for column in header.indices {
                        inlines[path + [-1, column]] = try .make(header[column], parsesMarkdown: true)
                    }
                    for row in rows.indices {
                        for column in header.indices {
                            inlines[path + [row, column]] = try .make(
                                rows[row].indices.contains(column) ? rows[row][column] : "", parsesMarkdown: true)
                        }
                    }
                case .code(_, let value):
                    let count = value.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
                    codeLineNumbers[path] = (1...count).map(String.init).joined(separator: "\n")
                case .thematicBreak: break
                }
            }
        }
        try visit(blocks, prefix: [])
        try Task.checkCancellation()
        return ConversationPreparedTextBase(source: source, parsesMarkdown: true, blocks: blocks,
                                            inlines: inlines, codeLineNumbers: codeLineNumbers)
    }
}

struct ConversationPreparedTextSnapshot: Sendable {
    let base: ConversationPreparedTextBase
    let query: String
    let current: Bool
    let highlighted: [[Int]: AttributedString]

    func inline(at path: [Int], query: String, current: Bool) -> AttributedString {
        // A cleared or newer query displays the already prepared base immediately, never stale
        // highlights. Source replacement is separately guarded before any snapshot is displayed.
        if !query.isEmpty, self.query == query, self.current == current, let value = highlighted[path] {
            return value
        }
        return base.inlines[path]?.attributed ?? AttributedString("")
    }
}

actor ConversationTextPreparationWorker {
    typealias PrepareBase = @Sendable (String, Bool) throws -> ConversationPreparedTextBase
    private let prepareBase: PrepareBase
    private var base: ConversationPreparedTextBase?
    private var baseLifetime: UUID?
    private let defaultLifetime = UUID()

    init(prepareBase: @escaping PrepareBase = { try ConversationPreparedTextBase.make(source: $0, parsesMarkdown: $1) }) {
        self.prepareBase = prepareBase
    }

    func prepare(_ request: ConversationTextPreparationRequest,
                 lifetime: UUID? = nil) throws -> ConversationPreparedTextSnapshot {
        // Actor isolation bounds each view to one active CPU preparation. Canceled queued
        // keystrokes exit before parsing; they cannot fan out into concurrent giant-body scans.
        try Task.checkCancellation()
        let prepared: ConversationPreparedTextBase
        let canReuseBase = base?.parsesMarkdown == request.parsesMarkdown && base?.source == request.source
        if canReuseBase, let base {
            prepared = base
        } else {
            base = nil
            baseLifetime = nil
            prepared = try prepareBase(request.source, request.parsesMarkdown)
            try Task.checkCancellation()
            base = prepared
        }
        baseLifetime = lifetime ?? defaultLifetime
        var highlighted: [[Int]: AttributedString] = [:]
        if !request.query.isEmpty {
            for (path, inline) in prepared.inlines {
                try Task.checkCancellation()
                highlighted[path] = try inline.highlighting(query: request.query, current: request.current)
            }
        }
        try Task.checkCancellation()
        return ConversationPreparedTextSnapshot(base: prepared, query: request.query,
                                                 current: request.current, highlighted: highlighted)
    }

    func release(lifetime: UUID) {
        // Actor jobs can be reordered. A release queued by disappearance must not erase a
        // base that has already been adopted by the view's newer appearance, even same-source.
        guard baseLifetime == lifetime else { return }
        base = nil
        baseLifetime = nil
    }
}

@MainActor
final class ConversationTextPreparation: ObservableObject {
    @Published private(set) var snapshot: ConversationPreparedTextSnapshot?
    private let worker: ConversationTextPreparationWorker
    private var activeTask: Task<ConversationPreparedTextSnapshot, Error>?
    private var generation = UUID()
    private var lifetime = UUID()

    init(worker: ConversationTextPreparationWorker = ConversationTextPreparationWorker()) {
        self.worker = worker
    }

    func prepare(_ request: ConversationTextPreparationRequest) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        self.generation = generation
        activeTask?.cancel()
        if let snapshot, snapshot.base.parsesMarkdown != request.parsesMarkdown
            || snapshot.base.source != request.source {
            // This source is no longer displayed. Do not retain its attributed text/highlights
            // while a different giant source is being prepared or after that work is canceled.
            self.snapshot = nil
        }
        let worker = worker
        let requestLifetime = lifetime
        let task = Task.detached(priority: .userInitiated) {
            try await worker.prepare(request, lifetime: requestLifetime)
        }
        activeTask = task
        defer {
            if self.generation == generation { activeTask = nil }
        }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, self.generation == generation else { return }
            self.snapshot = snapshot
        } catch {
            // Cancellation preserves the same-source base while its newest query is prepared.
        }
    }

    @discardableResult
    func release() -> Task<Void, Never> {
        generation = UUID()
        let releasedLifetime = lifetime
        lifetime = UUID()
        activeTask?.cancel()
        activeTask = nil
        snapshot = nil
        // Keep one worker even while an uncancellable Foundation operation is returning. A
        // reappearing row must queue behind it, not launch another concurrent giant-body parse.
        // Drop the heavy cache on that actor; the retained StateObject itself stays lightweight.
        let worker = worker
        return Task { await worker.release(lifetime: releasedLifetime) }
    }
}

/// Full block-Markdown conversation prose. Raw HTML is never interpreted: parsing produces only
/// native SwiftUI primitives, with Foundation inline parsing prepared off the input path.
@MainActor
struct ConversationHighlightedText: View {
    let value: String
    var query: String = ""
    var current = false
    var fontSize: CGFloat = 13
    var color: Color = Theme.foreground
    @StateObject private var preparation = ConversationTextPreparation()

    var body: some View {
        let request = ConversationTextPreparationRequest(source: value, query: query, current: current)
        Group {
            if let snapshot = preparation.snapshot, snapshot.base.source == value, snapshot.base.parsesMarkdown {
                ConversationMarkdownBlocksView(
                    blocks: snapshot.base.blocks, snapshot: snapshot,
                    query: request.query, current: current, fontSize: fontSize, color: color
                )
            } else {
                ConversationTextPreparationPlaceholder()
            }
        }
        .task(id: request) { await preparation.prepare(request) }
        .onDisappear { preparation.release() }
        .textSelection(.enabled)
    }
}

@MainActor
struct ConversationPlainHighlightedText: View {
    let value: String
    var query: String = ""
    var current = false
    @StateObject private var preparation = ConversationTextPreparation()

    var body: some View {
        let request = ConversationTextPreparationRequest(source: value, query: query,
                                                        current: current, parsesMarkdown: false)
        Group {
            if let snapshot = preparation.snapshot, snapshot.base.source == value, !snapshot.base.parsesMarkdown {
                Text(snapshot.inline(at: [], query: request.query, current: current))
            } else if value.utf8.count <= 4_096 {
                // Tiny plain snippets need no parsing and can remain immediately readable.
                Text(verbatim: value)
            } else {
                ConversationTextPreparationPlaceholder()
            }
        }
        .task(id: request) { await preparation.prepare(request) }
        .onDisappear { preparation.release() }
        .textSelection(.enabled)
    }
}

private struct ConversationTextPreparationPlaceholder: View {
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: Space.sm) {
            ConversationActivityIndicator(controlSize: .mini)
                .accessibilityHidden(true)
            Text(language.localized("正在读取会话…"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.message.preparing")
    }
}

private struct ConversationMarkdownBlocksView: View {
    let blocks: [ConversationMarkdownBlock]
    let snapshot: ConversationPreparedTextSnapshot
    var path: [Int] = []
    let query: String
    let current: Bool
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: max(6, fontSize * 0.55)) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index], at: path + [index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func blockView(_ block: ConversationMarkdownBlock, at path: [Int]) -> some View {
        switch block {
        case .paragraph:
            inlineText(at: path)
                .font(.system(size: fontSize))
                .foregroundStyle(color)
                .lineSpacing(max(1, fontSize * 0.18))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, _):
            inlineText(at: path)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .tracking(level <= 2 ? -0.18 : -0.08)
                .foregroundStyle(color)
                .padding(.top, level <= 2 ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let ordered, _, let items):
            VStack(alignment: .leading, spacing: max(3, fontSize * 0.24)) {
                ForEach(items.indices, id: \.self) { offset in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(snapshot.base.inlines[path + [offset]]?.listMarker ?? "•")
                            .font(.system(size: fontSize, weight: .medium, design: ordered ? .monospaced : .default))
                            .foregroundStyle(Theme.mutedForeground)
                            .frame(width: ordered ? 24 : 15, alignment: .trailing)
                        inlineText(at: path + [offset])
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
                    snapshot: snapshot,
                    path: path,
                    query: query,
                    current: current,
                    fontSize: max(10.5, fontSize * 0.94),
                    color: Theme.mutedForeground
                )
            }
            .padding(.vertical, 2)

        case .code(let language, let value):
            ConversationMarkdownCodeBlock(value: value, language: language, fontSize: fontSize,
                                           lineNumbers: snapshot.base.codeLineNumbers[path] ?? "1")

        case .table(let header, let alignments, let rows):
            ConversationMarkdownTable(
                header: header,
                alignments: alignments,
                rows: rows,
                snapshot: snapshot,
                path: path,
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

    private func inlineText(at path: [Int]) -> Text {
        Text(snapshot.inline(at: path, query: query, current: current))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        let factors: [CGFloat] = [1.55, 1.35, 1.20, 1.10, 1.03, 1]
        return fontSize * factors[min(max(level - 1, 0), factors.count - 1)]
    }

}

private struct ConversationMarkdownCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String
    let language: String?
    let fontSize: CGFloat
    let lineNumbers: String

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
    let snapshot: ConversationPreparedTextSnapshot
    let path: [Int]
    let query: String
    let current: Bool
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(at: -1, isHeader: true)
                ForEach(rows.indices, id: \.self) { row in
                    tableRow(at: row, isHeader: false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.separator))
    }

    private func tableRow(at row: Int, isHeader: Bool) -> some View {
        GridRow {
            ForEach(header.indices, id: \.self) { column in
                Text(snapshot.inline(at: path + [row, column], query: query, current: current))
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
