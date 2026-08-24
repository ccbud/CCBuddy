import Foundation

private struct CursorNormalizedTranscript {
    var messages: [HistoryMessage] = []
    var createdAt: Date?
    var lastActivity: Date?
    var unknownRecords = 0
}

private struct CursorPendingAssistant {
    var text: [String] = []
    var tools: [HistoryContentBlock] = []
}

/// Normalizes Cursor CLI's plaintext agent transcript while retaining Wake's turn boundaries.
enum CursorHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let normalized = normalize(context.document.records)
        let nativeID = WakeHistoryAdapterSupport.nativeID(context.candidate)
        let custom = ForeignHistorySupport.customMetadata(
            source: .cursor,
            sessionKey: nativeID,
            appDataRoot: context.appDataRoot
        )
        let inferredTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let autoTitle = inferredTitle.isEmpty ? "Untitled" : inferredTitle
        let cwd = decodeSlug(projectSlug(context.candidate))
        let subagents = readSubagents(mainFile: context.candidate.file)
        var diagnostics = context.document.diagnostics
        diagnostics.malformedLines += normalized.unknownRecords

        return HistorySession(
            metadata: HistorySessionMetadata(
                id: "cursor:\(nativeID)",
                file: context.candidate.file,
                source: .cursor,
                dirID: context.candidate.directory.id,
                dirLabel: context.candidate.directory.label,
                sessionID: nativeID,
                cwd: cwd,
                project: HistoryParsingSupport.projectName(cwd: cwd, encodedDirectory: nil),
                title: custom.title ?? autoTitle,
                autoTitle: autoTitle,
                tags: custom.tags,
                subagentCount: subagents.count,
                imported: context.candidate.directory.id == "__imported__",
                deleted: custom.deleted,
                createdAt: normalized.createdAt ?? context.facts.modifiedAt,
                lastActivity: normalized.lastActivity ?? context.facts.modifiedAt,
                sizeBytes: context.facts.sizeBytes,
                messageCount: normalized.messages.lazy.filter { !$0.isMetadata }.count,
                diagnostics: diagnostics
            ),
            messages: normalized.messages,
            subagents: subagents
        )
    }

    private static func normalize(
        _ records: [[String: HistoryValue]]
    ) -> CursorNormalizedTranscript {
        var result = CursorNormalizedTranscript()
        var pending: CursorPendingAssistant?

        func flushAssistant() {
            guard let value = pending else { return }
            pending = nil
            let text = value.text.joined(separator: "\n\n")
            guard !text.isEmpty || !value.tools.isEmpty else { return }
            var content: [HistoryContentBlock] = []
            if !text.isEmpty {
                content.append(.init(type: "text", text: text))
            }
            content.append(contentsOf: value.tools)
            result.messages.append(HistoryMessage(role: "assistant", content: content))
        }

        for record in records {
            guard let role = record["role"]?.stringValue else {
                if record["type"]?.stringValue == "turn_ended" {
                    flushAssistant()
                } else {
                    result.unknownRecords += 1
                }
                continue
            }
            let blocks = record["message"]?["content"]?.arrayValue ?? []

            switch role {
            case "user":
                flushAssistant()
                var parts: [String] = []
                var timestamp: Date?
                var timestampText: String?
                for rawBlock in blocks {
                    guard rawBlock["type"]?.stringValue == "text",
                          let raw = rawBlock["text"]?.stringValue else { continue }
                    if let embedded = extractTag(raw, tag: "timestamp"),
                       let parsed = cursorTimestamp(embedded) {
                        timestamp = parsed
                        timestampText = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let body = extractTag(raw, tag: "user_query") ?? raw
                    if let text = WakeHistoryAdapterSupport.nonempty(body) {
                        parts.append(text)
                    }
                }
                let text = parts.joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                if let timestamp {
                    if result.createdAt == nil { result.createdAt = timestamp }
                    if result.lastActivity.map({ timestamp > $0 }) ?? true {
                        result.lastActivity = timestamp
                    }
                }
                result.messages.append(HistoryMessage(
                    role: "user",
                    content: [.init(type: "text", text: text)],
                    timestamp: timestamp,
                    timestampText: timestampText,
                    isMetadata: isInjectedUserContent(text)
                ))

            case "assistant":
                if pending == nil { pending = CursorPendingAssistant() }
                for rawBlock in blocks {
                    switch rawBlock["type"]?.stringValue ?? "" {
                    case "text":
                        guard let text = rawBlock["text"]?.stringValue,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        pending?.text.append(text)
                    case "tool_use":
                        pending?.tools.append(HistoryContentBlock(
                            type: "tool_use",
                            id: "",
                            name: WakeHistoryAdapterSupport.nonempty(rawBlock["name"]?.stringValue)
                                ?? "tool",
                            input: rawBlock["input"] ?? .null,
                            raw: rawBlock
                        ))
                    default:
                        continue
                    }
                }

            default:
                result.unknownRecords += 1
            }
        }
        flushAssistant()
        return result
    }

    private static func readSubagents(mainFile: URL) -> [String: HistorySubagent] {
        let directory = subagentsDirectory(mainFile)
        var result: [String: HistorySubagent] = [:]
        for file in WakeHistoryAdapterSupport.contents(of: directory)
            where file.pathExtension.lowercased() == "jsonl"
                && WakeHistoryAdapterSupport.ordinaryFile(file) {
            guard let document = try? HistoryJSONLDocument.read(from: file) else { continue }
            let normalized = normalize(document.records)
            let agentID = file.deletingPathExtension().lastPathComponent
            let key = "agent:\(agentID)"
            result[key] = HistorySubagent(
                agentID: agentID,
                file: file.standardizedFileURL,
                count: normalized.messages.lazy.filter { !$0.isMetadata }.count,
                messages: normalized.messages
            )
        }
        return result
    }

    fileprivate static func subagentsDirectory(_ mainFile: URL) -> URL {
        mainFile.deletingLastPathComponent()
            .appendingPathComponent("subagents", isDirectory: true)
            .standardizedFileURL
    }

    private static func projectSlug(_ candidate: HistoryFileCandidate) -> String {
        if let name = WakeHistoryAdapterSupport.nonempty(candidate.projectDirectoryName) {
            return name
        }
        return candidate.file.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
    }

    /// Cursor's slug is lossy because `-` can be a separator or part of a directory name. Match
    /// Wake by preferring the shortest real path segment at every DFS level, then fall back to a
    /// direct separator translation when the project no longer exists.
    private static func decodeSlug(_ slug: String) -> String? {
        guard !slug.isEmpty else { return nil }
        let parts = slug.split(separator: "-", omittingEmptySubsequences: false).map(String.init)

        func search(base: URL, index: Int) -> URL? {
            guard index < parts.count else { return base }
            var segment = ""
            for end in index..<parts.count {
                if end > index { segment.append("-") }
                segment.append(parts[end])
                let candidate = base.appendingPathComponent(segment, isDirectory: true)
                // Match Path::is_dir in Wake: system path prefixes such as /var may be
                // symbolic links, but they still need to participate in slug reconstruction.
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: candidate.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else { continue }
                if let match = search(base: candidate, index: end + 1) { return match }
            }
            return nil
        }

        let root = URL(fileURLWithPath: "/", isDirectory: true)
        return search(base: root, index: 0)?.standardizedFileURL.path
            ?? "/" + slug.replacingOccurrences(of: "-", with: "/")
    }

    private static func cursorTimestamp(_ raw: String) -> Date? {
        guard let separator = raw.range(of: " (", options: .backwards), raw.hasSuffix(")") else {
            return nil
        }
        let dateText = raw[..<separator.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offsetStart = separator.upperBound
        let offsetEnd = raw.index(before: raw.endIndex)
        let zoneText = raw[offsetStart..<offsetEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard zoneText.hasPrefix("UTC") else { return nil }
        var offset = String(zoneText.dropFirst(3))
        var sign = 1
        if offset.hasPrefix("+") {
            offset.removeFirst()
        } else if offset.hasPrefix("-") {
            sign = -1
            offset.removeFirst()
        }
        let components = offset.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2,
              let hours = Int(components[0]), (0..<24).contains(hours),
              let minutes = components.count == 2 ? Int(components[1]) : 0,
              (0..<60).contains(minutes) else { return nil }
        let seconds = sign * (hours * 3_600 + minutes * 60)
        guard abs(seconds) < 86_400, let timeZone = TimeZone(secondsFromGMT: seconds) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMM dd, yyyy, h:mm a"
        formatter.isLenient = false
        return formatter.date(from: dateText)
    }

    private static func extractTag(_ text: String, tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>") else { return nil }
        let closeText = "</\(tag)>"
        guard let close = text.range(of: closeText, range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func isInjectedUserContent(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "<recommended_plugins", "<environment_context", "<user_instructions",
            "<permissions", "<workspace", "<system-", "<context ", "<session_context",
            "IMPORTANT: Do NOT read", "Caveat: The messages below",
            "# Files pasted by the user",
        ]
        return prefixes.contains(where: value.hasPrefix)
            || value.contains("/.codex/plugins/")
            || value.contains("/plugins/cache/") && value.contains("SKILL.md")
    }
}

struct CursorConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.cursor
    let format = HistoryTranscriptFormat.cursor

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let defaultBase = configuration.homeDirectory.appendingPathComponent(
            ".cursor",
            isDirectory: true
        )
        let root = configuration.primaryDataRoot(
            for: source,
            default: defaultBase.appendingPathComponent("projects", isDirectory: true)
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : defaultBase
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "Cursor",
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
            let transcripts = project.appendingPathComponent("agent-transcripts", isDirectory: true)
            for session in WakeHistoryAdapterSupport.contents(of: transcripts)
                where WakeHistoryAdapterSupport.ordinaryDirectory(session) {
                for file in WakeHistoryAdapterSupport.contents(of: session)
                    where file.pathExtension.lowercased() == "jsonl"
                        && WakeHistoryAdapterSupport.ordinaryFile(file) {
                    result.append(HistoryFileCandidate(
                        file: file.standardizedFileURL,
                        projectDirectoryName: project.lastPathComponent,
                        directory: directory,
                        formatHint: format,
                        nativeID: file.deletingPathExtension().lastPathComponent
                    ))
                }
            }
        }
        return result
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".cursor/projects")
        )
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root.standardizedFileURL] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        let subagents = CursorHistoryParser.subagentsDirectory(candidate.file)
        var result: [ConversationSourceDependency] = [
            .init(file: candidate.file, role: .primaryTranscript),
            .init(file: subagents, role: .subagentContainer, eventScope: .descendants),
        ]
        result.append(contentsOf: WakeHistoryAdapterSupport.contents(of: subagents).compactMap {
            file -> ConversationSourceDependency? in
            guard file.pathExtension.lowercased() == "jsonl",
                  WakeHistoryAdapterSupport.ordinaryFile(file) else { return nil }
            return .init(file: file, role: .subagentTranscript)
        })
        result.append(.init(
            file: configuration.appDataRoot.appendingPathComponent("agent-meta.json"),
            role: .customMetadata
        ))
        return result
    }

    func parse(_ input: ConversationSourceParseInput) throws -> HistorySession {
        guard let document = input.document else {
            throw HistoryError.unsupportedTranscript(input.candidate.file)
        }
        return CursorHistoryParser.parse(HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        ))
    }
}
