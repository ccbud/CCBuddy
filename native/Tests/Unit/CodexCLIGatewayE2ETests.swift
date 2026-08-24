import Foundation
import XCTest
@testable import CCBuddy

final class CodexCLIGatewayE2ETests: XCTestCase {
    private static let firstMarker = "CCBUD_CODEX_CLI_FIRST"
    private static let secondMarker = "CCBUD_CODEX_CLI_SECOND"

    func testRealCodexCLIUsesManagedResponsesGatewayAndResumesWithAssistantContext() async throws {
        guard let codex = ClaudeCLIE2ETestSupport.codexExecutable() else {
            throw XCTSkip("Codex CLI is unavailable; set CCBUD_CODEX_BINARY to enable this E2E")
        }
        guard let gateway = ClaudeCLIE2ETestSupport.gatewayExecutable() else {
            throw XCTSkip("ccbud-gateway is unavailable; run native/Scripts/build-gateway-helper.sh")
        }

        let upstream = try ClaudeCLIAnthropicMock(
            firstMarker: Self.firstMarker,
            secondMarker: Self.secondMarker
        )
        upstream.start()
        defer { upstream.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-codex-cli-e2e-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let ccbudHome = root.appendingPathComponent("ccbud", isDirectory: true)
        for directory in [home, codexHome, workspace, temporary, ccbudHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let version = try await ClaudeCLIE2ETestSupport.run(
            executable: codex,
            arguments: ["--version"],
            environment: isolatedEnvironment(
                home: home,
                codexHome: codexHome,
                workspace: workspace,
                temporary: temporary
            ),
            currentDirectory: workspace,
            timeout: 10
        )
        XCTAssertEqual(version.terminationStatus, 0, version.standardError)
        XCTAssertEqual(version.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "codex-cli 0.149.0")

        let gatewayToken = "sk-gateway-ccbud-codex-cli-e2e"
        let providerToken = "sk-ccbud-codex-upstream-e2e"
        var config = AppConfig.fixture
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].authToken = providerToken
        config.providers[0].protocol = .anthropic
        config.retry429.enabled = false
        config.requireToken = true
        config.gatewayToken = gatewayToken

        let repository = ConfigRepository(configURL: ccbudHome.appendingPathComponent("config.json"))
        try repository.save(config)
        let connectionEnvironment = [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "CCBUD_CODEX_CONFIG": codexHome.appendingPathComponent("config.toml").path,
        ]
        let connectionManager = CLIConnectionManager(
            repository: repository,
            environment: connectionEnvironment
        )
        let connected = try connectionManager.connectCodex(config: config)
        XCTAssertTrue(connected.connectTargets.contains(CLIConnectionManager.codexTarget))
        XCTAssertEqual(try repository.load(), connected)

        let codexDocument = CodexConfigDocument(
            try String(contentsOf: connectionManager.codexConfigURL, encoding: .utf8)
        )
        XCTAssertEqual(codexDocument.topLevelString(for: "model_provider"), "ccbud")
        XCTAssertEqual(codexDocument.topLevelString(for: "model"), CLIConnectionManager.codexModel)
        XCTAssertEqual(codexDocument.providerString(for: "base_url"), "http://localhost:\(config.port)/v1")
        XCTAssertEqual(codexDocument.providerString(for: "wire_api"), "responses")
        XCTAssertEqual(codexDocument.providerString(for: "experimental_bearer_token"), gatewayToken)

        let supervisor = GatewaySupervisor(environment: [
            "CCBUD_HOME": ccbudHome.path,
            "CCBUD_GATEWAY_BINARY": gateway,
        ])
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await supervisor.start(config: connected)

        let environment = isolatedEnvironment(
            home: home,
            codexHome: codexHome,
            workspace: workspace,
            temporary: temporary
        )
        let first = try await ClaudeCLIE2ETestSupport.run(
            executable: codex,
            arguments: [
                "exec", "--json", "--skip-git-repo-check",
                "Reply with exactly \(Self.firstMarker). Do not call tools.",
            ],
            environment: environment,
            currentDirectory: workspace,
            timeout: 60
        )
        let threadID = try assertSuccessfulCodexResult(first, marker: Self.firstMarker)

        let second = try await ClaudeCLIE2ETestSupport.run(
            executable: codex,
            arguments: [
                "exec", "resume", "--json", "--skip-git-repo-check", threadID,
                "Continue this session and reply with exactly \(Self.secondMarker). Do not call tools.",
            ],
            environment: environment,
            currentDirectory: workspace,
            timeout: 60
        )
        let resumedThreadID = try assertSuccessfulCodexResult(second, marker: Self.secondMarker)
        XCTAssertEqual(resumedThreadID, threadID)

        let requests = upstream.messageRequests
        XCTAssertEqual(
            requests.count,
            2,
            "Expected one Anthropic Messages operation per Codex turn; all targets: \(upstream.requests.map(\.target))"
        )
        guard requests.count == 2 else {
            await supervisor.stop()
            return
        }
        for request in requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.headers["x-api-key"], providerToken)
            XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
            XCTAssertEqual(request.body["stream"] as? Bool, true)
            XCTAssertEqual(request.body["model"] as? String, "glm-5.2")
        }

        let secondMessages = try XCTUnwrap(requests[1].body["messages"] as? [[String: Any]])
        XCTAssertTrue(
            Self.jsonContains(secondMessages, text: Self.firstMarker),
            "The resumed Codex turn did not include the first assistant response: \(secondMessages)"
        )
        await supervisor.stop()
    }

    private func isolatedEnvironment(
        home: URL,
        codexHome: URL,
        workspace: URL,
        temporary: URL
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "OPENAI_API_KEY", "AZURE_OPENAI_API_KEY", "CODEX_API_KEY",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["CODEX_HOME"] = codexHome.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
        environment["TMPDIR"] = temporary.path + "/"
        environment["PWD"] = workspace.path
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        environment["CI"] = "1"
        return environment
    }

    private func assertSuccessfulCodexResult(
        _ result: ClaudeCLIProcessResult,
        marker: String
    ) throws -> String {
        XCTAssertEqual(
            result.terminationStatus,
            0,
            "Codex CLI failed. stdout:\n\(result.standardOutput)\nstderr:\n\(result.standardError)"
        )
        let events: [[String: Any]] = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        let started = try XCTUnwrap(
            events.first(where: { $0["type"] as? String == "thread.started" }),
            "Codex CLI did not emit thread.started: \(result.standardOutput)"
        )
        let threadID = try XCTUnwrap(started["thread_id"] as? String)
        XCTAssertFalse(threadID.isEmpty)
        XCTAssertTrue(
            Self.jsonContains(events, text: marker),
            "Codex output did not contain \(marker): \(events)"
        )
        return threadID
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
