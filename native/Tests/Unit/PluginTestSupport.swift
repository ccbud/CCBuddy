import Foundation

private final class PluginTestBundleToken: NSObject {}

enum PluginTestSupport {
    private static let bundle = Bundle(for: PluginTestBundleToken.self)

    static var fixturesRoot: URL {
        guard let resourceURL = bundle.resourceURL else {
            preconditionFailure("CCBuddyTests has no resource directory")
        }
        return resourceURL
    }

    static func fixture(_ name: String) -> URL {
        fixtureManifest(name).deletingLastPathComponent()
    }

    static func fixtureManifest(_ name: String) -> URL {
        guard let fixture = bundle.url(
            forResource: "\(name)-plugin",
            withExtension: "json"
        ) else {
            preconditionFailure("Missing bundled plugin fixture: \(name)-plugin.json")
        }
        return fixture
    }

    static func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writePlugin(
        at directory: URL,
        id: String,
        version: String,
        source: String = "",
        branch: String = "main",
        build: String = "",
        payload: String = "payload"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableRelative = "bin/darwin-arm64/\(id)"
        let executable = directory.appendingPathComponent(executableRelative)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(payload.utf8).write(to: directory.appendingPathComponent("payload.txt"), options: [.atomic])

        let object: [String: Any] = [
            "spec": "ccbud-plugin/1",
            "id": id,
            "name": "Plugin \(id)",
            "version": version,
            "description": "fixture \(version)",
            "source": ["git": source, "branch": branch, "build": build],
            "runtime": [
                "exec": ["darwin-arm64": executableRelative],
                "args": ["serve", "--port", "{port}", "--home", "{home}"],
            ],
            "endpoint": [
                "protocol": "openai-responses",
                "basePath": "/v1",
                "healthPath": "/healthz",
                "readyTimeoutMs": 8_000,
            ],
            "auth": ["statusPath": "/v1/plugin/auth"],
            "models": [["alias": "primary", "upstream": "vendor-primary"]],
            "modelMapping": ["primary": "primary", "light": "primary"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("plugin.json"), options: [.atomic])
        return executable
    }
}
