import XCTest
@testable import CouchModeCore

final class NetflixHomeTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/netflix-browse-graphql", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func home() throws -> StreamHome {
        try XCTUnwrap(NetflixHome.parse(graphQLCache: try fixtureData()))
    }

    func testProfiles() throws {
        let h = try home()
        XCTAssertEqual(h.serviceID, "netflix")
        XCTAssertEqual(h.profiles.map(\.name), (1...5).map { "Profile \($0)" })
        XCTAssertEqual(h.currentProfile?.name, "Profile 1")
        XCTAssertEqual(h.currentProfileID, "SYNTHPROFILE0000000000000002")
        XCTAssertEqual(h.profiles.map(\.isKids), [false, false, true, true, true])
    }

    func testRowsInOrderWithKinds() throws {
        let rows = try home().rows
        XCTAssertEqual(rows.map(\.title), ["New on Netflix", "Continue Watching for Profile 1",
                                           "Today's Top Picks for You", "We Think You\u{2019}ll Love These"])
        XCTAssertEqual(rows.map(\.kind), [.standard, .continueWatching, .standard, .standard])
        XCTAssertEqual(rows[1].totalCount, 11)
        XCTAssertEqual(rows[1].titles.count, 3)
        XCTAssertFalse(rows.contains { $0.titles.isEmpty })
    }

    func testContinueWatchingShowPlaysCurrentEpisode() throws {
        let wonka = try XCTUnwrap(home().rows[1].titles.first { $0.id == "70002877" })
        XCTAssertEqual(wonka.name, "Golf Special")
        XCTAssertEqual(wonka.kind, .show)
        XCTAssertEqual(wonka.play.absoluteString, "https://www.netflix.com/watch/70004384")
        XCTAssertEqual(wonka.page?.absoluteString, "https://www.netflix.com/title/70002877")
        XCTAssertEqual(wonka.resumeSeconds, 2289)
        XCTAssertEqual(wonka.runtimeSeconds, 3140)
        XCTAssertNotNil(wonka.progress)
    }

    func testShowWithoutBookmarkHasNoResume() throws {
        let love = try XCTUnwrap(home().rows[1].titles.first { $0.id == "70000959" })
        XCTAssertEqual(love.play.absoluteString, "https://www.netflix.com/watch/70004932")
        XCTAssertNil(love.resumeSeconds)
        XCTAssertEqual(love.runtimeSeconds, 4157)
    }

    func testHero() throws {
        let hero = try XCTUnwrap(home().hero)
        XCTAssertEqual(hero.id, "70005069")
        XCTAssertEqual(hero.kind, .movie)
        XCTAssertFalse(hero.name.isEmpty)
        XCTAssertTrue(try XCTUnwrap(hero.synopsis).hasPrefix("A small-town hair"))
        XCTAssertEqual(hero.heroArt?.absoluteString, "https://art.invalid/1.jpg")
        XCTAssertEqual(hero.rating, "R")
        XCTAssertEqual(hero.play.absoluteString, "https://www.netflix.com/watch/70005069")
    }

    func testTileArtIsFixtureArt() throws {
        let titles = try home().rows.flatMap(\.titles)
        XCTAssertFalse(titles.isEmpty)
        for t in titles {
            let art = try XCTUnwrap(t.tileArt, t.name).absoluteString
            XCTAssertTrue(art.hasPrefix("https://art.invalid/") && art.hasSuffix(".jpg"), art)
        }
        // The widest of the two continue-watching sizes (665 wide) wins.
        XCTAssertEqual(try home().rows[1].titles[0].tileArt?.absoluteString, "https://art.invalid/13.jpg")
    }

    func testShowFacts() throws {
        let one = try XCTUnwrap(home().rows.flatMap(\.titles).first { $0.id == "70000274" })
        XCTAssertEqual(one.name, "Sample Long-Runner")
        XCTAssertEqual(one.seasonsLabel, "37 Seasons")
        XCTAssertEqual(one.year, 1999)
        XCTAssertEqual(one.play.absoluteString, "https://www.netflix.com/watch/70000411")
    }

    func testNotABrowsePageIsNil() {
        XCTAssertNil(NetflixHome.parse(graphQLCache: Data("garbage".utf8)))
        XCTAssertNil(NetflixHome.parse(graphQLCache: Data("{}".utf8)))
        XCTAssertNil(NetflixHome.parse(graphQLCache: Data("[]".utf8)))
        XCTAssertNil(NetflixHome.parse(graphQLCache: Data(#"{"ROOT_QUERY":{"currentProfile":{"__ref":"Profile:x"}}}"#.utf8)))
        XCTAssertNil(NetflixHome.parse(graphQLCache: Data(#"{"ROOT_QUERY":{"pinotBrowsePage({})":{"__ref":"Missing:1"}}}"#.utf8)))
    }

    func testMalformedPiecesAreSkipped() {
        let json = #"""
        {"ROOT_QUERY":{"pinotBrowsePage({})":{"__ref":"P:1"}},
         "P:1":{"sections({})":{"edges":[{"node":{"__ref":"PinotCarouselSection:a"}},{"node":5},{"node":{"__ref":"Nope"}}]}},
         "PinotCarouselSection:a":{"displayString":"Row","entities":{"edges":[{"node":{"__ref":"T:1"}},{"node":"x"}]}},
         "T:1":{"displayString":"X","unifiedEntity":{"__ref":"Movie:{\"videoId\":\"abc\"}"}},
         "Movie:{\"videoId\":\"abc\"}":{"videoId":"abc"}}
        """#
        let h = NetflixHome.parse(graphQLCache: Data(json.utf8))
        XCTAssertEqual(h?.rows.count, 0)
        XCTAssertEqual(h?.profiles.count, 0)
        XCTAssertNil(h?.hero)
    }

    func testURLValidation() {
        XCTAssertEqual(NetflixHome.playURL(videoID: "123")?.absoluteString, "https://www.netflix.com/watch/123")
        XCTAssertEqual(NetflixHome.pageURL(videoID: "123")?.absoluteString, "https://www.netflix.com/title/123")
        for bad in ["", "12a", "1/2", "../x", " 1", "1?x=y", "\u{0663}"] {
            XCTAssertNil(NetflixHome.playURL(videoID: bad), bad)
            XCTAssertNil(NetflixHome.pageURL(videoID: bad), bad)
        }
        XCTAssertEqual(NetflixHome.switchProfileURL(profileID: "AbC123")?.absoluteString,
                       "https://www.netflix.com/SwitchProfile?tkn=AbC123")
        XCTAssertNotNil(NetflixHome.switchProfileURL(profileID: String(repeating: "a", count: 64)))
        for bad in ["", String(repeating: "a", count: 65), "a-b", "a&b=c", "a b", "é"] {
            XCTAssertNil(NetflixHome.switchProfileURL(profileID: bad), bad)
        }
    }

    func testExtractScript() {
        XCTAssertFalse(NetflixHome.extractScript.isEmpty)
        XCTAssertTrue(NetflixHome.extractScript.contains("reactContext"))
        XCTAssertTrue(NetflixHome.extractScript.contains("catch"))
        XCTAssertTrue(NetflixHome.extractScript.contains(String(NetflixHome.maxCacheBytes)))
    }
}
