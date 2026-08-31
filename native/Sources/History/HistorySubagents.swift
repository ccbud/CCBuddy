import Foundation

/// Reads Claude/Qoder child transcripts stored beside a main session.
///
/// Only exact, direct `agent-*.jsonl` files are accepted. The directory and every file must be an
/// ordinary on-disk entry; symlinks are intentionally ignored for the same reason main history
/// discovery rejects them.
enum HistorySubagentReader {
    static func attach(
        to session: HistorySession,
        mainRecords: [[String: HistoryValue]],
        qoder: Bool,
        qoderReader: QoderFileReader = .shared
    ) -> HistorySession {
        var result = session
        if result.metadata.skill == nil, result.metadata.isSubagent {
            result.metadata.skill = fallbackSkill(from: mainRecords)
        }
        guard !result.metadata.isSubagent else { return result }
        var subagents = read(
            mainFile: session.metadata.file,
            qoder: qoder,
            qoderReader: qoderReader
        )
        applySkillNames(mainMessages: session.messages, subagents: &subagents)
        result.subagents = subagents
        result.metadata.subagentCount = subagents.count
        return result
    }

    static func fallbackSkill(from records: [[String: HistoryValue]]) -> String? {
        guard let firstUser = records.first(where: {
            $0["type"]?.stringValue == "user"
                && $0["message"] != nil
                && $0["isMeta"]?.boolValue != true
        }) else { return nil }
        let text = contentText(firstUser["message"]?["content"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Base directory for this skill: "
        guard text.hasPrefix(prefix) else { return nil }
        let firstLine = text.dropFirst(prefix.count).split(whereSeparator: { $0.isNewline }).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    static func qoderPrefetchFiles(mainFile: URL) -> [URL] {
        let stem = mainFile.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }
        let directory = mainFile.deletingLastPathComponent()
            .appendingPathComponent(stem, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard isOrdinaryDirectory(directory) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { file in
            let name = file.lastPathComponent
            let supported = exactAgentID(name, suffix: ".jsonl") != nil
                || exactAgentID(name, suffix: ".meta.json") != nil
            return supported && isOrdinaryFile(file)
        }.map { $0.standardizedFileURL }
    }

    private static func read(
        mainFile: URL,
        qoder: Bool,
        qoderReader: QoderFileReader
    ) -> [String: HistorySubagent] {
        let stem = mainFile.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [:] }
        let stemDirectory = mainFile.deletingLastPathComponent()
            .appendingPathComponent(stem, isDirectory: true)
        let directory = stemDirectory
            .appendingPathComponent("subagents", isDirectory: true)
        guard isOrdinaryDirectory(stemDirectory), isOrdinaryDirectory(directory) else { return [:] }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let transcripts = entries.compactMap { file -> (String, URL)? in
            guard let agentID = exactAgentID(file.lastPathComponent, suffix: ".jsonl"),
                  isOrdinaryFile(file) else { return nil }
            return (agentID, file.standardizedFileURL)
        }.sorted { $0.1.lastPathComponent < $1.1.lastPathComponent }

        if qoder { qoderReader.prefetch(qoderPrefetchFiles(mainFile: mainFile)) }

        var result: [String: HistorySubagent] = [:]
        for (agentID, transcript) in transcripts {
            guard let document = try? HistoryJSONLDocument.read(
                from: transcript,
                qoderReader: qoderReader
            ) else { continue }
            let records = qoder ? QoderHistoryParser.normalize(document.records) : document.records
            let shaped = shape(records)
            let metaFile = directory.appendingPathComponent("agent-\(agentID).meta.json")
            let meta = readMetadata(metaFile, qoder: qoder, qoderReader: qoderReader)
            let rawKey = meta["toolUseId"]?.stringValue
            let key = rawKey ?? "agent:\(agentID)"
            let type = meta["agentType"]?.stringValue
                ?? meta["subagent_type"]?.stringValue
                ?? "agent"
            result[key] = HistorySubagent(
                agentID: agentID,
                file: transcript,
                type: type,
                description: meta["description"]?.stringValue ?? "",
                skill: fallbackSkill(from: records),
                count: shaped.messages.count,
                totals: shaped.totals,
                messages: shaped.messages
            )
        }
        return result
    }

    private static func shape(
        _ records: [[String: HistoryValue]]
    ) -> (messages: [HistoryMessage], totals: HistoryTotals) {
        var messages: [HistoryMessage] = []
        var totals = HistoryTotals()
        for record in records {
            let type = record["type"]?.stringValue ?? ""
            guard type == "user" || type == "assistant",
                  record["isMeta"]?.boolValue != true,
                  let envelope = record["message"]?.objectValue,
                  let role = envelope["role"]?.stringValue else { continue }
            let usage = type == "assistant" ? HistoryParsingSupport.usage(from: envelope["usage"]) : nil
            if let usage { totals.add(usage) }
            let timestampText = record["timestamp"]?.stringValue
            messages.append(HistoryMessage(
                role: role,
                content: HistoryParsingSupport.blocks(from: envelope["content"]),
                timestamp: HistoryDateParser.parse(timestampText),
                timestampText: timestampText,
                modelActual: type == "assistant" ? envelope["model"]?.stringValue : nil,
                usage: usage,
                stopReason: type == "assistant" ? envelope["stop_reason"]?.stringValue : nil,
                isSidechain: record["isSidechain"]?.boolValue ?? false
            ))
        }
        return (messages, totals)
    }

    private static func applySkillNames(
        mainMessages: [HistoryMessage],
        subagents: inout [String: HistorySubagent]
    ) {
        guard !subagents.isEmpty else { return }
        var names: [(String, String)] = []
        func scan(_ messages: [HistoryMessage]) {
            for message in messages {
                for block in message.content where block.type == "tool_use" && block.name == "Skill" {
                    guard let id = block.id, subagents[id] != nil,
                          let skill = block.input?["skill"]?.stringValue?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !skill.isEmpty else { continue }
                    names.append((id, skill))
                }
            }
        }
        scan(mainMessages)
        for subagent in subagents.values { scan(subagent.messages) }
        for (id, skill) in names { subagents[id]?.skill = skill }
    }

    private static func contentText(_ value: HistoryValue?) -> String {
        guard let value else { return "" }
        if let string = value.stringValue { return string }
        return value.arrayValue?.compactMap { item -> String? in
            if let string = item.stringValue { return string }
            guard ["text", "input_text", "output_text"].contains(
                item["type"]?.stringValue ?? ""
            ) else { return nil }
            return item["text"]?.stringValue
        }.joined(separator: "\n") ?? value["text"]?.stringValue ?? ""
    }

    private static func readMetadata(
        _ file: URL,
        qoder: Bool,
        qoderReader: QoderFileReader
    ) -> [String: HistoryValue] {
        guard exactAgentID(file.lastPathComponent, suffix: ".meta.json") != nil,
              isOrdinaryFile(file) else { return [:] }
        let data: Data
        do {
            data = qoder
                ? try qoderReader.read(file)
                : try Data(contentsOf: file)
        } catch {
            return [:]
        }
        guard
              let value = try? JSONDecoder().decode(HistoryValue.self, from: data) else { return [:] }
        return value.objectValue ?? [:]
    }

    private static func exactAgentID(_ name: String, suffix: String) -> String? {
        guard name.hasPrefix("agent-"), name.hasSuffix(suffix),
              name.count > "agent-".count + suffix.count else { return nil }
        return String(name.dropFirst("agent-".count).dropLast(suffix.count))
    }

    private static func isOrdinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isOrdinaryFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
