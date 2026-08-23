import Foundation
import XCTest
@testable import CCBuddy

@MainActor
final class PluginAppModelIntegrationTests: XCTestCase {
    func testCatalogReconciliationReplacesAddsAndPrunesDerivedProviders() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = Provider(id: "http", name: "HTTP", baseUrl: "https://example.com")
        let stale = Provider(
            id: "plugin:alpha",
            name: "Old name",
            baseUrl: "http://127.0.0.1:1/v1",
            backend: .plugin,
            pluginId: "alpha"
        )
        let orphan = Provider(
            id: "plugin:orphan",
            name: "Orphan",
            baseUrl: "http://127.0.0.1:2/v1",
            backend: .plugin,
            pluginId: "orphan"
        )
        let config = AppConfig(
            activeProviderId: http.id,
            gatewayEnabled: false,
            providers: [http, stale, orphan]
        )
        let manager = FakePluginManager(items: [pluginItem(id: "alpha", port: 31_111)])
        let (model, repository) = try makeModel(root: root, config: config, manager: manager)

        await model.refreshPlugins()

        XCTAssertEqual(model.config.providers.map(\.id), ["http", "plugin:alpha"])
        let derived = try XCTUnwrap(model.config.providers.last)
        XCTAssertEqual(derived.name, "Alpha")
        XCTAssertEqual(derived.baseUrl, "http://127.0.0.1:31111/v1")
        XCTAssertEqual(derived.protocol, .openAIResponses)
        XCTAssertEqual(derived.backend, .plugin)
        XCTAssertEqual(derived.pluginId, "alpha")
        XCTAssertEqual(try repository.load().providers, model.config.providers)
        await model.shutdown()
    }

    func testStoppedPluginProviderCannotBeSelected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = Provider(id: "http", name: "HTTP", baseUrl: "https://example.com")
        let manager = FakePluginManager(items: [pluginItem(id: "alpha", port: 31_112)])
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(activeProviderId: http.id, gatewayEnabled: false, providers: [http]),
            manager: manager
        )
        await model.refreshPlugins()

        await model.setActiveProvider("plugin:alpha")

        XCTAssertEqual(model.config.activeProviderId, http.id)
        XCTAssertTrue(model.pluginAlert?.message.contains("先在插件页启用") == true)
        XCTAssertEqual(model.pluginAlert?.localizesMessage, true)
        await model.shutdown()
    }

    func testPluginAuthoredActionMessageRemainsVerbatim() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FakePluginManager(items: [])
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(gatewayEnabled: false),
            manager: manager
        )

        _ = await model.submitPluginAction(
            pluginID: "alpha",
            actionID: "external-message",
            values: [:]
        )

        XCTAssertEqual(model.pluginAlert?.message, "done")
        XCTAssertEqual(model.pluginAlert?.localizesMessage, false)
        await model.shutdown()
    }

    func testDisablingActivePluginRetainsProviderAndSelectsHTTPFallback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = Provider(id: "http", name: "HTTP", baseUrl: "https://example.com")
        let plugin = derivedProvider(id: "alpha", port: 31_113)
        let manager = FakePluginManager(items: [pluginItem(id: "alpha", port: 31_113, lifecycle: .running)])
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(
                activeProviderId: plugin.id,
                gatewayEnabled: false,
                providers: [http, plugin]
            ),
            manager: manager
        )
        await model.refreshPlugins()

        await model.setPluginEnabled("alpha", enabled: false)

        XCTAssertEqual(model.config.activeProviderId, http.id)
        XCTAssertEqual(model.config.providers.map(\.id), [http.id, plugin.id])
        XCTAssertEqual(model.plugins.first?.lifecycle, .stopped)
        let enabledValue = await manager.enabledValue(for: "alpha")
        XCTAssertEqual(enabledValue, false)
        await model.shutdown()
    }

    func testApplicationStartupAutoStartsActivePluginBeforeGatewayDecision() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = derivedProvider(id: "alpha", port: 31_114)
        let manager = FakePluginManager(items: [pluginItem(id: "alpha", port: 31_114)])
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(
                activeProviderId: plugin.id,
                gatewayEnabled: false,
                providers: [plugin]
            ),
            manager: manager
        )

        await model.startApplicationServices()

        let enabledValue = await manager.enabledValue(for: "alpha")
        XCTAssertEqual(enabledValue, true)
        XCTAssertEqual(model.plugins.first?.lifecycle, .running)
        XCTAssertEqual(model.gatewayState, .stopped)
        await model.shutdown()
    }

    func testUnexpectedActivePluginExitChoosesSafeFallback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = Provider(id: "http", name: "HTTP", baseUrl: "https://example.com")
        let plugin = derivedProvider(id: "alpha", port: 31_115)
        let manager = FakePluginManager(items: [pluginItem(id: "alpha", port: 31_115, lifecycle: .running)])
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(
                activeProviderId: plugin.id,
                gatewayEnabled: false,
                providers: [http, plugin]
            ),
            manager: manager
        )
        await model.refreshPlugins()

        await manager.crash(id: "alpha", message: "sidecar exited")
        for _ in 0..<100 where model.config.activeProviderId != http.id {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(model.config.activeProviderId, http.id)
        XCTAssertEqual(model.plugins.first?.lifecycle, .failed)
        XCTAssertTrue(model.pluginAlert?.message.contains("sidecar exited") == true)
        await model.shutdown()
    }

    func testOverlappingCatalogRefreshesPublishOnlyTheLatestRequest() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ControlledPluginManager()
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(gatewayEnabled: false),
            manager: manager
        )

        let first = Task { await model.refreshPlugins(reconcileProviders: false) }
        let observedFirstCall = await waitForCatalogCalls(1, manager: manager)
        XCTAssertTrue(observedFirstCall)
        let second = Task { await model.refreshPlugins(reconcileProviders: false) }
        let observedSecondCall = await waitForCatalogCalls(2, manager: manager)
        XCTAssertTrue(observedSecondCall)

        await manager.completeCatalog(
            call: 1,
            snapshot: .init(
                items: [pluginItem(id: "newer", port: 31_117)],
                issues: [.init(location: "newer", message: "newer snapshot")]
            )
        )
        await second.value
        XCTAssertEqual(model.plugins.map(\.id), ["newer"])
        XCTAssertEqual(model.pluginIssues.map(\.location), ["newer"])

        await manager.completeCatalog(
            call: 0,
            snapshot: .init(
                items: [pluginItem(id: "older", port: 31_116)],
                issues: [.init(location: "older", message: "stale snapshot")]
            )
        )
        await first.value

        XCTAssertEqual(model.plugins.map(\.id), ["newer"])
        XCTAssertEqual(model.pluginIssues.map(\.location), ["newer"])
        XCTAssertFalse(model.pluginCatalogLoading)
        await model.shutdown()
    }

    func testCatalogRefreshPreservesUpdateMetadataPublishedWhileCatalogIsSuspended() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ControlledPluginManager(updateLatestVersion: "2.0.0")
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(gatewayEnabled: false),
            manager: manager
        )
        let item = pluginItem(id: "alpha", port: 31_118)

        let initial = Task { await model.refreshPlugins(reconcileProviders: false) }
        let observedInitialCall = await waitForCatalogCalls(1, manager: manager)
        XCTAssertTrue(observedInitialCall)
        await manager.completeCatalog(call: 0, snapshot: .init(items: [item], issues: []))
        await initial.value

        let inFlight = Task { await model.refreshPlugins(reconcileProviders: false) }
        let observedInFlightCall = await waitForCatalogCalls(2, manager: manager)
        XCTAssertTrue(observedInFlightCall)
        await model.checkPluginUpdate("alpha")
        XCTAssertEqual(model.plugins.first?.latestVersion, "2.0.0")
        XCTAssertEqual(model.plugins.first?.updateAvailable, true)

        await manager.completeCatalog(call: 1, snapshot: .init(items: [item], issues: []))
        await inFlight.value

        XCTAssertEqual(model.plugins.first?.version, "1.0.0")
        XCTAssertEqual(model.plugins.first?.latestVersion, "2.0.0")
        XCTAssertEqual(model.plugins.first?.updateAvailable, true)
        await model.shutdown()
    }

    func testShutdownReachesPluginManager() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FakePluginManager(items: [])
        let (model, _) = try makeModel(
            root: root,
            config: AppConfig(gatewayEnabled: false),
            manager: manager
        )

        await model.shutdown()

        let didShutdown = await manager.didShutdown()
        XCTAssertTrue(didShutdown)
    }

    private func makeModel(
        root: URL,
        config: AppConfig,
        manager: any PluginManaging
    ) throws -> (AppModel, ConfigRepository) {
        let repository = ConfigRepository(configURL: root.appendingPathComponent("config.json"))
        try repository.save(config)
        return (
            AppModel(
                repository: repository,
                supervisor: BifrostSupervisor(environment: ["CCBUD_HOME": root.path]),
                environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
                pluginManager: manager
            ),
            repository
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-plugin-model-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func waitForCatalogCalls(
        _ expected: Int,
        manager: ControlledPluginManager,
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

final class PluginViewStateTests: XCTestCase {
    func testLifecycleAndAuthenticationLabelsMatchCardStates() {
        var item = pluginItem(id: "alpha", port: 31_120)
        XCTAssertEqual(item.lifecycleLabel, "已停用")
        XCTAssertEqual(item.authenticationLabel, "插件未运行")

        item.authentication = .init(
            state: .loggedOut,
            account: nil,
            message: nil,
            values: [:]
        )
        XCTAssertEqual(item.authenticationLabel, "未登录")
        XCTAssertEqual(
            "\(item.lifecycleLabel) · \(item.authenticationLabel)",
            "已停用 · 未登录"
        )

        item.lifecycle = .running
        item.authentication = .init(
            state: .loggedIn,
            account: "developer@example.com",
            message: nil,
            values: [:]
        )
        XCTAssertEqual(item.lifecycleLabel, "运行中")
        XCTAssertEqual(item.authenticationLabel, "已登录 · developer@example.com")

        item.lifecycle = .failed
        XCTAssertEqual(item.lifecycleLabel, "启动失败")
    }

    func testActionAvailabilityDefaultsLinksToOfflineAndCallsToRunning() {
        let link = PluginActionViewState(action: .init(values: [
            "id": .string("docs"),
            "kind": .string("link"),
            "url": .string("https://example.com/docs"),
        ]))
        let call = PluginActionViewState(action: .init(values: [
            "id": .string("login"),
            "kind": .string("call"),
        ]))
        let offlineCall = PluginActionViewState(action: .init(values: [
            "id": .string("reset"),
            "kind": .string("call"),
            "requiresRunning": .bool(false),
        ]))

        XCTAssertTrue(link.isAvailable(pluginRunning: false))
        XCTAssertEqual(link.externalURL?.absoluteString, "https://example.com/docs")
        XCTAssertFalse(call.isAvailable(pluginRunning: false))
        XCTAssertTrue(call.isAvailable(pluginRunning: true))
        XCTAssertTrue(offlineCall.isAvailable(pluginRunning: false))
    }

    func testFormDraftCoercesAllSupportedFieldKinds() throws {
        let action = formAction()
        var draft = PluginFormDraft(action: action, initialValues: [
            "name": .string("Ada"),
            "count": .number(2),
        ])
        draft.setText("Grace", for: "name")
        draft.setText("4.5", for: "count")
        draft.setText("secret", for: "password")
        draft.setText("two lines", for: "notes")
        draft.setSelection(1, for: "mode")
        draft.setChecked(true, for: "enabled")

        let values = try draft.collectedValues()

        XCTAssertEqual(values["name"], .string("Grace"))
        XCTAssertEqual(values["count"], .number(4.5))
        XCTAssertEqual(values["password"], .string("secret"))
        XCTAssertEqual(values["notes"], .string("two lines"))
        XCTAssertEqual(values["mode"], .number(2))
        XCTAssertEqual(values["enabled"], .bool(true))
    }

    func testFormDraftReportsFocusedValidationFailures() throws {
        var draft = PluginFormDraft(action: formAction())
        XCTAssertThrowsError(try draft.collectedValues()) { error in
            XCTAssertEqual(error as? PluginFormDraft.ValidationError, .required(key: "name", label: "Name"))
        }

        draft.setText("Ada", for: "name")
        draft.setText("not-a-number", for: "count")
        XCTAssertThrowsError(try draft.collectedValues()) { error in
            XCTAssertEqual(error as? PluginFormDraft.ValidationError, .invalidNumber(key: "count", label: "Count"))
        }

        draft.setText("0", for: "count")
        XCTAssertThrowsError(try draft.collectedValues()) { error in
            XCTAssertEqual(
                error as? PluginFormDraft.ValidationError,
                .belowMinimum(key: "count", label: "Count", minimum: 1)
            )
        }
    }

    private func formAction() -> PluginAction {
        .init(values: [
            "id": .string("settings"),
            "kind": .string("form"),
            "fields": .array([
                .object([
                    "key": .string("name"), "label": .string("Name"),
                    "type": .string("text"), "required": .bool(true),
                ]),
                .object([
                    "key": .string("count"), "label": .string("Count"),
                    "type": .string("number"), "required": .bool(true),
                    "min": .number(1), "max": .number(5), "default": .number(2),
                ]),
                .object([
                    "key": .string("password"), "type": .string("password"),
                ]),
                .object([
                    "key": .string("notes"), "type": .string("textarea"),
                ]),
                .object([
                    "key": .string("mode"), "type": .string("select"),
                    "options": .array([
                        .object(["label": .string("Fast"), "value": .string("fast")]),
                        .object(["label": .string("Exact"), "value": .number(2)]),
                    ]),
                ]),
                .object([
                    "key": .string("enabled"), "type": .string("checkbox"),
                    "default": .string("true"),
                ]),
            ]),
        ])
    }
}

private actor FakePluginManager: PluginManaging {
    private var itemsByID: [String: PluginCatalogItem]
    private var enabledValues: [String: Bool] = [:]
    private var shutdownValue = false
    private let directory: URL

    init(items: [PluginCatalogItem]) {
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fake-plugin-directory-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot {
        .init(items: itemsByID.values.sorted { $0.id < $1.id }, issues: [])
    }

    func setEnabled(id: String, enabled: Bool) async throws -> PluginCatalogItem {
        guard var item = itemsByID[id] else { throw PluginManagementError.pluginNotFound(id) }
        item.lifecycle = enabled ? .running : .stopped
        item.failureMessage = nil
        itemsByID[id] = item
        enabledValues[id] = enabled
        return item
    }

    func waitForExit(id: String) async -> PluginCatalogItem? {
        while itemsByID[id]?.isRunning == true {
            do { try await Task.sleep(nanoseconds: 5_000_000) }
            catch { return nil }
        }
        return itemsByID[id]
    }

    func install(from source: URL) async throws -> String { throw PluginManagementError.operationFailed("unused") }
    func installFromGit(_ source: String) async throws -> String { throw PluginManagementError.operationFailed("unused") }

    func uninstall(id: String) async throws {
        guard itemsByID.removeValue(forKey: id) != nil else {
            throw PluginManagementError.pluginNotFound(id)
        }
    }

    func checkForUpdate(id: String) async throws -> PluginUpdateStatus {
        guard let item = itemsByID[id] else { throw PluginManagementError.pluginNotFound(id) }
        return .init(
            hasSource: item.hasSource,
            currentVersion: item.version,
            latestVersion: item.version,
            updateAvailable: false,
            source: nil
        )
    }

    func update(id: String) async throws -> String {
        guard var item = itemsByID[id] else { throw PluginManagementError.pluginNotFound(id) }
        item.lifecycle = .stopped
        itemsByID[id] = item
        return id
    }

    func loadAction(pluginID: String, actionID: String) async throws -> PluginActionResponse {
        .init(succeeded: true, message: nil, values: [:])
    }

    func submitAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async throws -> PluginActionResponse {
        .init(succeeded: true, message: "done", values: values)
    }

    func pluginsDirectory() async -> URL { directory }

    func shutdown() async { shutdownValue = true }

    func enabledValue(for id: String) -> Bool? { enabledValues[id] }
    func didShutdown() -> Bool { shutdownValue }

    func crash(id: String, message: String) {
        guard var item = itemsByID[id] else { return }
        item.lifecycle = .failed
        item.failureMessage = message
        itemsByID[id] = item
    }
}

private actor ControlledPluginManager: PluginManaging {
    private var catalogCalls = 0
    private var catalogContinuations: [
        Int: CheckedContinuation<PluginCatalogSnapshot, Never>
    ] = [:]
    private let updateLatestVersion: String

    init(updateLatestVersion: String = "1.0.0") {
        self.updateLatestVersion = updateLatestVersion
    }

    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot {
        let call = catalogCalls
        catalogCalls += 1
        return await withCheckedContinuation { continuation in
            catalogContinuations[call] = continuation
        }
    }

    func completeCatalog(call: Int, snapshot: PluginCatalogSnapshot) {
        catalogContinuations.removeValue(forKey: call)?.resume(returning: snapshot)
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
        .init(
            hasSource: true,
            currentVersion: "1.0.0",
            latestVersion: updateLatestVersion,
            updateAvailable: updateLatestVersion != "1.0.0",
            source: nil
        )
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

private func pluginItem(
    id: String,
    port: UInt16,
    lifecycle: PluginLifecycleState = .stopped
) -> PluginCatalogItem {
    .init(
        id: id,
        name: id.capitalized,
        version: "1.0.0",
        summary: "Test plugin",
        protocolName: "openai-responses",
        hasSource: true,
        lifecycle: lifecycle,
        provider: .init(
            id: "plugin:\(id)",
            pluginID: id,
            name: id.capitalized,
            baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!,
            protocolName: "openai-responses",
            defaultModel: "primary",
            smallFastModel: "light"
        )
    )
}

private func derivedProvider(id: String, port: UInt16) -> Provider {
    Provider(
        id: "plugin:\(id)",
        name: id.capitalized,
        baseUrl: "http://127.0.0.1:\(port)/v1",
        defaultModel: "primary",
        smallFastModel: "light",
        protocol: .openAIResponses,
        backend: .plugin,
        pluginId: id
    )
}
