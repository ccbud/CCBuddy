import Foundation

private struct WakeGrokSummary {
    var cwd: String?
    var title: String?
    var createdAt: Date?
    var updatedAt: Date?
    var gitBranch: String?
    var model: String?
}

private struct WakeGrokBoundedText {
    private static let truncationMarker = "\n… (truncated)"

    let maximumUTF8Bytes: Int
    private(set) var value = ""
    private var utf8Bytes = 0
    private var truncated = false

    init(maximumUTF8Bytes: Int) {
        self.maximumUTF8Bytes = max(0, maximumUTF8Bytes)
        value.reserveCapacity(self.maximumUTF8Bytes)
    }

    /// Grok persists message text as many small chunks. Mutating one retained accumulator avoids
    /// rebuilding the complete pending message for every chunk, and stops reading presentation
    /// text as soon as its byte budget has been filled.
    mutating func append(_ fragment: String?) {
        guard !truncated, let fragment, !fragment.isEmpty else { return }
        let fragmentBytes = fragment.utf8.count
        if utf8Bytes + fragmentBytes <= maximumUTF8Bytes {
            value.append(contentsOf: fragment)
            utf8Bytes += fragmentBytes
            return
        }

        let marker = Self.truncationMarker
        let prefixLimit = max(0, maximumUTF8Bytes - marker.utf8.count)
        if utf8Bytes > prefixLimit {
            value = WakeGrokHistoryParser.utf8Prefix(value, maximumBytes: prefixLimit)
            utf8Bytes = value.utf8.count
        }
        if utf8Bytes < prefixLimit {
            let suffix = WakeGrokHistoryParser.utf8Prefix(
                fragment,
                maximumBytes: prefixLimit - utf8Bytes
            )
            value.append(contentsOf: suffix)
            utf8Bytes += suffix.utf8.count
        }
        if maximumUTF8Bytes >= marker.utf8.count {
            value.append(contentsOf: marker)
            utf8Bytes += marker.utf8.count
        }
        truncated = true
    }
}

private struct WakeGrokPendingBlock {
    var block: HistoryContentBlock
    var accumulatedText: WakeGrokBoundedText?

    static func text(type: String, maximumUTF8Bytes: Int) -> WakeGrokPendingBlock {
        WakeGrokPendingBlock(
            block: HistoryContentBlock(type: type),
            accumulatedText: WakeGrokBoundedText(maximumUTF8Bytes: maximumUTF8Bytes)
        )
    }

    mutating func append(_ text: String?) {
        accumulatedText?.append(text)
    }

    func materialized() -> HistoryContentBlock {
        guard let accumulatedText else { return block }
        var result = block
        if block.type == "thinking" {
            result.thinking = accumulatedText.value
        } else {
            result.text = accumulatedText.value
        }
        return result
    }
}

private struct WakeGrokPendingMessage {
    var role: String
    var timestamp: Date?
    var content: [WakeGrokPendingBlock] = []
    var toolUseIndex: [String: Int] = [:]
    var toolResultIndex: [String: Int] = [:]

    mutating func appendText(_ text: String?, type: String, maximumUTF8Bytes: Int) {
        guard let text, !text.isEmpty else { return }
        if let last = content.indices.last,
           content[last].block.type == type,
           content[last].accumulatedText != nil {
            content[last].append(text)
            return
        }
        var value = WakeGrokPendingBlock.text(
            type: type,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        value.append(text)
        content.append(value)
    }
}

private struct WakeGrokContentLocation {
    var messageIndex: Int
    var contentIndex: Int
}

private struct WakeGrokNormalizationState {
    var messages: [HistoryMessage] = []
    var pending: WakeGrokPendingMessage?
    var toolUseLocation: [String: WakeGrokContentLocation] = [:]
    var toolResultLocation: [String: WakeGrokContentLocation] = [:]
    var firstRecordTimestamp: Date?

    mutating func flush() {
        guard let value = pending.take(), !value.content.isEmpty else { return }
        let messageIndex = messages.count
        messages.append(HistoryMessage(
            role: value.role,
            content: value.content.map { $0.materialized() },
            timestamp: value.timestamp,
            timestampText: WakeHistoryAdapterSupport.timestampText(value.timestamp)
        ))
        for (callID, contentIndex) in value.toolUseIndex {
            toolUseLocation[callID] = WakeGrokContentLocation(
                messageIndex: messageIndex,
                contentIndex: contentIndex
            )
        }
        for (callID, contentIndex) in value.toolResultIndex {
            toolResultLocation[callID] = WakeGrokContentLocation(
                messageIndex: messageIndex,
                contentIndex: contentIndex
            )
        }
    }

    mutating func ensure(role: String, timestamp: Date?) {
        if pending?.role != role {
            flush()
            pending = WakeGrokPendingMessage(role: role, timestamp: timestamp)
        }
    }
}

struct WakeGrokStreamingNormalizationResult: Sendable {
    var messages: [HistoryMessage]
    var firstRecordTimestamp: Date?
    var metrics: HistoryJSONLStreamMetrics
}

enum WakeGrokHistoryParser {
    /// Wake's detail/index presentation budgets. Raw export, replay, and analysis continue to use
    /// the producer-owned `updates.jsonl`, which this parser never rewrites or retains wholesale.
    static let maximumMessageTextBytes = 32 * 1_024
    static let maximumToolValueBytes = 16 * 1_024

    static func parse(_ context: HistoryParseContext) -> HistorySession {
        var state = WakeGrokNormalizationState()
        for record in context.document.records {
            consume(record, state: &state)
        }
        state.flush()
        return makeSession(
            candidate: context.candidate,
            facts: context.facts,
            appDataRoot: context.appDataRoot,
            messages: state.messages,
            diagnostics: context.document.diagnostics
        )
    }

    static func parseStreaming(
        candidate: HistoryFileCandidate,
        facts inputFacts: HistoryFileFacts,
        appDataRoot: URL
    ) throws -> HistorySession {
        let streamed = try normalizeStreaming(from: candidate.file)
        var facts = inputFacts
        if let createdAt = streamed.firstRecordTimestamp {
            facts.createdAt = createdAt
        }
        return makeSession(
            candidate: candidate,
            facts: facts,
            appDataRoot: appDataRoot,
            messages: streamed.messages,
            diagnostics: streamed.metrics.diagnostics
        )
    }

    /// Replays canonical Grok ACP updates one record at a time. Decoded records die after the
    /// visitor returns; only bounded normalized message/tool fields survive the scan.
    static func normalizeStreaming(
        from file: URL
    ) throws -> WakeGrokStreamingNormalizationResult {
        var state = WakeGrokNormalizationState()
        let metrics = try HistoryJSONLStreamReader.scan(from: file) { record in
            consume(record, state: &state)
            return true
        }
        state.flush()
        return WakeGrokStreamingNormalizationResult(
            messages: state.messages,
            firstRecordTimestamp: state.firstRecordTimestamp,
            metrics: metrics
        )
    }

    private static func consume(
        _ record: [String: HistoryValue],
        state: inout WakeGrokNormalizationState
    ) {
        let timestamp = WakeHistoryAdapterSupport.date(record["timestamp"])
        if state.firstRecordTimestamp == nil { state.firstRecordTimestamp = timestamp }
        guard let update = record["params"]?["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue else { return }

        switch kind {
        case "user_message_chunk":
            state.ensure(role: "user", timestamp: timestamp)
            state.pending?.appendText(
                update["content"]?["text"]?.stringValue,
                type: "text",
                maximumUTF8Bytes: maximumMessageTextBytes
            )
        case "agent_message_chunk":
            state.ensure(role: "assistant", timestamp: timestamp)
            state.pending?.appendText(
                update["content"]?["text"]?.stringValue,
                type: "text",
                maximumUTF8Bytes: maximumMessageTextBytes
            )
        case "agent_thought_chunk":
            state.ensure(role: "assistant", timestamp: timestamp)
            state.pending?.appendText(
                update["content"]?["text"]?.stringValue,
                type: "thinking",
                maximumUTF8Bytes: maximumToolValueBytes
            )
        case "tool_call":
            state.ensure(role: "assistant", timestamp: timestamp)
            guard var pending = state.pending else { return }
            let callID = clipped(
                update["toolCallId"]?.stringValue ?? "",
                maximumUTF8Bytes: 1_024
            )
            let index = pending.content.count
            pending.content.append(WakeGrokPendingBlock(block: .init(
                type: "tool_use",
                id: callID.isEmpty ? nil : callID,
                name: clipped(
                    WakeHistoryAdapterSupport.nonempty(update["title"]?.stringValue) ?? "tool",
                    maximumUTF8Bytes: 512
                ),
                input: update["rawInput"].flatMap { value in
                    value == .null
                        ? nil
                        : boundedValue(value, maximumUTF8Bytes: maximumToolValueBytes)
                },
                raw: boundedValue(.object(update), maximumUTF8Bytes: maximumToolValueBytes)
            )))
            if !callID.isEmpty { pending.toolUseIndex[callID] = index }
            state.pending = pending
        case "tool_call_update":
            guard let rawCallID = WakeHistoryAdapterSupport.nonempty(
                update["toolCallId"]?.stringValue
            ) else { return }
            let callID = clipped(rawCallID, maximumUTF8Bytes: 1_024)
            applyToolUpdate(update, callID: callID, state: &state)
        case "task_backgrounded", "task_completed", "auto_compact_started",
             "auto_compact_completed", "compaction_checkpoint", "plan",
             "current_mode_update":
            return
        default:
            return
        }
    }

    private static func applyToolUpdate(
        _ update: [String: HistoryValue],
        callID: String,
        state: inout WakeGrokNormalizationState
    ) {
        let replacement = HistoryContentBlock(
            type: "tool_result",
            toolUseID: callID,
            content: toolOutput(update["content"]),
            isError: update["status"]?.stringValue == "failed",
            raw: boundedValue(.object(update), maximumUTF8Bytes: maximumToolValueBytes)
        )

        if let useIndex = state.pending?.toolUseIndex[callID],
           state.pending?.content.indices.contains(useIndex) == true {
            if state.pending?.content[useIndex].block.input == nil,
               let rawInput = update["rawInput"], rawInput != .null {
                state.pending?.content[useIndex].block.input = boundedValue(
                    rawInput,
                    maximumUTF8Bytes: maximumToolValueBytes
                )
            }
            if let resultIndex = state.pending?.toolResultIndex[callID],
               state.pending?.content.indices.contains(resultIndex) == true,
               let old = state.pending?.content[resultIndex].block {
                state.pending?.content[resultIndex].block = mergingToolResult(
                    old,
                    with: replacement
                )
            } else {
                let resultIndex = state.pending?.content.count ?? 0
                state.pending?.toolResultIndex[callID] = resultIndex
                state.pending?.content.append(WakeGrokPendingBlock(block: replacement))
            }
            return
        }

        guard let useLocation = state.toolUseLocation[callID],
              state.messages.indices.contains(useLocation.messageIndex),
              state.messages[useLocation.messageIndex].content.indices.contains(
                useLocation.contentIndex
              ) else { return }
        if state.messages[useLocation.messageIndex].content[useLocation.contentIndex].input == nil,
           let rawInput = update["rawInput"], rawInput != .null {
            state.messages[useLocation.messageIndex].content[useLocation.contentIndex].input =
                boundedValue(rawInput, maximumUTF8Bytes: maximumToolValueBytes)
        }
        if let resultLocation = state.toolResultLocation[callID],
           state.messages.indices.contains(resultLocation.messageIndex),
           state.messages[resultLocation.messageIndex].content.indices.contains(
               resultLocation.contentIndex
           ) {
            let old = state.messages[resultLocation.messageIndex].content[
                resultLocation.contentIndex
            ]
            state.messages[resultLocation.messageIndex].content[
                resultLocation.contentIndex
            ] = mergingToolResult(old, with: replacement)
        } else {
            let resultIndex = state.messages[useLocation.messageIndex].content.count
            state.messages[useLocation.messageIndex].content.append(replacement)
            state.toolResultLocation[callID] = WakeGrokContentLocation(
                messageIndex: useLocation.messageIndex,
                contentIndex: resultIndex
            )
        }
    }

    private static func mergingToolResult(
        _ old: HistoryContentBlock,
        with replacement: HistoryContentBlock
    ) -> HistoryContentBlock {
        var result = replacement
        if result.content == nil { result.content = old.content }
        if old.isError == true { result.isError = true }
        return result
    }

    private static func toolOutput(_ value: HistoryValue?) -> HistoryValue? {
        guard let values = value?.arrayValue else { return nil }
        var parts: [HistoryValue] = []
        parts.reserveCapacity(min(64, values.count))
        var omitted = 0
        for item in values {
            let content = item["content"] ?? item
            guard ForeignHistorySupport.meaningful(content) else { continue }
            if parts.count < 64 {
                parts.append(content)
            } else {
                omitted += 1
            }
        }
        guard !parts.isEmpty else { return nil }
        if omitted > 0 { parts.append(.string("… \(omitted) values omitted")) }
        return boundedValue(.array(parts), maximumUTF8Bytes: maximumToolValueBytes)
    }

    private static func makeSession(
        candidate: HistoryFileCandidate,
        facts: HistoryFileFacts,
        appDataRoot: URL,
        messages: [HistoryMessage],
        diagnostics: HistoryReadDiagnostics
    ) -> HistorySession {
        let summary = readSummary(candidate.file)
        let nativeID = candidate.nativeID
            ?? candidate.file.deletingLastPathComponent().lastPathComponent
        let custom = ForeignHistorySupport.customMetadata(
            source: .grok,
            sessionKey: nativeID,
            appDataRoot: appDataRoot
        )
        let autoTitle = summary.title ?? HistoryParsingSupport.firstUserTitle(in: messages)
        let metadata = HistorySessionMetadata(
            id: "grok:\(nativeID)",
            file: candidate.file,
            source: .grok,
            dirID: candidate.directory.id,
            dirLabel: candidate.directory.label,
            sessionID: nativeID,
            cwd: summary.cwd,
            project: HistoryParsingSupport.projectName(cwd: summary.cwd, encodedDirectory: nil),
            gitBranch: summary.gitBranch,
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: summary.model,
            imported: candidate.directory.id == "__imported__",
            deleted: custom.deleted,
            createdAt: summary.createdAt
                ?? ForeignHistorySupport.firstTimestamp(in: messages)
                ?? facts.createdAt,
            lastActivity: summary.updatedAt
                ?? ForeignHistorySupport.lastTimestamp(in: messages)
                ?? facts.modifiedAt,
            sizeBytes: facts.sizeBytes,
            messageCount: messages.lazy.filter { !$0.isMetadata }.count,
            diagnostics: diagnostics
        )
        return HistorySession(metadata: metadata, messages: messages)
    }

    private static func boundedValue(
        _ value: HistoryValue,
        maximumUTF8Bytes: Int
    ) -> HistoryValue {
        switch value {
        case .string(let string):
            return .string(clipped(string, maximumUTF8Bytes: maximumUTF8Bytes))
        case .number, .bool, .null:
            return value
        case .object(let object):
            guard !object.isEmpty else { return value }
            let keys = object.keys
                .filter { $0.utf8.count <= 256 }
                .sorted { lhs, rhs in
                    let left = valueKeyPriorities[lhs] ?? valueKeyPriorities.count
                    let right = valueKeyPriorities[rhs] ?? valueKeyPriorities.count
                    return left == right ? lhs < rhs : left < right
                }
            let retainedKeys = Array(keys.prefix(64))
            let omitted = object.count - retainedKeys.count
            let slots = retainedKeys.count + (omitted > 0 ? 1 : 0)
            let childBudget = max(
                64,
                (maximumUTF8Bytes - min(1_024, maximumUTF8Bytes / 4)) / max(1, slots)
            )
            var projected: [String: HistoryValue] = [:]
            for key in retainedKeys {
                guard let child = object[key] else { continue }
                projected[key] = boundedValue(child, maximumUTF8Bytes: childBudget)
            }
            if omitted > 0 {
                projected["_ccbuddy_omitted"] = .string("\(omitted) fields")
            }
            return fittedContainer(.object(projected), maximumUTF8Bytes: maximumUTF8Bytes)
        case .array(let values):
            guard !values.isEmpty else { return value }
            let retainedCount = min(64, values.count)
            let omitted = values.count - retainedCount
            let slots = retainedCount + (omitted > 0 ? 1 : 0)
            let childBudget = max(
                64,
                (maximumUTF8Bytes - min(1_024, maximumUTF8Bytes / 4)) / max(1, slots)
            )
            var projected = values.prefix(retainedCount).map {
                boundedValue($0, maximumUTF8Bytes: childBudget)
            }
            if omitted > 0 { projected.append(.string("… \(omitted) values omitted")) }
            return fittedContainer(.array(projected), maximumUTF8Bytes: maximumUTF8Bytes)
        }
    }

    private static func fittedContainer(
        _ value: HistoryValue,
        maximumUTF8Bytes: Int
    ) -> HistoryValue {
        let encoded = value.jsonString
        guard encoded.utf8.count > maximumUTF8Bytes else { return value }
        return .string(clipped(encoded, maximumUTF8Bytes: maximumUTF8Bytes))
    }

    fileprivate static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var used = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let bytes = value[end..<next].utf8.count
            guard used + bytes <= maximumBytes else { break }
            used += bytes
            end = next
        }
        return String(value[..<end])
    }

    private static func clipped(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        let marker = "\n… (truncated)"
        let prefixLimit = max(0, maximumUTF8Bytes - marker.utf8.count)
        return utf8Prefix(value, maximumBytes: prefixLimit) + marker
    }

    private static let valueKeyPriorities: [String: Int] = Dictionary(
        uniqueKeysWithValues: [
            "command", "cmd", "file_path", "path", "patch", "query", "code", "input",
            "output", "content", "text", "type", "name", "id", "toolCallId", "status",
            "sessionUpdate", "rawInput",
        ].enumerated().map { ($0.element, $0.offset) }
    )

    private static func readSummary(_ transcript: URL) -> WakeGrokSummary {
        guard let root = ForeignHistorySupport.jsonObject(
            at: transcript.deletingLastPathComponent().appendingPathComponent("summary.json")
        ) else { return WakeGrokSummary() }
        return WakeGrokSummary(
            cwd: WakeHistoryAdapterSupport.nonempty(root["info"]?["cwd"]?.stringValue).map {
                clipped($0, maximumUTF8Bytes: 4 * 1_024)
            },
            title: (WakeHistoryAdapterSupport.nonempty(root["generated_title"]?.stringValue)
                ?? WakeHistoryAdapterSupport.nonempty(root["session_summary"]?.stringValue)).map {
                    clipped($0, maximumUTF8Bytes: 512)
                },
            createdAt: WakeHistoryAdapterSupport.date(root["created_at"]),
            updatedAt: WakeHistoryAdapterSupport.date(root["updated_at"])
                ?? WakeHistoryAdapterSupport.date(root["last_active_at"]),
            gitBranch: WakeHistoryAdapterSupport.nonempty(root["head_branch"]?.stringValue).map {
                clipped($0, maximumUTF8Bytes: 512)
            },
            model: WakeHistoryAdapterSupport.nonempty(root["current_model_id"]?.stringValue).map {
                clipped($0, maximumUTF8Bytes: 512)
            }
        )
    }
}

struct WakeGrokConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.grok
    let format = HistoryTranscriptFormat.grok

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".grok/sessions")
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : root.deletingLastPathComponent()
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "Grok",
            baseURL: base,
            discoveryRoot: root
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        var result: [HistoryFileCandidate] = []
        for workspace in WakeHistoryAdapterSupport.contents(of: root)
            where WakeHistoryAdapterSupport.ordinaryDirectory(workspace) {
            for session in WakeHistoryAdapterSupport.contents(of: workspace)
                where WakeHistoryAdapterSupport.ordinaryDirectory(session) {
                let transcript = session.appendingPathComponent("updates.jsonl")
                guard WakeHistoryAdapterSupport.ordinaryFile(transcript) else { continue }
                result.append(HistoryFileCandidate(
                    file: transcript,
                    projectDirectoryName: workspace.lastPathComponent,
                    directory: directory,
                    formatHint: format,
                    nativeID: session.lastPathComponent
                ))
            }
        }
        return result
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".grok/sessions")
        )
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        [
            .init(file: candidate.file, role: .primaryTranscript),
            .init(
                file: candidate.file.deletingLastPathComponent()
                    .appendingPathComponent("summary.json"),
                role: .providerMetadata
            ),
            .init(
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return WakeGrokHistoryParser.parse(HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        ))
    }
}

private extension Optional {
    mutating func take() -> Wrapped? {
        let value = self
        self = nil
        return value
    }
}
