import XCTest
@testable import CCBuddy

final class ConversationLatestScrollIntentTests: XCTestCase {
    private func request(file: String = "a", transcript: ConversationTranscriptID = .main,
                         revision: Int = 1) -> ConversationLatestScrollRequest {
        .init(file: URL(fileURLWithPath: "/tmp/\(file).jsonl"), transcriptID: transcript, revision: revision)
    }

    func testOnlyActiveFollowingCanAuthorizeLayoutCorrections() throws {
        var intent = ConversationLatestScrollIntent()
        XCTAssertNil(intent.token)
        intent.update(request())
        let token = try XCTUnwrap(intent.token)
        XCTAssertTrue(intent.accepts(token))
        XCTAssertFalse(intent.update(request()), "Unrelated redraws do not create new navigation")
        XCTAssertTrue(intent.accepts(token))
        intent.update(nil)
        XCTAssertFalse(intent.accepts(token), "Opening a search result cancels pending following layout work")
    }

    func testUserScrollCancelsQueuedWorkAndSameRequestCannotReviveIt() throws {
        var intent = ConversationLatestScrollIntent()
        intent.update(request())
        let token = try XCTUnwrap(intent.token)
        intent.cancelFromUser()
        XCTAssertFalse(intent.accepts(token))
        XCTAssertNil(intent.token)
        intent.update(request())
        XCTAssertNil(intent.token, "A stale SwiftUI update must not fight a user's gesture")
        intent.update(request(revision: 2))
        XCTAssertNotNil(intent.token, "A new explicit Latest choice can resume following")
        XCTAssertFalse(intent.accepts(token))
    }

    func testSourceTranscriptAndRevisionRejectStaleCorrections() throws {
        for replacement in [request(file: "b"), request(transcript: .subagent("child")), request(revision: 2)] {
            var intent = ConversationLatestScrollIntent()
            intent.update(request())
            let old = try XCTUnwrap(intent.token)
            intent.update(replacement)
            XCTAssertFalse(intent.accepts(old))
            XCTAssertEqual(intent.token?.request, replacement)
        }
    }

    func testDisappearanceAndReappearanceNeverAuthorizeOldQueuedCallback() throws {
        var intent = ConversationLatestScrollIntent()
        intent.update(request())
        let old = try XCTUnwrap(intent.token)
        intent.update(nil)
        intent.update(request())
        XCTAssertFalse(intent.accepts(old))
        XCTAssertNotNil(intent.token)
    }
}
