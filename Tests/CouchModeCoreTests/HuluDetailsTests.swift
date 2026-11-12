import XCTest
@testable import CouchModeCore

final class HuluDetailsTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let seriesID = "00000000-0000-4000-8000-000000000001"
    private var show: StreamTitle {
        StreamTitle(id: seriesID, name: "Show A", kind: .show, play: URL(string: "https://www.hulu.com/watch/x")!,
                    page: URL(string: "https://www.hulu.com/series/\(seriesID)"))
    }

    func testShowDetailsCarryFactsSeasonsAndTheShownSeasonsEpisodes() throws {
        let details = try XCTUnwrap(HuluDetails.details(fromRead: try fixture("hulu-details-read"), title: show))
        XCTAssertEqual(details.title.id, seriesID, "the row's title, filled in")
        XCTAssertEqual(details.title.name, "Show A")
        XCTAssertEqual(details.title.synopsis, "Placeholder synopsis for Show A.")
        XCTAssertEqual(details.title.rating, "TVMA")
        XCTAssertEqual(details.title.year, 2020)
        XCTAssertEqual(details.title.seasonsLabel, "2 Seasons")
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(details.currentSeasonID, "\(seriesID)::1")
        let shown = try XCTUnwrap(details.seasons.first)
        XCTAssertEqual(shown.episodes.count, 10)
        let first = try XCTUnwrap(shown.episodes.first)
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.name, "Episode 1")
        XCTAssertEqual(first.runtimeSeconds, 1594)
        XCTAssertEqual(first.play.absoluteString, "https://www.hulu.com/watch/\(first.id)")
        XCTAssertEqual(first.art?.host, "img.hulu.invalid")
        XCTAssertNil(first.resumeSeconds)
        XCTAssertTrue(details.seasons[1].episodes.isEmpty, "another season loads when it's opened")
    }

    func testAShowFromSearchGetsTheEpisodePlayContinues() throws {
        let fromSearch = StreamTitle(id: seriesID, name: "Show A", kind: .show,
                                     play: URL(string: "https://www.hulu.com/watch/\(seriesID)")!)
        let details = try XCTUnwrap(HuluDetails.details(fromRead: try fixture("hulu-details-read"), title: fromSearch))
        XCTAssertEqual(details.title.play.absoluteString, "https://www.hulu.com/watch/00000000-0000-4000-8000-000000000004")
        XCTAssertEqual(details.title.play.lastPathComponent, details.seasons[0].episodes[2].id, "the third episode")
        XCTAssertEqual(details.title.episodeLabel, "S1 · E3")
        XCTAssertEqual(details.title.name, "Show A")
        XCTAssertEqual(details.title.page, fromSearch.page)
    }

    func testResumeIsTheShareOfTheEpisodeAlreadyWatched() throws {
        let details = try XCTUnwrap(HuluDetails.details(fromRead: try fixture("hulu-details-read"), title: show))
        let third = try XCTUnwrap(details.seasons[0].episodes.first { $0.number == 3 })
        XCTAssertEqual(third.resumeSeconds, 1434 * 40 / 100)
        XCTAssertEqual(third.runtimeSeconds, 1434)
    }

    func testAnotherSeasonsEpisodes() throws {
        let episodes = HuluDetails.episodes(fromSeason: try fixture("hulu-season-read"))
        XCTAssertEqual(episodes.count, 6)
        XCTAssertEqual(episodes.map(\.number), Array(1...6))
        XCTAssertEqual(episodes.first?.synopsis, "Placeholder synopsis for episode 1.")
        XCTAssertTrue(episodes.allSatisfy { $0.play.absoluteString.hasPrefix("https://www.hulu.com/watch/") })
    }

    func testMovieDetailsHaveASynopsisYearRatingAndLengthButNoSeasons() throws {
        let movie = StreamTitle(id: "m1", name: "Movie A", kind: .movie, play: URL(string: "https://www.hulu.com/watch/m1")!)
        let json = #"{"name":"Movie A","description":"Placeholder.","rating":"R","premiere":"2026-08-07T19:00:00Z","duration":6253,"genres":[],"currentSeasonId":null,"seasons":[],"shownEpisodes":[]}"#
        let details = try XCTUnwrap(HuluDetails.details(fromRead: json, title: movie))
        XCTAssertEqual(details.title.synopsis, "Placeholder.")
        XCTAssertEqual(details.title.year, 2026)
        XCTAssertEqual(details.title.runtimeSeconds, 6253)
        XCTAssertNil(details.title.seasonsLabel)
        XCTAssertTrue(details.seasons.isEmpty)
        XCTAssertNil(details.currentSeasonID)
    }

    func testASingleSeasonShowIsThatSeasonAndIsCurrent() throws {
        let json = #"{"description":"x","currentSeasonId":null,"seasons":[{"id":"s::1","name":"Limited Series"}],"shownEpisodes":[]}"#
        let details = try XCTUnwrap(HuluDetails.details(fromRead: json, title: show))
        XCTAssertEqual(details.title.seasonsLabel, "1 Season")
        XCTAssertEqual(details.currentSeasonID, "s::1")
    }

    func testSkipsBadEpisodesAndDuplicatesAndKeepsTheRowsTitleWhenFactsAreMissing() throws {
        let json = #"{"seasons":[{"id":"a::1","name":"Season 1"},{"id":"a::1","name":"Again"},{"id":"a::2","name":""}],"currentSeasonId":"a::1","shownEpisodes":[{"id":"bad id","name":"Bad"},{"id":"e1","number":"2","name":"Two","progress":150,"duration":100},{"id":"e1","name":"Dup"},{"id":"e2","number":null,"name":null}]}"#
        let details = try XCTUnwrap(HuluDetails.details(fromRead: json, title: show))
        XCTAssertEqual(details.seasons.map(\.id), ["a::1"])
        XCTAssertEqual(details.seasons[0].episodes.map(\.id), ["e1", "e2"])
        XCTAssertNil(details.seasons[0].episodes[0].resumeSeconds, "progress out of range")
        XCTAssertEqual(details.seasons[0].episodes[1].name, "Episode")
        XCTAssertNil(details.title.synopsis)
        XCTAssertNil(details.title.rating)
    }

    func testAnythingElseIsNotDetails() {
        XCTAssertNil(HuluDetails.details(fromRead: "", title: show))
        XCTAssertNil(HuluDetails.details(fromRead: "[]", title: show))
        XCTAssertEqual(HuluDetails.episodes(fromSeason: "not json"), [])
    }

    func testEpisodesAreCapped() throws {
        let list = (1...(StreamLimits.maxEpisodesPerSeason + 20)).map { #"{"id":"e\#($0)","number":"\#($0)","name":"E"}"# }
        let json = #"{"episodes":[\#(list.joined(separator: ","))]}"#
        XCTAssertEqual(HuluDetails.episodes(fromSeason: json).count, StreamLimits.maxEpisodesPerSeason)
    }

    func testScriptsAskOnlyDiscoverAndOnlyForTheShownTitle() {
        XCTAssertTrue(HuluDetails.readScript.contains("hubs/"))
        XCTAssertTrue(HuluDetails.readScript.contains("startsWith(base)"), "refuses addresses off the discover service")
        XCTAssertTrue(HuluDetails.seasonScript(seasonID: "x\"y").contains(#""x\"y""#), "the season id is quoted")
        XCTAssertTrue(HuluDetails.seasonScript(seasonID: "a::2").contains("/season/"))
        for script in [HuluDetails.readScript, HuluDetails.seasonScript(seasonID: "a::2")] {
            XCTAssertFalse(script.contains("email"))
            XCTAssertFalse(script.contains("birthdate"))
        }
    }
}
