import Foundation

struct AppConfig: Codable, Equatable {
    struct TrayUsage: Codable, Equatable { var enabled = false; var range = "7d" }
    struct Retry429: Codable, Equatable { var enabled = true; var max = 3; var baseMs = 500 }
    struct GatewayFailover: Codable, Equatable {
        var enabled = false
        var providerIds: [String] = []
    }
    struct AutoUpdate: Codable, Equatable { var check = true; var autoDownload = true }

    var port = 8788
    var activeProviderId: String?
    var requireToken = false
    var gatewayToken = ""
    var gatewayEnabled = true
    var openAtLogin = false
    var claudeBackup: JSONValue = .null
    var codexBackup: JSONValue = .null
    var trayUsage = TrayUsage()
    var language: String?
    var convFontPx: Int?
    var historyDirs = ["~/.claude"]
    var historyActive = "all"
    var connectTargets: [String] = []
    var retry429 = Retry429()
    var gatewayFailover = GatewayFailover()
    var insecureSkipVerify = false
    var autoUpdate = AutoUpdate()
    var providers: [Provider] = []
    /// Root keys introduced by older/newer CC Buddy releases that this build does not yet model.
    /// Keeping them here prevents a native save from silently destroying forward-compatible state.
    var additionalProperties: [String: JSONValue] = [:]

    var activeProvider: Provider? {
        providers.first(where: { $0.id == activeProviderId }) ?? providers.first
    }

    mutating func normalize() {
        port = (1...65535).contains(port) ? port : 8788
        providers = providers.map { provider in
            var item = provider
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.name.isEmpty { item.name = "Unnamed" }
            item.models = item.models.filter { !$0.alias.isEmpty || !$0.upstream.isEmpty }
            if item.protocol == .anthropic,
               item.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == "https://open.bigmodel.cn/api/anthropic" {
                item.baseUrl = "https://open.bigmodel.cn/api/anthropic/v1"
            }
            if let icon = item.icon?.trimmingCharacters(in: .whitespacesAndNewlines) {
                item.icon = icon.isEmpty ? nil : icon
            }
            return item
        }
        if activeProviderId == nil || !providers.contains(where: { $0.id == activeProviderId }) {
            activeProviderId = providers.first?.id
        }
        var normalizedDirectories: [String] = []
        for rawDirectory in ["~/.claude"] + historyDirs {
            var directory = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            while directory.count > 1 && (directory.hasSuffix("/") || directory.hasSuffix("\\")) {
                directory.removeLast()
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if directory == home { directory = "~" }
            else if directory.hasPrefix(home + "/") { directory = "~/" + directory.dropFirst(home.count + 1) }
            if !directory.isEmpty && !normalizedDirectories.contains(directory) {
                normalizedDirectories.append(directory)
            }
        }
        historyDirs = normalizedDirectories
        // Wake's library always reads the shared all-session catalog, with only imported and
        // trash remaining as persisted library scopes. Older releases persisted producer roots
        // (and the retired `__codex__` selector), which can make a healthy catalog appear empty
        // when that one producer has no rows. Normalize at the config boundary so every startup
        // path gets the migration, including launches which temporarily skip auto-discovery.
        if historyActive != "all" && historyActive != "__imported__"
            && historyActive != "__trash__" {
            historyActive = "all"
        }
        if let language, !["en", "zh", "zh-TW", "ja", "ko"].contains(language) {
            self.language = nil
        }
        var seenTargets = Set<String>()
        connectTargets = connectTargets.filter {
            ($0 == "claude" || $0 == "codex") && seenTargets.insert($0).inserted
        }
        if let size = convFontPx {
            let clamped = min(max(size, 10), 24)
            convFontPx = clamped == 13 ? nil : clamped
        }
        retry429.max = min(max(retry429.max, 0), 10)
        retry429.baseMs = min(max(retry429.baseMs, 0), 10_000)
        normalizeGatewayFailover()
    }

    mutating func normalizeGatewayFailover() {
        let providerIDs = providers.map(\.id)
        let available = Set(providerIDs)
        var seen = Set<String>()
        let queue = gatewayFailover.providerIds.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        gatewayFailover.providerIds = queue
    }

    static let fixture = AppConfig(
        activeProviderId: "p1",
        providers: [Provider(
            id: "p1", name: "GLM", baseUrl: "https://open.bigmodel.cn/api/anthropic/v1",
            authToken: "sk-testtoken1234", defaultModel: "glm-5.2",
            smallFastModel: "glm-5.2", models: [.init(alias: "claude-opus-4-8", upstream: "glm-5.2")]
        )]
    )
}

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue])
    case array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
