import XCTest
@testable import CCBuddy

final class BifrostLogDecodingTests: XCTestCase {
    func testProcessingLogToleratesMissingLatencyAndErrorAndRetainsProviderFields() throws {
        let data = Data(#"""
        {
          "id": "78d1a21a-ff5c-4d44-9774-a769cd0dfcb1",
          "provider": "anthropic",
          "model": "claude-test",
          "status": "processing",
          "timestamp": "2026-08-22T01:02:03.123456789Z",
          "input_history": [{"role":"user","content":"hello"}],
          "params": {"temperature":0.25},
          "vendor_trace": {"region":"sg", "attempt":2},
          "speech_input": {"input":"speak this"},
          "token_usage": {"input_tokens":7, "total_tokens":7, "cache_read_tokens":3},
          "future_server_field": [1, true, null]
        }
        """#.utf8)

        let log = try JSONDecoder().decode(BifrostLog.self, from: data)

        XCTAssertEqual(log.id, "78d1a21a-ff5c-4d44-9774-a769cd0dfcb1")
        XCTAssertEqual(log.status, .processing)
        XCTAssertTrue(log.isProcessing)
        XCTAssertFalse(log.isTerminal)
        XCTAssertNil(log.latency)
        XCTAssertNil(log.errorDetails)
        XCTAssertNotNil(log.timestamp)
        XCTAssertEqual(log.tokenUsage?.inputTokens, 7)
        XCTAssertEqual(log.tokenUsage?.additionalFields["cache_read_tokens"], .number(3))
        XCTAssertEqual(
            log.additionalFields["vendor_trace"],
            .object(["region": .string("sg"), "attempt": .number(2)])
        )
        XCTAssertEqual(log.additionalFields["future_server_field"], .array([.number(1), .bool(true), .null]))

        guard case .object(let normalized)? = log.normalizedRequest else {
            return XCTFail("Expected the real normalized request fragments")
        }
        XCTAssertNotNil(normalized["input_history"])
        XCTAssertEqual(normalized["params"], .object(["temperature": .number(0.25)]))
        XCTAssertEqual(normalized["speech_input"], .object(["input": .string("speak this")]))
    }

    func testDetailKeepsRawAndNormalizedPayloadsSeparate() throws {
        let data = Data(#"""
        {
          "id": "4ef4edab-dac5-488f-9c83-6bc85b2ead39",
          "provider": "openai",
          "selected_key_name": "Primary OpenAI Key",
          "model": "gpt-test",
          "alias": "requested-model",
          "status": "error",
          "raw_request": "{\"wire_model\":\"gpt-test\"}",
          "raw_response": "{\"error\":\"rate_limited\"}",
          "is_large_payload_request": true,
          "is_large_payload_response": false,
          "responses_input_history": [{"role":"user","content":[{"type":"input_text","text":"hi"}]}],
          "responses_output": [{"type":"message","role":"assistant","content":[]}],
          "error_details": {
            "is_bifrost_error": false,
            "status_code": 429,
            "error": {"message":"rate limited", "provider_code":"slow_down"}
          },
          "image_generation_output": {"data":[{"url":"https://example.test/image.png"}]}
        }
        """#.utf8)

        let log = try JSONDecoder().decode(BifrostLog.self, from: data)

        XCTAssertEqual(log.rawRequest, #"{"wire_model":"gpt-test"}"#)
        XCTAssertEqual(log.rawResponse, #"{"error":"rate_limited"}"#)
        XCTAssertTrue(log.isLargePayloadRequest)
        XCTAssertFalse(log.isLargePayloadResponse)
        XCTAssertNil(log.additionalFields["is_large_payload_request"])
        XCTAssertEqual(log.selectedKeyName, "Primary OpenAI Key")
        XCTAssertEqual(log.displayProvider, "Primary OpenAI Key")
        XCTAssertEqual(log.requestedModel, "requested-model")
        XCTAssertEqual(log.outgoingModel, "gpt-test")
        XCTAssertEqual(log.errorStatusCode, 429)
        XCTAssertEqual(log.httpStatusCode, 429)
        XCTAssertTrue(log.isTerminal)
        XCTAssertTrue(log.isError)
        XCTAssertNil(log.latency)
        XCTAssertNotNil(log.normalizedRequest)
        guard case .object(let normalized)? = log.normalizedResponse else {
            return XCTFail("Expected multiple normalized response fragments")
        }
        XCTAssertNotNil(normalized["responses_output"])
        XCTAssertNotNil(normalized["error_details"])
        XCTAssertNotNil(normalized["image_generation_output"])
        XCTAssertNil(normalized["raw_response"])
    }

    func testMissingAndUnknownStatusValuesRemainDecodable() throws {
        let missing = try JSONDecoder().decode(BifrostLog.self, from: Data(#"{"id":"plain-string-id"}"#.utf8))
        XCTAssertEqual(missing.id, "plain-string-id")
        XCTAssertEqual(missing.status, .unknown(""))
        XCTAssertFalse(missing.isTerminal)

        let future = try JSONDecoder().decode(
            BifrostLog.self,
            from: Data(#"{"id":"plain-string-id","status":"queued_by_provider"}"#.utf8)
        )
        XCTAssertEqual(future.status, .unknown("queued_by_provider"))
        XCTAssertFalse(future.isTerminal)
    }

    func testPageAndStatsUseDefaultsForVersionSkew() throws {
        let page = try JSONDecoder().decode(
            BifrostLogPage.self,
            from: Data(#"{"logs":[{"id":"one","status":"success"}],"pagination":{"limit":100,"offset":0}}"#.utf8)
        )
        XCTAssertTrue(page.hasLogs)
        XCTAssertEqual(page.logs.count, 1)
        XCTAssertEqual(page.pagination.limit, 100)
        XCTAssertEqual(page.pagination.totalCount, 0)

        let stats = try JSONDecoder().decode(
            BifrostLogStats.self,
            from: Data(#"{"total_requests":2,"total_tokens":9,"total_cost":0.02}"#.utf8)
        )
        XCTAssertEqual(stats.totalRequests, 2)
        XCTAssertEqual(stats.totalTokens, 9)
        XCTAssertEqual(stats.totalCost, 0.02)
        XCTAssertNil(stats.averageLatency)
        XCTAssertNil(stats.successRate)
    }

    func testStatsPreferDivergentUserFacingRootRequestMetrics() throws {
        let stats = try JSONDecoder().decode(
            BifrostLogStats.self,
            from: Data(#"""
            {
              "total_requests": 9,
              "success_rate": 55.5,
              "user_facing_total_requests": 4,
              "user_facing_success_rate": 75
            }
            """#.utf8)
        )

        XCTAssertEqual(stats.totalRequests, 9)
        XCTAssertEqual(stats.successRate, 55.5)
        XCTAssertEqual(stats.userFacingTotalRequests, 4)
        XCTAssertEqual(stats.userFacingSuccessRate, 75)
        XCTAssertEqual(stats.rootRequestCount, 4)
        XCTAssertEqual(stats.rootSuccessRate, 75)

        let legacy = BifrostLogStats(totalRequests: 3, successRate: 100)
        XCTAssertEqual(legacy.rootRequestCount, 3)
        XCTAssertEqual(legacy.rootSuccessRate, 100)
    }

    func testTrustedCompatibilityMetadataRestoresRequestedModelWithoutHeaderSyntax() throws {
        let requested = "claude-自定义\r\nnot-a-header"
        let encoded = LegacyRequestedModelMetadata.encode(requested)
        XCTAssertFalse(encoded.contains("\r"))
        XCTAssertFalse(encoded.contains("\n"))
        XCTAssertEqual(LegacyRequestedModelMetadata.decode(encoded), requested)

        let payload: [String: Any] = [
            "id": "routed",
            "model": "primary-upstream",
            "alias": "wrong-native-alias",
            "status": "success",
            "metadata": [LegacyRequestedModelMetadata.metadataKey: encoded],
        ]
        let log = try JSONDecoder().decode(
            BifrostLog.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(log.requestedModel, "wrong-native-alias")

        let restored = log.restoringLegacyRequestedModel()
        XCTAssertEqual(restored.requestedModel, requested)
        XCTAssertEqual(restored.outgoingModel, "primary-upstream")

        var invalid = log
        invalid.additionalFields["metadata"] = .object([
            LegacyRequestedModelMetadata.metadataKey: .string("not base64 !")
        ])
        XCTAssertEqual(
            invalid.restoringLegacyRequestedModel().requestedModel,
            "wrong-native-alias"
        )
    }
}
