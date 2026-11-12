import XCTest
@testable import CouchModeCore

final class PrimeHomeTests: XCTestCase {
    private func fixture(_ name: String = "prime-home-read") throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFixtureBecomesAHomeWithHeroRowsAndProfiles() throws {
        let home = try XCTUnwrap(PrimeHome.parse(try fixture()))
        XCTAssertEqual(home.serviceID, "prime")
        XCTAssertEqual(home.hero?.name, "Hero Show")
        XCTAssertEqual(home.rows.map(\.title), ["Continue watching", "Popular now", "Top 10 shows"],
                       "the hero row is the billboard; the empty row is dropped")
        XCTAssertEqual(home.rows.map(\.kind), [.continueWatching, .standard, .ranked])
        XCTAssertEqual(home.profiles.map(\.name), ["Profile 1", "Profile 3", "Profile 4"],
                       "a name that appears twice is left out")
        XCTAssertEqual(home.currentProfileID, "Profile 1")
        XCTAssertEqual(home.profiles[1].isKids, true)
        XCTAssertNotNil(home.profiles[0].avatar)
        XCTAssertNil(home.profiles[2].avatar, "plain http avatars are refused")
    }

    func testContinueWatchingCarriesPlayAddressAndProgress() throws {
        let home = try XCTUnwrap(PrimeHome.parse(try fixture()))
        let cw = try XCTUnwrap(home.rows.first).titles
        XCTAssertEqual(cw.map(\.name), ["Show One", "Movie Two", "Show Three"])
        let show = cw[0]
        XCTAssertEqual(show.id, "CW1season2")
        XCTAssertEqual(show.kind, .show)
        XCTAssertEqual(show.episodeLabel, "S2", "the season comes from the title's suffix")
        XCTAssertEqual(show.play.absoluteString, "https://www.primevideo.com/detail/CW1ep0005?autoplay=1&t=1737")
        XCTAssertEqual(show.page?.absoluteString, "https://www.primevideo.com/detail/CW1season2")
        XCTAssertEqual(show.resumeSeconds, 1737)
        XCTAssertEqual(try XCTUnwrap(show.runtimeSeconds), 3130, accuracy: 3, "length is worked out from position and percent")
        XCTAssertEqual(try XCTUnwrap(show.progress), 0.555, accuracy: 0.01)
        XCTAssertEqual(cw[1].kind, .movie)
        XCTAssertNotNil(cw[1].remainingText)
        XCTAssertNil(cw[2].resumeSeconds, "a queued show with no position has no progress")
        XCTAssertEqual(cw[2].play.absoluteString, "https://www.primevideo.com/detail/CW3ep00001?autoplay=1")
    }

    func testOffersAreKeptAndOpenTheirPageNotAPlayer() throws {
        let home = try XCTUnwrap(PrimeHome.parse(try fixture()))
        let popular = try XCTUnwrap(home.rows.first { $0.title == "Popular now" }).titles
        XCTAssertEqual(popular.map(\.name), ["Movie Four", "Movie To Rent", "Show Without Art"],
                       "a bad id and a nameless title are dropped")
        let offer = popular[1]
        XCTAssertEqual(offer.play, offer.page, "no playback action: Play opens the title's page")
        XCTAssertEqual(offer.page?.absoluteString, "https://www.primevideo.com/detail/P2rent0001")
        XCTAssertNil(popular[2].tileArt)
    }

    func testArtIsAskedAtTheWidthWithoutThePagesOverlay() throws {
        let home = try XCTUnwrap(PrimeHome.parse(try fixture()))
        let cw = try XCTUnwrap(home.rows.first).titles[0]
        XCTAssertEqual(cw.tileArt?.absoluteString, "https://example.invalid/images/S/synthetic-a/cover001._SX640_.jpg",
                       "the composite's badges are dropped; the plain image is sized")
        XCTAssertEqual(cw.heroArt?.absoluteString, "https://example.invalid/images/S/synthetic-a/cover001._SX1920_.jpg")
        XCTAssertEqual(home.hero?.heroArt?.absoluteString, "https://example.invalid/images/S/synthetic-a/hero0001._SX1920_.jpg")
    }

    func testImageURLRefusesOddAddresses() {
        XCTAssertNil(PrimeSite.imageURL("http://example.invalid/a/b.jpg", width: 640))
        XCTAssertNil(PrimeSite.imageURL("https://evil.test/a/b.jpg", width: 640))
        XCTAssertNil(PrimeSite.imageURL("https://example.invalid/a/b.jpg", width: 0))
        XCTAssertNil(PrimeSite.imageURL("https://example.invalid/a/b.jpg", width: 99_999))
        XCTAssertNil(PrimeSite.imageURL(nil, width: 640))
        XCTAssertEqual(PrimeSite.imageURL("https://m.media-amazon.com/images/S/x/y.png", width: 320)?.absoluteString,
                       "https://m.media-amazon.com/images/S/x/y._SX320_.jpg")
        XCTAssertEqual(PrimeSite.imageURL("https://images-na.ssl-images-amazon.com/images/S/x/y._UR1920,1080_CLs%7Cz.jpg", width: 640)?.absoluteString,
                       "https://images-na.ssl-images-amazon.com/images/S/x/y._SX640_.jpg")
    }

    func testAddressesPointAtPrimeAndRefuseOddIds() {
        XCTAssertEqual(PrimeSite.playURL(id: "abc123XYZ", resumeSeconds: 0)?.absoluteString, "https://www.primevideo.com/detail/abc123XYZ?autoplay=1")
        XCTAssertEqual(PrimeSite.playURL(id: "abc123XYZ", resumeSeconds: 90)?.absoluteString, "https://www.primevideo.com/detail/abc123XYZ?autoplay=1&t=90")
        XCTAssertNil(PrimeSite.playURL(id: "../x", resumeSeconds: nil))
        XCTAssertNil(PrimeSite.pageURL(id: "a/b"))
        XCTAssertNil(PrimeSite.pageURL(id: ""))
    }

    func testRowsAndTitlesStayWithinTheLimits() throws {
        let items = (0..<(StreamLimits.maxTitlesPerRow + 10)).map {
            #"{"id":"T\#(String(format: "%08d", $0))","name":"T\#($0)","type":"Movie","playId":null}"#
        }.joined(separator: ",")
        let rows = (0..<(StreamLimits.maxRows + 5)).map { #"{"id":"\#($0)","name":"Row \#($0)","type":"StandardCarousel","cw":false,"items":[\#(items)]}"# }
        let home = try XCTUnwrap(PrimeHome.parse(#"{"rows":[\#(rows.joined(separator: ","))],"profiles":[]}"#))
        XCTAssertEqual(home.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(home.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    func testBadOrEmptyDataIsNil() {
        XCTAssertNil(PrimeHome.parse(""))
        XCTAssertNil(PrimeHome.parse("[]"))
        XCTAssertNil(PrimeHome.parse(#"{"rows":"no"}"#))
        XCTAssertNil(PrimeHome.parse(#"{"rows":[],"profiles":[]}"#))
        XCTAssertNil(PrimeHome.parse(#"{"rows":[{"id":"0","name":"x","type":"t","cw":false,"items":[{"id":"zz"}]}],"profiles":[]}"#))
    }

    func testScriptsQuoteTheProfileNameAndNeverTouchTheCsrfValue() {
        let name = #"Mo"\n</script>"#
        XCTAssertTrue(PrimeHome.chooseProfileScript(profileID: name).contains(StreamJSON.jsString(name)))
        XCTAssertTrue(PrimeHome.profileIsCurrentScript(profileID: name).contains(StreamJSON.jsString(name)))
        for script in [PrimeHome.extractScript, PrimeHome.chooseProfileScript(profileID: "x")] {
            XCTAssertFalse(script.lowercased().contains("csrf"), "the profile form is submitted as the page's own button; its token is never read")
        }
    }
}
