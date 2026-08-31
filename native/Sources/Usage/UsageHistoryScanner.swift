import Foundation

protocol UsageHistoryScanning: Sendable {
    func scan(configuration: UsageHistoryConfiguration) -> [String: UsageHistoryDay]
}

struct UsageHistoryScanner: UsageHistoryScanning, Sendable {
    var calendar: Calendar
    var qoderReader: QoderFileReader
    /// Optional because tests and embedders want a scanner that always reads from disk. When
    /// present, unchanged transcripts are answered from their previously parsed records instead of
    /// being read again — the difference between re-reading a 14 GB library on every launch and
    /// reading a few megabytes of records.
    var recordCache: UsageHistoryRecordCache?

    init(
        calendar: Calendar = .current,
        qoderReader: QoderFileReader = .shared,
        recordCache: UsageHistoryRecordCache? = nil
    ) {
        self.calendar = calendar
        self.qoderReader = qoderReader
        self.recordCache = recordCache
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
        var visited = Set<String>()
        qoderReader.prefetch(claudeFiles)
        var claudeDeduplicator = ClaudeDeduplicator()
        for file in claudeFiles {
            guard !Task.isCancelled else { return days }
            for record in claudeRecords(in: file, visited: &visited) {
                claudeDeduplicator.append(record)
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
                for event in codexEvents(in: file, visited: &visited) {
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
        guard !Task.isCancelled else { return days }
        recordCache?.commit(retaining: visited)
        return days
    }

    private func bump(_ event: UsageHistoryEvent, into days: inout [String: UsageHistoryDay]) {
        // One calendar query per record. This fold visits every cached record on every scan, so a
        // second `calendar.component(.hour, ...)` call doubled the dominant per-record cost.
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour],
            from: event.timestamp
        )
        let key = UsageHistoryQuery.dayKey(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
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
        day.hours[components.hour ?? 0, default: 0] += event.total
        days[key] = day
    }

    /// Cached records for a transcript, or freshly parsed ones when it is new or has changed.
    ///
    /// Records — not day buckets — because deduplication runs across files: an assistant message
    /// appears in both a parent transcript and its subagent's, so the fold has to see every record.
    private func claudeRecords(in file: URL, visited: inout Set<String>) -> [ClaudeRecord] {
        let key = UsageHistoryRecordCache.key(for: file)
        visited.insert(key)
        let parseAll = { () -> [ClaudeRecord] in
            var parsed: [ClaudeRecord] = []
            self.forEachUsageLine(in: file) { line in
                if let record = Self.parseClaude(line) { parsed.append(record) }
            }
            return parsed
        }
        guard let cache = recordCache, let identity = UsageHistoryFileIdentity.of(file) else {
            return parseAll()
        }
        if let cached = cache.records(for: file, identity: identity) {
            return cached.claude.map(Self.record(from:))
        }

        // Qoder transcripts flow through the permission-aware reader; keep them on the plain
        // full-parse path rather than teaching the continuation about a second data source.
        guard !QoderFileReader.isQoderDataPath(file),
              let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            let parsed = parseAll()
            cache.store(
                UsageHistoryFileRecords(
                    modifiedAt: identity.modifiedAt,
                    sizeBytes: identity.sizeBytes,
                    claude: parsed.map(Self.cached(from:)),
                    codex: []
                ),
                for: file
            )
            return parsed
        }

        let boundary = Self.parsedLineBoundary(of: data)
        if Self.unterminatedTailIsCompleteLine(data, boundary: boundary) {
            var parsed: [ClaudeRecord] = []
            Self.forEachLossyLine(in: data) { line in
                if let record = Self.parseClaude(line) { parsed.append(record) }
            }
            cache.store(
                UsageHistoryFileRecords(
                    modifiedAt: identity.modifiedAt,
                    sizeBytes: identity.sizeBytes,
                    claude: parsed.map(Self.cached(from:)),
                    codex: []
                ),
                for: file
            )
            return parsed
        }

        var records: [UsageHistoryCachedClaudeRecord] = []
        if let prior = cache.entry(for: file),
           let resumeFrom = Self.continuationOffset(of: data, prior: prior, boundary: boundary),
           prior.codexCarry == nil {
            records = prior.claude
            Self.forEachLossyLine(in: data.subdata(in: resumeFrom..<boundary)) { line in
                if let record = Self.parseClaude(line) { records.append(Self.cached(from: record)) }
            }
        } else {
            Self.forEachLossyLine(in: data.subdata(in: 0..<boundary)) { line in
                if let record = Self.parseClaude(line) { records.append(Self.cached(from: record)) }
            }
        }
        cache.store(
            UsageHistoryFileRecords(
                modifiedAt: identity.modifiedAt,
                sizeBytes: identity.sizeBytes,
                claude: records,
                codex: [],
                parsedBytes: Int64(boundary),
                tailChecksum: Self.tailChecksum(of: data, through: boundary)
            ),
            for: file
        )
        return records.map(Self.record(from:))
    }

    private func codexEvents(in file: URL, visited: inout Set<String>) -> [CodexEvent] {
        let key = UsageHistoryRecordCache.key(for: file)
        visited.insert(key)
        guard let cache = recordCache, let identity = UsageHistoryFileIdentity.of(file) else {
            return Self.parseCodex(file)
        }
        if let cached = cache.records(for: file, identity: identity) {
            return cached.codex.map(Self.event(from:))
        }
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            return []
        }

        let boundary = Self.parsedLineBoundary(of: data)
        if Self.unterminatedTailIsCompleteLine(data, boundary: boundary) {
            var state = Self.initialCodexState(for: file)
            let parsed = Self.parseCodex(data, state: &state)
            cache.store(
                UsageHistoryFileRecords(
                    modifiedAt: identity.modifiedAt,
                    sizeBytes: identity.sizeBytes,
                    claude: [],
                    codex: parsed.map(Self.cached(from:))
                ),
                for: file
            )
            return parsed
        }

        var events: [UsageHistoryCachedCodexEvent]
        var state: CodexParseState
        if let prior = cache.entry(for: file),
           let carry = prior.codexCarry,
           let resumeFrom = Self.continuationOffset(of: data, prior: prior, boundary: boundary) {
            state = Self.codexState(from: carry)
            events = prior.codex
            let appended = Self.parseCodex(
                data.subdata(in: resumeFrom..<boundary),
                state: &state
            )
            events.append(contentsOf: appended.map(Self.cached(from:)))
        } else {
            state = Self.initialCodexState(for: file)
            events = Self.parseCodex(data.subdata(in: 0..<boundary), state: &state)
                .map(Self.cached(from:))
        }
        cache.store(
            UsageHistoryFileRecords(
                modifiedAt: identity.modifiedAt,
                sizeBytes: identity.sizeBytes,
                claude: [],
                codex: events,
                parsedBytes: Int64(boundary),
                tailChecksum: Self.tailChecksum(of: data, through: boundary),
                codexCarry: Self.carry(from: state)
            ),
            for: file
        )
        return events.map(Self.event(from:))
    }

    /// Byte offset just past the last newline: the region whose lines are complete. Anything after
    /// it is a line still being written; parsing it would consume a fragment and permanently skip
    /// the completed record on the next pass.
    private static func parsedLineBoundary(of data: Data) -> Int {
        guard let last = data.lastIndex(of: 0x0A) else { return 0 }
        return last + 1
    }

    /// A file whose final line is complete JSON but carries no terminator (some imports end this
    /// way, and nothing ever appends to them) must keep the legacy whole-file semantics: boundary
    /// bookkeeping would exclude that line from the cached records forever. A fragment mid-write
    /// fails the JSON parse and stays safely on the continuation path.
    private static func unterminatedTailIsCompleteLine(_ data: Data, boundary: Int) -> Bool {
        guard boundary < data.count else { return false }
        let tail = String(decoding: data[boundary...], as: UTF8.self)
        return parseObject(tail) != nil
    }

    /// Where an append-only continuation may resume, or nil when the file must be fully reparsed.
    /// The proof is the checksum: if the bytes immediately before the previously parsed boundary
    /// changed, the file was rewritten rather than appended to.
    private static func continuationOffset(
        of data: Data,
        prior: UsageHistoryFileRecords,
        boundary: Int
    ) -> Int? {
        guard let parsedBytes = prior.parsedBytes, parsedBytes > 0,
              let checksum = prior.tailChecksum,
              let resumeFrom = Int(exactly: parsedBytes),
              resumeFrom <= boundary,
              tailChecksum(of: data, through: resumeFrom) == checksum else { return nil }
        return resumeFrom
    }

    private static func tailChecksum(of data: Data, through boundary: Int) -> UInt64? {
        guard boundary > 0, boundary <= data.count else { return nil }
        let start = max(0, boundary - 256)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data[start..<boundary] {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    private static func codexState(from carry: UsageHistoryCodexParseCarry) -> CodexParseState {
        CodexParseState(
            skippingReplay: carry.skippingReplay,
            replaySecond: carry.replaySecond,
            currentModel: carry.currentModel,
            previousTotals: carry.previousTotals.map {
                CodexUsage(
                    input: $0.input,
                    cached: $0.cached,
                    output: $0.output,
                    reasoning: $0.reasoning,
                    total: $0.total
                )
            }
        )
    }

    private static func carry(from state: CodexParseState) -> UsageHistoryCodexParseCarry {
        UsageHistoryCodexParseCarry(
            skippingReplay: state.skippingReplay,
            replaySecond: state.replaySecond,
            currentModel: state.currentModel,
            previousTotals: state.previousTotals.map {
                UsageHistoryCachedCodexUsage(
                    input: $0.input,
                    cached: $0.cached,
                    output: $0.output,
                    reasoning: $0.reasoning,
                    total: $0.total
                )
            }
        )
    }

    private static func cached(from record: ClaudeRecord) -> UsageHistoryCachedClaudeRecord {
        .init(
            id: record.id,
            requestID: record.requestID,
            sidechain: record.sidechain,
            timestamp: record.event.timestamp,
            model: record.event.model,
            input: record.event.input,
            output: record.event.output,
            cacheRead: record.event.cacheRead,
            cacheCreation: record.event.cacheCreation
        )
    }

    private static func record(from cached: UsageHistoryCachedClaudeRecord) -> ClaudeRecord {
        .init(
            id: cached.id,
            requestID: cached.requestID,
            sidechain: cached.sidechain,
            event: UsageHistoryEvent(
                timestamp: cached.timestamp,
                model: cached.model,
                input: cached.input,
                output: cached.output,
                cacheRead: cached.cacheRead,
                cacheCreation: cached.cacheCreation
            )
        )
    }

    private static func cached(from event: CodexEvent) -> UsageHistoryCachedCodexEvent {
        .init(
            timestamp: event.timestamp,
            model: event.model,
            input: event.usage.input,
            cached: event.usage.cached,
            output: event.usage.output,
            reasoning: event.usage.reasoning,
            total: event.usage.total
        )
    }

    private static func event(from cached: UsageHistoryCachedCodexEvent) -> CodexEvent {
        .init(
            usage: CodexUsage(
                input: cached.input,
                cached: cached.cached,
                output: cached.output,
                reasoning: cached.reasoning,
                total: cached.total
            ),
            timestamp: cached.timestamp,
            model: cached.model
        )
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

    /// The per-line parser's cross-line state. A rollout is a running log: `turn_context` sets the
    /// model for later token lines, deltas are derived from the previous cumulative totals, and a
    /// subagent replay prefix is skipped by timestamp. Resuming a parse mid-file is only correct
    /// with exactly this state from the byte it stopped at.
    struct CodexParseState: Sendable {
        var skippingReplay: Bool
        var replaySecond: String?
        var currentModel: String?
        var previousTotals: CodexUsage?
    }

    static func initialCodexState(for file: URL) -> CodexParseState {
        let replaySecond = isCodexSubagent(file) ? codexReplaySecond(file) : nil
        return CodexParseState(
            skippingReplay: replaySecond != nil,
            replaySecond: replaySecond,
            currentModel: nil,
            previousTotals: nil
        )
    }

    static func parseCodex(_ file: URL) -> [CodexEvent] {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return [] }
        var state = initialCodexState(for: file)
        return parseCodex(data, state: &state)
    }

    static func parseCodex(_ data: Data, state: inout CodexParseState) -> [CodexEvent] {
        let replaySecond = state.replaySecond
        var skippingReplay = state.skippingReplay
        var currentModel = state.currentModel
        var previousTotals = state.previousTotals
        var events: [CodexEvent] = []
        defer {
            state.skippingReplay = skippingReplay
            state.currentModel = currentModel
            state.previousTotals = previousTotals
        }

        forEachLossyLine(in: data) { line in
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
