import Foundation

/// JSON carried by plugin-declared UI actions. It intentionally stays independent from
/// `AppConfig.JSONValue`: manifests are copied verbatim and plugin fields may evolve without
/// changing the application's configuration schema.
enum PluginJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PluginJSONValue])
    case array([PluginJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: PluginJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([PluginJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [PluginJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: PluginJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

struct PluginSource: Codable, Equatable, Sendable {
    var git: String
    var branch: String
    var build: String

    init(git: String = "", branch: String = "main", build: String = "") {
        self.git = git
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branch = normalizedBranch.isEmpty ? "main" : normalizedBranch
        self.build = build
    }

    private enum CodingKeys: String, CodingKey { case git, branch, build }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            git: try container.decodeIfPresent(String.self, forKey: .git) ?? "",
            branch: try container.decodeIfPresent(String.self, forKey: .branch) ?? "main",
            build: try container.decodeIfPresent(String.self, forKey: .build) ?? ""
        )
    }
}

struct PluginRuntime: Codable, Equatable, Sendable {
    static let defaultArguments = ["serve", "--port", "{port}", "--home", "{home}"]

    var executables: [String: String]
    var arguments: [String]

    init(executables: [String: String] = [:], arguments: [String] = defaultArguments) {
        self.executables = executables
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case exec, args }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executables = try container.decodeIfPresent([String: String].self, forKey: .exec) ?? [:]
        arguments = try container.decodeIfPresent([String].self, forKey: .args) ?? Self.defaultArguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executables, forKey: .exec)
        try container.encode(arguments, forKey: .args)
    }
}

struct PluginEndpoint: Codable, Equatable, Sendable {
    var protocolName: String
    var basePath: String
    var healthPath: String
    var readyTimeoutMilliseconds: Int

    init(
        protocolName: String = "openai-responses",
        basePath: String = "/v1",
        healthPath: String = "/healthz",
        readyTimeoutMilliseconds: Int = 8_000
    ) {
        self.protocolName = protocolName
        self.basePath = basePath
        self.healthPath = healthPath
        self.readyTimeoutMilliseconds = readyTimeoutMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case basePath, healthPath
        case readyTimeoutMilliseconds = "readyTimeoutMs"
    }
}

struct PluginAuthentication: Codable, Equatable, Sendable {
    var statusPath: String

    init(statusPath: String = "/v1/plugin/auth") {
        self.statusPath = statusPath
    }
}

struct PluginModel: Codable, Equatable, Sendable {
    var alias: String
    var upstream: String

    init(alias: String, upstream: String? = nil) {
        self.alias = alias
        self.upstream = upstream ?? alias
    }

    private enum CodingKeys: String, CodingKey { case alias, upstream }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        self.init(alias: alias, upstream: try container.decodeIfPresent(String.self, forKey: .upstream))
    }
}

struct PluginModelMapping: Codable, Equatable, Sendable {
    var primary: String
    var light: String

    init(primary: String = "", light: String = "") {
        self.primary = primary
        self.light = light
    }
}

/// A declarative button/form retains its complete object so newer field types remain forward
/// compatible. Host-only routing keys are exposed separately and removed from `publicValues`.
struct PluginAction: Codable, Equatable, Sendable {
    var values: [String: PluginJSONValue]

    init(values: [String: PluginJSONValue]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: PluginJSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    var id: String { values["id"]?.stringValue ?? "" }
    var label: String { values["label"]?.stringValue ?? id }
    var kind: String { values["kind"]?.stringValue ?? "call" }
    var requiresRunning: Bool? { values["requiresRunning"]?.boolValue }
    var fields: [PluginJSONValue] { values["fields"]?.arrayValue ?? [] }

    var submitPath: String {
        values["submitPath"]?.stringValue
            ?? values["path"]?.stringValue
            ?? "/v1/plugin/action/\(id)"
    }

    var loadPath: String { values["loadPath"]?.stringValue ?? submitPath }

    var publicValues: [String: PluginJSONValue] {
        var result = values
        result.removeValue(forKey: "submitPath")
        result.removeValue(forKey: "loadPath")
        result.removeValue(forKey: "path")
        return result
    }
}

struct PluginUserInterface: Codable, Equatable, Sendable {
    var actions: [PluginAction]

    init(actions: [PluginAction] = []) {
        self.actions = actions
    }
}

/// Native representation of the existing `~/.ccbud/plugins/<id>/plugin.json` contract.
/// Defaults deliberately match the Rust host so existing manifests keep decoding.
struct PluginManifest: Codable, Equatable, Sendable {
    static let supportedSpec = "ccbud-plugin/1"

    var spec: String
    var id: String
    var name: String
    var version: String
    var description: String
    var icon: String
    var source: PluginSource
    var runtime: PluginRuntime
    var endpoint: PluginEndpoint
    var authentication: PluginAuthentication
    var models: [PluginModel]
    var modelMapping: PluginModelMapping
    var userInterface: PluginUserInterface

    init(
        spec: String = supportedSpec,
        id: String,
        name: String = "Plugin",
        version: String = "0.0.0",
        description: String = "",
        icon: String = "",
        source: PluginSource = .init(),
        runtime: PluginRuntime = .init(),
        endpoint: PluginEndpoint = .init(),
        authentication: PluginAuthentication = .init(),
        models: [PluginModel] = [],
        modelMapping: PluginModelMapping = .init(),
        userInterface: PluginUserInterface = .init()
    ) {
        self.spec = spec
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.source = source
        self.runtime = runtime
        self.endpoint = endpoint
        self.authentication = authentication
        self.models = models
        self.modelMapping = modelMapping
        self.userInterface = userInterface
    }

    private enum CodingKeys: String, CodingKey {
        case spec, id, name, version, description, icon, source, runtime, endpoint
        case authentication = "auth"
        case models, modelMapping
        case userInterface = "ui"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            spec: try container.decodeIfPresent(String.self, forKey: .spec) ?? Self.supportedSpec,
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Plugin",
            version: try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0",
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            icon: try container.decodeIfPresent(String.self, forKey: .icon) ?? "",
            source: try container.decodeIfPresent(PluginSource.self, forKey: .source) ?? .init(),
            runtime: try container.decodeIfPresent(PluginRuntime.self, forKey: .runtime) ?? .init(),
            endpoint: try container.decodeIfPresent(PluginEndpoint.self, forKey: .endpoint) ?? .init(),
            authentication: try container.decodeIfPresent(PluginAuthentication.self, forKey: .authentication) ?? .init(),
            models: try container.decodeIfPresent([PluginModel].self, forKey: .models) ?? [],
            modelMapping: try container.decodeIfPresent(PluginModelMapping.self, forKey: .modelMapping) ?? .init(),
            userInterface: try container.decodeIfPresent(PluginUserInterface.self, forKey: .userInterface) ?? .init()
        )
    }

    var providerIdentifier: String { "plugin:\(id)" }
    var hasGitSource: Bool { !source.git.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func executablePath(for platformKey: String) -> String? {
        runtime.executables[platformKey]
    }
}
