import Foundation

struct CodexConfigDocument: Equatable {
    static let providerHeader = "model_providers.ccbud"

    private(set) var lines: [String]

    init(_ source: String) {
        lines = source.components(separatedBy: "\n")
    }

    var source: String { lines.joined(separator: "\n") }

    func topLevelString(for key: String) -> String? {
        guard let index = topLevelAssignmentIndex(for: key) else { return nil }
        return Self.parseTOMLString(fromAssignment: lines[index])
    }

    func rawTopLevelAssignment(for key: String) -> String? {
        topLevelAssignmentIndex(for: key).map { lines[$0] }
    }

    mutating func setTopLevelString(_ value: String, for key: String) {
        let replacement = "\(key) = \(Self.quoted(value))"
        if let index = topLevelAssignmentIndex(for: key) {
            lines[index] = replacement
            return
        }
        let insertion = firstTableIndex ?? effectiveEndIndex
        lines.insert(replacement, at: insertion)
        if insertion < lines.count - 1,
           insertion + 1 < lines.count,
           !lines[insertion + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert("", at: insertion + 1)
        }
    }

    mutating func removeTopLevelValue(for key: String) {
        guard let index = topLevelAssignmentIndex(for: key) else { return }
        lines.remove(at: index)
    }

    mutating func restoreTopLevelValue(
        for key: String,
        rawAssignment: String?,
        fallbackValue: String?
    ) {
        if let rawAssignment {
            if let index = topLevelAssignmentIndex(for: key) {
                lines[index] = rawAssignment
            } else {
                let insertion = firstTableIndex ?? effectiveEndIndex
                lines.insert(rawAssignment, at: insertion)
            }
        } else if let fallbackValue {
            setTopLevelString(fallbackValue, for: key)
        } else {
            removeTopLevelValue(for: key)
        }
    }

    func rawProviderBlock() -> String? {
        guard let range = tableRange(named: Self.providerHeader) else { return nil }
        return lines[range].joined(separator: "\n")
    }

    func providerString(for key: String) -> String? {
        guard let range = tableRange(named: Self.providerHeader) else { return nil }
        for index in range.dropFirst() where Self.isAssignment(lines[index], key: key) {
            return Self.parseTOMLString(fromAssignment: lines[index])
        }
        return nil
    }

    mutating func setCCBuddyProvider(port: Int, token: String) {
        removeCCBuddyProvider()
        appendBlock([
            "[model_providers.ccbud]",
            "name = \(Self.quoted("CC Buddy"))",
            "base_url = \(Self.quoted("http://localhost:\(port)/openai/v1"))",
            "wire_api = \(Self.quoted("responses"))",
            "requires_openai_auth = false",
            "experimental_bearer_token = \(Self.quoted(token))",
            "supports_websockets = false",
        ])
    }

    mutating func removeCCBuddyProvider() {
        guard let range = tableRange(named: Self.providerHeader) else { return }
        lines.removeSubrange(range)
        collapseTrailingBlankLines()
        if lines != [""] { lines.append("") }
    }

    mutating func restoreProviderBlock(_ rawBlock: String?) {
        removeCCBuddyProvider()
        guard let rawBlock, !rawBlock.isEmpty else { return }
        appendBlock(rawBlock.components(separatedBy: "\n"))
    }

    private var effectiveEndIndex: Int {
        if lines.last == "" { return max(lines.count - 1, 0) }
        return lines.count
    }

    private var firstTableIndex: Int? {
        lines.firstIndex { Self.tableName(in: $0) != nil }
    }

    private func topLevelAssignmentIndex(for key: String) -> Int? {
        let limit = firstTableIndex ?? lines.count
        return lines[..<limit].firstIndex { Self.isAssignment($0, key: key) }
    }

    private func tableRange(named target: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { Self.tableName(in: $0) == target }) else {
            return nil
        }
        let end = lines.indices.dropFirst(start + 1).first(where: {
            Self.tableName(in: lines[$0]) != nil
        }) ?? lines.endIndex
        return start..<end
    }

    private mutating func appendBlock(_ block: [String]) {
        collapseTrailingBlankLines()
        if lines.count == 1, lines[0].isEmpty {
            lines.removeAll()
        } else if !lines.isEmpty {
            lines.append("")
        }
        lines.append(contentsOf: block)
        lines.append("")
    }

    private mutating func collapseTrailingBlankLines() {
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        if lines.isEmpty { lines = [""] }
    }

    private static func tableName(in line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), !text.hasPrefix("[["), let close = text.firstIndex(of: "]") else {
            return nil
        }
        let tail = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        let body = text[text.index(after: text.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"ccbud\"", with: "ccbud")
            .replacingOccurrences(of: "'ccbud'", with: "ccbud")
        return body
    }

    private static func isAssignment(_ line: String, key: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.hasPrefix("#"), text.hasPrefix(key) else { return false }
        let rest = text.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
    }

    private static func parseTOMLString(fromAssignment line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard let first = raw.first else { return nil }
        if first == "'" {
            let contentStart = raw.index(after: raw.startIndex)
            guard let end = raw[contentStart...].firstIndex(of: "'") else { return nil }
            return String(raw[contentStart..<end])
        }
        guard first == "\"" else { return nil }
        var escaped = false
        var end: String.Index?
        var cursor = raw.index(after: raw.startIndex)
        while cursor < raw.endIndex {
            let character = raw[cursor]
            if character == "\"", !escaped { end = cursor; break }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            cursor = raw.index(after: cursor)
        }
        guard let end else { return nil }
        let literal = String(raw[raw.startIndex...end])
        return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try? encoder.encode(value)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
