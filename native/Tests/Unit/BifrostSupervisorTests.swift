import Foundation
import XCTest
@testable import CCBuddy

@MainActor
final class BifrostSupervisorTests: XCTestCase {
    func testChildProcessEnvironmentStripsLoaderAndXCTestInjection() {
        let sanitized = BifrostChildProcessEnvironment.make(
            inherited: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/tmp/inherited-home",
                "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
                "__XPC_DYLD_LIBRARY_PATH": "/tmp/injected-library-path",
                "XCTestBundleInjectPath": "/tmp/xctest-inject.dylib",
                "XCInjectBundleInto": "/tmp/host",
            ],
            overrides: [
                "HOME": "/tmp/override-home",
                "CCBUD_HOME": "/tmp/ccbud-home",
                "DYLD_FRAMEWORK_PATH": "/tmp/injected-framework-path",
                "XCTestSessionIdentifier": "synthetic-session",
            ]
        )

        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["HOME"], "/tmp/override-home")
        XCTAssertEqual(sanitized["CCBUD_HOME"], "/tmp/ccbud-home")
        for forbidden in [
            "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH", "__XPC_DYLD_LIBRARY_PATH",
            "XCTestBundleInjectPath", "XCTestSessionIdentifier", "XCInjectBundleInto",
        ] {
            XCTAssertNil(sanitized[forbidden], forbidden)
        }
    }

    func testLegacyGatewayRouteTableMatchesWireContractAndCountTokensSurface() {
        XCTAssertEqual(LegacyGatewayRouteCompatibility.destinations, [
            "/messages": "/anthropic/v1/messages",
            "/v1/messages": "/anthropic/v1/messages",
            "/chat/completions": "/openai/v1/chat/completions",
            "/v1/chat/completions": "/openai/v1/chat/completions",
            "/responses": "/openai/v1/responses",
            "/v1/responses": "/openai/v1/responses",
            "/responses/compact": "/openai/v1/responses/compact",
            "/v1/responses/compact": "/openai/v1/responses/compact",
            "/v1/messages/count_tokens": "/anthropic/v1/messages/count_tokens",
        ])
    }

    func testLegacyGatewayRouteRewritePreservesQueryAndLegacyTrailingSlashMatching() {
        XCTAssertEqual(
            LegacyGatewayRouteCompatibility.destination(
                for: "/v1/messages///?beta=true&trace=old"
            ),
            "/anthropic/v1/messages?beta=true&trace=old"
        )
        XCTAssertEqual(
            LegacyGatewayRouteCompatibility.destination(
                for: "http://127.0.0.1:8788/responses?provider=legacy"
            ),
            "/openai/v1/responses?provider=legacy"
        )
        XCTAssertNil(LegacyGatewayRouteCompatibility.destination(for: "/v1/models"))
        XCTAssertNil(LegacyGatewayRouteCompatibility.destination(for: "/responses/resp_123"))
        XCTAssertNil(LegacyGatewayRouteCompatibility.destination(for: "/messages-extra"))
    }

    func testRequestActivityIncludesOnlyInferenceRoutes() {
        for target in [
            "/messages", "/v1/messages?beta=true", "/responses/",
            "/v1/responses/resp_123", "/anthropic/v1/messages",
            "/openai/v1/chat/completions",
            "http://127.0.0.1:8788/chat/completions?provider=legacy",
        ] {
            XCTAssertTrue(
                LegacyGatewayRouteCompatibility.reportsInferenceActivity(for: target),
                target
            )
        }
        for target in [
            "/health", "/api/logs", "/api/providers", "/docs",
            "/v1-lookalike", "/openai-lookalike", "/anthropic-lookalike",
        ] {
            XCTAssertFalse(
                LegacyGatewayRouteCompatibility.reportsInferenceActivity(for: target),
                target
            )
        }
    }

    func testLegacyModelResolverMatchesRustPrecedenceAndFamilyTiers() {
        let provider = Provider(
            id: "active",
            defaultModel: "big",
            smallFastModel: "small",
            models: [.init(alias: "my-alias", upstream: "aliased-up")]
        )
        let resolver = LegacyModelRoutingCompatibility(
            provider: provider,
            knownModels: ["observed-model"]
        )
        let outgoing = { (model: String) in resolver.resolve(model)?.outgoingModel }

        let explicit = resolver.resolve("my-alias")
        XCTAssertEqual(explicit?.outgoingModel, "aliased-up")
        XCTAssertTrue(explicit?.usesNativeAlias == true)
        let duplicateProvider = Provider(
            id: "active",
            models: [
                .init(alias: "duplicate", upstream: "first-upstream"),
                .init(alias: "duplicate", upstream: "second-upstream"),
            ]
        )
        let duplicate = LegacyModelRoutingCompatibility(provider: duplicateProvider)
            .resolve("duplicate")
        XCTAssertEqual(duplicate?.outgoingModel, "first-upstream")
        XCTAssertTrue(duplicate?.usesNativeAlias == true)
        XCTAssertEqual(outgoing("big"), "big")
        XCTAssertEqual(outgoing("small"), "small")
        XCTAssertEqual(outgoing("aliased-up"), "aliased-up")
        XCTAssertEqual(outgoing("observed-model"), "observed-model")
        XCTAssertEqual(outgoing("claude-3-5-haiku-20241022"), "small")
        XCTAssertEqual(outgoing("claude-sonnet-4-6"), "big")
        XCTAssertEqual(outgoing("gpt-4-turbo"), "small")
        XCTAssertEqual(outgoing("other-alias"), "small")
        XCTAssertEqual(outgoing("gpt-5.5-ccbud"), "big")
        XCTAssertEqual(outgoing("gpt-5.4"), "big")
        XCTAssertEqual(outgoing("gpt-5.6-sol"), "big")
        XCTAssertEqual(outgoing("gpt_5_6_terra_pro"), "big")
        for small in [
            "gpt-5.6-sol-mini", "gpt-5.6-terra-nano", "gpt-5.6-sol-luna",
            "gpt-5.6-terra-spark",
        ] {
            XCTAssertEqual(outgoing(small), "small", small)
        }

        var disabled = provider
        disabled.mapDefaultModels = false
        XCTAssertEqual(
            LegacyModelRoutingCompatibility(provider: disabled)
                .resolve("whatever-x")?.outgoingModel,
            "whatever-x"
        )
    }

    func testModelsListForcesIdentityMergesAllProviderAliasesAndCachesOnlyUpstreamModels() throws {
        let provider = Provider(
            id: "active",
            defaultModel: "primary-upstream",
            smallFastModel: "fast-upstream",
            models: [.init(alias: "visible-alias", upstream: "alias-upstream")]
        )
        var config = AppConfig()
        config.activeProviderId = provider.id
        config.providers = [
            provider,
            Provider(
                id: "inactive",
                models: [.init(alias: "inactive-alias", upstream: "inactive-upstream")]
            ),
        ]
        let routing = LegacyModelRoutingCompatibility(config: config)
        let modelsRequest = Data((
            "GET /v1/models HTTP/1.1\r\nHost: localhost\r\n"
                + "User-Agent: claude-cli\r\nAccept-Encoding: gzip, br\r\n\r\n"
        ).utf8)
        let requestResult = try transformRequest(
            modelsRequest, fragmentSizes: [2, 7, 1], routing: routing
        )
        XCTAssertTrue(requestResult.requests.first?.capturesKnownModels == true)
        XCTAssertEqual(
            try parseHTTPMessage(requestResult.data).headers["accept-encoding"],
            "identity"
        )

        let modelList = Data(
            #"{"object":"list","data":[{"id":"claude-provider-native"}]}"#.utf8
        )
        let modelsResponseHeader = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(modelList.count)\r\n\r\n"
        var response = Data(modelsResponseHeader.utf8)
        response.append(modelList)
        let responseResult = try transformResponse(
            response,
            fragmentSizes: [3, 1, 19],
            requests: requestResult.requests,
            knownModelStore: routing.knownModelStore
        )
        let merged = try parseHTTPMessage(responseResult.data)
        let entries = try XCTUnwrap(try jsonObject(merged.body)["data"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, [
            "visible-alias",
            "inactive-alias",
            "claude-fable-5",
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-provider-native",
        ])

        let body = Data(#"{"model":"claude-provider-native","input":"ping"}"#.utf8)
        let inferenceHeader = "POST /openai/v1/responses HTTP/1.1\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        var inference = Data(inferenceHeader.utf8)
        inference.append(body)
        let inferenceResult = try transformRequest(
            inference, fragmentSizes: [5, 2, 11], routing: routing
        )
        XCTAssertEqual(inferenceResult.data, inference)
        XCTAssertEqual(
            inferenceResult.requests.first?.route?.outgoingModel,
            "claude-provider-native"
        )
    }

    func testModelsListUsesCodexTiersAndSynthesizesLegacySuccessOnUpstreamFailure() throws {
        let provider = Provider(
            id: "active",
            defaultModel: "primary-upstream",
            smallFastModel: "fast-upstream"
        )
        var config = AppConfig()
        config.activeProviderId = provider.id
        config.providers = [
            provider,
            Provider(
                id: "inactive",
                models: [.init(alias: "inactive-alias", upstream: "inactive-upstream")]
            ),
        ]
        let routing = LegacyModelRoutingCompatibility(config: config)
        let request = Data(
            "GET /v1/models HTTP/1.1\r\nHost: localhost\r\nOriginator: codex_cli_rs\r\n\r\n".utf8
        )
        let requestResult = try transformRequest(
            request, fragmentSizes: [4, 1, 9], routing: routing
        )
        let failureBody = Data("upstream unavailable".utf8)
        let header = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n"
            + "Content-Encoding: gzip\r\nContent-Length: \(failureBody.count)\r\n"
            + "Retry-After: 120\r\nWWW-Authenticate: Bearer realm=\"upstream\"\r\n"
            + "Cache-Control: max-age=3600\r\nAge: 45\r\nSet-Cookie: stale=true\r\n"
            + "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n\r\n"
        var response = Data(header.utf8)
        response.append(failureBody)

        let result = try transformResponse(
            response,
            fragmentSizes: [3, 17, 2],
            requests: requestResult.requests,
            knownModelStore: routing.knownModelStore
        )
        let synthesized = try parseHTTPMessage(result.data)
        XCTAssertEqual(synthesized.startLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(synthesized.headers["content-type"], "application/json")
        XCTAssertNil(synthesized.headers["content-encoding"])
        for stale in [
            "retry-after", "www-authenticate", "cache-control", "age", "set-cookie",
        ] {
            XCTAssertNil(synthesized.headers[stale], stale)
        }
        XCTAssertEqual(synthesized.headers["connection"], "keep-alive")
        XCTAssertEqual(synthesized.headers["keep-alive"], "timeout=5")
        let entries = try XCTUnwrap(
            try jsonObject(synthesized.body)["data"] as? [[String: Any]]
        )
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, [
            "inactive-alias", "gpt-5.4", "gpt-5.4-mini",
        ])
    }

    func testHeadRoot404BecomesFreshSuccessWhileOtherStatusesPassThrough() throws {
        let routing = LegacyModelRoutingCompatibility(provider: Provider(id: "active"))
        let request = Data("HEAD /?probe=1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let requestResult = try transformRequest(
            request, fragmentSizes: [1, 5, 2, 11], routing: routing
        )
        XCTAssertTrue(requestResult.requests.first?.isHeadRoot == true)

        let notFound = Data((
            "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
                + "Content-Length: 999\r\nRetry-After: 60\r\n"
                + "WWW-Authenticate: Bearer\r\nConnection: close\r\n\r\n"
        ).utf8)
        let fallbackResult = try transformResponse(
            notFound,
            fragmentSizes: [2, 1, 17, 3],
            requests: requestResult.requests
        )
        let fallback = try parseHTTPMessage(fallbackResult.data)
        XCTAssertEqual(fallback.startLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(fallback.headers["x-ccbud-fallback"], "head-root-404-to-200")
        XCTAssertEqual(fallback.headers["x-ccbud-upstream-status"], "404")
        XCTAssertEqual(fallback.headers["connection"], "close")
        XCTAssertNil(fallback.headers["content-type"])
        XCTAssertNil(fallback.headers["content-length"])
        XCTAssertNil(fallback.headers["retry-after"])
        XCTAssertNil(fallback.headers["www-authenticate"])
        XCTAssertTrue(fallback.body.isEmpty)

        let methodNotAllowed = Data((
            "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\n\r\n"
        ).utf8)
        let routerFallbackResult = try transformResponse(
            methodNotAllowed,
            fragmentSizes: [4, 1, 9],
            requests: requestResult.requests
        )
        let routerFallback = try parseHTTPMessage(routerFallbackResult.data)
        XCTAssertEqual(routerFallback.startLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(routerFallback.headers["x-ccbud-fallback"], "head-root-404-to-200")
        XCTAssertEqual(routerFallback.headers["x-ccbud-upstream-status"], "405")
        XCTAssertNil(routerFallback.headers["allow"])

        let success = Data(
            "HTTP/1.1 200 OK\r\nX-Upstream: unchanged\r\nContent-Length: 42\r\n\r\n".utf8
        )
        let passthrough = try transformResponse(
            success,
            fragmentSizes: [3, 9, 1],
            requests: requestResult.requests
        )
        XCTAssertEqual(passthrough.data, success)
    }

    func testCountTokensPreservesValidSuccessfulIntegerResponse() throws {
        let requestBody = Data(
            #"{"model":"count-model","messages":[{"role":"user","content":"hello"}]}"#.utf8
        )
        let requestHeader = "POST /v1/messages/count_tokens/?beta=true HTTP/1.1\r\n"
            + "Content-Type: application/json\r\nAccept-Encoding: gzip, br\r\n"
            + "Content-Length: \(requestBody.count)\r\n\r\n"
        var request = Data(requestHeader.utf8)
        request.append(requestBody)
        let routing = LegacyModelRoutingCompatibility(provider: Provider(
            id: "active", defaultModel: "count-model", mapDefaultModels: false
        ))
        let requestResult = try transformRequest(
            request, fragmentSizes: [1, 4, 13, 2], routing: routing
        )
        let rewrittenRequest = try parseHTTPMessage(requestResult.data)
        XCTAssertTrue(rewrittenRequest.startLine.contains("/anthropic/v1/messages/count_tokens"))
        XCTAssertEqual(rewrittenRequest.headers["accept-encoding"], "identity")
        let context = try XCTUnwrap(requestResult.requests.first)
        XCTAssertTrue(context.isCountTokens)
        XCTAssertGreaterThan(try XCTUnwrap(context.countTokensEstimate), 6)

        let upstreamBody = Data(" { \"input_tokens\" : -7 } ".utf8)
        let responseHeader = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n"
            + "X-Upstream-Request-ID: req-7\r\nContent-Length: \(upstreamBody.count)\r\n\r\n"
        var response = Data(responseHeader.utf8)
        response.append(upstreamBody)
        let result = try transformResponse(
            response, fragmentSizes: [1, 2, 19, 3], requests: [context]
        )
        let transformed = try parseHTTPMessage(result.data)
        XCTAssertEqual(transformed.startLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(transformed.headers["x-ccbud-tokens"], "upstream")
        XCTAssertNil(transformed.headers["x-ccbud-upstream-status"])
        XCTAssertEqual(transformed.headers["x-upstream-request-id"], "req-7")
        XCTAssertEqual(transformed.headers["content-length"], String(upstreamBody.count))
        XCTAssertEqual(transformed.body, upstreamBody)
    }

    func testCountTokensSpecialHandlingDoesNotAcceptMultipleTrailingSlashes() throws {
        let requestBody = Data(#"{"model":"count-model","messages":[]}"#.utf8)
        var request = Data((
            "POST /v1/messages/count_tokens//?beta=true HTTP/1.1\r\n"
                + "Content-Type: application/json\r\nAccept-Encoding: gzip\r\n"
                + "Content-Length: \(requestBody.count)\r\n\r\n"
        ).utf8)
        request.append(requestBody)
        let routing = LegacyModelRoutingCompatibility(provider: Provider(
            id: "active", defaultModel: "count-model", mapDefaultModels: false
        ))

        let result = try transformRequest(
            request, fragmentSizes: [2, 1, 7, 3], routing: routing
        )
        let rewritten = try parseHTTPMessage(result.data)
        XCTAssertTrue(rewritten.startLine.contains("/anthropic/v1/messages/count_tokens?beta=true"))
        XCTAssertEqual(rewritten.headers["accept-encoding"], "gzip")
        XCTAssertFalse(try XCTUnwrap(result.requests.first).isCountTokens)
        XCTAssertNil(result.requests.first?.countTokensEstimate)
    }

    func testCountTokensSwitchingProtocolsBecomesClosingEstimate() throws {
        let estimate = 321
        let context = LegacyGatewayRequestContext(
            method: "POST",
            reportsActivity: true,
            isCountTokens: true,
            countTokensEstimate: estimate
        )
        let response = Data((
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n"
                + "Keep-Alive: timeout=5\r\nUpgrade: websocket\r\n\r\n"
                + "unexpected-upgraded-bytes"
        ).utf8)

        let result = try transformResponse(
            response,
            fragmentSizes: [1, 5, 2, 11],
            requests: [context]
        )
        let transformed = try parseHTTPMessage(result.data)
        XCTAssertEqual(transformed.startLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(transformed.headers["x-ccbud-tokens"], "estimated")
        XCTAssertEqual(transformed.headers["x-ccbud-upstream-status"], "101")
        XCTAssertEqual(transformed.headers["connection"], "close")
        XCTAssertNil(transformed.headers["keep-alive"])
        XCTAssertNil(transformed.headers["upgrade"])
        XCTAssertEqual(
            try jsonObject(transformed.body)["input_tokens"] as? Int,
            estimate
        )
        XCTAssertEqual(result.completedResponses, 1)
    }

    func testCountTokensEstimates404NonJSONMissingAndNonIntegerResponses() throws {
        let estimate = 321
        let context = LegacyGatewayRequestContext(
            method: "POST",
            reportsActivity: true,
            isCountTokens: true,
            countTokensEstimate: estimate
        )
        let cases: [(name: String, status: Int, body: Data, chunked: Bool)] = [
            ("404", 404, Data(#"{"input_tokens":999}"#.utf8), false),
            ("non-json", 200, Data("not json".utf8), false),
            ("missing", 200, Data(#"{"type":"count"}"#.utf8), true),
            ("non-integer", 200, Data(#"{"input_tokens":7.0}"#.utf8), true),
        ]

        for item in cases {
            let reason = item.status == 404 ? "Not Found" : "OK"
            var response = Data()
            if item.chunked {
                let split = max(1, item.body.count / 2)
                var wireBody = Data()
                for chunk in [Data(item.body.prefix(split)), Data(item.body.dropFirst(split))]
                where !chunk.isEmpty {
                    wireBody.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
                    wireBody.append(chunk)
                    wireBody.append(Data("\r\n".utf8))
                }
                wireBody.append(Data("0\r\n\r\n".utf8))
                response.append(Data((
                    "HTTP/1.1 \(item.status) \(reason)\r\n"
                        + "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n"
                        + "Retry-After: 90\r\nConnection: keep-alive\r\n\r\n"
                ).utf8))
                response.append(wireBody)
            } else {
                response.append(Data((
                    "HTTP/1.1 \(item.status) \(reason)\r\n"
                        + "Content-Type: application/json\r\nContent-Length: \(item.body.count)\r\n"
                        + "Retry-After: 90\r\nConnection: keep-alive\r\n\r\n"
                ).utf8))
                response.append(item.body)
            }

            let result = try transformResponse(
                response,
                fragmentSizes: [1, 3, 2, 11, 5],
                requests: [context]
            )
            let transformed = try parseHTTPMessage(result.data)
            XCTAssertEqual(transformed.startLine, "HTTP/1.1 200 OK", item.name)
            XCTAssertEqual(transformed.headers["x-ccbud-tokens"], "estimated", item.name)
            XCTAssertEqual(
                transformed.headers["x-ccbud-upstream-status"],
                String(item.status),
                item.name
            )
            XCTAssertEqual(transformed.headers["content-type"], "application/json", item.name)
            XCTAssertEqual(transformed.headers["connection"], "keep-alive", item.name)
            XCTAssertNil(transformed.headers["retry-after"], item.name)
            XCTAssertNil(transformed.headers["transfer-encoding"], item.name)
            XCTAssertEqual(
                try jsonObject(transformed.body)["input_tokens"] as? Int,
                estimate,
                item.name
            )
        }
    }

    func testCountTokensPreservesAuthenticationRejections() throws {
        let context = LegacyGatewayRequestContext(
            method: "POST",
            reportsActivity: true,
            isCountTokens: true,
            countTokensEstimate: 321
        )
        for status in [401, 403] {
            let body = Data("{\"error\":\"denied\"}".utf8)
            var response = Data((
                "HTTP/1.1 \(status) Denied\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\nWWW-Authenticate: Bearer\r\n\r\n"
            ).utf8)
            response.append(body)

            let result = try transformResponse(
                response, fragmentSizes: [1, 7, 2], requests: [context]
            )
            XCTAssertEqual(result.data, response)
            XCTAssertEqual(result.completedResponses, 1)
        }
    }

    func testCountTokensEstimatorMatchesStructuralFallbackAndGrows() {
        XCTAssertEqual(LegacyCountTokensEstimator.estimate([String: Any]()), 6)
        let small = LegacyCountTokensEstimator.estimate([
            "messages": [["role": "user", "content": "hi"]],
        ])
        let large = LegacyCountTokensEstimator.estimate([
            "messages": [[
                "role": "user",
                "content": "hello world, this deliberately has much more UTF-8 text to count",
            ]],
        ])
        let structured = LegacyCountTokensEstimator.estimate([
            "system": [["type": "text", "text": "system prompt"]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64"]],
                    ["type": "tool_use", "name": "lookup", "input": ["city": "Paris"]],
                    ["type": "tool_result", "content": [["type": "text", "text": "sunny"]]],
                ],
            ]],
            "tools": [[
                "name": "lookup",
                "description": "weather lookup",
                "input_schema": ["type": "object"],
            ]],
        ])
        XCTAssertGreaterThan(small, 6)
        XCTAssertGreaterThan(large, small)
        XCTAssertGreaterThan(structured, 1_600)
    }

    func testFixedAndChunkedJSONRequestsRewriteOnlyWhenRoutingChanges() throws {
        let provider = Provider(
            id: "active",
            defaultModel: "primary-upstream",
            smallFastModel: "fast-upstream",
            models: [.init(alias: "claude-explicit", upstream: "explicit-upstream")]
        )
        let routing = LegacyModelRoutingCompatibility(provider: provider)

        let fixedBody = Data(
            #"{ "messages" : [], "model" : "claude-arbitrary", "stream" : false }"#.utf8
        )
        let fixedHeader = "POST /v1/messages HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Content-Type: application/json\r\n"
            + "Accept-Encoding: gzip\r\n"
            + "X-BF-LH-CCBUD-REQUESTED-MODEL-B64: attacker\r\n"
            + "Content-Length: \(fixedBody.count)\r\n\r\n"
        var fixed = Data(fixedHeader.utf8)
        fixed.append(fixedBody)
        let fixedResult = try transformRequest(
            fixed, fragmentSizes: [7, 13, 2, 29, 1, 5], routing: routing
        )
        let fixedHTTP = try parseHTTPMessage(fixedResult.data)
        XCTAssertTrue(fixedHTTP.startLine.contains("/anthropic/v1/messages"))
        XCTAssertEqual(fixedHTTP.headers["accept-encoding"], "identity")
        let encoded = try XCTUnwrap(
            fixedHTTP.headers[LegacyRequestedModelMetadata.headerName]
        )
        XCTAssertEqual(LegacyRequestedModelMetadata.decode(encoded), "claude-arbitrary")
        XCTAssertEqual(
            try jsonObject(fixedHTTP.body)["model"] as? String,
            "primary-upstream"
        )
        XCTAssertEqual(Int(fixedHTTP.headers["content-length"] ?? ""), fixedHTTP.body.count)
        XCTAssertEqual(fixedResult.requests.first?.route?.requestedModel, "claude-arbitrary")

        let chunkJSON = Data(#"{"model":"gpt-4-turbo","input":"ping"}"#.utf8)
        let split = 11
        var chunkedBody = Data()
        for chunk in [Data(chunkJSON.prefix(split)), Data(chunkJSON.dropFirst(split))] {
            chunkedBody.append(Data(String(chunk.count, radix: 16).utf8))
            chunkedBody.append(Data("\r\n".utf8))
            chunkedBody.append(chunk)
            chunkedBody.append(Data("\r\n".utf8))
        }
        chunkedBody.append(Data("0\r\n\r\n".utf8))
        let chunkedHeader = "POST /openai/v1/responses HTTP/1.1\r\n"
            + "Content-Type: application/json\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
        var chunked = Data(chunkedHeader.utf8)
        chunked.append(chunkedBody)
        let chunkedResult = try transformRequest(
            chunked, fragmentSizes: [1, 3, 8, 2, 17], routing: routing
        )
        let chunkedHTTP = try parseHTTPMessage(chunkedResult.data)
        XCTAssertNil(chunkedHTTP.headers["transfer-encoding"])
        XCTAssertEqual(chunkedHTTP.headers["content-length"], String(chunkedHTTP.body.count))
        XCTAssertEqual(
            try jsonObject(chunkedHTTP.body)["model"] as? String,
            "fast-upstream"
        )
    }

    func testExplicitAliasPreservesJSONAndUnchangedRequestIsByteIdentical() throws {
        let provider = Provider(
            id: "active",
            defaultModel: "primary-upstream",
            smallFastModel: "fast-upstream",
            models: [.init(alias: "claude-explicit", upstream: "explicit-upstream")]
        )
        let routing = LegacyModelRoutingCompatibility(provider: provider)
        let explicitBody = Data(#"{ "model" : "claude-explicit", "input" : "exact bytes" }"#.utf8)
        let explicitHeader = "POST /openai/v1/responses HTTP/1.1\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(explicitBody.count)\r\n\r\n"
        var explicit = Data(explicitHeader.utf8)
        explicit.append(explicitBody)
        let explicitResult = try transformRequest(
            explicit, fragmentSizes: [9, 1, 4, 21], routing: routing
        )
        let explicitHTTP = try parseHTTPMessage(explicitResult.data)
        XCTAssertEqual(explicitHTTP.body, explicitBody)
        XCTAssertEqual(
            try jsonObject(explicitHTTP.body)["model"] as? String,
            "claude-explicit"
        )
        XCTAssertTrue(explicitResult.requests.first?.route?.usesNativeAlias == true)

        let directBody = Data(#"{ "model" : "primary-upstream", "input" : "unchanged" }"#.utf8)
        let directHeader = "POST /openai/v1/responses HTTP/1.1\r\n"
            + "cOnTeNt-TyPe: application/json\r\n"
            + "Content-Length: \(directBody.count)\r\n\r\n"
        var direct = Data(directHeader.utf8)
        direct.append(directBody)
        let directResult = try transformRequest(
            direct, fragmentSizes: [2, 5, 13, 1], routing: routing
        )
        XCTAssertEqual(directResult.data, direct)
    }

    func testBufferedAndSSEResponsesRestoreCallerModelAcrossFragments() throws {
        let route = LegacyModelRoute(
            requestedModel: "claude-arbitrary",
            outgoingModel: "primary-upstream",
            usesNativeAlias: false
        )
        let context = LegacyGatewayRequestContext(
            method: "POST", reportsActivity: true, route: route
        )
        let jsonBody = Data(
            #"{"id":"r","model":"mock-upstream","nested":{"model":"keep-nested"}}"#.utf8
        )
        let responseHeader = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "X-Bifrost-Original-Model: primary-upstream\r\n"
            + "X-Bifrost-Resolved-Model: primary-upstream\r\n"
            + "X-Bifrost-Routing-Info-Model: primary-upstream\r\n"
            + "Content-Length: \(jsonBody.count)\r\n\r\n"
        var response = Data(responseHeader.utf8)
        response.append(jsonBody)
        let rewritten = try transformResponse(
            response,
            fragmentSizes: [1, 7, 2, 31, 3],
            requests: [context]
        )
        let message = try parseHTTPMessage(rewritten.data)
        let object = try jsonObject(message.body)
        XCTAssertEqual(object["model"] as? String, "claude-arbitrary")
        XCTAssertEqual((object["nested"] as? [String: Any])?["model"] as? String, "keep-nested")
        XCTAssertEqual(message.headers["x-bifrost-original-model"], "claude-arbitrary")
        XCTAssertEqual(message.headers["x-bifrost-routing-info-model"], "claude-arbitrary")
        XCTAssertEqual(message.headers["x-bifrost-resolved-model"], "primary-upstream")
        XCTAssertEqual(rewritten.completedResponses, 1)

        let sseText = "data: {\"type\":\"response.created\","
            + "\"response\":{\"model\":\"mock-upstream\"}}\n\n"
            + "data: {\"type\":\"message_start\",\"model\":\"mock-upstream\"}\n\n"
            + "data: [DONE]\n\n"
        let sse = Data(sseText.utf8)
        var chunked = Data()
        for chunk in [Data(sse.prefix(19)), Data(sse.dropFirst(19).prefix(37)), Data(sse.dropFirst(56))] {
            chunked.append(Data(String(chunk.count, radix: 16).utf8))
            chunked.append(Data("\r\n".utf8))
            chunked.append(chunk)
            chunked.append(Data("\r\n".utf8))
        }
        chunked.append(Data("0\r\n\r\n".utf8))
        let streamHeader = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
        var streamResponse = Data(streamHeader.utf8)
        streamResponse.append(chunked)
        let streamResult = try transformResponse(
            streamResponse,
            fragmentSizes: [2, 1, 11, 5, 3, 29],
            requests: [context]
        )
        let streamMessage = try parseHTTPMessage(streamResult.data)
        let decoded = try decodeChunked(streamMessage.body)
        let streamText = String(decoding: decoded, as: UTF8.self)
        XCTAssertTrue(streamText.contains(#""model":"claude-arbitrary""#), streamText)
        XCTAssertFalse(streamText.contains("mock-upstream"), streamText)
        XCTAssertTrue(streamText.contains("data: [DONE]"), streamText)
        XCTAssertEqual(streamResult.completedResponses, 1)
    }

    func testUnroutedResponseRemainsByteIdentical() throws {
        let body = Data(#"{"model":"upstream","ok":true}"#.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        let context = LegacyGatewayRequestContext(method: "POST", reportsActivity: true)
        let result = try transformResponse(
            response, fragmentSizes: [3, 17, 1, 4], requests: [context]
        )
        XCTAssertEqual(result.data, response)
        XCTAssertEqual(result.completedResponses, 1)
    }

    func testLargeChildOutputIsContinuouslyDrainedAndBounded() async throws {
        let fixture = try makeExecutable(
            named: "flood-output",
            contents: """
            #!/bin/sh
            i=0
            while [ "$i" -lt 5000 ]; do
              printf 'OUT-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i"
              printf 'ERR-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i" >&2
              i=$((i + 1))
            done
            exit 23
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let supervisor = BifrostSupervisor(
            environment: fixture.environment,
            logByteLimitPerStream: 2_048,
            healthCheckAttempts: 2_000,
            healthCheckIntervalNanoseconds: 1_000_000
        )

        do {
            try await supervisor.start(config: try testConfig())
            XCTFail("Expected the short-lived child to fail startup")
        } catch let error as BifrostError {
            guard case let .startupFailed(reason, failureDiagnostics) = error else {
                XCTFail("Expected startup diagnostics, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("23"), "Unexpected failure reason: \(reason)")
            XCTAssertEqual(failureDiagnostics.standardOutputBytes, 2_048)
            XCTAssertEqual(failureDiagnostics.standardErrorBytes, 2_048)
            XCTAssertTrue(failureDiagnostics.standardOutput.contains("OUT-4999"))
            XCTAssertTrue(failureDiagnostics.standardError.contains("ERR-4999"))
            let supervisorDiagnostics = await supervisor.diagnostics
            XCTAssertEqual(supervisorDiagnostics, failureDiagnostics)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let readersAfterFailure = await supervisor.hasActiveOutputReaders
        XCTAssertFalse(readersAfterFailure)
        guard case .failed(let message) = await supervisor.state else {
            XCTFail("Expected failed state")
            return
        }
        XCTAssertTrue(message.contains("ERR-4999"))
    }

    func testHealthTimeoutExposesBothOutputStreams() async throws {
        let fixture = try makeExecutable(
            named: "health-timeout",
            contents: """
            #!/bin/sh
            echo 'booting-bifrost'
            echo 'bind diagnostic from stderr' >&2
            : > "$2/output-ready"
            trap 'exit 0' TERM
            while :; do sleep 1; done
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let appHome = try XCTUnwrap(fixture.environment["CCBUD_HOME"])
        let readinessFile = URL(fileURLWithPath: appHome)
            .appendingPathComponent("bifrost/output-ready")
        UnhealthyURLProtocol.requireReadinessFile(readinessFile)
        defer { UnhealthyURLProtocol.clearReadinessFile() }
        let session = makeSession(protocolClass: UnhealthyURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let supervisor = BifrostSupervisor(
            session: session,
            environment: fixture.environment,
            logByteLimitPerStream: 4_096,
            healthCheckAttempts: 40,
            healthCheckIntervalNanoseconds: 50_000_000
        )
        var lifecycleChanges = supervisor.stateChanges.makeAsyncIterator()

        do {
            try await supervisor.start(config: try testConfig())
            XCTFail("Expected health check timeout")
        } catch let error as BifrostError {
            guard case let .startupFailed(reason, failureDiagnostics) = error else {
                XCTFail("Expected startup diagnostics, got \(error)")
                return
            }
            XCTAssertEqual(reason, BifrostError.healthTimeout.localizedDescription)
            XCTAssertTrue(failureDiagnostics.standardOutput.contains("booting-bifrost"))
            XCTAssertTrue(failureDiagnostics.standardError.contains("bind diagnostic from stderr"))
            XCTAssertTrue(error.localizedDescription.contains("stderr:"))
            XCTAssertTrue(error.localizedDescription.contains("stdout:"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let readersAfterTimeout = await supervisor.hasActiveOutputReaders
        XCTAssertFalse(readersAfterTimeout)
        guard case .failed(let message) = await supervisor.state else {
            XCTFail("Expected failed state")
            return
        }
        XCTAssertTrue(message.contains("bind diagnostic from stderr"))
        _ = await lifecycleChanges.next() // initial stopped state
        _ = await lifecycleChanges.next() // starting state
        guard case .failed(let streamedFailure) = await lifecycleChanges.next() else {
            XCTFail("Expected a streamed startup failure")
            return
        }
        XCTAssertFalse(streamedFailure.contains("bind diagnostic from stderr"))
    }

    func testStopDetachesReadersAndRetainsFinalBoundedSnapshot() async throws {
        let fixture = try makeExecutable(
            named: "running-output",
            contents: """
            #!/bin/sh
            trap 'exit 0' TERM
            printf 'live-out-%04d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' 0
            printf 'live-err-%04d-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n' 0 >&2
            : > "$2/output-ready"
            i=1
            while :; do
              printf 'live-out-%04d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' "$i"
              printf 'live-err-%04d-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\\n' "$i" >&2
              i=$((i + 1))
              sleep 0.01
            done
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let appHome = try XCTUnwrap(fixture.environment["CCBUD_HOME"])
        let readinessFile = URL(fileURLWithPath: appHome)
            .appendingPathComponent("bifrost/output-ready")
        HealthyURLProtocol.requireReadinessFile(readinessFile)
        defer { HealthyURLProtocol.clearReadinessFile() }
        let session = makeSession(protocolClass: HealthyURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let supervisor = BifrostSupervisor(
            session: session,
            environment: fixture.environment,
            logByteLimitPerStream: 512
        )

        try await supervisor.start(config: try testConfig())
        let readersWhileRunning = await supervisor.hasActiveOutputReaders
        XCTAssertTrue(readersWhileRunning)
        for _ in 0..<1_000 {
            if !(await supervisor.diagnostics).isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let liveDiagnostics = await supervisor.diagnostics
        XCTAssertFalse(liveDiagnostics.isEmpty)

        let stopStartedAt = Date()
        await supervisor.stop()
        XCTAssertLessThan(
            Date().timeIntervalSince(stopStartedAt),
            2,
            "Closing the parent pipe writers must allow drain to observe EOF promptly"
        )
        let readersAfterStop = await supervisor.hasActiveOutputReaders
        let stateAfterStop = await supervisor.state
        XCTAssertFalse(readersAfterStop)
        XCTAssertEqual(stateAfterStop, .stopped)
        let stoppedDiagnostics = await supervisor.diagnostics
        XCTAssertLessThanOrEqual(stoppedDiagnostics.standardOutputBytes, 512)
        XCTAssertLessThanOrEqual(stoppedDiagnostics.standardErrorBytes, 512)

        try await Task.sleep(nanoseconds: 50_000_000)
        let laterDiagnostics = await supervisor.diagnostics
        XCTAssertEqual(laterDiagnostics, stoppedDiagnostics)
    }

    func testOverlappingStartsCannotLetOldCleanupOrExitClobberNewGeneration() async throws {
        let fixture = try makeExecutable(
            named: "overlapping-starts",
            contents: """
            #!/bin/sh
            printf '%s\n' "$$" >> "$2/launches"
            trap 'exit 0' TERM
            while :; do sleep 1; done
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let firstHealthHeld = expectation(description: "first generation health is held")
        FirstRequestHoldingURLProtocol.holdFirstRequest {
            firstHealthHeld.fulfill()
        }
        defer {
            FirstRequestHoldingURLProtocol.releaseFirstRequest()
            FirstRequestHoldingURLProtocol.reset()
        }
        let session = makeSession(protocolClass: FirstRequestHoldingURLProtocol.self)
        defer { session.invalidateAndCancel() }

        let oldTerminationEntered = expectation(description: "old termination observation entered")
        let oldTerminationHandled = expectation(description: "old termination observation handled")
        let terminationGate = FirstTerminationObservationGate(
            entered: oldTerminationEntered,
            handled: oldTerminationHandled
        )
        let supervisor = BifrostSupervisor(
            session: session,
            environment: fixture.environment,
            healthCheckAttempts: 100,
            healthCheckIntervalNanoseconds: 1_000_000,
            processTerminationObserver: { observation in
                await terminationGate.observe(observation)
            }
        )
        addTeardownBlock {
            await terminationGate.release()
            FirstRequestHoldingURLProtocol.releaseFirstRequest()
            await supervisor.stop()
        }

        let firstConfig = try testConfig()
        var secondConfig = try testConfig()
        while secondConfig.port == firstConfig.port { secondConfig = try testConfig() }

        let firstStart = Task { try await supervisor.start(config: firstConfig) }
        await fulfillment(of: [firstHealthHeld], timeout: 3)

        let secondStart = Task { try await supervisor.start(config: secondConfig) }
        await fulfillment(of: [oldTerminationEntered], timeout: 3)
        try await secondStart.value
        let stateAfterSecondStart = await supervisor.state
        let readersAfterSecondStart = await supervisor.hasActiveOutputReaders
        XCTAssertEqual(stateAfterSecondStart, .running(port: secondConfig.port))
        XCTAssertTrue(readersAfterSecondStart)

        // Deliver the old process callback only after generation two is demonstrably running.
        await terminationGate.release()
        await fulfillment(of: [oldTerminationHandled], timeout: 3)
        let stateAfterOldExit = await supervisor.state
        let readersAfterOldExit = await supervisor.hasActiveOutputReaders
        XCTAssertEqual(stateAfterOldExit, .running(port: secondConfig.port))
        XCTAssertTrue(readersAfterOldExit)

        // Now resume generation one's stale health await and prove its catch path is also inert.
        FirstRequestHoldingURLProtocol.releaseFirstRequest()
        do {
            try await firstStart.value
            XCTFail("The superseded first start should be cancelled")
        } catch is CancellationError {
            // Expected: the newer start owns the supervisor now.
        } catch {
            XCTFail("Expected CancellationError for superseded start, got \(error)")
        }
        let stateAfterOldStart = await supervisor.state
        let readersAfterOldStart = await supervisor.hasActiveOutputReaders
        XCTAssertEqual(stateAfterOldStart, .running(port: secondConfig.port))
        XCTAssertTrue(readersAfterOldStart)

        await supervisor.stop()
        let stoppedState = await supervisor.state
        let readersAfterStop = await supervisor.hasActiveOutputReaders
        XCTAssertEqual(stoppedState, .stopped)
        XCTAssertFalse(readersAfterStop)
    }

    func testPostRunningProcessExitPublishesFailureAndTearsDownMatchingResources() async throws {
        let fixture = try makeExecutable(
            named: "post-running-exit",
            contents: """
            #!/bin/sh
            trap 'exit 0' TERM
            : > "$2/output-ready"
            while [ ! -f "$2/exit-now" ]; do sleep 0.01; done
            printf 'post-running-exit-marker\n' >&2
            exit 37
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let appHome = try XCTUnwrap(fixture.environment["CCBUD_HOME"])
        let appDirectory = URL(fileURLWithPath: appHome, isDirectory: true)
            .appendingPathComponent("bifrost", isDirectory: true)
        HealthyURLProtocol.requireReadinessFile(appDirectory.appendingPathComponent("output-ready"))
        defer { HealthyURLProtocol.clearReadinessFile() }
        let session = makeSession(protocolClass: HealthyURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let supervisor = BifrostSupervisor(session: session, environment: fixture.environment)
        addTeardownBlock { await supervisor.stop() }
        var stateChanges = supervisor.stateChanges.makeAsyncIterator()
        let initialStateChange = await stateChanges.next()
        XCTAssertEqual(initialStateChange, .stopped)

        let config = try testConfig()
        try await supervisor.start(config: config)
        let startingStateChange = await stateChanges.next()
        let runningStateChange = await stateChanges.next()
        let runningState = await supervisor.state
        let readersWhileRunning = await supervisor.hasActiveOutputReaders
        XCTAssertEqual(startingStateChange, .starting)
        XCTAssertEqual(runningStateChange, .running(port: config.port))
        XCTAssertEqual(runningState, .running(port: config.port))
        XCTAssertTrue(readersWhileRunning)

        try Data().write(to: appDirectory.appendingPathComponent("exit-now"))
        let deadline = Date().addingTimeInterval(3)
        while (await supervisor.state).isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard case .failed(let message) = await supervisor.state else {
            XCTFail("Expected a failed state after the running sidecar exited")
            return
        }
        XCTAssertTrue(message.contains("37"), message)
        guard case .failed(let streamedMessage) = await stateChanges.next() else {
            XCTFail("Expected the state stream to publish the post-running failure")
            return
        }
        XCTAssertEqual(streamedMessage, message)
        let readersAfterExit = await supervisor.hasActiveOutputReaders
        let diagnosticsAfterExit = await supervisor.diagnostics
        XCTAssertFalse(readersAfterExit)
        XCTAssertTrue(diagnosticsAfterExit.standardError.contains("post-running-exit-marker"))

        var publicPortWasReleased = canBindLoopbackPort(config.port)
        while !publicPortWasReleased, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            publicPortWasReleased = canBindLoopbackPort(config.port)
        }
        XCTAssertTrue(publicPortWasReleased, "The exited generation's proxy still owns its public port")
    }

    func testProcessLaunchFailureDoesNotLeaveStartingStateOrReaders() async throws {
        let fixture = try makeExecutable(
            named: "invalid-executable",
            contents: "this is not an executable image"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let supervisor = BifrostSupervisor(environment: fixture.environment)

        do {
            try await supervisor.start(config: try testConfig())
            XCTFail("Expected Process.run() to fail")
        } catch let error as BifrostError {
            guard case let .startupFailed(reason, failureDiagnostics) = error else {
                XCTFail("Expected wrapped startup failure, got \(error)")
                return
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(failureDiagnostics.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let readersAfterLaunchFailure = await supervisor.hasActiveOutputReaders
        XCTAssertFalse(readersAfterLaunchFailure)
        guard case .failed = await supervisor.state else {
            XCTFail("Expected failed state")
            return
        }
        let appHome = try XCTUnwrap(fixture.environment["CCBUD_HOME"])
        let configPath = URL(fileURLWithPath: appHome)
            .appendingPathComponent("bifrost/config.json").path
        let attributes = try FileManager.default.attributesOfItem(atPath: configPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o777, 0o600)
        let directoryPath = URL(fileURLWithPath: appHome)
            .appendingPathComponent("bifrost", isDirectory: true).path
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directoryPath)
        let directoryPermissions = try XCTUnwrap(directoryAttributes[.posixPermissions] as? Int)
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)

        let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let governance = try XCTUnwrap(root["governance"] as? [String: Any])
        let auth = try XCTUnwrap(governance["auth_config"] as? [String: Any])
        XCTAssertEqual(auth["is_enabled"] as? Bool, true)
        XCTAssertTrue(auth["admin_username"] as? String == supervisor.managementCredentials.username)
        XCTAssertTrue(auth["admin_password"] as? String == supervisor.managementCredentials.password)
        XCTAssertNil(root["auth_config"])
    }

    func testEachSupervisorOwnsDifferentProcessLocalManagementCredentials() {
        let first = BifrostSupervisor(environment: [:])
        let second = BifrostSupervisor(environment: [:])

        XCTAssertFalse(first.managementCredentials == second.managementCredentials)
    }

    func testRejectsPreseededBifrostDirectorySymlinkBeforeAnyWrite() async throws {
        let fixture = try makeExecutable(named: "symlink-escape", contents: "invalid")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let home = URL(
            fileURLWithPath: try XCTUnwrap(fixture.environment["CCBUD_HOME"]),
            isDirectory: true
        )
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("bifrost", isDirectory: true),
            withDestinationURL: outside
        )

        let supervisor = BifrostSupervisor(environment: fixture.environment)
        do {
            try await supervisor.start(config: try testConfig())
            XCTFail("Expected the symlinked app directory to be rejected")
        } catch let error as BifrostError {
            guard case .unsafeAppDirectory = error else {
                XCTFail("Unexpected Bifrost error: \(error)")
                return
            }
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("config.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent(BifrostConfigBuilder.modelParametersFileName).path
        ))
    }

    func testTrimsHomeOverrideBeforeResolvingBifrostDirectory() async throws {
        let fixture = try makeExecutable(
            named: "trimmed-home",
            contents: "this is not an executable image"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawHome = try XCTUnwrap(fixture.environment["CCBUD_HOME"])
        var environment = fixture.environment
        environment["CCBUD_HOME"] = "  \(rawHome)  "
        let supervisor = BifrostSupervisor(environment: environment)

        do {
            try await supervisor.start(config: try testConfig())
            XCTFail("Expected Process.run() to reject the invalid executable")
        } catch {
            // The launch failure is immaterial; directory resolution happens first.
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: rawHome, isDirectory: true)
                .appendingPathComponent("bifrost/config.json").path
        ))
    }

    private func makeExecutable(named name: String, contents: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return Fixture(root: root, environment: [
            "CCBUD_HOME": root.appendingPathComponent("home", isDirectory: true).path,
            "CCBUD_BIFROST_BINARY": executable.path,
        ])
    }

    private func transformRequest(
        _ data: Data,
        fragmentSizes: [Int],
        routing: LegacyModelRoutingCompatibility
    ) throws -> LegacyHTTPRequestTransformResult {
        var transformer = LegacyHTTPRequestStreamRewriter(modelRouting: routing)
        var cursor = 0
        var output = Data()
        var requests: [LegacyGatewayRequestContext] = []
        var continueResponses = 0
        var sizeIndex = 0
        while cursor < data.count {
            let requestedSize = fragmentSizes[sizeIndex % fragmentSizes.count]
            let count = min(max(1, requestedSize), data.count - cursor)
            let result = try transformer.transform(data.subdata(in: cursor..<(cursor + count)))
            output.append(result.data)
            requests.append(contentsOf: result.requests)
            continueResponses += result.continueResponses
            cursor += count
            sizeIndex += 1
        }
        return .init(
            data: output,
            requests: requests,
            continueResponses: continueResponses
        )
    }

    private func transformResponse(
        _ data: Data,
        fragmentSizes: [Int],
        requests initialRequests: [LegacyGatewayRequestContext],
        knownModelStore: LegacyKnownModelStore = LegacyKnownModelStore()
    ) throws -> LegacyHTTPResponseTransformResult {
        var transformer = LegacyHTTPResponseStreamRewriter(
            knownModelStore: knownModelStore
        )
        var requests = initialRequests
        var cursor = 0
        var output = Data()
        var completedResponses = 0
        var sizeIndex = 0
        while cursor < data.count {
            let requestedSize = fragmentSizes[sizeIndex % fragmentSizes.count]
            let count = min(max(1, requestedSize), data.count - cursor)
            cursor += count
            let result = try transformer.transform(
                data.subdata(in: (cursor - count)..<cursor),
                requests: &requests,
                streamComplete: cursor == data.count
            )
            output.append(result.data)
            completedResponses += result.completedResponses
            sizeIndex += 1
        }
        return .init(data: output, completedResponses: completedResponses)
    }

    private func parseHTTPMessage(_ data: Data) throws -> (
        startLine: String,
        headers: [String: String],
        body: Data
    ) {
        let delimiter = Data("\r\n\r\n".utf8)
        let range = try XCTUnwrap(data.range(of: delimiter))
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (
            try XCTUnwrap(lines.first),
            headers,
            Data(data[range.upperBound...])
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeChunked(_ data: Data) throws -> Data {
        var pending = data
        var decoded = Data()
        let lineEnd = Data("\r\n".utf8)
        while true {
            let sizeRange = try XCTUnwrap(pending.range(of: lineEnd))
            let sizeText = String(decoding: pending[..<sizeRange.lowerBound], as: UTF8.self)
            let size = try XCTUnwrap(Int(sizeText, radix: 16))
            pending.removeSubrange(..<sizeRange.upperBound)
            if size == 0 {
                XCTAssertTrue(pending.starts(with: lineEnd))
                return decoded
            }
            XCTAssertGreaterThanOrEqual(pending.count, size + 2)
            decoded.append(pending.prefix(size))
            pending.removeFirst(size)
            XCTAssertTrue(pending.starts(with: lineEnd))
            pending.removeFirst(2)
        }
    }

    private func testConfig() throws -> AppConfig {
        var config = AppConfig.fixture
        config.port = try availableLoopbackPort()
        return config
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
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func canBindLoopbackPort(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func makeSession(protocolClass: URLProtocol.Type) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }
}

private struct Fixture {
    let root: URL
    let environment: [String: String]
}

private actor FirstTerminationObservationGate {
    private let entered: XCTestExpectation
    private let handled: XCTestExpectation
    private var isFirstObservation = true
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(entered: XCTestExpectation, handled: XCTestExpectation) {
        self.entered = entered
        self.handled = handled
    }

    func observe(_ observation: @Sendable () async -> Void) async {
        let shouldHold = isFirstObservation
        isFirstObservation = false
        if shouldHold {
            entered.fulfill()
            if !isReleased {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        await observation()
        if shouldHold { handled.fulfill() }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class FirstRequestHoldingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var shouldHoldFirstRequest = false
    nonisolated(unsafe) private static var didHoldFirstRequest = false
    nonisolated(unsafe) private static var pendingRequest: FirstRequestHoldingURLProtocol?
    nonisolated(unsafe) private static var onHold: (() -> Void)?

    static func holdFirstRequest(onHold: @escaping () -> Void) {
        stateLock.lock()
        shouldHoldFirstRequest = true
        didHoldFirstRequest = false
        pendingRequest = nil
        self.onHold = onHold
        stateLock.unlock()
    }

    static func releaseFirstRequest() {
        stateLock.lock()
        let request = pendingRequest
        pendingRequest = nil
        stateLock.unlock()
        request?.respond(statusCode: 200)
    }

    static func reset() {
        releaseFirstRequest()
        stateLock.lock()
        shouldHoldFirstRequest = false
        didHoldFirstRequest = false
        onHold = nil
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.stateLock.lock()
        let shouldHold = Self.shouldHoldFirstRequest && !Self.didHoldFirstRequest
        let onHold = shouldHold ? Self.onHold : nil
        if shouldHold {
            Self.didHoldFirstRequest = true
            Self.pendingRequest = self
        }
        Self.stateLock.unlock()

        if shouldHold {
            onHold?()
        } else {
            respond(statusCode: 200)
        }
    }

    private func respond(statusCode: Int) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class HealthyURLProtocol: URLProtocol {
    private static let stateLock = NSLock()
    // Access is serialized by stateLock; the annotation makes that synchronization contract
    // explicit to complete strict-concurrency checking.
    nonisolated(unsafe) private static var readinessFile: URL?

    static func requireReadinessFile(_ file: URL) {
        stateLock.lock()
        readinessFile = file
        stateLock.unlock()
    }

    static func clearReadinessFile() {
        stateLock.lock()
        readinessFile = nil
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.stateLock.lock()
        let readinessFile = Self.readinessFile
        Self.stateLock.unlock()
        let status = readinessFile.map {
            FileManager.default.fileExists(atPath: $0.path) ? 200 : 503
        } ?? 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class UnhealthyURLProtocol: URLProtocol {
    private static let stateLock = NSLock()
    // Access is serialized by stateLock; the annotations make that synchronization contract
    // explicit to complete strict-concurrency checking.
    nonisolated(unsafe) private static var readinessFile: URL?
    nonisolated(unsafe) private static var didWaitForReadiness = false

    static func requireReadinessFile(_ file: URL) {
        stateLock.lock()
        readinessFile = file
        didWaitForReadiness = false
        stateLock.unlock()
    }

    static func clearReadinessFile() {
        stateLock.lock()
        readinessFile = nil
        didWaitForReadiness = false
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.stateLock.lock()
        let readinessFile = Self.readinessFile
        let shouldWait = readinessFile != nil && !Self.didWaitForReadiness
        if shouldWait { Self.didWaitForReadiness = true }
        Self.stateLock.unlock()

        if shouldWait, let readinessFile {
            // Do not consume the supervisor's short health-check budget before the fixture child
            // has actually executed and emitted both diagnostic lines. Under a heavily loaded full
            // suite, Process.run() can return before the child receives its first scheduler slice.
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: readinessFile.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
