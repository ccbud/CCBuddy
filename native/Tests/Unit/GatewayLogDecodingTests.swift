import Foundation
import XCTest
@testable import CCBuddy

final class GatewayLogDecodingTests: XCTestCase {
    func testListResponseDecodesCurrentHelperSchema() throws {
        let page = try JSONDecoder().decode(GatewayLogPage.self, from: Data(#"""
        {
          "data": [{
            "id": 42,
            "startedAt": "2026-08-24T10:11:12.123Z",
            "elapsedMs": 37,
            "method": "POST",
            "path": "/v1/messages",
            "status": 200,
            "clientModel": "claude-sonnet-4-6",
            "providerId": "primary",
            "providerName": "Primary Provider",
            "attempts": 2,
            "translation": "anthropic → openai-chat",
            "error": null
          }]
        }
        """#.utf8))

        let log = try XCTUnwrap(page.logs.first)
        XCTAssertEqual(log.id, "42")
        XCTAssertEqual(log.elapsedMs, 37)
        XCTAssertEqual(log.routeLabel, "POST /v1/messages")
        XCTAssertEqual(log.requestedModel, "claude-sonnet-4-6")
        XCTAssertEqual(log.displayProvider, "Primary Provider")
        XCTAssertEqual(log.numberOfRetries, 1)
        XCTAssertEqual(log.status, .success)
        XCTAssertNotNil(log.startedAt)
    }

    func testDetailDecodesAllFourCaptureBoundariesLosslessly() throws {
        let log = try JSONDecoder().decode(GatewayLog.self, from: Data(#"""
        {
          "id": 7,
          "startedAt": "2026-08-24T10:11:12Z",
          "elapsedMs": 91,
          "method": "POST",
          "path": "/v1/responses",
          "status": 429,
          "clientModel": "client-model",
          "providerId": "secondary",
          "providerName": "Secondary",
          "attempts": 3,
          "translation": null,
          "error": "rate limited",
          "clientRequest": {"headers":{"authorization":"<redacted>"},"body":"{\"model\":\"client-model\",\"stream\":true}","truncated":false},
          "upstreamRequest": {"headers":{"x-api-key":"<redacted>"},"body":"{\"model\":\"upstream-model\"}","truncated":false},
          "upstreamResponse": {"headers":{"content-type":"application/json"},"body":"{\"error\":\"limited\"}","truncated":true},
          "clientResponse": {"headers":{},"body":"{\"error\":\"limited\"}","truncated":false}
        }
        """#.utf8))

        XCTAssertEqual(log.status, .error)
        XCTAssertEqual(log.errorStatusCode, 429)
        XCTAssertEqual(log.outgoingModel, "upstream-model")
        XCTAssertEqual(log.stream, true)
        XCTAssertEqual(log.clientRequest?.headers, .object(["authorization": .string("<redacted>")]))
        XCTAssertEqual(log.upstreamResponse?.truncated, true)
        XCTAssertNotNil(log.clientResponse)
    }

    func testMissingHTTPStatusIsProcessingUntilErrorAppears() {
        XCTAssertEqual(GatewayLog(id: "1").status, .processing)
        XCTAssertEqual(GatewayLog(id: "2", error: "transport failed").status, .error)
    }

    func testNonSuccessHTTPStatusIsErrorEvenWithoutErrorText() {
        XCTAssertEqual(GatewayLog(id: "1", httpStatusCode: 503).status, .error)
        XCTAssertEqual(GatewayLog(id: "2", httpStatusCode: 302).status, .success)
    }

    func testNumericStringIDEncodesAsUnsignedInteger() throws {
        let encoded = try JSONEncoder().encode(GatewayLog(id: "18446744073709551615"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual((object["id"] as? NSNumber)?.stringValue, "18446744073709551615")
    }

    func testStringIDFixtureRemainsRoundTrippable() throws {
        let original = GatewayLog(id: "fixture", clientModel: "model")
        let decoded = try JSONDecoder().decode(
            GatewayLog.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    func testStatusResponseDecodesRuntimeCountersAndProviderCircuit() throws {
        let status = try JSONDecoder().decode(GatewayStatus.self, from: Data(#"""
        {
          "running": true,
          "publicPort": 8788,
          "managementPort": 49152,
          "uptimeSeconds": 123,
          "activeConnections": 2,
          "totalRequests": 10,
          "successfulRequests": 8,
          "failedRequests": 2,
          "providers": [{"id":"primary","name":"Primary","circuit":{"state":"closed"}}]
        }
        """#.utf8))

        XCTAssertTrue(status.running)
        XCTAssertEqual(status.managementPort, 49_152)
        XCTAssertEqual(status.totalRequests, 10)
        XCTAssertEqual(status.providers.first?.circuit, .object(["state": .string("closed")]))
    }

    func testStatsUseStatusTotalsAndVisibleRingLatency() {
        let stats = GatewayLogStats(
            status: GatewayStatus(totalRequests: 4, successfulRequests: 3, failedRequests: 1),
            logs: [
                GatewayLog(id: "1", elapsedMs: 20),
                GatewayLog(id: "2", elapsedMs: 40),
            ]
        )

        XCTAssertEqual(stats.totalRequests, 4)
        XCTAssertEqual(stats.successRate, 75)
        XCTAssertEqual(stats.averageLatency, 30)
        XCTAssertEqual(stats.totalTokens, 0)
        XCTAssertEqual(stats.totalCost, 0)
    }
}
