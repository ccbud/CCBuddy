import AppKit
import Foundation
import XCTest
@testable import CCBuddy

final class MonitorInspectorTests: XCTestCase {
    func testAppClipboardWritesPasteboardAndMirrorsExactValueOnlyForUITests() throws {
        let root = try HistoryTestSupport.temporaryDirectory("app-clipboard")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent(".ccbud-ui-test-clipboard")
        let pasteboard = NSPasteboard(
            name: .init("dev.ccbud.app-clipboard.\(UUID().uuidString)")
        )

        let disabledEnvironments = [
            ["CCBUD_HOME": root.path],
            ["CCBUD_UI_TESTING": "1"],
            ["CCBUD_UI_TESTING": "0", "CCBUD_HOME": root.path],
        ]
        for (index, environment) in disabledEnvironments.enumerated() {
            try? FileManager.default.removeItem(at: capture)
            let text = "pasteboard-only-\(index)"

            XCTAssertTrue(
                AppClipboard.write(text, pasteboard: pasteboard, environment: environment)
            )
            XCTAssertEqual(pasteboard.string(forType: .string), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        }

        let exact = #"{"authorization":"Bearer ui-secret-token","unicode":"复制•"}"#
        XCTAssertTrue(
            AppClipboard.write(
                exact,
                pasteboard: pasteboard,
                environment: ["CCBUD_UI_TESTING": "1", "CCBUD_HOME": root.path]
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), exact)
#if DEBUG
        XCTAssertEqual(try Data(contentsOf: capture), Data(exact.utf8))
#else
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
#endif
    }

    func testAppClipboardMirrorFailurePreservesPasteboardResultAndContents() throws {
        let root = try HistoryTestSupport.temporaryDirectory("app-clipboard-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedHome = root.appendingPathComponent("not-a-directory")
        try Data("leave unchanged".utf8).write(to: blockedHome)
        let text = "exact value despite mirror failure"

        let controlPasteboard = NSPasteboard(
            name: .init("dev.ccbud.app-clipboard.control.\(UUID().uuidString)")
        )
        controlPasteboard.clearContents()
        let expectedResult = controlPasteboard.setString(text, forType: .string)

        let pasteboard = NSPasteboard(
            name: .init("dev.ccbud.app-clipboard.failure.\(UUID().uuidString)")
        )
        let result = AppClipboard.write(
            text,
            pasteboard: pasteboard,
            environment: ["CCBUD_UI_TESTING": "1", "CCBUD_HOME": blockedHome.path]
        )

        XCTAssertEqual(result, expectedResult)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertEqual(try Data(contentsOf: blockedHome), Data("leave unchanged".utf8))
    }

    func testGatewayDetailAlwaysUsesFourExactCaptureBoundaries() throws {
        let log = GatewayLog(
            id: "1",
            translation: "anthropic → openai-chat",
            clientRequest: GatewayCapturedMessage(
                headers: .object(["authorization": .string("<redacted>")]),
                body: #"{"model":"client-model"}"#
            ),
            upstreamRequest: GatewayCapturedMessage(body: #"{"model":"upstream-model"}"#),
            upstreamResponse: GatewayCapturedMessage(body: #"{"choices":[]}"#),
            clientResponse: GatewayCapturedMessage(body: #"{"content":[]}"#)
        )

        let document = MonitorInspectorDocument(log: log)

        XCTAssertEqual(
            document.sections,
            [.clientRequest, .upstreamRequest, .upstreamResponse, .clientResponse]
        )
        XCTAssertEqual(document.protocolDisposition, .translated("anthropic → openai-chat"))
        let clientRequest = try XCTUnwrap(document.payload(for: .clientRequest))
        XCTAssertTrue(clientRequest.rawText.contains(#""authorization":"<redacted>""#))
        XCTAssertTrue(clientRequest.prettyText.contains(#""model" : "client-model""#))
        XCTAssertFalse(clientRequest.isTruncated)
    }

    func testMissingBoundaryIsShownAsUnavailableInsteadOfBeingInferred() {
        let log = GatewayLog(
            id: "1",
            clientRequest: GatewayCapturedMessage(body: "client")
        )
        let document = MonitorInspectorDocument(log: log)

        XCTAssertEqual(document.protocolDisposition, .passthrough)
        XCTAssertNotNil(document.payload(for: .clientRequest))
        XCTAssertNil(document.payload(for: .upstreamRequest))
        XCTAssertNil(document.payload(for: .upstreamResponse))
        XCTAssertNil(document.payload(for: .clientResponse))
    }

    func testTruncatedCaptureMarksCopyAsPartialWithoutInventingTotalBytes() throws {
        let body = String(repeating: "x", count: 256)
        let document = MonitorInspectorDocument(log: GatewayLog(
            id: "1",
            upstreamResponse: GatewayCapturedMessage(body: body, truncated: true)
        ))
        let payload = try XCTUnwrap(document.payload(for: .upstreamResponse))

        XCTAssertEqual(payload.shownBytes, 256)
        XCTAssertNil(payload.totalBytes)
        XCTAssertTrue(payload.isTruncated)
        XCTAssertTrue(payload.copyIsPartial)
    }

    func testPrivacyRedactorMasksStructuredAndPlaintextCredentials() {
        let json = #"{"authorization":"Bearer top-secret","nested":{"api_key":"sk-abcdefghijk","debug":"password=embedded-secret","prompt":"keep me"},"cookies":[{"set-cookie":"session=private"}]}"#
        let redactedJSON = MonitorPrivacyRedactor.redact(json)

        XCTAssertFalse(redactedJSON.contains("top-secret"))
        XCTAssertFalse(redactedJSON.contains("sk-abcdefghijk"))
        XCTAssertFalse(redactedJSON.contains("embedded-secret"))
        XCTAssertFalse(redactedJSON.contains("session=private"))
        XCTAssertTrue(redactedJSON.contains("keep me"))
        XCTAssertTrue(redactedJSON.contains(MonitorPrivacyRedactor.replacement))

        let plain = "Authorization: Bearer plain-secret password=hunter2 secret=quiet token=hidden https://user:pass@host.test/path sk-1234567890"
        let redactedPlain = MonitorPrivacyRedactor.redact(plain)
        for secret in ["plain-secret", "hunter2", "quiet", "hidden", "pass@", "sk-1234567890"] {
            XCTAssertFalse(redactedPlain.contains(secret), "Leaked \(secret): \(redactedPlain)")
        }
    }

    func testPrivacyRedactorUsesSelectedLanguageAndPreservesNonsecretPayload() {
        let markers: [(AppLanguage, String)] = [
            (.english, "•••••• (hidden)"),
            (.simplifiedChinese, "••••••（已隐藏）"),
            (.traditionalChinese, "••••••（已隱藏）"),
            (.japanese, "••••••（非表示）"),
            (.korean, "••••••(숨김)"),
        ]

        for (language, marker) in markers {
            let redacted = MonitorPrivacyRedactor.redact(
                #"{"authorization":"Bearer secret-value","model":"model-id-verbatim"}"#,
                language: language
            )
            XCTAssertEqual(MonitorPrivacyRedactor.replacement(for: language), marker)
            XCTAssertTrue(redacted.contains(marker), "Missing \(marker) in \(redacted)")
            XCTAssertTrue(redacted.contains("model-id-verbatim"))
            XCTAssertFalse(redacted.contains("secret-value"))
        }
    }

    func testMonitorRuntimeTemplatesPreserveBackendValues() {
        let requestedModel = "client/model-原样"
        let outgoingModel = "provider/model-そのまま"
        let provider = "Provider 사용자 값"
        let status = "HTTP 429"
        let source = "请求模型 \(requestedModel)，上游模型 \(outgoingModel)，\(provider)，\(status)，耗时 12.5 毫秒"

        XCTAssertEqual(
            AppLanguage.english.localized(source),
            "Requested model \(requestedModel), upstream model \(outgoingModel), \(provider), \(status), latency 12.5 ms"
        )
        XCTAssertEqual(GatewayLogStatus.success.monitorLabel(language: .korean), "성공")
        XCTAssertEqual(
            GatewayLogStatus.unknown("backend-status").monitorLabel(language: .english),
            "backend-status"
        )
    }

    func testBodySearchIsCaseInsensitiveWrapsAndCapsMarksAtEightHundred() {
        let body = Array(repeating: "Needle", count: 805).joined(separator: " ")
        var search = MonitorPayloadSearchState()

        search.update(query: "nEeDlE", in: body)

        XCTAssertEqual(search.totalMatchCount, 805)
        XCTAssertEqual(search.matches.count, 800)
        XCTAssertEqual(search.countLabel, "1/800+")
        search.move(by: -1)
        XCTAssertEqual(search.currentIndex, 799)
        search.move(by: 1)
        XCTAssertEqual(search.currentIndex, 0)
    }

    @MainActor
    func testFocusedUITestFixtureSurvivesConfigurationAndLoadsDetailLocally() async throws {
        let store = MonitorStore(
            client: makeClient(port: 8_788),
            environment: [
                "CCBUD_UI_TESTING": "1",
                "CCBUD_MONITOR_UI_FIXTURE": "1",
            ]
        )
        defer { store.shutdown() }

        store.configure(port: 8_788, gatewayRunning: false)
        XCTAssertEqual(store.requests.map(\.id), ["ui-monitor-translated"])
        XCTAssertEqual(store.lifecycleEvents.count, 1)

        await store.loadDetail(id: "ui-monitor-translated")
        let detail = try XCTUnwrap(store.selectedDetail)
        XCTAssertEqual(detail.outgoingModel, "upstream-model")
        XCTAssertEqual(
            MonitorInspectorDocument(log: detail).sections,
            [.clientRequest, .upstreamRequest, .upstreamResponse, .clientResponse]
        )
        XCTAssertNil(store.detailError)
    }

    @MainActor
    func testFocusedMonitorFixtureIsIgnoredOutsideUITestingMode() {
        let store = MonitorStore(
            client: makeClient(port: 8_788),
            environment: ["CCBUD_MONITOR_UI_FIXTURE": "1"]
        )
        defer { store.shutdown() }

        store.configure(port: 8_788, gatewayRunning: false)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(store.lifecycleEvents.isEmpty)
    }

    func testOperationalEventsReportOnlyNewStructuredRetriesAndErrors() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var synthesizer = MonitorOperationalEventSynthesizer()
        synthesizer.begin(at: startedAt)

        let historical = GatewayLog(
            id: "1",
            startedAt: startedAt.addingTimeInterval(-60),
            httpStatusCode: 429,
            attempts: 5,
            error: "Bearer must-never-appear"
        )
        XCTAssertTrue(synthesizer.events(for: [historical]).isEmpty)

        var current = GatewayLog(
            id: "2",
            startedAt: startedAt.addingTimeInterval(1),
            attempts: 1
        )
        XCTAssertTrue(synthesizer.events(for: [current]).isEmpty)

        current.attempts = 3
        XCTAssertEqual(
            synthesizer.events(for: [current]).map(\.message),
            ["网关请求已重试 2 次"]
        )
        XCTAssertTrue(synthesizer.events(for: [current]).isEmpty)

        current.httpStatusCode = 429
        current.error = "Bearer must-never-appear"
        let events = synthesizer.events(for: [current])
        XCTAssertEqual(events.map(\.message), ["网关请求失败 · 上游 HTTP 429"])
        XCTAssertFalse(events.map(\.message).joined().contains("must-never-appear"))
    }

    func testOperationalRetryCountsRemainMonotonicAcrossStaleRows() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var synthesizer = MonitorOperationalEventSynthesizer()
        synthesizer.begin(at: startedAt)

        var request = GatewayLog(
            id: "1",
            startedAt: startedAt.addingTimeInterval(1),
            attempts: 4
        )
        XCTAssertEqual(
            synthesizer.events(for: [request]).map(\.message),
            ["网关请求已重试 3 次"]
        )
        request.attempts = 2
        XCTAssertTrue(synthesizer.events(for: [request]).isEmpty)
        request.attempts = 5
        XCTAssertEqual(
            synthesizer.events(for: [request]).map(\.message),
            ["网关请求已重试 4 次"]
        )
    }

    @MainActor
    func testMonitorRefreshUsesPrivateManagementEndpointAndDerivesStatusMetrics() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorGatewayURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            MonitorGatewayURLProtocolStub.reset()
            session.invalidateAndCancel()
        }
        let recorder = MonitorRequestRecorder()
        MonitorGatewayURLProtocolStub.setHandler { request in
            recorder.append(request)
            switch request.url?.path {
            case "/status":
                return .json(#"{"running":true,"publicPort":8788,"managementPort":49152,"uptimeSeconds":5,"activeConnections":0,"totalRequests":4,"successfulRequests":3,"failedRequests":1,"providers":[]}"#)
            default:
                return .json(#"{"data":[{"id":1,"startedAt":"2026-08-24T10:00:00Z","elapsedMs":25,"method":"POST","path":"/v1/messages","status":200,"clientModel":"model","attempts":1}]}"#)
            }
        }
        let store = MonitorStore(
            client: makeClient(port: 49_152, session: session),
            pollIntervalNanoseconds: 60_000_000_000,
            environment: [:]
        )
        defer { store.shutdown() }

        store.configure(port: 8_788, gatewayRunning: true)
        let loaded = await waitUntil {
            store.requests.count == 1 && store.stats?.totalRequests == 4 && !store.isRefreshing
        }

        XCTAssertTrue(loaded)
        XCTAssertTrue(recorder.ports.allSatisfy { $0 == 49_152 })
        XCTAssertEqual(store.stats?.successRate, 75)
        XCTAssertEqual(store.stats?.averageLatency, 25)
    }

    private func makeClient(
        port: Int,
        session: URLSession = .shared
    ) -> GatewayManagementClient {
        let endpoint = GatewayManagementEndpoint()
        endpoint.update(port: port)
        let credentials = GatewayManagementCredentials(
            bearerToken: "monitor-test-token",
            endpoint: endpoint
        )
        return GatewayManagementClient(credentials: credentials, session: session)
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

private final class MonitorRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var ports: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap { $0.url?.port }
    }
}

private final class MonitorGatewayURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let data: Data

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
                headerFields: ["Content-Type": "application/json"]
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
