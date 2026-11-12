// Owns: the checks for AppleTVDetails: how a title's page data and a season's episodes become the
// details screen's facts, seasons, episodes and play addresses.
import XCTest
@testable import CouchModeCore

final class AppleTVDetailsTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func row(_ id: String, kind: StreamTitle.Kind, name: String) throws -> StreamTitle {
        StreamTitle(id: id, name: name, kind: kind, play: try XCTUnwrap(URL(string: "https://tv.apple.com/us/show/x/\(id)")),
                    page: URL(string: "https://tv.apple.com/us/show/x/\(id)"))
    }

    func testShowDetailsHaveFactsSeasonsCurrentSeasonAndEpisodePlayer() throws {
        let title = try row("umc.cmc.synthshow1", kind: .show, name: "Synthetic Series")
        let details = try XCTUnwrap(AppleTVDetails.details(fromRead: try fixture("appletv-details-show-read"), title: title))
        XCTAssertEqual(details.title.kind, .show)
        XCTAssertEqual(details.title.synopsis, "A synthetic description of a made-up show.")
        XCTAssertEqual(details.title.year, 2022)
        XCTAssertEqual(details.title.rating, "TV-MA")
        XCTAssertEqual(details.title.seasonsLabel, "2 Seasons")
        XCTAssertEqual(details.title.episodeLabel, "S2 · E3")
        XCTAssertEqual(details.title.resumeSeconds, 750)
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"], "bad and repeated ids are dropped")
        XCTAssertEqual(details.currentSeasonID, "umc.cmc.synthseason2")
        XCTAssertEqual(details.title.play.absoluteString, "https://tv.apple.com/us/episode/pilot/umc.cmc.synthep0001?showId=umc.cmc.synthshow1&action=play")
        XCTAssertEqual(details.title.heroArt?.absoluteString, "https://example.invalid/image/thumb/synthwide/1920x1080.jpg")
        XCTAssertTrue(details.seasons.allSatisfy { $0.episodes.isEmpty }, "episodes arrive when a season is opened")
    }

    func testMovieThisAccountCannotPlayKeepsItsPageAsPlay() throws {
        let title = try row("umc.cmc.synthrent1", kind: .movie, name: "Rent This One")
        let details = try XCTUnwrap(AppleTVDetails.details(fromRead: try fixture("appletv-details-movie-read"), title: title))
        XCTAssertEqual(details.title.kind, .movie)
        XCTAssertEqual(details.title.runtimeSeconds, 5400)
        XCTAssertNil(details.title.resumeSeconds)
        XCTAssertNil(details.title.seasonsLabel)
        XCTAssertTrue(details.seasons.isEmpty)
        XCTAssertNil(details.currentSeasonID)
        XCTAssertEqual(details.title.play.absoluteString, "https://tv.apple.com/us/movie/rent-this-one/umc.cmc.synthrent1")
    }

    func testDetailsOfAnotherTitleOrJunkAreNil() throws {
        let other = try row("umc.cmc.other1", kind: .show, name: "Other")
        XCTAssertNil(AppleTVDetails.details(fromRead: try fixture("appletv-details-show-read"), title: other))
        XCTAssertNil(AppleTVDetails.details(fromRead: "", title: other))
        XCTAssertNil(AppleTVDetails.details(fromRead: "[]", title: other))
    }

    func testSeasonEpisodesInOrderWithPlayAddressesAndProgress() throws {
        let episodes = AppleTVDetails.episodes(fromSeason: try fixture("appletv-season-read"))
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3, 5], "a repeated id and an off-site page are dropped")
        XCTAssertEqual(episodes.map(\.name), ["Pilot", "Second", "Locked", "Episode 5"])
        XCTAssertEqual(episodes[0].play.absoluteString, "https://tv.apple.com/us/episode/pilot/umc.cmc.synthep0001?showId=umc.cmc.synthshow1&action=play")
        XCTAssertEqual(episodes[1].resumeSeconds, 900)
        XCTAssertEqual(episodes[1].runtimeSeconds, 2700)
        XCTAssertEqual(episodes[2].play.absoluteString, "https://tv.apple.com/us/episode/locked/umc.cmc.synthep0003?showId=umc.cmc.synthshow1",
                       "an episode this account can't play opens its page")
        XCTAssertNotNil(episodes[0].art)
        XCTAssertNil(episodes[1].art)
    }

    func testEpisodesAreBoundedAndJunkIsEmpty() {
        let many = (1...(StreamLimits.maxEpisodesPerSeason + 20)).map {
            #"{"id":"umc.cmc.e\#($0)","name":"E\#($0)","number":\#($0),"url":"https://tv.apple.com/us/episode/e/umc.cmc.e\#($0)"}"#
        }
        XCTAssertEqual(AppleTVDetails.episodes(fromSeason: #"{"episodes":[\#(many.joined(separator: ","))]}"#).count, StreamLimits.maxEpisodesPerSeason)
        XCTAssertEqual(AppleTVDetails.episodes(fromSeason: "nope"), [])
        XCTAssertEqual(AppleTVDetails.episodes(fromSeason: "{}"), [])
    }

    func testScriptsAskTheRightRequestsAndRefuseOddIds() throws {
        let show = try XCTUnwrap(AppleTVDetails.readScript(id: "umc.cmc.synthshow1", kind: .show))
        XCTAssertTrue(show.contains(#""shows/umc.cmc.synthshow1""#))
        let movie = try XCTUnwrap(AppleTVDetails.readScript(id: "umc.cmc.synthmovie1", kind: .movie))
        XCTAssertTrue(movie.contains(#""movies/umc.cmc.synthmovie1""#))
        XCTAssertNil(AppleTVDetails.readScript(id: "bad id", kind: .show))
        XCTAssertNil(AppleTVDetails.readScript(id: "../shows/x", kind: .show))
        XCTAssertNil(AppleTVDetails.readScript(id: "umc.cmc.ok", kind: .other))
        let season = try XCTUnwrap(AppleTVDetails.seasonScript(showID: "umc.cmc.synthshow1", seasonID: "umc.cmc.synthseason1"))
        XCTAssertTrue(season.contains("selectedSeasonId") && season.contains("selectedEpisodeId") && season.contains("n < \(AppleTVDetails.maxWindows)"))
        XCTAssertNil(AppleTVDetails.seasonScript(showID: "umc.cmc.a", seasonID: "no way"))
        XCTAssertLessThanOrEqual(AppleTVDetails.maxWindows, 6)
    }
}
