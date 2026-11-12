import XCTest
@testable import CouchModeCore

final class NetflixDetailsTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "netflix-details-read", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let show = StreamTitle(id: "70000959", name: "A Show", kind: .show,
                                   play: URL(string: "https://www.netflix.com/watch/1")!,
                                   page: URL(string: "https://www.netflix.com/title/70000959"))

    func testShowDetailsCarryTheSynopsisSeasonsAndTheShownSeasonsEpisodes() throws {
        let details = try XCTUnwrap(NetflixDetails.details(fromRead: try fixture(), title: show))
        XCTAssertEqual(details.title.synopsis, "Show synopsis.")
        XCTAssertEqual(details.title.id, show.id, "the row's title, filled in")
        XCTAssertEqual(details.seasons.map(\.name), ["S1: Alpha", "S2: Bravo", "S3: Charlie"], "the nameless entry is skipped")
        XCTAssertEqual(details.currentSeasonID, "70001096")
        let shown = try XCTUnwrap(details.seasons.first { $0.id == "70001096" })
        XCTAssertEqual(shown.episodes.map(\.id), ["70001233", "70001370", "70001507"])
        XCTAssertEqual(shown.episodes.first?.number, 1)
        XCTAssertEqual(shown.episodes.first?.play.absoluteString, "https://www.netflix.com/watch/70001233")
        XCTAssertEqual(shown.episodes.first?.resumeSeconds, 26)
        XCTAssertEqual(shown.episodes.first?.runtimeSeconds, 3533)
        XCTAssertEqual(shown.episodes.first?.synopsis, "Synopsis for episode 1.")
        XCTAssertEqual(shown.episodes.first?.art?.absoluteString, "https://art.invalid/ep-1.jpg")
        XCTAssertNil(shown.episodes[1].resumeSeconds)
        XCTAssertTrue(details.seasons.filter { $0.id != "70001096" }.allSatisfy { $0.episodes.isEmpty },
                      "other seasons load when they're opened")
    }

    func testAMovieHasJustItsSynopsis() throws {
        let read = #"{"synopsis":"A movie.","currentSeasonId":null,"seasonLabel":null,"seasons":[],"episodes":[]}"#
        let details = try XCTUnwrap(NetflixDetails.details(fromRead: read, title: show))
        XCTAssertEqual(details.title.synopsis, "A movie.")
        XCTAssertTrue(details.seasons.isEmpty)
        XCTAssertNil(details.currentSeasonID)
    }

    func testAShowWithoutASeasonPickerGetsOneSeasonFromItsLabel() throws {
        let read = #"{"synopsis":null,"currentSeasonId":42,"seasonLabel":"Limited Series","seasons":[],"episodes":[{"id":7,"number":1,"name":"Part One","runtime":3000}]}"#
        let details = try XCTUnwrap(NetflixDetails.details(fromRead: read, title: show))
        XCTAssertEqual(details.seasons.map(\.name), ["Limited Series"])
        XCTAssertEqual(details.seasons.first?.id, "42")
        XCTAssertEqual(details.currentSeasonID, "42")
        XCTAssertEqual(details.seasons.first?.episodes.map(\.name), ["Part One"])
        XCTAssertNil(details.title.synopsis, "nothing to add keeps the row's")
    }

    func testEpisodesSkipBadEntries() throws {
        let read = #"{"episodes":[{"id":null,"name":"No id"},{"id":"12a","name":"Bad id"},{"id":9,"number":4},{"id":10,"name":"Ten","art":"http://plain.invalid/x.jpg"}]}"#
        let episodes = NetflixDetails.episodes(fromRead: read)
        XCTAssertEqual(episodes.map(\.id), ["9", "10"])
        XCTAssertEqual(episodes.first?.name, "Episode 4", "a nameless episode is named by its number")
        XCTAssertNil(episodes.last?.art, "plain-http art is dropped")
        XCTAssertNil(NetflixDetails.details(fromRead: "not json", title: show))
        XCTAssertEqual(NetflixDetails.episodes(fromRead: "not json"), [])
    }

    func testScriptsQuoteWhatTheyAreGiven() {
        let choose = NetflixDetails.chooseSeasonScript(seasonName: #"S1: "Quoted""#)
        XCTAssertTrue(choose.contains(#""S1: \"Quoted\"""#))
        XCTAssertTrue(choose.contains("dropdown-menu-item"))
        XCTAssertTrue(NetflixDetails.seasonShownScript(seasonID: "70001096").contains(#""70001096""#))
        XCTAssertTrue(NetflixDetails.readyScript.contains("preview-modal-synopsis"))
    }

    func testReadScriptWaitsForEpisodesOnlyWhenTheTitleMayHaveThem() {
        XCTAssertTrue(NetflixDetails.readScript(for: .show).contains(#"const expect = "episodes";"#))
        XCTAssertTrue(NetflixDetails.readScript(for: .movie).contains(#"const expect = "none";"#))
        XCTAssertTrue(NetflixDetails.readScript(for: .other).contains(#"const expect = "unknown";"#))
        XCTAssertTrue(NetflixDetails.readScript(for: .show).contains("section-expand"))
    }

    func testChoosingASeasonComparesWordsNotSpaces() {
        // Seen on a real Mac: "S10: Ohio\u{00A0}\u{00A0}(13 Episodes)" - the gap is non-breaking spaces.
        XCTAssertTrue(NetflixDetails.chooseSeasonScript(seasonName: "S10: Ohio").contains(#"replace(/\s+/g, " ")"#))
    }

    func testChoosingASeasonUsesAnAlreadyOpenMenu() {
        let script = NetflixDetails.chooseSeasonScript(seasonName: "S2: Bravo")
        // The menu is looked for before the toggle is clicked, so an open menu isn't closed.
        let find = script.range(of: "let item = findItem();")
        let click = script.range(of: "toggle.click();")
        XCTAssertNotNil(find)
        XCTAssertNotNil(click)
        if let find, let click { XCTAssertLessThan(find.lowerBound, click.lowerBound) }
    }
}
