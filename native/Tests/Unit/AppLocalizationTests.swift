import XCTest
@testable import CCBuddy

final class AppLocalizationTests: XCTestCase {
    func testConfiguredLanguagesMapToNativeLocales() {
        XCTAssertEqual(
            AppLanguage(configValue: nil, systemLocale: Locale(identifier: "en-SG")),
            .english
        )
        XCTAssertEqual(
            AppLanguage(configValue: nil, systemLocale: Locale(identifier: "zh-Hant-HK")),
            .traditionalChinese
        )
        XCTAssertEqual(
            AppLanguage(configValue: "ja", systemLocale: Locale(identifier: "en")),
            .japanese
        )
        XCTAssertEqual(
            AppLanguage(configValue: "unsupported", systemLocale: Locale(identifier: "ko-KR")),
            .korean
        )
        XCTAssertEqual(AppLanguage(configValue: "zh-TW").localeIdentifier, "zh-Hant")
        XCTAssertEqual(AppLanguage(configValue: "en").localeIdentifier, "en")
        XCTAssertEqual(AppLanguage(configValue: "ja").localeIdentifier, "ja")
        XCTAssertEqual(AppLanguage(configValue: "ko").localeIdentifier, "ko")
    }

    func testGeneratedCatalogLocalizesLegacyAndNativeLabels() {
        XCTAssertEqual(AppLanguage.english.localized("服务"), "Services")
        XCTAssertEqual(AppLanguage.traditionalChinese.localized("设置"), "設定")
        XCTAssertEqual(AppLanguage.japanese.localized("启动服务"), "サービスを起動")
        XCTAssertEqual(AppLanguage.korean.localized("成功率"), "성공률")
        XCTAssertEqual(AppLanguage.english.localized("model-id-does-not-translate"), "model-id-does-not-translate")
    }

    func testDynamicUsageConversationLifecycleAndPluginTemplatesPreserveRuntimeValues() {
        XCTAssertEqual(
            AppLanguage.english.localized("15 次请求"),
            "15 requests"
        )
        XCTAssertEqual(
            AppLanguage.japanese.localized("导入 2 · 跳过 1 · 失败 3"),
            "インポート 2件 · スキップ 1件 · 失敗 3件"
        )
        XCTAssertEqual(AppLanguage.english.localized("42 会话"), "42 sessions")
        XCTAssertEqual(AppLanguage.korean.localized("42 会话"), "세션 42개")
        XCTAssertEqual(
            AppLanguage.korean.localized("无法打开 Claude，请确认已安装桌面应用"),
            "Claude을(를) 열 수 없습니다. 데스크톱 앱이 설치되어 있는지 확인하세요"
        )
        XCTAssertEqual(
            AppLanguage.english.localized("正在将 Bifrost 从 localhost:8788 重启到 localhost:9799"),
            "Restarting Bifrost from localhost:8788 to localhost:9799"
        )
        XCTAssertEqual(
            AppLanguage.traditionalChinese.localized("Bifrost 启动失败 · socket detail"),
            "Bifrost 啟動失敗 · socket detail"
        )
        XCTAssertEqual(
            AppLanguage.english.localized("Bifrost 请求已重试 3 次"),
            "Bifrost retried the request 3 times"
        )
        XCTAssertEqual(
            AppLanguage.korean.localized("Bifrost 请求失败 · 上游 HTTP 429"),
            "Bifrost 요청 실패 · 업스트림 HTTP 429"
        )
        XCTAssertEqual(
            AppLanguage.english.localized("插件“raw-plugin-id”已安装"),
            "Plugin “raw-plugin-id” installed"
        )
        XCTAssertEqual(
            AppLanguage.japanese.localized("Qoder CLI helper 读取失败：raw helper detail"),
            "Qoder CLI helper の読み取りに失敗しました：raw helper detail"
        )
    }

    func testConversationMessageAndIndexTemplatesCoverEveryAppLanguage() {
        let expectations: [(AppLanguage, String, String, String)] = [
            (
                .english,
                "17 messages",
                "Conversation indexing failed: catalog unavailable",
                "3 conversations could not be indexed; the rest are shown"
            ),
            (
                .simplifiedChinese,
                "17 条消息",
                "会话索引失败：catalog unavailable",
                "3 个会话无法建立索引，已显示其余会话"
            ),
            (
                .traditionalChinese,
                "17 則訊息",
                "會話索引失敗：catalog unavailable",
                "3 個會話無法建立索引，已顯示其餘會話"
            ),
            (
                .japanese,
                "メッセージ 17件",
                "会話のインデックス作成に失敗しました：catalog unavailable",
                "3 件の会話をインデックス化できませんでした。残りの会話を表示しています"
            ),
            (
                .korean,
                "메시지 17개",
                "대화 색인 생성 실패: catalog unavailable",
                "대화 3개의 색인을 생성하지 못했습니다. 나머지 대화는 표시됩니다"
            ),
        ]

        for (language, messageCount, indexFailure, partialFailure) in expectations {
            XCTAssertEqual(language.localized("17 条消息"), messageCount)
            XCTAssertEqual(language.localized("会话索引失败：catalog unavailable"), indexFailure)
            XCTAssertEqual(
                language.localized("3 个会话无法建立索引，已显示其余会话"),
                partialFailure
            )
        }
    }

    func testAccessibilityTemplatesUseDistinctCommaAndExplanationPunctuation() {
        XCTAssertEqual(
            AppLanguage.english.localized("Tokens，15K"),
            "Tokens, 15K"
        )
        XCTAssertEqual(
            AppLanguage.english.localized("Translated：Request body was converted"),
            "Translated: Request body was converted"
        )
    }

    func testNativeGatewayErrorsAndCollapsedControlsAreLocalized() {
        XCTAssertEqual(
            AppLanguage.english.localized(
                "Bifrost 请求失败（HTTP 502，事件 event-7）：upstream unavailable"
            ),
            "Bifrost request failed (HTTP 502, event event-7): upstream unavailable"
        )
        XCTAssertEqual(
            AppLanguage.japanese.localized("Bifrost 启动健康检查超时"),
            "Bifrost の起動ヘルスチェックがタイムアウトしました"
        )
        XCTAssertEqual(AppLanguage.korean.localized("展开侧边栏"), "사이드바 펼치기")
        XCTAssertEqual(AppLanguage.english.localized("切换到深色模式"), "Switch to dark mode")
        XCTAssertEqual(AppLanguage.english.localized("会话时间线"), "Conversation timeline")
    }

    func testCLIManualRecoveryInstructionsAndDetailsAreLocalized() {
        XCTAssertEqual(
            AppLanguage.english.localized("CLI 配置需要手动恢复"),
            "CLI configuration requires manual recovery"
        )
        XCTAssertEqual(AppLanguage.japanese.localized("重新检查"), "再確認")
        XCTAssertEqual(
            AppLanguage.english.localized(
                "检测到未完成的 CLI 配置恢复记录：/private/recovery/tx-1。请先按照 journal.json 恢复原始文件并移除恢复目录"
            ),
            "Unfinished CLI configuration recovery records were found at: /private/recovery/tx-1. Restore the original files using journal.json and remove the recovery directories before continuing"
        )
        XCTAssertEqual(
            AppLanguage.korean.localized(
                "manual recovery detail；重新检查恢复记录失败：permission denied"
            ),
            "manual recovery detail; 복구 기록을 다시 확인하지 못했습니다: permission denied"
        )
    }
}
