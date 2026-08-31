import AppKit
import Darwin

private enum AppSelfCheckError: LocalizedError {
    case uiUnavailable
    case gatewayCleanupFailed

    var errorDescription: String? {
        switch self {
        case .uiUnavailable: "Self-check UI controller is unavailable"
        case .gatewayCleanupFailed: "Self-check gateway did not release its process readers"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private weak var mainWindow: NSWindow?
    private var menuBarController: MenuBarController?
    private var didFinishLaunching = false
    private var pendingMainWindowPresentation = false
    private var terminationInProgress = false
    private var observesWindowVisibility = false
    private var selfCheckTask: Task<Void, Never>?
    private var selfCheckExitCode: Int32?
    private let instanceCoordinator: ApplicationInstanceCoordinator?

    override init() {
        let mode = AppModel.processRuntimeMode(environment: ProcessInfo.processInfo.environment)
        if mode == .application,
           LegacyBundleNameMigrator.migrateCurrentProcess() == .relaunched {
            Darwin.exit(0)
        }
        instanceCoordinator = mode == .application ? .shared : nil
        super.init()
    }

    private var isPrimaryInstance: Bool {
        instanceCoordinator?.isPrimaryInstance ?? true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let instanceCoordinator else { return }
        if instanceCoordinator.isPrimaryInstance {
            instanceCoordinator.beginObservingActivation { [weak self] in
                self?.showMainWindow()
            }
        } else {
            instanceCoordinator.notifyPrimaryInstance()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isPrimaryInstance else {
            NSApp.terminate(nil)
            return
        }
        didFinishLaunching = true
        NSApp.setActivationPolicy(.regular)
        beginObservingWindowVisibilityIfNeeded()
        configureMenuBarIfReady()
        notifyUpdaterApplicationBecameVisible()
    }

    func attach(model: AppModel) {
        guard isPrimaryInstance else { return }
        self.model = model
        beginObservingWindowVisibilityIfNeeded()
        configureMenuBarIfReady()
        if didFinishLaunching { notifyUpdaterApplicationBecameVisible() }
    }

    func registerMainWindow(_ window: NSWindow) {
        guard isPrimaryInstance, !(window is MenuBarPanel) else { return }
        mainWindow = window
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(hideMainWindow(_:))
        }
        if pendingMainWindowPresentation { showMainWindow() }
        if window.isVisible { notifyUpdaterApplicationBecameVisible() }
        startSelfCheckIfReady()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        notifyUpdaterApplicationBecameVisible()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidHide(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isPrimaryInstance, let model else { return .terminateNow }
        // The packaged self-check awaits AppModel.shutdown() before requesting termination.
        // Returning .terminateLater here would enqueue another main-actor cleanup task while
        // NSApplication.terminate(_:) is synchronously waiting on this same actor.
        if selfCheckExitCode != nil { return .terminateNow }
        if terminationInProgress { return .terminateLater }
        terminationInProgress = true
        menuBarController?.hidePanel()
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if observesWindowVisibility {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            observesWindowVisibility = false
        }
        menuBarController?.invalidate()
        menuBarController = nil
        selfCheckTask = nil
        if let selfCheckExitCode {
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(selfCheckExitCode)
        }
    }

    @objc private func hideMainWindow(_ sender: Any?) {
        pendingMainWindowPresentation = false
        menuBarController?.hidePanel()
        mainWindow?.orderOut(sender)
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }

    private func showMainWindow() {
        guard isPrimaryInstance else { return }
        pendingMainWindowPresentation = true
        menuBarController?.hidePanel()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)

        let window = mainWindow ?? NSApp.windows.first(where: {
            !($0 is MenuBarPanel) && $0.canBecomeMain
        })
        guard let window else {
            NSApp.activate(ignoringOtherApps: true)
            notifyUpdaterApplicationBecameVisible()
            return
        }
        mainWindow = window
        pendingMainWindowPresentation = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        notifyUpdaterApplicationBecameVisible()
    }

    private func beginObservingWindowVisibilityIfNeeded() {
        guard !observesWindowVisibility else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        observesWindowVisibility = true
    }

    @objc private func windowDidBecomeVisible(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        notifyUpdaterApplicationBecameVisible()
    }

    private func notifyUpdaterApplicationBecameVisible() {
        guard let model else { return }
        Task { await model.applicationBecameVisible() }
    }

    private func configureMenuBarIfReady() {
        guard didFinishLaunching, let model else { return }
        if menuBarController == nil {
            menuBarController = MenuBarController(
                model: model,
                showMainWindow: { [weak self] in self?.showMainWindow() },
                requestQuit: { NSApp.terminate(nil) }
            )
        }
        startSelfCheckIfReady()
    }

    private func startSelfCheckIfReady() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[SelfCheckEnvironmentGate.enabledKey] == "1",
              selfCheckTask == nil,
              didFinishLaunching,
              model != nil,
              mainWindow != nil,
              menuBarController != nil else { return }

        var normalizedEnvironment = environment
        if case .enabled(let request) = SelfCheckEnvironmentGate.evaluate(
            environment: environment
        ) {
            normalizedEnvironment[SelfCheckEnvironmentGate.homeKey] = request.homeDirectory.path
            if let outputURL = request.outputURL {
                normalizedEnvironment[SelfCheckEnvironmentGate.outputKey] = outputURL.path
            }
        }
        let gatewaySupervisor = BifrostSupervisor(environment: normalizedEnvironment)
        let gatewayPort = Result {
            try PluginDeterministicPortAllocator().allocate(
                pluginID: "dev.ccbud.packaged-self-check",
                preferred: nil,
                reserved: []
            )
        }
        let gatewayProbe = SelfCheckGatewayProbe(
            start: {
                var config = AppConfig.fixture
                config.port = Int(try gatewayPort.get())
                config.gatewayEnabled = true
                try await gatewaySupervisor.start(config: config)
            },
            health: {
                await gatewaySupervisor.state.isRunning
            },
            stop: {
                await gatewaySupervisor.stop()
                let stoppedState = await gatewaySupervisor.state
                let hasActiveReaders = await gatewaySupervisor.hasActiveOutputReaders
                guard stoppedState == .stopped, !hasActiveReaders else {
                    throw AppSelfCheckError.gatewayCleanupFailed
                }
            }
        )
        let runner = SelfCheckRunner.live(
            uiProbe: { [weak self] in
                guard let self, let menuBarController = self.menuBarController else {
                    throw AppSelfCheckError.uiUnavailable
                }
                return await menuBarController.selfCheckUISnapshot(mainWindow: self.mainWindow)
            },
            uiRequirement: .required,
            gatewayProbe: gatewayProbe,
            gatewayRequirement: .required
        )

        selfCheckTask = Task { @MainActor [weak self] in
            let outcome = await runner.runIfRequested(environment: environment)
            guard let self else { return }
            switch outcome {
            case .disabled:
                self.selfCheckTask = nil
            case .completed(let execution):
                // NSApplication.terminate(_:) synchronously waits when its delegate returns
                // .terminateLater. Because this completion already runs on the main actor,
                // asking AppKit to terminate before awaiting shutdown would prevent the
                // termination task in applicationShouldTerminate(_:) from ever running.
                await self.model?.shutdown()
                self.selfCheckExitCode = execution.exitCode
                // Use the regular AppKit termination path so applicationWillTerminate performs
                // controller cleanup and preserves the self-check's process exit code.
                NSApp.terminate(nil)
            }
        }
    }
}
