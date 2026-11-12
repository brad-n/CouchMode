import XCTest
@testable import CouchModeCore

final class DemoArtSpecTests: XCTestCase {
    func testSeedIsStableAcrossRuns() {
        // FNV-1a of "a" is a published constant.
        XCTAssertEqual(DemoArtSpec.fnv1a("a"), 0xaf63dc4c8601ec8c)
        XCTAssertEqual(DemoArtSpec(kind: .tile, title: "Saltglass").seed, DemoArtSpec(kind: .hero, title: "Saltglass").seed)
    }

    func testUnitIsInRangeAndRepeatable() {
        let spec = DemoArtSpec(kind: .tile, title: "Lantern Harbor")
        for i in 0..<200 {
            let v = spec.unit(i)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
            XCTAssertEqual(v, spec.unit(i))
        }
        XCTAssertNotEqual(spec.unit(1), spec.unit(2))
    }

    func testUrlRoundTripsIncludingAwkwardTitles() {
        for title in ["Saltglass", "Marrow & Tide", "Quill & Compass 1.2", "A/B ? # %", "Ünïcode Ñame"] {
            for kind in DemoArtKind.allCases {
                let spec = DemoArtSpec(kind: kind, title: title)
                XCTAssertEqual(DemoArtSpec(url: spec.url), spec, "\(kind) \(title)")
            }
        }
    }

    func testOnlyDemoAddressesParse() {
        XCTAssertNil(DemoArtSpec(url: URL(string: "https://example.invalid/art/tile?title=x")!))
        XCTAssertNil(DemoArtSpec(url: URL(string: "couchmode-demo://art/poster?title=x")!))
        XCTAssertNil(DemoArtSpec(url: URL(string: "couchmode-demo://art/tile")!))
        XCTAssertNil(DemoArtSpec(url: URL(string: "couchmode-demo://other/tile?title=x")!))
    }

    func testTitleIsBounded() {
        XCTAssertEqual(DemoArtSpec(kind: .tile, title: String(repeating: "x", count: 500)).title.count, 80)
    }

    func testPixelSizes() {
        XCTAssertEqual(DemoArtSpec(kind: .tile, title: "t").pixelSize.width * 9, DemoArtSpec(kind: .tile, title: "t").pixelSize.height * 16)
        XCTAssertEqual(DemoArtSpec(kind: .hero, title: "t").pixelSize.width * 9, DemoArtSpec(kind: .hero, title: "t").pixelSize.height * 16)
        XCTAssertEqual(DemoArtSpec(kind: .square, title: "t").pixelSize.width, DemoArtSpec(kind: .square, title: "t").pixelSize.height)
    }

    func testPaletteIsValidDarkToLightAndVariedAcrossTitles() {
        var motifs = Set<DemoMotif>()
        var darks = Set<Double>()
        for title in DemoCatalog.titles.map(\.name) {
            let spec = DemoArtSpec(kind: .tile, title: title)
            let p = spec.palette
            for c in [p.dark, p.mid, p.light, p.accent] {
                XCTAssertTrue((0...1).contains(c.red) && (0...1).contains(c.green) && (0...1).contains(c.blue), title)
            }
            XCTAssertLessThan(p.dark.red + p.dark.green + p.dark.blue, p.light.red + p.light.green + p.light.blue, title)
            motifs.insert(spec.motif)
            darks.insert(p.dark.red)
        }
        XCTAssertGreaterThan(motifs.count, 3)
        XCTAssertGreaterThan(darks.count, 15)
    }

    func testColorConversionKnownValues() {
        XCTAssertEqual(DemoColor(hue: 0, saturation: 1, brightness: 1), DemoColor(hue: 1, saturation: 1, brightness: 1))
        let green = DemoColor(hue: 1.0 / 3, saturation: 1, brightness: 1)
        XCTAssertEqual(green.green, 1, accuracy: 1e-9)
        XCTAssertEqual(green.red, 0, accuracy: 1e-9)
        let grey = DemoColor(hue: 0.7, saturation: 0, brightness: 0.5)
        XCTAssertEqual([grey.red, grey.green, grey.blue], [0.5, 0.5, 0.5])
        let negative = DemoColor(hue: -0.25, saturation: 1, brightness: 1)
        XCTAssertEqual(negative, DemoColor(hue: 0.75, saturation: 1, brightness: 1))
    }
}

final class DemoCatalogTests: XCTestCase {
    func testTitlesAreUniqueAndComplete() {
        XCTAssertEqual(Set(DemoCatalog.titles.map(\.id)).count, DemoCatalog.titles.count)
        XCTAssertEqual(Set(DemoCatalog.titles.map(\.name)).count, DemoCatalog.titles.count)
        for t in DemoCatalog.titles {
            XCTAssertFalse(t.synopsis.isEmpty)
            XCTAssertEqual(t.isShow, t.seasons > 0, t.name)
        }
    }

    func testEveryAddressIsInventedOrDemoArt() {
        let home = DemoCatalog.home(serviceID: "netflix")
        let all = home.rows.flatMap(\.titles) + [home.hero].compactMap { $0 }
        XCTAssertFalse(all.isEmpty)
        for t in all {
            XCTAssertEqual(t.play.host, "example.invalid")
            XCTAssertEqual(t.page?.host, "example.invalid")
            XCTAssertEqual(t.tileArt?.scheme, DemoArtSpec.scheme)
            XCTAssertEqual(t.heroArt?.scheme, DemoArtSpec.scheme)
        }
    }

    func testHomeIsBoundedAndShaped() {
        let home = DemoCatalog.home(serviceID: "hulu")
        XCTAssertEqual(home.bounded, StreamHome(serviceID: home.serviceID, profiles: home.profiles, currentProfileID: home.currentProfileID,
                                                hero: home.hero, rows: home.rows.filter { !$0.titles.isEmpty }))
        XCTAssertEqual(home.rows.first?.kind, .continueWatching)
        XCTAssertTrue(home.rows.first?.titles.allSatisfy { $0.progress != nil } ?? false)
        XCTAssertEqual(home.rows.first { $0.kind == .ranked }?.titles.count, 10)
        XCTAssertEqual(home.currentProfileID, "alex")
        XCTAssertNotNil(home.currentProfile)
        XCTAssertLessThanOrEqual(home.profiles.count, StreamLimits.maxProfiles)
    }

    func testServicesGetDifferentOrders() {
        XCTAssertNotEqual(DemoCatalog.home(serviceID: "netflix").hero?.id, DemoCatalog.home(serviceID: "hulu").hero?.id)
        XCTAssertEqual(DemoCatalog.home(serviceID: "netflix"), DemoCatalog.home(serviceID: "netflix"))
    }

    func testShowDetailsHaveSeasonsAndFirstSeasonEpisodes() {
        let show = DemoCatalog.streamTitle(DemoCatalog.titles.first { $0.id == "lantern-harbor" }!, service: "netflix")
        let details = DemoCatalog.details(for: show, service: "netflix")
        XCTAssertEqual(details.seasons.count, 3)
        XCTAssertEqual(details.currentSeasonID, "s1")
        XCTAssertFalse(details.seasons[0].episodes.isEmpty)
        XCTAssertTrue(details.seasons[1].episodes.isEmpty)
        XCTAssertEqual(details.bounded, details)
        let later = DemoCatalog.episodes(season: 2, of: show, service: "netflix")
        XCTAssertEqual(Set(later.map(\.id)).count, later.count)
        XCTAssertTrue(Set(later.map(\.id)).isDisjoint(with: details.seasons[0].episodes.map(\.id)))
    }

    func testMovieDetailsHaveNoSeasons() {
        let movie = DemoCatalog.streamTitle(DemoCatalog.titles.first { !$0.isShow }!, service: "netflix")
        XCTAssertTrue(DemoCatalog.details(for: movie, service: "netflix").seasons.isEmpty)
    }

    func testSearchMatchesWordsAndFallsBack() {
        let hits = DemoCatalog.search("lantern", service: "netflix").map(\.name)
        XCTAssertTrue(hits.contains("Lantern Harbor"))
        XCTAssertTrue(hits.contains("Tin Lantern"))
        XCTAssertEqual(DemoCatalog.search("zzzz", service: "netflix").count, 4)
        XCTAssertLessThanOrEqual(DemoCatalog.search("", service: "hulu").count, StreamLimits.maxSearchResults)
    }

    func testPlexSamplesAreOrdinary() {
        XCTAssertGreaterThanOrEqual(DemoCatalog.plexContinue.count, 4)
        for p in DemoCatalog.plexContinue { XCTAssertTrue((0...1).contains(p.progress)) }
        let items = DemoCatalog.continueItems()
        XCTAssertEqual(items.count, DemoCatalog.plexContinue.count)
        XCTAssertEqual(Set(items.map(\.ratingKey)).count, items.count)
        XCTAssertEqual(items.sorted { $0.lastViewedAt > $1.lastViewedAt }.map(\.ratingKey), items.map(\.ratingKey))
        XCTAssertNotNil(items[0].remainingText)
    }

    func testGamesExistOnlyForSampleConsolesAndFileNamesRoundTrip() {
        for id in DemoCatalog.gameConsoleIDs {
            let console = ConsoleCatalog.all.first { $0.id == id }!
            let games = DemoCatalog.games(forConsole: id)
            XCTAssertFalse(games.isEmpty, id)
            let names = games.map { DemoCatalog.fileName($0, console: console) }
            // The library code must accept each file name as a game of its console.
            XCTAssertEqual(GameLibrary.games(fileNames: names, for: console).count, games.count, id)
            for (g, n) in zip(games, names) { XCTAssertEqual(DemoCatalog.game(fileName: n), g) }
        }
        XCTAssertTrue(DemoCatalog.games(forConsole: "psx").isEmpty)
        XCTAssertNil(DemoCatalog.game(fileName: "Unknown.nes"))
    }

    func testSwitchGamesShareGenresForGenreRows() {
        let genres = DemoCatalog.games(forConsole: "switch").flatMap(\.genres)
        XCTAssertGreaterThanOrEqual(Set(genres).filter { g in genres.filter { $0 == g }.count >= 2 }.count, 3)
    }

    func testCatalogJSONDecodesAsASwitchCatalogGame() throws {
        let game = DemoCatalog.games(forConsole: "switch")[0]
        let decoded = try JSONDecoder().decode(CatalogGame.self, from: game.catalogJSON(titleID: "DEMO0001"))
        XCTAssertEqual(decoded.name, game.title)
        XCTAssertEqual(decoded.genres, game.genres)
        XCTAssertEqual(decoded.summary, game.blurb)
        XCTAssertEqual(decoded.releaseYear, "\(game.year)")
    }

    func testPlayedHistoryNamesRealSampleGames() {
        for id in DemoCatalog.gameConsoleIDs {
            let titles = Set(DemoCatalog.games(forConsole: id).map(\.title))
            for name in DemoCatalog.playedSecondsAgo(console: id).keys { XCTAssertTrue(titles.contains(name), name) }
        }
    }
}
