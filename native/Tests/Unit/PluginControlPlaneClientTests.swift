import Foundation
import XCTest
@testable import CCBuddy

final class PluginControlPlaneClientTests: XCTestCase {
    func testAuthenticationUsesDeclaredLocalEndpointAndDecodesState() async throws {
        let transport = RecordingPluginHTTPTransport(responses: [
            .success(.init(
                statusCode: 200,
                body: Data(#"{"state":"logged_in","account":"dev@example.com"}"#.utf8)
            )),
        ])
        let client = PluginControlPlaneClient(
            transport: transport,
            authenticationTimeoutMilliseconds: 321
        )

        let status = try await client.authenticationStatus(for: sidecar())
        XCTAssertEqual(status.state, .loggedIn)
        XCTAssertEqual(status.account, "dev@example.com")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, .get)
        XCTAssertEqual(requests[0].url.absoluteString, "http://127.0.0.1:55123/v1/plugin/auth")
        XCTAssertEqual(requests[0].timeoutMilliseconds, 321)
        XCTAssertNil(requests[0].body)
        XCTAssertNil(requests[0].headers["Authorization"])
    }

    func testAuthenticationRedactsCredentialMessageInSnapshotAndValues() async throws {
        let transport = RecordingPluginHTTPTransport(responses: [
            .success(.init(
                statusCode: 200,
                body: Data(#"{"state":"expired","message":"api_key=visible-key"}"#.utf8)
            )),
        ])
        let snapshot = try await PluginControlPlaneClient(transport: transport)
            .authenticationStatus(for: sidecar())

        XCTAssertEqual(snapshot.message, "api_key=[REDACTED]")
        XCTAssertEqual(snapshot.values["message"], .string("api_key=[REDACTED]"))
    }

    func testSubmitUsesJSONBodyWithoutShellOrURLInterpolationAndRedactsEchoedSecret() async throws {
        let secret = "top-secret-value"
        let transport = RecordingPluginHTTPTransport(responses: [
            .success(.init(
                statusCode: 200,
                body: Data(#"{"ok":true,"message":"saved top-secret-value"}"#.utf8)
            )),
        ])
        let client = PluginControlPlaneClient(transport: transport, actionSubmitTimeoutMilliseconds: 654)
        let action = PluginAction(values: [
            "id": .string("settings"),
            "kind": .string("form"),
            "submitPath": .string("/v1/plugin/action/settings"),
        ])
        let values: [String: PluginJSONValue] = [
            "password": .string(secret),
            "enabled": .bool(true),
        ]

        let response = try await client.submit(action: action, values: values, for: sidecar())
        XCTAssertEqual(response.message, "saved [REDACTED]")
        let submittedRequests = await transport.requests
        let request = try XCTUnwrap(submittedRequests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:55123/v1/plugin/action/settings")
        XCTAssertEqual(request.timeoutMilliseconds, 654)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(request.body)
        let decoded = try JSONDecoder().decode(PluginJSONValue.self, from: body)
        XCTAssertEqual(decoded, .object(values))
    }

    func testNonSuccessMessageAndTransportErrorsNeverExposeSubmittedValues() async throws {
        let secret = "sk-private-123456"
        let transport = RecordingPluginHTTPTransport(responses: [
            .success(.init(
                statusCode: 422,
                body: Data(#"{"message":"invalid sk-private-123456"}"#.utf8)
            )),
            .failure(FixtureTransportError.failed(secret)),
        ])
        let client = PluginControlPlaneClient(transport: transport)
        let action = PluginAction(values: ["id": .string("reset"), "kind": .string("call")])

        do {
            _ = try await client.submit(
                action: action,
                values: ["api_key": .string(secret)],
                for: sidecar()
            )
            XCTFail("Expected HTTP failure")
        } catch let error as PluginControlPlaneError {
            XCTAssertEqual(error, .unsuccessfulStatus(code: 422, message: "invalid [REDACTED]"))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }

        do {
            _ = try await client.submit(
                action: action,
                values: ["api_key": .string(secret)],
                for: sidecar()
            )
            XCTFail("Expected transport failure")
        } catch let error as PluginControlPlaneError {
            XCTAssertEqual(error, .transportFailure)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testInjectedTransportCannotSupplyAnUnsafeControlPlaneError() async throws {
        let secret = "transport-secret"
        let transport = RecordingPluginHTTPTransport(responses: [
            .failure(PluginControlPlaneError.unsuccessfulStatus(code: 500, message: secret)),
        ])
        let client = PluginControlPlaneClient(transport: transport)
        let action = PluginAction(values: ["id": .string("reset"), "kind": .string("call")])

        do {
            _ = try await client.submit(
                action: action,
                values: ["password": .string(secret)],
                for: sidecar()
            )
            XCTFail("Expected transport failure")
        } catch let error as PluginControlPlaneError {
            XCTAssertEqual(error, .transportFailure)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testLoadReturnsDynamicValuesAndLinkActionsAreNeverForwarded() async throws {
        let transport = RecordingPluginHTTPTransport(responses: [
            .success(.init(
                statusCode: 200,
                body: Data(#"{"values":{"port":4321,"enabled":true}}"#.utf8)
            )),
        ])
        let client = PluginControlPlaneClient(transport: transport, actionLoadTimeoutMilliseconds: 987)
        let form = PluginAction(values: [
            "id": .string("settings"),
            "kind": .string("form"),
            "loadPath": .string("/v1/plugin/action/settings/load"),
        ])
        let response = try await client.load(action: form, for: sidecar())
        XCTAssertEqual(response.values["values"], .object([
            "port": .number(4321), "enabled": .bool(true),
        ]))
        let loadedRequests = await transport.requests
        XCTAssertEqual(loadedRequests.first?.timeoutMilliseconds, 987)

        let link = PluginAction(values: [
            "id": .string("docs"), "kind": .string("link"), "url": .string("https://example.com"),
        ])
        await XCTAssertThrowsErrorAsync(try await client.load(action: link, for: sidecar())) { error in
            XCTAssertEqual(error as? PluginControlPlaneError, .actionNotForwardable("docs"))
        }
        let finalRequests = await transport.requests
        XCTAssertEqual(finalRequests.count, 1)
    }

    func testResponseBodyIsBoundedBeforeJSONParsing() async throws {
        let transport = RecordingPluginHTTPTransport(responses: [
            .success(.init(statusCode: 200, body: Data(repeating: 65, count: 17))),
        ])
        let client = PluginControlPlaneClient(transport: transport, maximumResponseBytes: 16)
        do {
            _ = try await client.authenticationStatus(for: sidecar())
            XCTFail("Expected response limit")
        } catch let error as PluginControlPlaneError {
            XCTAssertEqual(error, .responseTooLarge(limit: 16))
        }
    }

    func testSecretRedactorCoversAuthorizationAndCredentialFields() {
        let redactor = PluginSecretRedactor(explicitSecrets: ["literal-secret"])
        let value = #"Authorization: Bearer abc.def password="hunter2" api_key=key-123 client_secret='two word secret' literal-secret"#
        let redacted = redactor.redact(value)
        XCTAssertFalse(redacted.contains("abc.def"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("key-123"))
        XCTAssertFalse(redacted.contains("two word secret"))
        XCTAssertFalse(redacted.contains("literal-secret"))
        XCTAssertTrue(redacted.contains(PluginSecretRedactor.replacement))
    }

    private func sidecar() -> PluginSidecarDescriptor {
        let provider = PluginProviderDescriptor(
            id: "plugin:fixture",
            name: "Fixture",
            pluginID: "fixture",
            baseURL: URL(string: "http://127.0.0.1:55123/v1")!,
            protocolName: "openai-responses",
            defaultModel: "primary",
            smallFastModel: "light",
            iconFile: nil
        )
        return PluginSidecarDescriptor(
            pluginID: "fixture",
            executable: URL(fileURLWithPath: "/fixture/plugin"),
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/fixture"),
            standardErrorLog: URL(fileURLWithPath: "/fixture/plugin.log"),
            healthURL: URL(string: "http://127.0.0.1:55123/healthz")!,
            authenticationStatusURL: URL(string: "http://127.0.0.1:55123/v1/plugin/auth")!,
            readyTimeoutMilliseconds: 8_000,
            provider: provider
        )
    }
}

private actor RecordingPluginHTTPTransport: PluginHTTPTransporting {
    private(set) var requests: [PluginHTTPRequest] = []
    private var responses: [Result<PluginHTTPResponse, Error>]

    init(responses: [Result<PluginHTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: PluginHTTPRequest) async throws -> PluginHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw FixtureTransportError.empty }
        return try responses.removeFirst().get()
    }
}

private enum FixtureTransportError: Error {
    case empty
    case failed(String)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        handler(error)
    }
}
