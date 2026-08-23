import CryptoKit
import Darwin
import XCTest
@testable import CCBuddy

final class BifrostSupervisorIntegrationTests: XCTestCase {
    private static let pinnedBifrostSHA256 =
        "422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263"

    func testPinnedBifrostStartsWithGeneratedConfiguration() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock { await supervisor.stop() }
        let managementCredentials = supervisor.managementCredentials

        let runningState = await supervisor.state
        XCTAssertEqual(runningState, .running(port: config.port))
        let initialDiagnostics = await supervisor.diagnostics
        XCTAssertFalse(initialDiagnostics.standardOutput.contains(managementCredentials.username))
        XCTAssertFalse(initialDiagnostics.standardOutput.contains(managementCredentials.password))
        XCTAssertFalse(initialDiagnostics.standardError.contains(managementCredentials.username))
        XCTAssertFalse(initialDiagnostics.standardError.contains(managementCredentials.password))
        let health = URL(string: "http://127.0.0.1:\(config.port)/health")!
        let (data, response) = try await URLSession.shared.data(from: health)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""status":"ok""#))

        let unauthenticatedStatus = try await managementStatus(
            port: config.port,
            authorization: nil
        )
        XCTAssertEqual(unauthenticatedStatus, 401)
        let wrongCredentialsStatus = try await managementStatus(
            port: config.port,
            authorization: BifrostManagementCredentials(
                username: "wrong-admin",
                password: "Wrong-Admin9!Password"
            ).basicAuthorizationHeader
        )
        XCTAssertEqual(wrongCredentialsStatus, 401)
        let authenticatedStatus = try await managementStatus(
            port: config.port,
            authorization: managementCredentials.basicAuthorizationHeader
        )
        XCTAssertEqual(authenticatedStatus, 200)

        let firstNetwork = try await providerNetwork(
            port: config.port,
            credentials: managementCredentials
        )
        XCTAssertEqual(
            firstNetwork["base_url"] as? String,
            "https://open.bigmodel.cn/api/anthropic/v1"
        )
        XCTAssertEqual(firstNetwork["max_retries"] as? Int, 3)
        let storeDirectory = root.appendingPathComponent("bifrost", isDirectory: true)
        try assertPrivatePermissions(at: storeDirectory, expected: 0o700)
        try assertPrivatePermissions(
            at: storeDirectory.appendingPathComponent("config.json"),
            expected: 0o600
        )
        try assertPrivatePermissions(
            at: storeDirectory.appendingPathComponent(BifrostConfigBuilder.modelParametersFileName),
            expected: 0o600
        )
        try assertPrivatePermissions(at: storeDirectory.appendingPathComponent("config.db"), expected: 0o600)
        try assertPrivatePermissions(at: storeDirectory.appendingPathComponent("logs.db"), expected: 0o600)

        // The SQLite config store survives a helper restart. `source_of_truth=config.json`
        // must therefore replace the stored provider values instead of resurrecting the
        // first launch's configuration.
        config.providers[0].baseUrl = "http://127.0.0.1:9/reconfigured"
        config.retry429.enabled = false
        try await supervisor.start(config: config)
        XCTAssertTrue(supervisor.managementCredentials == managementCredentials)
        let restartedCredentialsStatus = try await managementStatus(
            port: config.port,
            authorization: managementCredentials.basicAuthorizationHeader
        )
        XCTAssertEqual(restartedCredentialsStatus, 200)
        let restartedDiagnostics = await supervisor.diagnostics
        XCTAssertFalse(restartedDiagnostics.standardOutput.contains(managementCredentials.username))
        XCTAssertFalse(restartedDiagnostics.standardOutput.contains(managementCredentials.password))
        XCTAssertFalse(restartedDiagnostics.standardError.contains(managementCredentials.username))
        XCTAssertFalse(restartedDiagnostics.standardError.contains(managementCredentials.password))
        let restartedNetwork = try await providerNetwork(
            port: config.port,
            credentials: managementCredentials
        )
        XCTAssertEqual(
            restartedNetwork["base_url"] as? String,
            "http://127.0.0.1:9/reconfigured"
        )
        XCTAssertEqual(restartedNetwork["max_retries"] as? Int, 0)

        await supervisor.stop()
        let stoppedState = await supervisor.state
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testInferenceTokenEnforcementAndAuthoritativeDisableAgainstMockUpstream() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let upstream = try LoopbackAnthropicMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-auth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.retry429.enabled = false
        config.requireToken = true
        config.gatewayToken = "legacy-e2e-token"
        let inferenceToken = try XCTUnwrap(normalizeInferenceToken(config.gatewayToken))
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let enabledVirtualKeyCount = try await configuredVirtualKeyCount(
            port: config.port,
            credentials: supervisor.managementCredentials
        )
        XCTAssertEqual(enabledVirtualKeyCount, 1)

        let noToken = try await openAIInference(port: config.port, token: nil)
        XCTAssertEqual(noToken.statusCode, 401)
        let wrongToken = try await openAIInference(port: config.port, token: "sk-bf-wrong")
        XCTAssertEqual(wrongToken.statusCode, 401)
        XCTAssertTrue(upstream.messageRequestTargets.isEmpty)

        let bearerResult = try await openAIInference(port: config.port, token: inferenceToken)
        XCTAssertEqual(bearerResult.statusCode, 200)
        XCTAssertTrue(bearerResult.body.contains(LoopbackAnthropicMock.responseMarker))

        let anthropicResult = try await anthropicInference(
            port: config.port,
            xAPIKey: inferenceToken
        )
        XCTAssertEqual(anthropicResult.statusCode, 200)
        XCTAssertTrue(anthropicResult.body.contains(LoopbackAnthropicMock.responseMarker))
        XCTAssertEqual(upstream.messageRequestTargets, ["/v1/messages", "/v1/messages"])

        let blockedCORS = try await corsPreflight(
            port: config.port,
            origin: "https://attacker.example"
        )
        XCTAssertEqual(blockedCORS.statusCode, 403)
        XCTAssertNil(blockedCORS.allowedOrigin)
        let localhostCORS = try await corsPreflight(
            port: config.port,
            origin: "http://localhost:4321"
        )
        XCTAssertEqual(localhostCORS.statusCode, 200)
        XCTAssertEqual(localhostCORS.allowedOrigin, "http://localhost:4321")

        // Reuse the SQLite store to prove the explicit empty virtual_keys collection is
        // authoritative: disabling the feature both removes the persisted VK and permits an
        // unauthenticated inference request to reach the same upstream.
        config.requireToken = false
        config.gatewayToken = ""
        try await supervisor.start(config: config)
        let disabledVirtualKeyCount = try await configuredVirtualKeyCount(
            port: config.port,
            credentials: supervisor.managementCredentials
        )
        XCTAssertEqual(disabledVirtualKeyCount, 0)
        let disabledResult = try await openAIInference(port: config.port, token: nil)
        XCTAssertEqual(disabledResult.statusCode, 200)
        XCTAssertTrue(disabledResult.body.contains(LoopbackAnthropicMock.responseMarker))
        XCTAssertEqual(upstream.messageRequestTargets, [
            "/v1/messages", "/v1/messages", "/v1/messages",
        ])
        await supervisor.stop()
    }

    func testOpenAIChatProtocolConvertsResponsesAndStreamingOnTheRealSidecar() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let upstream = try LoopbackOpenAIChatMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-chat-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIChat
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.retry429.enabled = false
        config.requireToken = false
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let unary = try await responsesInference(port: config.port, stream: false, tools: false)
        XCTAssertEqual(unary.statusCode, 200, unary.body)
        XCTAssertTrue(unary.body.contains(LoopbackOpenAIChatMock.responseMarker), unary.body)
        XCTAssertTrue(unary.body.contains(#""object":"response""#), unary.body)

        let streaming = try await responsesInference(port: config.port, stream: true, tools: false)
        XCTAssertEqual(streaming.statusCode, 200, streaming.body)
        XCTAssertTrue(streaming.body.contains(LoopbackOpenAIChatMock.streamMarker), streaming.body)
        XCTAssertTrue(streaming.body.contains("response.output_text.delta"), streaming.body)
        XCTAssertTrue(streaming.body.contains("response.completed"), streaming.body)

        let tool = try await responsesInference(port: config.port, stream: false, tools: true)
        XCTAssertEqual(tool.statusCode, 200, tool.body)
        XCTAssertTrue(tool.body.contains(#""type":"function_call""#), tool.body)
        XCTAssertTrue(tool.body.contains(#""name":"lookup_weather""#), tool.body)

        XCTAssertEqual(upstream.chatCompletionTargets, [
            "/v1/chat/completions", "/v1/chat/completions", "/v1/chat/completions",
        ])
        let bodies = upstream.chatCompletionBodies
        XCTAssertEqual(bodies.count, 3)
        for body in bodies {
            XCTAssertNotNil(body["messages"] as? [Any], "Responses input was not converted: \(body)")
            XCTAssertNil(body["input"], "Responses wire field leaked to Chat upstream: \(body)")
        }
        XCTAssertFalse((bodies[0]["stream"] as? Bool) ?? false)
        XCTAssertEqual(bodies[1]["stream"] as? Bool, true)
        XCTAssertFalse((bodies[2]["stream"] as? Bool) ?? false)
        XCTAssertNotNil(bodies[2]["tools"] as? [Any])
        await supervisor.stop()
    }

    func testCodexCLIUsesNativeResponsesThroughPinnedBifrostWithoutUserCredentials() async throws {
        let bifrostBinary = try pinnedRepositoryBifrostBinaryPath()
        guard let codexBinary = codexBinaryPath() else {
            throw XCTSkip("Install Codex CLI or set CCBUD_CODEX_BINARY to run the CLI integration test")
        }

        let upstream = try ResponsesWireMock()
        upstream.start()
        defer { upstream.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-codex-native-responses-\(UUID().uuidString)", isDirectory: true)
        let ccbudHome = root.appendingPathComponent("ccbud-home", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let isolatedHome = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [ccbudHome, codexHome, isolatedHome, temporary, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let upstreamToken = "sk-ccbud-native-responses-upstream-e2e"
        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIResponses
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].authToken = upstreamToken
        config.providers[0].defaultModel = "gpt-5.4"
        config.providers[0].smallFastModel = ""
        config.providers[0].mapDefaultModels = false
        config.providers[0].models = []
        config.retry429.enabled = false
        config.requireToken = false

        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": ccbudHome.path,
            "CCBUD_BIFROST_BINARY": bifrostBinary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let providerID = "ccbud_native_responses_e2e"
        let providerAPIKeyEnvironment = "CCBUD_CODEX_NATIVE_RESPONSES_E2E_API_KEY"
        let codexConfiguration = """
        model = "gpt-5.4"
        model_provider = "\(providerID)"
        model_reasoning_effort = "low"
        approval_policy = "never"
        sandbox_mode = "read-only"
        cli_auth_credentials_store = "file"

        [model_providers.\(providerID)]
        name = "CC Buddy native Responses E2E"
        base_url = "http://127.0.0.1:\(config.port)/v1"
        env_key = "\(providerAPIKeyEnvironment)"
        requires_openai_auth = false
        wire_api = "responses"
        request_max_retries = 0
        stream_max_retries = 0
        """
        try Data(codexConfiguration.utf8).write(
            to: codexHome.appendingPathComponent("config.toml"),
            options: .atomic
        )

        let codexEnvironment = [
            "CODEX_HOME": codexHome.path,
            "HOME": isolatedHome.path,
            "NO_COLOR": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workspace.path,
            "TMPDIR": temporary.path + "/",
            "XDG_CACHE_HOME": isolatedHome.appendingPathComponent(".cache", isDirectory: true).path,
            "XDG_CONFIG_HOME": isolatedHome.appendingPathComponent(".config", isDirectory: true).path,
            providerAPIKeyEnvironment: "sk-ccbud-loopback-codex-e2e",
        ]
        XCTAssertEqual(
            Set(codexEnvironment.keys.filter { $0.contains("API_KEY") || $0.contains("TOKEN") }),
            [providerAPIKeyEnvironment],
            "The isolated Codex process must receive only its dummy custom-provider credential"
        )

        let userMarker = "CCBUD_NATIVE_RESPONSES_USER_7D2A91"
        let result = try runCodexCLI(
            executable: codexBinary,
            arguments: [
                "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only",
                "Reply exactly with \(ResponsesWireMock.streamMarker). Do not call tools. "
                    + "Request marker: \(userMarker)",
            ],
            environment: codexEnvironment,
            workingDirectory: workspace,
            outputDirectory: root,
            label: "native-responses"
        )
        addCodexEvidenceAttachments(result, label: "native-responses")

        XCTAssertFalse(result.timedOut, result.failureDescription)
        XCTAssertEqual(result.status, 0, result.failureDescription)
        XCTAssertTrue(
            result.standardOutput.contains(ResponsesWireMock.streamMarker),
            result.failureDescription
        )

        let responseRequests = upstream.requests.filter {
            $0.method == "POST"
                && $0.target.split(separator: "?", maxSplits: 1).first == "/v1/responses"
        }
        XCTAssertEqual(
            responseRequests.count,
            1,
            "Expected exactly one native Responses operation; all requests: \(upstream.requests.map { "\($0.method) \($0.target)" })"
        )
        if let request = responseRequests.first {
            XCTAssertEqual(request.target, "/v1/responses")
            XCTAssertEqual(request.authorization, "Bearer \(upstreamToken)")
            XCTAssertEqual(request.body["stream"] as? Bool, true)
            XCTAssertEqual(request.body["model"] as? String, "gpt-5.4")
            XCTAssertTrue(
                flattenedText(in: request.body["input"]).contains(userMarker),
                "Codex user input did not survive native Responses pass-through: \(request.body)"
            )
        }
        XCTAssertFalse(
            upstream.requests.contains {
                $0.target.split(separator: "?", maxSplits: 1).first == "/v1/chat/completions"
            },
            "The native Responses request was converted to Chat Completions"
        )

        await supervisor.stop()
        let stoppedState = await supervisor.state
        let hasActiveReaders = await supervisor.hasActiveOutputReaders
        XCTAssertEqual(stoppedState, .stopped)
        XCTAssertFalse(hasActiveReaders, "Bifrost output readers remained attached after stop")
    }

    func testCodexCLIResumePreservesHistoryThroughOpenAIChatSidecar() async throws {
        guard let bifrostBinary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        guard let codexBinary = codexBinaryPath() else {
            throw XCTSkip("Install Codex CLI or set CCBUD_CODEX_BINARY to run the CLI integration test")
        }

        let upstream = try LoopbackOpenAIChatMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-codex-resume-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIChat
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.retry429.enabled = false
        config.requireToken = false
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": bifrostBinary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let providerID = "ccbud_bifrost_e2e"
        let providerAPIKeyEnvironment = "CCBUD_CODEX_E2E_API_KEY"
        let codexConfiguration = """
        model = "gpt-5.4"
        model_provider = "\(providerID)"
        model_reasoning_effort = "low"
        approval_policy = "never"
        sandbox_mode = "read-only"

        [model_providers.\(providerID)]
        name = "CC Buddy pinned Bifrost E2E"
        base_url = "http://127.0.0.1:\(config.port)/v1"
        env_key = "\(providerAPIKeyEnvironment)"
        wire_api = "responses"
        """
        try Data(codexConfiguration.utf8).write(
            to: codexHome.appendingPathComponent("config.toml"),
            options: .atomic
        )

        var codexEnvironment = ProcessInfo.processInfo.environment
        codexEnvironment["CODEX_HOME"] = codexHome.path
        codexEnvironment[providerAPIKeyEnvironment] = "sk-ccbud-loopback-e2e"
        codexEnvironment["NO_COLOR"] = "1"

        let firstUserMarker = "CCBUD_E2E_FIRST_USER_58F34A"
        let secondUserMarker = "CCBUD_E2E_SECOND_USER_92C71D"
        let first = try runCodexCLI(
            executable: codexBinary,
            arguments: [
                "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only",
                "Reply briefly without tools. Preserve this marker: \(firstUserMarker)",
            ],
            environment: codexEnvironment,
            workingDirectory: root,
            outputDirectory: root,
            label: "first"
        )
        XCTAssertFalse(first.timedOut, first.failureDescription)
        XCTAssertEqual(first.status, 0, first.failureDescription)
        guard !first.timedOut, first.status == 0 else { return }
        XCTAssertTrue(
            first.standardOutput.contains(LoopbackOpenAIChatMock.streamMarker),
            first.failureDescription
        )
        let threadID = try XCTUnwrap(
            codexThreadID(fromJSONLines: first.standardOutput),
            "Codex did not emit thread.started: \(first.failureDescription)"
        )

        let second = try runCodexCLI(
            executable: codexBinary,
            arguments: [
                "exec", "resume", "--json", "--skip-git-repo-check", threadID,
                "Reply briefly without tools. Preserve this marker: \(secondUserMarker)",
            ],
            environment: codexEnvironment,
            workingDirectory: root,
            outputDirectory: root,
            label: "second"
        )
        XCTAssertFalse(second.timedOut, second.failureDescription)
        XCTAssertEqual(second.status, 0, second.failureDescription)
        guard !second.timedOut, second.status == 0 else { return }

        let bodies = upstream.chatCompletionBodies
        XCTAssertEqual(
            upstream.chatCompletionTargets,
            ["/v1/chat/completions", "/v1/chat/completions"],
            "Expected one upstream Chat request per Codex turn: \(bodies)"
        )
        guard bodies.count == 2 else { return }
        let secondMessages = try XCTUnwrap(
            bodies[1]["messages"] as? [[String: Any]],
            "Second Responses request was not materialized as Chat history: \(bodies[1])"
        )
        let firstUserIndex = try XCTUnwrap(messageIndex(
            role: "user", containing: firstUserMarker, in: secondMessages
        ))
        let assistantIndex = try XCTUnwrap(messageIndex(
            role: "assistant", containing: LoopbackOpenAIChatMock.streamMarker,
            in: secondMessages
        ))
        let secondUserIndex = try XCTUnwrap(messageIndex(
            role: "user", containing: secondUserMarker, in: secondMessages
        ))
        XCTAssertLessThan(firstUserIndex, assistantIndex, "Prior user/assistant order was lost")
        XCTAssertLessThan(assistantIndex, secondUserIndex, "Resumed user turn was not appended")
        XCTAssertNil(
            bodies[1]["previous_response_id"],
            "Responses-only continuation state leaked to the Chat upstream"
        )
        await supervisor.stop()
    }

    private func managementStatus(port: Int, authorization: String?) async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)/api/providers")!
        var request = URLRequest(url: url)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    }

    private func providerNetwork(
        port: Int,
        credentials: BifrostManagementCredentials
    ) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)/api/providers")!
        var request = URLRequest(url: url)
        request.setValue(credentials.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        let provider = try XCTUnwrap(
            providers.first(where: { $0["name"] as? String == BifrostConfigBuilder.providerName })
        )
        return try XCTUnwrap(provider["network_config"] as? [String: Any])
    }

    private func configuredVirtualKeyCount(
        port: Int,
        credentials: BifrostManagementCredentials
    ) async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)/api/governance/virtual-keys?from_memory=true")!
        var request = URLRequest(url: url)
        request.setValue(credentials.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["count"] as? Int)
    }

    private func openAIInference(port: Int, token: String?) async throws -> (
        statusCode: Int, body: String
    ) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(#"{"model":"claude-opus-4-8","messages":[{"role":"user","content":"ping"}],"stream":false}"#.utf8)
        return try await sendInference(request)
    }

    private func anthropicInference(port: Int, xAPIKey: String) async throws -> (
        statusCode: Int, body: String
    ) {
        let url = URL(string: "http://127.0.0.1:\(port)/anthropic/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(xAPIKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = Data(#"{"model":"claude-opus-4-8","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}"#.utf8)
        return try await sendInference(request)
    }

    private func responsesInference(
        port: Int,
        stream: Bool,
        tools: Bool
    ) async throws -> (statusCode: Int, body: String) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": "gpt-5.4",
            "input": "ping",
            "stream": stream,
        ]
        if tools {
            body["tools"] = [[
                "type": "function",
                "name": "lookup_weather",
                "description": "Look up a city's weather",
                "parameters": [
                    "type": "object",
                    "properties": ["city": ["type": "string"]],
                    "required": ["city"],
                ],
            ]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await sendInference(request)
    }

    private func sendInference(_ request: URLRequest) async throws -> (
        statusCode: Int, body: String
    ) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (
            try XCTUnwrap((response as? HTTPURLResponse)?.statusCode),
            String(decoding: data, as: UTF8.self)
        )
    }

    private func corsPreflight(port: Int, origin: String) async throws -> (
        statusCode: Int, allowedOrigin: String?
    ) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("POST", forHTTPHeaderField: "Access-Control-Request-Method")
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (
            httpResponse.statusCode,
            httpResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
        )
    }

    private func assertPrivatePermissions(at url: URL, expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o777, expected, "Unexpected permissions for \(url.path)")
    }

    private func integrationBinaryPath() throws -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["CCBUD_BIFROST_BINARY"]
        let bundledPath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("bifrost-http").path
        let repositoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/bifrost-http").path
        let candidates = [environmentPath, bundledPath, repositoryPath].compactMap { $0 }
        guard let sourcePath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        return try stagedPinnedBifrostBinary(at: URL(fileURLWithPath: sourcePath))
    }

    private func pinnedRepositoryBifrostBinaryPath() throws -> String {
        let repositoryBinary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/bifrost-http")
        let executable = try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: repositoryBinary.path)
                ? repositoryBinary
                : nil,
            "Pinned bifrost-http is unavailable; run native/Scripts/fetch-bifrost.sh"
        )
        return try stagedPinnedBifrostBinary(at: executable)
    }

    private func stagedPinnedBifrostBinary(at source: URL) throws -> String {
        let sourceDigest = try bifrostSHA256(at: source)
        guard sourceDigest == Self.pinnedBifrostSHA256 else {
            throw NSError(
                domain: "BifrostSupervisorIntegrationTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Pinned bifrost-http SHA-256 mismatch: expected "
                        + "\(Self.pinnedBifrostSHA256), got \(sourceDigest)",
                ]
            )
        }

        let resolvedSourcePath = source.resolvingSymlinksInPath().path
        let resolvedSystemTemporaryPath = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .resolvingSymlinksInPath().path
        if resolvedSourcePath == resolvedSystemTemporaryPath
            || resolvedSourcePath.hasPrefix(resolvedSystemTemporaryPath + "/") {
            return source.path
        }

        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ccbud-bifrost-integration-\(getuid())-\(Self.pinnedBifrostSHA256)"
            )
        if FileManager.default.isExecutableFile(atPath: destination.path),
           try bifrostSHA256(at: destination) == Self.pinnedBifrostSHA256 {
            return destination.path
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let partial = destination.appendingPathExtension("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            while let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: partial.path
        )
        let copiedDigest = try bifrostSHA256(at: partial)
        guard copiedDigest == Self.pinnedBifrostSHA256 else {
            throw NSError(
                domain: "BifrostSupervisorIntegrationTests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Copied bifrost-http SHA-256 mismatch: "
                        + "\(copiedDigest)",
                ]
            )
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination.path
    }

    private func bifrostSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func codexBinaryPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = [
            environment["CCBUD_CODEX_BINARY"],
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap { $0 }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex").path
            })
        }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func runCodexCLI(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        outputDirectory: URL,
        label: String,
        timeout: TimeInterval = 45
    ) throws -> CodexCLIResult {
        let stdoutURL = outputDirectory.appendingPathComponent("codex-\(label)-stdout.jsonl")
        let stderrURL = outputDirectory.appendingPathComponent("codex-\(label)-stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        return CodexCLIResult(
            status: process.terminationStatus,
            timedOut: timedOut,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }

    private func addCodexEvidenceAttachments(_ result: CodexCLIResult, label: String) {
        let standardOutput = XCTAttachment(string: result.standardOutput)
        standardOutput.name = "codex-\(label)-stdout.jsonl"
        standardOutput.lifetime = .keepAlways
        add(standardOutput)

        let standardError = XCTAttachment(string: result.standardError)
        standardError.name = "codex-\(label)-stderr.log"
        standardError.lifetime = .keepAlways
        add(standardError)
    }

    private func codexThreadID(fromJSONLines output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "thread.started",
                  let threadID = event["thread_id"] as? String,
                  !threadID.isEmpty
            else { continue }
            return threadID
        }
        return nil
    }

    private func messageIndex(
        role: String,
        containing marker: String,
        in messages: [[String: Any]]
    ) -> Int? {
        messages.firstIndex {
            $0["role"] as? String == role && flattenedText(in: $0["content"]).contains(marker)
        }
    }

    private func flattenedText(in value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let array as [Any]:
            return array.map { flattenedText(in: $0) }.joined(separator: " ")
        case let object as [String: Any]:
            return object.values.map { flattenedText(in: $0) }.joined(separator: " ")
        default:
            return ""
        }
    }

    private func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var bindAddress = address
        let bound = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private struct CodexCLIResult {
    let status: Int32
    let timedOut: Bool
    let standardOutput: String
    let standardError: String

    var failureDescription: String {
        "Codex CLI status=\(status), timedOut=\(timedOut)\nstdout:\n\(standardOutput)\nstderr:\n\(standardError)"
    }
}

private final class LoopbackOpenAIChatMock: @unchecked Sendable {
    static let responseMarker = "ccbud-chat-fallback-ok"
    static let streamMarker = "ccbud-stream-fallback-ok"

    let port: Int
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.ccbud.tests.mock-openai-chat")
    private let lock = NSLock()
    private var stopped = false
    private var targets: [String] = []
    private var bodies: [[String: Any]] = []

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }
        var closeOnFailure = true
        defer { if closeOnFailure { close(descriptor) } }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else { throw Self.posixError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw Self.posixError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw Self.posixError() }

        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        closeOnFailure = false
    }

    var chatCompletionTargets: [String] {
        lock.withLock {
            targets.filter { $0.split(separator: "?", maxSplits: 1).first == "/v1/chat/completions" }
        }
    }

    var chatCompletionBodies: [[String: Any]] {
        lock.withLock { bodies }
    }

    func start() {
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSignal: Int32 = 1
            _ = setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            )
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let request = readRequest(from: client),
              let target = requestTarget(in: request)
        else { return }
        let object = requestBody(in: request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        lock.withLock {
            targets.append(target)
            if target.split(separator: "?", maxSplits: 1).first == "/v1/chat/completions" {
                bodies.append(object)
            }
        }

        if target.split(separator: "?", maxSplits: 1).first == "/v1/models" {
            sendJSON(Data(#"{"object":"list","data":[]}"#.utf8), to: client)
        } else if object["stream"] as? Bool == true {
            sendStream(to: client)
        } else if object["tools"] != nil {
            sendToolResponse(to: client)
        } else {
            sendUnaryResponse(to: client)
        }
    }

    private func sendUnaryResponse(to client: Int32) {
        let body = Data("""
        {"id":"chatcmpl_ccbud","object":"chat.completion","created":1,"model":"mock-chat","choices":[{"index":0,"message":{"role":"assistant","content":"\(Self.responseMarker)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        """.utf8)
        sendJSON(body, to: client)
    }

    private func sendToolResponse(to client: Int32) {
        let body = Data(#"{"id":"chatcmpl_tool","object":"chat.completion","created":1,"model":"mock-chat","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_ccbud","type":"function","function":{"name":"lookup_weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#.utf8)
        sendJSON(body, to: client)
    }

    private func sendStream(to client: Int32) {
        let body = Data("""
        data: {"id":"chatcmpl_stream","object":"chat.completion.chunk","created":1,"model":"mock-chat","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

        data: {"id":"chatcmpl_stream","object":"chat.completion.chunk","created":1,"model":"mock-chat","choices":[{"index":0,"delta":{"content":"\(Self.streamMarker)"},"finish_reason":null}]}

        data: {"id":"chatcmpl_stream","object":"chat.completion.chunk","created":1,"model":"mock-chat","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

        data: [DONE]

        """.utf8)
        send(body, contentType: "text/event-stream", to: client)
    }

    private func sendJSON(_ body: Data, to client: Int32) {
        send(body, contentType: "application/json", to: client)
    }

    private func send(_ body: Data, contentType: String, to client: Int32) {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        response.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(client, cursor, remaining, 0)
                guard written > 0 else { return }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func readRequest(from client: Int32) -> Data? {
        var data = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while data.count < 1_048_576 {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer.prefix(count))
            guard let headerRange = data.range(of: delimiter) else { continue }
            let headers = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
            let contentLength = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let fields = line.split(separator: ":", maxSplits: 1)
                guard fields.count == 2,
                      fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                else { return nil }
                return Int(fields[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            if data.count >= headerRange.upperBound + contentLength { return data }
        }
        return nil
    }

    private func requestTarget(in request: Data) -> String? {
        let firstLine = String(decoding: request, as: UTF8.self)
            .components(separatedBy: "\r\n").first
        guard let firstLine else { return nil }
        let fields = firstLine.split(separator: " ")
        return fields.count >= 2 ? String(fields[1]) : nil
    }

    private func requestBody(in request: Data) -> Data? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: delimiter) else { return nil }
        return request.subdata(in: range.upperBound..<request.endIndex)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private final class LoopbackAnthropicMock: @unchecked Sendable {
    static let responseMarker = "ccbud-mock-upstream-ok"

    let port: Int
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.ccbud.tests.mock-anthropic")
    private let lock = NSLock()
    private var stopped = false
    private var targets: [String] = []

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }
        var closeOnFailure = true
        defer { if closeOnFailure { close(descriptor) } }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else { throw Self.posixError() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw Self.posixError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw Self.posixError() }

        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        closeOnFailure = false
    }

    var messageRequestTargets: [String] {
        lock.lock()
        defer { lock.unlock() }
        return targets.filter { $0.split(separator: "?", maxSplits: 1).first == "/v1/messages" }
    }

    func start() {
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSignal: Int32 = 1
            _ = setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            )
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let request = readRequest(from: client), let target = requestTarget(in: request) else {
            return
        }
        lock.lock()
        targets.append(target)
        lock.unlock()

        let body = Data("""
        {"id":"msg_ccbud_mock","type":"message","role":"assistant","model":"glm-5.2","content":[{"type":"text","text":"\(Self.responseMarker)"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
        """.utf8)
        let responseHead = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(responseHead.utf8)
        response.append(body)
        response.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.send(client, cursor, remaining, 0)
                guard written > 0 else { return }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func readRequest(from client: Int32) -> Data? {
        var data = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while data.count < 1_048_576 {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer.prefix(count))
            guard let headerRange = data.range(of: delimiter) else { continue }
            let headers = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
            let contentLength = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let fields = line.split(separator: ":", maxSplits: 1)
                guard fields.count == 2,
                      fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                else { return nil }
                return Int(fields[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            if data.count >= headerRange.upperBound + contentLength { return data }
        }
        return nil
    }

    private func requestTarget(in request: Data) -> String? {
        let firstLine = String(decoding: request, as: UTF8.self)
            .components(separatedBy: "\r\n").first
        guard let firstLine else { return nil }
        let fields = firstLine.split(separator: " ")
        return fields.count >= 2 ? String(fields[1]) : nil
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
