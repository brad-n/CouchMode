import XCTest
@testable import CouchModeCore

final class PlayerExitTests: XCTestCase {
    private let netflixPlay = URL(string: "https://www.netflix.com/watch/81234567?trackId=1")!
    private let huluPlay = URL(string: "https://www.hulu.com/watch/abc-123")!

    private func left(_ play: URL, _ current: String?) -> Bool {
        PlayerExit.hasLeftPlayer(playURL: play, current: current.flatMap { URL(string: $0) })
    }

    func testNilCurrentIsNotLeaving() {
        XCTAssertFalse(PlayerExit.hasLeftPlayer(playURL: netflixPlay, current: nil))
    }

    func testSamePlayerPageIsNotLeaving() {
        XCTAssertFalse(left(netflixPlay, "https://www.netflix.com/watch/81234567?trackId=1"))
        XCTAssertFalse(left(huluPlay, "https://www.hulu.com/watch/other-episode"))
    }

    func testSiteHomeOrTitleIsLeaving() {
        XCTAssertTrue(left(netflixPlay, "https://www.netflix.com/browse"))
        XCTAssertTrue(left(netflixPlay, "https://www.netflix.com/title/80100172"))
        XCTAssertTrue(left(huluPlay, "https://www.hulu.com/hub/home"))
        XCTAssertTrue(left(huluPlay, "https://www.hulu.com/"))
    }

    func testSubdomainOfSameSiteCounts() {
        XCTAssertTrue(left(huluPlay, "https://secure.hulu.com/account"))
        XCTAssertFalse(left(huluPlay, "https://secure.hulu.com/watch/x"))
    }

    func testOtherSiteIsNotLeaving() {
        XCTAssertFalse(left(netflixPlay, "https://accounts.example.org/login"))
        XCTAssertFalse(left(netflixPlay, "about:blank"))
        XCTAssertFalse(left(netflixPlay, "https://www.nothulu.com/browse"))
    }

    func testIsOnPlayer() {
        XCTAssertTrue(PlayerExit.isOnPlayer(playURL: huluPlay, current: URL(string: "https://www.hulu.com/watch/x")))
        XCTAssertFalse(PlayerExit.isOnPlayer(playURL: huluPlay, current: URL(string: "https://www.hulu.com/hub/home")))
        XCTAssertFalse(PlayerExit.isOnPlayer(playURL: huluPlay, current: nil))
    }

    func testPlayURLWithoutPathNeverLeaves() {
        XCTAssertFalse(left(URL(string: "https://www.hulu.com/")!, "https://www.hulu.com/hub/home"))
    }
}
