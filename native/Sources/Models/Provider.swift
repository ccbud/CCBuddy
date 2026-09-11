import Foundation

struct ModelMapping: Codable, Hashable, Identifiable {
    var alias: String
    var upstream: String
    var id: String { "\(alias)\u{0}\(upstream)" }

    private enum CodingKeys: String, CodingKey { case alias, upstream }

    init(alias: String, upstream: String) {
        self.alias = alias
        self.upstream = upstream
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream) ?? ""
    }
}

struct Provider: Codable, Hashable, Identifiable {
    enum WireProtocol: String, Codable, CaseIterable, Identifiable {
        case anthropic
        case openAIChat = "openai-chat"
        case openAIResponses = "openai-responses"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .anthropic: "Anthropic Messages"
            case .openAIChat: "OpenAI Chat Completions"
            case .openAIResponses: "OpenAI Responses"
            }
        }
    }

    enum Backend: String, Codable {
        case http
        case plugin
    }

    var id: String
    var name: String
    /// The root the provider is reached at, with nothing protocol-specific on it:
    /// `https://api.deepseek.com`, not `https://api.deepseek.com/anthropic/v1`.
    ///
    /// It is the seed the editor derives per-protocol addresses from and the root model
    /// discovery falls back to. `protocolUrls` is what the gateway actually calls; this stays
    /// authoritative only for a provider saved before per-protocol addresses existed.
    var baseUrl: String
    /// One upstream URL per wire protocol this provider speaks, keyed by `WireProtocol`.
    ///
    /// A provider binds up to three: Anthropic Messages, OpenAI Chat Completions and OpenAI
    /// Responses. Whatever is present is served to a client speaking that protocol untouched;
    /// whatever is absent is converted onto `protocol`. Plenty of vendors publish all three, and
    /// converting for them would be work done for nothing — so the conversion follows what the
    /// user configured rather than being wired in advance.
    var protocolUrls: [String: String]
    var authToken: String
    var defaultModel: String
    var smallFastModel: String
    var mapDefaultModels: Bool
    var `protocol`: WireProtocol
    var models: [ModelMapping]
    var icon: String?
    var backend: Backend
    var pluginId: String?

    init(
        id: String = UUID().uuidString.lowercased(), name: String = "",
        baseUrl: String = "", protocolUrls: [String: String] = [:],
        authToken: String = "", defaultModel: String = "",
        smallFastModel: String = "", mapDefaultModels: Bool = true,
        protocol: WireProtocol = .anthropic, models: [ModelMapping] = [],
        icon: String? = nil, backend: Backend = .http, pluginId: String? = nil
    ) {
        self.id = id; self.name = name; self.baseUrl = baseUrl
        self.protocolUrls = protocolUrls
        self.authToken = authToken; self.defaultModel = defaultModel
        self.smallFastModel = smallFastModel; self.mapDefaultModels = mapDefaultModels
        self.protocol = `protocol`; self.models = models; self.icon = icon
        self.backend = backend; self.pluginId = pluginId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseUrl, protocolUrls, authToken, defaultModel, smallFastModel
        case mapDefaultModels, `protocol`, models, icon, backend, pluginId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed"
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        protocolUrls = try c.decodeIfPresent([String: String].self, forKey: .protocolUrls) ?? [:]
        authToken = try c.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        smallFastModel = try c.decodeIfPresent(String.self, forKey: .smallFastModel) ?? ""
        mapDefaultModels = try c.decodeIfPresent(Bool.self, forKey: .mapDefaultModels) ?? true
        let protocolName = try c.decodeIfPresent(String.self, forKey: .protocol)
        `protocol` = protocolName.flatMap(WireProtocol.init(rawValue:)) ?? .anthropic
        models = try c.decodeIfPresent([ModelMapping].self, forKey: .models) ?? []
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        let backendName = try c.decodeIfPresent(String.self, forKey: .backend)
        backend = backendName.flatMap(Backend.init(rawValue:)) ?? .http
        pluginId = try c.decodeIfPresent(String.self, forKey: .pluginId)
    }
}

extension Provider {
    /// Every upstream URL this provider binds, by the protocol that URL speaks.
    ///
    /// A provider saved before per-protocol addresses existed, or one whose editor was opened and
    /// left alone, binds nothing here — those fall back to `baseUrl` under `protocol`, which is
    /// exactly the single upstream they have always had.
    var configuredUpstreamURLs: [WireProtocol: String] {
        var result: [WireProtocol: String] = [:]
        for wireProtocol in WireProtocol.allCases {
            let url = protocolUrls[wireProtocol.rawValue]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !url.isEmpty { result[wireProtocol] = url }
        }
        guard result.isEmpty else { return result }
        let base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? [:] : [`protocol`: base]
    }

    /// The URL the gateway calls for one protocol, or nil when this provider does not speak it —
    /// which is what makes conversion for that caller necessary.
    func upstreamURL(for wireProtocol: WireProtocol) -> String? {
        configuredUpstreamURLs[wireProtocol]
    }

    /// The protocols this provider speaks, primary first.
    ///
    /// `protocol` names the primary: the upstream that takes callers whose own protocol this
    /// provider does not bind. It is kept here rather than trusted blindly, because a URL the
    /// user cleared must not go on collecting the traffic nothing else claims.
    var configuredProtocols: [WireProtocol] {
        let configured = configuredUpstreamURLs
        let ordered = WireProtocol.allCases.filter { configured[$0] != nil }
        let candidate: WireProtocol? = ordered.contains(`protocol`) ? `protocol` : ordered.first
        guard let primary = candidate else { return [] }
        return [primary] + ordered.filter { $0 != primary }
    }

    var primaryProtocol: WireProtocol { configuredProtocols.first ?? `protocol` }

    /// The address to show when there is room for one: the primary protocol's.
    var primaryUpstreamURL: String {
        upstreamURL(for: primaryProtocol)
            ?? baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once every caller shape has an upstream of its own, so the gateway converts nothing.
    var servesEveryProtocolDirectly: Bool {
        configuredProtocols.count == WireProtocol.allCases.count
    }
}
