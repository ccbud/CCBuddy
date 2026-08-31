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
///
/// Both routes are exact about their query strings, and getting one word wrong fails silently —
/// the app comes forward with an empty composer and nothing says why. Claude only reads the
/// attachment list when the link declares `src=external`; without it the prompt arrives alone.
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
        language: AppLanguage = .simplifiedChinese,
        fileManager: FileManager = .default
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
            components.queryItems = [
                URLQueryItem(name: "q", value: replayPrompt),
                // Cowork ignores every attachment on a link that does not name its origin.
                URLQueryItem(name: "src", value: "external"),
            ] + files.map { URLQueryItem(name: "file", value: $0.path) }

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
                    value: workspace(for: session, main: main, fileManager: fileManager)
                ),
            ]
        }
        return components.url
    }

    /// The folder Codex should open the new thread in.
    ///
    /// The directory the transcript happens to sit in is the wrong answer whenever the two differ:
    /// a Codex rollout lives under `~/.codex/sessions/2026/…`, so the review used to start in an
    /// archive folder with none of the code it is about. The session's own working directory is
    /// what the conversation was about — when it is still there.
    static func workspace(
        for session: HistorySession,
        main: URL,
        fileManager: FileManager = .default
    ) -> String {
        let fallback = main.deletingLastPathComponent().path
        guard let cwd = session.metadata.cwd, !cwd.isEmpty else { return fallback }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue
        else { return fallback }
        return cwd
    }

    /// The same review request as plain text, for pasting into whatever the deep links cannot reach.
    ///
    /// A deep link can only ever address the two desktop apps that registered a scheme. This is the
    /// escape hatch for every other one — and the thing to fall back on when a link opens an app
    /// that then ignores it.
    static func clipboardText(
        for destination: ConversationReplayDestination,
        session: HistorySession,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        let files = transcriptFiles(in: session).map(\.path).joined(separator: "\n")
        return "\(prompt(for: destination, language: language))\n\nTranscripts:\n\(files)"
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
