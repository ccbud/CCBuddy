import Foundation
import XCTest
@testable import CCBuddy

final class ClaudeCLIBifrostE2ETests: XCTestCase {
    func testRealClaudeCLIStreamsThroughPinnedBifrostAndResumesWithAssistantContext() async throws {
        guard let claude = ClaudeCLIE2ETestSupport.claudeExecutable() else {
            throw XCTSkip("Claude CLI is unavailable; set CCBUD_CLAUDE_BINARY to enable this E2E")
        }
        guard let bifrost = ClaudeCLIE2ETestSupport.bifrostExecutable() else {
            throw XCTSkip("Pinned bifrost-http is unavailable; run native/Scripts/fetch-bifrost.sh")
        }

        let upstream = try ClaudeCLIAnthropicMock()
        upstream.start()
        defer { upstream.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-claude-cli-e2e-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let claudeConfig = root.appendingPathComponent("claude-config", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        for directory in [home, claudeConfig, workspace, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let gatewayToken = "sk-bf-ccbud-claude-cli-e2e"
        let providerToken = "sk-ccbud-upstream-e2e"
        var config = AppConfig.fixture
        config.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        config.providers[0].baseUrl = "http://127.0.0.1:\(upstream.port)"
        config.providers[0].authToken = providerToken
        config.retry429.enabled = false
        config.requireToken = true
        config.gatewayToken = gatewayToken

        let supervisor = BifrostSupervisor(environment: [
            "CCBUD_HOME": root.appendingPathComponent("ccbud", isDirectory: true).path,
            "CCBUD_BIFROST_BINARY": bifrost,
        ])
        try await supervisor.start(config: config)
        addTeardownBlock {
            await supervisor.stop()
            upstream.stop()
        }

        let sessionID = UUID().uuidString.lowercased()
        let environment = isolatedEnvironment(
            home: home,
            claudeConfig: claudeConfig,
            workspace: workspace,
            temporary: temporary,
            gatewayPort: config.port,
            gatewayToken: gatewayToken
        )
        let first = try await ClaudeCLIE2ETestSupport.run(
            executable: claude,
            arguments: arguments(
                session: ["--session-id", sessionID],
                prompt: "Reply with exactly \(ClaudeCLIAnthropicMock.firstMarker). Do not call tools."
            ),
            environment: environment,
            currentDirectory: workspace
        )
        try assertSuccessfulCLIResult(
            first,
            marker: ClaudeCLIAnthropicMock.firstMarker,
            sessionID: sessionID
        )

        let second = try await ClaudeCLIE2ETestSupport.run(
            executable: claude,
            arguments: arguments(
                session: ["--resume", sessionID],
                prompt: "Continue this session and reply with exactly \(ClaudeCLIAnthropicMock.secondMarker)."
            ),
            environment: environment,
            currentDirectory: workspace
        )
        try assertSuccessfulCLIResult(
            second,
            marker: ClaudeCLIAnthropicMock.secondMarker,
            sessionID: sessionID
        )

        let requests = upstream.messageRequests
        XCTAssertEqual(
            requests.count,
            2,
            "Expected one Anthropic Messages operation per CLI turn; all targets: \(upstream.requests.map(\.target))"
        )
        guard requests.count == 2 else {
            await supervisor.stop()
            return
        }

        for request in requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.target, "/v1/messages")
            XCTAssertEqual(request.headers["x-api-key"], providerToken)
            XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
            XCTAssertEqual(request.body["stream"] as? Bool, true)
            XCTAssertEqual(request.body["model"] as? String, "glm-5.2")
            let tools = try XCTUnwrap(request.body["tools"] as? [[String: Any]])
            XCTAssertFalse(tools.isEmpty, "Claude's tool-capable Messages payload lost its tools")
            XCTAssertNotNil(tools.first?["name"] as? String)
            XCTAssertNotNil(tools.first?["input_schema"] as? [String: Any])
        }

        let secondMessages = try XCTUnwrap(requests[1].body["messages"] as? [[String: Any]])
        let priorAssistant = secondMessages.first { message in
            message["role"] as? String == "assistant"
                && jsonContains(message["content"], text: ClaudeCLIAnthropicMock.firstMarker)
        }
        XCTAssertNotNil(
            priorAssistant,
            "The resumed CLI turn did not send the first assistant response as prior context: \(secondMessages)"
        )

        await supervisor.stop()
    }

    private func arguments(session: [String], prompt: String) -> [String] {
        [
            "--print",
            "--safe-mode",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--output-format", "json",
            "--prompt-suggestions", "false",
            "--permission-mode", "dontAsk",
            "--model", "claude-opus-4-8",
            "--tools", "Bash",
        ] + session + [prompt]
    }

    private func isolatedEnvironment(
        home: URL,
        claudeConfig: URL,
        workspace: URL,
        temporary: URL,
        gatewayPort: Int,
        gatewayToken: String
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "ANTHROPIC_API_KEY",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["CLAUDE_CONFIG_DIR"] = claudeConfig.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache").path
        environment["TMPDIR"] = temporary.path + "/"
        environment["PWD"] = workspace.path
        environment["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(gatewayPort)/anthropic"
        environment["ANTHROPIC_AUTH_TOKEN"] = gatewayToken
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["CLAUDE_CODE_ENABLE_TELEMETRY"] = "0"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        environment["CI"] = "1"
        return environment
    }

    private func assertSuccessfulCLIResult(
        _ result: ClaudeCLIProcessResult,
        marker: String,
        sessionID: String
    ) throws {
        XCTAssertEqual(
            result.terminationStatus,
            0,
            "Claude CLI failed. stdout:\n\(result.standardOutput)\nstderr:\n\(result.standardError)"
        )
        guard result.terminationStatus == 0 else { return }
        let data = Data(result.standardOutput.utf8)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Claude CLI did not emit JSON: \(result.standardOutput)"
        )
        XCTAssertEqual(object["type"] as? String, "result")
        XCTAssertEqual(object["is_error"] as? Bool, false)
        XCTAssertEqual((object["session_id"] as? String)?.lowercased(), sessionID)
        XCTAssertTrue(
            (object["result"] as? String)?.contains(marker) == true,
            "Claude result did not contain \(marker): \(object)"
        )
    }

    private func jsonContains(_ value: Any?, text: String) -> Bool {
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
