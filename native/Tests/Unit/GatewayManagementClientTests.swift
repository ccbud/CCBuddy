import Foundation
import XCTest
@testable import CCBuddy

final class GatewayManagementClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        GatewayURLProtocolStub.reset()
    }

    override func tearDown() {
        GatewayURLProtocolStub.reset()
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testListDetailAndStatusUseCurrentAuthenticatedEndpoints() async throws {
        let recorder = GatewayRequestRecorder()
        GatewayURLProtocolStub.setHandler { request in
            recorder.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-token")
            switch request.url?.path {
            case "/logs":
                XCTAssertEqual(request.url?.queryValue("limit"), "75")
                XCTAssertEqual(request.url?.queryValue("before"), "99")
                return .json(#"{"data":[{"id":42,"startedAt":"2026-08-24T10:00:00Z","method":"POST","path":"/v1/messages","status":200,"attempts":1}]}"#)
            case "/logs/42":
                return .json(#"{"id":42,"startedAt":"2026-08-24T10:00:00Z","method":"POST","path":"/v1/messages","status":200,"attempts":1,"clientRequest":{"headers":{},"body":"{}","truncated":false}}"#)
            case "/status":
                return .json(#"{"running":true,"publicPort":8788,"managementPort":49152,"uptimeSeconds":10,"activeConnections":0,"totalRequests":1,"successfulRequests":1,"failedRequests":0,"providers":[]}"#)
            default:
                return .json(#"{"error":{"message":"not found"}}"#, statusCode: 404)
            }
        }

        let client = makeClient()
        let page = try await client.fetchLogs(limit: 75, before: 99)
        let detail = try await client.fetchLogDetail(id: page.logs[0].id)
        let status = try await client.fetchStatus()

        XCTAssertEqual(page.logs.map(\.id), ["42"])
        XCTAssertNotNil(detail.clientRequest)
        XCTAssertEqual(status.totalRequests, 1)
        XCTAssertEqual(recorder.paths, ["/logs", "/logs/42", "/status"])
    }

    func testClearUsesSinglePostAndDecodesClearedCount() async throws {
        let recorder = GatewayRequestRecorder()
        GatewayURLProtocolStub.setHandler { request in
            recorder.append(request)
            XCTAssertEqual(request.url?.path, "/logs/clear")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.httpBody)
            return .json(#"{"cleared":17}"#)
        }

        let count = try await makeClient().clearLogs()

        XCTAssertEqual(count, 17)
        XCTAssertEqual(recorder.methods, ["POST"])
    }

    func testPinnedClearDoesNotMoveDuringEndpointUpdate() async throws {
        let recorder = GatewayRequestRecorder()
        let gate = GatewayRequestGate()
        let entered = expectation(description: "clear reached pinned management endpoint")
        GatewayURLProtocolStub.setHandler { request in
            recorder.append(request)
            gate.blockFirstRequest { entered.fulfill() }
            return .json(#"{"cleared":1}"#)
        }
        let client = makeClient()
        let snapshot = client.snapshotEndpoint()
        let clear = Task { try await client.clearLogs(pinnedTo: snapshot) }
        defer { gate.release() }

        await fulfillment(of: [entered], timeout: 2)
        client.updatePort(9_999)
        gate.release()

        let cleared = try await clear.value
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(recorder.ports, [8_788])
        XCTAssertEqual(client.baseURL.port, 9_999)
    }

    func testPublicPortInitializerDoesNotOverrideReadyManagementEndpoint() async throws {
        GatewayURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.port, 49_152)
            return .json(#"{"data":[]}"#)
        }
        let credentials = credentials(port: 49_152)
        let client = GatewayManagementClient(
            port: 8_788,
            credentials: credentials,
            session: session
        )

        _ = try await client.fetchLogs()
        XCTAssertEqual(client.baseURL.port, 49_152)
    }

    func testSharedEndpointUpdatesAreVisibleToRetainedClient() async throws {
        let credentials = credentials(port: 8_788)
        let client = GatewayManagementClient(credentials: credentials, session: session)
        credentials.endpoint.update(port: 9_999)
        GatewayURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.port, 9_999)
            return .json(#"{"data":[]}"#)
        }

        _ = try await client.fetchLogs()
        XCTAssertEqual(client.baseURL.port, 9_999)
    }

    func testBasicAuthenticationRemainsSupported() async throws {
        let expected = Data("user:pass".utf8).base64EncodedString()
        GatewayURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic \(expected)")
            return .json(#"{"data":[]}"#)
        }
        let client = GatewayManagementClient(
            port: 8_788,
            username: "user",
            password: "pass",
            session: session
        )

        _ = try await client.fetchLogs()
    }

    func testInvalidLimitDoesNotReachTransport() async throws {
        let recorder = GatewayRequestRecorder()
        GatewayURLProtocolStub.setHandler { request in
            recorder.append(request)
            return .json("{}")
        }

        do {
            _ = try await makeClient().fetchLogs(limit: 501)
            XCTFail("Expected invalid limit")
        } catch let error as GatewayManagementError {
            XCTAssertEqual(error, .invalidLimit(501))
        }
        XCTAssertTrue(recorder.methods.isEmpty)
    }

    func testNonNumericDetailIDDoesNotReachTransport() async throws {
        let recorder = GatewayRequestRecorder()
        GatewayURLProtocolStub.setHandler { request in
            recorder.append(request)
            return .json("{}")
        }

        do {
            _ = try await makeClient().fetchLogDetail(id: "../status")
            XCTFail("Expected invalid ID")
        } catch let error as GatewayManagementError {
            XCTAssertEqual(error, .invalidLogID)
        }
        XCTAssertTrue(recorder.methods.isEmpty)
    }

    func testGatewayErrorEnvelopeBecomesLocalizedManagementError() async throws {
        GatewayURLProtocolStub.setHandler { _ in
            .json(
                #"{"error":{"type":"authentication_error","message":"management authentication required"}}"#,
                statusCode: 401
            )
        }

        do {
            _ = try await makeClient().fetchLogs()
            XCTFail("Expected API error")
        } catch let error as GatewayManagementError {
            XCTAssertEqual(
                error,
                .api(statusCode: 401, message: "management authentication required")
            )
        }
    }

    func testMalformedSuccessfulResponseReportsDecodingFailure() async throws {
        GatewayURLProtocolStub.setHandler { _ in .json(#"{"data":"wrong"}"#) }

        do {
            _ = try await makeClient().fetchLogs()
            XCTFail("Expected decoding error")
        } catch let error as GatewayManagementError {
            guard case .decoding = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func credentials(port: Int) -> GatewayManagementCredentials {
        let endpoint = GatewayManagementEndpoint()
        endpoint.update(port: port)
        return GatewayManagementCredentials(bearerToken: "unit-token", endpoint: endpoint)
    }

    private func makeClient() -> GatewayManagementClient {
        GatewayManagementClient(credentials: credentials(port: 8_788), session: session)
    }
}

private final class GatewayRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var paths: [String] { snapshot.map { $0.url?.path ?? "" } }
    var methods: [String] { snapshot.map { $0.httpMethod ?? "GET" } }
    var ports: [Int] { snapshot.compactMap { $0.url?.port } }

    private var snapshot: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class GatewayRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var shouldBlock = true

    func blockFirstRequest(_ entered: () -> Void) {
        lock.lock()
        let blocks = shouldBlock
        shouldBlock = false
        lock.unlock()
        guard blocks else { return }
        entered()
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

private final class GatewayURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        var statusCode: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var data: Data

        static func json(_ value: String, statusCode: Int = 200) -> StubResponse {
            StubResponse(statusCode: statusCode, data: Data(value.utf8))
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> StubResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: Handler?
        Self.lock.lock()
        handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}
