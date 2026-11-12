// Owns: tests for first-run setup's pure logic: step sequencing, the default
// choices given installed apps and games folders, the reasons an app is off,
// sign-in status wording, and the order and content of the config it writes.

import XCTest
@testable import CouchModeCore

private func catalog() throws -> AppCatalog {
    try AppCatalog.parse(Data("""
    {"version":1,"apps":[
     {"id":"plex","name":"Plex","kind":"native","native":{"bundleId":"tv.example.htpc"},"site":{"url":"https://plex.example/","userAgent":"safari"}},
     {"id":"a","name":"A","kind":"stream","site":{"url":"https://a.example/","userAgent":"safari"}},
     {"id":"b","name":"B","kind":"stream","site":{"url":"https://b.example/","userAgent":"safari"}},
     {"id":"c","name":"C","kind":"stream","site":{"url":"https://c.example/","userAgent":"safari"},
      "requires":[{"label":"Thing installed","bundleId":"com.example.thing"}]},
     {"id":"settings","name":"Settings","kind":"system"},
     {"id":"ps","name":"PS","kind":"console","console":{"emulator":"app","extensions":["app"],"defaultFolder":"~/Games/ps"}},
     {"id":"nes","name":"NES","kind":"console","console":{"emulator":"retroarch","core":"x.dylib","extensions":["nes"],"defaultFolder":"~/Games/nes"},
      "requires":[{"label":"RetroArch installed","bundleId":"com.example.retro"}]}
    ]}
    """.utf8))
}

private struct Mac {
    var retroArch = true, thing = false, plex = false
    var games: [String: Int] = [:]   // folder text -> game count; absent = no folder
}

private func setup(_ mac: Mac = Mac(), existing: AppConfig? = nil, migrated: [String: [String: ConfigValue]] = [:]) throws -> FirstRunSetup {
    FirstRunSetup(catalog: try catalog(), existing: existing,
                  requirementMet: { r in r.bundleId == "com.example.retro" ? mac.retroArch : mac.thing },
                  nativeInstalled: { _ in mac.plex }, gameCount: { _, folder in mac.games[folder] }, migrated: migrated)
}

final class FirstRunSetupTests: XCTestCase {
    // MARK: Defaults

    func testServicesAreOnByDefaultAndAnUnmetOneIsOffWithItsReason() throws {
        let s = try setup()
        XCTAssertEqual(s.chosen, ["a", "b"])
        let c = try XCTUnwrap(s.apps.first { $0.app.id == "c" })
        XCTAssertEqual(c.note, "needs Thing")
        XCTAssertFalse(c.canToggle)
    }

    func testServicesAreListedBeforeNativeApps() throws {
        XCTAssertEqual(try setup().apps.map(\.app.id), ["a", "b", "c", "plex"])
    }

    func testPlexIsOnOnlyWhenItsAppIsInstalled() throws {
        XCTAssertFalse(try setup().isOn("plex"))
        XCTAssertEqual(try setup().apps.first { $0.app.id == "plex" }?.note, "not installed, opens its website")
        let s = try setup(Mac(plex: true))
        XCTAssertTrue(s.isOn("plex"))
        XCTAssertEqual(s.apps.first { $0.app.id == "plex" }?.note, "")
    }

    func testAConsoleIsOnOnlyWhenItsFolderHasGames() throws {
        let s = try setup(Mac(games: ["~/Games/ps": 3, "~/Games/nes": 0]))
        XCTAssertTrue(s.isOn("ps"))
        XCTAssertFalse(s.isOn("nes"), "found but empty")
        XCTAssertEqual(s.consoles.map(\.status), ["3 games", "Folder is empty"])
        XCTAssertEqual(try setup().consoles.map(\.status), ["Folder not found", "Folder not found"])
        XCTAssertEqual(try setup().chosen, ["a", "b"])
    }

    func testOnlyConsolesWhoseEmulatorIsInstalledAreOffered() throws {
        let s = try setup(Mac(retroArch: false))
        XCTAssertEqual(s.consoles.map(\.app.id), ["ps"])
    }

    func testAnUnmetAppCannotBeToggledOnAndAnUnknownIdIsRefused() throws {
        var s = try setup()
        XCTAssertFalse(s.toggle("c"))
        XCTAssertFalse(s.toggle("settings"))
        XCTAssertFalse(s.toggle("nope"))
        XCTAssertTrue(s.toggle("a"))
        XCTAssertFalse(s.isOn("a"))
        XCTAssertTrue(s.toggle("plex"), "not installed, but it can still be turned on")
    }

    // MARK: Steps

    func testStepsRunInOrderAndBackReturns() throws {
        var s = try setup()
        XCTAssertEqual(s.steps, [.welcome, .apps, .games, .signIn, .done])
        XCTAssertFalse(s.back(), "nothing before Welcome")
        var seen = [s.step]
        while s.advance() { seen.append(s.step) }
        XCTAssertEqual(seen, [.welcome, .apps, .games, .signIn, .done])
        XCTAssertFalse(s.advance(), "nothing after Done")
        XCTAssertTrue(s.back())
        XCTAssertEqual(s.step, .signIn)
    }

    func testGamesIsSkippedWithoutAConsoleAndSignInWithoutAChosenService() throws {
        let cat = try AppCatalog.parse(Data("""
        {"version":1,"apps":[
         {"id":"a","name":"A","kind":"stream","site":{"url":"https://a.example/","userAgent":"safari"}},
         {"id":"settings","name":"Settings","kind":"system"}]}
        """.utf8))
        var s = FirstRunSetup(catalog: cat, existing: nil, requirementMet: { _ in true }, nativeInstalled: { _ in true }, gameCount: { _, _ in nil })
        XCTAssertEqual(s.steps, [.welcome, .apps, .signIn, .done])
        XCTAssertTrue(s.advance()); XCTAssertTrue(s.advance())
        XCTAssertEqual(s.step, .signIn)
        XCTAssertTrue(s.toggle("a"))
        XCTAssertEqual(s.steps, [.welcome, .apps, .done], "no service chosen, nothing to sign in to")
        XCTAssertTrue(s.advance() || s.step == .done)
        XCTAssertEqual(s.step, .done)
        XCTAssertTrue(s.back())
        XCTAssertEqual(s.step, .apps, "Back skips the same steps")
    }

    // MARK: Signing in

    func testSignInStatusWording() throws {
        var s = try setup()
        XCTAssertEqual(s.status(of: "a").label, "")
        s.recordSignIn("a", signedIn: nil)
        XCTAssertEqual(s.status(of: "a").label, "Opened")
        s.recordSignIn("a", signedIn: false)
        XCTAssertEqual(s.status(of: "a").label, "Not yet")
        s.recordSignIn("a", signedIn: true)
        XCTAssertEqual(s.status(of: "a").label, "Signed in")
        s.recordSignIn("plex", signedIn: true)
        XCTAssertEqual(s.status(of: "plex"), .notVisited, "only a chosen streaming service")
    }

    // MARK: The written config

    func testAFirstRunWritesStreamsThenPlexThenGamesThenSettings() throws {
        var s = try setup(Mac(plex: true, games: ["~/Games/ps": 2]), migrated: ["a": ["netflix51": .string("on")]])
        XCTAssertNil(s.existing)
        _ = s.toggle("b")
        let config = s.result()
        XCTAssertEqual(config.apps.map(\.id), ["a", "plex", "ps", "settings"])
        XCTAssertEqual(config.setting("gamesFolder", for: "ps"), .string("~/Games/ps"))
        XCTAssertEqual(config.setting("netflix51", for: "a"), .string("on"))
        XCTAssertEqual(config.version, 1)
    }

    func testNothingChosenStillWritesSettings() throws {
        var s = try setup()
        _ = s.toggle("a"); _ = s.toggle("b")
        XCTAssertEqual(s.result().apps.map(\.id), ["settings"])
    }

    func testASecondRunShowsTheCurrentChoicesAndKeepsSettingsOrderAndUnknowns() throws {
        let existing = AppConfig(apps: [
            AppEntry(id: "nes", settings: ["gamesFolder": .string("~/roms/nes")]),
            AppEntry(id: "b", settings: ["k": .number(1)]), AppEntry(id: "future"),
            AppEntry(id: "settings"), AppEntry(id: "a"),
        ], packageRef: "main")
        var s = try setup(Mac(plex: true, games: ["~/roms/nes": 4, "~/Games/ps": 9]), existing: existing)
        XCTAssertEqual(s.chosen, ["a", "b", "nes"], "plex and ps were not added, so they start off")
        XCTAssertEqual(s.consoles.first { $0.app.id == "nes" }?.folder, "~/roms/nes")
        XCTAssertEqual(s.consoles.first { $0.app.id == "nes" }?.status, "4 games")
        _ = s.toggle("plex"); _ = s.toggle("ps"); _ = s.toggle("a")
        let config = s.result()
        // Streams keep their old order (b), new ones follow; nes keeps its folder; Settings, then the unknown id.
        XCTAssertEqual(config.apps.map(\.id), ["b", "plex", "nes", "ps", "settings", "future"])
        XCTAssertEqual(config.setting("k", for: "b"), .number(1))
        XCTAssertEqual(config.setting("gamesFolder", for: "nes"), .string("~/roms/nes"))
        XCTAssertEqual(config.packageRef, "main")
    }

    func testAnAppTheSetupNeverOfferedStaysInTheConfig() throws {
        // RetroArch was removed after nes was added: its entry is not lost by running setup again.
        let existing = AppConfig(apps: [AppEntry(id: "a"), AppEntry(id: "nes"), AppEntry(id: "settings")])
        let s = try setup(Mac(retroArch: false), existing: existing)
        XCTAssertEqual(s.result().apps.map(\.id), ["a", "nes", "settings"])
    }

    func testTheResultRoundTripsThroughTheConfigFile() throws {
        let s = try setup(Mac(plex: true))
        XCTAssertEqual(try AppConfig.parse(try s.result().encoded()), s.result())
    }
}
