import Foundation

struct GatewayConfiguration: Codable, Equatable {
    struct Management: Codable, Equatable {
        var port: Int
        var bearerToken: String
    }

    struct ProviderConfiguration: Codable, Equatable {
        var id: String
        var name: String
        var baseUrl: String
        var authToken: String
        var defaultModel: String
        var smallFastModel: String
        var mapDefaultModels: Bool
        var `protocol`: String
        var models: [ModelMapping]
        var enabled: Bool
        var headers: [String: String]
        var timeoutSeconds: Int
    }

    struct Failover: Codable, Equatable {
        var enabled = false
        var providerIds: [String] = []
    }

    struct Retry: Codable, Equatable {
        var enabled: Bool
        var maxRetries: Int
        var baseMs: Int
        var maxBackoffMs: Int
    }

    struct CircuitBreaker: Codable, Equatable {
        var failureThreshold = 4
        var successThreshold = 2
        var timeoutSeconds = 60
        var errorRateThreshold = 0.6
        var minRequests = 10
    }

    var publicPort: Int
    var management: Management
    var requireToken: Bool
    var gatewayToken: String
    var activeProviderId: String
    var providers: [ProviderConfiguration]
    var failover = Failover()
    var retry: Retry
    var circuitBreaker = CircuitBreaker()
    var monitorCapacity = 500
    var requestBodyLimitBytes = 64 * 1_024 * 1_024
    var responseBodyLimitBytes = 128 * 1_024 * 1_024
    var streamingFirstByteTimeout = 60
    var streamingIdleTimeout = 120
    var insecureSkipVerify: Bool
}

enum GatewayConfigurationError: LocalizedError, Equatable, Sendable {
    case noActiveProvider
    case noFailoverProviders
    case invalidPort(Int)
    case duplicateProviderID(String)
    case invalidProvider(String)
    case invalidBaseURL(String)
    case missingGatewayToken

    var errorDescription: String? {
        switch self {
        case .noActiveProvider:
            "尚未配置服务商"
        case .noFailoverProviders:
            "启用网关故障转移时至少需要一个服务商"
        case .invalidPort(let port):
            "无效的网关端口：\(port)"
        case .duplicateProviderID(let id):
            "服务商 ID 重复：\(id)"
        case .invalidProvider(let name):
            "服务商配置不完整：\(name)"
        case .invalidBaseURL(let name):
            "服务商 API 地址无效：\(name)"
        case .missingGatewayToken:
            "启用网关鉴权后必须设置访问令牌"
        }
    }
}

enum GatewayConfigBuilder {
    static func build(
        from appConfig: AppConfig,
        managementCredentials: GatewayManagementCredentials
    ) throws -> GatewayConfiguration {
        guard (1...65_535).contains(appConfig.port) else {
            throw GatewayConfigurationError.invalidPort(appConfig.port)
        }
        if appConfig.requireToken,
           appConfig.gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GatewayConfigurationError.missingGatewayToken
        }

        var seen = Set<String>()
        let providers = try appConfig.providers.map { provider in
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else {
                throw GatewayConfigurationError.invalidProvider(
                    name.isEmpty ? provider.id : provider.name
                )
            }
            guard seen.insert(id).inserted else {
                throw GatewayConfigurationError.duplicateProviderID(id)
            }
            guard isSafeHTTPBaseURL(provider.baseUrl) else {
                throw GatewayConfigurationError.invalidBaseURL(name)
            }
            return GatewayConfiguration.ProviderConfiguration(
                id: id,
                name: name,
                baseUrl: provider.baseUrl,
                authToken: provider.authToken,
                defaultModel: provider.defaultModel,
                smallFastModel: provider.smallFastModel,
                mapDefaultModels: provider.mapDefaultModels,
                protocol: provider.protocol.rawValue,
                models: provider.models,
                enabled: true,
                headers: [:],
                timeoutSeconds: 600
            )
        }

        guard !providers.isEmpty else { throw GatewayConfigurationError.noActiveProvider }
        let activeProviderID = appConfig.activeProviderId
            .flatMap { candidate in providers.contains(where: { $0.id == candidate }) ? candidate : nil }
            ?? providers[0].id

        var normalizedFailover = appConfig.gatewayFailover
        let availableProviderIDs = Set(providers.map(\.id))
        var queuedProviderIDs = Set<String>()
        normalizedFailover.providerIds = normalizedFailover.providerIds.filter {
            availableProviderIDs.contains($0) && queuedProviderIDs.insert($0).inserted
        }
        if normalizedFailover.enabled, normalizedFailover.providerIds.isEmpty {
            throw GatewayConfigurationError.noFailoverProviders
        }

        let baseDelay = min(max(appConfig.retry429.baseMs, 0), 10_000)
        return GatewayConfiguration(
            publicPort: appConfig.port,
            management: .init(
                port: 0,
                bearerToken: managementCredentials.bearerToken
            ),
            requireToken: appConfig.requireToken,
            gatewayToken: appConfig.gatewayToken,
            activeProviderId: activeProviderID,
            providers: providers,
            failover: .init(
                enabled: normalizedFailover.enabled,
                providerIds: normalizedFailover.enabled ? normalizedFailover.providerIds : []
            ),
            retry: .init(
                enabled: appConfig.retry429.enabled,
                maxRetries: min(max(appConfig.retry429.max, 0), 10),
                baseMs: baseDelay,
                maxBackoffMs: max(30_000, baseDelay)
            ),
            insecureSkipVerify: appConfig.insecureSkipVerify
        )
    }

    private static func isSafeHTTPBaseURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return false }
        return true
    }
}
