import Foundation

private struct KiroSidecar {
    var cwd: String?
    var title: String?
    var createdAt: Date?
    var updatedAt: Date?
    var model: String?
}

private struct KiroNormalizedTranscript {
    var messages: [HistoryMessage] = []
    var unknownRecords = 0
}

/// Normalizes Kiro CLI's JSONL payload and its same-stem JSON metadata sidecar.
enum KiroHistoryParser {
    static func parse(_ context: HistoryParseContext) -> HistorySession {
        let normalized = normalize(context.document.records)
        let sidecar = readSidecar(for: context.candidate.file)
        let nativeID = WakeHistoryAdapterSupport.nativeID(context.candidate)
        let custom = ForeignHistorySupport.customMetadata(
            source: .kiro,
            sessionKey: nativeID,
            appDataRoot: context.appDataRoot
        )
        let inferredTitle = HistoryParsingSupport.firstUserTitle(in: normalized.messages)
        let autoTitle = sidecar.title
            ?? (inferredTitle.isEmpty ? "Untitled" : inferredTitle)
        let messageActivity = normalized.messages.compactMap(\.timestamp).max()
        let lastActivity = [sidecar.updatedAt, messageActivity].compactMap { $0 }.max()
        var diagnostics = context.document.diagnostics
        diagnostics.malformedLines += normalized.unknownRecords

        return HistorySession(
            metadata: HistorySessionMetadata(
                id: "kiro:\(nativeID)",
                file: context.candidate.file,
                source: .kiro,
                dirID: context.candidate.directory.id,
                dirLabel: context.candidate.directory.label,
                sessionID: nativeID,
                cwd: sidecar.cwd,
                project: HistoryParsingSupport.projectName(cwd: sidecar.cwd, encodedDirectory: nil),
                title: custom.title ?? autoTitle,
                autoTitle: autoTitle,
                tags: custom.tags,
                model: sidecar.model,
                imported: context.candidate.directory.id == "__imported__",
                deleted: custom.deleted,
                createdAt: sidecar.createdAt ?? context.facts.modifiedAt,
                lastActivity: lastActivity ?? context.facts.modifiedAt,
                sizeBytes: context.facts.sizeBytes,
                messageCount: normalized.messages.lazy.filter { !$0.isMetadata }.count,
                diagnostics: diagnostics
            ),
            messages: normalized.messages
        )
    }

    private static func normalize(
        _ records: [[String: HistoryValue]]
    ) -> KiroNormalizedTranscript {
        var result = KiroNormalizedTranscript()
        for record in records {
            let role: String
            switch record["kind"]?.stringValue ?? "" {
            case "Prompt": role = "user"
            case "AssistantMessage": role = "assistant"
            default:
                result.unknownRecords += 1
                continue
            }
            guard let data = record["data"]?.objectValue else {
                result.unknownRecords += 1
                continue
            }
            let parts = data["content"]?.arrayValue?.compactMap { block -> String? in
                guard block["kind"]?.stringValue == "text" else { return nil }
                return WakeHistoryAdapterSupport.nonempty(block["data"]?.stringValue)
            } ?? []
            let text = parts.joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            let timestamp = timestamp(seconds: data["meta"]?["timestamp"])
            result.messages.append(HistoryMessage(
                role: role,
                content: [.init(type: "text", text: text, raw: data["content"])],
                timestamp: timestamp,
                isMetadata: role == "user" && isInjectedUserContent(text)
            ))
        }
        return result
    }

    private static func readSidecar(for transcript: URL) -> KiroSidecar {
        let file = transcript.deletingPathExtension().appendingPathExtension("json")
        guard let value = ForeignHistorySupport.jsonObject(at: file) else {
            return KiroSidecar()
        }
        let rawTitle = WakeHistoryAdapterSupport.nonempty(value["title"]?.stringValue)
            .map { cleanTitleCandidate($0) }
        let modelInfo = value["session_state"]?["rts_model_state"]?["model_info"]
        return KiroSidecar(
            cwd: WakeHistoryAdapterSupport.nonempty(value["cwd"]?.stringValue),
            title: rawTitle.flatMap { WakeHistoryAdapterSupport.nonempty($0) },
            createdAt: WakeHistoryAdapterSupport.date(value["created_at"]),
            updatedAt: WakeHistoryAdapterSupport.date(value["updated_at"]),
            model: WakeHistoryAdapterSupport.nonempty(modelInfo?["model_id"]?.stringValue)
                ?? WakeHistoryAdapterSupport.nonempty(modelInfo?["model_name"]?.stringValue)
        )
    }

    private static func timestamp(seconds value: HistoryValue?) -> Date? {
        guard let seconds = value?.integerValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Wake strips common command/system wrappers before accepting a producer title.
    private static func cleanTitleCandidate(_ raw: String) -> String {
        var value = stripTagBlock(raw, tag: "system-reminder")
        value = stripTagBlock(value, tag: "local-command-caveat")
        value = stripTagBlock(value, tag: "local-command-stdout")

        let arguments = extractTag(value, tag: "command-args")
        let name = extractTag(value, tag: "command-name")
        if arguments != nil || name != nil {
            value = arguments.flatMap(WakeHistoryAdapterSupport.nonempty) ?? name ?? ""
        }

        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "<" else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            var cursor = value.index(after: index)
            var tag = ""
            var closed = false
            while cursor < value.endIndex {
                let character = value[cursor]
                if character == ">" {
                    closed = true
                    cursor = value.index(after: cursor)
                    break
                }
                if character.isNewline || tag.count > 60 { break }
                tag.append(character)
                cursor = value.index(after: cursor)
            }
            if closed {
                output.append(" ")
                index = cursor
            } else {
                output.append("<")
                output.append(tag)
                index = cursor
            }
        }

        let compact = output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard compact.count > 80 else { return compact }
        return String(compact.prefix(80)) + "…"
    }

    private static func stripTagBlock(_ text: String, tag: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result = ""
        var remainder = text[...]
        while let start = remainder.range(of: open) {
            result.append(contentsOf: remainder[..<start.lowerBound])
            result.append(" ")
            let afterOpen = remainder[start.upperBound...]
            guard let end = afterOpen.range(of: close) else { return result }
            remainder = afterOpen[end.upperBound...]
        }
        result.append(contentsOf: remainder)
        return result
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

struct KiroConversationSourceAdapter: ConversationSourceAdapter {
    let source = HistorySource.kiro
    let format = HistoryTranscriptFormat.kiro

    func discover(
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> [HistoryFileCandidate] {
        let defaultBase = configuration.homeDirectory.appendingPathComponent(
            ".kiro",
            isDirectory: true
        )
        let root = configuration.primaryDataRoot(
            for: source,
            default: defaultBase.appendingPathComponent("sessions/cli", isDirectory: true)
        )
        let base = configuration.activeSessionLocation?.source == source
            ? configuration.activeSessionLocation!.ownerRoot
            : defaultBase
        let directory = WakeHistoryAdapterSupport.directory(
            source: source,
            label: "Kiro",
            baseURL: base,
            discoveryRoot: root
        )
        guard WakeHistoryAdapterSupport.isActive(
            directory,
            configuration: configuration,
            activeOnly: activeOnly
        ) else { return [] }
        return WakeHistoryAdapterSupport.jsonlFiles(in: root).map { file in
            HistoryFileCandidate(
                file: file.standardizedFileURL,
                projectDirectoryName: nil,
                directory: directory,
                formatHint: format,
                nativeID: file.deletingPathExtension().lastPathComponent
            )
        }
    }

    func watchRoots(configuration: HistoryConfiguration) -> [URL] {
        let root = configuration.primaryDataRoot(
            for: source,
            default: configuration.homeDirectory.appendingPathComponent(".kiro/sessions/cli")
        )
        return WakeHistoryAdapterSupport.ordinaryDirectory(root) ? [root.standardizedFileURL] : []
    }

    func dependencies(
        for candidate: HistoryFileCandidate,
        configuration: HistoryConfiguration
    ) -> [ConversationSourceDependency] {
        [
            .init(file: candidate.file, role: .primaryTranscript),
            .init(
                file: candidate.file.deletingPathExtension().appendingPathExtension("json"),
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
        return KiroHistoryParser.parse(HistoryParseContext(
            candidate: input.candidate,
            document: document,
            facts: input.facts,
            homeDirectory: input.configuration.homeDirectory,
            appDataRoot: input.configuration.appDataRoot
        ))
    }
}
