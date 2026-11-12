import XCTest
@testable import CouchModeCore

final class DisneyDetailsTests: XCTestCase {
    private func read(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func rowTitle(kind: StreamTitle.Kind = .show, id: String = "00000000-0000-4000-8000-000000000102") -> StreamTitle {
        let page = DisneyExplore.pageURL(entityID: id)
        return StreamTitle(id: id, name: "Show B", kind: kind, play: page ?? DisneyExplore.sessionPageURL, page: page,
                           synopsis: "Short.", year: 2000, tileArt: URL(string: "https://example.invalid/tile"))
    }

    func testShowDetailsHaveSeasonsCurrentSeasonAndAnEpisodeToPlay() throws {
        let details = try XCTUnwrap(DisneyDetails.details(fromRead: try read("disney-details-read"), title: rowTitle()))
        XCTAssertEqual(details.title.kind, .show)
        XCTAssertEqual(details.title.synopsis, "Placeholder synopsis for Show B, the longer one.")
        XCTAssertEqual(details.title.year, 2023)
        XCTAssertEqual(details.title.rating, "TV-PG")
        XCTAssertEqual(details.title.seasonsLabel, "2 Seasons")
        XCTAssertEqual(details.title.play.absoluteString, "https://www.disneyplus.com/play/00000000-0000-4000-8000-000000000201")
        XCTAssertEqual(details.title.tileArt?.absoluteString, "https://example.invalid/tile", "the row's art is kept")
        XCTAssertNotNil(details.title.heroArt)
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"])
        XCTAssertTrue(details.seasons.allSatisfy { $0.episodes.isEmpty }, "episodes arrive when a season is opened")
        XCTAssertEqual(details.currentSeasonID, "00000000-0000-4000-8000-000000000302")
    }

    func testMovieDetailsHaveALengthAndWhereToResume() throws {
        let id = "00000000-0000-4000-8000-000000000101"
        let details = try XCTUnwrap(DisneyDetails.details(fromRead: try read("disney-movie-details-read"), title: rowTitle(kind: .show, id: id)))
        XCTAssertEqual(details.title.kind, .movie, "the page knows what the row only guessed")
        XCTAssertEqual(details.title.runtimeSeconds, 6000)
        XCTAssertEqual(details.title.resumeSeconds, 1500)
        XCTAssertEqual(details.title.play.absoluteString, "https://www.disneyplus.com/play/\(id)")
        XCTAssertTrue(details.seasons.isEmpty)
        XCTAssertNil(details.currentSeasonID)
        XCTAssertNil(details.title.seasonsLabel)
    }

    func testDetailsWithoutAPlayerKeepTheRowsAddress() throws {
        let json = #"{"id":"a1","name":"X","series":false,"seasons":[]}"#
        let title = rowTitle(kind: .movie)
        let details = try XCTUnwrap(DisneyDetails.details(fromRead: json, title: title))
        XCTAssertEqual(details.title.play, title.play)
    }

    func testSeasonEpisodesHaveNumbersRuntimeProgressAndPlayAddresses() throws {
        let episodes = DisneyDetails.episodes(fromSeason: try read("disney-season-read"))
        XCTAssertEqual(episodes.map(\.name), ["Episode One", "Episode Two", "Episode Three"])
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3])
        XCTAssertEqual(episodes[0].play.absoluteString, "https://www.disneyplus.com/play/00000000-0000-4000-8000-000000000501")
        XCTAssertEqual(episodes[1].runtimeSeconds, 2640)
        XCTAssertEqual(episodes[1].resumeSeconds, 1056)
        XCTAssertNil(episodes[0].resumeSeconds, "a finished episode isn't resumed")
        XCTAssertNil(episodes[2].resumeSeconds)
        XCTAssertNotNil(episodes[0].art)
        XCTAssertNil(episodes[2].art)
    }

    func testEpisodesSkipBadIdsDuplicatesAndAreCapped() {
        let json = #"{"episodes":[{"id":"e1","playId":"bad id","name":"A"},{"id":"e2","playId":"p2","name":"B"},{"id":"e2","playId":"p2","name":"B again"},{"id":"e3"}]}"#
        XCTAssertEqual(DisneyDetails.episodes(fromSeason: json).map(\.id), ["e2"])
        XCTAssertEqual(DisneyDetails.episodes(fromSeason: "nope"), [])
        let many = (1...(StreamLimits.maxEpisodesPerSeason + 20)).map { #"{"id":"e\#($0)","playId":"p\#($0)","name":"E"}"# }
        XCTAssertEqual(DisneyDetails.episodes(fromSeason: #"{"episodes":[\#(many.joined(separator: ","))]}"#).count, StreamLimits.maxEpisodesPerSeason)
    }

    func testMalformedDetailsAreNil() {
        XCTAssertNil(DisneyDetails.details(fromRead: "", title: rowTitle()))
        XCTAssertNil(DisneyDetails.details(fromRead: "[1]", title: rowTitle()))
    }

    func testScriptsTakeOnlyPlainIdsAndUseThePagesOwnRequests() {
        let page = DisneyDetails.readScript(entityID: "00000000-0000-4000-8000-000000000102") ?? ""
        XCTAssertTrue(page.contains("\"page/entity-\""))
        XCTAssertTrue(page.contains("00000000-0000-4000-8000-000000000102"))
        XCTAssertNil(DisneyDetails.readScript(entityID: "x\"; evil()"))
        let season = DisneyDetails.seasonScript(seasonID: "00000000-0000-4000-8000-000000000301")
        XCTAssertTrue(season?.contains("\"season/\"") == true)
        XCTAssertNil(DisneyDetails.seasonScript(seasonID: "../x"))
    }
}
