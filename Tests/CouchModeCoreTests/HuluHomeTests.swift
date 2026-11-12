import XCTest
@testable import CouchModeCore

final class HuluHomeTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hulu-home-read", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func item(id: String = "00000000-0000-4000-8000-000000000042", type: String = "series", name: String = "Show Z",
                      subtitle: String? = nil, action: String? = nil, eab: String? = "EAB::00000000-0000-4000-8000-000000000099::1::2",
                      tile: String? = "https://img.hulu.invalid/a?x=1") -> String {
        func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        return #"{"id":\#(q(id)),"type":\#(q(type)),"name":\#(q(name)),"subtitle":\#(q(subtitle)),"action":\#(q(action)),"body":"Placeholder.","eab":\#(q(eab)),"tile":\#(q(tile)),"wide":\#(q(tile))}"#
    }

    private func home(rows: [(String, String, [String])], current: String = "null") -> String {
        let rowJSON = rows.map { #"{"id":"\#($0.0)","name":"\#($0.1)","items":[\#($0.2.joined(separator: ","))]}"# }
        return #"{"rows":[\#(rowJSON.joined(separator: ","))],"profiles":[],"currentProfileId":\#(current)}"#
    }

    func testFixtureBecomesAHomeWithRowsHeroAndProfiles() throws {
        let home = try XCTUnwrap(HuluHome.parse(try fixture()))
        XCTAssertEqual(home.serviceID, "hulu")
        XCTAssertEqual(home.rows.map(\.title), ["TV for You", "Movies for You", "Continue Watching", "Top 15 Today"],
                       "Spotlight is the hero, the networks row is empty once networks are dropped")
        XCTAssertEqual(home.rows.map(\.id), ["hulu-row-47", "hulu-row-48", "hulu-row-282", "hulu-row-8869"])
        XCTAssertEqual(home.rows.map(\.kind), [.standard, .standard, .continueWatching, .ranked])
        XCTAssertEqual(home.hero?.name, "Movie A")
        XCTAssertEqual(home.hero?.kind, .movie)
        XCTAssertEqual(home.profiles.map(\.name), ["Profile 1", "Profile 2", "Profile 3", "Profile 4"])
        XCTAssertEqual(home.profiles.map(\.isKids), [false, false, false, true])
        XCTAssertEqual(home.currentProfileID, "1001")
        XCTAssertEqual(home.currentProfile?.name, "Profile 1")
    }

    func testTitlesCarryHuluAddressesLabelsAndArt() throws {
        let home = try XCTUnwrap(HuluHome.parse(try fixture()))
        let continueRow = try XCTUnwrap(home.rows.first { $0.kind == .continueWatching })
        let first = try XCTUnwrap(continueRow.titles.first)
        XCTAssertEqual(first.name, "Show D")
        XCTAssertEqual(first.kind, .show)
        XCTAssertEqual(first.episodeLabel, "S1 · E7")
        XCTAssertEqual(continueRow.titles.map(\.episodeLabel), ["S1 · E7", "S1 · E3", "S38 · E3"])
        XCTAssertEqual(first.page?.absoluteString, "https://www.hulu.com/series/\(first.id)")
        XCTAssertTrue(first.play.absoluteString.hasPrefix("https://www.hulu.com/watch/"))
        XCTAssertNotEqual(first.play.lastPathComponent, first.id, "plays the episode the eab names, not the series")
        XCTAssertEqual(first.synopsis, "Placeholder synopsis for Show D.")
        let tile = try XCTUnwrap(first.tileArt)
        XCTAssertEqual(tile.host, "img.hulu.invalid")
        let operations = try XCTUnwrap(URLComponents(url: tile, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "operations" }?.value)
        XCTAssertEqual(operations, #"[{"resize":"640x360|max"},{"format":"jpeg"}]"#)
        let hero = try XCTUnwrap(home.hero)
        XCTAssertTrue(try XCTUnwrap(URLComponents(url: try XCTUnwrap(hero.heroArt), resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "operations" }?.value).contains("1920x1080"))
        XCTAssertEqual(hero.page?.absoluteString, "https://www.hulu.com/movie/\(hero.id)")
        XCTAssertNil(hero.episodeLabel)
    }

    func testKeepsOnlySeriesMoviesAndEpisodesAndSkipsTitlesWithNothingToPlay() throws {
        let json = home(rows: [("1", "Mixed", [
            item(id: "a1", type: "network"), item(id: "a2", type: "hub"), item(id: "a3", type: "series"),
            item(id: "a4", type: "movie"), item(id: "a5", type: "episode", subtitle: "S2 E5 - Name"),
            item(id: "a6", type: "series", eab: nil), item(id: "a7", type: "series", eab: "EAB::NULL::1::2"),
            item(id: "bad id!", type: "series"),
        ]), ("2", "Only networks", [item(id: "b1", type: "network")])])
        let result = try XCTUnwrap(HuluHome.parse(json))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].titles.map(\.id), ["a3", "a4", "a5"])
        XCTAssertEqual(result.rows[0].titles.map(\.kind), [.show, .movie, .episode])
        XCTAssertNil(result.rows[0].titles[2].page, "an episode has no title page of its own")
        XCTAssertEqual(result.rows[0].titles[2].episodeLabel, "S2 · E5")
    }

    func testEpisodeLabelOnlyMarksWhereYouAre() throws {
        // A show's label is its current episode: only when Hulu offers to resume it.
        // A recommendation's "S1 E1" subtitle is just where it would start.
        let json = home(rows: [("1", "Mixed", [
            item(id: "c1", type: "series", subtitle: "S1 E7 - Name", action: "Resume Episode"),
            item(id: "c2", type: "series", subtitle: "S1 E1 - Name", action: "Start Watching"),
            item(id: "c3", type: "series", subtitle: "S23 E1 - Name", action: "Watch Latest Season"),
            item(id: "c4", type: "episode", subtitle: "S2 E5 - Name", action: "Watch Episode"),
        ])])
        let titles = try XCTUnwrap(HuluHome.parse(json)).rows[0].titles
        XCTAssertEqual(titles.map(\.episodeLabel), ["S1 · E7", nil, nil, "S2 · E5"])
    }

    func testSpotlightRowsAreNotRowsAndTheFirstOneGivesTheHero() throws {
        let json = home(rows: [("1", "Spotlight", [item(id: "h1", type: "network"), item(id: "h2", type: "movie", name: "Movie H")]),
                               ("2", "Spotlight", [item(id: "h3", type: "movie", name: "Movie I")]),
                               ("3", "Popular", [item(id: "p1")])])
        let result = try XCTUnwrap(HuluHome.parse(json))
        XCTAssertEqual(result.hero?.id, "h2", "the first Spotlight row's first title the home can show")
        XCTAssertEqual(result.rows.map(\.title), ["Popular"])
    }

    func testRowKindsFollowTheRowName() throws {
        let json = home(rows: [("1", "Continue Watching for Profile 1", [item(id: "c1")]), ("2", "Top 10 Movies", [item(id: "c2")]),
                               ("3", "Top Picks", [item(id: "c3")]), ("4", "Comedy", [item(id: "c4")])])
        XCTAssertEqual(try XCTUnwrap(HuluHome.parse(json)).rows.map(\.kind), [.continueWatching, .ranked, .standard, .standard])
    }

    func testImageHostsMustBeHttpsHulu() {
        XCTAssertNotNil(HuluHome.imageURL("https://img2.hulu.com/user/v3/artwork/x?a=1", width: 640, height: 360))
        XCTAssertNotNil(HuluHome.imageURL("https://img.hulu.invalid/x", width: 640, height: 360))
        XCTAssertNil(HuluHome.imageURL("http://img2.hulu.com/x", width: 640, height: 360), "plain http")
        XCTAssertNil(HuluHome.imageURL("https://evilhulu.com/x", width: 640, height: 360), "lookalike host")
        XCTAssertNil(HuluHome.imageURL("https://hulu.com.evil.example/x", width: 640, height: 360))
        XCTAssertNil(HuluHome.imageURL("https://example.com/x", width: 640, height: 360))
        XCTAssertNil(HuluHome.imageURL(nil, width: 640, height: 360))
    }

    func testImageSizeReplacesAnOperationsParameterTheAddressAlreadyHas() throws {
        let url = try XCTUnwrap(HuluHome.imageURL(#"https://img2.hulu.com/x?base_image=1&operations=%5B%7B%22resize%22:%22200x200%7Cmax%22%7D%5D"#,
                                                  width: 640, height: 360))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "operations" }.count, 1)
        XCTAssertEqual(items.first { $0.name == "base_image" }?.value, "1")
        XCTAssertTrue(url.absoluteString.contains("640x360"))
    }

    func testProfilesNeedAnIdAndANameAndStayBounded() throws {
        let many = (1...15).map { #"{"id":"\#($0)","name":"Profile \#($0)","kids":false}"# }
        let json = #"{"rows":[{"id":"1","name":"Popular","items":[\#(item())]}],"profiles":[{"id":"bad id","name":"X","kids":false},{"id":"7","name":"","kids":false},\#(many.joined(separator: ","))],"currentProfileId":"3"}"#
        let result = try XCTUnwrap(HuluHome.parse(json))
        XCTAssertEqual(result.profiles.count, StreamLimits.maxProfiles)
        XCTAssertEqual(result.profiles.first?.id, "1")
        XCTAssertEqual(result.currentProfileID, "3")
    }

    func testAnythingElseIsNotAHome() {
        XCTAssertNil(HuluHome.parse(""))
        XCTAssertNil(HuluHome.parse("not json"))
        XCTAssertNil(HuluHome.parse("[]"))
        XCTAssertNil(HuluHome.parse(#"{"profiles":[]}"#), "no rows key")
        XCTAssertNil(HuluHome.parse(#"{"rows":[{"id":"1","name":"Networks","items":[]}],"profiles":[]}"#), "nothing to show")
    }

    func testRowsAreCapped() throws {
        let titles = (1...(StreamLimits.maxTitlesPerRow + 10)).map { item(id: "t\($0)") }
        let rows = (1...(StreamLimits.maxRows + 5)).map { ("\($0)", "Row \($0)", titles) }
        let result = try XCTUnwrap(HuluHome.parse(home(rows: rows)))
        XCTAssertEqual(result.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(result.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    func testProfileSwitchScriptsUseTheTopBarsListAndQuoteTheId() {
        let choose = HuluHome.chooseProfileScript(profileID: #"1"001"#)
        XCTAssertTrue(choose.contains("Switch profile to"))
        XCTAssertTrue(choose.contains(#""1\"001""#), "the id is quoted")
        XCTAssertTrue(choose.contains("!== 1"), "a name two profiles share is refused")
        XCTAssertTrue(HuluHome.profileIsCurrentScript(profileID: "1002").contains(#""1002""#))
        XCTAssertTrue(HuluHome.profileListReadyScript.contains("ProfileList__profile-item"))
        for script in [choose, HuluHome.profileListReadyScript, HuluHome.profileIsCurrentScript(profileID: "1")] {
            XCTAssertFalse(script.contains("email"))
            XCTAssertFalse(script.contains("birthdate"))
        }
    }

    func testScriptReadsTheHomeThePageMakesAndNoPersonalData() {
        XCTAssertTrue(HuluHome.extractScript.contains("discoverHref"))
        XCTAssertFalse(HuluHome.extractScript.contains("email"))
        XCTAssertFalse(HuluHome.extractScript.contains("birthdate"))
    }
}
