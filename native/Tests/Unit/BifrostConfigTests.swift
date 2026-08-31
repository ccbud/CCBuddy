import XCTest
@testable import CCBuddy

final class BifrostConfigTests: XCTestCase {
    private let managementCredentials = BifrostManagementCredentials(
        username: "unit-admin",
        password: "Unit-Test9!Password"
    )

    func testBuildsSingleActiveCustomProviderAndTierAliases() throws {
        let output = try BifrostConfigBuilder.build(
            from: .fixture,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/ccbud-test-logs.db"),
            managementCredentials: managementCredentials
        )
        let provider = try XCTUnwrap(output.providers[BifrostConfigBuilder.providerName])
        XCTAssertTrue(output.configStore.enabled)
        XCTAssertEqual(output.configStore.type, "sqlite")
        XCTAssertEqual(output.configStore.config?["path"], "/tmp/config.db")
        XCTAssertEqual(
            URL(string: output.framework.pricing.modelParametersURL)?.path,
            "/tmp/model-parameters.json"
        )
        XCTAssertEqual(output.sourceOfTruth, "config.json")
        XCTAssertFalse(output.client.enforceAuthOnInference)
        XCTAssertTrue(output.client.allowedOrigins.isEmpty)
        XCTAssertTrue(output.governance.authConfig.isEnabled)
        XCTAssertTrue(output.governance.virtualKeys.isEmpty)
        XCTAssertEqual(output.governance.authConfig.adminUsername.value, managementCredentials.username)
        XCTAssertEqual(output.governance.authConfig.adminPassword.value, managementCredentials.password)
        XCTAssertEqual(provider.customProviderConfig.baseProviderType, "anthropic")
        XCTAssertTrue(provider.customProviderConfig.allowedRequests.chatCompletion)
        XCTAssertTrue(provider.customProviderConfig.allowedRequests.chatCompletionStream)
        XCTAssertTrue(provider.customProviderConfig.allowedRequests.responses)
        XCTAssertTrue(provider.customProviderConfig.allowedRequests.responsesStream)
        XCTAssertTrue(provider.customProviderConfig.allowedRequests.countTokens)
        XCTAssertFalse(output.client.compat.convertChatToResponses)
        XCTAssertEqual(provider.networkConfig.baseURL, "https://open.bigmodel.cn/api/anthropic/v1")
        XCTAssertEqual(provider.networkConfig.maxRetries, 3)
        XCTAssertEqual(provider.networkConfig.retryBackoffInitial, 500)
        XCTAssertEqual(provider.networkConfig.retryBackoffMax, 4_000)
        XCTAssertTrue(provider.storeRawRequestResponse)
        XCTAssertEqual(provider.keys.first?.aliases["claude-opus-4-8"], "glm-5.2")
        XCTAssertEqual(provider.keys.first?.aliases["gpt-5.5-ccbud"], "glm-5.2")
    }

    func testRawMonitorPayloadsUseMinimumSQLiteRetentionAtClientLevel() throws {
        let output = try BifrostConfigBuilder.build(
            from: .fixture,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/ccbud-test-logs.db"),
            managementCredentials: managementCredentials
        )

        XCTAssertTrue(try XCTUnwrap(
            output.providers[BifrostConfigBuilder.providerName]
        ).storeRawRequestResponse)
        XCTAssertEqual(output.client.logRetentionDays, 1)
        XCTAssertEqual(output.client.logRetentionDays, BifrostConfigBuilder.logRetentionDays)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any]
        )
        let client = try XCTUnwrap(object["client"] as? [String: Any])
        XCTAssertEqual(client["log_retention_days"] as? Int, 1)
        let logsStore = try XCTUnwrap(object["logs_store"] as? [String: Any])
        XCTAssertNil(
            logsStore["retention_days"],
            "SQLite retention is controlled by client.log_retention_days in Bifrost v1.6.11"
        )
    }

    func testExplicitAliasWinsOverDefaultTierMapping() throws {
        var config = AppConfig.fixture
        config.providers[0].models = [.init(alias: "claude-opus-4-8", upstream: "special")]
        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        XCTAssertEqual(output.providers[BifrostConfigBuilder.providerName]?.keys[0].aliases["claude-opus-4-8"], "special")
    }

    func testRejectsMissingProvider() {
        XCTAssertThrowsError(try BifrostConfigBuilder.build(
            from: AppConfig(),
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        ))
    }

    func testDuplicateAliasesUseFirstConfiguredMappingWithoutCrashing() throws {
        var config = AppConfig.fixture
        config.providers[0].models = [
            .init(alias: "same", upstream: "first"),
            .init(alias: "same", upstream: "second"),
        ]
        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        XCTAssertEqual(output.providers[BifrostConfigBuilder.providerName]?.keys[0].aliases["same"], "first")
    }

    func testExplicitAliasWinsWhenItsNameMatchesDefaultOrFastModel() throws {
        var config = AppConfig.fixture
        config.providers[0].defaultModel = "primary-name"
        config.providers[0].smallFastModel = "fast-name"
        config.providers[0].models = [
            .init(alias: "primary-name", upstream: "explicit-primary"),
            .init(alias: "fast-name", upstream: "explicit-fast"),
        ]
        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        let aliases = output.providers[BifrostConfigBuilder.providerName]?.keys[0].aliases
        XCTAssertEqual(aliases?["primary-name"], "explicit-primary")
        XCTAssertEqual(aliases?["fast-name"], "explicit-fast")
    }

    func testDisabledRetryWritesZeroBudgetAndSchemaSafeBackoff() throws {
        var config = AppConfig.fixture
        config.retry429.enabled = false
        config.retry429.max = 9
        config.retry429.baseMs = 0
        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        let network = try XCTUnwrap(output.providers[BifrostConfigBuilder.providerName]?.networkConfig)
        XCTAssertEqual(network.maxRetries, 0)
        XCTAssertEqual(network.retryBackoffInitial, 100)
        XCTAssertEqual(network.retryBackoffMax, 100)
    }

    func testEncodesBifrostReconciliationAndRetryFieldsAtDocumentedLevels() throws {
        let output = try BifrostConfigBuilder.build(
            from: .fixture,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any]
        )
        XCTAssertEqual(object["source_of_truth"] as? String, "config.json")
        let framework = try XCTUnwrap(object["framework"] as? [String: Any])
        let pricing = try XCTUnwrap(framework["pricing"] as? [String: Any])
        let modelParametersURL = try XCTUnwrap(pricing["model_parameters_url"] as? String)
        let modelParametersComponents = try XCTUnwrap(URLComponents(string: modelParametersURL))
        XCTAssertEqual(modelParametersComponents.scheme, "file")
        XCTAssertEqual(modelParametersComponents.path, "/tmp/model-parameters.json")
        XCTAssertEqual(modelParametersComponents.queryItems?.map(\.name), ["revision"])
        XCTAssertFalse(modelParametersComponents.queryItems?.first?.value?.isEmpty ?? true)
        let providers = try XCTUnwrap(object["providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers[BifrostConfigBuilder.providerName] as? [String: Any])
        let network = try XCTUnwrap(provider["network_config"] as? [String: Any])
        XCTAssertEqual(network["max_retries"] as? Int, 3)
        XCTAssertEqual(network["retry_backoff_initial"] as? Int, 500)
        XCTAssertEqual(network["retry_backoff_max"] as? Int, 4_000)
        XCTAssertEqual(provider["store_raw_request_response"] as? Bool, true)
        let governance = try XCTUnwrap(object["governance"] as? [String: Any])
        let auth = try XCTUnwrap(governance["auth_config"] as? [String: Any])
        XCTAssertEqual(auth["admin_username"] as? String, managementCredentials.username)
        XCTAssertEqual(auth["admin_password"] as? String, managementCredentials.password)
        XCTAssertEqual(auth["is_enabled"] as? Bool, true)
        XCTAssertNil(object["auth_config"], "Use the non-deprecated governance.auth_config")
        XCTAssertNil(object["max_retries"])
        let client = try XCTUnwrap(object["client"] as? [String: Any])
        XCTAssertEqual(Set(client.keys), [
            "allowed_origins", "compat", "enforce_auth_on_inference", "log_retention_days",
        ])
        XCTAssertEqual(client["enforce_auth_on_inference"] as? Bool, false)
        XCTAssertEqual(client["log_retention_days"] as? Int, 1)
        XCTAssertTrue((client["allowed_origins"] as? [Any])?.isEmpty == true)
        let compat = try XCTUnwrap(client["compat"] as? [String: Any])
        XCTAssertEqual(compat["convert_chat_to_responses"] as? Bool, false)
        XCTAssertEqual(compat["convert_text_to_chat"] as? Bool, false)
        XCTAssertEqual(compat["should_drop_params"] as? Bool, false)
        XCTAssertEqual(compat["should_convert_params"] as? Bool, false)
        let custom = try XCTUnwrap(provider["custom_provider_config"] as? [String: Any])
        let allowed = try XCTUnwrap(custom["allowed_requests"] as? [String: Any])
        XCTAssertEqual(allowed["chat_completion"] as? Bool, true)
        XCTAssertEqual(allowed["chat_completion_stream"] as? Bool, true)
        XCTAssertEqual(allowed["responses"] as? Bool, true)
        XCTAssertEqual(allowed["responses_stream"] as? Bool, true)
        XCTAssertEqual(allowed["compaction"] as? Bool, false)
        XCTAssertTrue((governance["virtual_keys"] as? [Any])?.isEmpty == true)
    }

    func testRequireTokenBuildsOneActivePrefixedVirtualKeyWithNarrowProviderAccess() throws {
        var config = AppConfig.fixture
        config.requireToken = true
        config.gatewayToken = "ccbud_legacy-token"

        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )

        XCTAssertTrue(output.client.enforceAuthOnInference)
        XCTAssertTrue(output.client.allowedOrigins.isEmpty)
        let virtualKey = try XCTUnwrap(output.governance.virtualKeys.only)
        XCTAssertEqual(virtualKey.id, BifrostConfigBuilder.virtualKeyID)
        XCTAssertEqual(virtualKey.name, BifrostConfigBuilder.virtualKeyName)
        XCTAssertEqual(virtualKey.value.value, "sk-bf-ccbud_legacy-token")
        XCTAssertTrue(virtualKey.isActive)
        XCTAssertTrue(virtualKey.mcpConfigs.isEmpty)
        let provider = try XCTUnwrap(virtualKey.providerConfigs.only)
        XCTAssertEqual(provider.provider, BifrostConfigBuilder.providerName)
        XCTAssertEqual(provider.weight, 1)
        XCTAssertEqual(provider.allowedModels, ["*"])
        XCTAssertTrue(provider.blacklistedModels.isEmpty)
        XCTAssertEqual(provider.keyIDs, ["*"])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any]
        )
        let client = try XCTUnwrap(object["client"] as? [String: Any])
        XCTAssertEqual(Set(client.keys), [
            "allowed_origins", "compat", "enforce_auth_on_inference", "log_retention_days",
        ])
        XCTAssertEqual(client["enforce_auth_on_inference"] as? Bool, true)
        XCTAssertEqual(client["log_retention_days"] as? Int, 1)
        XCTAssertTrue((client["allowed_origins"] as? [Any])?.isEmpty == true)
        let governance = try XCTUnwrap(object["governance"] as? [String: Any])
        let encodedVirtualKeys = try XCTUnwrap(governance["virtual_keys"] as? [[String: Any]])
        let encodedVirtualKey = try XCTUnwrap(encodedVirtualKeys.only)
        XCTAssertEqual(encodedVirtualKey["value"] as? String, "sk-bf-ccbud_legacy-token")
        XCTAssertEqual(encodedVirtualKey["is_active"] as? Bool, true)
        let encodedProviders = try XCTUnwrap(
            encodedVirtualKey["provider_configs"] as? [[String: Any]]
        )
        let encodedProvider = try XCTUnwrap(encodedProviders.only)
        XCTAssertEqual(Set(encodedProvider.keys), [
            "provider", "weight", "allowed_models", "blacklisted_models", "key_ids",
        ])
        XCTAssertEqual(encodedProvider["provider"] as? String, BifrostConfigBuilder.providerName)
        XCTAssertEqual((encodedProvider["weight"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(encodedProvider["allowed_models"] as? [String], ["*"])
        XCTAssertTrue((encodedProvider["blacklisted_models"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(encodedProvider["key_ids"] as? [String], ["*"])
    }

    func testOpenAIChatCapabilitiesTriggerResponsesFallbackWithoutClaimingResponsesSupport() throws {
        var config = AppConfig.fixture
        config.providers[0].protocol = .openAIChat

        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        let provider = try XCTUnwrap(output.providers[BifrostConfigBuilder.providerName])
        let allowed = provider.customProviderConfig.allowedRequests

        XCTAssertEqual(provider.customProviderConfig.baseProviderType, "openai")
        XCTAssertTrue(allowed.chatCompletion)
        XCTAssertTrue(allowed.chatCompletionStream)
        XCTAssertFalse(allowed.responses)
        XCTAssertFalse(allowed.responsesStream)
        XCTAssertFalse(allowed.compaction)
        XCTAssertFalse(output.client.compat.convertChatToResponses)
    }

    func testOpenAIResponsesCapabilitiesIncludeLifecycleAndEnableCompatibleChatConversion() throws {
        var config = AppConfig.fixture
        config.providers[0].protocol = .openAIResponses

        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        let provider = try XCTUnwrap(output.providers[BifrostConfigBuilder.providerName])
        let allowed = provider.customProviderConfig.allowedRequests

        XCTAssertEqual(provider.customProviderConfig.baseProviderType, "openai")
        XCTAssertFalse(allowed.chatCompletion)
        XCTAssertFalse(allowed.chatCompletionStream)
        XCTAssertTrue(allowed.responses)
        XCTAssertTrue(allowed.responsesStream)
        XCTAssertTrue(allowed.responsesRetrieve)
        XCTAssertTrue(allowed.responsesDelete)
        XCTAssertTrue(allowed.responsesCancel)
        XCTAssertTrue(allowed.responsesInputItems)
        XCTAssertTrue(allowed.countTokens)
        XCTAssertTrue(allowed.compaction)
        XCTAssertTrue(allowed.webSocketResponses)
        XCTAssertTrue(output.client.compat.convertChatToResponses)
    }

    func testLocalModelParametersCatalogMarksEveryConfiguredResponsesAliasAndUpstream() throws {
        var config = AppConfig.fixture
        config.providers[0].protocol = .openAIResponses
        config.providers[0].defaultModel = " upstream-primary "
        config.providers[0].smallFastModel = "upstream-fast"
        config.providers[0].models = [
            .init(alias: "custom-alias", upstream: "custom-upstream"),
        ]

        let data = try BifrostConfigBuilder.modelParametersData(from: config)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        )
        for model in [
            "upstream-primary", "upstream-fast", "custom-alias", "custom-upstream",
            "gpt-5.4", "gpt-5.4-mini", "claude-opus-4-8", "claude-haiku-4-5",
        ] {
            let entry = try XCTUnwrap(document[model], "Missing deterministic catalog entry for \(model)")
            XCTAssertEqual(entry["mode"] as? String, "responses")
            XCTAssertEqual(entry["supported_endpoints"] as? [String], ["/v1/responses"])
        }
        XCTAssertNil(document[" upstream-primary "])
    }

    func testResponsesChatConversionIsDisabledWhenNoConfiguredModelCanBeCatalogued() throws {
        var config = AppConfig.fixture
        config.providers[0].protocol = .openAIResponses
        config.providers[0].defaultModel = ""
        config.providers[0].smallFastModel = ""
        config.providers[0].models = []

        let output = try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )
        XCTAssertFalse(output.client.compat.convertChatToResponses)
        XCTAssertEqual(String(decoding: try BifrostConfigBuilder.modelParametersData(from: config), as: UTF8.self), "{}")
    }

    func testNormalizeInferenceTokenIsPurePrefixMigrationAndRejectsEmptyInput() {
        XCTAssertNil(normalizeInferenceToken(""))
        XCTAssertNil(normalizeInferenceToken(" \n\t "))
        XCTAssertEqual(normalizeInferenceToken("sk-bf-already-valid"), "sk-bf-already-valid")
        XCTAssertEqual(normalizeInferenceToken(" ccbud_old-token "), "sk-bf-ccbud_old-token")
    }

    func testRequireTokenRejectsMissingTokenInsteadOfLettingBifrostGenerateAnUnknownKey() {
        var config = AppConfig.fixture
        config.requireToken = true
        config.gatewayToken = "  "

        XCTAssertThrowsError(try BifrostConfigBuilder.build(
            from: config,
            logDatabaseURL: URL(fileURLWithPath: "/tmp/logs.db"),
            managementCredentials: managementCredentials
        )) { error in
            XCTAssertEqual(error as? BifrostConfigBuilder.BuildError, .missingInferenceToken)
        }
    }

    func testGeneratedManagementCredentialsAreStrongUniqueAndTextuallyRedacted() throws {
        let first = BifrostManagementCredentials.generate()
        let second = BifrostManagementCredentials.generate()

        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.password.utf8.count, 12)
        XCTAssertNotNil(first.password.range(of: #"[A-Z]"#, options: .regularExpression))
        XCTAssertNotNil(first.password.range(of: #"[a-z]"#, options: .regularExpression))
        XCTAssertNotNil(first.password.range(of: #"[0-9]"#, options: .regularExpression))
        XCTAssertNotNil(first.password.range(of: #"[^A-Za-z0-9]"#, options: .regularExpression))

        let encoded = try XCTUnwrap(first.basicAuthorizationHeader.split(separator: " ").last)
        let decoded = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        XCTAssertTrue(String(decoding: decoded, as: UTF8.self) == "\(first.username):\(first.password)")
        XCTAssertFalse(first.description.contains(first.username))
        XCTAssertFalse(first.description.contains(first.password))
        XCTAssertEqual(first.description, first.debugDescription)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
