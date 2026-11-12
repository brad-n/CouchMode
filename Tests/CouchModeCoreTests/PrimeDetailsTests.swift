import XCTest
@testable import CouchModeCore

final class PrimeDetailsTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func row(_ id: String, kind: StreamTitle.Kind, name: String) -> StreamTitle {
        StreamTitle(id: id, name: name, kind: kind, play: PrimeSite.pageURL(id: id)!, page: PrimeSite.pageURL(id: id))
    }

    func testShowGetsFactsSeasonsAndTheCurrentEpisodeToPlay() throws {
        let row = row("S2season02", kind: .show, name: "Show One")
        let details = try XCTUnwrap(PrimeDetails.details(fromRead: try fixture("prime-details-show-read"), title: row))
        XCTAssertEqual(details.title.kind, .show)
        XCTAssertEqual(details.title.synopsis, "A longer synopsis of the season.")
        XCTAssertEqual(details.title.rating, "TV-MA")
        XCTAssertEqual(details.title.year, 2025)
        XCTAssertEqual(details.title.play.absoluteString, "https://www.primevideo.com/detail/S2ep000003?autoplay=1&t=1440")
        XCTAssertEqual(details.title.episodeLabel, "S2 · E3")
        XCTAssertEqual(details.title.resumeSeconds, 1440)
        XCTAssertEqual(details.title.runtimeSeconds, 4231)
        XCTAssertEqual(details.title.seasonsLabel, "2 Seasons")
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"], "a repeated or odd season id is dropped")
        XCTAssertEqual(details.currentSeasonID, "S2season02")
        XCTAssertTrue(details.seasons[0].episodes.isEmpty, "other seasons load when opened")
        XCTAssertEqual(details.seasons[1].episodes.count, 3)
    }

    func testEpisodesCarryNumberPlayAddressAndProgress() throws {
        let episodes = PrimeDetails.episodes(fromRead: try fixture("prime-details-show-read"))
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3], "an episode with no player address is left out")
        XCTAssertEqual(episodes[0].name, "First Period")
        XCTAssertEqual(episodes[0].play.absoluteString, "https://www.primevideo.com/detail/S2ep000001?autoplay=1")
        XCTAssertEqual(episodes[0].runtimeSeconds, 2903)
        XCTAssertNil(episodes[0].resumeSeconds)
        XCTAssertEqual(episodes[2].name, "Episode 3", "a missing name falls back to its number")
        XCTAssertEqual(episodes[2].resumeSeconds, 1440)
        XCTAssertEqual(episodes[2].art?.absoluteString, "https://example.invalid/images/S/synthetic-a/ep0003._SX640_.jpg")
        XCTAssertNil(episodes[1].art)
    }

    func testSingleSeasonShowGetsOneSeasonFromThePageItself() throws {
        let row = row("L1limited1", kind: .show, name: "Limited Show")
        let details = try XCTUnwrap(PrimeDetails.details(fromRead: try fixture("prime-details-single-season-read"), title: row))
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1"])
        XCTAssertEqual(details.seasons[0].id, "L1limited1")
        XCTAssertEqual(details.currentSeasonID, "L1limited1")
        XCTAssertEqual(details.seasons[0].episodes.count, 1)
        XCTAssertEqual(details.title.seasonsLabel, "1 Season")
        XCTAssertEqual(details.title.episodeLabel, "S1 · E1", "the label 'Play Episode 1' uses the page's season")
    }

    func testMovieHasLengthAndPlace() throws {
        let row = row("M1movie001", kind: .show, name: "Movie Four")
        let details = try XCTUnwrap(PrimeDetails.details(fromRead: try fixture("prime-details-movie-read"), title: row))
        XCTAssertEqual(details.title.kind, .movie)
        XCTAssertEqual(details.title.runtimeSeconds, 5580)
        XCTAssertEqual(details.title.resumeSeconds, 600)
        XCTAssertTrue(details.seasons.isEmpty)
        XCTAssertNil(details.title.seasonsLabel)
        XCTAssertEqual(details.title.play.absoluteString, "https://www.primevideo.com/detail/M1movie001?autoplay=1&t=600")
    }

    func testTitleToRentKeepsItsPageAsPlayAndReadsLengthFromText() throws {
        let row = row("P2rent0001", kind: .movie, name: "Movie To Rent")
        let details = try XCTUnwrap(PrimeDetails.details(fromRead: try fixture("prime-details-offer-read"), title: row))
        XCTAssertEqual(details.title.play, details.title.page, "no playback action: Play opens Prime's own page")
        XCTAssertEqual(details.title.runtimeSeconds, 3900)
        XCTAssertNil(details.title.resumeSeconds)
    }

    func testRuntimeTextShapes() {
        XCTAssertEqual(PrimeDetails.seconds(fromRuntimeText: "1 h 33 min"), 5580)
        XCTAssertEqual(PrimeDetails.seconds(fromRuntimeText: "55min"), 3300)
        XCTAssertEqual(PrimeDetails.seconds(fromRuntimeText: "2 h"), 7200)
        XCTAssertNil(PrimeDetails.seconds(fromRuntimeText: ""))
        XCTAssertNil(PrimeDetails.seconds(fromRuntimeText: "soon"))
    }

    func testNonsenseIsNilOrEmpty() {
        let row = row("X1xxxxxxxx", kind: .movie, name: "X")
        XCTAssertNil(PrimeDetails.details(fromRead: "", title: row))
        XCTAssertNil(PrimeDetails.details(fromRead: "[]", title: row))
        XCTAssertEqual(PrimeDetails.episodes(fromRead: "nope"), [])
    }

    func testScriptsRefuseOddIdsAndQuoteTheRest() {
        XCTAssertNil(PrimeDetails.pageURL(forID: "a/b"))
        XCTAssertEqual(PrimeDetails.pageURL(forID: "abcd1234")?.absoluteString, "https://www.primevideo.com/detail/abcd1234")
        XCTAssertTrue(PrimeDetails.readyScript.contains("detail"))
    }
}
