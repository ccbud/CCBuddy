import Foundation

enum HistorySource: String, Codable, Equatable, Hashable, Sendable {
    /// The Rust API called Claude's native transcript source `disk`.
    case claude = "disk"
    case codex
    case qoder
    case grok
    case copilot
    case cursor
    case opencode
    case kiro
    case gemini
    case pi
    case omp
    case kimi
    case antigravity
    case dsh
}

struct HistoryUsage: Codable, Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0
    /// Qoder reports billing/context facts even when its token counters are unavailable.
    var credits: Double?
    var originalCredits: Double?
    var contextUsageRatio: Double?
}

struct HistoryTotals: Codable, Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0
    var turns: Int = 0
    var credits: Double?
    var tokenUsageAvailable: Bool?

    mutating func add(_ usage: HistoryUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheRead += usage.cacheRead
        cacheCreation += usage.cacheCreation
        turns += 1
        if let value = usage.credits {
            credits = (credits ?? 0) + value
        }
        if credits != nil {
            tokenUsageAvailable = inputTokens != 0 || outputTokens != 0
                || cacheRead != 0 || cacheCreation != 0
        }
    }
}

/// One normalized Anthropic-style content block.
///
/// Common fields are promoted for consumers while `raw` keeps producer-specific information
/// losslessly. Claude and Codex therefore share one message model without pretending their tool
/// payloads are identical.
struct HistoryContentBlock: Codable, Equatable, Sendable {
    var type: String
    var text: String?
    var thinking: String?
    var id: String?
    var name: String?
    var toolUseID: String?
    var input: HistoryValue?
    var content: HistoryValue?
    var isError: Bool?
    var raw: HistoryValue?

    init(
        type: String,
        text: String? = nil,
        thinking: String? = nil,
        id: String? = nil,
        name: String? = nil,
        toolUseID: String? = nil,
        input: HistoryValue? = nil,
        content: HistoryValue? = nil,
        isError: Bool? = nil,
        raw: HistoryValue? = nil
    ) {
        self.type = type
        self.text = text
        self.thinking = thinking
        self.id = id
        self.name = name
        self.toolUseID = toolUseID
        self.input = input
        self.content = content
        self.isError = isError
        self.raw = raw
    }
}

struct HistoryMessage: Codable, Equatable, Sendable {
    var role: String
    var content: [HistoryContentBlock]
    var timestamp: Date?
    var timestampText: String?
    var modelActual: String?
    var usage: HistoryUsage?
    var stopReason: String?
    var isSidechain: Bool = false
    var isMetadata: Bool = false
}

struct HistoryReadDiagnostics: Codable, Equatable, Sendable {
    var decodedLines: Int = 0
    var malformedLines: Int = 0
}

struct HistorySessionMetadata: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var file: URL
    var source: HistorySource
    var dirID: String
    var dirLabel: String
    var sessionID: String
    var threadID: String?
    var rootSessionID: String?
    var parentThreadID: String?
    var forkedFromID: String?
    var canonicalThreadIDValid: Bool = false
    var cwd: String?
    var project: String
    var gitBranch: String?
    var version: String?
    var title: String
    var autoTitle: String
    var tags: [String] = []
    var summary: HistoryValue?
    var model: String?
    var isSubagent: Bool = false
    var skill: String?
    var agentPath: String?
    var agentNickname: String?
    var agentRole: String?
    var agentDepth: Int?
    var subagentCount: Int = 0
    var starred: Bool = false
    var pinned: Bool = false
    var imported: Bool = false
    var deleted: Bool = false
    var createdAt: Date
    var lastActivity: Date
    var sizeBytes: UInt64
    var totals: HistoryTotals = .init()
    var messageCount: Int = 0
    var diagnostics: HistoryReadDiagnostics = .init()
}

extension HistorySessionMetadata {
    private enum CodingKeys: String, CodingKey {
        case id, file, source, dirID, dirLabel, sessionID, threadID, rootSessionID
        case parentThreadID, forkedFromID, canonicalThreadIDValid, cwd, project, gitBranch
        case version, title, autoTitle, tags, summary, model, isSubagent, skill, agentPath
        case agentNickname, agentRole, agentDepth, subagentCount, starred, pinned, imported
        case deleted, createdAt, lastActivity, sizeBytes, totals, messageCount, diagnostics
    }

    /// `starred` and `pinned` were added after the first indexed-catalog release. Keep decoding
    /// old metadata blobs so a schema migration can preserve a warm index instead of discarding
    /// every producer-derived row just to add app-owned user metadata.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        file = try values.decode(URL.self, forKey: .file)
        source = try values.decode(HistorySource.self, forKey: .source)
        dirID = try values.decode(String.self, forKey: .dirID)
        dirLabel = try values.decode(String.self, forKey: .dirLabel)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        rootSessionID = try values.decodeIfPresent(String.self, forKey: .rootSessionID)
        parentThreadID = try values.decodeIfPresent(String.self, forKey: .parentThreadID)
        forkedFromID = try values.decodeIfPresent(String.self, forKey: .forkedFromID)
        canonicalThreadIDValid = try values.decode(Bool.self, forKey: .canonicalThreadIDValid)
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        project = try values.decode(String.self, forKey: .project)
        gitBranch = try values.decodeIfPresent(String.self, forKey: .gitBranch)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        title = try values.decode(String.self, forKey: .title)
        autoTitle = try values.decode(String.self, forKey: .autoTitle)
        tags = try values.decode([String].self, forKey: .tags)
        summary = try values.decodeIfPresent(HistoryValue.self, forKey: .summary)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        isSubagent = try values.decode(Bool.self, forKey: .isSubagent)
        skill = try values.decodeIfPresent(String.self, forKey: .skill)
        agentPath = try values.decodeIfPresent(String.self, forKey: .agentPath)
        agentNickname = try values.decodeIfPresent(String.self, forKey: .agentNickname)
        agentRole = try values.decodeIfPresent(String.self, forKey: .agentRole)
        agentDepth = try values.decodeIfPresent(Int.self, forKey: .agentDepth)
        subagentCount = try values.decode(Int.self, forKey: .subagentCount)
        starred = try values.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        imported = try values.decode(Bool.self, forKey: .imported)
        deleted = try values.decode(Bool.self, forKey: .deleted)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastActivity = try values.decode(Date.self, forKey: .lastActivity)
        sizeBytes = try values.decode(UInt64.self, forKey: .sizeBytes)
        totals = try values.decode(HistoryTotals.self, forKey: .totals)
        messageCount = try values.decode(Int.self, forKey: .messageCount)
        diagnostics = try values.decode(HistoryReadDiagnostics.self, forKey: .diagnostics)
    }
}

struct HistorySubagent: Codable, Equatable, Sendable {
    var agentID: String
    var file: URL
    var type: String = "agent"
    var description: String = ""
    var skill: String?
    var count: Int = 0
    var totals: HistoryTotals = .init()
    var messages: [HistoryMessage] = []
}

struct HistorySession: Codable, Equatable, Sendable {
    var metadata: HistorySessionMetadata
    var messages: [HistoryMessage]
    var subagents: [String: HistorySubagent] = [:]
}

struct HistoryProject: Codable, Equatable, Identifiable, Sendable {
    var cwd: String
    var name: String
    var sessions: [HistorySessionMetadata]
    var lastActivity: Date

    var id: String { cwd }
}

struct HistorySearchHit: Codable, Equatable, Identifiable, Sendable {
    var sessionID: String
    var file: URL
    var source: HistorySource
    var agent: String = "main"
    var agentType: String?
    /// Parser-stable message position within `agent`; indexed hits use it for exact navigation.
    var sequence: Int? = nil
    var snippet: String
    var count: Int

    var id: String { "\(file.path)\u{0}\(agent)" }
}

struct HistoryDirectory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var baseURL: URL
    var projectsURL: URL
    var sessionsURL: URL
}

enum HistoryError: LocalizedError, Equatable, Sendable {
    case invalidPath(URL)
    case pathOutsideConfiguredRoots(URL)
    case notARegularJSONLFile(URL)
    case unreadableFile(URL, String)
    case unsupportedTranscript(URL)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let url): "无效的会话路径：\(url.path)"
        case .pathOutsideConfiguredRoots(let url): "会话路径不在已配置目录内：\(url.path)"
        case .notARegularJSONLFile(let url): "会话不是普通 JSONL 文件：\(url.path)"
        case .unreadableFile(let url, let detail): "无法读取会话 \(url.path)：\(detail)"
        case .unsupportedTranscript(let url): "无法识别会话格式：\(url.path)"
        }
    }
}
