import XCTest
@testable import CCBuddy

final class ProviderProbeServiceTests: XCTestCase {
    override func tearDown() {
        ProviderProbeURLProtocol.handler = nil
        super.tearDown()
    }

    func testUsesDeclaredWireEndpointHeadersAndBody() async throws {
        let cases: [(Provider.WireProtocol, String, String, String)] = [
            (.anthropic, "/api/messages", "type", "message"),
            (.openAIChat, "/api/chat/completions", "choices", "[]"),
            (.openAIResponses, "/api/responses", "output", "[]"),
        ]
        for (wireProtocol, expectedPath, responseKey, responseValue) in cases {
            var captured: URLRequest?
            ProviderProbeURLProtocol.handler = { request in
                captured = request
                let value = responseValue == "[]" ? responseValue : #""message""#
                return (200, "{\"model\":\"probe-model\",\"\(responseKey)\":\(value)}")
            }
            var provider = Provider(
                name: "Probe",
                baseUrl: "https://provider.example/api/",
                authToken: "secret-key",
                defaultModel: "probe-model"
            )
            provider.protocol = wireProtocol

            let result = await ProviderProbeService(session: makeSession()).test(
                provider,
                insecureSkipVerify: false
            )

            XCTAssertTrue(result.succeeded, "\(wireProtocol): \(String(describing: result))")
            let request = try XCTUnwrap(captured)
            XCTAssertEqual(request.url?.path, expectedPath)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "anthropic-version"),
                wireProtocol == .anthropic ? "2023-06-01" : nil
            )
            let body = try XCTUnwrap(requestBody(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
            XCTAssertEqual(body["model"] as? String, "probe-model")
            if wireProtocol == .openAIResponses {
                XCTAssertEqual(body["input"] as? String, "ping")
                XCTAssertNil(body["messages"])
            } else {
                XCTAssertNotNil(body["messages"] as? [Any])
                XCTAssertNil(body["input"])
            }
        }
    }

    func testRetriesOnlyEligibleUnversionedEndpointAndReportsMigration() async throws {
        var targets: [String] = []
        ProviderProbeURLProtocol.handler = { request in
            targets.append(request.url?.path ?? "")
            if request.url?.path == "/chat/completions" {
                return (404, #"{"error":{"message":"missing"}}"#)
            }
            return (200, #"{"model":"chat-model","choices":[]}"#)
        }
        let provider = Provider(
            name: "Chat",
            baseUrl: "https://provider.example",
            authToken: "token",
            defaultModel: "chat-model",
            protocol: .openAIChat
        )

        let result = await ProviderProbeService(session: makeSession()).test(
            provider,
            insecureSkipVerify: false
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.migratedBaseURL, "https://provider.example/v1")
        XCTAssertEqual(targets, ["/chat/completions", "/v1/chat/completions"])
    }

    func testSuccessfulHTTPWithWrongProtocolShapeIsRejected() async {
        ProviderProbeURLProtocol.handler = { _ in (200, #"{"ok":true}"#) }
        let provider = Provider(
            name: "Wrong shape",
            baseUrl: "https://provider.example/v1",
            authToken: "token",
            defaultModel: "model",
            protocol: .openAIResponses
        )

        let result = await ProviderProbeService(session: makeSession()).test(
            provider,
            insecureSkipVerify: false
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertTrue(result.message?.contains(#""ok":true"#) == true)
    }

    func testRejectsEmptyAndNonHTTPBaseURLsWithoutSending() async {
        var requestCount = 0
        ProviderProbeURLProtocol.handler = { _ in
            requestCount += 1
            return (200, "{}")
        }
        let service = ProviderProbeService(session: makeSession())

        let empty = await service.test(Provider(baseUrl: "  "), insecureSkipVerify: false)
        let file = await service.test(
            Provider(baseUrl: "file:///tmp/provider", protocol: .openAIChat),
            insecureSkipVerify: false
        )

        XCTAssertEqual(empty.reason, .baseURLEmpty)
        XCTAssertEqual(file.reason, .baseURLInvalid)
        XCTAssertEqual(requestCount, 0)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class ProviderProbeURLProtocol: URLProtocol {
    // Tests install the handler before creating a request and clear it after the session stops.
    // URLProtocol invokes it from its own callback thread, so mark this controlled fixture state
    // explicitly for complete strict-concurrency checking.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (status: Int, body: String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let result = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: result.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(result.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
