import Foundation
import XCTest
@testable import CCBuddy

final class MonitorInspectorTests: XCTestCase {
    func testPinnedSchemaAmbiguousAnthropicRecordDoesNotClaimTranslation() throws {
        let request = "  {\"model\":\"claude-upstream\",\"messages\":[]}\n"
        let data = Data(#"""
        {
          "id": "same-protocol",
          "object": "responses",
          "provider": "ccbud-active",
          "model": "claude-upstream",
          "status": "success",
          "raw_request": "  {\"model\":\"claude-upstream\",\"messages\":[]}\n",
          "raw_response": "{\"type\":\"message\",\"content\":[]}",
          "responses_input_history": [{"type":"message","role":"user","content":[]}],
          "responses_output": [{"type":"message","role":"assistant","content":[]}],
          "is_large_payload_request": false,
          "is_large_payload_response": false
        }
        """#.utf8)
        let log = try JSONDecoder().decode(BifrostLog.self, from: data)

        let document = MonitorInspectorDocument(log: log, upstreamProtocol: .anthropic)

        XCTAssertEqual(document.protocolDisposition, .unknown)
        XCTAssertEqual(document.sections, [.request, .response])
        XCTAssertEqual(document.payload(for: .request)?.rawText, request)
        XCTAssertEqual(document.payload(for: .request)?.source, .capturedRaw)
        XCTAssertNil(document.protocolDisposition.translationLabel)
    }

    func testPinnedSchemaProvenChatToAnthropicUsesFourTabsAndMarksLargePreviewPartial() throws {
        let raw = #"{"model":"claude-upstream","messages":[]}"#
        let data = Data(#"""
        {
          "id": "translated",
          "object": "chat_completion",
          "provider": "ccbud-active",
          "model": "claude-upstream",
          "status": "success",
          "raw_request": "{\"model\":\"claude-upstream\",\"messages\":[]}",
          "raw_response": "{\"type\":\"message\",\"content\":[]}",
          "input_history": [{"role":"user","content":"hello"}],
          "output_message": {"role":"assistant","content":"done"},
          "is_large_payload_request": true,
          "is_large_payload_response": false
        }
        """#.utf8)
        let log = try JSONDecoder().decode(BifrostLog.self, from: data)

        let document = MonitorInspectorDocument(log: log, upstreamProtocol: .anthropic)
        let upstream = document.payload(for: .upstreamRequest)

        XCTAssertEqual(
            document.protocolDisposition,
            .translated(
                clientProtocol: Provider.WireProtocol.openAIChat.title,
                upstreamProtocol: .anthropic
            )
        )
        XCTAssertEqual(document.sections, [
            .clientRequest, .upstreamRequest, .upstreamResponse, .clientResponse,
        ])
        XCTAssertEqual(upstream?.rawText, raw)
        XCTAssertEqual(upstream?.shownBytes, raw.utf8.count)
        XCTAssertNil(upstream?.totalBytes)
        XCTAssertTrue(upstream?.copyIsPartial == true)
        XCTAssertTrue(upstream?.isTruncated == true)
        XCTAssertTrue(upstream?.prettyText.contains("\n") == true)
    }

    func testPinnedPassthroughBodyIsExplicitTwoSidedEvidence() throws {
        let data = Data(#"""
        {
          "id": "passthrough",
          "object": "passthrough",
          "provider": "ccbud-active",
          "model": "wire-model",
          "status": "success",
          "passthrough_request_body": "raw client body",
          "passthrough_response_body": "raw provider body",
          "is_large_payload_request": false,
          "is_large_payload_response": false
        }
        """#.utf8)
        let log = try JSONDecoder().decode(BifrostLog.self, from: data)

        let document = MonitorInspectorDocument(log: log, upstreamProtocol: .openAIResponses)

        XCTAssertEqual(document.protocolDisposition, .passthrough)
        XCTAssertEqual(document.sections, [.request, .response])
        XCTAssertEqual(document.payload(for: .request)?.rawText, "raw client body")
        XCTAssertEqual(document.payload(for: .response)?.rawText, "raw provider body")
    }

    func testPrivacyRedactorMasksStructuredAndPlaintextCredentials() throws {
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

        let localized = AppLanguage.english.localized(source)
        XCTAssertEqual(
            localized,
            "Requested model \(requestedModel), upstream model \(outgoingModel), \(provider), \(status), latency 12.5 ms"
        )
        XCTAssertEqual(AppLanguage.english.localized("成功率 99%"), "Success 99%")
        XCTAssertEqual(
            AppLanguage.japanese.localized("仅显示前 1 KB / 共 2 KB（已截断）"),
            "先頭 1 KB / 全 2 KB を表示（切り詰め）"
        )
        XCTAssertEqual(
            BifrostLogStatus.success.monitorLabel(language: .korean),
            "성공"
        )
        XCTAssertEqual(
            BifrostLogStatus.unknown("backend-status").monitorLabel(language: .english),
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
        XCTAssertEqual(search.countLabel, "800/800+")
        search.move(by: 1)
        XCTAssertEqual(search.currentIndex, 0)

        search.update(query: "missing", in: body)
        XCTAssertEqual(search.countLabel, "0/0")
    }

    @MainActor
    func testFocusedUITestFixtureSurvivesInitialPortConfigurationAndLoadsDetailLocally() async throws {
        let client = BifrostManagementClient(
            baseURL: URL(string: "http://127.0.0.1:8788")!,
            username: "fixture",
            password: "fixture"
        )
        let store = MonitorStore(
            client: client,
            environment: [
                "CCBUD_UI_TESTING": "1",
                "CCBUD_MONITOR_UI_FIXTURE": "1",
            ]
        )

        store.configure(port: 8_788, gatewayRunning: false)
        XCTAssertEqual(store.requests.map(\.id), ["ui-monitor-translated"])
        XCTAssertEqual(store.lifecycleEvents.count, 1)

        await store.loadDetail(id: "ui-monitor-translated")
        let detail = try XCTUnwrap(store.selectedDetail)
        XCTAssertEqual(detail.id, "ui-monitor-translated")
        XCTAssertNil(detail.additionalFields["translated"])
        XCTAssertEqual(
            MonitorInspectorDocument(log: detail, upstreamProtocol: .anthropic).sections,
            [.clientRequest, .upstreamRequest, .upstreamResponse, .clientResponse]
        )
        XCTAssertNil(store.detailError)
    }

    @MainActor
    func testFocusedMonitorFixtureIsIgnoredOutsideUITestingMode() {
        let store = MonitorStore(
            client: BifrostManagementClient(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                username: "fixture",
                password: "fixture"
            ),
            environment: ["CCBUD_MONITOR_UI_FIXTURE": "1"]
        )

        store.configure(port: 8_788, gatewayRunning: false)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(store.lifecycleEvents.isEmpty)
        XCTAssertNil(store.stats)
    }

    @MainActor
    func testLegacySmokeVisualFixtureKeepsMonitorEmptyAndSuppressesLiveRefresh() async {
        let client = BifrostManagementClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            username: "fixture",
            password: "fixture"
        )
        let store = MonitorStore(
            client: client,
            environment: [
                "CCBUD_UI_TESTING": "1",
                "CCBUD_UI_VISUAL_FIXTURE": "legacy-smoke",
                // The legacy visual mode must win even if the functional fixture leaks in.
                "CCBUD_MONITOR_UI_FIXTURE": "1",
            ]
        )

        store.configure(port: 8_788, gatewayRunning: true)
        store.appendLifecycle(message: "must remain hidden")
        await store.refreshNow()

        XCTAssertTrue(store.gatewayRunning)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(store.stats)
        XCTAssertTrue(store.lifecycleEvents.isEmpty)
        XCTAssertNil(store.lastUpdatedAt)
        XCTAssertNil(store.refreshError)
        XCTAssertFalse(store.isRefreshing)
    }

    func testOperationalEventsReportOnlyNewStructuredRetriesAndErrors() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var synthesizer = MonitorOperationalEventSynthesizer()
        synthesizer.begin(at: startedAt)

        let historical = BifrostLog(
            id: "historical",
            timestamp: startedAt.addingTimeInterval(-60),
            status: .error,
            errorDetails: .object([
                "status_code": .number(429),
                "error": .object(["message": .string("Bearer must-never-appear")]),
            ]),
            numberOfRetries: 4
        )
        XCTAssertTrue(synthesizer.events(for: [historical]).isEmpty)

        var current = BifrostLog(
            id: "current",
            timestamp: startedAt.addingTimeInterval(1),
            status: .processing
        )
        XCTAssertTrue(synthesizer.events(for: [current]).isEmpty)

        current.numberOfRetries = 2
        let retryEvents = synthesizer.events(for: [current])
        XCTAssertEqual(retryEvents.map(\.level), [.warning])
        XCTAssertEqual(retryEvents.map(\.message), ["Bifrost 请求已重试 2 次"])
        XCTAssertTrue(synthesizer.events(for: [current]).isEmpty)

        current.status = .error
        current.errorDetails = .object([
            "status_code": .number(429),
            "error": .object(["message": .string("Bearer must-never-appear")]),
        ])
        let errorEvents = synthesizer.events(for: [current])
        XCTAssertEqual(errorEvents.map(\.level), [.error])
        XCTAssertEqual(errorEvents.map(\.message), ["Bifrost 请求失败 · 上游 HTTP 429"])
        XCTAssertFalse(errorEvents.map(\.message).joined().contains("must-never-appear"))
        XCTAssertTrue(synthesizer.events(for: [current]).isEmpty)
    }

    func testOperationalRetryCountsRemainMonotonicAcrossStaleRows() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var synthesizer = MonitorOperationalEventSynthesizer()
        synthesizer.begin(at: startedAt)

        var request = BifrostLog(
            id: "retry-monotonic",
            timestamp: startedAt.addingTimeInterval(1),
            status: .processing,
            numberOfRetries: 3
        )
        XCTAssertEqual(
            synthesizer.events(for: [request]).map(\.message),
            ["Bifrost 请求已重试 3 次"]
        )

        request.numberOfRetries = 1
        XCTAssertTrue(synthesizer.events(for: [request]).isEmpty)

        request.numberOfRetries = nil
        XCTAssertTrue(synthesizer.events(for: [request]).isEmpty)

        request.numberOfRetries = 4
        XCTAssertEqual(
            synthesizer.events(for: [request]).map(\.message),
            ["Bifrost 请求已重试 4 次"]
        )
    }

    @MainActor
    func testOperationalObservationStateCompactsToVisibleRequestIDs() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var synthesizer = MonitorOperationalEventSynthesizer()
        synthesizer.begin(at: startedAt)

        let logs = (0...200).map { index in
            BifrostLog(
                id: "request-\(index)",
                timestamp: startedAt.addingTimeInterval(Double(index)),
                status: .processing
            )
        }
        XCTAssertTrue(synthesizer.events(for: logs).isEmpty)

        let visibleIDs = Set(logs.suffix(MonitorStore.requestLimit).map(\.id))
        XCTAssertEqual(
            synthesizer.limitObservations(retaining: visibleIDs),
            MonitorStore.requestLimit
        )
    }

    @MainActor
    func testCompletedGatewayActivityCoalescesImmediateRefreshAndRequestReceiptDoesNot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorActivityURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let counter = MonitorActivityRequestCounter()
        MonitorActivityURLProtocolStub.setHandler { request in
            counter.increment(path: request.url?.path ?? "")
            return Data("{}".utf8)
        }
        defer {
            MonitorActivityURLProtocolStub.reset()
            session.invalidateAndCancel()
        }

        var continuation: AsyncStream<BifrostRequestActivity>.Continuation?
        let activity = AsyncStream<BifrostRequestActivity> { continuation = $0 }
        let store = MonitorStore(
            client: BifrostManagementClient(
                baseURL: URL(string: "http://127.0.0.1:8788")!,
                username: "fixture",
                password: "fixture",
                session: session
            ),
            pollIntervalNanoseconds: 60_000_000_000,
            requestActivity: activity,
            activityCoalescingNanoseconds: 20_000_000,
            environment: [:]
        )
        defer {
            store.shutdown()
            continuation?.finish()
        }

        store.configure(port: 8_788, gatewayRunning: true)
        let completedInitialRefresh = await waitUntil { store.lastUpdatedAt != nil }
        XCTAssertTrue(completedInitialRefresh)
        let baseline = counter.count
        XCTAssertEqual(baseline, 2)

        continuation?.yield(.requestReceived)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(counter.count, baseline)

        for _ in 0..<12 { continuation?.yield(.responseCompleted) }
        let completedActivityRefresh = await waitUntil { counter.count >= baseline + 2 }
        XCTAssertTrue(completedActivityRefresh)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(counter.count, baseline + 2)
        XCTAssertEqual(Array(counter.paths.suffix(2)), ["/api/logs", "/api/logs/stats"])
    }

    @MainActor
    func testCompletedGatewayActivityDuringActivePollQueuesFollowUpRefresh() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorActivityURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let counter = MonitorActivityRequestCounter()
        let gate = MonitorActivityRequestGate()
        MonitorActivityURLProtocolStub.setHandler { request in
            let path = request.url?.path ?? ""
            counter.increment(path: path)
            if path == "/api/logs" { gate.blockFirstRequest() }
            return Data("{}".utf8)
        }

        var continuation: AsyncStream<BifrostRequestActivity>.Continuation?
        let activity = AsyncStream<BifrostRequestActivity> { continuation = $0 }
        let store = MonitorStore(
            client: BifrostManagementClient(
                baseURL: URL(string: "http://127.0.0.1:8788")!,
                username: "fixture",
                password: "fixture",
                session: session
            ),
            pollIntervalNanoseconds: 60_000_000_000,
            requestActivity: activity,
            activityCoalescingNanoseconds: 20_000_000,
            environment: [:]
        )
        defer {
            gate.release()
            store.shutdown()
            continuation?.finish()
            MonitorActivityURLProtocolStub.reset()
            session.invalidateAndCancel()
        }

        store.configure(port: 8_788, gatewayRunning: true)
        let initialRefreshBlocked = await waitUntil {
            store.isRefreshing && counter.count == 1
        }
        XCTAssertTrue(initialRefreshBlocked)

        continuation?.yield(.responseCompleted)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(counter.count, 1)

        gate.release()
        let completedFollowUpRefresh = await waitUntil { counter.count >= 4 }
        XCTAssertTrue(completedFollowUpRefresh)
        XCTAssertEqual(
            Array(counter.paths.prefix(4)),
            ["/api/logs", "/api/logs/stats", "/api/logs", "/api/logs/stats"]
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

private final class MonitorActivityRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    func increment(path: String) {
        lock.lock()
        storedPaths.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedPaths
    }

    var count: Int { paths.count }
}

private final class MonitorActivityRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var shouldBlock = true

    func blockFirstRequest() {
        lock.lock()
        let blocks = shouldBlock
        shouldBlock = false
        lock.unlock()
        if blocks { semaphore.wait() }
    }

    func release() {
        semaphore.signal()
    }
}

private final class MonitorActivityURLProtocolStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> Data

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
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: handler(request))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
