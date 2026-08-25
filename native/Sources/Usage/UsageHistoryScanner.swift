import Foundation

protocol UsageHistoryScanning: Sendable {
    func scan(configuration: UsageHistoryConfiguration) -> [String: UsageHistoryDay]
}

struct UsageHistoryScanner: UsageHistoryScanning, Sendable {
    var calendar: Calendar
    var qoderReader: QoderFileReader

    init(
        calendar: Calendar = .current,
        qoderReader: QoderFileReader = .shared
    ) {
        self.calendar = calendar
        self.qoderReader = qoderReader
    }

    func scan(configuration: UsageHistoryConfiguration) -> [String: UsageHistoryDay] {
        let roots = configuration.activeRoots
        var days: [String: UsageHistoryDay] = [:]

        // Records are folded in as they are parsed rather than collected first. Holding every
        // parsed line before aggregating meant peak memory tracked the size of the transcripts —
        // on a 14 GB library that is hundreds of megabytes of records that are about to collapse
        // into a few hundred day buckets. Deduplication still sees the same records in the same
        // order, so the result is unchanged.
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
            forEachUsageLine(in: file) { line in
                if let record = Self.parseClaude(line) { claudeDeduplicator.append(record) }
            }
        }
        for record in claudeDeduplicator.kept {
            guard !Task.isCancelled else { return days }
            bump(record.event, into: &days)
        }

        var seenCodex = Set<CodexEventKey>()
        for root in roots {
            guard !Task.isCancelled else { return days }
            for file in Self.codexFiles(root: root) {
                guard !Task.isCancelled else { return days }
                for event in Self.parseCodex(file) {
                    guard !Task.isCancelled else { return days }
                    let key = CodexEventKey(
                        timestampMilliseconds: Self.timestampMilliseconds(event.timestamp),
                        model: event.model,
                        usage: event.usage
                    )
                    guard seenCodex.insert(key).inserted else { continue }
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
                }
            }
        }
        return days
    }

    private func bump(_ event: UsageHistoryEvent, into days: inout [String: UsageHistoryDay]) {
        let key = UsageHistoryQuery.dayKey(for: event.timestamp, calendar: calendar)
        var day = days[key] ?? UsageHistoryDay()
        day.requests += 1
        day.tokens += event.total
        day.input += event.input
        day.output += event.output
        day.cacheRead += event.cacheRead
        day.cacheCreation += event.cacheCreation
        if let model = event.model {
            day.models[model, default: 0] += event.total
        }
        let hour = calendar.component(.hour, from: event.timestamp)
        day.hours[hour, default: 0] += event.total
        days[key] = day
    }

    private func forEachUsageLine(in file: URL, _ body: (String) -> Void) {
        if QoderFileReader.isQoderDataPath(file) {
            guard let data = try? qoderReader.read(file) else { return }
            Self.forEachLossyLine(in: data, body)
        } else {
            Self.forEachLossyLine(in: file, body)
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

    static func deduplicateClaude(_ records: [ClaudeRecord]) -> [ClaudeRecord] {
        var deduplicator = ClaudeDeduplicator()
        for record in records { deduplicator.append(record) }
        return deduplicator.kept
    }

    /// The same rule as before, applied one record at a time: an assistant message can appear in
    /// both a parent transcript and a subagent's, and the fuller copy wins. Keeping it incremental
    /// is what lets the scan avoid materialising every parsed record first.
    struct ClaudeDeduplicator {
        private(set) var kept: [ClaudeRecord] = []
        private var byExact: [ClaudeExactKey: Int] = [:]
        private var byID: [String: Int] = [:]

        mutating func append(_ candidate: ClaudeRecord) {
            guard let id = candidate.id, !UsageHistoryScanner.isDegenerateClaudeID(id) else {
                kept.append(candidate)
                return
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
                if shouldReplace { kept[slot] = candidate }
                byExact[exact] = slot
            } else {
                let index = kept.count
                byExact[exact] = index
                if byID[id] == nil { byID[id] = index }
                kept.append(candidate)
            }
        }
    }

    static func isDegenerateClaudeID(_ id: String) -> Bool {
        ["msg_ccbud", "chatcmpl-ccbud", "resp_ccbud"].contains(id)
    }

    static func parseCodex(_ file: URL) -> [CodexEvent] {
        let replaySecond = isCodexSubagent(file) ? codexReplaySecond(file) : nil
        var skippingReplay = replaySecond != nil
        var currentModel: String?
        var previousTotals: CodexUsage?
        var events: [CodexEvent] = []

        forEachLossyLine(in: file) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            if trimmed.contains("turn_context"), let record = parseObject(trimmed),
               record["type"]?.stringValue == "turn_context" {
                if let model = codexModel(record["payload"]?.objectValue) {
                    currentModel = model
                }
                return
            }
            guard let tokenLine = codexTokenLine(trimmed) else { return }
            let timestampText = tokenLine.timestamp
            let payload = tokenLine.payload
            let info = payload["info"]?.objectValue
            let total = info?["total_token_usage"]?.objectValue.flatMap(codexUsage)
            let last = info?["last_token_usage"]?.objectValue.flatMap(codexUsage)

            if skippingReplay {
                let second = String(timestampText.prefix(19))
                if second == replaySecond {
                    if let total { previousTotals = total }
                    return
                }
                skippingReplay = false
            }

            let candidateUsage = last ?? total.map { subtract($0, previous: previousTotals) }
            if let total { previousTotals = total }
            guard var usage = candidateUsage,
                  usage.input + usage.cached + usage.output + usage.reasoning != 0,
                  let timestamp = parseTimestamp(timestampText) else { return }
            usage.cached = min(usage.cached, usage.input)
            let model = codexModel(payload)
                ?? codexModel(info)
                ?? currentModel
                ?? "gpt-5"
            events.append(CodexEvent(usage: usage, timestamp: timestamp, model: model))
        }
        return events
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

    static func codexReplaySecond(_ file: URL) -> String? {
        var first: String?
        var result: String?
        forEachLossyLine(in: file) { line in
            guard result == nil, let tokenLine = codexTokenLine(line),
                  let info = tokenLine.payload["info"]?.objectValue,
                  info["last_token_usage"] != nil || info["total_token_usage"] != nil else { return }
            let second = String(tokenLine.timestamp.prefix(19))
            if let first {
                result = first == second ? second : ""
            } else {
                first = second
            }
        }
        return result.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func codexFiles(root: URL) -> [URL] {
        var output: [URL] = []
        var seenRelative = Set<String>()
        for directoryName in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            for file in collectJSONL(under: directory) where !isInsideGrokDirectory(file) {
                let relative = relativePath(of: file, under: directory) ?? file.path
                if seenRelative.insert(relative).inserted { output.append(file) }
            }
        }
        return output
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

    static func forEachLossyLine(in file: URL, _ body: (String) -> Void) {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return }
        forEachLossyLine(in: data, body)
    }

    static func forEachLossyLine(in data: Data, _ body: (String) -> Void) {
        var start = data.startIndex
        while start < data.endIndex, !Task.isCancelled {
            let newline = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            body(String(decoding: data[start..<newline], as: UTF8.self))
            if newline == data.endIndex { break }
            start = data.index(after: newline)
        }
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
