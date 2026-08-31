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
    var baseUrl: String
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
        baseUrl: String = "", authToken: String = "", defaultModel: String = "",
        smallFastModel: String = "", mapDefaultModels: Bool = true,
        protocol: WireProtocol = .anthropic, models: [ModelMapping] = [],
        icon: String? = nil, backend: Backend = .http, pluginId: String? = nil
    ) {
        self.id = id; self.name = name; self.baseUrl = baseUrl
        self.authToken = authToken; self.defaultModel = defaultModel
        self.smallFastModel = smallFastModel; self.mapDefaultModels = mapDefaultModels
        self.protocol = `protocol`; self.models = models; self.icon = icon
        self.backend = backend; self.pluginId = pluginId
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseUrl, authToken, defaultModel, smallFastModel
        case mapDefaultModels, `protocol`, models, icon, backend, pluginId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed"
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
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
