import XCTest
@testable import CouchModeCore

final class DisneyHomeTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "disney-home-read", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func card(_ id: String, name: String = "Title", extra: String = "") -> String {
        #"{"id":"\#(id)","name":"\#(name)"\#(extra)}"#
    }

    private func home(rows: [(String, String, [String])]) -> String {
        let json = rows.enumerated().map { #"{"id":"r\#($0.offset)","name":"\#($0.element.1)","style":"\#($0.element.0)","items":[\#($0.element.2.joined(separator: ","))]}"# }
        return #"{"rows":[\#(json.joined(separator: ","))],"profiles":[]}"#
    }

    func testFixtureBecomesAHomeWithHeroRowsAndProfiles() throws {
        let home = try XCTUnwrap(DisneyHome.parse(try fixture()))
        XCTAssertEqual(home.serviceID, "disney")
        XCTAssertEqual(home.hero?.name, "Movie A")
        XCTAssertEqual(home.rows.map(\.title), ["Recommended For You", "Continue Watching", "Top 10"], "hero row is the hero; the empty row is dropped")
        XCTAssertEqual(home.rows.map(\.kind), [.standard, .continueWatching, .ranked])
        XCTAssertEqual(home.rows.map(\.id), ["disney-row-00000000-0000-4000-8000-0000000000a2", "disney-row-00000000-0000-4000-8000-0000000000a3",
                                              "disney-row-00000000-0000-4000-8000-0000000000a4"])
        XCTAssertEqual(home.profiles.map(\.name), ["Profile 1", "Profile 2", "Profile 3"])
        XCTAssertEqual(home.currentProfileID, "Profile 1")
        XCTAssertEqual(home.currentProfile?.avatar?.absoluteString, "https://example.invalid/avatar/1")
        XCTAssertNil(home.profiles[2].avatar)
    }

    func testTitlesCarryDisneyAddressesFactsAndArt() throws {
        let home = try XCTUnwrap(DisneyHome.parse(try fixture()))
        let rec = try XCTUnwrap(home.rows.first).titles
        XCTAssertEqual(rec.map(\.name), ["Movie C", "Show D", "Show E without art"])
        XCTAssertEqual(rec.map(\.kind), [.movie, .show, .show], "a length means a movie; a show carries none")
        let movie = rec[0]
        XCTAssertEqual(movie.id, "00000000-0000-4000-8000-000000000103")
        XCTAssertEqual(movie.page?.absoluteString, "https://www.disneyplus.com/browse/entity-00000000-0000-4000-8000-000000000103")
        XCTAssertEqual(movie.play, movie.page, "a row title has no player address until its details are read")
        XCTAssertEqual(movie.year, 2019)
        XCTAssertEqual(movie.rating, "PG-13")
        XCTAssertEqual(movie.runtimeSeconds, 7200)
        XCTAssertNil(movie.resumeSeconds)
        let art = try XCTUnwrap(movie.tileArt)
        XCTAssertEqual(art.absoluteString,
                       "https://disney.images.edge.bamgrid.com/ripcut-delivery/v2/variant/disney/00000000-0000-4000-8000-0000000001a3/compose?format=jpeg&width=640")
        XCTAssertNil(rec[2].tileArt)
        let hero = try XCTUnwrap(home.hero)
        XCTAssertTrue(try XCTUnwrap(hero.heroArt).absoluteString.hasSuffix("0000000001b1/compose?format=jpeg&width=1920"))
    }

    func testContinueWatchingPlaysTheEpisodeAndShowsProgress() throws {
        let home = try XCTUnwrap(DisneyHome.parse(try fixture()))
        let row = try XCTUnwrap(home.rows.first { $0.kind == .continueWatching })
        let show = row.titles[0]
        XCTAssertEqual(show.kind, .show)
        XCTAssertEqual(show.episodeLabel, "S2 · E5")
        XCTAssertEqual(show.play.absoluteString, "https://www.disneyplus.com/play/00000000-0000-4000-8000-000000000201")
        XCTAssertEqual(show.page?.absoluteString, "https://www.disneyplus.com/browse/entity-00000000-0000-4000-8000-000000000102")
        XCTAssertEqual(show.runtimeSeconds, 2700)
        XCTAssertEqual(show.resumeSeconds, 1080)
        XCTAssertEqual(try XCTUnwrap(show.progress), 0.4, accuracy: 0.001)
        XCTAssertEqual(show.remainingText, "27 min left")
        let movie = row.titles[1]
        XCTAssertEqual(movie.kind, .movie)
        XCTAssertNil(movie.episodeLabel)
        XCTAssertEqual(movie.resumeSeconds, 5400, "no percentage: the seconds left give the place")
        XCTAssertEqual(movie.play.absoluteString, "https://www.disneyplus.com/play/00000000-0000-4000-8000-000000000101")
    }

    func testDropsCardsWithBadIdsAndRowsWithNothingLeft() throws {
        let json = home(rows: [("standard", "Mixed", [card("bad id!"), card("a1"), card("a2", name: "  ")]), ("standard", "Nothing", [card("bad id!")])])
        let result = try XCTUnwrap(DisneyHome.parse(json))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].titles.map(\.id), ["a1"])
    }

    func testProgressIgnoresNonsense() throws {
        let extra = #","runtimeMs":3600000,"pct":150,"left":-5,"playId":"p1""#
        let result = try XCTUnwrap(DisneyHome.parse(home(rows: [("continue_watching", "Continue Watching", [card("a1", extra: extra)])])))
        XCTAssertNil(result.rows[0].titles[0].resumeSeconds)
    }

    func testBoundsRowsTitlesAndProfiles() throws {
        let cards = (1...(StreamLimits.maxTitlesPerRow + 10)).map { card("t\($0)") }
        let rows = (1...(StreamLimits.maxRows + 5)).map { _ in ("standard", "Row", cards) }
        let profiles = (1...(StreamLimits.maxProfiles + 5)).map { #"{"name":"Profile \#($0)","current":false}"# }
        let json = home(rows: rows).replacingOccurrences(of: #""profiles":[]"#, with: #""profiles":[\#(profiles.joined(separator: ","))]"#)
        let result = try XCTUnwrap(DisneyHome.parse(json))
        XCTAssertEqual(result.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(result.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
        XCTAssertEqual(result.profiles.count, StreamLimits.maxProfiles)
    }

    func testProfilesWithSharedOrEmptyNamesAreLeftOut() throws {
        let json = #"{"rows":[{"id":"r1","name":"R","style":"standard_art","items":[{"id":"a1","name":"T"}]}],"profiles":[{"name":"Same","current":true},{"name":"Same"},{"name":" "},{"name":"Other"}]}"#
        let result = try XCTUnwrap(DisneyHome.parse(json))
        XCTAssertEqual(result.profiles.map(\.name), ["Other"], "a name the page's list can't tell apart can't be switched to by name")
        XCTAssertNil(result.currentProfileID)
    }

    func testMalformedOrEmptyIsNil() {
        XCTAssertNil(DisneyHome.parse(""))
        XCTAssertNil(DisneyHome.parse("not json"))
        XCTAssertNil(DisneyHome.parse(#"{"rows":"x"}"#))
        XCTAssertNil(DisneyHome.parse(#"{"rows":[],"profiles":[]}"#))
    }

    func testScriptsUseThePagesOwnRequestsAndQuoteTheProfile() {
        XCTAssertTrue(DisneyHome.readyScript.contains("DTCI-DISNEYPLUS.WEB-PROD.token"))
        XCTAssertTrue(DisneyHome.extractScript.contains("explore/v1.21/"))
        XCTAssertTrue(DisneyHome.extractScript.contains("globalNav"))
        XCTAssertFalse(DisneyHome.extractScript.contains("console."), "nothing is logged")
        let script = DisneyHome.chooseProfileScript(profileID: #"a "quoted" \ name"#)
        XCTAssertTrue(script.contains(#""a \"quoted\" \\ name""#))
        XCTAssertTrue(DisneyHome.profileIsCurrentScript(profileID: "Profile 2").contains("\"Profile 2\""))
    }

    func testSessionPageIsAQuietDisneyPageAndPlayerPagesAreNotUsable() {
        XCTAssertEqual(DisneyExplore.sessionPageURL.host, "www.disneyplus.com")
        XCTAssertTrue(DisneyExplore.isUsableSessionPage(URL(string: "https://www.disneyplus.com/browse/search")))
        XCTAssertTrue(DisneyExplore.isUsableSessionPage(URL(string: "https://www.disneyplus.com/home")))
        XCTAssertFalse(DisneyExplore.isUsableSessionPage(URL(string: "https://www.disneyplus.com/play/abc")))
        XCTAssertFalse(DisneyExplore.isUsableSessionPage(URL(string: "https://www.disneyplus.com/video/abc")))
        XCTAssertFalse(DisneyExplore.isUsableSessionPage(URL(string: "https://example.com/home")))
        XCTAssertFalse(DisneyExplore.isUsableSessionPage(nil))
    }

    func testImageAddressesAreBuiltOnlyFromPlainIds() {
        XCTAssertNil(DisneyExplore.imageURL("bad/id", width: 640))
        XCTAssertNil(DisneyExplore.imageURL(nil, width: 640))
        XCTAssertNil(DisneyExplore.imageURL("abc", width: 0))
        XCTAssertEqual(DisneyExplore.imageURL("ABC-123", width: 320)?.absoluteString,
                       "https://disney.images.edge.bamgrid.com/ripcut-delivery/v2/variant/disney/ABC-123/compose?format=jpeg&width=320")
        XCTAssertNil(DisneyExplore.avatarURL("http://example.invalid/a"))
        XCTAssertNil(DisneyExplore.avatarURL("https://evil.example/a"))
        XCTAssertNotNil(DisneyExplore.avatarURL("https://prod-ripcut-delivery.disney-plus.net/v1/variant/disney/ABC"))
    }

    // MARK: Profile form (a switch can land on Disney's own "update this profile" page)

    func testProfileFormIsRecognisedByPath() {
        let id = "00000000-0000-4000-8000-000000000201"
        XCTAssertTrue(DisneyHome.isProfileForm(URL(string: "https://www.disneyplus.com/update-profile/\(id)?notif=x")))
        XCTAssertTrue(DisneyHome.isProfileForm(URL(string: "https://www.disneyplus.com/update-profile")))
        XCTAssertFalse(DisneyHome.isProfileForm(URL(string: "https://www.disneyplus.com/browse/search")))
        XCTAssertFalse(DisneyHome.isProfileForm(URL(string: "https://www.disneyplus.com/select-profile")))
        XCTAssertFalse(DisneyHome.isProfileForm(URL(string: "https://www.disneyplus.com/play/\(id)")))
        XCTAssertFalse(DisneyHome.isProfileForm(URL(string: "https://example.invalid/update-profile/\(id)")), "only Disney's own site")
        XCTAssertFalse(DisneyHome.isProfileForm(URL(string: "http://www.disneyplus.com/update-profile/\(id)")))
        XCTAssertFalse(DisneyHome.isProfileForm(nil))
    }

    func testSettledScriptWatchesTheSamePathTheCheckUses() {
        let script = DisneyHome.profileSettledScript(profileID: "Profile 2")
        XCTAssertTrue(script.contains(#""update-profile""#))
        XCTAssertTrue(script.contains(#""Profile 2""#))
    }

    func testCurrentProfileIDIsTheCurrentProfilesName() throws {
        let json = #"{"rows":[{"id":"r0","name":"Row","style":"standard","items":[{"id":"00000000-0000-4000-8000-000000000301","name":"Movie"}]}],"profiles":[{"name":"Profile 4","avatar":null,"current":true},{"name":"Profile 5","avatar":null,"current":false}]}"#
        let home = try XCTUnwrap(DisneyHome.parse(json))
        XCTAssertEqual(home.currentProfileID, "Profile 4")
        XCTAssertEqual(home.currentProfile?.name, "Profile 4")
        XCTAssertEqual(home.profiles.map(\.id), ["Profile 4", "Profile 5"])
    }

    func testPickerAddressAndScriptsChooseByName() {
        XCTAssertEqual(DisneyHome.selectProfileURL.absoluteString, "https://www.disneyplus.com/select-profile")
        let script = DisneyHome.choosePickerProfileScript(profileID: "Profile 1")
        XCTAssertTrue(script.contains(#""Profile 1""#))
        XCTAssertTrue(script.contains("profile-avatar-"))
        XCTAssertTrue(DisneyHome.pickerReadyScript.contains("profile-avatar-"))
        XCTAssertTrue(DisneyHome.leftPickerScript.contains("select-profile"))
    }

    func testReadyOrFormWaitEndsOnEitherCondition() {
        let script = DisneyHome.readyOrFormScript
        XCTAssertTrue(script.contains(#""update-profile""#), "ends on the profile form")
        XCTAssertTrue(script.contains("dropdown-active-profile"), "or on the page being ready")
        XCTAssertTrue(script.contains("DTCI-DISNEYPLUS.WEB-PROD.token"))
        XCTAssertLessThan(try XCTUnwrap(script.range(of: "update-profile")).lowerBound, try XCTUnwrap(script.range(of: "dropdown-active-profile")).lowerBound,
                          "the form is checked first")
    }
}
