import CryptoKit
import Darwin
import Foundation

enum ConversationReplayDestination: String, Sendable {
    case claude
    case chatGPT

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }
}

/// Builds the desktop-app deep links used to review a saved conversation.
///
/// Claude accepts repeated `file` query items, so the main transcript and every parsed
/// subagent transcript are attached individually. ChatGPT's `codex://new` route accepts a
/// workspace instead; its prompt therefore includes the same absolute file list.
enum ConversationReplayLink {
    private static let claudePromptSource = """
    附件是我之前一段 Claude Code 会话的 JSONL 记录——主会话以及每个子代理各为一个文件。请结合它们一起通读，然后帮我复盘：1）这次会话的目标与最终结果；2）走过的弯路或失误；3）可改进的提示词或 agent 使用方式。
    """

    private static let chatGPTPromptSource = """
    下面列出的是我之前一段 Coding CLI 会话的 JSONL 记录文件——主会话以及每个子代理各为一个文件。请读取它们后帮我复盘：1）这次会话的目标与最终结果；2）走过的弯路或失误；3）可改进的提示词或 agent 使用方式。
    """

    static func prompt(
        for destination: ConversationReplayDestination,
        language: AppLanguage
    ) -> String {
        language.localized(destination == .claude ? claudePromptSource : chatGPTPromptSource)
    }

    static func makeURL(
        destination: ConversationReplayDestination,
        session: HistorySession,
        language: AppLanguage = .simplifiedChinese
    ) -> URL? {
        let files = transcriptFiles(in: session)
        guard let main = files.first else { return nil }
        let replayPrompt = prompt(for: destination, language: language)

        var components = URLComponents()
        switch destination {
        case .claude:
            components.scheme = "claude"
            components.host = "cowork"
            components.path = "/new"
            components.queryItems = [URLQueryItem(name: "q", value: replayPrompt)]
                + files.map { URLQueryItem(name: "file", value: $0.path) }

        case .chatGPT:
            components.scheme = "codex"
            components.host = "new"
            let fileList = files.map(\.path).joined(separator: "\n")
            components.queryItems = [
                URLQueryItem(
                    name: "prompt",
                    // Preserve the legacy deep-link contract: the localized review prompt is
                    // followed by the scheme-facing, language-neutral transcript inventory.
                    value: "\(replayPrompt)\n\nTranscripts:\n\(fileList)"
                ),
                URLQueryItem(
                    name: "path",
                    value: main.deletingLastPathComponent().path
                ),
            ]
        }
        return components.url
    }

    static func transcriptFiles(in session: HistorySession) -> [URL] {
        let main = session.metadata.file.standardizedFileURL
        var seen = Set([main.path])
        let subagents = session.subagents.values
            .map { $0.file.standardizedFileURL }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .filter { seen.insert($0.path).inserted }
        return [main] + subagents
    }
}

protocol ConversationReplayPreparing: Sendable {
    func prepare(_ session: HistorySession) throws -> HistorySession
}

struct ConversationReplayPassthrough: ConversationReplayPreparing {
    func prepare(_ session: HistorySession) throws -> HistorySession { session }
}

enum ConversationReplayMaterializationError: LocalizedError, Sendable {
    case writeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let file, let detail):
            "无法准备会话分析附件 \(file.lastPathComponent)：\(detail)"
        }
    }
}

/// SQLite-backed, compressed, virtual, and permission-protected producers cannot be handed to a
/// desktop deep link as their original path. Materialize the already-normalized in-memory detail
/// as app-owned JSONL while leaving ordinary readable JSONL producers untouched.
struct ConversationReplayMaterializer: @unchecked Sendable, ConversationReplayPreparing {
    private struct MetadataRecord: Encodable {
        let type = "ccbud_session"
        let metadata: HistorySessionMetadata
    }

    private struct MessageRecord: Encodable {
        let type = "message"
        let message: HistoryMessage
    }

    private let root: URL
    private let creationAnchor: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        creationAnchor = root.standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.fileManager = fileManager
    }

    func prepare(_ session: HistorySession) throws -> HistorySession {
        guard needsMaterialization(session) else { return session }
        let directory = root.appendingPathComponent(directoryName(for: session), isDirectory: true)
        do {
            try ensurePrivateDirectory(root)
            try ensurePrivateDirectory(directory)
        } catch {
            throw ConversationReplayMaterializationError.writeFailed(
                directory,
                String(describing: error)
            )
        }

        var prepared = session
        let main = directory.appendingPathComponent("main.jsonl")
        try write(metadata: session.metadata, messages: session.messages, to: main)
        prepared.metadata.file = main.standardizedFileURL

        var materializedSubagents: [String: HistorySubagent] = [:]
        for (offset, entry) in session.subagents.sorted(by: { $0.key < $1.key }).enumerated() {
            var subagent = entry.value
            let name = "agent-\(offset + 1)-\(safeComponent(subagent.agentID)).jsonl"
            let file = directory.appendingPathComponent(name)
            var metadata = session.metadata
            metadata.file = file
            metadata.title = subagent.description.isEmpty ? subagent.agentID : subagent.description
            metadata.autoTitle = metadata.title
            metadata.isSubagent = true
            metadata.agentPath = subagent.agentID
            metadata.agentRole = subagent.type
            metadata.skill = subagent.skill
            metadata.messageCount = subagent.messages.count
            metadata.totals = subagent.totals
            try write(metadata: metadata, messages: subagent.messages, to: file)
            subagent.file = file.standardizedFileURL
            materializedSubagents[entry.key] = subagent
        }
        prepared.subagents = materializedSubagents
        return prepared
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        let target = directory.standardizedFileURL
        let components = try relativeComponents(of: target, under: creationAnchor)
        guard !components.isEmpty else { throw POSIXError(.EINVAL) }

        // The anchor is the caller-owned parent of the app data directory (the user's home in
        // production). Every app-owned descendant is then traversed by directory descriptor, so
        // neither a pre-seeded symlink nor a path-swap race can redirect mkdir/chmod outside it.
        var parentDescriptor = Darwin.open(
            creationAnchor.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(parentDescriptor) }

        for component in components {
            var facts = stat()
            var status = component.withCString {
                Darwin.fstatat(parentDescriptor, $0, &facts, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0 {
                guard errno == ENOENT else { throw posixError() }
                let creationStatus = component.withCString {
                    Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
                }
                guard creationStatus == 0 || errno == EEXIST else { throw posixError() }
                status = component.withCString {
                    Darwin.fstatat(parentDescriptor, $0, &facts, AT_SYMLINK_NOFOLLOW)
                }
                guard status == 0 else { throw posixError() }
            }
            guard facts.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ELOOP) }

            let childDescriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard childDescriptor >= 0 else { throw posixError() }
            guard Darwin.fchmod(childDescriptor, S_IRWXU) == 0 else {
                let error = posixError()
                Darwin.close(childDescriptor)
                throw error
            }
            Darwin.close(parentDescriptor)
            parentDescriptor = childDescriptor
        }
    }

    private func relativeComponents(of target: URL, under anchor: URL) throws -> [String] {
        let anchorPath = anchor.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(anchorPath + "/") else { throw POSIXError(.EINVAL) }
        return targetPath.dropFirst(anchorPath.count + 1).split(separator: "/").map(String.init)
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func needsMaterialization(_ session: HistorySession) -> Bool {
        if session.metadata.source == .qoder { return true }
        return ConversationReplayLink.transcriptFiles(in: session).contains { file in
            file.pathExtension.lowercased() != "jsonl"
                || !fileManager.isReadableFile(atPath: file.path)
                || !ForeignHistorySupport.isOrdinaryFile(file)
        }
    }

    private func write(
        metadata: HistorySessionMetadata,
        messages: [HistoryMessage],
        to file: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            var data = try encoder.encode(MetadataRecord(metadata: metadata))
            data.append(0x0A)
            for message in messages {
                data.append(try encoder.encode(MessageRecord(message: message)))
                data.append(0x0A)
            }
            try SecureAtomicFile.write(data, to: file, fileManager: fileManager)
        } catch {
            throw ConversationReplayMaterializationError.writeFailed(file, String(describing: error))
        }
    }

    private func directoryName(for session: HistorySession) -> String {
        let identity = "\(session.metadata.source.rawValue)\0\(session.metadata.sessionID)\0\(session.metadata.file.path)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "\(safeComponent(session.metadata.source.rawValue))-\(digest)"
    }

    private func safeComponent(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            return allowed ? Character(String(scalar)) : "-"
        }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((value.isEmpty ? "subagent" : value).prefix(64))
    }
}
