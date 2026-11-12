import XCTest
@testable import CouchModeCore

final class PlayerShownWatchTests: XCTestCase {
    private func run(_ answers: [Bool?]) -> [Bool] {
        var watch = PlayerShownWatch()
        return answers.map { watch.record($0) }
    }

    func testNeverShownNeverExits() {
        XCTAssertEqual(run([false, false, false, false]), [false, false, false, false])
    }

    func testExitsAfterShownThenTwoFalseInARow() {
        XCTAssertEqual(run([false, true, true, false, false]), [false, false, false, false, true])
    }

    func testOneFalseBlipDoesNotExit() {
        XCTAssertEqual(run([true, false, true, false, true]), [false, false, false, false, false])
    }

    func testNoAnswerIsNeitherShownNorGone() {
        XCTAssertEqual(run([true, false, nil, false]), [false, false, false, true])
        XCTAssertEqual(run([nil, nil, false, false]), [false, false, false, false])
    }

    func testGivesUpAfterTheBoundedNumberOfPolls() {
        var watch = PlayerShownWatch()
        var expired = false
        for _ in 0..<PlayerShownWatch.maxPolls + 1 { _ = watch.record(false); expired = watch.isExpired }
        XCTAssertTrue(expired)
        XCTAssertFalse(PlayerShownWatch().isExpired)
    }

    func testLeavingTheSiteIsOffSite() {
        let play = URL(string: "https://www.primevideo.com/detail/x?autoplay=1")!
        XCTAssertFalse(PlayerExit.hasLeftSite(playURL: play, current: URL(string: "https://www.primevideo.com/")))
        XCTAssertFalse(PlayerExit.hasLeftSite(playURL: play, current: nil))
        XCTAssertTrue(PlayerExit.hasLeftSite(playURL: play, current: URL(string: "https://www.amazon.com/ap/signin")))
    }
}
