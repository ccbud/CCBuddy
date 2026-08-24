import ServiceManagement
import XCTest
@testable import CCBuddy

final class AppConfigTests: XCTestCase {
    func testLegacyConfigDecodesAndNormalizes() throws {
        let data = Data(#"{"port":0,"activeProviderId":"missing","providers":[{"name":" GLM ","baseUrl":"https://example.com","authToken":"k","models":[{"alias":"a","upstream":"b"}]}]}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(config.port, 8788)
        XCTAssertEqual(config.providers.first?.name, "GLM")
        XCTAssertEqual(config.activeProviderId, config.providers.first?.id)
        XCTAssertEqual(config.providers.first?.protocol, .anthropic)
    }

    func testRepositoryRoundTripUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("config.json")
        let repository = ConfigRepository(configURL: url)
        try repository.save(.fixture)
        XCTAssertEqual(try repository.load(), .fixture)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testRepositorySavePreservesSymlinkedConfigFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-config-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managedDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        let configDirectory = root.appendingPathComponent("ccbud", isDirectory: true)
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let target = managedDirectory.appendingPathComponent("config.json")
        let link = configDirectory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let repository = ConfigRepository(configURL: link)
        var config = AppConfig.fixture
        config.port = 9_876

        try repository.save(config)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            target.path
        )
        XCTAssertEqual(try repository.load().port, 9_876)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: target)).port, 9_876)
    }

    func testRepositoryPreservesCompatibilityBackupsAndUnknownRootKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("config.json")
        let data = Data(#"{"port":8788,"claudeBackup":{"model":"old"},"codexBackup":{"model_provider":"openai"},"futureFeature":{"enabled":true},"providers":[]}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url)

        let repository = ConfigRepository(configURL: url)
        var config = try repository.load()
        config.openAtLogin = true
        try repository.save(config)

        let saved = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved["claudeBackup"], .object(["model": .string("old")]))
        XCTAssertEqual(saved["codexBackup"], .object(["model_provider": .string("openai")]))
        XCTAssertEqual(saved["futureFeature"], .object(["enabled": .bool(true)]))
    }

    func testLegacyNormalizationMatchesInvalidEnumsDeduplicationAndGLMMigration() throws {
        let data = Data(#"{"language":"bogus","connectTargets":["codex","claude","codex","other"],"historyActive":"missing","providers":[{"id":"p","name":" ","baseUrl":"https://open.bigmodel.cn/api/anthropic/","protocol":"grpc","backend":"unknown","models":[]}] }"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertNil(config.language)
        XCTAssertEqual(config.connectTargets, ["codex", "claude"])
        XCTAssertEqual(config.historyActive, "all")
        XCTAssertEqual(config.providers[0].name, "Unnamed")
        XCTAssertEqual(config.providers[0].protocol, .anthropic)
        XCTAssertEqual(config.providers[0].backend, .http)
        XCTAssertEqual(config.providers[0].baseUrl, "https://open.bigmodel.cn/api/anthropic/v1")
    }

    func testRealisticLegacyConfigDecodesPartialObjectsAndRoundTripsWithoutFieldLoss() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-config-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AppConfigMigrationFixtures.legacy1xPartial.write(to: repository.configURL)

        let config = try repository.load()

        XCTAssertEqual(config.port, 9_124)
        XCTAssertEqual(config.activeProviderId, "legacy-glm")
        XCTAssertTrue(config.requireToken)
        XCTAssertEqual(config.gatewayToken, "ccbud_legacy-token")
        XCTAssertFalse(config.gatewayEnabled)
        XCTAssertTrue(config.openAtLogin)
        XCTAssertEqual(config.claudeBackup, .object(["model": .string("claude-legacy")]))
        XCTAssertEqual(config.codexBackup, .object(["model_provider": .string("ccbud")]))
        XCTAssertEqual(config.trayUsage, .init(enabled: true, range: "7d"))
        XCTAssertEqual(config.language, "en")
        XCTAssertEqual(config.convFontPx, 15)
        XCTAssertEqual(config.historyDirs, ["~/.claude", "~/.codex"])
        XCTAssertEqual(config.historyActive, "all")
        XCTAssertEqual(config.connectTargets, ["claude", "codex"])
        XCTAssertEqual(config.retry429, .init(enabled: true, max: 8, baseMs: 500))
        XCTAssertTrue(config.insecureSkipVerify)
        XCTAssertEqual(config.autoUpdate, .init(check: false, autoDownload: true))
        XCTAssertEqual(config.providers.map(\.id), ["legacy-glm"])
        XCTAssertEqual(config.providers[0].authToken, "legacy-provider-token")
        XCTAssertEqual(config.providers[0].models, [.init(alias: "fast", upstream: "glm-fast")])
        XCTAssertEqual(config.additionalProperties["futureFeature"], .object([
            "enabled": .bool(true),
            "label": .string("preserve me"),
        ]))

        try repository.save(config)
        XCTAssertEqual(try repository.load(), config)
        let saved = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(contentsOf: repository.configURL)
        )
        XCTAssertEqual(saved["futureFeature"], config.additionalProperties["futureFeature"])
        XCTAssertEqual(saved["claudeBackup"], config.claudeBackup)
        XCTAssertEqual(saved["codexBackup"], config.codexBackup)
        XCTAssertEqual(saved["port"], .number(9_124))
        XCTAssertEqual(saved["activeProviderId"], .string("legacy-glm"))
    }

    func testMixedNestedTypesDefaultOnlyInvalidMembersWithoutResettingConfig() throws {
        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: AppConfigMigrationFixtures.mixedNestedTypes
        )

        XCTAssertEqual(config.port, 8_788)
        XCTAssertEqual(config.activeProviderId, "mixed-provider")
        XCTAssertTrue(config.openAtLogin)
        XCTAssertEqual(config.language, "ja")
        XCTAssertEqual(config.trayUsage, .init(enabled: false, range: "30d"))
        XCTAssertEqual(config.retry429, .init(enabled: false, max: 3, baseMs: 750))
        XCTAssertEqual(config.autoUpdate, .init(check: true, autoDownload: false))
        XCTAssertEqual(config.providers.first?.name, "Mixed provider")
        XCTAssertEqual(config.additionalProperties["futureScalar"], .string("keep-me"))
    }

    func testGatewayFailoverDefaultsDisabledAndRoundTripsOrderedQueue() throws {
        let legacy = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"providers":[{"id":"primary","name":"Primary","baseUrl":"https://primary.example/v1"}]}"#.utf8)
        )
        XCTAssertEqual(legacy.gatewayFailover, .init())

        var config = legacy
        config.gatewayFailover = .init(
            enabled: true,
            providerIds: ["missing", "secondary", "secondary", "primary"]
        )
        config.providers.append(Provider(
            id: "secondary", name: "Secondary", baseUrl: "https://secondary.example/v1"
        ))
        config.normalize()

        XCTAssertEqual(config.gatewayFailover.providerIds, ["secondary", "primary"])
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        XCTAssertEqual(decoded.gatewayFailover, config.gatewayFailover)
    }

    func testEnabledEmptyGatewayFailoverQueueIsNotImplicitlyFilledFromActiveProvider() throws {
        let data = Data(#"{"activeProviderId":"b","gatewayFailover":{"enabled":true,"providerIds":[]},"providers":[{"id":"a","name":"A","baseUrl":"https://a.example/v1"},{"id":"b","name":"B","baseUrl":"https://b.example/v1"},{"id":"c","name":"C","baseUrl":"https://c.example/v1"}]}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.gatewayFailover.providerIds, [])
    }

    func testEnabledGatewayFailoverPreservesDecodedQueueOrderIndependentOfActiveProvider() throws {
        for queue in [["a", "b", "c"], ["a", "c"]] {
            let object: [String: Any] = [
                "activeProviderId": "b",
                "gatewayFailover": ["enabled": true, "providerIds": queue],
                "providers": [
                    ["id": "a", "name": "A", "baseUrl": "https://a.example/v1"],
                    ["id": "b", "name": "B", "baseUrl": "https://b.example/v1"],
                    ["id": "c", "name": "C", "baseUrl": "https://c.example/v1"],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)

            XCTAssertEqual(config.gatewayFailover.providerIds, queue)
        }
    }
}

@MainActor
final class AppModelInterfacePreferencesTests: XCTestCase {
    func testInterfacePreferencesArePersistentOnlyForPrimaryApplicationProcess() {
        XCTAssertEqual(AppModel.themeModeDefaultsKey, "ccbud-theme")
        XCTAssertEqual(AppModel.sidebarCollapsedDefaultsKey, "ccbud-sidebar-collapsed")
        XCTAssertTrue(AppModel.shouldUsePersistentInterfacePreferences(
            runtimeMode: .application,
            isPrimaryInstance: true
        ))

        let excludedContexts: [(AppModel.RuntimeMode, Bool)] = [
            (.application, false),
            (.uiTesting, true),
            (.unitTestHost, true),
            (.selfCheck, true),
        ]
        for (runtimeMode, isPrimaryInstance) in excludedContexts {
            XCTAssertFalse(AppModel.shouldUsePersistentInterfacePreferences(
                runtimeMode: runtimeMode,
                isPrimaryInstance: isPrimaryInstance
            ))
        }
    }

    func testPrimaryApplicationRestoresAndPersistsInterfacePreferences() async throws {
        let root = temporaryRoot(named: "primary")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try configuredRepository(at: root)
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialModel = makeModel(
            root: root,
            repository: repository,
            environment: applicationEnvironment(root: root),
            isPrimaryInstance: true,
            defaults: defaults
        )

        XCTAssertEqual(initialModel.themeMode, .light)
        XCTAssertFalse(initialModel.sidebarCollapsed)
        initialModel.toggleTheme()
        initialModel.toggleSidebar()
        XCTAssertEqual(defaults.string(forKey: AppModel.themeModeDefaultsKey), "dark")
        XCTAssertEqual(
            defaults.object(forKey: AppModel.sidebarCollapsedDefaultsKey) as? Bool,
            true
        )
        await initialModel.shutdown()

        let restoredModel = makeModel(
            root: root,
            repository: repository,
            environment: applicationEnvironment(root: root),
            isPrimaryInstance: true,
            defaults: defaults
        )

        XCTAssertEqual(restoredModel.themeMode, .dark)
        XCTAssertTrue(restoredModel.sidebarCollapsed)
        restoredModel.toggleTheme()
        restoredModel.toggleSidebar()
        XCTAssertEqual(defaults.string(forKey: AppModel.themeModeDefaultsKey), "light")
        XCTAssertEqual(
            defaults.object(forKey: AppModel.sidebarCollapsedDefaultsKey) as? Bool,
            false
        )
        await restoredModel.shutdown()
    }

    func testMalformedInterfacePreferencesFallBackWithoutBeingRewritten() async throws {
        let root = temporaryRoot(named: "malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try configuredRepository(at: root)
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("system", forKey: AppModel.themeModeDefaultsKey)
        defaults.set(2, forKey: AppModel.sidebarCollapsedDefaultsKey)

        let model = makeModel(
            root: root,
            repository: repository,
            environment: applicationEnvironment(root: root),
            isPrimaryInstance: true,
            defaults: defaults
        )

        XCTAssertEqual(model.themeMode, .light)
        XCTAssertFalse(model.sidebarCollapsed)
        XCTAssertEqual(defaults.string(forKey: AppModel.themeModeDefaultsKey), "system")
        XCTAssertEqual(defaults.integer(forKey: AppModel.sidebarCollapsedDefaultsKey), 2)
        await model.shutdown()
    }

    func testExcludedRuntimeContextsNeitherRestoreNorPersistInterfacePreferences() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("dark", forKey: AppModel.themeModeDefaultsKey)
        defaults.set(true, forKey: AppModel.sidebarCollapsedDefaultsKey)

        let scenarios: [(name: String, environment: [String: String], primary: Bool)] = [
            ("ui", ["CCBUD_UI_TESTING": "1"], true),
            ("unit", ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"], true),
            ("self-check", [SelfCheckEnvironmentGate.enabledKey: "1"], true),
            ("secondary", [:], false),
        ]

        for scenario in scenarios {
            let root = temporaryRoot(named: scenario.name)
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = try configuredRepository(at: root)
            var environment = applicationEnvironment(root: root)
            environment.merge(scenario.environment) { _, scenarioValue in scenarioValue }
            let model = makeModel(
                root: root,
                repository: repository,
                environment: environment,
                isPrimaryInstance: scenario.primary,
                defaults: defaults
            )

            XCTAssertEqual(model.themeMode, .light, scenario.name)
            XCTAssertFalse(model.sidebarCollapsed, scenario.name)
            model.toggleTheme()
            model.toggleSidebar()
            model.toggleTheme()
            model.toggleSidebar()
            XCTAssertEqual(
                defaults.string(forKey: AppModel.themeModeDefaultsKey),
                "dark",
                scenario.name
            )
            XCTAssertEqual(
                defaults.object(forKey: AppModel.sidebarCollapsedDefaultsKey) as? Bool,
                true,
                scenario.name
            )
            await model.shutdown()
        }
    }

    private func makeModel(
        root: URL,
        repository: ConfigRepository,
        environment: [String: String],
        isPrimaryInstance: Bool,
        defaults: UserDefaults
    ) -> AppModel {
        AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: environment,
            isPrimaryInstance: isPrimaryInstance,
            userDefaults: defaults
        )
    }

    private func configuredRepository(at root: URL) throws -> ConfigRepository {
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        var config = AppConfig.fixture
        config.gatewayEnabled = false
        config.openAtLogin = false
        config.autoUpdate.check = false
        config.autoUpdate.autoDownload = false
        config.historyDirs = [root.appendingPathComponent("history", isDirectory: true).path]
        config.historyActive = "all"
        try repository.save(config)
        return repository
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dev.ccbud.gateway.tests.interface-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func applicationEnvironment(root: URL) -> [String: String] {
        [
            "HOME": root.path,
            "CCBUD_HOME": root.path,
        ]
    }

    private func temporaryRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-interface-preferences-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private enum AppConfigMigrationFixtures {
    /// Representative 1.x state: string-backed form port, the retired Codex selector, backups,
    /// a full provider/token, a future root key, and nested settings written by older releases
    /// before every member existed.
    static let legacy1xPartial = Data(#"""
    {
      "port": "9124",
      "activeProviderId": "legacy-glm",
      "requireToken": true,
      "gatewayToken": "ccbud_legacy-token",
      "gatewayEnabled": false,
      "openAtLogin": true,
      "claudeBackup": { "model": "claude-legacy" },
      "codexBackup": { "model_provider": "ccbud" },
      "trayUsage": { "enabled": true },
      "language": "en",
      "convFontPx": 15,
      "historyDirs": ["~/.claude", "~/.codex"],
      "historyActive": "__codex__",
      "connectTargets": ["claude", "codex"],
      "retry429": { "max": 8 },
      "insecureSkipVerify": true,
      "autoUpdate": { "check": false },
      "providers": [
        {
          "id": "legacy-glm",
          "name": "Legacy GLM",
          "baseUrl": "https://legacy.example/v1",
          "authToken": "legacy-provider-token",
          "defaultModel": "glm-main",
          "smallFastModel": "glm-fast",
          "models": [{ "alias": "fast", "upstream": "glm-fast" }]
        }
      ],
      "futureFeature": { "enabled": true, "label": "preserve me" }
    }
    """#.utf8)

    /// Wrongly typed nested members occurred in hand-edited and pre-normalized configs. Valid
    /// siblings and unrelated root fields must survive even though those members fall back.
    static let mixedNestedTypes = Data(#"""
    {
      "port": "not-a-port",
      "activeProviderId": "mixed-provider",
      "openAtLogin": true,
      "language": "ja",
      "trayUsage": { "enabled": "true", "range": "30d" },
      "retry429": { "enabled": false, "max": "8", "baseMs": 750 },
      "autoUpdate": { "check": 0, "autoDownload": false },
      "providers": [
        {
          "id": "mixed-provider",
          "name": "Mixed provider",
          "baseUrl": "https://mixed.example/v1"
        }
      ],
      "futureScalar": "keep-me"
    }
    """#.utf8)
}

@MainActor
final class AppModelTests: XCTestCase {
    func testSelectingProviderDoesNotChangeEnabledFailoverQueueOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-failover-active-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        initial.providers.append(Provider(
            id: "secondary", name: "Secondary", baseUrl: "https://secondary.example/v1"
        ))
        initial.gatewayFailover = .init(
            enabled: true,
            providerIds: [initial.providers[0].id, "secondary"]
        )
        try repository.save(initial)
        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        )
        addTeardownBlock {
            await model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        await model.setActiveProvider("secondary")

        XCTAssertEqual(model.config.activeProviderId, "secondary")
        XCTAssertEqual(
            model.config.gatewayFailover.providerIds,
            [initial.providers[0].id, "secondary"]
        )
        XCTAssertEqual(try repository.load(), model.config)
    }

    func testEnablingGatewayFailoverSeedsAnEmptyQueueWithOnlyTheCurrentProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-failover-seed-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        initial.providers.append(contentsOf: [
            Provider(id: "secondary", name: "Secondary", baseUrl: "https://secondary.example/v1"),
            Provider(id: "tertiary", name: "Tertiary", baseUrl: "https://tertiary.example/v1"),
        ])
        initial.gatewayFailover = .init(enabled: false, providerIds: [])
        try repository.save(initial)
        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        )
        addTeardownBlock {
            await model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        await model.setGatewayFailoverEnabled(true)

        XCTAssertTrue(model.config.gatewayFailover.enabled)
        XCTAssertEqual(model.config.gatewayFailover.providerIds, [initial.providers[0].id])
        XCTAssertEqual(model.config.activeProviderId, initial.providers[0].id)
        XCTAssertEqual(try repository.load(), model.config)
    }

    func testEnablingGatewayFailoverDoesNotChangeTheActiveProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-failover-enable-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        initial.providers.append(Provider(
            id: "secondary", name: "Secondary", baseUrl: "https://secondary.example/v1"
        ))
        initial.gatewayFailover = .init(
            enabled: false,
            providerIds: ["secondary", initial.providers[0].id]
        )
        try repository.save(initial)
        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        )
        addTeardownBlock {
            await model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        await model.setGatewayFailoverEnabled(true)

        XCTAssertTrue(model.config.gatewayFailover.enabled)
        XCTAssertEqual(
            model.config.gatewayFailover.providerIds,
            ["secondary", initial.providers[0].id]
        )
        XCTAssertEqual(model.config.activeProviderId, initial.providers[0].id)
        XCTAssertEqual(try repository.load(), model.config)
    }

    func testXcodeHostedRunUsesUnitTestRuntimeMode() {
        XCTAssertEqual(
            AppModel.runtimeMode(environment: ProcessInfo.processInfo.environment),
            .unitTestHost
        )
    }

    func testRuntimeModeOnlyTreatsExplicitTestSignalsAsTests() {
        XCTAssertTrue(AppModel.uiTestingBuildEnabled)
        XCTAssertEqual(AppModel.runtimeMode(environment: [:]), .application)
        XCTAssertEqual(
            AppModel.runtimeMode(environment: ["XCTestConfigurationFilePath": ""]),
            .application
        )
        XCTAssertEqual(
            AppModel.runtimeMode(environment: [
                "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"
            ]),
            .unitTestHost
        )
        XCTAssertEqual(
            AppModel.runtimeMode(environment: [
                "CCBUD_UI_TESTING": "1",
                "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
            ]),
            .uiTesting
        )
        XCTAssertEqual(
            AppModel.runtimeMode(environment: [
                "CCBUD_SELFCHECK": "1",
                "CCBUD_UI_TESTING": "1",
                "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
            ]),
            .selfCheck
        )
    }

    func testProcessRuntimeModeUsesLoadedXCTestOnlyAsBootstrapFallback() {
        XCTAssertEqual(
            AppModel.processRuntimeMode(environment: [:], xctestLoaded: true),
            .unitTestHost
        )
        XCTAssertEqual(
            AppModel.processRuntimeMode(
                environment: ["CCBUD_UI_TESTING": "1"],
                xctestLoaded: true
            ),
            .uiTesting
        )
        XCTAssertEqual(
            AppModel.processRuntimeMode(
                environment: ["CCBUD_SELFCHECK": "1"],
                xctestLoaded: true
            ),
            .selfCheck
        )
        XCTAssertEqual(
            AppModel.processRuntimeMode(environment: [:], xctestLoaded: false),
            .application
        )
    }

    func testConversationHistoryHomeKeepsAutomatedCanonicalAdaptersIsolated() {
        let userHome = URL(fileURLWithPath: "/Users/ccbud-real-home", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/private/tmp/ccbud-home-tests", isDirectory: true)
        let isolated = temporary.appendingPathComponent("isolated", isDirectory: true)

        XCTAssertEqual(
            AppModel.conversationHistoryHomeDirectory(
                runtimeMode: .application,
                environment: ["CCBUD_HOME": isolated.path],
                userHomeDirectory: userHome,
                temporaryDirectory: temporary,
                processIdentifier: 42
            ),
            userHome.standardizedFileURL
        )
        XCTAssertEqual(
            AppModel.conversationHistoryHomeDirectory(
                runtimeMode: .uiTesting,
                environment: ["CCBUD_HOME": "  \(isolated.path)  "],
                userHomeDirectory: userHome,
                temporaryDirectory: temporary,
                processIdentifier: 42
            ),
            isolated.standardizedFileURL
        )
        XCTAssertEqual(
            AppModel.conversationHistoryHomeDirectory(
                runtimeMode: .uiTesting,
                environment: [:],
                userHomeDirectory: userHome,
                temporaryDirectory: temporary,
                processIdentifier: 42
            ),
            temporary.appendingPathComponent(
                "ccbud-ui-history-home-42",
                isDirectory: true
            ).standardizedFileURL
        )
        let selfCheckEnvironment = [
            SelfCheckEnvironmentGate.enabledKey: "1",
            SelfCheckEnvironmentGate.homeKey: isolated.path,
        ]
        let selfCheckHome: URL
        if case .enabled(let request) = SelfCheckEnvironmentGate.evaluate(
            environment: selfCheckEnvironment,
            userHomeDirectory: userHome
        ) {
            selfCheckHome = request.homeDirectory
        } else {
            return XCTFail("Expected the dedicated self-check home to pass isolation validation")
        }
        XCTAssertEqual(
            AppModel.conversationHistoryHomeDirectory(
                runtimeMode: .selfCheck,
                environment: selfCheckEnvironment,
                userHomeDirectory: userHome,
                temporaryDirectory: temporary,
                processIdentifier: 42
            ),
            selfCheckHome
        )
        XCTAssertEqual(
            AppModel.conversationHistoryHomeDirectory(
                runtimeMode: .selfCheck,
                environment: [SelfCheckEnvironmentGate.enabledKey: "1"],
                userHomeDirectory: userHome,
                temporaryDirectory: temporary,
                processIdentifier: 42
            ),
            temporary.appendingPathComponent(
                "ccbud-rejected-selfcheck-42",
                isDirectory: true
            ).standardizedFileURL
        )
    }

    func testLegacySmokeVisualFixtureRequiresExactValueAndUITestingMode() {
        let fixtureOnly = ["CCBUD_UI_VISUAL_FIXTURE": "legacy-smoke"]
        XCTAssertNil(AppModel.uiVisualFixture(environment: fixtureOnly))
        XCTAssertNil(AppModel.uiVisualFixture(environment: [
            "CCBUD_UI_TESTING": "1",
            "CCBUD_UI_VISUAL_FIXTURE": "unknown",
        ]))
        XCTAssertEqual(AppModel.uiVisualFixture(environment: [
            "CCBUD_UI_TESTING": "1",
            "CCBUD_UI_VISUAL_FIXTURE": "legacy-smoke",
        ]), .legacySmoke)
        XCTAssertNil(AppModel.uiVisualFixture(environment: [
            "CCBUD_SELFCHECK": "1",
            "CCBUD_UI_TESTING": "1",
            "CCBUD_UI_VISUAL_FIXTURE": "legacy-smoke",
        ]))
    }

    func testLegacySmokeVisualFixtureUsesReadOnlyLegacyCatalogAndMapping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-visual-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: [
                "CCBUD_UI_TESTING": "1",
                "CCBUD_UI_VISUAL_FIXTURE": "legacy-smoke",
            ]
        )

        XCTAssertEqual(model.config.providers[0].models, [.init(alias: "a", upstream: "b")])
        await model.refreshPlugins(reconcileProviders: false)
        XCTAssertEqual(model.plugins.map(\.id), ["demo"])
        XCTAssertEqual(model.plugins[0].name, "Demo")
        XCTAssertEqual(model.plugins[0].version, "1.0.0")
        XCTAssertEqual(model.plugins[0].protocolName, "anthropic")
        XCTAssertEqual(model.plugins[0].lifecycle, .stopped)
        XCTAssertEqual(model.plugins[0].authentication?.state, .loggedOut)
        XCTAssertEqual(model.plugins[0].actions.map(\.id), ["a1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.configURL.path))
    }

    func testHistoryDirectoryDiscoveryOnlyRunsAutomaticallyInPrimaryApplication() {
        XCTAssertTrue(AppModel.shouldAutoDiscoverHistoryDirectories(
            runtimeMode: .application,
            isPrimaryInstance: true
        ))
        XCTAssertFalse(AppModel.shouldAutoDiscoverHistoryDirectories(
            runtimeMode: .application,
            isPrimaryInstance: false
        ))
        XCTAssertFalse(AppModel.shouldAutoDiscoverHistoryDirectories(
            runtimeMode: .unitTestHost,
            isPrimaryInstance: true
        ))
        XCTAssertFalse(AppModel.shouldAutoDiscoverHistoryDirectories(
            runtimeMode: .uiTesting,
            isPrimaryInstance: true
        ))
        XCTAssertFalse(AppModel.shouldAutoDiscoverHistoryDirectories(
            runtimeMode: .selfCheck,
            isPrimaryInstance: true
        ))
    }

    func testLaunchAtLoginControllerReregistersEnabledNativeService() throws {
        var actions: [String] = []
        let controller = LaunchAtLoginController(
            status: { .enabled },
            register: { actions.append("register") },
            unregister: { actions.append("unregister") }
        )

        try controller.reconcileEnabledRegistration()

        XCTAssertEqual(actions, ["unregister", "register"])
    }

    func testLaunchAtLoginControllerRegistersWhenNativeServiceIsMissing() throws {
        var actions: [String] = []
        let controller = LaunchAtLoginController(
            status: { .notRegistered },
            register: { actions.append("register") },
            unregister: { actions.append("unregister") }
        )

        try controller.reconcileEnabledRegistration()

        XCTAssertEqual(actions, ["register"])
    }

    func testLaunchAtLoginStartupReconciliationRunsOnlyForPersistedPrimaryApplicationOptIn() throws {
        var actions: [String] = []
        var statusReads = 0
        let controller = LaunchAtLoginController(
            status: {
                statusReads += 1
                return .notRegistered
            },
            register: { actions.append("register") },
            unregister: { actions.append("unregister") }
        )

        try AppModel.reconcileLaunchAtLoginIfNeeded(
            openAtLogin: true,
            runtimeMode: .application,
            isPrimaryInstance: true,
            controller: controller
        )

        XCTAssertEqual(statusReads, 1)
        XCTAssertEqual(actions, ["register"])
    }

    func testLaunchAtLoginStartupReconciliationDoesNotInspectExcludedModes() throws {
        let excludedContexts: [(AppModel.RuntimeMode, Bool, Bool)] = [
            (.application, false, true),
            (.application, true, false),
            (.uiTesting, true, true),
            (.unitTestHost, true, true),
            (.selfCheck, true, true),
        ]

        for (runtimeMode, isPrimaryInstance, openAtLogin) in excludedContexts {
            var actions: [String] = []
            var statusReads = 0
            let controller = LaunchAtLoginController(
                status: {
                    statusReads += 1
                    return .enabled
                },
                register: { actions.append("register") },
                unregister: { actions.append("unregister") }
            )

            try AppModel.reconcileLaunchAtLoginIfNeeded(
                openAtLogin: openAtLogin,
                runtimeMode: runtimeMode,
                isPrimaryInstance: isPrimaryInstance,
                controller: controller
            )

            XCTAssertEqual(statusReads, 0, "Unexpected service read for \(runtimeMode)")
            XCTAssertTrue(actions.isEmpty, "Unexpected service write for \(runtimeMode)")
        }
    }

    func testExcludedStartupModesDoNotTouchLoginServiceOrRewritePersistedConfig() async throws {
        let scenarios: [(name: String, environment: [String: String], primary: Bool?)] = [
            (
                "ui",
                ["CCBUD_UI_TESTING": "1"],
                true
            ),
            (
                "unit",
                ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
                true
            ),
            (
                "selfcheck",
                ["CCBUD_SELFCHECK": "1"],
                true
            ),
            (
                "secondary",
                [:],
                false
            ),
        ]

        for scenario in scenarios {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ccbud-login-startup-\(scenario.name)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
            var persisted = AppConfig.fixture
            persisted.gatewayEnabled = false
            persisted.openAtLogin = true
            persisted.autoUpdate.check = false
            persisted.autoUpdate.autoDownload = false
            try repository.save(persisted)
            let before = try Data(contentsOf: repository.configURL)
            var serviceReads = 0
            var serviceWrites = 0
            let controller = LaunchAtLoginController(
                status: {
                    serviceReads += 1
                    return .enabled
                },
                register: { serviceWrites += 1 },
                unregister: { serviceWrites += 1 }
            )

            let model = AppModel(
                repository: repository,
                supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
                launchAtLoginController: controller,
                environment: scenario.environment,
                isPrimaryInstance: scenario.primary
            )

            XCTAssertEqual(serviceReads, 0, scenario.name)
            XCTAssertEqual(serviceWrites, 0, scenario.name)
            XCTAssertEqual(try Data(contentsOf: repository.configURL), before, scenario.name)
            await model.shutdown()
        }
    }

    func testDiscoveredHistoryIsPersistedBeforeStoresReceiveInitialConfiguration() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-app-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let home = container.appendingPathComponent("home", isDirectory: true)
        let codex = container.appendingPathComponent("external-codex", isDirectory: true)
        let session = codex.appendingPathComponent(
            "sessions/2026/08/22/rollout-discovered.jsonl"
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00Z",
                type: "session_meta",
                payload: #"{"id":"discovered","cwd":"/discovered/project"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:01Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"startup discovery"}]}"#
            ),
        ], to: session)

        let repository = ConfigRepository(configURL: container.appendingPathComponent("config.json"))
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        initial.historyDirs = ["~/.claude"]
        initial.historyActive = "__codex__"
        try repository.save(initial)
        let environment = [
            "HOME": home.path,
            "CODEX_HOME": codex.path,
            "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
        ]
        let discovery = HistoryDirectoryDiscovery(
            environment: environment,
            homeDirectory: home
        )

        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": container.path]),
            environment: environment,
            historyDirectoryDiscovery: discovery
        )

        XCTAssertEqual(model.config.historyDirs, ["~/.claude", codex.path])
        XCTAssertEqual(model.config.historyActive, "all")
        XCTAssertEqual(model.config.additionalProperties["codexDirAutoAdded"], .bool(true))
        let persisted = try repository.load()
        XCTAssertEqual(persisted.historyDirs, ["~/.claude", codex.path])
        XCTAssertEqual(persisted.historyActive, "all")
        XCTAssertTrue(model.usageHistoryConfiguration.activeRoots.contains {
            $0.standardizedFileURL.path == codex.standardizedFileURL.path
        })

        XCTAssertEqual(
            model.conversationStore.configuredHistoryDirectories,
            ["~/.claude", codex.path]
        )
        XCTAssertEqual(model.conversationStore.historyActive, "all")
    }

    func testLegacyConcreteHistoryScopeStartsUnifiedLibraryAndShowsOtherRoots() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-app-legacy-history-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let first = container.appendingPathComponent("first", isDirectory: true)
        let second = container.appendingPathComponent("second", isDirectory: true)
        let session = second.appendingPathComponent("projects/fixture/from-second.jsonl")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try HistoryTestSupport.write([
            #"{"type":"user","uuid":"legacy-scope-user","timestamp":"2026-08-22T00:00:00.000Z","sessionId":"legacy-scope-session","cwd":"/workspace/second","message":{"role":"user","content":"visible from the unified library"}}"#,
        ], to: session)

        let repository = ConfigRepository(configURL: container.appendingPathComponent("config.json"))
        var legacy = AppConfig.fixture
        legacy.gatewayEnabled = false
        legacy.autoUpdate.check = false
        legacy.autoUpdate.autoDownload = false
        legacy.historyDirs = [first.path, second.path]
        legacy.historyActive = first.path
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        // Bypass ConfigRepository.save so the fixture really represents an older on-disk config.
        try JSONEncoder().encode(legacy).write(to: repository.configURL)

        let loaded = try repository.load()
        XCTAssertEqual(loaded.historyActive, "all")

        let provider = HistoryRepository(
            historyDirs: loaded.historyDirs,
            active: loaded.historyActive,
            homeDirectory: container,
            importsRoot: container.appendingPathComponent("imports", isDirectory: true)
        )
        let store = ConversationStore(
            repository: provider,
            historyActive: loaded.historyActive,
            homeDirectory: container,
            pollIntervalNanoseconds: 60_000_000_000,
            searchDelayNanoseconds: 0
        )
        store.activate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !store.projects.lazy.flatMap(\.sessions).contains(where: {
                  $0.sessionID == "legacy-scope-session"
              }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.projects.lazy.flatMap(\.sessions).contains {
            $0.sessionID == "legacy-scope-session"
        })
        store.deactivate()
    }

    func testUsageHistorySurfacesIgnoreConversationScopeAndAggregateAllConfiguredRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-usage-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        var config = AppConfig.fixture
        config.historyDirs = [first.path, second.path]
        config.historyActive = first.path
        try repository.save(config)

        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        )

        XCTAssertEqual(model.config.historyActive, "all")
        XCTAssertEqual(model.usageHistoryConfiguration.active, "all")
        let roots = Set(model.usageHistoryConfiguration.activeRoots.map(\.path))
        XCTAssertTrue(roots.contains(first.resolvingSymlinksInPath().standardizedFileURL.path))
        XCTAssertTrue(roots.contains(second.resolvingSymlinksInPath().standardizedFileURL.path))
    }

    func testHostedUnitTestsDoNotAutomaticallyStartGateway() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-app-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let supervisor = GatewaySupervisor(environment: ["CCBUD_HOME": root.path])
        let model = AppModel(
            repository: ConfigRepository(configURL: root.appendingPathComponent("config.json")),
            supervisor: supervisor,
            environment: [
                "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"
            ]
        )

        // If automatic startup is accidentally restored, the empty configuration fails fast.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.gatewayState, .stopped)
        let supervisorState = await supervisor.state
        XCTAssertEqual(supervisorState, .stopped)
    }

    func testExistingGatewayTokenIsPreservedBeforeStartup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-token-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        var legacy = AppConfig.fixture
        legacy.requireToken = true
        legacy.gatewayToken = "ccbud_legacy-token"
        try repository.save(legacy)

        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        )

        XCTAssertEqual(model.config.gatewayToken, "ccbud_legacy-token")
        XCTAssertEqual(try repository.load().gatewayToken, "ccbud_legacy-token")
        XCTAssertEqual(model.gatewayState, .stopped)
    }

    func testProviderEditIsNotPublishedOrRestartedWhenPersistenceFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-provider-save-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)
        let repository = ConfigRepository(configURL: blockedParent.appendingPathComponent("config.json"))
        let supervisor = GatewaySupervisor(environment: ["CCBUD_HOME": root.path])
        let model = AppModel(
            repository: repository,
            supervisor: supervisor,
            environment: ["CCBUD_UI_TESTING": "1"]
        )
        let original = model.config
        var edited = try XCTUnwrap(original.providers.first)
        edited.name = "Must not be published"

        await model.upsertProvider(edited)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.config, original)
        XCTAssertNotNil(model.lastError)
        let supervisorState = await supervisor.state
        XCTAssertEqual(supervisorState, .stopped)
        await model.shutdown()
    }

    func testTokenRefreshRollsBackPublishedConfigAndBothManagedCLIsOnWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-token-transaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeURL = root.appendingPathComponent("claude/settings.json")
        let codexURL = root.appendingPathComponent("codex/config.toml")
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"env":{"KEEP":"yes"}}"#.utf8).write(to: claudeURL)
        try Data("model = \"gpt-5\"\n".utf8).write(to: codexURL)
        let repository = ConfigRepository(configURL: root.appendingPathComponent("ccbud/config.json"))
        let environment = [
            "HOME": root.path,
            "CCBUD_CLAUDE_SETTINGS": claudeURL.path,
            "CCBUD_CODEX_CONFIG": codexURL.path,
            "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
        ]
        let setupManager = CLIConnectionManager(repository: repository, environment: environment)
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        let connected = try setupManager.updateConnections(
            config: initial,
            claude: .connect,
            codex: .connect
        )
        let configBefore = try Data(contentsOf: repository.configURL)
        let claudeBefore = try Data(contentsOf: claudeURL)
        let codexBefore = try Data(contentsOf: codexURL)
        var injected = false
        let faultingManager = CLIConnectionManager(
            repository: repository,
            environment: environment,
            fileWriter: { data, url, fileManager in
                if url.standardizedFileURL == codexURL.standardizedFileURL, !injected {
                    injected = true
                    throw CocoaError(.fileWriteUnknown)
                }
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            }
        )
        let model = AppModel(
            repository: repository,
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            connectionManager: faultingManager,
            environment: environment
        )

        await model.setRequireToken(true)

        XCTAssertTrue(injected)
        XCTAssertEqual(model.config, connected)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), configBefore)
        XCTAssertEqual(try Data(contentsOf: claudeURL), claudeBefore)
        XCTAssertEqual(try Data(contentsOf: codexURL), codexBefore)
        await model.shutdown()
    }

    func testDirectCLIRollbackFailureLatchesUntilExplicitSuccessfulRecheck() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-direct-cli-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigRepository(configURL: root.appendingPathComponent("ccbud/config.json"))
        let claudeURL = root.appendingPathComponent("claude/settings.json")
        let environment = [
            "HOME": root.path,
            "CCBUD_HOME": root.appendingPathComponent("home", isDirectory: true).path,
            "CCBUD_CLAUDE_SETTINGS": claudeURL.path,
            "CCBUD_CODEX_CONFIG": root.appendingPathComponent("codex/config.toml").path,
            "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
        ]
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        try repository.save(initial)
        var writesByPath: [String: Int] = [:]
        let connectionManager = CLIConnectionManager(
            repository: repository,
            environment: environment,
            fileWriter: { data, url, fileManager in
                let path = url.standardizedFileURL.path
                writesByPath[path, default: 0] += 1
                if path == claudeURL.standardizedFileURL.path {
                    throw CocoaError(.fileWriteUnknown)
                }
                if path == repository.configURL.standardizedFileURL.path,
                   writesByPath[path] == 2 {
                    throw CocoaError(.fileWriteUnknown)
                }
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            }
        )
        let supervisor = GatewaySupervisor(environment: environment)
        let model = AppModel(
            repository: repository,
            supervisor: supervisor,
            connectionManager: connectionManager,
            environment: environment
        )

        await model.setConnectTarget(CLIConnectionManager.claudeTarget, enabled: true)

        XCTAssertTrue(model.cliRecoveryRequired)
        guard case .failed(let message) = model.gatewayState else {
            return XCTFail("Expected the direct CLI transaction to enter manual recovery")
        }
        XCTAssertEqual(message, "CLI 配置恢复不完整，需要手动恢复")
        let pending = try connectionManager.pendingRecoveryJournalDirectories()
        XCTAssertEqual(pending.count, 1)
        let latchedError = try XCTUnwrap(model.lastError)
        XCTAssertTrue(latchedError.contains(pending[0].lastPathComponent))
        let latchedSupervisorState = await supervisor.state
        XCTAssertEqual(latchedSupervisorState, .stopped)

        let persistedBeforeBlockedMutation = try Data(contentsOf: repository.configURL)
        await model.setLanguage("ja")
        XCTAssertEqual(try Data(contentsOf: repository.configURL), persistedBeforeBlockedMutation)
        XCTAssertEqual(model.lastError, latchedError)
        XCTAssertEqual(try connectionManager.pendingRecoveryJournalDirectories(), pending)

        var recovered = initial
        recovered.language = "ja"
        recovered.gatewayEnabled = true
        recovered.normalize()
        try repository.save(recovered)
        try FileManager.default.removeItem(at: pending[0])

        await model.recheckCLIRecovery()

        XCTAssertFalse(model.cliRecoveryRequired)
        XCTAssertEqual(model.config, recovered)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.gatewayState, .stopped)
        let recheckedSupervisorState = await supervisor.state
        XCTAssertEqual(recheckedSupervisorState, .stopped)
        XCTAssertFalse(model.monitorStore.gatewayRunning)
        await model.shutdown()
    }

    func testPendingRecoveryOnRelaunchSkipsReconnectPluginsAndGatewayStartup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-relaunch-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent(
            ".codex/sessions/2026/08/22/rollout-pending-relaunch.jsonl"
        )
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00Z",
                type: "session_meta",
                payload: #"{"id":"pending-relaunch","cwd":"/pending/project"}"#
            ),
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:01Z",
                type: "response_item",
                payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"pending recovery history"}]}"#
            ),
        ], to: session, modifiedAt: Date())
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repository = ConfigRepository(configURL: home.appendingPathComponent("config.json"))
        let executable = root.appendingPathComponent("must-not-start")
        let marker = home.appendingPathComponent("gateway/start-marker")
        let script = """
        #!/bin/sh
        app_dir=$(/usr/bin/dirname "$2")
        : > "$app_dir/start-marker"
        exit 91
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let environment = [
            "HOME": root.path,
            "CCBUD_HOME": home.path,
            "CCBUD_GATEWAY_BINARY": executable.path,
            "CCBUD_CLAUDE_SETTINGS": root.appendingPathComponent("claude/settings.json").path,
            "CCBUD_CODEX_CONFIG": root.appendingPathComponent("codex/config.toml").path,
        ]
        let setupManager = CLIConnectionManager(repository: repository, environment: environment)
        var initial = AppConfig.fixture
        initial.gatewayEnabled = true
        initial.autoUpdate.check = false
        initial.autoUpdate.autoDownload = false
        initial = try setupManager.updateConnections(
            config: initial,
            claude: .connect,
            codex: .connect
        )
        let historyDiscovery = HistoryDirectoryDiscovery(
            environment: environment,
            homeDirectory: root
        )
        let discoveryWithoutRecoveryLatch = historyDiscovery.discover(in: initial)
        XCTAssertTrue(discoveryWithoutRecoveryLatch.didChange)
        XCTAssertEqual(
            discoveryWithoutRecoveryLatch.config.additionalProperties["codexDirAutoAdded"],
            .bool(true)
        )
        XCTAssertTrue(discoveryWithoutRecoveryLatch.config.historyDirs.contains("~/.codex"))
        let transaction = setupManager.recoveryRootURL
            .appendingPathComponent("pending-relaunch", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: transaction.appendingPathComponent(CLIConnectionManager.recoveryJournalFileName)
        )
        let persistedBeforeLaunch = try Data(contentsOf: repository.configURL)
        var reconnectWrites = 0
        let observingManager = CLIConnectionManager(
            repository: repository,
            environment: environment,
            fileWriter: { data, url, fileManager in
                reconnectWrites += 1
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            }
        )
        let pluginManager = AppModelTestPluginManager(items: [])
        let supervisor = GatewaySupervisor(environment: environment)

        let model = AppModel(
            repository: repository,
            supervisor: supervisor,
            connectionManager: observingManager,
            environment: environment,
            pluginManager: pluginManager,
            historyDirectoryDiscovery: historyDiscovery,
            isPrimaryInstance: true,
            automaticUpdatesEnabled: false
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(model.cliRecoveryRequired)
        XCTAssertEqual(model.cliRecoveryState?.journalDirectories, [transaction.standardizedFileURL])
        XCTAssertEqual(model.config, initial)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), persistedBeforeLaunch)
        XCTAssertNotEqual(model.config.additionalProperties["codexDirAutoAdded"], .bool(true))
        XCTAssertEqual(reconnectWrites, 0)
        let catalogCallCount = await pluginManager.catalogCallCount()
        XCTAssertEqual(catalogCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let supervisorState = await supervisor.state
        XCTAssertEqual(supervisorState, .stopped)
        XCTAssertTrue(model.lastError?.contains(transaction.path) == true)
        await model.shutdown()
    }

    func testLatestCredentialIntentRestartsGatewayWhenItSupersedesAStoppedReconfiguration() async throws {
        let fixture = try makeRunningGatewayFixture(named: "credential-supersession")
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()
        XCTAssertEqual(fixture.model.gatewayState, .running(port: fixture.initial.port))

        let enable = Task { await fixture.model.setRequireToken(true) }
        let observedCredentialStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedCredentialStop)
        let disable = Task { await fixture.model.setRequireToken(false) }
        try await Task.sleep(nanoseconds: 10_000_000)
        try Data().write(to: fixture.releaseStopFile)
        await enable.value
        await disable.value

        XCTAssertFalse(fixture.model.config.requireToken)
        XCTAssertFalse(try fixture.repository.load().requireToken)
        XCTAssertEqual(fixture.model.gatewayState, .running(port: fixture.initial.port))
        let credentialSupervisorState = await fixture.supervisor.state
        XCTAssertEqual(credentialSupervisorState, .running(port: fixture.initial.port))
        await fixture.model.shutdown()
    }

    func testGatewayDisableSupersedesCredentialRestartAndPersistsStoppedIntent() async throws {
        let fixture = try makeRunningGatewayFixture(named: "disable-supersession")
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()

        let tokenUpdate = Task { await fixture.model.setGatewayToken("disable-race-token") }
        let observedDisableStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedDisableStop)
        let disable = Task { await fixture.model.setGatewayEnabled(false) }
        try await Task.sleep(nanoseconds: 10_000_000)
        try Data().write(to: fixture.releaseStopFile)
        await tokenUpdate.value
        await disable.value

        XCTAssertEqual(fixture.model.config.gatewayToken, "disable-race-token")
        XCTAssertFalse(fixture.model.config.gatewayEnabled)
        let persisted = try fixture.repository.load()
        XCTAssertEqual(persisted.gatewayToken, "disable-race-token")
        XCTAssertFalse(persisted.gatewayEnabled)
        XCTAssertEqual(fixture.model.gatewayState, .stopped)
        let disabledSupervisorState = await fixture.supervisor.state
        XCTAssertEqual(disabledSupervisorState, .stopped)
        await fixture.model.shutdown()
    }

    func testQueuedInvalidProviderEditDoesNotDropCredentialOrStrandStoppedGateway() async throws {
        let fixture = try makeRunningGatewayFixture(named: "invalid-provider-supersession")
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()

        let tokenUpdate = Task { await fixture.model.setGatewayToken("preserved-token") }
        let observedStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedStop)
        var invalidProvider = try XCTUnwrap(fixture.model.config.activeProvider)
        invalidProvider.baseUrl = ""
        let invalidEdit = Task { await fixture.model.upsertProvider(invalidProvider) }
        try Data().write(to: fixture.releaseStopFile)
        await tokenUpdate.value
        await invalidEdit.value

        XCTAssertEqual(fixture.model.config.gatewayToken, "preserved-token")
        XCTAssertEqual(fixture.model.config.activeProvider?.baseUrl, fixture.initial.activeProvider?.baseUrl)
        XCTAssertEqual(try fixture.repository.load(), fixture.model.config)
        XCTAssertEqual(fixture.model.gatewayState, .running(port: fixture.initial.port))
        let supervisorState = await fixture.supervisor.state
        XCTAssertEqual(supervisorState, .running(port: fixture.initial.port))
        XCTAssertNotNil(fixture.model.lastError)
        await fixture.model.shutdown()
    }

    func testPluginReconciliationMergesWithProviderEditCommittedAheadOfIt() async throws {
        let plugin = PluginCatalogItem(
            id: "alpha",
            name: "Alpha",
            version: "1.0.0",
            protocolName: "openai-responses",
            provider: .init(
                id: "plugin:alpha",
                pluginID: "alpha",
                name: "Alpha",
                baseURL: URL(string: "http://127.0.0.1:31111/v1")!,
                protocolName: "openai-responses",
                defaultModel: "primary",
                smallFastModel: "light"
            )
        )
        let pluginManager = AppModelTestPluginManager(items: [plugin])
        let fixture = try makeRunningGatewayFixture(
            named: "plugin-provider-merge",
            pluginManager: pluginManager
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()

        var edited = try XCTUnwrap(fixture.model.config.activeProvider)
        edited.name = "Concurrent user edit"
        let providerEdit = Task { await fixture.model.upsertProvider(edited) }
        let observedStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedStop)
        let pluginRefresh = Task { await fixture.model.refreshPlugins() }
        let catalogDeadline = Date().addingTimeInterval(2)
        while Date() < catalogDeadline, await pluginManager.catalogCallCount() == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let catalogCallCount = await pluginManager.catalogCallCount()
        XCTAssertEqual(catalogCallCount, 1)
        // The provider edit deliberately retains the gate while its old sidecar waits for TERM.
        // Give the catalog continuation a turn to queue reconciliation behind that edit.
        for _ in 0..<4 { await Task.yield() }
        try Data().write(to: fixture.releaseStopFile)
        await providerEdit.value
        await pluginRefresh.value

        XCTAssertEqual(
            fixture.model.config.providers.first(where: { $0.id == edited.id })?.name,
            "Concurrent user edit"
        )
        XCTAssertTrue(fixture.model.config.providers.contains { $0.id == "plugin:alpha" })
        XCTAssertEqual(try fixture.repository.load(), fixture.model.config)
        XCTAssertTrue(fixture.model.gatewayState.isRunning)
        await fixture.model.shutdown()
    }

    func testAcceptedOlderCatalogCannotReconcileAfterNewerRefreshPublishes() async throws {
        let older = PluginCatalogItem(
            id: "older",
            name: "Older",
            version: "1.0.0",
            protocolName: "openai-responses",
            provider: .init(
                id: "plugin:older",
                pluginID: "older",
                name: "Older",
                baseURL: URL(string: "http://127.0.0.1:31120/v1")!,
                protocolName: "openai-responses",
                defaultModel: "primary",
                smallFastModel: "light"
            )
        )
        let newer = PluginCatalogItem(
            id: "newer",
            name: "Newer",
            version: "1.0.0",
            protocolName: "openai-responses",
            provider: .init(
                id: "plugin:newer",
                pluginID: "newer",
                name: "Newer",
                baseURL: URL(string: "http://127.0.0.1:31121/v1")!,
                protocolName: "openai-responses",
                defaultModel: "primary",
                smallFastModel: "light"
            )
        )
        let pluginManager = AppModelControlledPluginManager()
        let fixture = try makeRunningGatewayFixture(
            named: "stale-plugin-reconcile",
            pluginManager: pluginManager
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()

        var edited = try XCTUnwrap(fixture.model.config.activeProvider)
        edited.name = "Gate-owning provider edit"
        let providerEdit = Task { await fixture.model.upsertProvider(edited) }
        let observedStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedStop)

        let olderRefresh = Task { await fixture.model.refreshPlugins() }
        let observedOlderCall = await waitForCatalogCalls(
            1,
            manager: pluginManager
        )
        XCTAssertTrue(observedOlderCall)
        await pluginManager.completeCatalog(
            call: 0,
            snapshot: .init(items: [older], issues: [])
        )
        let olderPublishDeadline = Date().addingTimeInterval(2)
        while Date() < olderPublishDeadline, fixture.model.plugins.first?.id != "older" {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(fixture.model.plugins.first?.id, "older")

        let newerRefresh = Task {
            await fixture.model.refreshPlugins(reconcileProviders: false)
        }
        let observedNewerCall = await waitForCatalogCalls(
            2,
            manager: pluginManager
        )
        XCTAssertTrue(observedNewerCall)
        await pluginManager.completeCatalog(
            call: 1,
            snapshot: .init(items: [newer], issues: [])
        )
        await newerRefresh.value
        XCTAssertEqual(fixture.model.plugins.first?.id, "newer")

        try Data().write(to: fixture.releaseStopFile)
        await providerEdit.value
        await olderRefresh.value

        XCTAssertEqual(
            fixture.model.config.providers.first(where: { $0.id == edited.id })?.name,
            edited.name
        )
        XCTAssertFalse(fixture.model.config.providers.contains { $0.backend == .plugin })
        XCTAssertEqual(try fixture.repository.load(), fixture.model.config)
        XCTAssertTrue(fixture.model.gatewayState.isRunning)
        await fixture.model.shutdown()
    }

    func testCatalogSupersededDuringGatewayStopRestoresHealthyRuntimeWithoutCommitting() async throws {
        let older = PluginCatalogItem(
            id: "older",
            name: "Older",
            version: "1.0.0",
            protocolName: "openai-responses",
            provider: .init(
                id: "plugin:older",
                pluginID: "older",
                name: "Older",
                baseURL: URL(string: "http://127.0.0.1:31122/v1")!,
                protocolName: "openai-responses",
                defaultModel: "primary",
                smallFastModel: "light"
            )
        )
        let pluginManager = AppModelControlledPluginManager()
        let fixture = try makeRunningGatewayFixture(
            named: "plugin-superseded-during-stop",
            pluginManager: pluginManager
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()
        let configBeforeRefresh = fixture.model.config

        let olderRefresh = Task { await fixture.model.refreshPlugins() }
        let observedOlderCall = await waitForCatalogCalls(1, manager: pluginManager)
        XCTAssertTrue(observedOlderCall)
        await pluginManager.completeCatalog(
            call: 0,
            snapshot: .init(items: [older], issues: [])
        )
        let olderPublishDeadline = Date().addingTimeInterval(2)
        while Date() < olderPublishDeadline, fixture.model.plugins.first?.id != older.id {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(fixture.model.plugins.first?.id, older.id)
        let observedStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedStop)

        let newerRefresh = Task {
            await fixture.model.refreshPlugins(reconcileProviders: false)
        }
        let observedNewerCall = await waitForCatalogCalls(2, manager: pluginManager)
        XCTAssertTrue(observedNewerCall)
        await pluginManager.completeCatalog(
            call: 1,
            snapshot: .init(items: [], issues: [])
        )
        await newerRefresh.value
        XCTAssertTrue(fixture.model.plugins.isEmpty)

        try Data().write(to: fixture.releaseStopFile)
        await olderRefresh.value

        XCTAssertEqual(fixture.model.config, configBeforeRefresh)
        XCTAssertEqual(try fixture.repository.load(), configBeforeRefresh)
        XCTAssertFalse(fixture.model.config.providers.contains { $0.backend == .plugin })
        XCTAssertTrue(fixture.model.gatewayState.isRunning)
        let supervisorState = await fixture.supervisor.state
        XCTAssertTrue(supervisorState.isRunning)
        XCTAssertNil(fixture.model.lastError)
        await fixture.model.shutdown()
    }

    func testQueuedProviderAndPluginReconciliationCannotEscapeCredentialRecoveryLatch() async throws {
        let plugin = PluginCatalogItem(
            id: "recovery-plugin",
            name: "Recovery plugin",
            version: "1.0.0",
            protocolName: "openai-responses",
            provider: .init(
                id: "plugin:recovery-plugin",
                pluginID: "recovery-plugin",
                name: "Recovery plugin",
                baseURL: URL(string: "http://127.0.0.1:31119/v1")!,
                protocolName: "openai-responses",
                defaultModel: "primary",
                smallFastModel: "light"
            )
        )
        let pluginManager = AppModelTestPluginManager(items: [plugin])
        var writesByPath: [String: Int] = [:]
        let fixture = try makeRunningGatewayFixture(
            named: "queued-recovery-latch",
            connectCLIs: true,
            fileWriter: { data, url, fileManager in
                let path = url.standardizedFileURL.path
                writesByPath[path, default: 0] += 1
                if url.lastPathComponent == "config.toml" {
                    throw CocoaError(.fileWriteUnknown)
                }
                if url.lastPathComponent == "config.json", writesByPath[path] == 2 {
                    throw CocoaError(.fileWriteUnknown)
                }
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            },
            pluginManager: pluginManager
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()

        let credentialUpdate = Task { await fixture.model.setRequireToken(true) }
        let observedStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedStop)
        var edited = try XCTUnwrap(fixture.model.config.activeProvider)
        edited.name = "Queued edit must remain blocked"
        let providerEdit = Task { await fixture.model.upsertProvider(edited) }
        let pluginRefresh = Task { await fixture.model.refreshPlugins() }
        let catalogDeadline = Date().addingTimeInterval(2)
        while Date() < catalogDeadline, await pluginManager.catalogCallCount() == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let catalogCallCount = await pluginManager.catalogCallCount()
        XCTAssertEqual(catalogCallCount, 1)
        for _ in 0..<4 { await Task.yield() }

        try Data().write(to: fixture.releaseStopFile)
        await credentialUpdate.value
        await providerEdit.value
        await pluginRefresh.value

        XCTAssertTrue(fixture.model.cliRecoveryRequired)
        XCTAssertNotEqual(
            fixture.model.config.providers.first(where: { $0.id == edited.id })?.name,
            edited.name
        )
        XCTAssertFalse(fixture.model.config.providers.contains {
            $0.id == "plugin:recovery-plugin"
        })
        XCTAssertEqual(try fixture.repository.load(), fixture.model.config)
        let connectionManager = CLIConnectionManager(
            repository: fixture.repository,
            environment: [
                "HOME": fixture.root.path,
                "CCBUD_CLAUDE_SETTINGS": fixture.root
                    .appendingPathComponent("claude/settings.json").path,
                "CCBUD_CODEX_CONFIG": fixture.root
                    .appendingPathComponent("codex/config.toml").path,
            ]
        )
        let pending = try connectionManager.pendingRecoveryJournalDirectories()
        XCTAssertEqual(pending.count, 1)
        let latchedError = try XCTUnwrap(fixture.model.lastError)
        XCTAssertTrue(latchedError.contains(pending[0].lastPathComponent))

        // The supervisor's stopped event is delivered asynchronously after the recovery latch.
        // It must not replace either the manual-recovery state or its complete actionable detail.
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .failed(let failureMessage) = fixture.model.gatewayState else {
            return XCTFail("Expected manual recovery to remain authoritative")
        }
        XCTAssertEqual(failureMessage, "CLI 配置恢复不完整，需要手动恢复")
        XCTAssertEqual(fixture.model.lastError, latchedError)
        XCTAssertEqual(try connectionManager.pendingRecoveryJournalDirectories(), pending)
        XCTAssertFalse(fixture.model.monitorStore.gatewayRunning)
        let supervisorState = await fixture.supervisor.state
        XCTAssertEqual(supervisorState, .stopped)
        await fixture.model.shutdown()
    }

    func testCredentialTransactionSerializesLaterCLIDisconnectWithoutReconnectingIt() async throws {
        let fixture = try makeRunningGatewayFixture(named: "credential-disconnect", connectCLIs: true)
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()

        let tokenUpdate = Task { await fixture.model.setGatewayToken("serialized-token") }
        let observedDisconnectStop = await waitForFile(fixture.stopObservedFile)
        XCTAssertTrue(observedDisconnectStop)
        let disconnect = Task {
            await fixture.model.setConnectTarget(CLIConnectionManager.claudeTarget, enabled: false)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        try Data().write(to: fixture.releaseStopFile)
        await tokenUpdate.value
        await disconnect.value

        let persisted = try fixture.repository.load()
        XCTAssertEqual(persisted.gatewayToken, "serialized-token")
        XCTAssertFalse(persisted.connectTargets.contains(CLIConnectionManager.claudeTarget))
        XCTAssertTrue(persisted.connectTargets.contains(CLIConnectionManager.codexTarget))
        XCTAssertTrue(persisted.claudeBackup.isNull)
        XCTAssertTrue(fixture.model.gatewayState.isRunning)
        XCTAssertFalse(fixture.model.claudeConnected)
        XCTAssertTrue(fixture.model.codexConnected)
        await fixture.model.shutdown()
    }

    func testProviderRestartFailureRestoresPreviousConfigAndHealthyGateway() async throws {
        let fixture = try makeRunningGatewayFixture(named: "provider-rollback")
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()
        try Data().write(to: fixture.releaseStopFile)
        AppModelGatewayURLProtocol.failNextRequests(300)
        var edited = try XCTUnwrap(fixture.model.config.activeProvider)
        edited.name = "Replacement that fails health"

        await fixture.model.upsertProvider(edited)

        XCTAssertEqual(fixture.model.config, fixture.initial)
        XCTAssertEqual(try fixture.repository.load(), fixture.initial)
        XCTAssertEqual(fixture.model.gatewayState, .running(port: fixture.initial.port))
        let restoredSupervisorState = await fixture.supervisor.state
        XCTAssertEqual(restoredSupervisorState, .running(port: fixture.initial.port))
        XCTAssertNotNil(fixture.model.lastError)
        await fixture.model.shutdown()
    }

    func testCredentialRestartFailureRestoresConfigManagedCLIsAndHealthyGateway() async throws {
        let fixture = try makeRunningGatewayFixture(
            named: "credential-health-rollback",
            connectCLIs: true
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let claudeURL = fixture.root.appendingPathComponent("claude/settings.json")
        let codexURL = fixture.root.appendingPathComponent("codex/config.toml")
        let claudeBefore = try Data(contentsOf: claudeURL)
        let codexBefore = try Data(contentsOf: codexURL)
        await fixture.model.startGateway()
        try Data().write(to: fixture.releaseStopFile)
        AppModelGatewayURLProtocol.failNextRequests(300)

        await fixture.model.setRequireToken(true)

        XCTAssertEqual(fixture.model.config, fixture.initial)
        XCTAssertEqual(try fixture.repository.load(), fixture.initial)
        XCTAssertEqual(try Data(contentsOf: claudeURL), claudeBefore)
        XCTAssertEqual(try Data(contentsOf: codexURL), codexBefore)
        XCTAssertEqual(fixture.model.gatewayState, .running(port: fixture.initial.port))
        let supervisorState = await fixture.supervisor.state
        XCTAssertEqual(supervisorState, .running(port: fixture.initial.port))
        XCTAssertTrue(fixture.model.claudeConnected)
        XCTAssertTrue(fixture.model.codexConnected)
        XCTAssertNotNil(fixture.model.lastError)
        await fixture.model.shutdown()
    }

    func testCredentialRestartRestorationRollbackFailureSurfacesRecoveryJournal() async throws {
        var writesByPath: [String: Int] = [:]
        var injectedRestorationWriteFailure = false
        var injectedRestorationRollbackFailure = false
        let fixture = try makeRunningGatewayFixture(
            named: "credential-restoration-indeterminate",
            connectCLIs: true,
            fileWriter: { data, url, fileManager in
                let path = url.standardizedFileURL.path
                writesByPath[path, default: 0] += 1
                let count = writesByPath[path] ?? 0
                if url.lastPathComponent == "config.toml", count == 2 {
                    injectedRestorationWriteFailure = true
                    throw CocoaError(.fileWriteUnknown)
                }
                if url.lastPathComponent == "config.json", count == 3 {
                    injectedRestorationRollbackFailure = true
                    throw CocoaError(.fileWriteUnknown)
                }
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            }
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()
        try Data().write(to: fixture.releaseStopFile)
        AppModelGatewayURLProtocol.failNextRequests(300)

        await fixture.model.setRequireToken(true)

        XCTAssertTrue(injectedRestorationWriteFailure)
        XCTAssertTrue(injectedRestorationRollbackFailure)
        let persisted = try fixture.repository.load()
        XCTAssertEqual(fixture.model.config, persisted)
        guard case .failed(let message) = fixture.model.gatewayState else {
            return XCTFail("Expected restoration rollback to be indeterminate")
        }
        XCTAssertEqual(message, "CLI 配置恢复不完整，需要手动恢复")
        XCTAssertFalse(fixture.model.monitorStore.gatewayRunning)
        let recoveryRoot = fixture.repository.configURL.deletingLastPathComponent()
            .appendingPathComponent(CLIConnectionManager.recoveryDirectoryName, isDirectory: true)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryDirectories.count, 1)
        XCTAssertTrue(
            fixture.model.lastError?.contains(recoveryDirectories[0].lastPathComponent) == true
        )
        XCTAssertTrue(fixture.model.lastError?.contains("恢复先前状态失败") == true)
        await fixture.model.shutdown()
    }

    func testIndeterminateCredentialRollbackReloadsDiskAndKeepsGatewayFailed() async throws {
        var writesByPath: [String: Int] = [:]
        let fixture = try makeRunningGatewayFixture(
            named: "credential-indeterminate-rollback",
            connectCLIs: true,
            fileWriter: { data, url, fileManager in
                let path = url.standardizedFileURL.path
                writesByPath[path, default: 0] += 1
                if url.lastPathComponent == "config.toml" {
                    throw CocoaError(.fileWriteUnknown)
                }
                if url.lastPathComponent == "config.json", writesByPath[path] == 2 {
                    throw CocoaError(.fileWriteUnknown)
                }
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            }
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()
        try Data().write(to: fixture.releaseStopFile)

        await fixture.model.setGatewayToken("indeterminate-token")
        try await Task.sleep(nanoseconds: 50_000_000)

        let persisted = try fixture.repository.load()
        XCTAssertEqual(persisted.gatewayToken, "indeterminate-token")
        XCTAssertEqual(fixture.model.config, persisted)
        guard case .failed(let message) = fixture.model.gatewayState else {
            return XCTFail("Expected an indeterminate gateway failure")
        }
        XCTAssertEqual(message, "CLI 配置恢复不完整，需要手动恢复")
        XCTAssertFalse(fixture.model.monitorStore.gatewayRunning)
        let supervisorState = await fixture.supervisor.state
        XCTAssertEqual(supervisorState, .stopped)
        let recoveryRoot = fixture.repository.configURL.deletingLastPathComponent()
            .appendingPathComponent(CLIConnectionManager.recoveryDirectoryName, isDirectory: true)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryDirectories.count, 1)
        XCTAssertTrue(
            fixture.model.lastError?.contains(recoveryDirectories[0].lastPathComponent) == true
        )
        await fixture.model.shutdown()
    }

    func testDeletingLastProviderPersistsDisabledConfigAndStopsGateway() async throws {
        let fixture = try makeRunningGatewayFixture(named: "last-provider")
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.startGateway()
        try Data().write(to: fixture.releaseStopFile)
        let providerID = try XCTUnwrap(fixture.model.config.activeProviderId)

        await fixture.model.deleteProvider(providerID)

        XCTAssertTrue(fixture.model.config.providers.isEmpty)
        XCTAssertFalse(fixture.model.config.gatewayEnabled)
        XCTAssertEqual(fixture.model.gatewayState, .stopped)
        let persisted = try fixture.repository.load()
        XCTAssertTrue(persisted.providers.isEmpty)
        XCTAssertFalse(persisted.gatewayEnabled)
        await fixture.model.shutdown()
    }

    func testImmediatePostHealthExitIsNotPublishedAsStartupSuccess() async throws {
        let fixture = try makeRunningGatewayFixture(
            named: "post-health-exit",
            exitImmediatelyAfterHealth: true
        )
        defer {
            fixture.session.invalidateAndCancel()
            AppModelGatewayURLProtocol.clearReadinessFile()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        await fixture.model.startGateway()

        guard case .failed(let message) = fixture.model.gatewayState else {
            let supervisorState = await fixture.supervisor.state
            let lastError = fixture.model.lastError ?? "nil"
            return XCTFail(
                "Expected immediate post-health exit to remain failed; app=\(fixture.model.gatewayState), "
                    + "supervisor=\(supervisorState), lastError=\(lastError)"
            )
        }
        XCTAssertTrue(message.contains("47"), message)
        XCTAssertEqual(fixture.model.lastError, message)
        XCTAssertFalse(fixture.model.monitorStore.gatewayRunning)
        XCTAssertFalse(fixture.model.monitorStore.lifecycleEvents.contains {
            $0.message.contains("网关已启动")
        })
        await fixture.model.shutdown()
    }

    func testAppModelPublishesSanitizedFailureAfterRunningSidecarExits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-appmodel-sidecar-exit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("exit-after-running")
        let script = """
        #!/bin/sh
        config_path="$2"
        app_dir=$(/usr/bin/dirname "$config_path")
        public_port=$(/usr/bin/grep '"publicPort"' "$config_path" | /usr/bin/tr -cd '0-9')
        management_port=65535
        if [ "$public_port" = "$management_port" ]; then management_port=65534; fi
        trap 'exit 0' TERM
        : > "$app_dir/output-ready"
        printf '{"event":"ready","publicPort":%s,"managementPort":%s}\n' "$public_port" "$management_port"
        while [ ! -f "$app_dir/exit-now" ]; do sleep 0.01; done
        printf 'private-sidecar-output-must-not-reach-ui\n' >&2
        exit 37
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appDirectory = home.appendingPathComponent("gateway", isDirectory: true)
        let readinessFile = appDirectory.appendingPathComponent("output-ready")
        AppModelGatewayURLProtocol.requireReadinessFile(readinessFile)
        defer { AppModelGatewayURLProtocol.clearReadinessFile() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppModelGatewayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let environment = [
            "CCBUD_HOME": home.path,
            "CCBUD_GATEWAY_BINARY": executable.path,
            "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
        ]
        let repository = ConfigRepository(configURL: home.appendingPathComponent("config.json"))
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        initial.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        try repository.save(initial)
        let supervisor = GatewaySupervisor(
            session: session,
            environment: environment,
            healthCheckAttempts: 300,
            healthCheckIntervalNanoseconds: 5_000_000
        )
        let model = AppModel(
            repository: repository,
            supervisor: supervisor,
            environment: environment
        )

        await model.startGateway()
        XCTAssertEqual(model.gatewayState, .running(port: initial.port))
        try Data().write(to: appDirectory.appendingPathComponent("exit-now"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if case .failed = model.gatewayState, model.lastError != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard case .failed(let message) = model.gatewayState else {
            XCTFail("Expected AppModel to publish the sidecar exit")
            await model.shutdown()
            return
        }
        XCTAssertTrue(message.contains("37"), message)
        XCTAssertFalse(message.contains("private-sidecar-output"), message)
        XCTAssertEqual(model.lastError, message)
        XCTAssertFalse(model.monitorStore.gatewayRunning)
        XCTAssertTrue(model.monitorStore.lifecycleEvents.contains {
            $0.message.contains("网关运行异常") && $0.message.contains("37")
        })
        XCTAssertFalse(model.monitorStore.lifecycleEvents.contains {
            $0.message.contains("private-sidecar-output")
        })
        await model.shutdown()
    }

    private struct RunningGatewayFixture {
        let root: URL
        let initial: AppConfig
        let repository: ConfigRepository
        let supervisor: GatewaySupervisor
        let model: AppModel
        let session: URLSession
        let stopObservedFile: URL
        let releaseStopFile: URL
    }

    private func makeRunningGatewayFixture(
        named name: String,
        connectCLIs: Bool = false,
        fileWriter: CLIConnectionManager.FileWriter? = nil,
        pluginManager: (any PluginManaging)? = nil,
        exitImmediatelyAfterHealth: Bool = false
    ) throws -> RunningGatewayFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-appmodel-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("controllable-gateway")
        let script = """
        #!/bin/sh
        config_path="$2"
        app_dir=$(/usr/bin/dirname "$config_path")
        public_port=$(/usr/bin/grep '"publicPort"' "$config_path" | /usr/bin/tr -cd '0-9')
        management_port=65535
        if [ "$public_port" = "$management_port" ]; then management_port=65534; fi
        trap 'touch "$app_dir/stop-observed"; while [ ! -f "$app_dir/release-stop" ]; do sleep 0.01; done; exit 0' TERM
        : > "$app_dir/output-ready"
        printf '{"event":"ready","publicPort":%s,"managementPort":%s}\n' "$public_port" "$management_port"
        while true; do
          if [ -f "$app_dir/exit-after-health" ]; then exit 47; fi
          sleep 0.01
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let home = root.appendingPathComponent("home", isDirectory: true)
        let appDirectory = home.appendingPathComponent("gateway", isDirectory: true)
        let readinessFile = appDirectory.appendingPathComponent("output-ready")
        let stopObservedFile = appDirectory.appendingPathComponent("stop-observed")
        let releaseStopFile = appDirectory.appendingPathComponent("release-stop")
        AppModelGatewayURLProtocol.clearReadinessFile()
        AppModelGatewayURLProtocol.requireReadinessFile(readinessFile)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppModelGatewayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let environment = [
            "HOME": root.path,
            "CCBUD_HOME": home.path,
            "CCBUD_GATEWAY_BINARY": executable.path,
            "CCBUD_CLAUDE_SETTINGS": root.appendingPathComponent("claude/settings.json").path,
            "CCBUD_CODEX_CONFIG": root.appendingPathComponent("codex/config.toml").path,
            "XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration",
        ]
        let repository = ConfigRepository(configURL: home.appendingPathComponent("config.json"))
        var initial = AppConfig.fixture
        initial.gatewayEnabled = true
        initial.port = try ClaudeCLIE2ETestSupport.availableLoopbackPort()
        let setupConnectionManager = CLIConnectionManager(
            repository: repository,
            environment: environment
        )
        if connectCLIs {
            initial = try setupConnectionManager.updateConnections(
                config: initial,
                claude: .connect,
                codex: .connect
            )
        } else {
            try repository.save(initial)
        }
        let connectionManager = fileWriter.map {
            CLIConnectionManager(
                repository: repository,
                environment: environment,
                fileWriter: $0
            )
        } ?? setupConnectionManager
        let supervisor = GatewaySupervisor(
            session: session,
            environment: environment,
            healthCheckAttempts: 300,
            healthCheckIntervalNanoseconds: 5_000_000
        )
        let exitAfterHealthFile = appDirectory.appendingPathComponent("exit-after-health")
        let startupVerificationHook: (@MainActor () async -> Void)?
        if exitImmediatelyAfterHealth {
            startupVerificationHook = {
                try? Data().write(to: exitAfterHealthFile)
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    if case .failed = await supervisor.state { return }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        } else {
            startupVerificationHook = nil
        }
        let model = AppModel(
            repository: repository,
            supervisor: supervisor,
            connectionManager: connectionManager,
            environment: environment,
            pluginManager: pluginManager,
            gatewayStartupVerificationHook: startupVerificationHook
        )
        return .init(
            root: root,
            initial: initial,
            repository: repository,
            supervisor: supervisor,
            model: model,
            session: session,
            stopObservedFile: stopObservedFile,
            releaseStopFile: releaseStopFile
        )
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func waitForCatalogCalls(
        _ expected: Int,
        manager: AppModelControlledPluginManager,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await manager.catalogCallCount() >= expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

private final class AppModelGatewayURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var readinessFile: URL?
    nonisolated(unsafe) private static var failedResponsesRemaining = 0

    static func requireReadinessFile(_ file: URL) {
        stateLock.lock()
        readinessFile = file
        stateLock.unlock()
    }

    static func clearReadinessFile() {
        stateLock.lock()
        readinessFile = nil
        failedResponsesRemaining = 0
        stateLock.unlock()
    }

    static func failNextRequests(_ count: Int) {
        stateLock.lock()
        failedResponsesRemaining = max(0, count)
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.stateLock.lock()
        let readinessFile = Self.readinessFile
        let shouldFail = Self.failedResponsesRemaining > 0
        if shouldFail { Self.failedResponsesRemaining -= 1 }
        Self.stateLock.unlock()
        let status = shouldFail ? 503 : readinessFile.map {
            FileManager.default.fileExists(atPath: $0.path) ? 200 : 503
        } ?? 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor AppModelTestPluginManager: PluginManaging {
    private let items: [PluginCatalogItem]
    private var catalogCalls = 0

    init(items: [PluginCatalogItem]) {
        self.items = items
    }

    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot {
        catalogCalls += 1
        return .init(items: items, issues: [])
    }

    func setEnabled(id: String, enabled: Bool) async throws -> PluginCatalogItem {
        guard let item = items.first(where: { $0.id == id }) else {
            throw PluginManagementError.pluginNotFound(id)
        }
        return item
    }

    func waitForExit(id: String) async -> PluginCatalogItem? {
        items.first(where: { $0.id == id })
    }

    func install(from source: URL) async throws -> String {
        throw PluginManagementError.operationFailed("unused")
    }

    func installFromGit(_ source: String) async throws -> String {
        throw PluginManagementError.operationFailed("unused")
    }

    func uninstall(id: String) async throws {
        throw PluginManagementError.operationFailed("unused")
    }

    func checkForUpdate(id: String) async throws -> PluginUpdateStatus {
        throw PluginManagementError.operationFailed("unused")
    }

    func update(id: String) async throws -> String {
        throw PluginManagementError.operationFailed("unused")
    }

    func loadAction(pluginID: String, actionID: String) async throws -> PluginActionResponse {
        throw PluginManagementError.operationFailed("unused")
    }

    func submitAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async throws -> PluginActionResponse {
        throw PluginManagementError.operationFailed("unused")
    }

    func pluginsDirectory() async -> URL { FileManager.default.temporaryDirectory }
    func shutdown() async {}
    func catalogCallCount() -> Int { catalogCalls }
}

private actor AppModelControlledPluginManager: PluginManaging {
    private var catalogCalls = 0
    private var continuations: [
        Int: CheckedContinuation<PluginCatalogSnapshot, Never>
    ] = [:]

    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot {
        let call = catalogCalls
        catalogCalls += 1
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func completeCatalog(call: Int, snapshot: PluginCatalogSnapshot) {
        continuations.removeValue(forKey: call)?.resume(returning: snapshot)
    }

    func catalogCallCount() -> Int { catalogCalls }
    func setEnabled(id: String, enabled: Bool) async throws -> PluginCatalogItem {
        throw PluginManagementError.operationFailed("unused")
    }
    func waitForExit(id: String) async -> PluginCatalogItem? { nil }
    func install(from source: URL) async throws -> String {
        throw PluginManagementError.operationFailed("unused")
    }
    func installFromGit(_ source: String) async throws -> String {
        throw PluginManagementError.operationFailed("unused")
    }
    func uninstall(id: String) async throws {
        throw PluginManagementError.operationFailed("unused")
    }
    func checkForUpdate(id: String) async throws -> PluginUpdateStatus {
        throw PluginManagementError.operationFailed("unused")
    }
    func update(id: String) async throws -> String {
        throw PluginManagementError.operationFailed("unused")
    }
    func loadAction(pluginID: String, actionID: String) async throws -> PluginActionResponse {
        throw PluginManagementError.operationFailed("unused")
    }
    func submitAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async throws -> PluginActionResponse {
        throw PluginManagementError.operationFailed("unused")
    }
    func pluginsDirectory() async -> URL { FileManager.default.temporaryDirectory }
    func shutdown() async {}
}
