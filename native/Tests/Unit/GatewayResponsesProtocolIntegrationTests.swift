import Foundation
import XCTest
@testable import CCBuddy

final class GatewayResponsesProtocolIntegrationTests: XCTestCase {
    func testCanonicalAnthropicRequestTranslatesToOpenAIChatAndAppliesAlias() async throws {
        let upstream = try GatewayHTTPMock(responses: [.chat(text: "chat-to-anthropic")])
        upstream.start()
        defer { upstream.stop() }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "anthropic-to-chat",
            upstreamPort: upstream.port,
            protocol: .openAIChat
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let result = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/messages",
            object: [
                "model": "client-alias",
                "max_tokens": 64,
                "system": "Be exact.",
                "messages": [["role": "user", "content": "translate me"]],
                "stream": false,
            ]
        )
        XCTAssertEqual(result.statusCode, 200, result.bodyText)
        let response = try XCTUnwrap(result.jsonObject)
        XCTAssertEqual(response["type"] as? String, "message")
        XCTAssertEqual(response["model"] as? String, "client-alias")
        let content = try XCTUnwrap(response["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "chat-to-anthropic")

        let request = try XCTUnwrap(upstream.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/v1/chat/completions")
        XCTAssertEqual(request.headers["authorization"], "Bearer upstream-secret")
        let body = try XCTUnwrap(request.jsonObject)
        XCTAssertEqual(body["model"] as? String, "upstream-model")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["content"] as? String, "translate me")
        await running.supervisor.stop()
    }

    func testCanonicalOpenAIChatRequestTranslatesToAnthropic() async throws {
        let upstream = try GatewayHTTPMock(responses: [.anthropic(text: "anthropic-to-chat")])
        upstream.start()
        defer { upstream.stop() }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "chat-to-anthropic",
            upstreamPort: upstream.port,
            protocol: .anthropic
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let result = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/chat/completions",
            object: [
                "model": "client-alias",
                "max_tokens": 64,
                "messages": [
                    ["role": "system", "content": "Be concise."],
                    ["role": "user", "content": "hello chat"],
                ],
                "stream": false,
            ]
        )
        XCTAssertEqual(result.statusCode, 200, result.bodyText)
        let response = try XCTUnwrap(result.jsonObject)
        XCTAssertEqual(response["object"] as? String, "chat.completion")
        XCTAssertEqual(response["model"] as? String, "client-alias")
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "anthropic-to-chat")

        let request = try XCTUnwrap(upstream.requests.first)
        XCTAssertEqual(request.target, "/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "upstream-secret")
        let body = try XCTUnwrap(request.jsonObject)
        XCTAssertEqual(body["model"] as? String, "upstream-model")
        XCTAssertEqual(body["system"] as? String, "Be concise.")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertTrue(Self.jsonContains(messages, text: "hello chat"))
        await running.supervisor.stop()
    }

    func testCanonicalResponsesRequestTranslatesToAnthropic() async throws {
        let upstream = try GatewayHTTPMock(responses: [.anthropic(text: "anthropic-to-responses")])
        upstream.start()
        defer { upstream.stop() }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "responses-to-anthropic",
            upstreamPort: upstream.port,
            protocol: .anthropic
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let result = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/responses",
            object: [
                "model": "client-alias",
                "instructions": "Respond exactly.",
                "input": [[
                    "type": "message",
                    "role": "user",
                    "content": "hello responses",
                ]],
                "stream": false,
            ]
        )
        XCTAssertEqual(result.statusCode, 200, result.bodyText)
        let response = try XCTUnwrap(result.jsonObject)
        XCTAssertEqual(response["object"] as? String, "response")
        XCTAssertEqual(response["status"] as? String, "completed")
        XCTAssertEqual(response["model"] as? String, "client-alias")
        XCTAssertTrue(Self.jsonContains(response["output"], text: "anthropic-to-responses"))

        let request = try XCTUnwrap(upstream.requests.first)
        XCTAssertEqual(request.target, "/v1/messages")
        let body = try XCTUnwrap(request.jsonObject)
        XCTAssertEqual(body["model"] as? String, "upstream-model")
        XCTAssertEqual(body["system"] as? String, "Respond exactly.")
        XCTAssertTrue(Self.jsonContains(body["messages"], text: "hello responses"))
        await running.supervisor.stop()
    }

    func testRetryAfter429RetriesSameProviderWithoutEnablingFailover() async throws {
        let upstream = try GatewayHTTPMock(responses: [
            .json(
                ["error": ["message": "slow down"]],
                statusCode: 429,
                headers: ["Retry-After": "0"]
            ),
            .anthropic(text: "retried-success"),
        ])
        upstream.start()
        defer { upstream.stop() }

        let binary = try GatewayIntegrationSupport.gatewayExecutable()
        let root = try GatewayIntegrationSupport.temporaryRoot("retry-429")
        var config = GatewayIntegrationSupport.appConfig(
            upstreamPort: upstream.port,
            protocol: .anthropic
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        config.retry429 = .init(enabled: true, max: 1, baseMs: 0)
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_GATEWAY_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let result = try await GatewayIntegrationSupport.postJSON(
            port: config.port,
            path: "/v1/messages",
            object: GatewayIntegrationSupport.anthropicRequest(prompt: "retry")
        )
        XCTAssertEqual(result.statusCode, 200, result.bodyText)
        XCTAssertTrue(result.bodyText.contains("retried-success"), result.bodyText)
        XCTAssertEqual(upstream.requests.count, 2)
        XCTAssertTrue(upstream.requests.allSatisfy { $0.target == "/v1/messages" })

        let client = GatewayManagementClient(credentials: supervisor.managementCredentials)
        let logs = try await client.fetchLogs(limit: 10)
        let log = try XCTUnwrap(logs.logs.first)
        XCTAssertEqual(log.attempts, 2)
        await supervisor.stop()
    }

    func testResponsesContinuationMaterializesPriorHistoryForOpenAIChatUpstream() async throws {
        let upstream = try GatewayHTTPMock(responses: [
            .chat(text: "first answer", id: "chatcmpl_turn_one"),
            .chat(text: "second answer", id: "chatcmpl_turn_two"),
        ])
        upstream.start()
        defer { upstream.stop() }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "responses-continuation",
            upstreamPort: upstream.port,
            protocol: .openAIChat
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let first = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/responses",
            object: [
                "model": "client-alias",
                "input": [[
                    "type": "message", "role": "user", "content": "first question",
                ]],
                "stream": false,
            ]
        )
        XCTAssertEqual(first.statusCode, 200, first.bodyText)
        let firstID = try XCTUnwrap(first.jsonObject?["id"] as? String)
        XCTAssertFalse(firstID.isEmpty)
        XCTAssertTrue(Self.jsonContains(first.jsonObject?["output"], text: "first answer"))

        let second = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/responses",
            object: [
                "model": "client-alias",
                "previous_response_id": firstID,
                "input": [[
                    "type": "message", "role": "user", "content": "second question",
                ]],
                "stream": false,
            ]
        )
        XCTAssertEqual(second.statusCode, 200, second.bodyText)
        XCTAssertTrue(Self.jsonContains(second.jsonObject?["output"], text: "second answer"))
        XCTAssertEqual(upstream.requests.count, 2)

        let secondRequest = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(secondRequest.target, "/v1/chat/completions")
        let secondBody = try XCTUnwrap(secondRequest.jsonObject)
        XCTAssertNil(secondBody["previous_response_id"])
        XCTAssertNil(secondBody["input"])
        let messages = try XCTUnwrap(secondBody["messages"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(messages.count, 3, "Materialized history: \(messages)")
        XCTAssertTrue(Self.jsonContains(messages, text: "first question"))
        XCTAssertTrue(Self.jsonContains(messages, text: "first answer"))
        XCTAssertTrue(Self.jsonContains(messages, text: "second question"))
        let roles = messages.compactMap { $0["role"] as? String }
        XCTAssertTrue(roles.contains("assistant"), "Materialized history: \(messages)")
        await running.supervisor.stop()
    }

    func testEnabledFailoverUsesOneGlobalAttemptBudgetAcrossProviders() async throws {
        let primary = try GatewayHTTPMock(responses: [
            .json(["error": ["message": "primary unavailable"]], statusCode: 503),
        ])
        let secondary = try GatewayHTTPMock(responses: [
            .json(["error": ["message": "secondary unavailable"]], statusCode: 503),
        ])
        let tertiary = try GatewayHTTPMock(responses: [
            .json(["error": ["message": "tertiary must not run"]], statusCode: 503),
        ])
        for upstream in [primary, secondary, tertiary] { upstream.start() }
        defer {
            primary.stop()
            secondary.stop()
            tertiary.stop()
        }

        let binary = try GatewayIntegrationSupport.gatewayExecutable()
        let root = try GatewayIntegrationSupport.temporaryRoot("failover-budget")
        var config = GatewayIntegrationSupport.appConfig(
            upstreamPort: primary.port,
            protocol: .anthropic
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        config.providers.append(contentsOf: [
            Provider(
                id: "secondary",
                name: "Secondary",
                baseUrl: "http://127.0.0.1:\(secondary.port)/v1",
                authToken: "secondary-secret",
                defaultModel: "secondary-model",
                protocol: .anthropic
            ),
            Provider(
                id: "tertiary",
                name: "Tertiary",
                baseUrl: "http://127.0.0.1:\(tertiary.port)/v1",
                authToken: "tertiary-secret",
                defaultModel: "tertiary-model",
                protocol: .anthropic
            ),
        ])
        config.gatewayFailover = .init(
            enabled: true,
            providerIds: ["primary", "secondary", "tertiary"]
        )
        config.retry429 = .init(enabled: true, max: 1, baseMs: 0)
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_GATEWAY_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let result = try await GatewayIntegrationSupport.postJSON(
            port: config.port,
            path: "/v1/messages",
            object: GatewayIntegrationSupport.anthropicRequest(prompt: "bounded failover")
        )

        XCTAssertEqual(result.statusCode, 503, result.bodyText)
        XCTAssertEqual(primary.requests.count, 1)
        XCTAssertEqual(secondary.requests.count, 1)
        XCTAssertTrue(tertiary.requests.isEmpty, "maxRetries=1 permits only two provider attempts")
        await supervisor.stop()
    }

    func testDisabledSameProviderRetryPreservesEnabledFailoverBudget() async throws {
        let primary = try GatewayHTTPMock(responses: [
            .json(["error": ["message": "primary unavailable"]], statusCode: 503),
        ])
        let secondary = try GatewayHTTPMock(responses: [.anthropic(text: "fallback-ok")])
        primary.start()
        secondary.start()
        defer {
            primary.stop()
            secondary.stop()
        }

        let binary = try GatewayIntegrationSupport.gatewayExecutable()
        let root = try GatewayIntegrationSupport.temporaryRoot("failover-no-retry")
        var config = GatewayIntegrationSupport.appConfig(
            upstreamPort: primary.port,
            protocol: .anthropic
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        config.providers.append(Provider(
            id: "secondary",
            name: "Secondary",
            baseUrl: "http://127.0.0.1:\(secondary.port)/v1",
            authToken: "secondary-secret",
            defaultModel: "secondary-model",
            protocol: .anthropic
        ))
        config.gatewayFailover = .init(
            enabled: true,
            providerIds: ["primary", "secondary"]
        )
        config.retry429 = .init(enabled: false, max: 10, baseMs: 0)
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_GATEWAY_BINARY": binary,
        ])
        addTeardownBlock {
            await supervisor.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await supervisor.start(config: config)

        let result = try await GatewayIntegrationSupport.postJSON(
            port: config.port,
            path: "/v1/messages",
            object: GatewayIntegrationSupport.anthropicRequest(prompt: "use failover")
        )

        XCTAssertEqual(result.statusCode, 200, result.bodyText)
        XCTAssertTrue(result.bodyText.contains("fallback-ok"), result.bodyText)
        XCTAssertEqual(primary.requests.count, 1)
        XCTAssertEqual(secondary.requests.count, 1)
        await supervisor.stop()
    }

    func testDisabledFailoverNeverUsesSecondaryAndDoesNotCircuitLockPrimary() async throws {
        let primary = try GatewayHTTPMock(responses: [
            .json(["error": ["message": "primary unavailable"]], statusCode: 503),
        ])
        let secondary = try GatewayHTTPMock(responses: [.anthropic(text: "must-not-run")])
        primary.start()
        secondary.start()
        defer {
            primary.stop()
            secondary.stop()
        }

        let binary = try GatewayIntegrationSupport.gatewayExecutable()
        let root = try GatewayIntegrationSupport.temporaryRoot("failover-disabled")
        var config = GatewayIntegrationSupport.appConfig(
            upstreamPort: primary.port,
            protocol: .anthropic
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        config.providers.append(Provider(
            id: "secondary",
            name: "Secondary",
            baseUrl: "http://127.0.0.1:\(secondary.port)/v1",
            authToken: "secondary-secret",
            defaultModel: "secondary-model",
            protocol: .anthropic
        ))
        config.retry429 = .init(enabled: false, max: 0, baseMs: 0)
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_GATEWAY_BINARY": binary,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        for prompt in ["first failure", "second failure"] {
            let result = try await GatewayIntegrationSupport.postJSON(
                port: config.port,
                path: "/v1/messages",
                object: GatewayIntegrationSupport.anthropicRequest(prompt: prompt)
            )
            XCTAssertEqual(result.statusCode, 503, result.bodyText)
        }
        XCTAssertEqual(primary.requests.count, 2, "Disabled failover must leave the primary queue-neutral")
        XCTAssertTrue(secondary.requests.isEmpty, "Disabled failover contacted the secondary")

        let configURL = root.appendingPathComponent("gateway/config.json")
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        let failover = try XCTUnwrap(document["failover"] as? [String: Any])
        XCTAssertEqual(failover["enabled"] as? Bool, false)
        XCTAssertEqual(failover["providerIds"] as? [String], [])
        await supervisor.stop()
    }

    private static func jsonContains(_ value: Any?, text: String) -> Bool {
        switch value {
        case let string as String:
            return string.contains(text)
        case let array as [Any]:
            return array.contains { jsonContains($0, text: text) }
        case let object as [String: Any]:
            return object.values.contains { jsonContains($0, text: text) }
        default:
            return false
        }
    }
}
