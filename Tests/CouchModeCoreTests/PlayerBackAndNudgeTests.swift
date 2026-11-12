import XCTest
@testable import CouchModeCore

final class PlayerBackAndNudgeTests: XCTestCase {
    func testEscapeAndDeleteAreBackOnlyDuringAHandedOffTitle() {
        XCTAssertTrue(PlayerBackKey.isBack(keyCode: 53, handedOffTitleShowing: true))
        XCTAssertTrue(PlayerBackKey.isBack(keyCode: 51, handedOffTitleShowing: true))
        XCTAssertFalse(PlayerBackKey.isBack(keyCode: 53, handedOffTitleShowing: false))
    }

    func testOnlyEscapeIsBackOnASignInPageSoDeleteStillTypes() {
        XCTAssertTrue(PlayerBackKey.isSignInBack(keyCode: 53, signInShowing: true))
        XCTAssertFalse(PlayerBackKey.isSignInBack(keyCode: 51, signInShowing: true), "Delete edits a password")
        XCTAssertFalse(PlayerBackKey.isSignInBack(keyCode: 53, signInShowing: false))
    }

    func testOtherKeysGoToThePlayer() {
        for code: UInt16 in [49, 36, 123, 124, 125, 126, 3, 40] {
            XCTAssertFalse(PlayerBackKey.isBack(keyCode: code, handedOffTitleShowing: true))
        }
    }

    func testNudgesAPausedReadyVideoAfterTheGraceOnce() {
        XCTAssertTrue(PlayNudge.shouldPress(state: .readyPaused, secondsSinceAllowed: 3.5, alreadyPressed: false))
        XCTAssertFalse(PlayNudge.shouldPress(state: .readyPaused, secondsSinceAllowed: 2, alreadyPressed: false))
        XCTAssertFalse(PlayNudge.shouldPress(state: .readyPaused, secondsSinceAllowed: 5, alreadyPressed: true))
    }

    func testNeverNudgesARollingOrNotReadyVideo() {
        XCTAssertFalse(PlayNudge.shouldPress(state: .rolling, secondsSinceAllowed: 5, alreadyPressed: false))
        XCTAssertFalse(PlayNudge.shouldPress(state: .other, secondsSinceAllowed: 5, alreadyPressed: false))
    }

    func testProbeValues() {
        XCTAssertEqual(PlayNudge.state(fromProbe: "rolling"), .rolling)
        XCTAssertEqual(PlayNudge.state(fromProbe: "paused"), .readyPaused)
        XCTAssertEqual(PlayNudge.state(fromProbe: nil), .other)
    }
}
