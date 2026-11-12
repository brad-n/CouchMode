// Owns: the checks for AppleTVHome and the card rules it shares with AppleTVSite: how the channel
// canvas's shelves become rows, the hero, Up Next with progress and the play addresses.
import XCTest
@testable import CouchModeCore

final class AppleTVHomeTests: XCTestCase {
    private func fixture(_ name: String = "appletv-home-read") throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFixtureBecomesAHomeWithHeroRowsAndOneProfile() throws {
        let home = try XCTUnwrap(AppleTVHome.parse(try fixture()))
        XCTAssertEqual(home.serviceID, "appletv")
        XCTAssertEqual(home.hero?.name, "Stage Show")
        XCTAssertEqual(home.rows.map(\.title), ["Continue Watching", "Top 10 Shows", "New Releases"], "the stage is the hero; the empty shelf is dropped")
        XCTAssertEqual(home.rows.map(\.kind), [.continueWatching, .ranked, .standard])
        XCTAssertEqual(home.rows[0].id, "appletv-row-uts.col.UpNext")
        XCTAssertEqual(home.profiles.count, 1)
        XCTAssertEqual(home.currentProfileID, home.profiles.first?.id)
        XCTAssertFalse(home.asksWhoIsWatching)
    }

    func testUpNextCarriesProgressEpisodeLabelAndThePlayerAddressOfTheEpisode() throws {
        let home = try XCTUnwrap(AppleTVHome.parse(try fixture()))
        let up = home.rows[0].titles
        XCTAssertEqual(up.map(\.name), ["Synthetic Series", "Synthetic Movie", "Next Episode Show", "Rent This One"], "bad id and off-site cards are dropped")
        let show = up[0]
        XCTAssertEqual(show.kind, .show)
        XCTAssertEqual(show.episodeLabel, "S2 · E3")
        XCTAssertEqual(show.runtimeSeconds, 3000)
        XCTAssertEqual(show.resumeSeconds, 750)
        XCTAssertEqual(try XCTUnwrap(show.progress), 0.25, accuracy: 0.001)
        XCTAssertEqual(show.remainingText, "38 min left")
        XCTAssertEqual(show.id, "umc.cmc.synthshow1", "a continued episode stands for its show")
        XCTAssertEqual(show.page?.absoluteString, "https://tv.apple.com/us/show/synthetic-series/umc.cmc.synthshow1")
        XCTAssertEqual(show.play.absoluteString, "https://tv.apple.com/us/episode/pilot/umc.cmc.synthep0001?showId=umc.cmc.synthshow1&action=play")
        XCTAssertEqual(show.tileArt?.absoluteString, "https://example.invalid/image/thumb/synthtile1/640x360KF.TVALC03.jpg?color=C78469")
    }

    func testFinishedUnwatchedAndUnplayableTitlesHaveNoProgressAndTheRightPlayAddress() throws {
        let up = try XCTUnwrap(AppleTVHome.parse(try fixture())).rows[0].titles
        XCTAssertNil(up[1].progress, "cursor at the end is finished")
        XCTAssertEqual(up[1].kind, .movie)
        XCTAssertEqual(up[1].year, 2019)
        XCTAssertEqual(up[1].play.absoluteString, "https://tv.apple.com/us/movie/synthetic-movie/umc.cmc.synthmovie1?action=play")
        XCTAssertNil(up[2].progress)
        XCTAssertEqual(up[2].episodeLabel, "S1 · E2")
        XCTAssertEqual(up[3].play.absoluteString, "https://tv.apple.com/us/movie/rent-this-one/umc.cmc.synthrent1",
                       "a title this account can't play opens its own page instead")
        XCTAssertEqual(up[3].play, up[3].page)
    }

    func testTitleWithoutArtAndPortraitOnlyCardsHaveNoTileArt() throws {
        let home = try XCTUnwrap(AppleTVHome.parse(try fixture()))
        XCTAssertNil(home.rows[0].titles[1].tileArt)
        XCTAssertNotNil(home.rows[1].titles[0].tileArt)
        XCTAssertNil(home.rows[1].titles[1].tileArt)
        XCTAssertEqual(home.hero?.heroArt?.absoluteString, "https://example.invalid/image/thumb/synthstage/1920x1080.jpg")
    }

    func testBoundsHold() {
        let cards = (1...(StreamLimits.maxTitlesPerRow + 15)).map {
            #"{"id":"umc.cmc.t\#($0)","kind":"show","name":"T\#($0)","page":"https://tv.apple.com/us/show/t/umc.cmc.t\#($0)"}"#
        }
        let shelves = (1...(StreamLimits.maxRows + 5)).map {
            #"{"id":"s\#($0)","name":"Row \#($0)","type":"lockup","items":[\#(cards.joined(separator: ","))]}"#
        }
        let home = AppleTVHome.parse(#"{"rows":[\#(shelves.joined(separator: ","))]}"#)
        XCTAssertEqual(home?.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(home?.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    func testMalformedOrEmptyDataIsNil() {
        XCTAssertNil(AppleTVHome.parse(""))
        XCTAssertNil(AppleTVHome.parse("not json"))
        XCTAssertNil(AppleTVHome.parse("{}"))
        XCTAssertNil(AppleTVHome.parse(#"{"rows":[]}"#))
        XCTAssertNil(AppleTVHome.parse(#"{"rows":[{"id":"a","name":"A","type":"lockup","items":[{"id":"x"}]}]}"#))
        XCTAssertNil(AppleTVHome.parse(#"{"rows":"nope"}"#))
    }

    func testDuplicateShelfIdsAreKeptOnce() {
        let card = #"{"id":"umc.cmc.one1","kind":"movie","name":"One","page":"https://tv.apple.com/us/movie/one/umc.cmc.one1"}"#
        let row = #"{"id":"same","name":"Row","type":"lockup","items":[\#(card)]}"#
        XCTAssertEqual(AppleTVHome.parse(#"{"rows":[\#(row),\#(row)]}"#)?.rows.count, 1)
    }

    func testPlayAddressKeepsItsQueryAndReplacesAnEarlierAction() throws {
        let page = try XCTUnwrap(URL(string: "https://tv.apple.com/us/episode/x/umc.cmc.e1?showId=umc.cmc.s1&action=play"))
        XCTAssertEqual(AppleTVSite.playURL(page: page)?.absoluteString, "https://tv.apple.com/us/episode/x/umc.cmc.e1?showId=umc.cmc.s1&action=play")
        XCTAssertNil(AppleTVSite.playURL(page: try XCTUnwrap(URL(string: "https://example.com/x"))))
    }

    func testImageAddressesAreFilledInAndRefuseOtherHostsAndLeftoverTemplates() {
        XCTAssertEqual(AppleTVSite.imageURL("https://is1-ssl.mzstatic.com/image/thumb/abc/{w}x{h}.{f}", width: 640)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/abc/640x360.jpg")
        XCTAssertEqual(AppleTVSite.imageURL("https://is1-ssl.mzstatic.com/image/thumb/abc/{w}x{h}{c}.{f}", width: 1920)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/thumb/abc/1920x1080sr.jpg")
        XCTAssertNil(AppleTVSite.imageURL("https://evil.example.com/{w}x{h}.{f}", width: 640))
        XCTAssertNil(AppleTVSite.imageURL("http://is1-ssl.mzstatic.com/{w}x{h}.{f}", width: 640))
        XCTAssertNil(AppleTVSite.imageURL("https://is1-ssl.mzstatic.com/{w}x{h}{z}.{f}", width: 640))
        XCTAssertNil(AppleTVSite.imageURL("https://is1-ssl.mzstatic.com/a.jpg", width: 0))
        XCTAssertNil(AppleTVSite.imageURL(nil, width: 640))
    }

    func testSessionPageRulesAndScriptsKeepTokensInside() {
        XCTAssertTrue(AppleTVSite.isUsableSessionPage(AppleTVSite.sessionPageURL))
        XCTAssertFalse(AppleTVSite.isUsableSessionPage(URL(string: "https://tv.apple.com/us/episode/x/umc.cmc.e1?action=play")))
        XCTAssertFalse(AppleTVSite.isUsableSessionPage(URL(string: "https://example.com/")))
        XCTAssertFalse(AppleTVSite.isUsableSessionPage(nil))
        let script = AppleTVHome.extractScript
        XCTAssertTrue(script.contains("canvases/channels/tvs.sbd.4000"))
        XCTAssertTrue(script.contains("try {") && script.contains(#"return "";"#))
        XCTAssertFalse(script.contains("return kit.developerToken") || script.contains("return userToken"))
        XCTAssertTrue(AppleTVSite.playerShownScript.contains("dialog.playback-view"))
    }
}
