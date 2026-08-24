import Foundation
import libzstd

fileprivate struct DSHHeader {
    var id: String
    var cwd: String?
    var createdAt: Date?
    var isSubagent: Bool
}

private struct DSHNormalizedTranscript {
    var header: DSHHeader?
    var title: String?
    var messages: [HistoryMessage] = []
    var totals = HistoryTotals()
    var model: String?
    var lastActivity: Date?
    var diagnostics = HistoryReadDiagnostics()
}

enum DSHHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let normalized = normalize(context.document.records)
        let nativeID = normalized.header?.id
            ?? context.candidate.nativeID
            ?? context.candidate.file.deletingPathExtension().deletingPathExtension()
                .lastPathComponent
        let custom = ForeignHistorySupport.customMetadata(
            source: .dsh,
            sessionKey: nativeID,
            appDataRoot: context.appDataRoot
        )
        let inferredTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let autoTitle = normalized.title ?? inferredTitle
        let cwd = normalized.header?.cwd
        let metadata = HistorySessionMetadata(
            id: "dsh:\(nativeID)",
            file: context.candidate.file,
            source: .dsh,
            dirID: context.candidate.directory.id,
            dirLabel: context.candidate.directory.label,
            sessionID: nativeID,
            cwd: cwd,
            project: HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil),
            title: custom.title ?? autoTitle,
            autoTitle: autoTitle,
            tags: custom.tags,
            model: normalized.model,
            imported: false,
            deleted: custom.deleted,
            createdAt: normalized.header?.createdAt ?? context.facts.createdAt,
            lastActivity: normalized.lastActivity ?? context.facts.modifiedAt,
            sizeBytes: context.facts.sizeBytes,
            totals: normalized.totals,
            messageCount: normalized.messages.lazy.filter { !$0.isMetadata }.count,
            diagnostics: normalized.diagnostics
        )
        return HistorySession(metadata: metadata, messages: normalized.messages)
    }

    fileprivate static func header(_ document: HistoryJSONLDocument) -> DSHHeader? {
        document.records.lazy.compactMap(header).first
    }

    private static func normalize(
        _ records: [[String: HistoryValue]]
    ) -> DSHNormalizedTranscript {
        var result = DSHNormalizedTranscript()
        var toolLocations: [String: (message: Int, block: Int)] = [:]
        let knownSkip: Set<String> = [
            "agent-preset/selected", "agent/inbox/spliced", "approval/asked",
            "approval/decided", "approval/policy", "assistant/chunk", "command/done",
            "command/run", "compaction/end", "compaction/prune", "compaction/start",
            "compaction/summary", "feedback/record", "goal/change", "hook/invoked",
            "hook/result", "llm/retry", "llm/retry-started", "permission/preset",
            "plan/mode", "request/header", "sandbox/mode", "schedule/change",
            "session/end-seed", "session/title-llm-request", "step/end", "step/start",
            "subagent/descriptor", "team/member", "team/message/delivered",
            "team/message/queued", "team/task", "todo/write", "tool-workflow/agent-end",
            "tool-workflow/agent-start", "tool-workflow/run-end", "tool-workflow/run-start",
            "tool/call", "tool/code-dispatch", "tool/code-dispatch-start", "turn/end",
            "turn/start", "web/deepseek-search-llm-request", "text-chunks",
            "reasoning-chunks", "tool-call-chunks",
        ]

        for record in records {
            result.diagnostics.decodedLines += 1
            if record["surfaceOp"]?["op"]?.stringValue == "replace" { continue }
            let timestamp = WakeHistoryAdapterSupport.date(record["time"])
            if let timestamp, result.lastActivity.map({ timestamp > $0 }) ?? true {
                result.lastActivity = timestamp
            }
            let type = record["type"]?.stringValue ?? ""
            let data = record["data"]?.objectValue ?? [:]
            switch type {
            case "session":
                result.header = header(record) ?? result.header

            case "user/message":
                let text = WakeHistoryAdapterSupport.text(from: data["content"])
                guard !text.isEmpty else { continue }
                let sourceKind = data["source"]?["kind"]?.stringValue
                result.messages.append(HistoryMessage(
                    role: "user",
                    content: [.init(type: "text", text: text, raw: data["content"])],
                    timestamp: timestamp,
                    timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                    isMetadata: sourceKind.map { $0 != "user" } ?? false
                ))

            case "assistant/message":
                let message = data["message"]?.objectValue ?? [:]
                let model = WakeHistoryAdapterSupport.nonempty(
                    message["source"]?["model"]?.stringValue
                )
                if let model { result.model = model }
                let usage = usage(data["usage"])
                if let usage { result.totals.add(usage) }
                var blocks: [HistoryContentBlock] = []
                for raw in message["content"]?.arrayValue ?? [] {
                    guard let block = raw.objectValue else { continue }
                    switch block["type"]?.stringValue ?? "" {
                    case "text":
                        if let text = WakeHistoryAdapterSupport.nonempty(block["text"]?.stringValue) {
                            blocks.append(.init(type: "text", text: text, raw: raw))
                        }
                    case "reasoning":
                        if let text = WakeHistoryAdapterSupport.nonempty(block["text"]?.stringValue) {
                            blocks.append(.init(type: "thinking", thinking: text, raw: raw))
                        }
                    case "tool-call":
                        let callID = block["id"]?.stringValue
                        let arguments = toolArguments(block["arguments"])
                        blocks.append(.init(
                            type: "tool_use",
                            id: callID,
                            name: WakeHistoryAdapterSupport.nonempty(block["name"]?.stringValue)
                                ?? "tool",
                            input: arguments,
                            raw: raw
                        ))
                    default:
                        continue
                    }
                }
                guard !blocks.isEmpty else { continue }

                let messageIndex: Int
                if let last = result.messages.indices.last,
                   result.messages[last].role == "assistant" {
                    messageIndex = last
                    let offset = result.messages[last].content.count
                    result.messages[last].content.append(contentsOf: blocks)
                    if let model { result.messages[last].modelActual = model }
                    if let usage { result.messages[last].usage = usage }
                    recordToolLocations(
                        blocks,
                        message: last,
                        offset: offset,
                        locations: &toolLocations
                    )
                } else {
                    messageIndex = result.messages.count
                    result.messages.append(HistoryMessage(
                        role: "assistant",
                        content: blocks,
                        timestamp: timestamp,
                        timestampText: WakeHistoryAdapterSupport.timestampText(timestamp),
                        modelActual: model,
                        usage: usage
                    ))
                    recordToolLocations(
                        blocks,
                        message: messageIndex,
                        offset: 0,
                        locations: &toolLocations
                    )
                }

            case "tool/result":
                guard let raw = data["message"]?["content"]?.arrayValue?.first,
                      let block = raw.objectValue,
                      let callID = WakeHistoryAdapterSupport.nonempty(
                        block["toolCallId"]?.stringValue
                      ),
                      let location = toolLocations[callID],
                      result.messages.indices.contains(location.message) else { continue }
                let output = block["content"] ?? .null
                result.messages[location.message].content.append(.init(
                    type: "tool_result",
                    toolUseID: callID,
                    content: output,
                    isError: block["isError"]?.boolValue
                        ?? (data["error"].map(ForeignHistorySupport.meaningful) == true),
                    raw: raw
                ))

            case "session/title":
                if let title = WakeHistoryAdapterSupport.nonempty(data["title"]?.stringValue) {
                    result.title = title
                }

            case "request/context":
                if result.model == nil {
                    result.model = WakeHistoryAdapterSupport.nonempty(data["model"]?.stringValue)
                }

            default:
                if record["ignorable"]?.boolValue != true, !knownSkip.contains(type) {
                    result.diagnostics.malformedLines += 1
                }
            }
        }
        return result
    }

    private static func header(_ record: [String: HistoryValue]) -> DSHHeader? {
        guard record["type"]?.stringValue == "session",
              let id = WakeHistoryAdapterSupport.nonempty(record["id"]?.stringValue) else {
            return nil
        }
        return DSHHeader(
            id: id,
            cwd: WakeHistoryAdapterSupport.nonempty(record["cwd"]?.stringValue),
            createdAt: WakeHistoryAdapterSupport.date(record["createdAt"]),
            isSubagent: record["origin"]?.stringValue == "subagent"
                || (record["delegationDepth"]?.integerValue ?? 0) > 0
        )
    }

    private static func usage(_ value: HistoryValue?) -> HistoryUsage? {
        guard let object = value?.objectValue else { return nil }
        let result = HistoryUsage(
            inputTokens: object["inputTokens"]?.integerValue ?? 0,
            outputTokens: (object["outputTokens"]?.integerValue ?? 0)
                + (object["reasoningTokens"]?.integerValue ?? 0),
            cacheRead: object["cacheReadTokens"]?.integerValue ?? 0,
            cacheCreation: object["cacheWriteTokens"]?.integerValue ?? 0
        )
        return result.inputTokens == 0 && result.outputTokens == 0
            && result.cacheRead == 0 && result.cacheCreation == 0 ? nil : result
    }

    private static func toolArguments(_ value: HistoryValue?) -> HistoryValue {
        guard let value else { return .object([:]) }
        if value.objectValue != nil || value.arrayValue != nil { return value }
        return WakeHistoryAdapterSupport.historyValue(json: value.stringValue) ?? value
    }

    private static func recordToolLocations(
        _ blocks: [HistoryContentBlock],
        message: Int,
        offset: Int,
        locations: inout [String: (message: Int, block: Int)]
    ) {
        for (index, block) in blocks.enumerated() where block.type == "tool_use" {
            guard let id = WakeHistoryAdapterSupport.nonempty(block.id) else { continue }
            locations[id] = (message, offset + index)
        }
    }
}

enum DSHZstdDecoder {
    private static let maximumDecodedBytes = 512 * 1_024 * 1_024
    private static let maximumHeaderBytes = 64 * 1_024

    private struct DecodedPayload {
        var data: Data
        var incompleteTail: Bool
    }

    static func headerRecord(from file: URL) throws -> [String: HistoryValue]? {
        let data: Data
        if file.lastPathComponent.hasSuffix(".zstd") {
            data = try decode(file, stopAfterFirstLine: true).data
        } else {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumHeaderBytes) ?? Data()
        }
        let line = data.prefix { $0 != 0x0A }
        guard !line.isEmpty,
              let value = try? JSONDecoder().decode(HistoryValue.self, from: Data(line)) else {
            return nil
        }
        return value.objectValue
    }

    static func document(from file: URL) throws -> HistoryJSONLDocument {
        if file.lastPathComponent.hasSuffix(".zstd") {
            let payload = try decode(file, stopAfterFirstLine: false)
            let data = payload.data
            guard let text = String(data: data, encoding: .utf8) else {
                throw HistoryError.unreadableFile(file, "DSH 解压结果不是有效 UTF-8")
            }
            var document = HistoryJSONLDocument.parse(text)
            if payload.incompleteTail { document.diagnostics.malformedLines += 1 }
            return document
        }
        return try HistoryJSONLDocument.read(from: file)
    }

    /// DSH appends one independent zstd frame per write. A scan can therefore observe a complete
    /// prefix followed by a half-written final frame. Keep every complete JSONL line already
    /// decoded instead of making the whole conversation disappear until the producer's next write.
    /// libzstd is linked into the app so compressed sessions work on a clean macOS installation.
    private static func decode(
        _ file: URL,
        stopAfterFirstLine: Bool
    ) throws -> DecodedPayload {
        let compressed: Data
        do {
            compressed = try Data(contentsOf: file, options: [.mappedIfSafe])
        } catch {
            throw HistoryError.unreadableFile(file, String(describing: error))
        }
        guard !compressed.isEmpty, let stream = ZSTD_createDStream() else {
            throw HistoryError.unreadableFile(file, "无法初始化 zstd 解码器")
        }
        defer { ZSTD_freeDStream(stream) }
        let initialization = ZSTD_initDStream(stream)
        guard ZSTD_isError(initialization) == 0 else {
            throw HistoryError.unreadableFile(file, zstdError(initialization))
        }

        let limit = stopAfterFirstLine ? maximumHeaderBytes : maximumDecodedBytes
        let outputCapacity = min(1 * 1_024 * 1_024, limit)
        var decoded = Data()
        var incompleteTail = false
        var failure: String?
        var finalStatus = initialization

        compressed.withUnsafeBytes { rawInput in
            var input = ZSTD_inBuffer(
                src: rawInput.baseAddress,
                size: rawInput.count,
                pos: 0
            )
            var outputBytes = [UInt8](repeating: 0, count: outputCapacity)
            while input.pos < input.size {
                let priorInputPosition = input.pos
                let priorOutputCount = decoded.count
                let status = outputBytes.withUnsafeMutableBytes { rawOutput -> Int in
                    var output = ZSTD_outBuffer(
                        dst: rawOutput.baseAddress,
                        size: rawOutput.count,
                        pos: 0
                    )
                    let status = ZSTD_decompressStream(stream, &output, &input)
                    if output.pos > 0 {
                        let producedByteCount = min(Int(output.pos), rawOutput.count)
                        decoded.append(
                            contentsOf: rawOutput.bindMemory(to: UInt8.self).prefix(producedByteCount)
                        )
                    }
                    return status
                }
                finalStatus = status
                if ZSTD_isError(status) != 0 {
                    failure = zstdError(status)
                    incompleteTail = true
                    break
                }
                if stopAfterFirstLine, let newline = decoded.firstIndex(of: 0x0A) {
                    decoded = Data(decoded[...newline])
                    return
                }
                if decoded.count > limit {
                    failure = stopAfterFirstLine
                        ? "DSH 会话头超过 64 KiB 安全上限"
                        : "DSH 解压结果超过 512 MiB 安全上限"
                    return
                }
                if input.pos == priorInputPosition, decoded.count == priorOutputCount {
                    failure = "zstd 解码器未取得进展"
                    return
                }
            }
            if failure == nil, finalStatus != 0 {
                incompleteTail = true
            }
        }

        if let failure, !incompleteTail {
            throw HistoryError.unreadableFile(file, failure)
        }
        if incompleteTail {
            guard let newline = decoded.lastIndex(of: 0x0A) else {
                throw HistoryError.unreadableFile(file, failure ?? "zstd 数据帧不完整")
            }
            decoded = Data(decoded[...newline])
        }
        guard !decoded.isEmpty else {
            throw HistoryError.unreadableFile(file, failure ?? "zstd 解压结果为空")
        }
        return DecodedPayload(data: decoded, incompleteTail: incompleteTail)
    }

    private static func zstdError(_ status: Int) -> String {
        guard let name = ZSTD_getErrorName(status) else { return "zstd 解码失败" }
        return "zstd 解码失败：\(String(cString: name))"
    }
}

struct DSHConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.dsh
    let format = HistoryTranscriptFormat.dsh

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".dsh/sessions")
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : root.deletingLastPathComponent()
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "DeepSeek Harness",
            baseURL: base,
            discoveryRoot: root
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        var result: [HistoryFileCandidate] = []
        for project in WakeHistoryAdapterSupport.contents(of: root)
            where WakeHistoryAdapterSupport.ordinaryDirectory(project) {
            for sessionDirectory in WakeHistoryAdapterSupport.contents(of: project)
                where WakeHistoryAdapterSupport.ordinaryDirectory(sessionDirectory) {
                guard let file = preferredTranscript(in: sessionDirectory),
                      let record = (try? DSHZstdDecoder.headerRecord(from: file)) ?? nil,
                      let header = DSHHistoryParser.header(
                        HistoryJSONLDocument(
                            records: [record],
                            diagnostics: .init(decodedLines: 1)
                        )
                      ),
                      !header.isSubagent else { continue }
                result.append(HistoryFileCandidate(
                    file: file,
                    projectDirectoryName: project.lastPathComponent,
                    directory: directory,
                    formatHint: format,
                    nativeID: header.id
                ))
            }
        }
        return result
    }

    func document(
        for candidate: HistoryFileCandidate,
        qoderReader: QoderFileReader
    ) throws -> HistoryJSONLDocument? {
        try DSHZstdDecoder.document(from: candidate.file)
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".dsh/sessions")
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
                file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
                role: .customMetadata
            ),
        ]
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return DSHHistoryParser.parse(HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        ))
    }

    private func preferredTranscript(in directory: URL) -> URL? {
        let compressed = directory.appendingPathComponent("session.jsonl.zstd")
        let plain = directory.appendingPathComponent("session.jsonl")
        let candidates = [compressed, plain].filter {
            WakeHistoryAdapterSupport.ordinaryFile($0)
        }
        return candidates.max { lhs, rhs in
            let lhsDate = modifiedAt(lhs)
            let rhsDate = modifiedAt(rhs)
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.lastPathComponent == "session.jsonl"
        }
    }

    private func modifiedAt(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
