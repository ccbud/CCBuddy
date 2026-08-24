import Darwin
import Foundation
import XCTest
@testable import CCBuddy

final class GatewaySupervisorIntegrationTests: XCTestCase {
    func testRejectsSymlinkedCCBudHomeBeforeWritingGatewayConfig() async throws {
        let root = try GatewayIntegrationSupport.temporaryRoot("symlinked-home")
        defer { try? FileManager.default.removeItem(at: root) }
        let redirectedHome = root.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(
            at: redirectedHome,
            withIntermediateDirectories: true
        )
        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedHome,
            withDestinationURL: redirectedHome
        )
        let supervisor = GatewaySupervisor(environment: ["CCBUD_HOME": linkedHome.path])

        do {
            try await supervisor.start(config: AppConfig.fixture)
            XCTFail("Expected an intermediate CCBUD_HOME symlink to be rejected")
        } catch let error as GatewayError {
            guard case .unsafeAppDirectory(let detail) = error else {
                return XCTFail("Expected unsafeAppDirectory, got \(error)")
            }
            XCTAssertTrue(detail.contains(linkedHome.path), detail)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: redirectedHome.appendingPathComponent("gateway/config.json").path
            )
        )
    }

    func testRealHelperPublishesDynamicManagementPortAndWritesPrivateCheckedConfig() async throws {
        let binary = try GatewayIntegrationSupport.gatewayExecutable()
        let root = try GatewayIntegrationSupport.temporaryRoot("configuration")

        var config = GatewayIntegrationSupport.appConfig(
            upstreamPort: try ClaudeCLIE2ETestSupport.availableLoopbackPort(),
            protocol: .anthropic
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_GATEWAY_BINARY": binary,
        ])
        addTeardownBlock {
            await supervisor.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await supervisor.start(config: config)

        let state = await supervisor.state
        let publishedManagementPort = await supervisor.managementPort
        let managementPort = try XCTUnwrap(publishedManagementPort)
        XCTAssertEqual(state, .running(port: config.port))
        XCTAssertTrue((1...65_535).contains(managementPort))
        XCTAssertNotEqual(managementPort, config.port)
        XCTAssertEqual(supervisor.managementCredentials.endpoint.baseURL.port, managementPort)

        let gatewayDirectory = root.appendingPathComponent("gateway", isDirectory: true)
        let configURL = gatewayDirectory.appendingPathComponent("config.json")
        XCTAssertEqual(try GatewayIntegrationSupport.permissions(at: gatewayDirectory), 0o700)
        XCTAssertEqual(try GatewayIntegrationSupport.permissions(at: configURL), 0o600)

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        let management = try XCTUnwrap(encoded["management"] as? [String: Any])
        XCTAssertEqual(management["port"] as? Int, 0)
        XCTAssertEqual(
            management["bearerToken"] as? String,
            supervisor.managementCredentials.bearerToken
        )
        let failover = try XCTUnwrap(encoded["failover"] as? [String: Any])
        XCTAssertEqual(failover["enabled"] as? Bool, false)

        let checked = try await ClaudeCLIE2ETestSupport.run(
            executable: binary,
            arguments: ["--config", configURL.path, "--check-config"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: root,
            timeout: 10
        )
        XCTAssertEqual(
            checked.terminationStatus,
            0,
            "--check-config failed. stdout:\n\(checked.standardOutput)\nstderr:\n\(checked.standardError)"
        )
        await supervisor.stop()
    }

    func testBearerManagementHealthStatusLogsAndClearAgainstRealHelper() async throws {
        let upstream = try GatewayHTTPMock(responses: [.anthropic(text: "management-ok")])
        upstream.start()
        defer { upstream.stop() }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "management",
            upstreamPort: upstream.port,
            protocol: .anthropic
        )
        addTeardownBlock {
            await running.supervisor.stop()
            upstream.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let publishedManagementPort = await running.supervisor.managementPort
        let managementPort = try XCTUnwrap(publishedManagementPort)
        let unauthorized = try await GatewayIntegrationSupport.request(
            port: managementPort,
            method: "GET",
            path: "/health"
        )
        XCTAssertEqual(unauthorized.statusCode, 401, unauthorized.bodyText)

        let health = try await GatewayIntegrationSupport.request(
            port: managementPort,
            method: "GET",
            path: "/health",
            headers: [
                "Authorization": running.supervisor.managementCredentials.authorizationHeader,
            ]
        )
        XCTAssertEqual(health.statusCode, 200, health.bodyText)
        XCTAssertEqual(health.jsonObject?["status"] as? String, "ok")

        let inference = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/messages",
            object: [
                "model": "client-alias",
                "max_tokens": 32,
                "messages": [["role": "user", "content": "hello"]],
                "stream": false,
            ]
        )
        XCTAssertEqual(inference.statusCode, 200, inference.bodyText)

        let client = GatewayManagementClient(
            credentials: running.supervisor.managementCredentials
        )
        let status = try await client.fetchStatus()
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.publicPort, running.config.port)
        XCTAssertEqual(status.managementPort, managementPort)
        XCTAssertEqual(status.totalRequests, 1)
        XCTAssertEqual(status.successfulRequests, 1)
        XCTAssertEqual(status.failedRequests, 0)

        let logs = try await client.fetchLogs(limit: 10)
        let log = try XCTUnwrap(logs.logs.first)
        XCTAssertEqual(log.path, "/v1/messages")
        XCTAssertEqual(log.clientModel, "client-alias")
        XCTAssertEqual(log.providerID, "primary")
        XCTAssertEqual(log.httpStatusCode, 200)
        let cleared = try await client.clearLogs()
        let emptyLogs = try await client.fetchLogs(limit: 10)
        XCTAssertEqual(cleared, 1)
        XCTAssertTrue(emptyLogs.logs.isEmpty)
        await running.supervisor.stop()
    }

    func testStopTerminatesRealHelperAndResetsPublishedEndpoint() async throws {
        let upstream = try GatewayHTTPMock(responses: [.anthropic(text: "stop-ok")])
        upstream.start()
        defer { upstream.stop() }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "stop",
            upstreamPort: upstream.port,
            protocol: .anthropic
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let publicPort = running.config.port
        let publishedManagementPort = await running.supervisor.managementPort
        let managementPort = try XCTUnwrap(publishedManagementPort)
        await running.supervisor.stop()

        let stoppedState = await running.supervisor.state
        let stoppedManagementPort = await running.supervisor.managementPort
        let hasReadersAfterStop = await running.supervisor.hasActiveOutputReaders
        XCTAssertEqual(stoppedState, .stopped)
        XCTAssertNil(stoppedManagementPort)
        XCTAssertEqual(running.supervisor.managementCredentials.endpoint.baseURL.port, 1)
        XCTAssertFalse(hasReadersAfterStop)

        for port in [publicPort, managementPort] {
            do {
                _ = try await GatewayIntegrationSupport.request(
                    port: port, method: "GET", path: "/health", timeout: 0.5
                )
                XCTFail("Stopped helper still accepted connections on port \(port)")
            } catch {
                // Connection refusal is the expected proof that both listeners were closed.
            }
        }
    }

    func testAbnormalRealHelperExitTransitionsSupervisorToFailed() async throws {
        let binary = try GatewayIntegrationSupport.gatewayExecutable()
        let root = try GatewayIntegrationSupport.temporaryRoot("abnormal-exit")
        let wrapper = root.appendingPathComponent("ccbud-gateway-test-wrapper")
        let pidFile = root.appendingPathComponent("helper.pid")
        let quotedBinary = GatewayIntegrationSupport.shellSingleQuoted(binary)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "$CCBUD_TEST_PID_FILE"
        exec \(quotedBinary) "$@"
        """
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        var config = GatewayIntegrationSupport.appConfig(
            upstreamPort: try ClaudeCLIE2ETestSupport.availableLoopbackPort(),
            protocol: .anthropic
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.appendingPathComponent("home", isDirectory: true).path,
            "CCBUD_GATEWAY_BINARY": wrapper.path,
            "CCBUD_TEST_PID_FILE": pidFile.path,
        ])
        addTeardownBlock {
            await supervisor.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await supervisor.start(config: config)

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)

        let failed = await GatewayIntegrationSupport.eventually {
            if case .failed = await supervisor.state { return true }
            return false
        }
        XCTAssertTrue(failed, "Supervisor did not observe the killed helper")
        let state = await supervisor.state
        guard case .failed(let message) = state else {
            XCTFail("Expected failed state, got \(state)")
            return
        }
        XCTAssertTrue(message.contains("9"), message)
        let failedManagementPort = await supervisor.managementPort
        let hasReadersAfterFailure = await supervisor.hasActiveOutputReaders
        XCTAssertNil(failedManagementPort)
        XCTAssertEqual(supervisor.managementCredentials.endpoint.baseURL.port, 1)
        XCTAssertFalse(hasReadersAfterFailure)
        await supervisor.stop()
    }

    func testRestartReplacesRealHelperPortAndProviderConfiguration() async throws {
        let firstUpstream = try GatewayHTTPMock(responses: [.anthropic(text: "first-provider")])
        let secondUpstream = try GatewayHTTPMock(responses: [.anthropic(text: "second-provider")])
        firstUpstream.start()
        secondUpstream.start()
        defer {
            firstUpstream.stop()
            secondUpstream.stop()
        }
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "restart",
            upstreamPort: firstUpstream.port,
            protocol: .anthropic
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }

        let first = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/messages",
            object: GatewayIntegrationSupport.anthropicRequest(prompt: "first")
        )
        XCTAssertEqual(first.statusCode, 200, first.bodyText)
        XCTAssertTrue(first.bodyText.contains("first-provider"), first.bodyText)

        let oldPort = running.config.port
        var replacement = running.config
        replacement.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        replacement.providers[0].baseUrl = "http://127.0.0.1:\(secondUpstream.port)"
        replacement.providers[0].name = "Replacement"
        try await running.supervisor.start(config: replacement)

        let restartedState = await running.supervisor.state
        XCTAssertEqual(restartedState, .running(port: replacement.port))
        let second = try await GatewayIntegrationSupport.postJSON(
            port: replacement.port,
            path: "/v1/messages",
            object: GatewayIntegrationSupport.anthropicRequest(prompt: "second")
        )
        XCTAssertEqual(second.statusCode, 200, second.bodyText)
        XCTAssertTrue(second.bodyText.contains("second-provider"), second.bodyText)
        XCTAssertEqual(firstUpstream.requests.count, 1)
        XCTAssertEqual(secondUpstream.requests.count, 1)

        do {
            _ = try await GatewayIntegrationSupport.request(
                port: oldPort, method: "GET", path: "/health", timeout: 0.5
            )
            XCTFail("The replaced helper still listens on its previous public port")
        } catch {}
        await running.supervisor.stop()
    }

    func testInferenceTokenRejectsMissingCredentialAndAcceptsBearerOrAPIKey() async throws {
        let upstream = try GatewayHTTPMock(responses: [.anthropic(text: "authorized")])
        upstream.start()
        defer { upstream.stop() }
        let token = "sk-ccbud-private-inference-token"
        let running = try await GatewayIntegrationSupport.startSupervisor(
            prefix: "inference-auth",
            upstreamPort: upstream.port,
            protocol: .anthropic,
            requireToken: true,
            gatewayToken: token
        )
        addTeardownBlock {
            await running.supervisor.stop()
            try? FileManager.default.removeItem(at: running.root)
        }
        let body = GatewayIntegrationSupport.anthropicRequest(prompt: "protected")

        let missing = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/messages",
            object: body
        )
        XCTAssertEqual(missing.statusCode, 401, missing.bodyText)

        let bearer = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/messages",
            object: body,
            headers: ["Authorization": "Bearer \(token)"]
        )
        XCTAssertEqual(bearer.statusCode, 200, bearer.bodyText)

        let apiKey = try await GatewayIntegrationSupport.postJSON(
            port: running.config.port,
            path: "/v1/messages",
            object: body,
            headers: ["x-api-key": token]
        )
        XCTAssertEqual(apiKey.statusCode, 200, apiKey.bodyText)
        XCTAssertEqual(upstream.requests.count, 2)
        XCTAssertTrue(upstream.requests.allSatisfy {
            $0.headers["x-api-key"] == "upstream-secret"
                && !$0.headers.values.contains(token)
        })
        await running.supervisor.stop()
    }
}

struct GatewayIntegrationRun {
    let supervisor: GatewaySupervisor
    let config: AppConfig
    let root: URL
}

enum GatewayIntegrationSupport {
    struct HTTPResult {
        let statusCode: Int
        let headers: [AnyHashable: Any]
        let data: Data

        var bodyText: String { String(decoding: data, as: UTF8.self) }
        var jsonObject: [String: Any]? {
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    static func gatewayExecutable(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(
            ClaudeCLIE2ETestSupport.gatewayExecutable(),
            "CCBUD_GATEWAY_BINARY is required in CI; local fallback is native/Vendor/ccbud-gateway",
            file: file,
            line: line
        )
    }

    static func temporaryRoot(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-gateway-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func appConfig(
        upstreamPort: Int,
        protocol wire: Provider.WireProtocol,
        requireToken: Bool = false,
        gatewayToken: String = ""
    ) -> AppConfig {
        var config = AppConfig.fixture
        config.providers = [Provider(
            id: "primary",
            name: "Mock upstream",
            baseUrl: "http://127.0.0.1:\(upstreamPort)/v1",
            authToken: "upstream-secret",
            defaultModel: "upstream-model",
            smallFastModel: "upstream-fast",
            mapDefaultModels: true,
            protocol: wire,
            models: [.init(alias: "client-alias", upstream: "upstream-model")]
        )]
        config.activeProviderId = "primary"
        config.retry429 = .init(enabled: false, max: 0, baseMs: 0)
        config.requireToken = requireToken
        config.gatewayToken = gatewayToken
        return config
    }

    static func startSupervisor(
        prefix: String,
        upstreamPort: Int,
        protocol wire: Provider.WireProtocol,
        requireToken: Bool = false,
        gatewayToken: String = ""
    ) async throws -> GatewayIntegrationRun {
        let binary = try gatewayExecutable()
        let root = try temporaryRoot(prefix)
        var config = appConfig(
            upstreamPort: upstreamPort,
            protocol: wire,
            requireToken: requireToken,
            gatewayToken: gatewayToken
        )
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": root.path,
            "CCBUD_GATEWAY_BINARY": binary,
        ])
        do {
            try await supervisor.start(config: config)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return GatewayIntegrationRun(supervisor: supervisor, config: config, root: root)
    }

    static func anthropicRequest(prompt: String) -> [String: Any] {
        [
            "model": "client-alias",
            "max_tokens": 64,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
    }

    static func postJSON(
        port: Int,
        path: String,
        object: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> HTTPResult {
        try await request(
            port: port,
            method: "POST",
            path: path,
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current }
        )
    }

    static func request(
        port: Int,
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 5
    ) async throws -> HTTPResult {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("close", forHTTPHeaderField: "Connection")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return HTTPResult(statusCode: http.statusCode, headers: http.allHeaderFields, data: data)
    }

    static func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func eventually(
        attempts: Int = 200,
        intervalNanoseconds: UInt64 = 10_000_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }
}

struct GatewayMockHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let data: Data

    var jsonObject: [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

struct GatewayMockHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    static func json(
        _ object: [String: Any],
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> GatewayMockHTTPResponse {
        GatewayMockHTTPResponse(
            statusCode: statusCode,
            headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
            data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                ?? Data("{}".utf8)
        )
    }

    static func anthropic(text: String, id: String = "msg_mock") -> GatewayMockHTTPResponse {
        .json([
            "id": id,
            "type": "message",
            "role": "assistant",
            "model": "upstream-model",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 3, "output_tokens": 1],
        ])
    }

    static func chat(text: String, id: String = "chatcmpl_mock") -> GatewayMockHTTPResponse {
        .json([
            "id": id,
            "object": "chat.completion",
            "created": 1,
            "model": "upstream-model",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": "stop",
            ]],
            "usage": ["prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4],
        ])
    }

    static func responses(text: String, id: String = "resp_mock") -> GatewayMockHTTPResponse {
        .json([
            "id": id,
            "object": "response",
            "created_at": 1,
            "status": "completed",
            "model": "upstream-model",
            "output": [[
                "id": "msg_\(id)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": text, "annotations": []]],
            ]],
            "usage": ["input_tokens": 3, "output_tokens": 1, "total_tokens": 4],
        ])
    }
}

final class GatewayHTTPMock: @unchecked Sendable {
    let port: Int

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.ccbud.tests.gateway-http-mock")
    private let lock = NSLock()
    private var stopped = false
    private var scriptedResponses: [GatewayMockHTTPResponse]
    private var responseIndex = 0
    private var recordedRequests: [GatewayMockHTTPRequest] = []

    init(responses: [GatewayMockHTTPResponse]) throws {
        precondition(!responses.isEmpty)
        scriptedResponses = responses
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }
        var closeOnFailure = true
        defer { if closeOnFailure { close(descriptor) } }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
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

    var requests: [GatewayMockHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func start() {
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
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
            configure(client)
            handle(client)
            close(client)
        }
    }

    private func configure(_ client: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private func handle(_ client: Int32) {
        guard let raw = readRequest(from: client), let request = parse(raw) else {
            send(.json(["error": ["message": "invalid mock request"]], statusCode: 400), to: client)
            return
        }
        let response: GatewayMockHTTPResponse = lock.withLock {
            recordedRequests.append(request)
            let index = min(responseIndex, scriptedResponses.count - 1)
            responseIndex += 1
            return scriptedResponses[index]
        }
        send(response, to: client)
    }

    private func readRequest(from client: Int32) -> Data? {
        var data = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while data.count < 8 * 1_024 * 1_024 {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(client, $0.baseAddress, $0.count, 0)
            }
            guard count > 0 else { return data.isEmpty ? nil : data }
            data.append(contentsOf: buffer.prefix(count))
            guard let headerRange = data.range(of: delimiter) else { continue }
            let headers = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
            let length = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }.first ?? 0
            if data.count >= headerRange.upperBound + length {
                return data.subdata(in: data.startIndex..<headerRange.upperBound + length)
            }
        }
        return nil
    }

    private func parse(_ raw: Data) -> GatewayMockHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: delimiter) else { return nil }
        var lines = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return GatewayMockHTTPRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            headers: headers,
            data: raw.subdata(in: range.upperBound..<raw.endIndex)
        )
    }

    private func send(_ response: GatewayMockHTTPResponse, to client: Int32) {
        let reason: String = switch response.statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: "Response"
        }
        var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.data.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.data)
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.send(client, pointer, remaining, 0)
                guard count > 0 else { return }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
