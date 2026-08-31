import Foundation
import XCTest
@testable import CCBuddy

final class BifrostManagementClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BifrostURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        BifrostURLProtocolStub.reset()
    }

    override func tearDown() {
        BifrostURLProtocolStub.reset()
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testListStatsAndDetailUseIndependentAuthenticatedEndpoints() async throws {
        let credentials = BifrostManagementCredentials(username: "monitor", password: "s3cret!")
        let expectedAuthorization = credentials.basicAuthorizationHeader
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
            switch request.url?.path {
            case "/api/logs":
                XCTAssertEqual(request.url?.queryValue("limit"), "75")
                XCTAssertEqual(request.url?.queryValue("offset"), "25")
                XCTAssertEqual(request.url?.queryValue("sort_by"), "timestamp")
                XCTAssertEqual(request.url?.queryValue("order"), "desc")
                XCTAssertNotNil(request.url?.queryValue("end_time"))
                return .json(#"{"logs":[{"id":"e11f45d9-27ff-43d5-b758-22a46eeb317d","status":"processing"}],"pagination":{"limit":75,"offset":25,"sort_by":"timestamp","order":"desc","total_count":101},"has_logs":true}"#)
            case "/api/logs/stats":
                return .json(#"{"total_requests":101,"total_tokens":900,"total_cost":1.25,"average_latency":33.5,"success_rate":99}"#)
            case "/api/logs/e11f45d9-27ff-43d5-b758-22a46eeb317d":
                return .json(#"{"id":"e11f45d9-27ff-43d5-b758-22a46eeb317d","status":"success","raw_request":"{}","raw_response":"{}"}"#)
            default:
                return .json(#"{"error":{"message":"not found"}}"#, statusCode: 404)
            }
        }

        let client = BifrostManagementClient(
            baseURL: URL(string: "http://127.0.0.1:9876")!,
            credentials: credentials,
            session: session
        )
        let cutoff = Date(timeIntervalSince1970: 1_777_777_777.25)
        let page = try await client.fetchLogs(limit: 75, offset: 25, endTime: cutoff)
        let stats = try await client.fetchLogStats(endTime: cutoff)
        let detail = try await client.fetchLogDetail(id: page.logs[0].id)

        XCTAssertEqual(page.pagination.totalCount, 101)
        XCTAssertTrue(page.logs[0].isProcessing)
        XCTAssertEqual(stats.totalRequests, 101)
        XCTAssertEqual(stats.averageLatency, 33.5)
        XCTAssertEqual(detail.rawRequest, "{}")
        XCTAssertTrue(detail.isTerminal)
        XCTAssertEqual(recorder.paths, [
            "/api/logs", "/api/logs/stats", "/api/logs/e11f45d9-27ff-43d5-b758-22a46eeb317d",
        ])
    }

    func testDeleteUsesJSONIDsBodyAndBatchesAtTwoHundred() async throws {
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return .json(#"{"message":"Logs deleted successfully"}"#)
        }
        let client = makeClient()
        let ids = (0..<401).map { "request-\($0)" }

        try await client.deleteLogs(ids: ids)

        XCTAssertEqual(recorder.deleteBatches.map(\.count), [200, 200, 1])
        XCTAssertEqual(recorder.deleteBatches.flatMap { $0 }, ids)
    }

    func testClearCollectsFrozenSnapshotBeforeDeletingInBoundedBatches() async throws {
        let allIDs = (0..<1_205).map {
            String(format: "00000000-0000-0000-0000-%012d", $0)
        }
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "DELETE" {
                return .json(#"{"message":"Logs deleted successfully"}"#)
            }

            let offset = Int(request.url?.queryValue("offset") ?? "") ?? 0
            XCTAssertEqual(request.url?.queryValue("sort_by"), "timestamp")
            XCTAssertEqual(request.url?.queryValue("order"), "desc")
            let pageIDs: ArraySlice<String>
            switch offset {
            case 0: pageIDs = allIDs[0..<1_000]
            case 1_000: pageIDs = allIDs[1_000..<1_205]
            default: pageIDs = []
            }
            let payload: [String: Any] = [
                "logs": pageIDs.map { ["id": $0, "status": "success"] },
                "pagination": [
                    "limit": 1_000, "offset": offset, "sort_by": "timestamp",
                    "order": "desc", "total_count": allIDs.count,
                ],
                "has_logs": true,
            ]
            return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: payload))
        }
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000.75)

        let deletedCount = try await makeClient().clearLogs(through: cutoff)

        XCTAssertEqual(deletedCount, allIDs.count)
        XCTAssertEqual(recorder.getOffsets, [0, 1_000])
        XCTAssertEqual(Set(recorder.getEndTimes).count, 1)
        XCTAssertEqual(recorder.getEndTimes.count, 2)
        XCTAssertEqual(recorder.deleteBatches.map(\.count), [200, 200, 200, 200, 200, 200, 5])
        XCTAssertEqual(recorder.deleteBatches.flatMap { $0 }, allIDs)
        XCTAssertEqual(Array(recorder.methods.prefix(2)), ["GET", "GET"])
        XCTAssertTrue(recorder.methods.dropFirst(2).allSatisfy { $0 == "DELETE" })
    }

    func testClearPinsEndpointAcrossConcurrentPortUpdate() async throws {
        let ids = (0..<401).map { "request-\($0)" }
        let pageData = try JSONSerialization.data(withJSONObject: [
            "logs": ids.map { ["id": $0, "status": "success"] },
            "pagination": [
                "limit": 1_000, "offset": 0, "sort_by": "timestamp",
                "order": "desc", "total_count": ids.count,
            ],
            "has_logs": true,
        ])
        let recorder = BifrostRequestRecorder()
        let gate = BifrostRequestGate()
        let entered = expectation(description: "clear reached its pinned endpoint")
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                gate.blockFirstRequest { entered.fulfill() }
                return .init(statusCode: 200, data: pageData)
            }
            return .json(#"{"message":"Logs deleted successfully"}"#)
        }
        let client = makeClient()
        let clear = Task { try await client.clearLogs() }
        defer { gate.release() }

        await fulfillment(of: [entered], timeout: 2)
        client.updatePort(9_999)
        gate.release()

        let deletedCount = try await clear.value
        XCTAssertEqual(deletedCount, ids.count)
        XCTAssertEqual(recorder.ports, Array(repeating: 8_788, count: 4))
        XCTAssertEqual(recorder.deleteBatches.map(\.count), [200, 200, 1])
        XCTAssertEqual(client.baseURL.port, 9_999)
    }

    func testSynchronouslyCapturedEndpointPinsClearBeforeAsyncWorkStarts() async throws {
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            return .json(#"{"logs":[],"pagination":{"total_count":0},"has_logs":false}"#)
        }
        let client = makeClient()
        let endpoint = client.snapshotEndpoint()

        client.updatePort(9_999)
        _ = try await client.clearLogs(through: Date(), pinnedTo: endpoint)

        XCTAssertEqual(recorder.ports, [8_788])
        XCTAssertEqual(client.baseURL.port, 9_999)
    }

    func testClearReportsSuccessfullyDeletedIDsWhenLaterBatchFails() async throws {
        let ids = (0..<401).map { "request-\($0)" }
        let pageData = try JSONSerialization.data(withJSONObject: [
            "logs": ids.map { ["id": $0, "status": "success"] },
            "pagination": [
                "limit": 1_000, "offset": 0, "sort_by": "timestamp",
                "order": "desc", "total_count": ids.count,
            ],
            "has_logs": true,
        ])
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, data: pageData)
            }
            if recorder.deleteBatches.count == 2 {
                return .json(#"{"error":{"message":"second batch failed"}}"#, statusCode: 500)
            }
            return .json(#"{"message":"Logs deleted successfully"}"#)
        }

        do {
            _ = try await makeClient().clearLogs()
            XCTFail("Expected a partial-delete failure")
        } catch let error as BifrostPartialLogDeleteError {
            XCTAssertEqual(error.deletedIDs, Array(ids.prefix(200)))
            XCTAssertTrue(error.failureDescription.contains("second batch failed"))
        }

        XCTAssertEqual(recorder.deleteBatches.map(\.count), [200, 200])
    }

    @MainActor
    func testStorePartialClearRemovesOnlyRowsFromConfirmedBatches() async throws {
        let ids = (0..<401).map { "request-\($0)" }
        let visibleIDs = Array(ids.prefix(50)) + Array(ids[200..<250])
        let visibleData = try JSONSerialization.data(withJSONObject: [
            "logs": visibleIDs.map { ["id": $0, "status": "success"] },
            "pagination": [
                "limit": 100, "offset": 0, "sort_by": "timestamp",
                "order": "desc", "total_count": ids.count,
            ],
            "has_logs": true,
        ])
        let clearData = try JSONSerialization.data(withJSONObject: [
            "logs": ids.map { ["id": $0, "status": "success"] },
            "pagination": [
                "limit": 1_000, "offset": 0, "sort_by": "timestamp",
                "order": "desc", "total_count": ids.count,
            ],
            "has_logs": true,
        ])
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            if request.url?.path == "/api/logs/stats" {
                return .json(#"{"total_requests":401}"#)
            }
            if request.httpMethod == "GET" {
                return .init(
                    statusCode: 200,
                    data: request.url?.queryValue("limit") == "100" ? visibleData : clearData
                )
            }
            if recorder.deleteBatches.count == 2 {
                return .json(#"{"error":{"message":"second batch failed"}}"#, statusCode: 500)
            }
            return .json(#"{"message":"Logs deleted successfully"}"#)
        }
        let store = MonitorStore(
            client: makeClient(),
            pollIntervalNanoseconds: 60_000_000_000,
            environment: [:]
        )
        defer { store.shutdown() }

        store.configure(port: 8_788, gatewayRunning: true)
        let loadedVisibleRows = await waitUntil {
            store.requests.count == visibleIDs.count && !store.isRefreshing
        }
        XCTAssertTrue(loadedVisibleRows)
        store.stopPolling()

        let cleared = await store.clearAllLogs()
        XCTAssertFalse(cleared)
        XCTAssertEqual(Set(store.requests.map(\.id)), Set(ids[200..<250]))
        XCTAssertNil(store.stats)
        XCTAssertTrue(store.refreshError?.contains("second batch failed") == true)
        XCTAssertFalse(store.isClearing)
    }

    @MainActor
    func testStoreIgnoresStaleClearCompletionAfterEndpointChange() async throws {
        let pageData = try JSONSerialization.data(withJSONObject: [
            "logs": [["id": "old-endpoint-row", "status": "success"]],
            "pagination": [
                "limit": 1_000, "offset": 0, "sort_by": "timestamp",
                "order": "desc", "total_count": 1,
            ],
            "has_logs": true,
        ])
        let gate = BifrostRequestGate()
        let recorder = BifrostRequestRecorder()
        let entered = expectation(description: "store clear reached old endpoint")
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                gate.blockFirstRequest { entered.fulfill() }
                return .init(statusCode: 200, data: pageData)
            }
            return .json(#"{"message":"Logs deleted successfully"}"#)
        }
        let store = MonitorStore(
            client: makeClient(),
            environment: [
                "CCBUD_UI_TESTING": "1",
                "CCBUD_MONITOR_UI_FIXTURE": "1",
            ]
        )
        defer {
            gate.release()
            store.shutdown()
        }
        let clear = Task { @MainActor in await store.clearAllLogs() }

        await fulfillment(of: [entered], timeout: 2)
        store.configure(port: 9_999, gatewayRunning: false)
        await store.loadDetail(id: "ui-monitor-translated")
        store.appendLifecycle(
            timestamp: .distantPast,
            level: .info,
            message: "new endpoint state"
        )
        gate.release()

        let cleared = await clear.value
        XCTAssertFalse(cleared)
        XCTAssertEqual(store.requests.map(\.id), ["ui-monitor-translated"])
        XCTAssertEqual(store.selectedDetail?.id, "ui-monitor-translated")
        XCTAssertTrue(store.lifecycleEvents.contains { $0.message == "new endpoint state" })
        XCTAssertNil(store.refreshError)
        XCTAssertEqual(recorder.ports, [8_788, 8_788])
        XCTAssertEqual(store.currentPort, 9_999)
    }

    @MainActor
    func testStoreClearPreservesLifecycleEventsAppendedWhileSuspended() async throws {
        let gate = BifrostRequestGate()
        let entered = expectation(description: "store clear suspended")
        BifrostURLProtocolStub.setHandler { request in
            if request.httpMethod == "GET" {
                gate.blockFirstRequest { entered.fulfill() }
            }
            return .json(#"{"logs":[],"pagination":{"total_count":0},"has_logs":false}"#)
        }
        let store = MonitorStore(client: makeClient(), environment: [:])
        defer {
            gate.release()
            store.shutdown()
        }
        store.appendLifecycle(timestamp: .distantPast, message: "before clear")
        let clear = Task { @MainActor in await store.clearAllLogs() }

        await fulfillment(of: [entered], timeout: 2)
        let duringClear = MonitorLifecycleEvent(
            sequence: 42,
            timestamp: .distantPast,
            level: .info,
            message: "during clear"
        )
        store.appendLifecycle(duringClear)
        gate.release()

        let cleared = await clear.value
        XCTAssertTrue(cleared)
        XCTAssertEqual(store.lifecycleEvents.map(\.message), ["during clear"])
        store.appendLifecycle(duringClear)
        XCTAssertEqual(store.lifecycleEvents.map(\.message), ["during clear"])
        XCTAssertFalse(store.isClearing)
    }

    func testStandardBifrostErrorEnvelopeIsSurfaced() async throws {
        BifrostURLProtocolStub.setHandler { _ in
            .json(
                #"{"is_bifrost_error":false,"status_code":401,"error":{"message":"invalid management credentials","event_id":"evt-123"}}"#,
                statusCode: 401
            )
        }

        do {
            _ = try await makeClient().fetchLogStats()
            XCTFail("Expected API error")
        } catch let error as BifrostManagementError {
            XCTAssertEqual(
                error,
                .api(statusCode: 401, message: "invalid management credentials", eventID: "evt-123")
            )
        }
    }

    func testPaginationValidationDoesNotReachTransport() async throws {
        let recorder = BifrostRequestRecorder()
        BifrostURLProtocolStub.setHandler { request in
            recorder.append(request)
            return .json("{}")
        }
        do {
            _ = try await makeClient().fetchLogs(limit: 1_001)
            XCTFail("Expected invalid limit")
        } catch let error as BifrostManagementError {
            XCTAssertEqual(error, .invalidLimit(1_001))
        }
        XCTAssertTrue(recorder.methods.isEmpty)
    }

    func testPortUpdatePreservesCredentialsAndChangesDestination() async throws {
        let expected = Data("user:pass".utf8).base64EncodedString()
        BifrostURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.port, 9_999)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic \(expected)")
            return .json(#"{"total_requests":0}"#)
        }
        let client = BifrostManagementClient(port: 8_788, username: "user", password: "pass", session: session)
        client.updatePort(9_999)

        _ = try await client.fetchLogStats()
        XCTAssertEqual(client.baseURL.port, 9_999)
    }

    @MainActor
    func testMonitorNormalizesPersistedRequestedModelInListAndDetail() async throws {
        let callerModel = "claude-family-route"
        let encoded = LegacyRequestedModelMetadata.encode(callerModel)
        BifrostURLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/api/logs/stats":
                return .json(#"{"total_requests":1}"#)
            case "/api/logs/routed":
                return .json("""
                {"id":"routed","model":"primary-upstream","status":"success",\
                "metadata":{"\(LegacyRequestedModelMetadata.metadataKey)":"\(encoded)"},\
                "raw_request":"{}","raw_response":"{}"}
                """)
            default:
                return .json("""
                {"logs":[{"id":"routed","model":"primary-upstream","status":"success",\
                "metadata":{"\(LegacyRequestedModelMetadata.metadataKey)":"\(encoded)"}}],\
                "pagination":{"total_count":1},"has_logs":true}
                """)
            }
        }
        let store = MonitorStore(
            client: makeClient(),
            pollIntervalNanoseconds: 60_000_000_000,
            environment: [:]
        )
        defer { store.shutdown() }

        store.configure(port: 8_788, gatewayRunning: true)
        let normalizedList = await waitUntil {
            store.requests.first?.requestedModel == callerModel && !store.isRefreshing
        }
        XCTAssertTrue(normalizedList)
        store.stopPolling()
        XCTAssertEqual(store.requests.first?.outgoingModel, "primary-upstream")

        await store.loadDetail(id: "routed")
        XCTAssertEqual(store.selectedDetail?.requestedModel, callerModel)
        XCTAssertEqual(store.selectedDetail?.outgoingModel, "primary-upstream")
    }

    private func makeClient() -> BifrostManagementClient {
        BifrostManagementClient(
            baseURL: URL(string: "http://127.0.0.1:8788")!,
            username: "unit",
            password: "test",
            session: session
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private final class BifrostRequestRecorder: @unchecked Sendable {
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
    var getOffsets: [Int] {
        snapshot.compactMap { request in
            guard request.httpMethod == "GET" else { return nil }
            return Int(request.url?.queryValue("offset") ?? "")
        }
    }
    var getEndTimes: [String] {
        snapshot.compactMap { request in
            guard request.httpMethod == "GET" else { return nil }
            return request.url?.queryValue("end_time")
        }
    }
    var deleteBatches: [[String]] {
        snapshot.compactMap { request in
            guard request.httpMethod == "DELETE", let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return object["ids"] as? [String]
        }
    }

    private var snapshot: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class BifrostRequestGate: @unchecked Sendable {
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

private final class BifrostURLProtocolStub: URLProtocol, @unchecked Sendable {
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
    // Access is serialized by lock; the annotation makes that synchronization contract explicit
    // to complete strict-concurrency checking.
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
            let materializedRequest = Self.materializingBodyStream(in: request)
            let stub = try handler(materializedRequest)
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

    /// URLSession converts `httpBody` to an input stream before handing a request to URLProtocol.
    /// Materialize it for assertions because this stub terminates the request and will not need to
    /// replay the stream to another protocol.
    private static func materializingBodyStream(in request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }

        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = body
        return copy
    }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}
