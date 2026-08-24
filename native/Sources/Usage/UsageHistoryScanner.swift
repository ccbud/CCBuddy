import Foundation

protocol UsageHistoryScanning: Sendable {
    func scan(configuration: UsageHistoryConfiguration) -> [String: UsageHistoryDay]
}

/// Incremental JSONL reader used by the usage scanner. It never maps an entire transcript and
/// drops a malformed/hostile line once it exceeds the configured bound, then resumes at the next
/// newline. Real usage records are small; the generous production limit preserves those records
/// while keeping unrelated tool output from determining the scanner's working set.
struct UsageHistoryLineReader: Sendable {
    static let defaultChunkBytes = 64 * 1_024
    static let defaultMaximumLineBytes = 32 * 1_024 * 1_024

    let chunkBytes: Int
    let maximumLineBytes: Int

    init(
        chunkBytes: Int = UsageHistoryLineReader.defaultChunkBytes,
        maximumLineBytes: Int = UsageHistoryLineReader.defaultMaximumLineBytes
    ) {
        self.chunkBytes = max(1, chunkBytes)
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    /// Returns false when the caller stops iteration or the current task is cancelled.
    @discardableResult
    func forEachLine(in file: URL, _ body: (String) -> Bool) -> Bool {
        guard !Task.isCancelled,
              let handle = try? FileHandle(forReadingFrom: file) else { return !Task.isCancelled }
        defer { try? handle.close() }
        do {
            return try consumeChunks(
                next: { try handle.read(upToCount: chunkBytes) },
                body
            )
        } catch {
            // A disappearing or unreadable history file has always been treated as an empty
            // source. Keep that behavior; the watcher will invalidate again on later changes.
            return !Task.isCancelled
        }
    }

    /// Qoder's permission helper necessarily returns bounded `Data`; consume it through the same
    /// capped line path so parsing semantics stay identical to ordinary files.
    @discardableResult
    func forEachLine(in data: Data, _ body: (String) -> Bool) -> Bool {
        var offset = data.startIndex
        do {
            return try consumeChunks(
                next: {
                    guard offset < data.endIndex else { return nil }
                    let end = data.index(
                        offset,
                        offsetBy: min(chunkBytes, data.distance(from: offset, to: data.endIndex))
                    )
                    defer { offset = end }
                    return Data(data[offset..<end])
                },
                body
            )
        } catch {
            return !Task.isCancelled
        }
    }

    private func consumeChunks(
        next: () throws -> Data?,
        _ body: (String) -> Bool
    ) throws -> Bool {
        var pending = Data()
        var discardingOversizedLine = false

        while !Task.isCancelled {
            let nextChunk = try autoreleasepool(invoking: next)
            guard let chunk = nextChunk, !chunk.isEmpty else {
                guard !discardingOversizedLine, !pending.isEmpty else {
                    return !Task.isCancelled
                }
                let shouldContinue = autoreleasepool {
                    body(String(decoding: pending, as: UTF8.self))
                }
                return shouldContinue && !Task.isCancelled
            }

            var start = chunk.startIndex
            while start < chunk.endIndex {
                guard !Task.isCancelled else { return false }
                let newline = chunk[start...].firstIndex(of: 0x0A)
                let end = newline ?? chunk.endIndex
                let segment = chunk[start..<end]

                if discardingOversizedLine {
                    if newline != nil { discardingOversizedLine = false }
                } else if pending.isEmpty, newline != nil,
                          segment.count <= maximumLineBytes {
                    let shouldContinue = autoreleasepool {
                        body(String(decoding: segment, as: UTF8.self))
                    }
                    guard shouldContinue else { return false }
                } else if segment.count <= maximumLineBytes,
                          pending.count <= maximumLineBytes - segment.count {
                    pending.append(contentsOf: segment)
                    if newline != nil {
                        let shouldContinue = autoreleasepool {
                            body(String(decoding: pending, as: UTF8.self))
                        }
                        guard shouldContinue else { return false }
                        let keepCapacity = pending.count <= chunkBytes * 2
                        pending.removeAll(keepingCapacity: keepCapacity)
                    }
                } else {
                    pending.removeAll(keepingCapacity: false)
                    discardingOversizedLine = newline == nil
                }

                guard let newline else { break }
                start = chunk.index(after: newline)
            }
        }
        return false
    }
}

struct UsageHistoryScanner: UsageHistoryScanning, Sendable {
    var calendar: Calendar
    var qoderReader: QoderFileReader
    var lineReader: UsageHistoryLineReader

    init(
        calendar: Calendar = .current,
        qoderReader: QoderFileReader = .shared,
        lineReader: UsageHistoryLineReader = UsageHistoryLineReader()
    ) {
        self.calendar = calendar
        self.qoderReader = qoderReader
        self.lineReader = lineReader
    }

    func scan(configuration: UsageHistoryConfiguration) -> [String: UsageHistoryDay] {
        let roots = configuration.activeRoots
        var days: [String: UsageHistoryDay] = [:]

        var claudeFiles: [URL] = []
        for root in roots {
            guard !Task.isCancelled else { return days }
            claudeFiles.append(contentsOf: Self.collectJSONL(
                under: root.appendingPathComponent("projects", isDirectory: true)
            ))
        }
        qoderReader.prefetch(claudeFiles)
        var claudeDeduplicator = ClaudeDeduplicator()
        for file in claudeFiles {
            guard !Task.isCancelled else { return days }
            let completed = autoreleasepool {
                forEachUsageLine(in: file) { line in
                    guard !Task.isCancelled else { return false }
                    guard let record = Self.parseClaude(line) else { return true }
                    switch claudeDeduplicator.consume(record) {
                    case .none:
                        break
                    case .insert(let event):
                        bump(event, into: &days)
                    case .replace(let old, let new):
                        bump(old, multiplier: -1, into: &days)
                        bump(new, into: &days)
                    }
                    return true
                }
            }
            guard completed || !Task.isCancelled else { return days }
        }

        var seenCodex = Set<CodexEventKey>()
        for root in roots {
            guard !Task.isCancelled else { return days }
            let completed = Self.forEachCodexFile(root: root) { file in
                guard !Task.isCancelled else { return false }
                return autoreleasepool {
                    forEachCodexEvent(in: file) { event in
                        guard !Task.isCancelled else { return false }
                        let key = CodexEventKey(
                            timestampMilliseconds: Self.timestampMilliseconds(event.timestamp),
                            model: event.model,
                            usage: event.usage
                        )
                        guard seenCodex.insert(key).inserted else { return true }
                        bump(
                            UsageHistoryEvent(
                                timestamp: event.timestamp,
                                model: event.model,
                                input: max(0, event.usage.input - event.usage.cached),
                                output: event.usage.output,
                                cacheRead: event.usage.cached,
                                cacheCreation: 0
                            ),
                            into: &days
                        )
                        return true
                    }
                }
            }
            guard completed || !Task.isCancelled else { return days }
        }
        return days
    }

    private func bump(
        _ event: UsageHistoryEvent,
        multiplier: Int = 1,
        into days: inout [String: UsageHistoryDay]
    ) {
        let key = UsageHistoryQuery.dayKey(for: event.timestamp, calendar: calendar)
        var day = days[key] ?? UsageHistoryDay()
        day.requests += multiplier
        day.tokens += event.total * multiplier
        day.input += event.input * multiplier
        day.output += event.output * multiplier
        day.cacheRead += event.cacheRead * multiplier
        day.cacheCreation += event.cacheCreation * multiplier
        if let model = event.model {
            Self.adjust(model, by: event.total * multiplier, in: &day.models)
        }
        let hour = calendar.component(.hour, from: event.timestamp)
        Self.adjust(hour, by: event.total * multiplier, in: &day.hours)
        if day.requests == 0 {
            days.removeValue(forKey: key)
        } else {
            days[key] = day
        }
    }

    private func forEachUsageLine(in file: URL, _ body: (String) -> Bool) -> Bool {
        if QoderFileReader.isQoderDataPath(file) {
            guard let data = try? qoderReader.read(file) else { return true }
            return lineReader.forEachLine(in: data, body)
        } else {
            return lineReader.forEachLine(in: file, body)
        }
    }
}

private extension UsageHistoryScanner {
    struct ClaudeRecord: Sendable {
        let id: String?
        let requestID: String?
        let sidechain: Bool
        let event: UsageHistoryEvent
    }

    struct ClaudeExactKey: Hashable {
        let id: String
        let requestID: String?
    }

    enum ClaudeDeduplicationChange {
        case none
        case insert(UsageHistoryEvent)
        case replace(old: UsageHistoryEvent, new: UsageHistoryEvent)
    }

    struct ClaudeDeduplicator {
        private var kept: [ClaudeRecord] = []
        private var byExact: [ClaudeExactKey: Int] = [:]
        private var byID: [String: Int] = [:]

        mutating func consume(_ candidate: ClaudeRecord) -> ClaudeDeduplicationChange {
            guard let id = candidate.id, !UsageHistoryScanner.isDegenerateClaudeID(id) else {
                return .insert(candidate.event)
            }
            let exact = ClaudeExactKey(id: id, requestID: candidate.requestID)
            let slot = byExact[exact] ?? byID[id].flatMap { index in
                candidate.sidechain || kept[index].sidechain ? index : nil
            }
            if let slot {
                let current = kept[slot]
                let shouldReplace = (current.sidechain && !candidate.sidechain)
                    || (current.sidechain == candidate.sidechain
                        && candidate.event.total > current.event.total)
                byExact[exact] = slot
                guard shouldReplace else { return .none }
                kept[slot] = candidate
                return .replace(old: current.event, new: candidate.event)
            }

            let index = kept.count
            byExact[exact] = index
            if byID[id] == nil { byID[id] = index }
            kept.append(candidate)
            return .insert(candidate.event)
        }
    }

    struct CodexUsage: Hashable, Sendable {
        var input = 0
        var cached = 0
        var output = 0
        var reasoning = 0
        var total = 0
    }

    struct CodexEvent: Sendable {
        let usage: CodexUsage
        let timestamp: Date
        let model: String
    }

    struct CodexEventKey: Hashable {
        let timestampMilliseconds: Int64
        let model: String
        let usage: CodexUsage
    }

    static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let ordinaryISO8601 = Date.ISO8601FormatStyle()

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return (try? Date(value, strategy: fractionalISO8601))
            ?? (try? Date(value, strategy: ordinaryISO8601))
    }

    static func timestampMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    static func adjust<Key: Hashable>(
        _ key: Key,
        by delta: Int,
        in values: inout [Key: Int]
    ) {
        let adjusted = (values[key] ?? 0) + delta
        if adjusted == 0 {
            values.removeValue(forKey: key)
        } else {
            values[key] = adjusted
        }
    }

    static func parseObject(_ line: String) -> [String: HistoryValue]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(HistoryValue.self, from: data) else { return nil }
        return value.objectValue
    }

    static func parseClaude(_ line: String) -> ClaudeRecord? {
        guard line.contains("\"usage\""),
              let record = parseObject(line),
              let message = record["message"]?.objectValue,
              let usage = message["usage"]?.objectValue,
              let input = usage["input_tokens"]?.integerValue,
              let output = usage["output_tokens"]?.integerValue else { return nil }

        let cacheRead = usage["cache_read_input_tokens"]?.integerValue ?? 0
        let cacheCreation: Int
        if let nested = usage["cache_creation"]?.objectValue {
            cacheCreation = (nested["ephemeral_5m_input_tokens"]?.integerValue ?? 0)
                + (nested["ephemeral_1h_input_tokens"]?.integerValue ?? 0)
        } else {
            cacheCreation = usage["cache_creation_input_tokens"]?.integerValue ?? 0
        }
        guard input + output + cacheRead + cacheCreation > 0,
              let timestamp = parseTimestamp(record["timestamp"]?.stringValue) else { return nil }

        let speedIsFast = usage["speed"]?.stringValue == "fast"
        let rawModel = message["model"]?.stringValue ?? ""
        let model: String?
        if rawModel.isEmpty || rawModel == "<synthetic>" {
            model = nil
        } else {
            model = speedIsFast ? "\(rawModel)-fast" : rawModel
        }
        return ClaudeRecord(
            id: nonempty(message["id"]?.stringValue),
            requestID: nonempty(record["requestId"]?.stringValue),
            sidechain: record["isSidechain"]?.boolValue ?? false,
            event: UsageHistoryEvent(
                timestamp: timestamp,
                model: model,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation
            )
        )
    }

    static func isDegenerateClaudeID(_ id: String) -> Bool {
        ["msg_ccbud", "chatcmpl-ccbud", "resp_ccbud"].contains(id)
    }

    func forEachCodexEvent(in file: URL, _ body: (CodexEvent) -> Bool) -> Bool {
        let replaySecond = Self.isCodexSubagent(file) ? codexReplaySecond(file) : nil
        var skippingReplay = replaySecond != nil
        var currentModel: String?
        var previousTotals: CodexUsage?

        return lineReader.forEachLine(in: file) { line in
            guard !Task.isCancelled else { return false }
            guard !line.isEmpty else { return true }

            if line.contains("turn_context"), let record = Self.parseObject(line),
               record["type"]?.stringValue == "turn_context" {
                if let model = Self.codexModel(record["payload"]?.objectValue) {
                    currentModel = model
                }
                return true
            }
            guard let tokenLine = Self.codexTokenLine(line) else { return true }
            let timestampText = tokenLine.timestamp
            let payload = tokenLine.payload
            let info = payload["info"]?.objectValue
            let total = info?["total_token_usage"]?.objectValue.flatMap(Self.codexUsage)
            let last = info?["last_token_usage"]?.objectValue.flatMap(Self.codexUsage)

            if skippingReplay {
                let second = String(timestampText.prefix(19))
                if second == replaySecond {
                    if let total { previousTotals = total }
                    return true
                }
                skippingReplay = false
            }

            let candidateUsage = last ?? total.map {
                Self.subtract($0, previous: previousTotals)
            }
            if let total { previousTotals = total }
            guard var usage = candidateUsage,
                  usage.input + usage.cached + usage.output + usage.reasoning != 0,
                  let timestamp = Self.parseTimestamp(timestampText) else { return true }
            usage.cached = min(usage.cached, usage.input)
            let model = Self.codexModel(payload)
                ?? Self.codexModel(info)
                ?? currentModel
                ?? "gpt-5"
            return body(CodexEvent(usage: usage, timestamp: timestamp, model: model))
        }
    }

    static func codexUsage(_ object: [String: HistoryValue]) -> CodexUsage? {
        func value(_ aliases: [String]) -> Int {
            aliases.lazy.compactMap { object[$0]?.integerValue }.first ?? 0
        }
        let input = value(["input_tokens", "prompt_tokens", "input"])
        let cached = value(["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"])
        let output = value(["output_tokens", "completion_tokens", "output"])
        let reasoning = value(["reasoning_output_tokens", "reasoning_tokens"])
        let componentTotal = input + output + reasoning
        let declared = object["total_tokens"]?.integerValue
        let total = if let declared, declared > 0 || componentTotal == 0 {
            declared
        } else {
            componentTotal
        }
        return CodexUsage(
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            total: total
        )
    }

    static func subtract(_ current: CodexUsage, previous: CodexUsage?) -> CodexUsage {
        let previous = previous ?? CodexUsage()
        return CodexUsage(
            input: max(0, current.input - previous.input),
            cached: max(0, current.cached - previous.cached),
            output: max(0, current.output - previous.output),
            reasoning: max(0, current.reasoning - previous.reasoning),
            total: max(0, current.total - previous.total)
        )
    }

    static func codexModel(_ object: [String: HistoryValue]?) -> String? {
        guard let object else { return nil }
        return nonempty(object["model"]?.stringValue)
            ?? nonempty(object["model_name"]?.stringValue)
            ?? nonempty(object["metadata"]?["model"]?.stringValue)
    }

    static func codexTokenLine(
        _ line: String
    ) -> (timestamp: String, payload: [String: HistoryValue])? {
        guard line.contains("token_count"), let record = parseObject(line),
              record["type"]?.stringValue == "event_msg",
              let payload = record["payload"]?.objectValue,
              payload["type"]?.stringValue == "token_count",
              let timestamp = record["timestamp"]?.stringValue else { return nil }
        return (timestamp, payload)
    }

    static func isCodexSubagent(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1_024) else { return false }
        return data.range(of: Data("thread_spawn".utf8)) != nil
    }

    func codexReplaySecond(_ file: URL) -> String? {
        var first: String?
        var result: String?
        _ = lineReader.forEachLine(in: file) { line in
            guard !Task.isCancelled else { return false }
            guard result == nil, let tokenLine = Self.codexTokenLine(line),
                  let info = tokenLine.payload["info"]?.objectValue,
                  info["last_token_usage"] != nil || info["total_token_usage"] != nil else {
                return true
            }
            let second = String(tokenLine.timestamp.prefix(19))
            if let first {
                result = first == second ? second : ""
            } else {
                first = second
            }
            return result == nil
        }
        return result.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func forEachCodexFile(root: URL, _ body: (URL) -> Bool) -> Bool {
        var seenRelative = Set<String>()
        for directoryName in ["sessions", "archived_sessions"] {
            guard !Task.isCancelled else { return false }
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            let completed = forEachJSONL(under: directory) { file in
                guard !isInsideGrokDirectory(file) else { return true }
                let relative = relativePath(of: file, under: directory) ?? file.path
                guard seenRelative.insert(relative).inserted else { return true }
                return body(file)
            }
            guard completed else { return false }
        }
        return !Task.isCancelled
    }

    static func isInsideGrokDirectory(_ file: URL) -> Bool {
        file.pathComponents.contains { component in
            let lower = component.lowercased()
            return lower.hasPrefix("%2f") || lower.hasPrefix("%3a%5c")
        }
    }

    static func relativePath(of file: URL, under directory: URL) -> String? {
        let base = directory.standardizedFileURL.pathComponents
        let candidate = file.standardizedFileURL.pathComponents
        guard candidate.count >= base.count,
              Array(candidate.prefix(base.count)) == base else { return nil }
        return candidate.dropFirst(base.count).joined(separator: "/")
    }

    static func collectJSONL(under directory: URL, depth: Int = 0) -> [URL] {
        guard depth <= 8, !Task.isCancelled else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []
        var result: [URL] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled else { return result }
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                result.append(contentsOf: collectJSONL(under: entry, depth: depth + 1))
            } else if values.isRegularFile == true, entry.pathExtension.lowercased() == "jsonl" {
                result.append(entry.standardizedFileURL)
            }
        }
        return result
    }

    static func forEachJSONL(
        under directory: URL,
        depth: Int = 0,
        _ body: (URL) -> Bool
    ) -> Bool {
        guard depth <= 8, !Task.isCancelled else { return !Task.isCancelled }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled else { return false }
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                guard forEachJSONL(under: entry, depth: depth + 1, body) else { return false }
            } else if values.isRegularFile == true,
                      entry.pathExtension.lowercased() == "jsonl",
                      !body(entry.standardizedFileURL) {
                return false
            }
        }
        return !Task.isCancelled
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
