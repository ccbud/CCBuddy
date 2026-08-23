import AppKit
import XCTest

final class CCBuddyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var isolatedHome: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-xcui-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        app = makeIsolatedApplication()
        terminateAppIfRunning()
        app.launchEnvironment["CCBUD_MONITOR_UI_FIXTURE"] = "1"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 8)
        }
        app = nil
        if let isolatedHome { try? FileManager.default.removeItem(at: isolatedHome) }
        isolatedHome = nil
    }

    private func makeIsolatedApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["CCBUD_UI_TESTING"] = "1"
        application.launchEnvironment["CCBUD_HOME"] = isolatedHome.path
        application.launchEnvironment["CCBUD_UI_LANGUAGE"] = "zh"
        return application
    }

    func testMainNavigationAndProviderEditor() {
        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["providers.hero"].exists)
        XCTAssertTrue(app.groups["provider.p1"].exists)

        for destination in ["plugins", "conversations", "monitor", "settings", "providers"] {
            app.buttons["sidebar.\(destination)"].click()
        }

        app.buttons["providers.add"].click()
        XCTAssertTrue(app.otherElements["provider.editor"].waitForExistence(timeout: 2))
    }

    func testPluginManagementSurfaceLoads() {
        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        let plugins = app.buttons["sidebar.plugins"]
        XCTAssertTrue(plugins.waitForExistence(timeout: 2))
        plugins.click()

        XCTAssertTrue(app.otherElements["view.plugins"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["plugins.hero"].exists)
        XCTAssertTrue(app.otherElements["plugins.empty"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["plugins.install-git"].exists)
        XCTAssertTrue(app.buttons["plugins.install-local"].exists)
    }

    func testProviderHeroReadsFullHistoryUsageInsteadOfMonitorBuffer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-ui-usage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = #"{"timestamp":"\#(timestamp)","requestId":"ui-request","message":{"id":"ui-message","model":"claude-ui-history","usage":{"input_tokens":12,"output_tokens":3}}}"#
            + "\n"
        try Data(line.utf8).write(to: project.appendingPathComponent("session.jsonl"))

        terminateAppIfRunning()
        app = makeIsolatedApplication()
        app.launchEnvironment["CCBUD_UI_HISTORY_DIR"] = root.path
        app.launchEnvironment["CCBUD_UI_GATEWAY_RUNNING"] = "1"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
        app.activate()

        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        let tokens = app.staticTexts["providers.usage.tokens"]
        XCTAssertTrue(tokens.waitForExistence(timeout: 5))
        XCTAssertEqual(tokens.value as? String, "15")
        XCTAssertEqual(
            app.staticTexts["providers.usage.requests"].value as? String,
            "1 次请求"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["providers.usage.sparkline"].exists,
            "History heatmap values must feed the hero sparkline"
        )
    }

    func testMenuBarStatusAndPanelReadLocalizedHistoryUsage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-ui-menubar-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = #"{"timestamp":"\#(timestamp)","requestId":"ui-menubar-request","message":{"id":"ui-menubar-message","model":"claude-ui-history","usage":{"input_tokens":12,"output_tokens":3}}}"#
            + "\n"
        try Data(line.utf8).write(to: project.appendingPathComponent("session.jsonl"))

        terminateAppIfRunning()
        app = makeIsolatedApplication()
        app.launchEnvironment["CCBUD_UI_HISTORY_DIR"] = root.path
        app.launchEnvironment["CCBUD_UI_GATEWAY_RUNNING"] = "1"
        app.launchEnvironment["CCBUD_UI_TRAY_USAGE"] = "1"
        app.launchEnvironment["CCBUD_UI_TRAY_RANGE"] = "7d"
        app.launchEnvironment["CCBUD_UI_LANGUAGE"] = "en"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()

        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        let status = app.descendants(matching: .statusItem)["menubar.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "CC Buddy menu bar")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "7 days 15 tokens"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)

        status.click()
        let content = app.descendants(matching: .any)["menubar.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["menubar.overview"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["menubar.heatmap"].exists)
        XCTAssertTrue(app.buttons["menubar.gateway"].exists)
        XCTAssertEqual(app.buttons["menubar.main"].label, "Main window")
        XCTAssertEqual(app.buttons["menubar.quit"].label, "Quit")

        let models = app.buttons["menubar.section.models"]
        XCTAssertTrue(models.waitForExistence(timeout: 2))
        XCTAssertEqual(models.label, "Model")
        models.click()
        let modelUsage = app.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "claude-ui-history"))
            .firstMatch
        XCTAssertTrue(modelUsage.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(content.waitForExistence(timeout: 1))
    }

    func testMenuBarRightClickShowsLocalizedContextMenuAndOpensMainWindow() throws {
        terminateAppIfRunning()
        app = makeIsolatedApplication()
        app.launchEnvironment["CCBUD_UI_GATEWAY_RUNNING"] = "1"
        app.launchEnvironment["CCBUD_UI_LANGUAGE"] = "en"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
        app.activate()

        let shell = app.otherElements["app.shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        let status = app.descendants(matching: .statusItem)["menubar.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        let closeButton = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        closeButton.click()
        XCTAssertTrue(shell.waitForNonExistence(timeout: 2))

        status.rightClick()
        let statusItem = app.menuItems["menubar.menu.status"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 2))
        XCTAssertEqual(statusItem.label, "Gateway running · GLM")
        XCTAssertFalse(statusItem.isEnabled)
        XCTAssertEqual(app.menuItems["menubar.menu.gateway"].label, "Stop service")
        XCTAssertEqual(app.menuItems["menubar.menu.check-update"].label, "Check for updates…")
        XCTAssertEqual(app.menuItems["menubar.menu.quit"].label, "Quit CC Buddy")

        let openMain = app.menuItems["menubar.menu.open"]
        XCTAssertEqual(openMain.label, "Open main window")
        openMain.click()
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
    }

    func testProviderRowDeleteActionDoesNotAlsoSelectTheRow() {
        terminateAppIfRunning()
        app = makeIsolatedApplication()
        app.launchEnvironment["CCBUD_UI_GATEWAY_RUNNING"] = "1"
        app.launchEnvironment["CCBUD_UI_SECOND_PROVIDER"] = "1"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()

        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        let delete = app.buttons["provider.p2.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.click()

        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["切换"].exists)
        let localizedCancel = app.buttons["取消"]
        let defaultCancel = app.buttons["Cancel"]
        XCTAssertTrue(
            localizedCancel.waitForExistence(timeout: 1)
                || defaultCancel.waitForExistence(timeout: 1)
        )
    }

    func testEndpointAndExportCopyWriteExpectedClipboardContents() {
        terminateAppIfRunning()
        app = makeIsolatedApplication()
        app.launchEnvironment["CCBUD_UI_GATEWAY_RUNNING"] = "1"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
        app.activate()

        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        let pasteboard = NSPasteboard.general
        let originalItems = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(originalItems, to: pasteboard) }

        pasteboard.clearContents()
        let providerEndpoint = app.buttons["providers.endpoint"]
        XCTAssertTrue(providerEndpoint.waitForExistence(timeout: 2))
        providerEndpoint.click()
        XCTAssertTrue(waitForPasteboard { $0 == "http://localhost:8788" })

        app.buttons["sidebar.settings"].click()
        XCTAssertTrue(app.otherElements["settings.pane.gateway"].waitForExistence(timeout: 2))

        pasteboard.clearContents()
        let endpointCopy = app.buttons["settings.gateway.endpoint.copy"]
        XCTAssertTrue(endpointCopy.waitForExistence(timeout: 2))
        endpointCopy.click()
        XCTAssertTrue(waitForPasteboard { $0 == "http://localhost:8788" })

        pasteboard.clearContents()
        let exportsCopy = app.buttons["settings.gateway.exports.copy"]
        XCTAssertTrue(exportsCopy.waitForExistence(timeout: 2))
        exportsCopy.click()
        XCTAssertTrue(waitForPasteboard {
            $0 == "export ANTHROPIC_BASE_URL=http://localhost:8788/anthropic\n"
                + "export ANTHROPIC_AUTH_TOKEN=ccbud-local"
        })
    }

    func testMonitorInspectorTabsRawCopySearchPrivacyAndExpand() {
        let pasteboard = NSPasteboard.general
        let originalItems = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(originalItems, to: pasteboard) }

        // Window restoration can remember the app's menu-bar-only state. Reopening is the same
        // user path as clicking the dock icon and asks AppDelegate to present the main window.
        app.activate()
        XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5))
        app.buttons["sidebar.monitor"].click()

        let row = app.buttons["monitor.request.ui-monitor-translated"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.click()

        let clientRequestTab = app.buttons["monitor.detail.tab.clientRequest"]
        XCTAssertTrue(clientRequestTab.waitForExistence(timeout: 2))
        for tab in ["clientRequest", "upstreamRequest", "upstreamResponse", "clientResponse"] {
            XCTAssertTrue(app.buttons["monitor.detail.tab.\(tab)"].exists)
        }
        XCTAssertFalse(app.buttons["monitor.detail.tab.request"].exists)

        app.buttons["monitor.detail.tab.upstreamRequest"].click()
        app.buttons["monitor.detail.presentation.raw"].click()

        let search = app.searchFields["monitor.detail.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.click()
        search.typeText("needle")
        let count = app.staticTexts["monitor.detail.search.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 1))
        let countUpdated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1/1"),
            object: count
        )
        XCTAssertEqual(XCTWaiter.wait(for: [countUpdated], timeout: 2), .completed)

        pasteboard.clearContents()
        app.buttons["monitor.detail.copy"].click()
        XCTAssertTrue(waitForPasteboard { value in
            value.contains("••••••（已隐藏）") && !value.contains("ui-secret-token")
        })

        app.buttons["monitor.detail.privacy"].click()
        pasteboard.clearContents()
        app.buttons["monitor.detail.copy"].click()
        XCTAssertTrue(waitForPasteboard { value in
            value == #"{"authorization":"Bearer ui-secret-token","prompt":"Needle secret"}"#
        })

        let expand = app.buttons["monitor.detail.expand"]
        XCTAssertTrue(expand.exists)
        expand.click()
        XCTAssertEqual(expand.label, "恢复抽屉宽度")
        app.buttons["monitor.detail.close"].click()
        XCTAssertFalse(clientRequestTab.waitForExistence(timeout: 0.5))
    }

    func testConfiguredLocalesLocalizeNavigationAndProviderHeroWithScreenshots() {
        let fixtures: [(String, [String], String)] = [
            ("zh", ["服务", "插件", "会话", "监控", "设置"], "启动服务"),
            ("zh-TW", ["服務", "外掛", "工作階段", "監控", "設定"], "啟動服務"),
            ("ja", ["サービス", "プラグイン", "セッション", "モニター", "設定"], "サービスを起動"),
            ("ko", ["서비스", "플러그인", "세션", "모니터", "설정"], "서비스 시작"),
            ("en", ["Services", "Plugins", "Sessions", "Monitor", "Settings"], "Start service"),
        ]
        let identifiers = ["providers", "plugins", "conversations", "monitor", "settings"]

        for (language, labels, action) in fixtures {
            terminateAppIfRunning()
            app = makeIsolatedApplication()
            app.launchEnvironment["CCBUD_UI_LANGUAGE"] = language
            app.launchArguments += [
                "-ApplePersistenceIgnoreState", "YES",
                "-NSQuitAlwaysKeepsWindows", "NO",
            ]
            app.launch()

            XCTAssertTrue(app.otherElements["app.shell"].waitForExistence(timeout: 5), language)
            for (identifier, label) in zip(identifiers, labels) {
                XCTAssertEqual(app.buttons["sidebar.\(identifier)"].label, label, language)
            }
            XCTAssertEqual(app.buttons["providers.connect"].label, action, language)

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "providers-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testDeterministicVisualParityScreenshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-ui-visual-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let timestamp = "2026-01-01T00:00:00.000Z"
        let transcriptLines = [
            #"{"type":"user","uuid":"visual-user","timestamp":"\#(timestamp)","sessionId":"visual-session","cwd":"/workspace/project","message":{"role":"user","content":"hello **world**"},"__ccbud__":{"title":"Test session","tagList":["x"]}}"#,
            #"{"type":"assistant","uuid":"visual-assistant","timestamp":"\#(timestamp)","requestId":"visual-request","sessionId":"visual-session","cwd":"/workspace/project","message":{"id":"visual-message","role":"assistant","model":"glm-5.2","content":[{"type":"thinking","thinking":"thinking hard"},{"type":"text","text":"hi there"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la","description":"list"}}],"usage":{"input_tokens":10,"output_tokens":20}}}"#,
            #"{"type":"user","uuid":"visual-result","timestamp":"\#(timestamp)","sessionId":"visual-session","cwd":"/workspace/project","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"total 0"}]}}"#,
        ]
        // The legacy bridge reports a 12,345-token / 42-request aggregate independently from
        // its three-message history detail. Non-transcript records let the real native usage
        // scanner reproduce that aggregate without adding fake messages to the conversation UI.
        // The day layout also exercises the real query path for the popover's frozen metrics.
        // The selected-range records cover a current three-day run and four isolated future
        // fixture days. The latter are intentional because the legacy seven-day payload has seven
        // active days and a three-day current streak, a combination that cannot be represented
        // using only the seven calendar days ending today. A separate nine-day run older than the
        // 30-day hero range establishes the longest streak without changing its 12,345 / 42 total.
        let usageDayOffsets = [-2, -1, 0, 2, 4, 6, 8]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let usageFormatter = ISO8601DateFormatter()
        usageFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func usageTimestamp(dayOffset: Int) -> String {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            let hour = calendar.date(byAdding: .hour, value: 14, to: day) ?? day
            return usageFormatter.string(from: hour)
        }
        let usageLines = (0..<42).map { index in
            let input = index == 41 ? 291 : 294
            let dayOffset = usageDayOffsets[index % usageDayOffsets.count]
            let timestamp = usageTimestamp(dayOffset: dayOffset)
            return #"{"type":"progress","timestamp":"\#(timestamp)","requestId":"visual-usage-\#(index)","message":{"id":"visual-usage-message-\#(index)","role":"assistant","model":"glm-5.2","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
        }
        let longestStreakLines = Array(-50 ... -42).enumerated().map { index, dayOffset in
            let timestamp = usageTimestamp(dayOffset: dayOffset)
            return #"{"type":"progress","timestamp":"\#(timestamp)","requestId":"visual-streak-\#(index)","message":{"id":"visual-streak-message-\#(index)","role":"assistant","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":0}}}"#
        }
        let lines = transcriptLines + usageLines + longestStreakLines
        let sessionFile = project.appendingPathComponent("visual-session.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: sessionFile)
        let fixtureDate = Date(timeIntervalSince1970: 1_767_225_600)
        try FileManager.default.setAttributes(
            [.creationDate: fixtureDate, .modificationDate: fixtureDate],
            ofItemAtPath: sessionFile.path
        )

        terminateAppIfRunning()
        app = makeIsolatedApplication()
        app.launchEnvironment["CCBUD_UI_VISUAL_FIXTURE"] = "legacy-smoke"
        app.launchEnvironment["CCBUD_UI_HISTORY_DIR"] = root.path
        app.launchEnvironment["CCBUD_UI_GATEWAY_RUNNING"] = "1"
        app.launchEnvironment["CCBUD_UI_TRAY_RANGE"] = "7d"
        app.launchEnvironment["CCBUD_UI_LANGUAGE"] = "zh"
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()
        app.activate()

        let shell = app.otherElements["app.shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let windowFrame = window.frame
        let titleBarInset = shell.frame.minY - windowFrame.minY
        XCTAssertEqual(windowFrame.width, 1_180, accuracy: 0.5)
        let hostingScreen = NSScreen.screens.first { $0.visibleFrame.intersects(windowFrame) }
            ?? NSScreen.main
        let availableContentHeight = hostingScreen.map {
            max(0, $0.visibleFrame.height - titleBarInset)
        } ?? 760
        XCTAssertEqual(
            windowFrame.height - titleBarInset,
            min(760, availableContentHeight),
            accuracy: 4
        )
        let visualTokens = app.staticTexts["providers.usage.tokens"]
        XCTAssertTrue(visualTokens.waitForExistence(timeout: 5))
        let usageLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "12K"),
            object: visualTokens
        )
        XCTAssertEqual(XCTWaiter.wait(for: [usageLoaded], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["providers.usage.requests"].value as? String, "42 次请求")
        keepMainContentScreenshot(named: "native-visual-providers", shell: shell)

        app.buttons["sidebar.plugins"].click()
        XCTAssertTrue(app.otherElements["view.plugins"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["plugin.demo"].waitForExistence(timeout: 3))
        keepMainContentScreenshot(named: "native-visual-plugins", shell: shell)

        app.buttons["sidebar.conversations"].click()
        XCTAssertTrue(app.otherElements["conversations.view"].waitForExistence(timeout: 3))
        let session = app.buttons["conversation.session.disk:visual-session"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        keepMainContentScreenshot(named: "native-visual-conversations-list", shell: shell)
        let conversationsView = app.otherElements["conversations.view"]
        if !conversationsView.exists {
            app.buttons["sidebar.conversations"].click()
            XCTAssertTrue(conversationsView.waitForExistence(timeout: 3))
        }
        let currentSession = app.buttons["conversation.session.disk:visual-session"]
        XCTAssertTrue(currentSession.waitForExistence(timeout: 5))
        let sessionHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: currentSession
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sessionHittable], timeout: 5), .completed)
        currentSession.click()
        XCTAssertTrue(app.otherElements["conversation.timeline"].waitForExistence(timeout: 5))
        keepMainContentScreenshot(named: "native-visual-conversation-detail", shell: shell)

        app.buttons["sidebar.monitor"].click()
        XCTAssertTrue(app.otherElements["view.monitor"].waitForExistence(timeout: 2))
        keepMainContentScreenshot(named: "native-visual-monitor", shell: shell)

        app.buttons["sidebar.settings"].click()
        XCTAssertTrue(app.otherElements["view.settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["settings.pane.gateway"].exists)
        keepMainContentScreenshot(named: "native-visual-settings-gateway", shell: shell)
        app.buttons["settings.nav.general"].click()
        XCTAssertTrue(app.otherElements["settings.pane.general"].waitForExistence(timeout: 2))
        keepMainContentScreenshot(named: "native-visual-settings-general", shell: shell)
        app.buttons["settings.nav.about"].click()
        XCTAssertTrue(app.otherElements["settings.pane.about"].waitForExistence(timeout: 2))
        keepMainContentScreenshot(named: "native-visual-settings-update", shell: shell)

        let status = app.descendants(matching: .statusItem)["menubar.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        status.click()
        let menuBarContent = app.descendants(matching: .any)["menubar.content"]
        XCTAssertTrue(menuBarContent.waitForExistence(timeout: 3))
        let expectedMetrics = [
            "用量，12K",
            "请求，42",
            "活跃天，7",
            "服务，GLM",
            "连续，3 天",
            "最长，9 天",
            "峰值，14时",
            "模型，glm-5.2",
        ]
        for value in expectedMetrics {
            let metric = menuBarContent.staticTexts
                .matching(NSPredicate(format: "value == %@", value))
                .firstMatch
            XCTAssertTrue(
                metric.exists,
                "Missing deterministic legacy popover metric: \(value)"
            )
        }
        // `menubar.content` includes the half-point overlay stroke (425×345 points). The panel is
        // the actual legacy comparison boundary and remains exactly 424×344 points.
        let menuBarPanel = app.descendants(matching: .any)["menubar.panel"]
        XCTAssertTrue(menuBarPanel.exists)
        XCTAssertEqual(menuBarPanel.frame.width, 424, accuracy: 0.5)
        XCTAssertEqual(menuBarPanel.frame.height, 344, accuracy: 0.5)
        keepScreenshot(named: "native-visual-popover", of: menuBarPanel)
        app.typeKey(.escape, modifierFlags: [])
    }

    private func waitForPasteboard(
        timeout: TimeInterval = 2,
        predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = NSPasteboard.general.string(forType: .string), predicate(value) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private struct PasteboardEntry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private typealias PasteboardSnapshot = [[PasteboardEntry]]

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardEntry(type: type, data: Data($0)) }
            }
        }
    }

    private func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshot.compactMap { entries -> NSPasteboardItem? in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(Data(entry.data), forType: entry.type)
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func keepScreenshot(named name: String, of element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `app.shell` is deliberately a tiny, non-blocking accessibility marker. Its screen origin
    /// identifies the first content pixel below the hidden native title bar. Crop the window at
    /// that boundary so visual attachments contain only the app surface, with no desktop or
    /// traffic-light chrome, while retaining normal XCUI hit-testing for all controls.
    private func keepMainContentScreenshot(named name: String, shell: XCUIElement) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let screenshot = window.screenshot()
        guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation),
              let source = bitmap.cgImage else {
            XCTFail("Could not decode the window screenshot")
            return
        }

        let windowFrame = window.frame
        let topInset = max(0, shell.frame.minY - windowFrame.minY)
        let scale = windowFrame.width > 0 ? CGFloat(source.width) / windowFrame.width : 1
        let topPixels = min(source.height - 1, max(0, Int((topInset * scale).rounded())))
        let cropRect = CGRect(
            x: 0,
            y: topPixels,
            width: source.width,
            height: source.height - topPixels
        )
        guard let cropped = source.cropping(to: cropRect) else {
            XCTFail("Could not crop the window screenshot to the app shell")
            return
        }
        let image = NSImage(
            cgImage: cropped,
            size: NSSize(
                width: windowFrame.width,
                height: max(1, windowFrame.height - topInset)
            )
        )
        let attachment = XCTAttachment(image: image, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func terminateAppIfRunning() {
        guard app.state != .notRunning else { return }
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 8),
            "Previous CC Buddy process did not finish its asynchronous shutdown"
        )
    }
}
