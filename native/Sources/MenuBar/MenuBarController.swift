import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let showMainWindow: () -> Void
    private let requestQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var contextMenu: NSMenu?

    init(
        model: AppModel,
        showMainWindow: @escaping () -> Void,
        requestQuit: @escaping () -> Void
    ) {
        self.model = model
        self.showMainWindow = showMainWindow
        self.requestQuit = requestQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = MenuBarPanel(language: model.appLanguage, themeMode: model.themeMode)
        super.init()

        configureStatusItem()
        configurePanel()
        observeState()
        updateStatusItem()
        Task { await model.refreshUsageHistory() }
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeEventMonitors()
    }

    /// Opens the real non-activating panel long enough for packaged self-check to capture the
    /// status item, selected screen, and final clamped panel geometry. The panel is hidden again
    /// before the probe returns so automation cannot leave menu-bar UI behind.
    func selfCheckUISnapshot(mainWindow: NSWindow?) async -> SelfCheckUISnapshot {
        defer { hidePanel() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var statusFrame: NSRect?
        var panelFrame: NSRect?
        var screen: NSScreen?
        repeat {
            if !panel.isVisible { showPanel() }
            mainWindow?.displayIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()

            statusFrame = statusItem.button.flatMap { button in
                guard let window = button.window else { return nil }
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }
            screen = statusItem.button?.window?.screen ?? panel.screen
            panelFrame = panel.isVisible ? panel.frame : nil

            if let statusFrame, let panelFrame, let screen,
               statusFrame.width > 0, statusFrame.height > 0,
               panelFrame.width > 0, panelFrame.height > 0 {
                let expected = MenuBarPanelPositioner.frame(
                    anchor: statusFrame,
                    visibleFrame: screen.visibleFrame
                )
                let tolerance = SelfCheckUIValidator.geometryTolerance
                let layoutIsFinal = abs(panelFrame.origin.x - expected.origin.x) <= tolerance
                    && abs(panelFrame.origin.y - expected.origin.y) <= tolerance
                    && abs(panelFrame.width - expected.width) <= tolerance
                    && abs(panelFrame.height - expected.height) <= tolerance
                if layoutIsFinal { break }
            }

            if Task.isCancelled || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(25))
        } while true

        return SelfCheckUISnapshot(
            mainWindowFrame: mainWindow.map { SelfCheckFrame($0.frame) },
            statusItemFrame: statusFrame.map(SelfCheckFrame.init),
            panelFrame: panelFrame.map(SelfCheckFrame.init),
            visibleScreenFrame: screen.map { SelfCheckFrame($0.visibleFrame) },
            // A missing frontmost application is a real UI-probe failure. Reporting our own PID
            // here would make an unavailable Workspace value indistinguishable from success.
            frontmostApplicationPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    /// Explicit main-actor cleanup. AppKit observer tokens and status items are non-Sendable, so
    /// they must be released here instead of from Swift's nonisolated `deinit`.
    func invalidate() {
        hidePanel()
        removeEventMonitors()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        cancellables.removeAll()
        contextMenu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: "CC Buddy"
        ) ?? NSImage(systemSymbolName: "network", accessibilityDescription: "CC Buddy")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityIdentifier("menubar.status")
        button.setAccessibilityLabel(model.appLanguage.localized("CC Buddy 菜单栏"))
        button.toolTip = "CC Buddy"
    }

    private func configurePanel() {
        panel.onCancel = { [weak self] in self?.hidePanel() }
        let content = MenuBarView(
            model: model,
            onShowMain: { [weak self] in
                self?.hidePanel()
                self?.showMainWindow()
            },
            onQuit: { [weak self] in
                self?.hidePanel()
                self?.requestQuit()
            }
        )
        .environment(\.locale, model.appLanguage.locale)
        .environment(\.appLanguage, model.appLanguage)
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.frame = NSRect(origin: .zero, size: MenuBarPanelPositioner.defaultSize)
        panel.contentViewController = hostingController
        panel.setContentSize(MenuBarPanelPositioner.defaultSize)
    }

    private func observeState() {
        model.$config
            .sink { [weak self] config in
                guard let self else { return }
                let language = AppLanguage(configValue: config.language)
                self.panel.apply(language: language)
                self.updateStatusItem(config: config, language: language)
                self.rebuildContextMenu(language: language)
            }
            .store(in: &cancellables)
        model.$gatewayState
            .sink { [weak self] _ in self?.rebuildContextMenu() }
            .store(in: &cancellables)
        model.$themeMode
            .sink { [weak self] themeMode in self?.panel.apply(themeMode: themeMode) }
            .store(in: &cancellables)
        model.$usageHistorySummaries
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.$usageHistoryState
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.model.refreshUsageHistory() }
            }
            .store(in: &cancellables)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            Task { @MainActor [weak self] in self?.hidePanel() }
        }
    }

    private func updateStatusItem(
        config suppliedConfig: AppConfig? = nil,
        language suppliedLanguage: AppLanguage? = nil
    ) {
        guard let button = statusItem.button else { return }
        let config = suppliedConfig ?? model.config
        let language = suppliedLanguage ?? AppLanguage(configValue: config.language)
        let usageEnabled = config.trayUsage.enabled
        let range = UsageRange(rawValue: config.trayUsage.range) ?? .sevenDays
        let summary = model.usageHistorySummary(for: range)
        let presentation = MenuBarUsageTitlePresenter.presentation(
            enabled: usageEnabled,
            range: range,
            state: model.usageHistoryState,
            summary: summary
        )
        let accessibilityValue = MenuBarStatusLocalization.accessibilityValue(
            enabled: usageEnabled,
            range: range,
            state: model.usageHistoryState,
            summary: summary,
            language: language
        )
        button.title = presentation.title
        button.setAccessibilityLabel(language.localized("CC Buddy 菜单栏"))
        button.setAccessibilityValue(accessibilityValue)
        button.toolTip = usageEnabled
            ? "CC Buddy · \(accessibilityValue)"
            : "CC Buddy"
    }

    @objc private func statusItemPressed(_ sender: Any?) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp {
            showContextMenu(with: event)
            return
        }
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func rebuildContextMenu(language suppliedLanguage: AppLanguage? = nil) {
        let language = suppliedLanguage ?? model.appLanguage
        let presentation = MenuBarContextMenuPresentation.presentation(
            language: language,
            gatewayRunning: model.gatewayState.isRunning,
            providerName: model.activeProvider?.name
        )
        let menu = NSMenu(title: "CC Buddy")
        menu.autoenablesItems = false

        let status = NSMenuItem(title: presentation.statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.identifier = NSUserInterfaceItemIdentifier("menubar.menu.status")
        status.setAccessibilityLabel(presentation.statusTitle)
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(
            title: presentation.openMainTitle,
            identifier: "menubar.menu.open",
            action: #selector(openMainFromContextMenu(_:))
        ))
        menu.addItem(contextMenuItem(
            title: presentation.gatewayActionTitle,
            identifier: "menubar.menu.gateway",
            action: #selector(toggleGatewayFromContextMenu(_:))
        ))
        menu.addItem(contextMenuItem(
            title: presentation.checkForUpdatesTitle,
            identifier: "menubar.menu.check-update",
            action: #selector(checkForUpdatesFromContextMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(
            title: presentation.quitTitle,
            identifier: "menubar.menu.quit",
            action: #selector(quitFromContextMenu(_:))
        ))
        contextMenu = menu
    }

    private func contextMenuItem(
        title: String,
        identifier: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        item.setAccessibilityLabel(title)
        return item
    }

    private func showContextMenu(with event: NSEvent) {
        hidePanel()
        rebuildContextMenu()
        guard let contextMenu, let button = statusItem.button else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: button)
    }

    @objc private func openMainFromContextMenu(_ sender: Any?) {
        hidePanel()
        showMainWindow()
    }

    @objc private func toggleGatewayFromContextMenu(_ sender: Any?) {
        let shouldEnable = !model.gatewayState.isRunning
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.setGatewayEnabled(shouldEnable)
        }
    }

    @objc private func checkForUpdatesFromContextMenu(_ sender: Any?) {
        hidePanel()
        model.openSettings(.about)
        showMainWindow()
        Task { @MainActor [weak self] in
            await self?.model.checkForUpdates()
        }
    }

    @objc private func quitFromContextMenu(_ sender: Any?) {
        hidePanel()
        requestQuit()
    }

    private func showPanel() {
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        Task { await model.refreshUsageHistory() }
        let anchorInWindow = button.convert(button.bounds, to: nil)
        let anchor = statusWindow.convertToScreen(anchorInWindow)
        let screen = statusWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })
            ?? NSScreen.main
        guard let screen else { return }

        let frame = MenuBarPanelPositioner.frame(anchor: anchor, visibleFrame: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installEventMonitors()
    }

    private func installEventMonitors() {
        removeEventMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.hidePanel()
                return nil
            }
            guard event.type != .keyDown else { return event }
            if event.window === self.panel || self.statusItemContainsMouseLocation() { return event }
            self.hidePanel()
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.hidePanel() }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func statusItemContainsMouseLocation() -> Bool {
        guard let statusWindow = statusItem.button?.window else { return false }
        return statusWindow.frame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
    }
}

struct MenuBarContextMenuPresentation: Equatable {
    let statusTitle: String
    let openMainTitle: String
    let gatewayActionTitle: String
    let checkForUpdatesTitle: String
    let quitTitle: String

    static func presentation(
        language: AppLanguage,
        gatewayRunning: Bool,
        providerName: String?
    ) -> Self {
        let provider = providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusSource = gatewayRunning
            ? "网关运行中 · \((provider?.isEmpty == false ? provider : nil) ?? "CC Buddy")"
            : "网关已停止"
        return Self(
            statusTitle: language.localized(statusSource),
            openMainTitle: language.localized("打开主界面"),
            gatewayActionTitle: language.localized(gatewayRunning ? "停止服务" : "启动服务"),
            checkForUpdatesTitle: language.localized("检查更新…"),
            quitTitle: language.localized("退出 CC Buddy")
        )
    }
}

enum MenuBarStatusLocalization {
    static func accessibilityValue(
        enabled: Bool,
        range: UsageRange,
        state: UsageHistoryLoadState,
        summary: UsageHistorySummary?,
        language: AppLanguage
    ) -> String {
        guard enabled else { return language.localized("仅图标") }
        if case .failed = state { return language.localized("历史用量读取失败") }
        guard let summary else { return language.localized("历史用量加载中") }

        let rangeDescription = language.localized(range == .all ? "全部" : range.shortLabel)
        let tokenDescription = language.localized("\(summary.tokens) Tokens")
        return "\(rangeDescription) \(tokenDescription)"
    }
}
