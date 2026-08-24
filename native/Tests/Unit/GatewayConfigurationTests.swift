import Foundation
import XCTest
@testable import CCBuddy

final class GatewayConfigurationTests: XCTestCase {
    private let credentials = GatewayManagementCredentials(
        bearerToken: "0123456789abcdef0123456789abcdef",
        endpoint: GatewayManagementEndpoint()
    )

    func testBuildPreservesProvidersProtocolsAliasesAndPrivateManagementContract() throws {
        var config = AppConfig.fixture
        config.port = 19_876
        config.providers = [
            Provider(
                id: "anthropic", name: "Anthropic upstream",
                baseUrl: "https://anthropic.example/v1", authToken: "anthropic-secret",
                defaultModel: "claude-upstream", smallFastModel: "claude-fast",
                mapDefaultModels: false, protocol: .anthropic,
                models: [.init(alias: "claude-opus-4-8", upstream: "claude-upstream")]
            ),
            Provider(
                id: "chat", name: "Chat upstream",
                baseUrl: "https://chat.example/openai/v1", authToken: "chat-secret",
                defaultModel: "gpt-upstream", smallFastModel: "gpt-fast",
                protocol: .openAIChat,
                models: [.init(alias: "gpt-5.4", upstream: "gpt-upstream")]
            ),
            Provider(
                id: "responses", name: "Responses upstream",
                baseUrl: "https://responses.example/v1", authToken: "responses-secret",
                defaultModel: "responses-upstream", smallFastModel: "responses-fast",
                protocol: .openAIResponses
            ),
        ]
        config.activeProviderId = "chat"
        config.gatewayFailover = .init(
            enabled: true,
            providerIds: ["chat", "responses", "anthropic"]
        )
        config.retry429 = .init(enabled: true, max: 4, baseMs: 750)
        config.insecureSkipVerify = true

        let output = try GatewayConfigBuilder.build(
            from: config,
            managementCredentials: credentials
        )

        XCTAssertEqual(output.publicPort, 19_876)
        XCTAssertEqual(output.management.port, 0)
        XCTAssertEqual(output.management.bearerToken, credentials.bearerToken)
        XCTAssertEqual(output.activeProviderId, "chat")
        XCTAssertEqual(output.providers.map(\.id), ["anthropic", "chat", "responses"])
        XCTAssertEqual(output.providers.map(\.protocol), [
            "anthropic", "openai-chat", "openai-responses",
        ])
        XCTAssertEqual(output.providers[0].models, config.providers[0].models)
        XCTAssertFalse(output.providers[0].mapDefaultModels)
        XCTAssertTrue(output.providers.allSatisfy(\.enabled))
        XCTAssertTrue(output.providers.allSatisfy { $0.headers.isEmpty })
        XCTAssertTrue(output.providers.allSatisfy { $0.timeoutSeconds == 600 })
        XCTAssertTrue(output.failover.enabled)
        XCTAssertEqual(output.failover.providerIds, ["chat", "responses", "anthropic"])
        XCTAssertEqual(output.retry, .init(
            enabled: true,
            maxRetries: 4,
            baseMs: 750,
            maxBackoffMs: 30_000
        ))
        XCTAssertTrue(output.insecureSkipVerify)
    }

    func testEncodingUsesGatewayHelpersCamelCaseSchema() throws {
        let output = try GatewayConfigBuilder.build(
            from: .fixture,
            managementCredentials: credentials
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any]
        )
        XCTAssertNotNil(object["publicPort"])
        XCTAssertNotNil(object["activeProviderId"])
        XCTAssertNotNil(object["circuitBreaker"])
        XCTAssertNotNil(object["requestBodyLimitBytes"])
        XCTAssertNil(object["public_port"])

        let management = try XCTUnwrap(object["management"] as? [String: Any])
        XCTAssertEqual(management["port"] as? Int, 0)
        XCTAssertEqual(management["bearerToken"] as? String, credentials.bearerToken)
        let provider = try XCTUnwrap((object["providers"] as? [[String: Any]])?.first)
        XCTAssertEqual(provider["baseUrl"] as? String, AppConfig.fixture.providers[0].baseUrl)
        XCTAssertEqual(provider["authToken"] as? String, AppConfig.fixture.providers[0].authToken)
        XCTAssertEqual(provider["defaultModel"] as? String, AppConfig.fixture.providers[0].defaultModel)
    }

    func testUnknownActiveProviderFallsBackToFirstProvider() throws {
        var config = AppConfig.fixture
        config.activeProviderId = "missing"
        config.providers.append(Provider(
            id: "second", name: "Second", baseUrl: "https://second.example/v1"
        ))

        let output = try GatewayConfigBuilder.build(
            from: config,
            managementCredentials: credentials
        )
        XCTAssertEqual(output.activeProviderId, config.providers[0].id)
    }

    func testBuilderFiltersQueueWithoutPrependingActiveProviderOrMutatingAppConfig() throws {
        var config = AppConfig.fixture
        config.providers.append(Provider(
            id: "second", name: "Second", baseUrl: "https://second.example/v1"
        ))
        config.gatewayFailover = .init(
            enabled: true,
            providerIds: ["missing", "second", "second"]
        )

        let output = try GatewayConfigBuilder.build(
            from: config,
            managementCredentials: credentials
        )

        XCTAssertTrue(output.failover.enabled)
        XCTAssertEqual(output.failover.providerIds, ["second"])
        XCTAssertEqual(config.gatewayFailover.providerIds, ["missing", "second", "second"])
    }

    func testBuilderRejectsAnEnabledEmptyFailoverQueue() throws {
        var config = AppConfig.fixture
        config.providers.append(Provider(
            id: "second", name: "Second", baseUrl: "https://second.example/v1"
        ))
        config.gatewayFailover = .init(enabled: true, providerIds: [])

        XCTAssertThrowsError(try GatewayConfigBuilder.build(
            from: config,
            managementCredentials: credentials
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .noFailoverProviders)
        }
    }

    func testRetryValuesAreClampedToHelperSafetyLimits() throws {
        var config = AppConfig.fixture
        config.retry429 = .init(enabled: true, max: 99, baseMs: 99_999)
        let maximum = try GatewayConfigBuilder.build(
            from: config,
            managementCredentials: credentials
        )
        XCTAssertEqual(maximum.retry.maxRetries, 10)
        XCTAssertEqual(maximum.retry.baseMs, 10_000)
        XCTAssertEqual(maximum.retry.maxBackoffMs, 30_000)

        config.retry429 = .init(enabled: false, max: -3, baseMs: -1)
        let minimum = try GatewayConfigBuilder.build(
            from: config,
            managementCredentials: credentials
        )
        XCTAssertFalse(minimum.retry.enabled)
        XCTAssertEqual(minimum.retry.maxRetries, 0)
        XCTAssertEqual(minimum.retry.baseMs, 0)
        XCTAssertEqual(minimum.retry.maxBackoffMs, 30_000)
    }

    func testRejectsMissingProviderInvalidPortAndMissingInferenceToken() {
        XCTAssertThrowsError(try GatewayConfigBuilder.build(
            from: AppConfig(), managementCredentials: credentials
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .noActiveProvider)
        }

        var invalidPort = AppConfig.fixture
        invalidPort.port = 0
        XCTAssertThrowsError(try GatewayConfigBuilder.build(
            from: invalidPort, managementCredentials: credentials
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .invalidPort(0))
        }

        var missingToken = AppConfig.fixture
        missingToken.requireToken = true
        missingToken.gatewayToken = " \n\t "
        XCTAssertThrowsError(try GatewayConfigBuilder.build(
            from: missingToken, managementCredentials: credentials
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .missingGatewayToken)
        }
    }

    func testRejectsDuplicateOrIncompleteProviders() {
        var duplicate = AppConfig.fixture
        duplicate.providers.append(Provider(
            id: duplicate.providers[0].id,
            name: "Duplicate",
            baseUrl: "https://duplicate.example/v1"
        ))
        XCTAssertThrowsError(try GatewayConfigBuilder.build(
            from: duplicate, managementCredentials: credentials
        )) { error in
            XCTAssertEqual(
                error as? GatewayConfigurationError,
                .duplicateProviderID(duplicate.providers[0].id)
            )
        }

        var incomplete = AppConfig.fixture
        incomplete.providers[0].name = "  "
        XCTAssertThrowsError(try GatewayConfigBuilder.build(
            from: incomplete, managementCredentials: credentials
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .invalidProvider(incomplete.providers[0].id))
        }
    }

    func testRejectsUnsafeProviderBaseURLs() {
        for rawURL in [
            "file:///tmp/socket", "ftp://provider.example/v1",
            "https://user:password@provider.example/v1", "https://provider.example/v1#fragment",
            "not a url",
        ] {
            var config = AppConfig.fixture
            config.providers[0].baseUrl = rawURL
            XCTAssertThrowsError(try GatewayConfigBuilder.build(
                from: config, managementCredentials: credentials
            ), "Expected unsafe base URL to fail: \(rawURL)") { error in
                XCTAssertEqual(
                    error as? GatewayConfigurationError,
                    .invalidBaseURL(config.providers[0].name)
                )
            }
        }
    }

    func testGeneratedManagementCredentialsAreUniqueStrongAndRedacted() {
        let first = GatewayManagementCredentials.generate()
        let second = GatewayManagementCredentials.generate()

        XCTAssertNotEqual(first.bearerToken, second.bearerToken)
        XCTAssertGreaterThanOrEqual(first.bearerToken.count, 64)
        XCTAssertEqual(first.authorizationHeader, "Bearer \(first.bearerToken)")
        XCTAssertFalse(first.description.contains(first.bearerToken))
        XCTAssertFalse(first.debugDescription.contains(first.bearerToken))
    }
}
