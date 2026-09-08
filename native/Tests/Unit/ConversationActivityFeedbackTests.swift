import XCTest
@testable import CCBuddy

final class ConversationActivityFeedbackTests: XCTestCase {
    func testSearchFeedbackOnlyUsesReportedStagesAndEndsWithCompletion() {
        XCTAssertEqual(ConversationActivityStage.searchStage(for: nil), .preparingSearch)
        XCTAssertEqual(ConversationActivityStage.searchStage(for: .preparingCandidates), .preparingSearch)
        XCTAssertEqual(ConversationActivityStage.searchStage(for: .refiningResults), .refiningSearch)
        XCTAssertNil(ConversationActivityStage.searchStage(for: .completed))
    }

    func testOpeningAndInSessionFindDescribeDifferentWork() {
        XCTAssertEqual(ConversationActivityStage.openingSession.titleKey, "正在读取会话…")
        XCTAssertEqual(ConversationActivityStage.searchingMessages.titleKey, "正在搜索消息内容…")
        XCTAssertNotEqual(ConversationActivityStage.preparingSearch.titleKey,
                          ConversationActivityStage.refiningSearch.titleKey)
    }

    func testSearchFeedbackOnlyOffersOpeningResultsWhenVerifiedResultsExist() {
        for stage in [ConversationActivityStage.preparingSearch, .refiningSearch] {
            XCTAssertEqual(stage.messageKey(hasVerifiedResults: false), "可继续输入或清空搜索。")
            XCTAssertEqual(stage.messageKey(hasVerifiedResults: true), "已找到的结果可先打开，也可继续输入。")
        }
    }
}
