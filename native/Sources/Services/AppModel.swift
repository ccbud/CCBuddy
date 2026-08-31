import AppKit
import Combine
import Foundation
import Security
import SwiftUI

private struct AppModelGatewayStartupStateError: LocalizedError {
    let detail: String

    var errorDescription: String? { detail }
}

private struct AppModelConfigurationSupersededError: LocalizedError {
    var errorDescription: String? { "插件目录刷新已被较新的结果取代" }
}

@MainActor
private final class AppModelConfigMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum UIVisualFixture: String, Equatable {
        case legacySmoke = "legacy-smoke"
    }

    enum RuntimeMode: Equatable {
        case application
        case selfCheck
        case unitTestHost
        case uiTesting
    }

    enum ThemeMode: String {
        case light, dark
        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    static let themeModeDefaultsKey = "ccbud-theme"

    enum Destination: String, CaseIterable, Identifiable {
        case providers, plugins, conversations, timeline, monitor, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers: "服务"
            case .plugins: "插件"
            case .conversations: "会话"
            case .timeline: "时间线"
            case .monitor: "监控"
            case .settings: "设置"
            }
        }
        var symbol: String {
            switch self {
            case .providers: "square.grid.2x2"
            case .plugins: "puzzlepiece.extension"
            case .conversations: "bubble.left"
            case .timeline: "calendar"
            case .monitor: "chart.line.uptrend.xyaxis"
            case .settings: "gearshape"
            }
        }
    }

    enum SettingsPane: String, CaseIterable, Identifiable {
        case general, locations, gateway, data, about

        var id: String { rawValue }

        /// About is pinned to the bottom of the rail, separated from the functional panes.
        static var functionalCases: [SettingsPane] { allCases.filter { $0 != .about } }

        var title: String {
            switch self {
            case .general: "常规"
            case .locations: "会话位置"
            case .gateway: "网关"
            case .data: "数据"
            case .about: "关于与更新"
            }
        }

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .locations: "folder"
            case .gateway: "network"
            case .data: "internaldrive"
            case .about: "info.circle"
            }
        }
    }

    struct NavigationState: Equatable {
        private(set) var destination: Destination = .providers
        private(set) var settingsPane: SettingsPane = .gateway

        mutating func select(_ destination: Destination) {
            self.destination = destination
        }

        mutating func selectSettingsPane(_ pane: SettingsPane) {
            settingsPane = pane
        }

        mutating func openSettings(_ pane: SettingsPane) {
            destination = .settings
            settingsPane = pane
        }
    }

    enum PluginGlobalOperation: Equatable {
        case installingLocal
        case installingGit

        var message: String {
            switch self {
            case .installingLocal: return "正在安装插件…"
            case .installingGit: return "正在克隆并构建插件…"
            }
        }
    }

    struct PluginAlert: Identifiable, Equatable {
        enum Style: Equatable { case success, error, information }

        let id = UUID()
        var message: String
        var style: Style
        var localizesMessage = true
    }

    struct CLIRecoveryState: Equatable {
        let journalDirectories: [URL]
        let detail: String
    }

    @Published private(set) var config: AppConfig
    @Published private(set) var navigation = NavigationState()
    @Published private(set) var themeMode: ThemeMode
    @Published var gatewayState: BifrostGatewayState = .stopped
    @Published private(set) var claudeConnected = false
    @Published private(set) var codexConnected = false
    @Published private(set) var claudeAvailable = false
    @Published private(set) var codexAvailable = false
    @Published var lastError: String?
    @Published private(set) var plugins: [PluginCatalogItem] = []
    @Published private(set) var pluginIssues: [PluginCatalogIssue] = []
    @Published private(set) var pluginBusyIDs = Set<String>()
    @Published private(set) var pluginCheckingUpdateIDs = Set<String>()
    @Published private(set) var pluginCatalogLoading = false
    @Published private(set) var pluginGlobalOperation: PluginGlobalOperation?
    @Published var pluginAlert: PluginAlert?
    @Published private(set) var cliRecoveryState: CLIRecoveryState?
    @Published private(set) var updateState: UpdateState
    @Published private(set) var usageHistoryState: UsageHistoryLoadState = .idle
    @Published private(set) var usageHistorySummaries: [UsageRange: UsageHistorySummary] = [:]

    let monitorStore: MonitorStore
    let conversationStore: ConversationStore
    let usageHistoryService: UsageHistoryService

    private let repository: ConfigRepository
    private let importsRoot: URL
    private let supervisor: BifrostSupervisor
    private let connectionManager: CLIConnectionManager
    private let launchAtLoginController: LaunchAtLoginController
    private let pluginManager: any PluginManaging
    private let pluginMayMutateState: Bool
    private let updateService: UpdateService
    private let automaticUpdateLifecycle: AutomaticUpdateLifecycle
    private let updateMayRunAutomatically: Bool
    private let updateRelaunchScheduler: any UpdateRelaunchScheduling
    private let terminateAfterUpdate: @MainActor () -> Void
    private let automaticUpdatePrompt:
        (@MainActor (UpdateRestartPrompt) async -> UpdateRestartChoice)?
    /// Test-only scheduling seam for the narrow interval after supervisor health succeeds and
    /// before AppModel verifies the authoritative state. Production always leaves this nil.
    private let gatewayStartupVerificationHook: (@MainActor () async -> Void)?
    private let usageHistoryMayWatch: Bool
    private let interfacePreferencesDefaults: UserDefaults?
    private var pluginExitMonitors: [String: Task<Void, Never>] = [:]
    private var pluginMonitorTokens: [String: UUID] = [:]
    private var pluginRefreshGeneration: UInt64 = 0
    private var gatewayStateMonitor: Task<Void, Never>?
    private var gatewayOperationGeneration: UInt64 = 0
    private var gatewayControlRequestGeneration: UInt64 = 0
    private var gatewayConfigurationOperation: UInt64?
    private var gatewayControlOperation: UInt64?
    private var gatewayShouldBeRunning = false
    private let configMutationGate = AppModelConfigMutationGate()
    private var usageHistoryWatcher: UsageHistoryWatcher?
    private var usageHistoryInvalidationTask: Task<Void, Never>?
    private var usageHistoryRefreshQueued = false
    private var usageHistoryRefreshWantsInvalidate = false
    private var lastInvalidatingUsageRefreshAt: Date?
    private var usageHistoryGeneration = UUID()
    private var publishedUsageHistorySignature: String?
    private var usageHistoryWatchSignature: String?
    private var isShuttingDown = false

    var cliRecoveryRequired: Bool { cliRecoveryState != nil }

    var selected: Destination {
        get { navigation.destination }
        set {
            var next = navigation
            next.select(newValue)
            navigation = next
        }
    }

    func selectSettingsPane(_ pane: SettingsPane) {
        var next = navigation
        next.selectSettingsPane(pane)
        navigation = next
    }

    func openSettings(_ pane: SettingsPane) {
        var next = navigation
        next.openSettings(pane)
        navigation = next
    }

    init(
        repository: ConfigRepository = ConfigRepository(),
        supervisor: BifrostSupervisor = BifrostSupervisor(),
        connectionManager: CLIConnectionManager? = nil,
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pluginManager: (any PluginManaging)? = nil,
        usageHistoryService: UsageHistoryService? = nil,
        historyDirectoryDiscovery: HistoryDirectoryDiscovery? = nil,
        isPrimaryInstance: Bool? = nil,
        userDefaults: UserDefaults = .standard,
        updateService: UpdateService? = nil,
        automaticUpdateLifecycle: AutomaticUpdateLifecycle? = nil,
        automaticUpdatesEnabled: Bool? = nil,
        updateRelaunchScheduler: any UpdateRelaunchScheduling = UpdateRelaunchCoordinator(),
        terminateAfterUpdate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        automaticUpdatePrompt:
            (@MainActor (UpdateRestartPrompt) async -> UpdateRestartChoice)? = nil,
        gatewayStartupVerificationHook: (@MainActor () async -> Void)? = nil
    ) {
        let runtimeMode = Self.runtimeMode(environment: environment)
        let uiVisualFixture = Self.uiVisualFixture(environment: environment)
        // Constructing the process-wide instance coordinator acquires its on-disk lock. Test and
        // self-check modes must not touch it merely to initialize an AppModel.
        let applicationIsPrimaryInstance = runtimeMode == .application
            ? (isPrimaryInstance ?? ApplicationInstanceCoordinator.shared.isPrimaryInstance)
            : false
        let shouldUsePersistentInterfacePreferences = Self.shouldUsePersistentInterfacePreferences(
            runtimeMode: runtimeMode,
            isPrimaryInstance: applicationIsPrimaryInstance
        )
        interfacePreferencesDefaults = shouldUsePersistentInterfacePreferences ? userDefaults : nil
        _themeMode = Published(initialValue: shouldUsePersistentInterfacePreferences
            ? ThemeMode(rawValue: userDefaults.string(forKey: Self.themeModeDefaultsKey) ?? "") ?? .light
            : .light)
        let mayMutateApplicationState = runtimeMode != .application
            || applicationIsPrimaryInstance
        self.repository = repository
        let importsRoot = repository.configURL.deletingLastPathComponent()
            .appendingPathComponent("imports", isDirectory: true)
        self.importsRoot = importsRoot
        let updateConfiguration = UpdateServiceConfiguration.live(
            stagingRoot: repository.configURL.deletingLastPathComponent()
                .appendingPathComponent("updates", isDirectory: true)
        )
        let resolvedUpdateService = updateService ?? UpdateService(configuration: updateConfiguration)
        self.updateService = resolvedUpdateService
        self.automaticUpdateLifecycle = automaticUpdateLifecycle ?? AutomaticUpdateLifecycle(
            updateService: resolvedUpdateService,
            stampFileURL: repository.configURL.deletingLastPathComponent()
                .appendingPathComponent("update-check.json")
        )
        self.updateRelaunchScheduler = updateRelaunchScheduler
        self.terminateAfterUpdate = terminateAfterUpdate
        self.automaticUpdatePrompt = automaticUpdatePrompt
        self.gatewayStartupVerificationHook = gatewayStartupVerificationHook
        updateMayRunAutomatically = automaticUpdatesEnabled
            ?? (runtimeMode == .application && mayMutateApplicationState)
        usageHistoryMayWatch = runtimeMode == .application && mayMutateApplicationState
        updateState = .idle(currentVersion: updateConfiguration.currentVersion)
        // Built here rather than defaulted in the signature so the record cache lands beside the
        // rest of this process's data — which is an isolated root under test, not the real home.
        self.usageHistoryService = usageHistoryService
            ?? UsageHistoryService(recordCacheRoot: importsRoot.deletingLastPathComponent())
        self.supervisor = supervisor
        let resolvedConnectionManager = connectionManager ?? CLIConnectionManager(
            repository: repository,
            environment: environment
        )
        self.connectionManager = resolvedConnectionManager
        self.launchAtLoginController = launchAtLoginController
        let mayMutatePluginState = runtimeMode != .uiTesting && mayMutateApplicationState
        pluginMayMutateState = mayMutatePluginState
        if let pluginManager {
            self.pluginManager = pluginManager
        } else if uiVisualFixture == .legacySmoke {
            self.pluginManager = LegacySmokeVisualPluginManager()
        } else {
            let pluginHome: URL
            if runtimeMode == .uiTesting {
                pluginHome = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ccbud-ui-plugins-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            } else if let configured = environment["CCBUD_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !configured.isEmpty {
                pluginHome = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                pluginHome = repository.configURL.deletingLastPathComponent()
            }
            let pluginRepository = PluginRepository(layout: .init(ccbudHome: pluginHome))
            self.pluginManager = LivePluginManager(repository: pluginRepository)
        }
        self.monitorStore = MonitorStore(client: BifrostManagementClient(
            port: 8_788,
            credentials: supervisor.managementCredentials
        ), requestActivity: supervisor.requestActivity)
        var initialConfig: AppConfig
        var initialConfigError: String?
        if runtimeMode == .uiTesting {
            var fixture = AppConfig.fixture
            if uiVisualFixture == .legacySmoke {
                fixture.providers[0].models = [.init(alias: "a", upstream: "b")]
            }
            fixture.language = AppLanguage(rawValue: environment["CCBUD_UI_LANGUAGE"] ?? "")?.rawValue
            fixture.historyDirs = [
                environment["CCBUD_UI_HISTORY_DIR"]
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                        "ccbud-ui-history-\(ProcessInfo.processInfo.processIdentifier)",
                        isDirectory: true
                    ).path,
            ]
            fixture.historyActive = "all"
            if environment["CCBUD_UI_TRAY_USAGE"] == "1" {
                fixture.trayUsage.enabled = true
                if let range = environment["CCBUD_UI_TRAY_RANGE"],
                   ["1d", "7d", "30d", "all"].contains(range) {
                    fixture.trayUsage.range = range
                }
            }
            if environment["CCBUD_UI_SECOND_PROVIDER"] == "1" {
                fixture.providers.append(Provider(
                    id: "p2",
                    name: "Backup",
                    baseUrl: "https://backup.example.com/v1",
                    authToken: "sk-backup-fixture",
                    defaultModel: "backup-model",
                    smallFastModel: "backup-fast"
                ))
            }
            initialConfig = fixture
        } else if runtimeMode == .selfCheck {
            // A packaged self-check must never discover or scan the user's real CLI history.
            // Its functional probes create their own fixtures below the explicitly isolated
            // CCBUD_HOME; this in-memory UI model uses the same isolated tree and never starts
            // normal background services or the updater.
            let isolatedRoot: URL
            if case .enabled(let request) = SelfCheckEnvironmentGate.evaluate(
                environment: environment
            ) {
                isolatedRoot = request.homeDirectory
            } else {
                isolatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ccbud-rejected-selfcheck-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            }
            var fixture = AppConfig.fixture
            fixture.gatewayEnabled = false
            fixture.historyDirs = [
                isolatedRoot.appendingPathComponent("history", isDirectory: true).path,
            ]
            fixture.historyActive = "all"
            fixture.autoUpdate.check = false
            fixture.autoUpdate.autoDownload = false
            initialConfig = fixture
        } else {
            do { initialConfig = try repository.load() }
            catch {
                initialConfig = AppConfig()
                initialConfigError = error.localizedDescription
            }
        }
        var pendingCLIRecoveryJournals: [URL]?
        var pendingCLIRecoveryInspectionError: Error?
        if mayMutatePluginState {
            do {
                let pending = try resolvedConnectionManager.pendingRecoveryJournalDirectories()
                if !pending.isEmpty { pendingCLIRecoveryJournals = pending }
            } catch {
                pendingCLIRecoveryInspectionError = error
            }
        }
        let shouldAutoDiscoverHistoryDirectories = runtimeMode == .application
            && Self.shouldAutoDiscoverHistoryDirectories(
                runtimeMode: runtimeMode,
                isPrimaryInstance: applicationIsPrimaryInstance
            )
        let shouldDiscoverHistoryDirectories = historyDirectoryDiscovery != nil
            || shouldAutoDiscoverHistoryDirectories
        if shouldDiscoverHistoryDirectories,
           pendingCLIRecoveryJournals == nil,
           pendingCLIRecoveryInspectionError == nil {
            let discovery = historyDirectoryDiscovery
                ?? HistoryDirectoryDiscovery(environment: environment)
            let result = discovery.discover(in: initialConfig)
            initialConfig = result.config
            if result.didChange {
                do { try repository.save(initialConfig) }
                catch { initialConfigError = error.localizedDescription }
            }
        }
        config = initialConfig
        conversationStore = ConversationStore(config: initialConfig, importsRoot: importsRoot)
        conversationStore.usageHistoryDidChange = { [weak self] in
            self?.scheduleUsageHistoryRefresh(invalidate: true)
        }
        var automaticGatewayStartupAllowed = true
        if let initialConfigError { lastError = initialConfigError }
        if let pendingCLIRecoveryInspectionError {
            automaticGatewayStartupAllowed = false
            recordPendingCLIRecoveryInspectionFailure(pendingCLIRecoveryInspectionError)
        } else if let pendingCLIRecoveryJournals {
            automaticGatewayStartupAllowed = false
            recordPendingCLIRecovery(journalDirectories: pendingCLIRecoveryJournals)
        }
        if cliRecoveryState == nil {
            do {
                try Self.reconcileLaunchAtLoginIfNeeded(
                    openAtLogin: config.openAtLogin,
                    runtimeMode: runtimeMode,
                    isPrimaryInstance: applicationIsPrimaryInstance,
                    controller: launchAtLoginController
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
        if runtimeMode == .application && mayMutateApplicationState,
           cliRecoveryState == nil {
            var startupConfig = config
            var tokenNeedsMigration = false
            if startupConfig.requireToken {
                let migratedToken = Self.normalizeGatewayToken(startupConfig.gatewayToken)
                tokenNeedsMigration = migratedToken != startupConfig.gatewayToken
                startupConfig.gatewayToken = migratedToken
            }
            let reconnectClaude = startupConfig.connectTargets.contains(CLIConnectionManager.claudeTarget)
                && startupConfig.claudeBackup.objectValue != nil
            let reconnectCodex = startupConfig.connectTargets.contains(CLIConnectionManager.codexTarget)
                && startupConfig.codexBackup.objectValue != nil
            if tokenNeedsMigration || reconnectClaude || reconnectCodex {
                do {
                    config = try self.connectionManager.updateConnections(
                        config: startupConfig,
                        claude: reconnectClaude ? .connect : .unchanged,
                        codex: reconnectCodex ? .connect : .unchanged
                    )
                } catch {
                    automaticGatewayStartupAllowed = false
                    if let rollbackFailure = Self.rollbackFailure(error) {
                        config = (try? repository.load()) ?? config
                        recordCLIRecovery(
                            rollbackFailure,
                            detail: rollbackFailure.localizedDescription
                        )
                    } else {
                        lastError = error.localizedDescription
                    }
                }
            }
            refreshCLIConnectionStatus()
        } else if config.requireToken && mayMutateApplicationState,
                  cliRecoveryState == nil {
            let migratedToken = Self.normalizeGatewayToken(config.gatewayToken)
            if migratedToken != config.gatewayToken {
                var migrated = config
                migrated.gatewayToken = migratedToken
                do {
                    try repository.save(migrated)
                    config = migrated
                } catch {
                    lastError = error.localizedDescription
                }
            }
        } else if cliRecoveryState != nil {
            refreshCLIConnectionStatus()
        }
        monitorStore.configure(port: config.port, gatewayRunning: false)
        if runtimeMode == .uiTesting, environment["CCBUD_UI_GATEWAY_RUNNING"] == "1" {
            gatewayState = .running(port: config.port)
            gatewayShouldBeRunning = true
            monitorStore.configure(port: config.port, gatewayRunning: true)
        }
        if runtimeMode != .uiTesting {
            observeGatewayStateChanges()
        }
        if runtimeMode == .application && mayMutateApplicationState {
            configureUsageHistoryWatcher()
            Task { await refreshUsageHistory() }
            Task { await startApplicationServices(allowGatewayStartup: automaticGatewayStartupAllowed) }
            Task { await initializeUpdater() }
        }
    }

    static func runtimeMode(environment: [String: String]) -> RuntimeMode {
        if environment[SelfCheckEnvironmentGate.enabledKey] == "1" { return .selfCheck }
        if uiTestingBuildEnabled, environment["CCBUD_UI_TESTING"] == "1" { return .uiTesting }

        let xctestHostKeys = [
            "XCTestBundlePath",
            "XCTestConfigurationFilePath",
            "XCTestSessionIdentifier",
        ]
        if xctestHostKeys.contains(where: { !(environment[$0] ?? "").isEmpty }) {
            return .unitTestHost
        }
        return .application
    }

    /// Xcode does not consistently copy its XCTest marker variables into a hosted macOS test
    /// application's environment. The loaded XCTest runtime is the authoritative fallback for
    /// process bootstrap, while `runtimeMode(environment:)` stays deterministic for model tests.
    static func processRuntimeMode(
        environment: [String: String],
        xctestLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> RuntimeMode {
        let explicitMode = runtimeMode(environment: environment)
        guard explicitMode == .application, xctestLoaded else { return explicitMode }
        return .unitTestHost
    }

    /// UI fixtures are development/test infrastructure and must be unreachable in a distributed
    /// Release binary even if its process inherits similarly named environment variables.
    static var uiTestingBuildEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    /// Visual fixtures are intentionally subordinate to the explicit UI-testing gate. An
    /// environment variable inherited by a normal or packaged launch must never replace live
    /// configuration or plugin discovery with test data.
    static func uiVisualFixture(environment: [String: String]) -> UIVisualFixture? {
        guard runtimeMode(environment: environment) == .uiTesting,
              let rawValue = environment["CCBUD_UI_VISUAL_FIXTURE"]
        else { return nil }
        return UIVisualFixture(rawValue: rawValue)
    }

    static func shouldAutoDiscoverHistoryDirectories(
        runtimeMode: RuntimeMode,
        isPrimaryInstance: Bool
    ) -> Bool {
        runtimeMode == .application && isPrimaryInstance
    }

    static func shouldUsePersistentInterfacePreferences(
        runtimeMode: RuntimeMode,
        isPrimaryInstance: Bool
    ) -> Bool {
        runtimeMode == .application && isPrimaryInstance
    }

    static func reconcileLaunchAtLoginIfNeeded(
        openAtLogin: Bool,
        runtimeMode: RuntimeMode,
        isPrimaryInstance: Bool,
        controller: LaunchAtLoginController
    ) throws {
        guard openAtLogin, runtimeMode == .application, isPrimaryInstance else { return }
        try controller.reconcileEnabledRegistration()
    }

    var activeProvider: Provider? { config.activeProvider }

    var pluginsDirectoryUnavailable: Bool { !pluginMayMutateState }

    /// Usage surfaces intentionally stay global even when the Conversations page selects one
    /// source. This matches the legacy command, popover, hero, and tray-title contract.
    var usageHistoryConfiguration: UsageHistoryConfiguration {
        UsageHistoryConfiguration(historyDirs: config.enabledHistoryDirs, active: "all")
    }

    func usageHistorySummary(for range: UsageRange) -> UsageHistorySummary? {
        usageHistorySummaries[range]
    }

    func refreshUsageHistory(invalidate: Bool = false) async {
        guard !isShuttingDown else { return }
        var shouldInvalidate = invalidate
        if usageHistoryMayWatch {
            let currentWatchSignature = usageHistoryRootIdentitySignature()
            if currentWatchSignature != usageHistoryWatchSignature {
                configureUsageHistoryWatcher()
                shouldInvalidate = true
            }
        }
        let configuration = usageHistoryConfiguration
        let signature = configuration.cacheSignature
        let generation = UUID()
        usageHistoryGeneration = generation

        if publishedUsageHistorySignature != signature {
            publishedUsageHistorySignature = signature
            usageHistorySummaries = [:]
            usageHistoryState = .loading
        } else if usageHistorySummaries.isEmpty {
            usageHistoryState = .loading
        }

        if shouldInvalidate { await usageHistoryService.invalidate() }
        do {
            let summaries = try await usageHistoryService.summaries(
                configuration: configuration,
                ranges: UsageRange.allCases
            )
            guard usageHistoryGeneration == generation,
                  usageHistoryConfiguration.cacheSignature == signature,
                  !isShuttingDown else { return }
            let activeProviderID = config.activeProvider?.id
            let resolved = summaries.mapValues { summary in
                summary.resolvingFavoriteProvider(
                    providers: config.providers,
                    activeProviderID: activeProviderID
                )
            }
            // A publish here re-renders every observer of the model. Between two appends the
            // aggregates are frequently identical, so equality is checked first.
            if usageHistorySummaries != resolved { usageHistorySummaries = resolved }
            if usageHistoryState != .loaded { usageHistoryState = .loaded }
        } catch is CancellationError {
            return
        } catch {
            guard usageHistoryGeneration == generation,
                  usageHistoryConfiguration.cacheSignature == signature,
                  !isShuttingDown else { return }
            usageHistoryState = .failed(error.localizedDescription)
        }
    }

    func toggleTheme() {
        themeMode = themeMode == .light ? .dark : .light
        interfacePreferencesDefaults?.set(themeMode.rawValue, forKey: Self.themeModeDefaultsKey)
    }

    func setActiveProvider(_ id: String) async {
        guard let provider = config.providers.first(where: { $0.id == id }) else { return }
        if provider.backend == .plugin {
            guard let pluginID = provider.pluginId,
                  plugins.first(where: { $0.id == pluginID })?.isRunning == true else {
                pluginAlert = .init(message: "请先在插件页启用该服务对应的插件", style: .error)
                return
            }
        }
        await persistAndRestartGateway { next in
            next.activeProviderId = id
            // With failover on the queue decides where requests go, so choosing a provider has to
            // mean "try this one first" — otherwise the click marks a row that receives nothing.
            if next.gatewayFailover.enabled {
                next.gatewayFailover.providerIds.removeAll { $0 == id }
                next.gatewayFailover.providerIds.insert(id, at: 0)
            }
        }
    }

    func upsertProvider(_ provider: Provider) async {
        guard provider.backend == .http else {
            pluginAlert = .init(message: "插件服务由插件清单管理，不能手动编辑", style: .information)
            return
        }
        await persistAndRestartGateway { next in
            if let index = next.providers.firstIndex(where: { $0.id == provider.id }) {
                next.providers[index] = provider
            } else {
                next.providers.append(provider)
                next.activeProviderId = next.activeProviderId ?? provider.id
            }
        }
    }

    func deleteProvider(_ id: String) async {
        if config.providers.first(where: { $0.id == id })?.backend == .plugin {
            pluginAlert = .init(message: "请从插件页卸载插件以移除该服务", style: .information)
            return
        }
        await persistAndRestartGateway { next in
            next.providers.removeAll { $0.id == id }
            if next.activeProviderId == id { next.activeProviderId = next.providers.first?.id }
        }
    }

    func reorderProvider(_ sourceID: String, to targetID: String) async {
        guard sourceID != targetID, !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            guard let sourceIndex = config.providers.firstIndex(where: { $0.id == sourceID }),
                  let targetIndex = config.providers.firstIndex(where: { $0.id == targetID })
            else { return }
            var next = config
            let provider = next.providers.remove(at: sourceIndex)
            next.providers.insert(provider, at: min(targetIndex, next.providers.endIndex))
            persistConfigLocked(next)
        }
    }

    /// Discovers installed plugins before starting Bifrost. A plugin-backed active provider must
    /// be healthy first because Bifrost starts routing as soon as its configuration is accepted.
    func startApplicationServices(allowGatewayStartup: Bool = true) async {
        guard pluginMayMutateState, !isShuttingDown,
              !reassertCLIRecoveryIfNeeded() else { return }
        await refreshPlugins(reconcileProviders: true, restartRunningGateway: false)

        if let provider = activeProvider, provider.backend == .plugin,
           let pluginID = provider.pluginId,
           plugins.first(where: { $0.id == pluginID })?.isRunning != true {
            await setPluginEnabled(pluginID, enabled: true, announceSuccess: false)
        }

        guard !isShuttingDown, !reassertCLIRecoveryIfNeeded() else { return }
        if config.gatewayEnabled && allowGatewayStartup {
            await startGateway()
        }
    }

    func refreshPlugins(reconcileProviders: Bool = true) async {
        await refreshPlugins(
            reconcileProviders: reconcileProviders,
            restartRunningGateway: true
        )
    }

    func setPluginEnabled(_ id: String, enabled: Bool) async {
        await setPluginEnabled(id, enabled: enabled, announceSuccess: true)
    }

    func installPlugin(from source: URL) async {
        guard canBeginGlobalPluginOperation(.installingLocal) else { return }
        pluginGlobalOperation = .installingLocal
        defer { pluginGlobalOperation = nil }

        do {
            let id = try await pluginManager.install(from: source)
            await refreshPlugins(reconcileProviders: true)
            showPluginMessage("插件“\(id)”已安装", style: .success)
        } catch {
            showPluginError(error, prefix: "安装插件失败")
        }
    }

    func installPluginFromGit(_ source: String) async {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showPluginMessage("请输入 Git 仓库地址", style: .error)
            return
        }
        guard canBeginGlobalPluginOperation(.installingGit) else { return }
        pluginGlobalOperation = .installingGit
        defer { pluginGlobalOperation = nil }

        do {
            let id = try await pluginManager.installFromGit(trimmed)
            await refreshPlugins(reconcileProviders: true)
            showPluginMessage("插件“\(id)”已安装", style: .success)
        } catch {
            showPluginError(error, prefix: "从 Git 安装失败")
        }
    }

    func checkPluginUpdate(_ id: String) async {
        guard pluginMayMutateState, !isShuttingDown,
              !pluginCheckingUpdateIDs.contains(id) else { return }
        pluginCheckingUpdateIDs.insert(id)
        defer { pluginCheckingUpdateIDs.remove(id) }

        do {
            let status = try await pluginManager.checkForUpdate(id: id)
            guard let index = plugins.firstIndex(where: { $0.id == id }),
                  plugins[index].version == status.currentVersion else { return }
            plugins[index].latestVersion = status.latestVersion
            plugins[index].updateAvailable = status.updateAvailable
        } catch {
            // Background update discovery is intentionally quiet. An explicit retry still leaves
            // the card usable and does not turn a network failure into plugin failure state.
        }
    }

    func updatePlugin(_ id: String) async {
        guard canBeginPluginOperation(id) else { return }
        let wasActive = activeProvider?.pluginId == id
        invalidatePluginExitMonitor(id: id)
        pluginBusyIDs.insert(id)
        defer { pluginBusyIDs.remove(id) }

        do {
            let installedID = try await pluginManager.update(id: id)
            await refreshPlugins(reconcileProviders: true)
            if wasActive { await selectSafeFallback(excludingPluginID: id) }
            showPluginMessage("插件“\(installedID)”已更新，重新启用后生效", style: .success)
        } catch {
            await refreshPlugins(reconcileProviders: false)
            showPluginError(error, prefix: "更新插件失败")
        }
    }

    func uninstallPlugin(_ id: String) async {
        guard canBeginPluginOperation(id) else { return }
        let displayName = plugins.first(where: { $0.id == id })?.name ?? id
        let wasActive = activeProvider?.pluginId == id
        invalidatePluginExitMonitor(id: id)
        pluginBusyIDs.insert(id)
        defer { pluginBusyIDs.remove(id) }

        do {
            try await pluginManager.uninstall(id: id)
            await refreshPlugins(reconcileProviders: true)
            if wasActive { await selectSafeFallback(excludingPluginID: id) }
            showPluginMessage("插件“\(displayName)”已卸载", style: .success)
        } catch {
            await refreshPlugins(reconcileProviders: false)
            showPluginError(error, prefix: "卸载插件失败")
        }
    }

    func loadPluginAction(pluginID: String, actionID: String) async -> PluginActionResponse? {
        guard canBeginPluginOperation(pluginID) else { return nil }
        pluginBusyIDs.insert(pluginID)
        defer { pluginBusyIDs.remove(pluginID) }
        do {
            return try await pluginManager.loadAction(pluginID: pluginID, actionID: actionID)
        } catch {
            showPluginError(error, prefix: "载入插件操作失败")
            return nil
        }
    }

    func submitPluginAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async -> PluginActionResponse? {
        guard canBeginPluginOperation(pluginID) else { return nil }
        pluginBusyIDs.insert(pluginID)
        defer { pluginBusyIDs.remove(pluginID) }
        do {
            let response = try await pluginManager.submitAction(
                pluginID: pluginID,
                actionID: actionID,
                values: values
            )
            await refreshPlugins(reconcileProviders: false)
            if let message = response.message {
                showPluginMessage(
                    message,
                    style: response.succeeded ? .success : .error,
                    localizesMessage: false
                )
            } else {
                showPluginMessage(
                    "操作已完成",
                    style: response.succeeded ? .success : .error
                )
            }
            return response
        } catch {
            showPluginError(error, prefix: "插件操作失败")
            return nil
        }
    }

    func pluginsDirectory() async -> URL { await pluginManager.pluginsDirectory() }

    func startGateway() async {
        guard !isShuttingDown else { return }
        let request = beginGatewayControlRequest(shouldRun: true)
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard isCurrentGatewayControlRequest(request), gatewayShouldBeRunning,
              !isShuttingDown, !reassertCLIRecoveryIfNeeded() else { return }
        let operation = beginGatewayOperation()
        gatewayControlOperation = operation
        defer {
            if gatewayControlOperation == operation { gatewayControlOperation = nil }
        }
        guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
        await startGatewayLocked(operation: operation, controlRequest: request)
    }

    private func startGatewayLocked(operation: UInt64, controlRequest: UInt64) async {
        let wasRunning = gatewayState.isRunning
        gatewayState = .starting
        monitorStore.configure(port: config.port, gatewayRunning: false)
        monitorStore.appendLifecycle(
            level: .info,
            message: "\(wasRunning ? "正在重启" : "正在启动") Bifrost · localhost:\(config.port)"
        )
        do {
            try await supervisor.start(config: config)
            await gatewayStartupVerificationHook?()
            guard isCurrentGatewayOperation(operation) else { return }
            if isShuttingDown {
                await supervisor.stop()
                guard isCurrentGatewayOperation(operation) else { return }
                gatewayState = .stopped
                monitorStore.configure(port: config.port, gatewayRunning: false)
                return
            }
            let supervisorState = await supervisor.state
            guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
            let runningState = try confirmedRunningGatewayState(supervisorState)
            guard gatewayShouldBeRunning else {
                await supervisor.stop()
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
                gatewayState = .stopped
                monitorStore.configure(port: config.port, gatewayRunning: false)
                return
            }
            gatewayState = runningState
            monitorStore.configure(port: config.port, gatewayRunning: gatewayState.isRunning)
            monitorStore.appendLifecycle(
                level: .info,
                message: "Bifrost 已启动 · localhost:\(config.port)"
            )
            lastError = nil
        } catch {
            guard isCurrentGatewayOperation(operation) else { return }
            if isShuttingDown {
                gatewayState = .stopped
                monitorStore.configure(port: config.port, gatewayRunning: false)
                return
            }
            let detail = Self.publicGatewayMessage(error)
            if isCurrentGatewayControlRequest(controlRequest) {
                gatewayShouldBeRunning = false
            }
            gatewayState = .failed(detail)
            monitorStore.configure(port: config.port, gatewayRunning: false)
            monitorStore.appendLifecycle(level: .error, message: "Bifrost 启动失败 · \(detail)")
            lastError = detail
        }
    }

    func stopGateway() async {
        guard !isShuttingDown else { return }
        let request = beginGatewayControlRequest(shouldRun: false)
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard isCurrentGatewayControlRequest(request), !gatewayShouldBeRunning,
              !isShuttingDown else { return }
        let operation = beginGatewayOperation()
        gatewayControlOperation = operation
        defer {
            if gatewayControlOperation == operation { gatewayControlOperation = nil }
        }
        guard isCurrentGatewayOperation(operation) else { return }
        await stopGatewayLocked(operation: operation)
    }

    private func stopGatewayLocked(operation: UInt64) async {
        let wasRunningOrStarting = gatewayState.isRunningOrStarting
        if wasRunningOrStarting {
            monitorStore.appendLifecycle(level: .info, message: "正在停止 Bifrost · localhost:\(config.port)")
        }
        await supervisor.stop()
        guard isCurrentGatewayOperation(operation) else { return }
        if reassertCLIRecoveryIfNeeded() { return }
        gatewayState = .stopped
        monitorStore.configure(port: config.port, gatewayRunning: false)
        if wasRunningOrStarting {
            monitorStore.appendLifecycle(level: .info, message: "Bifrost 已停止")
        }
    }

    func setGatewayEnabled(_ enabled: Bool) async {
        guard !isShuttingDown else { return }
        let previousRunIntent = gatewayShouldBeRunning
        let request = beginGatewayControlRequest(shouldRun: enabled)
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard isCurrentGatewayControlRequest(request), gatewayShouldBeRunning == enabled,
              !isShuttingDown, !reassertCLIRecoveryIfNeeded() else { return }
        let operation = beginGatewayOperation()
        gatewayControlOperation = operation
        defer {
            if gatewayControlOperation == operation { gatewayControlOperation = nil }
        }
        guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
        await setGatewayEnabledLocked(
            enabled,
            operation: operation,
            controlRequest: request,
            previousRunIntent: previousRunIntent
        )
    }

    private func setGatewayEnabledLocked(
        _ enabled: Bool,
        operation: UInt64,
        controlRequest: UInt64,
        previousRunIntent: Bool
    ) async {
        let previous = config
        var next = config
        next.gatewayEnabled = enabled
        if enabled {
            gatewayState = .starting
            monitorStore.configure(port: next.port, gatewayRunning: false)
            monitorStore.appendLifecycle(level: .info, message: "正在启动 Bifrost · localhost:\(next.port)")
            do {
                try await supervisor.start(config: next)
                await gatewayStartupVerificationHook?()
                guard isCurrentGatewayOperation(operation) else { return }
                if isShuttingDown {
                    await supervisor.stop()
                    guard isCurrentGatewayOperation(operation) else { return }
                    gatewayState = .stopped
                    monitorStore.configure(port: previous.port, gatewayRunning: false)
                    return
                }
                let supervisorState = await supervisor.state
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
                let runningState = try confirmedRunningGatewayState(supervisorState)
                guard gatewayShouldBeRunning else {
                    await supervisor.stop()
                    guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
                    gatewayState = .stopped
                    monitorStore.configure(port: previous.port, gatewayRunning: false)
                    return
                }
                try repository.save(next)
                config = next
                gatewayState = runningState
                monitorStore.configure(port: config.port, gatewayRunning: gatewayState.isRunning)
                monitorStore.appendLifecycle(level: .info, message: "Bifrost 已启动 · localhost:\(config.port)")
                lastError = nil
            } catch {
                guard isCurrentGatewayOperation(operation) else { return }
                if isShuttingDown {
                    gatewayState = .stopped
                    monitorStore.configure(port: previous.port, gatewayRunning: false)
                    return
                }
                let detail = Self.publicGatewayMessage(error)
                await supervisor.stop()
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
                if isCurrentGatewayControlRequest(controlRequest) {
                    gatewayShouldBeRunning = false
                }
                config = previous
                gatewayState = .failed(detail)
                monitorStore.configure(port: previous.port, gatewayRunning: false)
                monitorStore.appendLifecycle(level: .error, message: "Bifrost 启动失败 · \(detail)")
                lastError = detail
            }
        } else {
            if gatewayState.isRunningOrStarting {
                monitorStore.appendLifecycle(level: .info, message: "正在停止 Bifrost · localhost:\(previous.port)")
            }
            await supervisor.stop()
            guard isCurrentGatewayOperation(operation) else { return }
            guard !gatewayShouldBeRunning else { return }
            do {
                try repository.save(next)
                config = next
                gatewayState = .stopped
                monitorStore.configure(port: config.port, gatewayRunning: false)
                monitorStore.appendLifecycle(level: .info, message: "Bifrost 已停止")
                lastError = nil
            } catch {
                config = previous
                lastError = error.localizedDescription
                if isCurrentGatewayControlRequest(controlRequest) {
                    gatewayShouldBeRunning = previousRunIntent
                }
                if gatewayShouldBeRunning && !isShuttingDown {
                    try? await supervisor.start(config: previous)
                    guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
                }
                let supervisorState = await supervisor.state
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return }
                gatewayState = Self.publicGatewayState(supervisorState)
                monitorStore.configure(port: previous.port, gatewayRunning: gatewayState.isRunning)
                monitorStore.appendLifecycle(
                    level: .warning,
                    message: "保存网关开关失败，已恢复先前状态 · \(error.localizedDescription)"
                )
            }
        }
    }

    func setPort(_ port: Int) async {
        guard !isShuttingDown, (1...65_535).contains(port) else { return }
        await applyGatewayConfiguration(
            mutating: { $0.port = port },
            refreshManagedCLIConnections: true,
            progressMessage: "正在将 Bifrost 从 localhost:\(config.port) 切换到 localhost:\(port)",
            successMessage: "网关端口已更新 · localhost:\(port)",
            failurePrefix: "切换网关端口失败"
        )
    }

    func setInsecureSkipVerify(_ enabled: Bool) async {
        guard !isShuttingDown else { return }
        let setting = enabled ? "已允许上游使用不受信任的 TLS 证书" : "已恢复上游 TLS 证书校验"
        await applyGatewayConfiguration(
            mutating: { $0.insecureSkipVerify = enabled },
            progressMessage: "正在重启 Bifrost · \(setting)",
            successMessage: setting,
            failurePrefix: "更新上游 TLS 设置失败"
        )
    }

    func setRetry429Enabled(_ enabled: Bool) async {
        guard !isShuttingDown else { return }
        let setting = enabled ? "已启用 429 自动重试" : "已关闭 429 自动重试"
        await applyGatewayConfiguration(
            mutating: { $0.retry429.enabled = enabled },
            progressMessage: "正在重启 Bifrost · \(setting)",
            successMessage: setting,
            failurePrefix: "更新 429 重试设置失败"
        )
    }

    // MARK: - Failover queue

    /// The queue is the whole route set while failover is on, so an empty one would leave the
    /// gateway with nowhere to send a request. `AppConfig.normalize()` seeds it with the active
    /// provider in that case; these entry points only ever describe the user's edit.
    func setGatewayFailoverEnabled(_ enabled: Bool) async {
        guard !isShuttingDown else { return }
        let setting = enabled ? "已开启自动故障转移" : "已关闭自动故障转移"
        await applyGatewayConfiguration(
            mutating: { $0.gatewayFailover.enabled = enabled },
            progressMessage: "正在重启 Bifrost · \(setting)",
            successMessage: setting,
            failurePrefix: "更新故障转移设置失败"
        )
    }

    func addFailoverProvider(_ providerID: String) async {
        guard !isShuttingDown,
              let provider = config.providers.first(where: { $0.id == providerID }),
              !config.gatewayFailover.providerIds.contains(providerID) else { return }
        await applyGatewayConfiguration(
            mutating: { $0.gatewayFailover.providerIds.append(providerID) },
            progressMessage: "正在重启 Bifrost · 已加入 \(provider.name)",
            successMessage: "已将 \(provider.name) 加入故障转移队列",
            failurePrefix: "加入故障转移队列失败"
        )
    }

    func removeFailoverProvider(_ providerID: String) async {
        guard !isShuttingDown,
              config.gatewayFailover.providerIds.contains(providerID) else { return }
        let name = config.providers.first(where: { $0.id == providerID })?.name ?? providerID
        await applyGatewayConfiguration(
            mutating: { $0.gatewayFailover.providerIds.removeAll { $0 == providerID } },
            progressMessage: "正在重启 Bifrost · 已移出 \(name)",
            successMessage: "已将 \(name) 移出故障转移队列",
            failurePrefix: "移出故障转移队列失败"
        )
    }

    /// Moves one entry by a single position. Priority is the queue's whole meaning, so it is edited
    /// directly here rather than inherited from the provider list's own order.
    func moveFailoverProvider(_ providerID: String, offset: Int) async {
        guard !isShuttingDown, offset != 0 else { return }
        let queue = config.gatewayFailover.providerIds
        guard let index = queue.firstIndex(of: providerID) else { return }
        let target = index + offset
        guard queue.indices.contains(target) else { return }
        let name = config.providers.first(where: { $0.id == providerID })?.name ?? providerID
        await applyGatewayConfiguration(
            mutating: { proposed in
                guard let from = proposed.gatewayFailover.providerIds.firstIndex(of: providerID),
                      proposed.gatewayFailover.providerIds.indices.contains(from + offset)
                else { return }
                proposed.gatewayFailover.providerIds.remove(at: from)
                proposed.gatewayFailover.providerIds.insert(providerID, at: from + offset)
            },
            progressMessage: "正在重启 Bifrost · 队列顺序已更新",
            successMessage: "\(name) 现在是队列第 \(target + 1) 位",
            failurePrefix: "调整故障转移顺序失败"
        )
    }

    func setRequireToken(_ enabled: Bool) async {
        await applyGatewayCredentialConfiguration { next in
            next.requireToken = enabled
            if enabled { next.gatewayToken = Self.normalizeGatewayToken(next.gatewayToken) }
        }
    }

    func setGatewayToken(_ token: String) async {
        await applyGatewayCredentialConfiguration { next in
            next.gatewayToken = Self.normalizeGatewayToken(token)
        }
    }

    func generateGatewayToken() async {
        let token = Self.generateGatewayToken()
        await applyGatewayCredentialConfiguration { next in
            next.requireToken = true
            next.gatewayToken = token
        }
    }

    func setOpenAtLogin(_ enabled: Bool) async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            guard config.openAtLogin != enabled else { return }
            let previous = config
            var next = previous
            next.openAtLogin = enabled
            do {
                try launchAtLoginController.setEnabled(enabled)
                do {
                    try repository.save(next)
                } catch {
                    try? launchAtLoginController.setEnabled(previous.openAtLogin)
                    throw error
                }
                config = next
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func setTrayUsage(enabled: Bool, range: String) async {
        guard !isShuttingDown else { return }
        let persisted = await withConfigMutation(blockedValue: false) {
            guard !isShuttingDown else { return false }
            var next = config
            next.trayUsage.enabled = enabled
            next.trayUsage.range = ["1d", "7d", "30d", "all"].contains(range) ? range : "7d"
            return persistConfigLocked(next)
        }
        if persisted, enabled { await refreshUsageHistory() }
    }

    func setLanguage(_ language: String) async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            var next = config
            next.language = ["en", "zh", "zh-TW", "ja", "ko"].contains(language) ? language : nil
            persistConfigLocked(next)
        }
    }

    func setConversationFontSize(_ size: Int?) async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            var next = config
            next.convFontPx = size
            persistConfigLocked(next)
        }
    }

    func setHistoryActive(_ scope: String) async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            let allowed = scope == "all" || scope == "__imported__" || scope == "__trash__"
                || config.enabledHistoryDirs.contains(scope)
            guard allowed, config.historyActive != scope else { return }
            var next = config
            next.historyActive = scope
            if persistConfigLocked(next) {
                conversationStore.configure(config: config, importsRoot: importsRoot)
            }
        }
    }

    func historyDirectoryStatistics() async -> [HistoryDirectoryStatistic] {
        let configuration = HistoryConfiguration(
            historyDirs: config.historyDirs,
            active: "all",
            importsRoot: importsRoot
        )
        return await Task.detached(priority: .utility) {
            HistoryRepository(configuration: configuration).directoryStatistics()
        }.value
    }

    func setAutoUpdate(check: Bool? = nil, autoDownload: Bool? = nil) async {
        guard !isShuttingDown else { return }
        let persisted = await withConfigMutation(blockedValue: false) {
            guard !isShuttingDown else { return false }
            var next = config
            if let check { next.autoUpdate.check = check }
            if let autoDownload { next.autoUpdate.autoDownload = autoDownload }
            return persistConfigLocked(next)
        }
        guard persisted else { return }
        if updateMayRunAutomatically, check == true {
            Task { await applicationBecameVisible() }
        } else if updateMayRunAutomatically, autoDownload == true,
                  case .available = updateState {
            Task {
                await downloadUpdate()
                if case .staged(let staged) = updateState {
                    await handleAutomaticStagedUpdate(staged)
                }
            }
        }
    }

    func checkForUpdates() async {
        updateState = await updateService.check()
    }

    func downloadUpdate() async {
        updateState = await updateService.downloadAndStage()
    }

    func installUpdateAndRelaunch() async {
        let result = await updateService.installStaged()
        updateState = result
        guard case .installed(let installed) = result else { return }
        do {
            try updateRelaunchScheduler.scheduleRelaunch(
                of: installed.applicationURL,
                afterProcess: ProcessInfo.processInfo.processIdentifier
            )
            terminateAfterUpdate()
        } catch {
            _ = await updateService.rollbackInstalledUpdate()
            updateState = .manualDownload(
                installed.staged.release,
                reason: "更新已安全回滚，因为无法安排重启：\(error.localizedDescription)"
            )
        }
    }

    func relaunchInstalledUpdate() {
        guard case .installedAwaitingRestart(let installed) = updateState else { return }
        do {
            try updateRelaunchScheduler.scheduleRelaunch(
                of: installed.applicationURL,
                afterProcess: ProcessInfo.processInfo.processIdentifier
            )
            updateState = .installed(installed)
            terminateAfterUpdate()
        } catch {
            lastError = "无法安排更新重启：\(error.localizedDescription)"
        }
    }

    func applicationBecameVisible(at date: Date = Date()) async {
        guard updateMayRunAutomatically else { return }
        let outcome = await automaticUpdateLifecycle.applicationBecameVisible(
            at: date,
            checkEnabled: config.autoUpdate.check,
            autoDownload: config.autoUpdate.autoDownload
        )
        switch outcome {
        case .skipped:
            break
        case .state(let state):
            updateState = state
        case .restartPrompt(let staged):
            updateState = .staged(staged)
            await handleAutomaticStagedUpdate(staged)
        }
    }

    private func initializeUpdater() async {
        await updateService.finalizePreviousInstallation()
    }

    private func handleAutomaticStagedUpdate(_ staged: StagedUpdate) async {
        let prompt = UpdateRestartPrompt(
            language: AppLanguage(configValue: config.language),
            version: staged.release.version.description
        )
        let choice = if let automaticUpdatePrompt {
            await automaticUpdatePrompt(prompt)
        } else {
            Self.presentDefaultAutomaticUpdatePrompt(prompt)
        }
        switch choice {
        case .restartNow:
            await installUpdateAndRelaunch()
        case .later:
            let installed = await updateService.installStaged()
            guard case .installed = installed else {
                updateState = installed
                return
            }
            updateState = await updateService.markInstalledAwaitingRestart()
        }
    }

    private static func presentDefaultAutomaticUpdatePrompt(
        _ prompt: UpdateRestartPrompt
    ) -> UpdateRestartChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.restartButtonTitle)
        alert.addButton(withTitle: prompt.laterButtonTitle)
        return alert.runModal() == .alertFirstButtonReturn ? .restartNow : .later
    }

    func addHistoryDirectory(_ path: String) async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            var next = config
            next.historyDirs.append(path)
            guard persistConfigLocked(next) else { return }
            conversationStore.configure(config: config, importsRoot: importsRoot)
            configureUsageHistoryWatcher()
            scheduleUsageHistoryRefresh(invalidate: true, delayNanoseconds: 0)
        }
    }

    /// Switching a location off keeps its configuration and its catalog rows; the scanner, the
    /// watcher, the session list and search simply stop seeing it, and switching it back on picks
    /// up incrementally instead of rebuilding.
    func setHistoryDirectoryEnabled(_ path: String, _ enabled: Bool) async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown, config.historyDirs.contains(path) else { return }
            var next = config
            if enabled {
                next.disabledHistoryDirs.removeAll { $0 == path }
            } else if !next.disabledHistoryDirs.contains(path) {
                next.disabledHistoryDirs.append(path)
            } else {
                return
            }
            // The active scope may be the location that just went away.
            if !enabled, next.historyActive == path { next.historyActive = "all" }
            guard persistConfigLocked(next) else { return }
            conversationStore.configure(config: config, importsRoot: importsRoot)
            configureUsageHistoryWatcher()
            scheduleUsageHistoryRefresh(invalidate: true, delayNanoseconds: 0)
        }
    }

    func removeHistoryDirectory(_ path: String) async {
        guard path != "~/.claude", !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            var next = config
            next.historyDirs.removeAll { $0 == path }
            next.disabledHistoryDirs.removeAll { $0 == path }
            guard persistConfigLocked(next) else { return }
            conversationStore.configure(config: config, importsRoot: importsRoot)
            configureUsageHistoryWatcher()
            scheduleUsageHistoryRefresh(invalidate: true, delayNanoseconds: 0)
        }
    }

    func connectSelectedCLIs() async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            guard !config.providers.isEmpty else {
                lastError = "请先添加服务商"
                return
            }
            let targets = config.connectTargets.isEmpty
                ? [CLIConnectionManager.claudeTarget]
                : config.connectTargets
            do {
                config = try connectionManager.updateConnections(
                    config: config,
                    claude: targets.contains(CLIConnectionManager.claudeTarget) ? .connect : .unchanged,
                    codex: targets.contains(CLIConnectionManager.codexTarget) ? .connect : .unchanged
                )
                lastError = nil
            } catch {
                await handleCLIConnectionFailure(error)
            }
            refreshCLIConnectionStatus()
        }
    }

    func disconnectAllCLIs() async {
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            do {
                config = try connectionManager.updateConnections(
                    config: config,
                    claude: .disconnect,
                    codex: .disconnect
                )
                lastError = nil
            } catch {
                await handleCLIConnectionFailure(error)
            }
            refreshCLIConnectionStatus()
        }
    }

    /// Stops polling and the retained Bifrost child before AppKit completes application
    /// termination. This is deliberately idempotent because macOS may ask to terminate again
    /// while an async shutdown reply is pending.
    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        gatewayShouldBeRunning = false
        gatewayControlRequestGeneration &+= 1
        gatewayControlOperation = nil
        gatewayConfigurationOperation = nil
        gatewayOperationGeneration &+= 1
        gatewayStateMonitor?.cancel()
        gatewayStateMonitor = nil
        pluginRefreshGeneration &+= 1
        pluginCatalogLoading = false
        invalidateAllPluginExitMonitors()
        usageHistoryInvalidationTask?.cancel()
        usageHistoryInvalidationTask = nil
        usageHistoryWatcher?.invalidate()
        usageHistoryWatcher = nil
        usageHistoryWatchSignature = nil
        monitorStore.shutdown()
        conversationStore.deactivate()
        usageHistoryService.flushRecordCache()
        await usageHistoryService.invalidate()
        await pluginManager.shutdown()
        await supervisor.stop()
        gatewayState = .stopped
        monitorStore.configure(port: config.port, gatewayRunning: false)
    }

    func setConnectTarget(_ target: String, enabled: Bool) async {
        guard [CLIConnectionManager.claudeTarget, CLIConnectionManager.codexTarget].contains(target) else {
            return
        }
        guard !isShuttingDown else { return }
        await withConfigMutation {
            guard !isShuttingDown else { return }
            if enabled && config.providers.isEmpty {
                lastError = "请先添加服务商"
                return
            }
            do {
                switch (target, enabled) {
                case (CLIConnectionManager.claudeTarget, true):
                    config = try connectionManager.updateConnections(config: config, claude: .connect)
                case (CLIConnectionManager.claudeTarget, false):
                    config = try connectionManager.updateConnections(config: config, claude: .disconnect)
                case (CLIConnectionManager.codexTarget, true):
                    config = try connectionManager.updateConnections(config: config, codex: .connect)
                case (CLIConnectionManager.codexTarget, false):
                    config = try connectionManager.updateConnections(config: config, codex: .disconnect)
                default:
                    break
                }
                lastError = nil
            } catch {
                await handleCLIConnectionFailure(error)
            }
            refreshCLIConnectionStatus()
        }
    }

    /// Re-evaluates an explicit, user-completed manual recovery. Merely succeeding at an unrelated
    /// write never clears the latch: every durable journal must first be restored and removed, and
    /// the persisted application config must still be readable. The gateway remains stopped after a
    /// successful recheck so resuming service is always a separate user decision.
    func recheckCLIRecovery() async {
        guard !isShuttingDown else { return }
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard !isShuttingDown, let recoveryState = cliRecoveryState else { return }

        do {
            let pending = try connectionManager.pendingRecoveryJournalDirectories()
            guard pending.isEmpty else {
                activateCLIRecovery(
                    journalDirectories: pending,
                    detail: recoveryState.detail
                )
                return
            }
        } catch {
            activateCLIRecovery(
                journalDirectories: recoveryState.journalDirectories,
                detail: "\(recoveryState.detail)；重新检查恢复记录失败：\(error.localizedDescription)"
            )
            return
        }

        do {
            config = try repository.load()
        } catch {
            activateCLIRecovery(
                journalDirectories: [],
                detail: "\(recoveryState.detail)；恢复后的应用配置仍无法读取：\(error.localizedDescription)"
            )
            return
        }

        cliRecoveryState = nil
        forceGatewayStoppedIntent()
        gatewayState = .stopped
        monitorStore.configure(port: config.port, gatewayRunning: false)
        refreshCLIConnectionStatus()
        conversationStore.configure(config: config, importsRoot: importsRoot)
        if usageHistoryMayWatch {
            configureUsageHistoryWatcher()
            scheduleUsageHistoryRefresh(invalidate: true, delayNanoseconds: 0)
        }
        lastError = nil
    }

    private func persistAndRestartGateway(
        _ mutation: @escaping (inout AppConfig) -> Void
    ) async {
        await applyGatewayConfiguration(
            mutating: mutation,
            disableWhenProviderless: true,
            progressMessage: "正在应用服务商配置并重启 Bifrost",
            successMessage: "服务商配置已更新",
            failurePrefix: "应用服务商配置失败"
        )
    }

    private func configureUsageHistoryWatcher() {
        guard usageHistoryMayWatch, !isShuttingDown else { return }
        usageHistoryWatcher?.invalidate()
        usageHistoryWatcher = nil

        let fileManager = FileManager()
        let roots = usageHistoryConfiguration.activeRoots
        usageHistoryWatchSignature = usageHistoryRootIdentitySignature(roots: roots)
        let paths = roots.compactMap { root -> String? in
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return root.path
        }
        usageHistoryWatcher = UsageHistoryWatcher(paths: paths) { [weak self] rootsChanged in
            Task { @MainActor [weak self] in
                if rootsChanged { self?.configureUsageHistoryWatcher() }
                self?.scheduleUsageHistoryRefresh(invalidate: true)
            }
        }
    }

    private func usageHistoryRootIdentitySignature(
        roots: [URL]? = nil
    ) -> String {
        UsageHistoryRootIdentity.signature(
            roots: roots ?? usageHistoryConfiguration.activeRoots
        )
    }

    /// Fewest scans that still keep the numbers honest.
    ///
    /// The previous shape cancelled whatever was in flight and started over on every file-system
    /// event. With agents appending to their transcripts every few seconds, scans were killed
    /// mid-corpus and restarted from scratch indefinitely: the record cache was never committed,
    /// the summaries never updated, and one core stayed busy re-reading the same megabytes. One
    /// serialized worker lets each scan finish; changes that arrive meanwhile coalesce into a
    /// single follow-up, spaced so a chatty producer costs bounded background work.
    static let minimumInvalidatingUsageRefreshInterval: TimeInterval = 10

    private func scheduleUsageHistoryRefresh(
        invalidate: Bool,
        delayNanoseconds: UInt64 = 350_000_000
    ) {
        guard !isShuttingDown else { return }
        usageHistoryRefreshQueued = true
        usageHistoryRefreshWantsInvalidate = usageHistoryRefreshWantsInvalidate || invalidate
        guard usageHistoryInvalidationTask == nil else { return }
        usageHistoryInvalidationTask = Task { @MainActor [weak self] in
            defer { self?.usageHistoryInvalidationTask = nil }
            while let self, !Task.isCancelled, !self.isShuttingDown,
                  self.usageHistoryRefreshQueued {
                if delayNanoseconds > 0 {
                    do { try await Task.sleep(nanoseconds: delayNanoseconds) }
                    catch { return }
                }
                if self.usageHistoryRefreshWantsInvalidate,
                   let last = self.lastInvalidatingUsageRefreshAt {
                    let wait = Self.minimumInvalidatingUsageRefreshInterval
                        - Date().timeIntervalSince(last)
                    if wait > 0 {
                        do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                        catch { return }
                    }
                }
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.usageHistoryRefreshQueued = false
                let shouldInvalidate = self.usageHistoryRefreshWantsInvalidate
                self.usageHistoryRefreshWantsInvalidate = false
                if shouldInvalidate { self.lastInvalidatingUsageRefreshAt = Date() }
                await self.refreshUsageHistory(invalidate: shouldInvalidate)
            }
        }
    }

    private func refreshPlugins(
        reconcileProviders: Bool,
        restartRunningGateway: Bool
    ) async {
        guard !isShuttingDown else { return }
        pluginRefreshGeneration &+= 1
        let refreshGeneration = pluginRefreshGeneration
        pluginCatalogLoading = true
        let snapshot = await pluginManager.catalog(
            ensureRuntimeRecords: pluginMayMutateState && cliRecoveryState == nil
        )
        guard !isShuttingDown, refreshGeneration == pluginRefreshGeneration else { return }

        // Merge update discovery from the latest published catalog, not from the value that existed
        // before this async request. An update check may have completed while catalog I/O was in flight.
        let priorItems = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        plugins = snapshot.items.map { item in
            var merged = item
            if let prior = priorItems[item.id], prior.version == item.version {
                merged.latestVersion = prior.latestVersion
                merged.updateAvailable = prior.updateAvailable
            }
            return merged
        }
        pluginIssues = snapshot.issues
        pluginCatalogLoading = false
        synchronizePluginExitMonitors()

        if reconcileProviders, pluginMayMutateState {
            await reconcilePluginProviders(
                restartRunningGateway: restartRunningGateway,
                refreshGeneration: refreshGeneration
            )
        }
    }

    private func setPluginEnabled(
        _ id: String,
        enabled: Bool,
        announceSuccess: Bool
    ) async {
        guard canBeginPluginOperation(id) else { return }
        let wasActive = config.providers.first(where: { $0.id == config.activeProviderId })?.pluginId == id
        if !enabled { invalidatePluginExitMonitor(id: id) }
        pluginBusyIDs.insert(id)
        defer { pluginBusyIDs.remove(id) }

        do {
            _ = try await pluginManager.setEnabled(id: id, enabled: enabled)
            await refreshPlugins(reconcileProviders: true)
            if !enabled && wasActive {
                await selectSafeFallback(excludingPluginID: id)
            }
            if announceSuccess {
                showPluginMessage(enabled ? "插件已启用" : "插件已停用", style: .success)
            }
        } catch {
            await refreshPlugins(reconcileProviders: false)
            if enabled && wasActive {
                await selectSafeFallback(excludingPluginID: id)
            }
            showPluginError(error, prefix: enabled ? "启用插件失败" : "停用插件失败")
        }
    }

    private func reconcilePluginProviders(
        restartRunningGateway: Bool,
        refreshGeneration: UInt64
    ) async {
        // Capture the catalog result, but merge it into the latest config only after acquiring the
        // mutation gate. A running provider edit may still be awaiting sidecar shutdown here; a
        // provider array derived before the gate would overwrite that newer edit when it commits.
        let pluginSnapshot = plugins

        if restartRunningGateway {
            await applyGatewayConfiguration(
                mutating: { candidate in
                    self.reconcilePluginProviders(in: &candidate, pluginSnapshot: pluginSnapshot)
                },
                disableWhenProviderless: true,
                configurationIsCurrent: { [self] in
                    refreshGeneration == pluginRefreshGeneration
                },
                progressMessage: "正在应用插件服务配置并重启 Bifrost",
                successMessage: "插件服务配置已更新",
                failurePrefix: "保存插件服务失败"
            )
        } else {
            await withConfigMutation {
                guard !isShuttingDown,
                      refreshGeneration == pluginRefreshGeneration else { return }
                var candidate = config
                self.reconcilePluginProviders(in: &candidate, pluginSnapshot: pluginSnapshot)
                if candidate != config { persistConfigLocked(candidate) }
            }
        }
    }

    private func reconcilePluginProviders(
        in candidate: inout AppConfig,
        pluginSnapshot: [PluginCatalogItem]
    ) {
        let installedIDs = Set(pluginSnapshot.map(\.id))
        let derived = pluginSnapshot.compactMap(\.provider)
        let derivedByID = Dictionary(uniqueKeysWithValues: derived.map { ($0.id, $0) })
        var consumed = Set<String>()
        var providers: [Provider] = []

        for existing in candidate.providers {
            if let descriptor = derivedByID[existing.id] {
                providers.append(provider(from: descriptor))
                consumed.insert(descriptor.id)
            } else if existing.backend == .plugin {
                if let pluginID = existing.pluginId, installedIDs.contains(pluginID) {
                    // Keep a prior derived provider if an unusual runtime-port allocation failure
                    // prevents refreshing it. Installed plugins must remain visible while stopped.
                    providers.append(existing)
                }
            } else {
                providers.append(existing)
            }
        }
        for descriptor in derived where !consumed.contains(descriptor.id) {
            providers.append(provider(from: descriptor))
        }

        candidate.providers = providers
        if let activeID = candidate.activeProviderId,
           !providers.contains(where: { $0.id == activeID }) {
            candidate.activeProviderId = safeFallbackProvider(
                in: providers,
                pluginSnapshot: pluginSnapshot
            )?.id
        } else if candidate.activeProviderId == nil {
            candidate.activeProviderId = safeFallbackProvider(
                in: providers,
                pluginSnapshot: pluginSnapshot
            )?.id
        }
    }

    private func provider(from descriptor: PluginDerivedProvider) -> Provider {
        Provider(
            id: descriptor.id,
            name: descriptor.name,
            baseUrl: descriptor.baseURL.absoluteString,
            authToken: "",
            defaultModel: descriptor.defaultModel,
            smallFastModel: descriptor.smallFastModel,
            mapDefaultModels: true,
            protocol: Provider.WireProtocol(rawValue: descriptor.protocolName) ?? .openAIResponses,
            models: [],
            icon: descriptor.iconDataURI,
            backend: .plugin,
            pluginId: descriptor.pluginID
        )
    }

    private func safeFallbackProvider(
        in providers: [Provider]? = nil,
        excludingPluginID: String? = nil,
        pluginSnapshot: [PluginCatalogItem]? = nil
    ) -> Provider? {
        (providers ?? config.providers).first { provider in
            switch provider.backend {
            case .http:
                return true
            case .plugin:
                guard provider.pluginId != excludingPluginID,
                      let pluginID = provider.pluginId else { return false }
                return (pluginSnapshot ?? plugins)
                    .first(where: { $0.id == pluginID })?.isRunning == true
            }
        }
    }

    private func selectSafeFallback(excludingPluginID: String) async {
        let fallback = safeFallbackProvider(excludingPluginID: excludingPluginID)
        let nextID = fallback?.id
        guard config.activeProviderId != nextID else { return }
        await applyGatewayConfiguration(
            mutating: { $0.activeProviderId = nextID },
            disableWhenProviderless: true,
            progressMessage: "正在切换备用服务并重启 Bifrost",
            successMessage: nextID == nil ? "已停止没有可用服务商的网关" : "已切换备用服务",
            failurePrefix: "切换备用服务失败"
        )
    }

    private func synchronizePluginExitMonitors() {
        let runningIDs = Set(plugins.filter(\.isRunning).map(\.id))
        for id in pluginExitMonitors.keys where !runningIDs.contains(id) {
            invalidatePluginExitMonitor(id: id)
        }
        for id in runningIDs where pluginExitMonitors[id] == nil {
            startPluginExitMonitor(id: id)
        }
    }

    private func startPluginExitMonitor(id: String) {
        let token = UUID()
        pluginMonitorTokens[id] = token
        let manager = pluginManager
        pluginExitMonitors[id] = Task { [weak self] in
            let item = await manager.waitForExit(id: id)
            guard !Task.isCancelled else { return }
            await self?.handlePluginExit(id: id, token: token, item: item)
        }
    }

    private func invalidatePluginExitMonitor(id: String) {
        pluginMonitorTokens.removeValue(forKey: id)
        pluginExitMonitors.removeValue(forKey: id)?.cancel()
    }

    private func invalidateAllPluginExitMonitors() {
        pluginMonitorTokens.removeAll()
        let tasks = pluginExitMonitors.values
        pluginExitMonitors.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func handlePluginExit(
        id: String,
        token: UUID,
        item: PluginCatalogItem?
    ) async {
        guard !isShuttingDown, pluginMonitorTokens[id] == token else { return }
        pluginMonitorTokens.removeValue(forKey: id)
        pluginExitMonitors.removeValue(forKey: id)
        if let item, let index = plugins.firstIndex(where: { $0.id == id }) {
            var merged = item
            merged.latestVersion = plugins[index].latestVersion
            merged.updateAvailable = plugins[index].updateAvailable
            plugins[index] = merged
        } else {
            await refreshPlugins(reconcileProviders: false)
        }

        let name = plugins.first(where: { $0.id == id })?.name ?? id
        let reason = item?.failureMessage.map { "：\($0)" } ?? ""
        showPluginMessage("插件“\(name)”已停止\(reason)", style: .error)
        if config.providers.first(where: { $0.id == config.activeProviderId })?.pluginId == id {
            await selectSafeFallback(excludingPluginID: id)
        }
    }

    private func canBeginPluginOperation(_ id: String) -> Bool {
        guard pluginMayMutateState, !isShuttingDown,
              !reassertCLIRecoveryIfNeeded(),
              pluginGlobalOperation == nil,
              !pluginBusyIDs.contains(id) else { return false }
        return true
    }

    private func canBeginGlobalPluginOperation(_ operation: PluginGlobalOperation) -> Bool {
        guard pluginMayMutateState, !isShuttingDown,
              !reassertCLIRecoveryIfNeeded(),
              pluginGlobalOperation == nil,
              pluginBusyIDs.isEmpty else { return false }
        return true
    }

    private func showPluginMessage(
        _ message: String,
        style: PluginAlert.Style,
        localizesMessage: Bool = true
    ) {
        pluginAlert = .init(
            message: message,
            style: style,
            localizesMessage: localizesMessage
        )
    }

    private func showPluginError(_ error: Error, prefix: String) {
        let detail = String(PluginSecretRedactor().redact(error.localizedDescription).prefix(512))
        showPluginMessage("\(prefix)：\(detail)", style: .error)
        lastError = detail
    }

    @discardableResult
    private func persistConfigLocked(_ next: AppConfig) -> Bool {
        guard !reassertCLIRecoveryIfNeeded() else { return false }
        var next = next
        next.normalize()
        do {
            try repository.save(next)
            config = next
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func withConfigMutation(_ operation: () async -> Void) async {
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard !reassertCLIRecoveryIfNeeded() else { return }
        await operation()
    }

    private func withConfigMutation<T>(
        blockedValue: T,
        _ operation: () async -> T
    ) async -> T {
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard !reassertCLIRecoveryIfNeeded() else { return blockedValue }
        return await operation()
    }

    private struct ManagedCLIConnections {
        let claude: CLIConnectionManager.ConnectionUpdate
        let codex: CLIConnectionManager.ConnectionUpdate
    }

    private func managedCLIConnections(in config: AppConfig) -> ManagedCLIConnections {
        // Persisted selection plus a backup is the ownership record. Endpoint shape alone is not
        // ownership: another local proxy may legitimately use the same host and path.
        ManagedCLIConnections(
            claude: config.connectTargets.contains(CLIConnectionManager.claudeTarget)
                && config.claudeBackup.objectValue != nil ? .connect : .unchanged,
            codex: config.connectTargets.contains(CLIConnectionManager.codexTarget)
                && config.codexBackup.objectValue != nil ? .connect : .unchanged
        )
    }

    private func persistGatewayConfiguration(
        _ candidate: AppConfig,
        managedConnections: ManagedCLIConnections,
        refreshManagedCLIConnections: Bool
    ) throws -> AppConfig {
        if refreshManagedCLIConnections {
            return try connectionManager.updateConnections(
                config: candidate,
                claude: managedConnections.claude,
                codex: managedConnections.codex
            )
        }
        try repository.save(candidate)
        return candidate
    }

    private func preflightGatewayConfiguration(_ candidate: AppConfig) throws {
        let logDatabaseURL = repository.configURL.deletingLastPathComponent()
            .appendingPathComponent("bifrost", isDirectory: true)
            .appendingPathComponent("logs.db")
        _ = try BifrostConfigBuilder.build(
            from: candidate,
            logDatabaseURL: logDatabaseURL,
            managementCredentials: supervisor.managementCredentials
        )
    }

    /// Reconfigures the persisted gateway and its running generation as one serialized operation.
    /// The old generation is stopped before credential-bearing CLI files change, and a failed
    /// replacement restores both the previous persisted state and the previously healthy runtime.
    @discardableResult
    private func applyGatewayConfiguration(
        mutating mutation: (inout AppConfig) -> Void,
        refreshManagedCLIConnections: Bool = false,
        disableWhenProviderless: Bool = false,
        configurationIsCurrent: (() -> Bool)? = nil,
        progressMessage: String,
        successMessage: String,
        failurePrefix: String
    ) async -> Bool {
        guard !isShuttingDown else { return false }
        await configMutationGate.acquire()
        defer { configMutationGate.release() }
        guard !isShuttingDown, !reassertCLIRecoveryIfNeeded() else { return false }
        guard configurationIsCurrent?() ?? true else { return false }
        let operation = beginGatewayOperation()
        gatewayConfigurationOperation = operation
        defer {
            if gatewayConfigurationOperation == operation {
                gatewayConfigurationOperation = nil
            }
        }

        var proposed = config
        mutation(&proposed)
        return await applyGatewayConfigurationLocked(
            proposed,
            operation: operation,
            refreshManagedCLIConnections: refreshManagedCLIConnections,
            disableWhenProviderless: disableWhenProviderless,
            configurationIsCurrent: configurationIsCurrent,
            progressMessage: progressMessage,
            successMessage: successMessage,
            failurePrefix: failurePrefix
        )
    }

    @discardableResult
    private func applyGatewayConfigurationLocked(
        _ proposed: AppConfig,
        operation: UInt64,
        refreshManagedCLIConnections: Bool,
        disableWhenProviderless: Bool,
        configurationIsCurrent: (() -> Bool)?,
        progressMessage: String,
        successMessage: String,
        failurePrefix: String
    ) async -> Bool {
        guard isCurrentGatewayOperation(operation), !isShuttingDown,
              configurationIsCurrent?() ?? true else { return false }

        let previous = config
        let previousGatewayState = gatewayState
        let previousLastError = lastError
        let runtimeWasActive = gatewayShouldBeRunning
        let managedConnections = managedCLIConnections(in: previous)
        var next = proposed
        next.normalize()
        if runtimeWasActive, next.activeProvider != nil {
            // Preserve the launch setting for a live generation, including a manual start that
            // has not otherwise changed the persisted gateway switch.
            next.gatewayEnabled = true
        }
        if disableWhenProviderless, next.providers.isEmpty {
            next.activeProviderId = nil
            next.gatewayEnabled = false
        }
        guard next != previous else { return true }
        if runtimeWasActive, next.activeProvider != nil {
            do {
                try preflightGatewayConfiguration(next)
            } catch {
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                let detail = Self.publicGatewayMessage(error)
                lastError = detail
                monitorStore.appendLifecycle(
                    level: .error,
                    message: "\(failurePrefix) · \(detail)"
                )
                return false
            }
        }

        if runtimeWasActive {
            monitorStore.appendLifecycle(level: .info, message: progressMessage)
            monitorStore.configure(port: previous.port, gatewayRunning: false)
            await supervisor.stop()
            guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
            gatewayState = .stopped
        }

        var didPersistNext = false
        do {
            guard configurationIsCurrent?() ?? true else {
                throw AppModelConfigurationSupersededError()
            }
            let committed = try persistGatewayConfiguration(
                next,
                managedConnections: managedConnections,
                refreshManagedCLIConnections: refreshManagedCLIConnections
            )
            didPersistNext = true
            config = committed

            guard committed.activeProvider != nil else {
                gatewayShouldBeRunning = false
                gatewayState = .stopped
                monitorStore.configure(port: committed.port, gatewayRunning: false)
                refreshCLIConnectionStatus()
                monitorStore.appendLifecycle(level: .info, message: successMessage)
                lastError = nil
                return true
            }

            if runtimeWasActive, gatewayShouldBeRunning {
                gatewayState = .starting
                monitorStore.configure(port: committed.port, gatewayRunning: false)
                try await supervisor.start(config: committed)
                await gatewayStartupVerificationHook?()
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                guard configurationIsCurrent?() ?? true else {
                    throw AppModelConfigurationSupersededError()
                }
                let supervisorState = await supervisor.state
                guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                guard configurationIsCurrent?() ?? true else {
                    throw AppModelConfigurationSupersededError()
                }
                let runningState = try confirmedRunningGatewayState(supervisorState)
                if gatewayShouldBeRunning {
                    gatewayState = runningState
                } else {
                    await supervisor.stop()
                    guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                    guard configurationIsCurrent?() ?? true else {
                        throw AppModelConfigurationSupersededError()
                    }
                    gatewayState = .stopped
                }
            }

            monitorStore.configure(port: committed.port, gatewayRunning: gatewayState.isRunning)
            refreshCLIConnectionStatus()
            monitorStore.appendLifecycle(level: .info, message: successMessage)
            lastError = nil
            return true
        } catch {
            guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
            let configurationWasSuperseded = error is AppModelConfigurationSupersededError
            let failureDetail = Self.publicGatewayMessage(error)
            if let rollbackFailure = Self.rollbackFailure(error) {
                config = (try? repository.load()) ?? config
                await enterCLIRecovery(rollbackFailure, detail: failureDetail)
                monitorStore.appendLifecycle(
                    level: .error,
                    message: "\(failurePrefix) · \(failureDetail)"
                )
                return false
            }
            var recoveryFailure: String?

            if didPersistNext {
                do {
                    config = try persistGatewayConfiguration(
                        previous,
                        managedConnections: managedConnections,
                        refreshManagedCLIConnections: refreshManagedCLIConnections
                    )
                } catch {
                    if let rollbackFailure = Self.rollbackFailure(error) {
                        let recoveryDetail = Self.publicGatewayMessage(error)
                        config = (try? repository.load()) ?? config
                        let detail = "\(failureDetail)；恢复先前状态失败：\(recoveryDetail)"
                        await enterCLIRecovery(rollbackFailure, detail: detail)
                        monitorStore.appendLifecycle(
                            level: .error,
                            message: "\(failurePrefix) · \(detail)"
                        )
                        return false
                    }
                    recoveryFailure = String(error.localizedDescription.prefix(512))
                    config = (try? repository.load()) ?? next
                    forceGatewayStoppedIntent()
                }
            } else {
                config = previous
            }

            if recoveryFailure == nil, runtimeWasActive, gatewayShouldBeRunning,
               previous.activeProvider != nil {
                do {
                    gatewayState = .starting
                    monitorStore.configure(port: previous.port, gatewayRunning: false)
                    try await supervisor.start(config: previous)
                    await gatewayStartupVerificationHook?()
                    guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                    let restoredState = await supervisor.state
                    guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                    let runningState = try confirmedRunningGatewayState(restoredState)
                    if gatewayShouldBeRunning {
                        gatewayState = runningState
                    } else {
                        await supervisor.stop()
                        guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                        gatewayState = .stopped
                    }
                } catch {
                    guard isCurrentGatewayOperation(operation), !isShuttingDown else { return false }
                    if gatewayShouldBeRunning {
                        recoveryFailure = Self.publicGatewayMessage(error)
                        forceGatewayStoppedIntent()
                        gatewayState = .failed("无法恢复先前的 Bifrost 服务")
                    } else {
                        gatewayState = .stopped
                    }
                }
            } else if runtimeWasActive {
                gatewayState = gatewayShouldBeRunning ? .failed(failureDetail) : .stopped
            } else {
                gatewayState = previousGatewayState
            }

            monitorStore.configure(port: config.port, gatewayRunning: gatewayState.isRunning)
            refreshCLIConnectionStatus()
            if configurationWasSuperseded, recoveryFailure == nil {
                lastError = previousLastError
                return false
            }
            let detail = recoveryFailure.map {
                "\(failureDetail)；恢复先前状态失败：\($0)"
            } ?? failureDetail
            lastError = detail
            monitorStore.appendLifecycle(level: .error, message: "\(failurePrefix) · \(detail)")
            return false
        }
    }

    private func applyGatewayCredentialConfiguration(
        _ mutation: @escaping (inout AppConfig) -> Void
    ) async {
        await applyGatewayConfiguration(
            mutating: mutation,
            refreshManagedCLIConnections: true,
            progressMessage: "正在安全更新网关访问令牌",
            successMessage: "网关访问令牌设置已更新",
            failurePrefix: "更新网关访问令牌失败"
        )
    }

    private static func generateGatewayToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return "sk-bf-ccbud-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return "sk-bf-ccbud-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeGatewayToken(_ rawToken: String) -> String {
        normalizeInferenceToken(rawToken) ?? generateGatewayToken()
    }

    private static func rollbackFailure(_ error: Error) -> CLIConnectionError? {
        guard let connectionError = error as? CLIConnectionError,
              case .rollbackFailed = connectionError else { return nil }
        return connectionError
    }

    private func recordPendingCLIRecovery(journalDirectories: [URL]) {
        activateCLIRecovery(
            journalDirectories: journalDirectories,
            detail: Self.pendingCLIRecoveryDetail(journalDirectories)
        )
    }

    private func recordPendingCLIRecoveryInspectionFailure(_ error: Error) {
        activateCLIRecovery(
            journalDirectories: [connectionManager.recoveryRootURL],
            detail: "无法检查 CLI 配置恢复记录：\(error.localizedDescription)"
        )
    }

    private func recordCLIRecovery(_ error: CLIConnectionError, detail: String) {
        guard case .rollbackFailed(_, let recoveryDirectory) = error else { return }
        var directories = (try? connectionManager.pendingRecoveryJournalDirectories()) ?? []
        if !directories.contains(where: {
            $0.standardizedFileURL == recoveryDirectory.standardizedFileURL
        }) {
            directories.append(recoveryDirectory)
        }
        activateCLIRecovery(journalDirectories: directories, detail: detail)
    }

    private func activateCLIRecovery(journalDirectories: [URL], detail: String) {
        var seenPaths = Set<String>()
        let directories = journalDirectories.compactMap { directory -> URL? in
            let standardized = directory.standardizedFileURL
            return seenPaths.insert(standardized.path).inserted ? standardized : nil
        }.sorted { $0.path < $1.path }
        cliRecoveryState = .init(journalDirectories: directories, detail: detail)
        forceGatewayStoppedIntent()
        gatewayState = .failed("CLI 配置恢复不完整，需要手动恢复")
        monitorStore.configure(port: config.port, gatewayRunning: false)
        lastError = detail
        refreshCLIConnectionStatus()
    }

    private func enterCLIRecovery(_ error: CLIConnectionError, detail: String) async {
        config = (try? repository.load()) ?? config
        recordCLIRecovery(error, detail: detail)
        await supervisor.stop()
        guard !isShuttingDown else { return }
        _ = reassertCLIRecoveryIfNeeded()
    }

    private func handleCLIConnectionFailure(_ error: Error) async {
        guard let rollbackFailure = Self.rollbackFailure(error) else {
            lastError = error.localizedDescription
            return
        }
        await enterCLIRecovery(
            rollbackFailure,
            detail: rollbackFailure.localizedDescription
        )
    }

    @discardableResult
    private func reassertCLIRecoveryIfNeeded() -> Bool {
        guard let recoveryState = cliRecoveryState else { return false }
        forceGatewayStoppedIntent()
        gatewayState = .failed("CLI 配置恢复不完整，需要手动恢复")
        monitorStore.configure(port: config.port, gatewayRunning: false)
        lastError = recoveryState.detail
        return true
    }

    private static func pendingCLIRecoveryDetail(_ directories: [URL]) -> String {
        let paths = directories.map(\.standardizedFileURL.path).joined(separator: ", ")
        return "检测到未完成的 CLI 配置恢复记录：\(paths)。请先按照 journal.json 恢复原始文件并移除恢复目录"
    }

    private func confirmedRunningGatewayState(
        _ supervisorState: BifrostGatewayState
    ) throws -> BifrostGatewayState {
        // The state observer may win the main-actor race after start() reports health but before this
        // operation resumes. Do not replace that authoritative failure with a success publication.
        if case .failed(let detail) = gatewayState {
            throw AppModelGatewayStartupStateError(detail: detail)
        }
        let publicState = Self.publicGatewayState(supervisorState)
        guard publicState.isRunning else {
            let detail = if case .failed(let detail) = publicState {
                detail
            } else {
                "Bifrost 服务不可用"
            }
            throw AppModelGatewayStartupStateError(detail: detail)
        }
        return publicState
    }

    private func beginGatewayControlRequest(shouldRun: Bool) -> UInt64 {
        gatewayControlRequestGeneration &+= 1
        gatewayShouldBeRunning = shouldRun
        return gatewayControlRequestGeneration
    }

    private func isCurrentGatewayControlRequest(_ generation: UInt64) -> Bool {
        generation == gatewayControlRequestGeneration
    }

    private func forceGatewayStoppedIntent() {
        gatewayControlRequestGeneration &+= 1
        gatewayShouldBeRunning = false
    }

    private func beginGatewayOperation() -> UInt64 {
        gatewayOperationGeneration &+= 1
        return gatewayOperationGeneration
    }

    private func isCurrentGatewayOperation(_ generation: UInt64) -> Bool {
        generation == gatewayOperationGeneration
    }

    private func observeGatewayStateChanges() {
        let changes = supervisor.stateChanges
        gatewayStateMonitor = Task { [weak self] in
            for await state in changes {
                guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
                let authoritativeState = await self.supervisor.state
                guard !Task.isCancelled, !self.isShuttingDown,
                      state == authoritativeState else { continue }
                if let recoveryState = self.cliRecoveryState {
                    self.gatewayState = .failed("CLI 配置恢复不完整，需要手动恢复")
                    self.monitorStore.configure(port: self.config.port, gatewayRunning: false)
                    self.lastError = recoveryState.detail
                    continue
                }
                let previous = self.gatewayState
                let publicState = Self.publicGatewayState(state)
                if case .stopped = publicState {
                    if self.gatewayShouldBeRunning { continue }
                    if case .failed = previous { continue }
                }
                self.gatewayState = publicState
                self.monitorStore.configure(
                    port: self.config.port,
                    gatewayRunning: publicState.isRunning
                )
                if previous.isRunning, case .failed(let message) = publicState,
                   self.gatewayControlOperation == nil,
                   self.gatewayConfigurationOperation == nil {
                    // A registered operation owns startup/replacement failure handling, including
                    // rollback. Only an otherwise-unexpected exit revokes the durable run intent.
                    self.gatewayShouldBeRunning = false
                    self.monitorStore.appendLifecycle(
                        level: .error,
                        message: "Bifrost 运行异常 · \(message)"
                    )
                    self.lastError = message
                }
            }
        }
    }

    private static func publicGatewayMessage(_ error: Error) -> String {
        if let connectionError = error as? CLIConnectionError,
           case .rollbackFailed = connectionError {
            // This text is assembled entirely by the app and ends with the private recovery
            // journal path. Truncating it can remove the only actionable recovery location.
            return connectionError.localizedDescription
        }
        if let bifrostError = error as? BifrostError,
           case .startupFailed(let reason, _) = bifrostError {
            return String(reason.prefix(512))
        }
        return String(error.localizedDescription.prefix(512))
    }

    private static func publicGatewayState(_ state: BifrostGatewayState) -> BifrostGatewayState {
        guard case .failed(let message) = state else { return state }
        let reason = message.components(separatedBy: "\n\n").first ?? "Bifrost 服务不可用"
        return .failed(String(reason.prefix(512)))
    }

    private func refreshCLIConnectionStatus() {
        claudeAvailable = connectionManager.isClaudeAvailable
        codexAvailable = connectionManager.isCodexAvailable
        claudeConnected = connectionManager.isClaudeConnected(port: config.port)
        codexConnected = connectionManager.isCodexConnected(port: config.port)
    }
}
