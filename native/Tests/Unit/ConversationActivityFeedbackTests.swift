import XCTest
@testable import CCBuddy

final class ConversationActivityFeedbackTests: XCTestCase {
    func testBackgroundPreparationIsDirectSearchNotAnAccelerationFailure() {
        for reason in ["indexPreparing", "indexRestoring"] {
            XCTAssertTrue(ConversationSearchAccelerationPresentation.isPreparing(reason))
            XCTAssertEqual(ConversationSearchAccelerationPresentation.explanationKey(reason),
                "本次查询直接核对压缩正文，不等待索引；加速在后台准备，后续查询自动使用。")
        }
        for reason in ["unsafeCache", "lowDiskSpace", "ioFailure", "operationFailed"] {
            XCTAssertFalse(ConversationSearchAccelerationPresentation.isPreparing(reason))
            XCTAssertNotEqual(ConversationSearchAccelerationPresentation.explanationKey(reason),
                ConversationSearchAccelerationPresentation.explanationKey("indexPreparing"))
        }
    }

    func testSearchFeedbackOnlyUsesReportedStagesAndEndsWithCompletion() {
        XCTAssertEqual(ConversationActivityStage.searchStage(for: nil), .preparingSearch)
        XCTAssertEqual(ConversationActivityStage.searchStage(for: .preparingCandidates), .preparingSearch)
        XCTAssertEqual(ConversationActivityStage.searchStage(for: .refiningResults), .refiningSearch)
        XCTAssertEqual(ConversationActivityStage.searchStage(for: .countingOccurrences), .countingSearchOccurrences)
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
