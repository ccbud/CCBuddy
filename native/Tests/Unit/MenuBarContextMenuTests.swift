import XCTest
@testable import CCBuddy

@MainActor
final class MenuBarContextMenuTests: XCTestCase {
    func testContextMenuTitlesAreLocalizedInEveryConfiguredLanguage() {
        let provider = "Provider/原样-そのまま-그대로"
        let fixtures: [(AppLanguage, [String])] = [
            (.english, [
                "Gateway running · \(provider)", "Open main window", "Stop service",
                "Check for updates…", "Quit CC Buddy",
            ]),
            (.simplifiedChinese, [
                "网关运行中 · \(provider)", "打开主界面", "停止服务", "检查更新…", "退出 CC Buddy",
            ]),
            (.traditionalChinese, [
                "閘道執行中 · \(provider)", "開啟主視窗", "停止服務", "檢查更新…", "結束 CC Buddy",
            ]),
            (.japanese, [
                "ゲートウェイ実行中 · \(provider)", "メインウィンドウを開く", "サービスを停止",
                "更新を確認…", "CC Buddy を終了",
            ]),
            (.korean, [
                "게이트웨이 실행 중 · \(provider)", "메인 창 열기", "서비스 중지",
                "업데이트 확인…", "CC Buddy 종료",
            ]),
        ]

        for (language, expected) in fixtures {
            let presentation = MenuBarContextMenuPresentation.presentation(
                language: language,
                gatewayRunning: true,
                providerName: provider
            )
            XCTAssertEqual([
                presentation.statusTitle,
                presentation.openMainTitle,
                presentation.gatewayActionTitle,
                presentation.checkForUpdatesTitle,
                presentation.quitTitle,
            ], expected, language.rawValue)
        }
    }

    func testGatewayStatusAndActionTitlesTrackRunningStateInEveryLanguage() {
        let fixtures: [(AppLanguage, String, String, String)] = [
            (.english, "Gateway stopped", "Start service", "Stop service"),
            (.simplifiedChinese, "网关已停止", "启动服务", "停止服务"),
            (.traditionalChinese, "閘道已停止", "啟動服務", "停止服務"),
            (.japanese, "ゲートウェイ停止中", "サービスを起動", "サービスを停止"),
            (.korean, "게이트웨이 중지됨", "서비스 시작", "서비스 중지"),
        ]

        for (language, stoppedStatus, startTitle, stopTitle) in fixtures {
            let stopped = MenuBarContextMenuPresentation.presentation(
                language: language,
                gatewayRunning: false,
                providerName: nil
            )
            let running = MenuBarContextMenuPresentation.presentation(
                language: language,
                gatewayRunning: true,
                providerName: "  "
            )

            XCTAssertEqual(stopped.statusTitle, stoppedStatus, language.rawValue)
            XCTAssertEqual(stopped.gatewayActionTitle, startTitle, language.rawValue)
            XCTAssertEqual(running.gatewayActionTitle, stopTitle, language.rawValue)
            XCTAssertTrue(running.statusTitle.contains("CC Buddy"), language.rawValue)
        }
    }

    func testSettingsDeepLinkSelectsAboutAndPersistsPaneAcrossDestinations() {
        var navigation = AppModel.NavigationState()
        XCTAssertEqual(navigation.destination, .providers)
        XCTAssertEqual(navigation.settingsPane, .gateway)

        navigation.select(.monitor)
        navigation.openSettings(.about)
        XCTAssertEqual(navigation.destination, .settings)
        XCTAssertEqual(navigation.settingsPane, .about)

        navigation.selectSettingsPane(.data)
        navigation.select(.providers)
        XCTAssertEqual(navigation.destination, .providers)
        XCTAssertEqual(navigation.settingsPane, .data)
    }
}
