import Darwin
import CryptoKit
import XCTest
@testable import CCBuddy

/// Real-process protocol contract tests for the pinned Bifrost helper. These use a
/// loopback wire server rather than URLProtocol, so both Bifrost's HTTP transport
/// and CC Buddy's generated config participate in every assertion.
final class BifrostResponsesProtocolIntegrationTests: XCTestCase {
    func testLegacyGatewayAliasesReachPinnedBifrostWithItsTokenEnforcement() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Pinned bifrost-http is unavailable; run native/Scripts/fetch-bifrost.sh")
        }
        let upstream = try ResponsesWireMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-legacy-routes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIResponses
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].defaultModel = "gpt-5.4"
        config.retry429.enabled = false
        config.requireToken = true
        config.gatewayToken = "legacy-route-contract"
        let inferenceToken = try XCTUnwrap(normalizeInferenceToken(config.gatewayToken))
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        let activityRecorder = BifrostActivityRecorder()
        let activityTask = Task {
            for await activity in supervisor.requestActivity {
                await activityRecorder.append(activity)
            }
        }
        defer { activityTask.cancel() }
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let anthropicBody: [String: Any] = [
            "model": "gpt-5.4",
            "max_tokens": 64,
            "messages": [["role": "user", "content": "legacy messages"]],
        ]
        let chatBody: [String: Any] = [
            "model": "gpt-5.4",
            "messages": [["role": "user", "content": "legacy chat"]],
            "stream": false,
        ]
        let responsesBody: [String: Any] = [
            "model": "gpt-5.4", "input": "legacy responses", "stream": false,
        ]
        let compactBody: [String: Any] = [
            "model": "gpt-5.4", "input": "legacy compact",
        ]
        let anthropicData = try JSONSerialization.data(withJSONObject: anthropicBody)
        let chatData = try JSONSerialization.data(withJSONObject: chatBody)
        let responsesData = try JSONSerialization.data(withJSONObject: responsesBody)
        let compactData = try JSONSerialization.data(withJSONObject: compactBody)
        let unauthenticatedCases: [(path: String, body: Data)] = [
            ("/messages", anthropicData), ("/v1/messages", anthropicData),
            ("/chat/completions", chatData), ("/v1/chat/completions", chatData),
            ("/responses", responsesData), ("/v1/responses", responsesData),
            ("/responses/compact", compactData), ("/v1/responses/compact", compactData),
            ("/v1/messages/count_tokens", anthropicData),
        ]
        let inferencePostsBeforeRejections = upstream.requests.filter { $0.method == "POST" }.count
        for item in unauthenticatedCases {
            let result = try await request(
                port: config.port,
                method: "POST",
                path: item.path,
                body: item.body
            )
            XCTAssertEqual(
                result.statusCode, 401,
                "Unauthenticated legacy route was open: \(item.path); \(result.body)"
            )
        }
        XCTAssertEqual(
            upstream.requests.filter { $0.method == "POST" }.count,
            inferencePostsBeforeRejections,
            "Rejected aliases must not reach inference upstreams"
        )

        for path in ["/messages", "/v1/messages"] {
            let result = try await request(
                port: config.port,
                method: "POST",
                path: path,
                body: anthropicData,
                headers: ["x-api-key": inferenceToken]
            )
            XCTAssertEqual(result.statusCode, 200, "\(path): \(result.body)")
            XCTAssertTrue(result.body.contains(ResponsesWireMock.unaryMarker), result.body)
            XCTAssertTrue(result.body.contains(#""type":"message""#), result.body)
        }

        let authorization = ["Authorization": "Bearer \(inferenceToken)"]
        for path in ["/chat/completions", "/v1/chat/completions"] {
            let result = try await request(
                port: config.port,
                method: "POST",
                path: path,
                body: chatData,
                headers: authorization
            )
            XCTAssertEqual(result.statusCode, 200, "\(path): \(result.body)")
            XCTAssertTrue(result.body.contains(ResponsesWireMock.unaryMarker), result.body)
            XCTAssertTrue(result.body.contains(#""object":"chat.completion""#), result.body)
        }

        for path in ["/responses", "/v1/responses"] {
            let result = try await request(
                port: config.port,
                method: "POST",
                path: path,
                body: responsesData,
                headers: authorization
            )
            XCTAssertEqual(result.statusCode, 200, "\(path): \(result.body)")
            XCTAssertTrue(result.body.contains(ResponsesWireMock.unaryMarker), result.body)
            XCTAssertTrue(result.body.contains(#""object":"response""#), result.body)
        }

        for path in ["/responses/compact", "/v1/responses/compact"] {
            let result = try await request(
                port: config.port,
                method: "POST",
                path: path,
                body: compactData,
                headers: authorization
            )
            XCTAssertEqual(result.statusCode, 200, "\(path): \(result.body)")
            XCTAssertTrue(result.body.contains(#""object":"response.compaction""#), result.body)
        }

        let countResult = try await request(
            port: config.port,
            method: "POST",
            path: "/v1/messages/count_tokens",
            body: anthropicData,
            headers: ["x-api-key": inferenceToken]
        )
        XCTAssertEqual(countResult.statusCode, 200, countResult.body)
        XCTAssertTrue(countResult.body.contains(#""input_tokens":7"#), countResult.body)
        XCTAssertEqual(countResult.headers["x-ccbud-tokens"], "upstream")

        let headResult = try await request(
            port: config.port,
            method: "HEAD",
            path: "/",
            headers: authorization
        )
        XCTAssertEqual(headResult.statusCode, 200, headResult.body)
        XCTAssertEqual(headResult.headers["x-ccbud-fallback"], "head-root-404-to-200")
        // The pinned Bifrost router rejects HEAD / itself, before the mock upstream can return
        // its 404. The compatibility proxy records that actual router status.
        XCTAssertEqual(headResult.headers["x-ccbud-upstream-status"], "405")
        XCTAssertTrue(headResult.body.isEmpty)

        let requests = upstream.requests
        XCTAssertEqual(requests.filter { $0.target == "/v1/responses" }.count, 6)
        XCTAssertEqual(requests.filter { $0.target == "/v1/responses/compact" }.count, 2)
        XCTAssertEqual(requests.filter { $0.target == "/v1/responses/input_tokens" }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer sk-testtoken1234" })

        let managementResult = try await request(
            port: config.port,
            method: "GET",
            path: "/api/providers",
            headers: [
                "Authorization": supervisor.managementCredentials.basicAuthorizationHeader,
            ]
        )
        XCTAssertEqual(managementResult.statusCode, 200, managementResult.body)
        let healthResult = try await request(
            port: config.port,
            method: "GET",
            path: "/health"
        )
        XCTAssertEqual(healthResult.statusCode, 200, healthResult.body)

        // Only the nine rejected and nine accepted inference requests are activity. Public health
        // and authenticated management traffic must stay silent to prevent monitor-refresh loops.
        for _ in 0..<100 {
            let events = await activityRecorder.snapshot()
            if events.filter({ $0 == .responseCompleted }).count >= 18 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let activities = await activityRecorder.snapshot()
        XCTAssertEqual(activities.filter { $0 == .requestReceived }.count, 18)
        XCTAssertEqual(activities.filter { $0 == .responseCompleted }.count, 18)
        await supervisor.stop()
    }

    @MainActor
    func testLegacyModelCompatibilityAgainstPinnedBifrostAndMonitor() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let upstream = try ResponsesWireMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-model-compat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].name = "Compatibility upstream"
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].authToken = "sk-compat-upstream"
        config.providers[0].defaultModel = "primary-upstream"
        config.providers[0].smallFastModel = "fast-upstream"
        config.providers[0].protocol = .openAIResponses
        config.providers[0].models = [
            .init(alias: "exact-alias", upstream: "explicit-upstream"),
        ]
        config.providers.append(Provider(
            id: "inactive",
            models: [.init(alias: "inactive-visible-alias", upstream: "unused-upstream")]
        ))
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

        let claudeModels = try await request(
            port: config.port,
            method: "GET",
            path: "/v1/models",
            headers: [
                "User-Agent": "claude-cli",
                "Accept-Encoding": "gzip, br",
            ]
        )
        XCTAssertEqual(claudeModels.statusCode, 200, claudeModels.body)
        let claudeModelIDs = try modelIDs(in: claudeModels.body)
        for required in [
            "exact-alias", "inactive-visible-alias", "claude-fable-5",
            "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5",
        ] {
            XCTAssertTrue(claudeModelIDs.contains(required), "Missing \(required): \(claudeModels.body)")
        }

        let codexModels = try await request(
            port: config.port,
            method: "GET",
            path: "/v1/models",
            headers: ["Originator": "codex_cli_rs"]
        )
        XCTAssertEqual(codexModels.statusCode, 200, codexModels.body)
        let codexModelIDs = try modelIDs(in: codexModels.body)
        for required in ["exact-alias", "inactive-visible-alias", "gpt-5.4", "gpt-5.4-mini"] {
            XCTAssertTrue(codexModelIDs.contains(required), "Missing \(required): \(codexModels.body)")
        }

        let cases: [(caller: String, upstream: String, stream: Bool)] = [
            ("exact-alias", "explicit-upstream", false),
            ("claude-arbitrary-sonnet", "primary-upstream", false),
            ("gpt-4-turbo", "fast-upstream", false),
            ("gpt-5.6-sol", "primary-upstream", false),
            ("gpt_5_6_terra_pro", "primary-upstream", false),
            ("claude-streaming-sonnet", "primary-upstream", true),
        ]
        for item in cases {
            let data = try JSONSerialization.data(withJSONObject: [
                "model": item.caller,
                "input": "route \(item.caller)",
                "stream": item.stream,
            ])
            let result = try await request(
                port: config.port,
                method: "POST",
                path: "/v1/responses",
                body: data,
                headers: item.caller == "claude-arbitrary-sonnet"
                    ? [LegacyRequestedModelMetadata.headerName: "attacker"]
                    : [:]
            )
            XCTAssertEqual(result.statusCode, 200, "\(item.caller): \(result.body)")
            XCTAssertTrue(
                result.body.contains(#""model":"\#(item.caller)""#),
                "Caller model was not restored for \(item.caller): \(result.body)"
            )
            XCTAssertFalse(
                result.body.contains(#""model":"mock-responses""#),
                "Upstream model leaked for \(item.caller): \(result.body)"
            )
        }

        let routedRequests = upstream.requests.filter { $0.target == "/v1/responses" }
        XCTAssertEqual(
            routedRequests.suffix(cases.count).compactMap { $0.body["model"] as? String },
            cases.map(\.upstream)
        )

        let managementClient = BifrostManagementClient(
            port: config.port,
            credentials: supervisor.managementCredentials
        )
        let callerModel = "claude-arbitrary-sonnet"
        let trustedMetadata = LegacyRequestedModelMetadata.encode(callerModel)
        var rawRoutedLog: BifrostLog?
        for _ in 0..<200 {
            let page = try await managementClient.fetchLogs(limit: 100)
            rawRoutedLog = page.logs.first { log in
                guard case .object(let metadata)? = log.additionalFields["metadata"] else {
                    return false
                }
                return metadata[LegacyRequestedModelMetadata.metadataKey]?.stringValue
                    == trustedMetadata
            }
            if rawRoutedLog != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let rawLog = try XCTUnwrap(rawRoutedLog, "Trusted requested-model metadata was not logged")
        XCTAssertEqual(rawLog.model, "primary-upstream")
        XCTAssertEqual(rawLog.restoringLegacyRequestedModel().requestedModel, callerModel)

        let monitor = MonitorStore(
            client: managementClient,
            pollIntervalNanoseconds: 60_000_000_000,
            environment: [:]
        )
        defer { monitor.shutdown() }
        monitor.configure(port: config.port, gatewayRunning: true)
        var monitorLog: BifrostLog?
        for _ in 0..<200 {
            monitorLog = monitor.requests.first { $0.id == rawLog.id }
            if monitorLog?.requestedModel == callerModel, !monitor.isRefreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        monitor.stopPolling()
        XCTAssertEqual(monitorLog?.requestedModel, callerModel)
        XCTAssertEqual(monitorLog?.outgoingModel, "primary-upstream")
        await monitor.loadDetail(id: rawLog.id)
        XCTAssertEqual(monitor.selectedDetail?.requestedModel, callerModel)
        XCTAssertEqual(monitor.selectedDetail?.outgoingModel, "primary-upstream")

        await supervisor.stop()
    }

    func testResponsesProviderPreservesNativeInferenceAndLifecycleOperations() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let upstream = try ResponsesWireMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-responses-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIResponses
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.retry429.enabled = false
        config.requireToken = false
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        let activityRecorder = BifrostActivityRecorder()
        let activityTask = Task {
            for await activity in supervisor.requestActivity {
                await activityRecorder.append(activity)
            }
        }
        defer { activityTask.cancel() }
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let unary = try await postJSON(
            port: config.port,
            path: "/v1/responses",
            body: ["model": "gpt-5.4", "input": "ping", "stream": false]
        )
        XCTAssertEqual(unary.statusCode, 200, unary.body)
        XCTAssertTrue(unary.body.contains(ResponsesWireMock.unaryMarker), unary.body)

        // Wait until the unary response has crossed the proxy, then prove an SSE response
        // produces its own completion signal at the wire boundary. Health is deliberately silent.
        for _ in 0..<100 {
            let completed = await activityRecorder.snapshot()
                .filter { $0 == .responseCompleted }.count
            if completed >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completionsBeforeStream = await activityRecorder.snapshot()
            .filter { $0 == .responseCompleted }.count
        XCTAssertEqual(completionsBeforeStream, 1)

        let streaming = try await postJSON(
            port: config.port,
            path: "/v1/responses",
            body: ["model": "gpt-5.4", "input": "ping", "stream": true]
        )
        XCTAssertEqual(streaming.statusCode, 200, streaming.body)
        XCTAssertTrue(streaming.body.contains(ResponsesWireMock.streamMarker), streaming.body)
        XCTAssertTrue(streaming.body.contains("response.completed"), streaming.body)
        for _ in 0..<100 {
            let completed = await activityRecorder.snapshot()
                .filter { $0 == .responseCompleted }.count
            if completed > completionsBeforeStream { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let completionsAfterStream = await activityRecorder.snapshot()
            .filter { $0 == .responseCompleted }.count
        XCTAssertEqual(completionsAfterStream, completionsBeforeStream + 1)

        let tool = try await postJSON(
            port: config.port,
            path: "/v1/responses",
            body: [
                "model": "gpt-5.4",
                "input": "weather",
                "tools": [[
                    "type": "function",
                    "name": "lookup_weather",
                    "parameters": ["type": "object"],
                ]],
            ]
        )
        XCTAssertEqual(tool.statusCode, 200, tool.body)
        XCTAssertTrue(tool.body.contains(#""type":"function_call""#), tool.body)
        XCTAssertTrue(tool.body.contains(#""name":"lookup_weather""#), tool.body)

        let count = try await postJSON(
            port: config.port,
            path: "/v1/responses/input_tokens",
            body: ["model": "gpt-5.4", "input": "count me"]
        )
        XCTAssertEqual(count.statusCode, 200, count.body)
        XCTAssertTrue(count.body.contains(#""input_tokens":7"#), count.body)

        let compact = try await postJSON(
            port: config.port,
            path: "/v1/responses/compact",
            body: ["model": "gpt-5.4", "input": "compact me"]
        )
        XCTAssertEqual(compact.statusCode, 200, compact.body)
        XCTAssertTrue(compact.body.contains(#""object":"response.compaction""#), compact.body)
        XCTAssertTrue(compact.body.contains("encrypted-ccbud-state"), compact.body)

        let retrieve = try await request(
            port: config.port,
            method: "GET",
            path: "/v1/responses/resp_ccbud?provider=ccbud-active"
        )
        XCTAssertEqual(retrieve.statusCode, 200, retrieve.body)
        XCTAssertTrue(retrieve.body.contains(ResponsesWireMock.unaryMarker), retrieve.body)

        let inputItems = try await request(
            port: config.port,
            method: "GET",
            path: "/v1/responses/resp_ccbud/input_items?provider=ccbud-active"
        )
        XCTAssertEqual(inputItems.statusCode, 200, inputItems.body)
        XCTAssertTrue(inputItems.body.contains(#""object":"list""#), inputItems.body)
        XCTAssertTrue(inputItems.body.contains("input-item-marker"), inputItems.body)

        let cancel = try await request(
            port: config.port,
            method: "POST",
            path: "/v1/responses/resp_ccbud/cancel?provider=ccbud-active"
        )
        XCTAssertEqual(cancel.statusCode, 200, cancel.body)
        XCTAssertTrue(cancel.body.contains(#""status":"cancelled""#), cancel.body)

        let delete = try await request(
            port: config.port,
            method: "DELETE",
            path: "/v1/responses/resp_ccbud?provider=ccbud-active"
        )
        XCTAssertEqual(delete.statusCode, 200, delete.body)
        XCTAssertTrue(delete.body.contains(#""deleted":true"#), delete.body)

        let operations = upstream.requests.filter { $0.target.hasPrefix("/v1/responses") }
        // `provider` is Bifrost's routing selector. The gateway consumes it instead of
        // leaking an implementation-specific query item to the configured upstream.
        XCTAssertEqual(operations.map { "\($0.method) \($0.target)" }, [
            "POST /v1/responses",
            "POST /v1/responses",
            "POST /v1/responses",
            "POST /v1/responses/input_tokens",
            "POST /v1/responses/compact",
            "GET /v1/responses/resp_ccbud",
            "GET /v1/responses/resp_ccbud/input_items",
            "POST /v1/responses/resp_ccbud/cancel",
            "DELETE /v1/responses/resp_ccbud",
        ])
        XCTAssertTrue(operations.allSatisfy { $0.authorization == "Bearer sk-testtoken1234" })

        await supervisor.stop()
    }

    func testResponsesProviderConvertsCataloguedResponsesOnlyChatRequest() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let upstream = try ResponsesWireMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-chat-to-responses-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIResponses
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].defaultModel = "gpt-5.4"
        config.retry429.enabled = false
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let result = try await postJSON(
            port: config.port,
            path: "/v1/chat/completions",
            body: [
                "model": "gpt-5.4",
                "messages": [["role": "user", "content": "ping"]],
                "stream": false,
            ]
        )
        XCTAssertEqual(result.statusCode, 200, result.body)
        XCTAssertTrue(result.body.contains(ResponsesWireMock.unaryMarker), result.body)
        XCTAssertEqual(
            upstream.requests.filter { $0.target == "/v1/responses" }.count,
            1,
            "Chat request did not use Bifrost's Chat -> Responses conversion"
        )
        XCTAssertFalse(upstream.requests.contains(where: { $0.target == "/v1/chat/completions" }))
        await supervisor.stop()
    }

    func testChangedResponsesCatalogIsAuthoritativeImmediatelyAfterRestart() async throws {
        guard let binary = try integrationBinaryPath() else {
            throw XCTSkip("Set CCBUD_BIFROST_BINARY to run the pinned sidecar integration test")
        }
        let upstream = try ResponsesWireMock()
        upstream.start()
        defer { upstream.stop() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-bifrost-catalog-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        config.providers[0].protocol = .openAIResponses
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].mapDefaultModels = false
        config.providers[0].defaultModel = "catalog-model-one"
        config.providers[0].smallFastModel = ""
        config.providers[0].models = []
        config.retry429.enabled = false
        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_BIFROST_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let first = try await postJSON(
            port: config.port,
            path: "/v1/chat/completions",
            body: [
                "model": "catalog-model-one",
                "messages": [["role": "user", "content": "first"]],
                "stream": false,
            ]
        )
        XCTAssertEqual(first.statusCode, 200, first.body)
        XCTAssertTrue(first.body.contains(ResponsesWireMock.unaryMarker), first.body)

        // Reuse the same config.db, but change the only catalogued model. The first request
        // after health readiness must already use the replacement catalog; accepting a stale
        // DB snapshot and refreshing it later would route this request to the wrong endpoint.
        config.providers[0].defaultModel = "catalog-model-two"
        try await supervisor.start(config: config)
        let second = try await postJSON(
            port: config.port,
            path: "/v1/chat/completions",
            body: [
                "model": "catalog-model-two",
                "messages": [["role": "user", "content": "second"]],
                "stream": false,
            ]
        )
        XCTAssertEqual(second.statusCode, 200, second.body)
        XCTAssertTrue(second.body.contains(ResponsesWireMock.unaryMarker), second.body)

        let responses = upstream.requests.filter { $0.target == "/v1/responses" }
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses.compactMap { $0.body["model"] as? String }, [
            "catalog-model-one", "catalog-model-two",
        ])
        XCTAssertFalse(upstream.requests.contains { $0.target == "/v1/chat/completions" })
        await supervisor.stop()
    }

    private func postJSON(
        port: Int,
        path: String,
        body: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> (statusCode: Int, body: String, headers: [String: String]) {
        try await request(
            port: port,
            method: "POST",
            path: path,
            body: try JSONSerialization.data(withJSONObject: body),
            headers: headers
        )
    }

    private func modelIDs(in body: String) throws -> [String] {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        let entries = try XCTUnwrap(object["data"] as? [[String: Any]])
        return entries.compactMap { $0["id"] as? String }
    }

    private func request(
        port: Int,
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (statusCode: Int, body: String, headers: [String: String]) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var responseHeaders: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            responseHeaders[String(describing: name).lowercased()] = String(describing: value)
        }
        return (
            http.statusCode,
            String(decoding: data, as: UTF8.self),
            responseHeaders
        )
    }

    /// Verifies the helper the way the app and the build scripts do: one digest per Mach-O slice.
    ///
    /// A release helper is universal, so the file as a whole has a digest nobody published. The
    /// pinned values live on `SelfCheckRunner` rather than being copied here again.
    private func assertPinnedBifrost(at url: URL) throws {
        let slices = try SelfCheckSystemProbe.machOSlices(at: url)
        let digests = Dictionary(
            slices.map { ($0.architecture, $0.sha256) },
            uniquingKeysWith: { first, _ in first }
        )
        let expected = SelfCheckRunner.expectedBifrostSliceSHA256
        guard !digests.isEmpty, digests.allSatisfy({ expected[$0.key] == $0.value }) else {
            throw NSError(
                domain: "PinnedBifrost",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Pinned bifrost-http slice digests do not match: \(digests)",
                ]
            )
        }
    }

    /// A plain whole-file digest, used only to name and re-check the staged copy. Trust comes from
    /// `assertPinnedBifrost`; this just proves the copy is byte-identical to what was verified.
    private func fileDigest(at path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func integrationBinaryPath() throws -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["CCBUD_BIFROST_BINARY"]
        let bundledPath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("bifrost-http").path
        let repositoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/bifrost-http").path
        let candidates = [environmentPath, repositoryPath, bundledPath].compactMap { $0 }
        guard let sourcePath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        try assertPinnedBifrost(at: URL(fileURLWithPath: sourcePath))
        let stagedToken = try fileDigest(at: sourcePath)

        let resolvedSourcePath = URL(fileURLWithPath: sourcePath)
            .resolvingSymlinksInPath().path
        let resolvedSystemTemporaryPath = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .resolvingSymlinksInPath().path
        if resolvedSourcePath == resolvedSystemTemporaryPath
            || resolvedSourcePath.hasPrefix(resolvedSystemTemporaryPath + "/") {
            return sourcePath
        }

        // Executing the 113 MiB helper directly from an external workspace can leave dyld in a
        // prolonged file-validation wait. Stage it under /tmp with streaming I/O so XCTest never
        // asks Foundation to memory-map the external executable, then verify the launched bytes.
        let destination = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ccbud-bifrost-integration-\(getuid())-\(stagedToken)")
        let destinationPath = destination.path
        if FileManager.default.isExecutableFile(atPath: destinationPath),
           try fileDigest(at: destinationPath) == stagedToken {
            return destinationPath
        }
        if FileManager.default.fileExists(atPath: destinationPath) {
            try FileManager.default.removeItem(at: destination)
        }
        let partial = destination.appendingPathExtension("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
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
        let copiedDigest = try fileDigest(at: partial.path)
        guard copiedDigest == stagedToken else {
            throw NSError(
                domain: "BifrostResponsesProtocolIntegrationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Copied helper SHA-256 mismatch: \(copiedDigest)"]
            )
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destinationPath
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

private actor BifrostActivityRecorder {
    private var activities: [BifrostRequestActivity] = []

    func append(_ activity: BifrostRequestActivity) { activities.append(activity) }
    func snapshot() -> [BifrostRequestActivity] { activities }
}

struct ResponsesWireRequest: @unchecked Sendable {
    let method: String
    let target: String
    let authorization: String?
    let body: [String: Any]
}

final class ResponsesWireMock: @unchecked Sendable {
    static let unaryMarker = "ccbud-native-responses-ok"
    static let streamMarker = "ccbud-native-responses-stream-ok"

    let port: Int
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.ccbud.tests.responses-wire")
    private let lock = NSLock()
    private var stopped = false
    private var recorded: [ResponsesWireRequest] = []

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
        guard bound == 0, listen(descriptor, 16) == 0 else { throw Self.posixError() }
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

    var requests: [ResponsesWireRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func start() { queue.async { [weak self] in self?.acceptLoop() } }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
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
        guard let raw = readRequest(from: client), let head = parseHead(raw) else { return }
        let bodyData = requestBody(raw)
        let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        lock.lock()
        recorded.append(.init(
            method: head.method,
            target: head.target,
            authorization: head.headers["authorization"],
            body: body
        ))
        lock.unlock()

        let path = head.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.target
        switch (head.method, path) {
        case ("GET", "/v1/models"):
            sendJSON(#"{"object":"list","data":[]}"#, to: client)
        case ("POST", "/v1/responses") where body["stream"] as? Bool == true:
            sendResponsesStream(to: client)
        case ("POST", "/v1/responses") where body["tools"] != nil:
            sendJSON(toolResponse(), to: client)
        case ("POST", "/v1/responses"):
            sendJSON(responsesResponse(status: "completed"), to: client)
        case ("POST", "/v1/responses/input_tokens"):
            sendJSON(#"{"object":"response.input_tokens","input_tokens":7}"#, to: client)
        case ("POST", "/v1/responses/compact"):
            sendJSON(#"{"id":"cmp_ccbud","object":"response.compaction","created_at":1,"model":"mock-responses","output":[{"id":"cmp_item","type":"compaction","encrypted_content":"encrypted-ccbud-state"}]}"#, to: client)
        case ("GET", "/v1/responses/resp_ccbud"):
            sendJSON(responsesResponse(status: "completed"), to: client)
        case ("GET", "/v1/responses/resp_ccbud/input_items"):
            sendJSON(#"{"object":"list","data":[{"id":"msg_input","type":"message","role":"user","status":"completed","content":[{"type":"input_text","text":"input-item-marker"}]}],"has_more":false,"first_id":"msg_input","last_id":"msg_input"}"#, to: client)
        case ("POST", "/v1/responses/resp_ccbud/cancel"):
            sendJSON(responsesResponse(status: "cancelled"), to: client)
        case ("DELETE", "/v1/responses/resp_ccbud"):
            sendJSON(#"{"id":"resp_ccbud","object":"response.deleted","deleted":true}"#, to: client)
        default:
            sendJSON(
                #"{"error":{"message":"unexpected wire path","type":"invalid_request_error"}}"#,
                status: 404,
                to: client
            )
        }
    }

    private func responsesResponse(
        status: String,
        text: String? = nil
    ) -> String {
        let responseText = text ?? Self.unaryMarker
        return """
        {"id":"resp_ccbud","object":"response","created_at":1,"status":"\(status)","model":"mock-responses","output":[{"id":"msg_ccbud","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"\(responseText)","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}
        """
    }

    private func toolResponse() -> String {
        #"{"id":"resp_tool","object":"response","created_at":1,"status":"completed","model":"mock-responses","output":[{"id":"fc_ccbud","type":"function_call","status":"completed","call_id":"call_ccbud","name":"lookup_weather","arguments":"{\"city\":\"Paris\"}"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}"#
    }

    private func sendResponsesStream(to client: Int32) {
        let terminal = responsesResponse(status: "completed", text: Self.streamMarker)
        let body = """
        event: response.created
        data: {"type":"response.created","sequence_number":1,"response":{"id":"resp_ccbud","object":"response","created_at":1,"status":"in_progress","model":"mock-responses","output":[]}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"msg_ccbud","type":"message","status":"in_progress","role":"assistant","content":[]}}

        event: response.content_part.added
        data: {"type":"response.content_part.added","sequence_number":3,"item_id":"msg_ccbud","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","sequence_number":4,"item_id":"msg_ccbud","output_index":0,"content_index":0,"delta":"\(Self.streamMarker)"}

        event: response.output_text.done
        data: {"type":"response.output_text.done","sequence_number":5,"item_id":"msg_ccbud","output_index":0,"content_index":0,"text":"\(Self.streamMarker)"}

        event: response.content_part.done
        data: {"type":"response.content_part.done","sequence_number":6,"item_id":"msg_ccbud","output_index":0,"content_index":0,"part":{"type":"output_text","text":"\(Self.streamMarker)","annotations":[]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","sequence_number":7,"output_index":0,"item":{"id":"msg_ccbud","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"\(Self.streamMarker)","annotations":[]}]}}

        event: response.completed
        data: {"type":"response.completed","sequence_number":8,"response":\(terminal)}

        """
        send(Data(body.utf8), contentType: "text/event-stream", status: 200, to: client)
    }

    private func sendJSON(_ body: String, status: Int = 200, to client: Int32) {
        send(Data(body.utf8), contentType: "application/json", status: status, to: client)
    }

    private func send(_ body: Data, contentType: String, status: Int, to client: Int32) {
        let reason = status == 200 ? "OK" : "Not Found"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
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
        while data.count < 2_097_152 {
            var buffer = [UInt8](repeating: 0, count: 16_384)
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

    private func parseHead(_ request: Data) -> (method: String, target: String, headers: [String: String])? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: delimiter) else { return nil }
        let lines = String(decoding: request[..<range.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let fields = first.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        return (String(fields[0]), String(fields[1]), headers)
    }

    private func requestBody(_ request: Data) -> Data? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: delimiter) else { return nil }
        let body = request.subdata(in: range.upperBound..<request.endIndex)
        return body.isEmpty ? nil : body
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
