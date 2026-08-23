import CryptoKit
import Foundation

struct BifrostConfiguration: Codable, Equatable {
    /// Bifrost accepts SecretVar values as either a scalar string or its management-API
    /// object form. Config schema v1.6.11 documents the scalar form, so generated config
    /// uses it while decoding both representations for round-trip compatibility.
    struct SecretVar: Codable, Equatable {
        var value: String

        init(_ value: String) { self.value = value }

        init(from decoder: Decoder) throws {
            if let scalar = try? decoder.singleValueContainer().decode(String.self) {
                value = scalar
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(String.self, forKey: .value)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }

        private enum CodingKeys: String, CodingKey { case value }
    }
    struct AuthConfig: Codable, Equatable {
        var adminUsername: SecretVar
        var adminPassword: SecretVar
        var isEnabled: Bool
        enum CodingKeys: String, CodingKey {
            case adminUsername = "admin_username"
            case adminPassword = "admin_password"
            case isEnabled = "is_enabled"
        }
    }
    struct Governance: Codable, Equatable {
        var authConfig: AuthConfig
        var virtualKeys: [VirtualKey]
        enum CodingKeys: String, CodingKey {
            case authConfig = "auth_config"
            case virtualKeys = "virtual_keys"
        }
    }
    /// Only fields deliberately owned by CC Buddy are encoded. Bifrost v1.6.11 fills all other
    /// ClientConfig defaults after decoding this partial object, including its compatibility
    /// conversion defaults. An explicit empty origin list is preserved while Bifrost's built-in
    /// localhost exception continues to allow the native app and local CLIs.
    struct Client: Codable, Equatable {
        struct Compatibility: Codable, Equatable {
            var convertTextToChat: Bool = false
            var convertChatToResponses: Bool = false
            var shouldDropParams: Bool = false
            var shouldConvertParams: Bool = false

            enum CodingKeys: String, CodingKey {
                case convertTextToChat = "convert_text_to_chat"
                case convertChatToResponses = "convert_chat_to_responses"
                case shouldDropParams = "should_drop_params"
                case shouldConvertParams = "should_convert_params"
            }
        }

        var enforceAuthOnInference: Bool
        var allowedOrigins: [String]
        var logRetentionDays: Int
        var compat: Compatibility
        enum CodingKeys: String, CodingKey {
            case enforceAuthOnInference = "enforce_auth_on_inference"
            case allowedOrigins = "allowed_origins"
            case logRetentionDays = "log_retention_days"
            case compat
        }
    }
    struct VirtualKey: Codable, Equatable {
        var id: String
        var name: String
        var value: SecretVar
        var isActive: Bool
        var providerConfigs: [VirtualKeyProviderConfig]
        var mcpConfigs: [String]
        enum CodingKeys: String, CodingKey {
            case id, name, value
            case isActive = "is_active"
            case providerConfigs = "provider_configs"
            case mcpConfigs = "mcp_configs"
        }
    }
    struct VirtualKeyProviderConfig: Codable, Equatable {
        var provider: String
        var weight: Double
        var allowedModels: [String]
        var blacklistedModels: [String]
        var keyIDs: [String]
        enum CodingKeys: String, CodingKey {
            case provider, weight
            case allowedModels = "allowed_models"
            case blacklistedModels = "blacklisted_models"
            case keyIDs = "key_ids"
        }
    }
    struct Store: Codable, Equatable {
        var enabled: Bool
        var type: String?
        var config: [String: String]?
    }
    struct Framework: Codable, Equatable {
        struct Pricing: Codable, Equatable {
            var modelParametersURL: String

            enum CodingKeys: String, CodingKey {
                case modelParametersURL = "model_parameters_url"
            }
        }

        var pricing: Pricing
    }
    struct Key: Codable, Equatable {
        var name: String
        var value: String?
        var weight: Double
        var models: [String]
        var aliases: [String: String]
    }
    struct Network: Codable, Equatable {
        var baseURL: String
        var insecureSkipVerify: Bool
        var timeout: Int = 600
        var maxRetries: Int
        var retryBackoffInitial: Int
        var retryBackoffMax: Int
        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case insecureSkipVerify = "insecure_skip_verify"
            case timeout = "default_request_timeout_in_seconds"
            case maxRetries = "max_retries"
            case retryBackoffInitial = "retry_backoff_initial"
            case retryBackoffMax = "retry_backoff_max"
        }
    }
    /// Mirrors Bifrost v1.6.11's `AllowedRequests`. A non-nil object is an
    /// allow-list: every omitted or false operation is rejected. Encoding the
    /// complete shape makes the selected upstream wire protocol authoritative
    /// instead of silently granting newly added Bifrost operations.
    struct AllowedRequests: Codable, Equatable {
        var listModels = false
        var textCompletion = false
        var textCompletionStream = false
        var chatCompletion = false
        var chatCompletionStream = false
        var responses = false
        var responsesStream = false
        var responsesRetrieve = false
        var responsesDelete = false
        var responsesCancel = false
        var responsesInputItems = false
        var countTokens = false
        var compaction = false
        var embedding = false
        var rerank = false
        var ocr = false
        var speech = false
        var speechStream = false
        var transcription = false
        var transcriptionStream = false
        var imageGeneration = false
        var imageGenerationStream = false
        var imageEdit = false
        var imageEditStream = false
        var imageVariation = false
        var videoGeneration = false
        var videoRetrieve = false
        var videoDownload = false
        var videoDelete = false
        var videoList = false
        var videoRemix = false
        var batchCreate = false
        var batchList = false
        var batchRetrieve = false
        var batchCancel = false
        var batchDelete = false
        var batchResults = false
        var fileUpload = false
        var fileList = false
        var fileRetrieve = false
        var fileDelete = false
        var fileContent = false
        var containerCreate = false
        var containerList = false
        var containerRetrieve = false
        var containerDelete = false
        var containerFileCreate = false
        var containerFileList = false
        var containerFileRetrieve = false
        var containerFileContent = false
        var containerFileDelete = false
        var passthrough = false
        var passthroughStream = false
        var webSocketResponses = false
        var realtime = false
        var cachedContentCreate = false
        var cachedContentList = false
        var cachedContentRetrieve = false
        var cachedContentUpdate = false
        var cachedContentDelete = false

        enum CodingKeys: String, CodingKey {
            case listModels = "list_models"
            case textCompletion = "text_completion"
            case textCompletionStream = "text_completion_stream"
            case chatCompletion = "chat_completion"
            case chatCompletionStream = "chat_completion_stream"
            case responses
            case responsesStream = "responses_stream"
            case responsesRetrieve = "responses_retrieve"
            case responsesDelete = "responses_delete"
            case responsesCancel = "responses_cancel"
            case responsesInputItems = "responses_input_items"
            case countTokens = "count_tokens"
            case compaction, embedding, rerank, ocr, speech
            case speechStream = "speech_stream"
            case transcription
            case transcriptionStream = "transcription_stream"
            case imageGeneration = "image_generation"
            case imageGenerationStream = "image_generation_stream"
            case imageEdit = "image_edit"
            case imageEditStream = "image_edit_stream"
            case imageVariation = "image_variation"
            case videoGeneration = "video_generation"
            case videoRetrieve = "video_retrieve"
            case videoDownload = "video_download"
            case videoDelete = "video_delete"
            case videoList = "video_list"
            case videoRemix = "video_remix"
            case batchCreate = "batch_create"
            case batchList = "batch_list"
            case batchRetrieve = "batch_retrieve"
            case batchCancel = "batch_cancel"
            case batchDelete = "batch_delete"
            case batchResults = "batch_results"
            case fileUpload = "file_upload"
            case fileList = "file_list"
            case fileRetrieve = "file_retrieve"
            case fileDelete = "file_delete"
            case fileContent = "file_content"
            case containerCreate = "container_create"
            case containerList = "container_list"
            case containerRetrieve = "container_retrieve"
            case containerDelete = "container_delete"
            case containerFileCreate = "container_file_create"
            case containerFileList = "container_file_list"
            case containerFileRetrieve = "container_file_retrieve"
            case containerFileContent = "container_file_content"
            case containerFileDelete = "container_file_delete"
            case passthrough
            case passthroughStream = "passthrough_stream"
            case webSocketResponses = "websocket_responses"
            case realtime
            case cachedContentCreate = "cached_content_create"
            case cachedContentList = "cached_content_list"
            case cachedContentRetrieve = "cached_content_retrieve"
            case cachedContentUpdate = "cached_content_update"
            case cachedContentDelete = "cached_content_delete"
        }
    }

    struct CustomProvider: Codable, Equatable {
        var baseProviderType: String
        var allowedRequests: AllowedRequests
        enum CodingKeys: String, CodingKey {
            case baseProviderType = "base_provider_type"
            case allowedRequests = "allowed_requests"
        }
    }
    struct ProviderConfig: Codable, Equatable {
        var keys: [Key]
        var networkConfig: Network
        var customProviderConfig: CustomProvider
        var storeRawRequestResponse: Bool
        enum CodingKeys: String, CodingKey {
            case keys
            case networkConfig = "network_config"
            case customProviderConfig = "custom_provider_config"
            case storeRawRequestResponse = "store_raw_request_response"
        }
    }

    var schema = "https://www.getbifrost.ai/schema"
    var sourceOfTruth = "config.json"
    var client: Client
    var configStore: Store
    var logsStore: Store
    var framework: Framework
    var governance: Governance
    var providers: [String: ProviderConfig]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case sourceOfTruth = "source_of_truth"
        case client
        case configStore = "config_store"
        case logsStore = "logs_store"
        case framework
        case governance
        case providers
    }
}

enum BifrostConfigBuilder {
    static let providerName = "ccbud-active"
    static let virtualKeyID = "ccbud-gateway"
    static let virtualKeyName = "CC Buddy Gateway"
    /// Bifrost v1.6.11's SQLite cleaner reads `client.log_retention_days`; the similarly named
    /// `logs_store.retention_days` is consumed only by the ClickHouse store. Raw provider payloads
    /// exist solely for the local monitor inspector, so keep them for Bifrost's minimum interval.
    static let logRetentionDays = 1
    static let claudePrimaryAliases = ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-5"]
    static let claudeFastAliases = ["claude-haiku-4-5", "claude-haiku-4-5-20251001"]
    static let codexPrimaryAliases = ["gpt-5.4", "gpt-5.5-ccbud"]
    static let codexFastAliases = ["gpt-5.4-mini"]

    enum BuildError: LocalizedError, Equatable {
        case missingInferenceToken

        var errorDescription: String? {
            switch self {
            case .missingInferenceToken: "已要求网关令牌，但令牌为空"
            }
        }
    }

    private struct ModelParametersEntry: Codable, Equatable {
        var mode: String
        var supportedEndpoints: [String]

        enum CodingKeys: String, CodingKey {
            case mode
            case supportedEndpoints = "supported_endpoints"
        }
    }

    static let modelParametersFileName = "model-parameters.json"

    /// Bifrost's Chat -> Responses compatibility hook is model-catalog driven. Generate a
    /// deliberately small local catalog from every caller-facing alias and upstream model ID
    /// CC Buddy owns so conversion never depends on a remote catalog being current or reachable.
    static func modelParametersData(from config: AppConfig) throws -> Data {
        guard let provider = config.activeProvider else { throw BifrostError.noActiveProvider }
        let endpoints: [String]
        let mode: String
        switch provider.protocol {
        case .anthropic:
            mode = "chat"
            endpoints = ["/v1/chat/completions", "/v1/responses"]
        case .openAIChat:
            mode = "chat"
            endpoints = ["/v1/chat/completions"]
        case .openAIResponses:
            mode = "responses"
            endpoints = ["/v1/responses"]
        }
        let entry = ModelParametersEntry(mode: mode, supportedEndpoints: endpoints)
        let document = Dictionary(uniqueKeysWithValues: modelCatalogModels(for: provider).map {
            ($0, entry)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private static func aliases(for provider: Provider) -> [String: String] {
        var aliases: [String: String] = [:]
        for item in provider.models {
            let alias = trimmedModelName(item.alias)
            let upstream = trimmedModelName(item.upstream)
            if !alias.isEmpty && !upstream.isEmpty && aliases[alias] == nil {
                aliases[alias] = upstream
            }
        }
        let defaultModel = trimmedModelName(provider.defaultModel)
        let smallFastModel = trimmedModelName(provider.smallFastModel)
        if !defaultModel.isEmpty && aliases[defaultModel] == nil {
            aliases[defaultModel] = defaultModel
        }
        if !smallFastModel.isEmpty && aliases[smallFastModel] == nil {
            aliases[smallFastModel] = smallFastModel
        }
        if provider.mapDefaultModels {
            let primary = defaultModel.isEmpty ? smallFastModel : defaultModel
            let fast = smallFastModel.isEmpty ? defaultModel : smallFastModel
            for alias in claudePrimaryAliases + codexPrimaryAliases where aliases[alias] == nil {
                if !primary.isEmpty { aliases[alias] = primary }
            }
            for alias in claudeFastAliases + codexFastAliases where aliases[alias] == nil {
                if !fast.isEmpty { aliases[alias] = fast }
            }
        }
        return aliases
    }

    private static func modelCatalogModels(for provider: Provider) -> [String] {
        let aliases = aliases(for: provider)
        let names = aliases.keys.map(trimmedModelName) + aliases.values.map(trimmedModelName)
        return Set(names)
            .filter { !$0.isEmpty && $0 != "*" }
            .sorted()
    }

    private static func trimmedModelName(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func revisionedFileURL(_ fileURL: URL, data: Data) -> URL {
        let revision = SHA256.hash(data: data).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "revision", value: revision)]
        return components.url!
    }

    static func build(
        from config: AppConfig,
        logDatabaseURL: URL,
        managementCredentials: BifrostManagementCredentials
    ) throws -> BifrostConfiguration {
        guard let provider = config.activeProvider else { throw BifrostError.noActiveProvider }
        guard !provider.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BifrostError.invalidBaseURL
        }
        let aliases = aliases(for: provider)
        let catalogModels = modelCatalogModels(for: provider)
        let modelParametersData = try modelParametersData(from: config)
        let baseType = provider.protocol == .anthropic ? "anthropic" : "openai"
        let allowedRequests: BifrostConfiguration.AllowedRequests = {
            var requests = BifrostConfiguration.AllowedRequests()
            switch provider.protocol {
            case .anthropic:
                // Bifrost's Anthropic transport represents Messages as Responses
                // internally; its provider supports both caller-facing shapes on
                // the same upstream /v1/messages endpoint.
                requests.listModels = true
                requests.chatCompletion = true
                requests.chatCompletionStream = true
                requests.responses = true
                requests.responsesStream = true
                requests.countTokens = true
            case .openAIChat:
                // Keeping Responses explicitly disabled is intentional. Bifrost's
                // OpenAI provider detects this exact capability pair and performs
                // its native Responses -> Chat conversion, including SSE events.
                requests.listModels = true
                requests.chatCompletion = true
                requests.chatCompletionStream = true
            case .openAIResponses:
                requests.listModels = true
                requests.responses = true
                requests.responsesStream = true
                requests.responsesRetrieve = true
                requests.responsesDelete = true
                requests.responsesCancel = true
                requests.responsesInputItems = true
                requests.countTokens = true
                requests.compaction = true
                requests.webSocketResponses = true
            }
            return requests
        }()
        let key = BifrostConfiguration.Key(
            name: "CC Buddy \(provider.name)", value: provider.authToken.isEmpty ? nil : provider.authToken,
            weight: 1, models: ["*"], aliases: aliases
        )
        // Bifrost retries several transient upstream failures, including 429.  Keep the
        // configured retry budget/backoff intact and set the cap beyond the final scheduled
        // retry so it does not truncate CC Buddy's exponential sequence.
        let retryCount = config.retry429.enabled ? min(max(config.retry429.max, 0), 10) : 0
        let retryInitial = min(max(config.retry429.baseMs, 100), 10_000)
        let retryBackoffMax = retryInitial * (1 << retryCount)
        let providerConfig = BifrostConfiguration.ProviderConfig(
            keys: [key],
            networkConfig: .init(
                baseURL: provider.baseUrl,
                insecureSkipVerify: config.insecureSkipVerify,
                maxRetries: retryCount,
                retryBackoffInitial: retryInitial,
                retryBackoffMax: retryBackoffMax
            ),
            customProviderConfig: .init(
                baseProviderType: baseType,
                allowedRequests: allowedRequests
            ),
            // The monitor detail endpoint only returns provider-wire request/response bodies
            // when Bifrost captured them for internal logging. They are deliberately not sent
            // back to CLI clients.
            storeRawRequestResponse: true
        )
        let appDirectory = logDatabaseURL.deletingLastPathComponent()
        let virtualKeys: [BifrostConfiguration.VirtualKey]
        if config.requireToken {
            guard let token = normalizeInferenceToken(config.gatewayToken) else {
                throw BuildError.missingInferenceToken
            }
            virtualKeys = [.init(
                id: virtualKeyID,
                name: virtualKeyName,
                value: .init(token),
                isActive: true,
                providerConfigs: [.init(
                    provider: providerName,
                    weight: 1,
                    allowedModels: ["*"],
                    blacklistedModels: [],
                    keyIDs: ["*"]
                )],
                // CC Buddy's inference key deliberately grants no MCP access.
                mcpConfigs: []
            )]
        } else {
            // Presence matters: source_of_truth=config.json uses this empty collection to remove
            // a previously persisted inference key when token enforcement is turned off.
            virtualKeys = []
        }
        return BifrostConfiguration(
            client: .init(
                enforceAuthOnInference: config.requireToken,
                allowedOrigins: [],
                logRetentionDays: logRetentionDays,
                // Bifrost's compat plugin converts Chat callers only when the
                // selected model is catalogued as Responses-only. Enabling the
                // feature is safe for mixed catalogs and lets Responses-native
                // providers serve compatible Chat clients where Bifrost has a
                // verified conversion path.
                compat: .init(
                    convertChatToResponses: provider.protocol == .openAIResponses
                        && !catalogModels.isEmpty
                )
            ),
            configStore: .init(
                enabled: true,
                type: "sqlite",
                config: ["path": appDirectory.appendingPathComponent("config.db").path]
            ),
            logsStore: .init(enabled: true, type: "sqlite", config: ["path": logDatabaseURL.path]),
            framework: .init(pricing: .init(modelParametersURL: revisionedFileURL(
                appDirectory.appendingPathComponent(modelParametersFileName),
                data: modelParametersData
            ).absoluteString)),
            governance: .init(authConfig: .init(
                adminUsername: .init(managementCredentials.username),
                adminPassword: .init(managementCredentials.password),
                isEnabled: true
            ), virtualKeys: virtualKeys),
            providers: [providerName: providerConfig]
        )
    }
}

/// Converts CC Buddy's persisted token into the prefix Bifrost recognizes in conventional
/// Authorization and API-key headers. Empty input remains an explicit failure so callers decide
/// whether to generate a new secret, reject a save, or surface a configuration error.
func normalizeInferenceToken(_ rawToken: String) -> String? {
    let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return nil }
    return token.hasPrefix("sk-bf-") ? token : "sk-bf-\(token)"
}
