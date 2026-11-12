import XCTest
@testable import CouchModeCore

final class FocusGridTests: XCTestCase {
    func testRejectsEmptyGridAndEmptyRows() {
        XCTAssertNil(FocusGrid(rowLengths: []))
        XCTAssertNil(FocusGrid(rowLengths: [3, 0]))
    }

    func testStopsAtEdgesInsteadOfWrapping() {
        let g = FocusGrid(rowLengths: [3, 2])!
        XCTAssertEqual(g.moved(.up).row, 0)
        XCTAssertEqual(g.moved(.left).column, 0)
        let end = g.moved(.right).moved(.right).moved(.right).moved(.right)
        XCTAssertEqual(end.column, 2)
        XCTAssertEqual(end.moved(.down).moved(.down).row, 1)
    }

    func testMovingToShorterRowClampsColumn() {
        let g = FocusGrid(rowLengths: [5, 1])!.moved(.right).moved(.right).moved(.right)
        XCTAssertEqual(g.column, 3)
        let down = g.moved(.down)
        XCTAssertEqual(down.row, 1)
        XCTAssertEqual(down.column, 0)
    }
}

final class PlayerInputTests: XCTestCase {
    private let netflix = ServiceCatalog.all.first { $0.id == "netflix" }!
    private let youtube = ServiceCatalog.all.first { $0.id == "youtube" }!

    func testHomeAlwaysReturnsToShell() {
        XCTAssertEqual(PlayerInput.command(for: .home, service: netflix), .returnHome)
        XCTAssertEqual(PlayerInput.command(for: .home, service: youtube), .returnHome)
    }

    func testBackUsesTVInterfaceEscapeOnlyWhereTheSiteHasOne() {
        XCTAssertEqual(PlayerInput.command(for: .back, service: youtube), .press(.escape))
        XCTAssertEqual(PlayerInput.command(for: .back, service: netflix), .goBackInPage)
    }

    func testMovesAndSelectBecomeRealKeys() {
        XCTAssertEqual(PlayerInput.command(for: .move(.left), service: netflix), .press(.left))
        XCTAssertEqual(PlayerInput.command(for: .select, service: netflix), .press(.enter))
    }

    func testCatalogIdsAreUnique() {
        let ids = ServiceCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

final class HTTPRequestTests: XCTestCase {
    func testWaitsForCompleteHeadersAndBody() {
        XCTAssertNil(HTTPRequest(Data("GET /state HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertNil(HTTPRequest(Data("POST /eval HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)))
    }

    func testParsesPathQueryAndBody() {
        let get = HTTPRequest(Data("GET /intent?i=left HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(get?.method, "GET")
        XCTAssertEqual(get?.path, "/intent")
        XCTAssertEqual(get?.query["i"], "left")
        let post = HTTPRequest(Data("POST /eval HTTP/1.1\r\nContent-Length: 9\r\n\r\nreturn 1;".utf8))
        XCTAssertEqual(post.map { String(decoding: $0.body, as: UTF8.self) }, "return 1;")
    }
}

final class CycleTests: XCTestCase {
    func testCyclesAndWraps() {
        XCTAssertEqual(Cycle.next(after: "a", in: ["a", "b", "c"]), "b")
        XCTAssertEqual(Cycle.next(after: "c", in: ["a", "b", "c"]), "a")
    }

    func testUnknownOrMissingCurrentPicksFirst_EmptyGivesNil() {
        XCTAssertEqual(Cycle.next(after: "z", in: ["a", "b"]), "a")
        XCTAssertEqual(Cycle.next(after: nil, in: ["a", "b"]), "a")
        XCTAssertNil(Cycle.next(after: "a", in: [String]()))
    }
}

final class ConfirmGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testSecondPressWithinWindowConfirms() {
        var g = ConfirmGate()
        XCTAssertFalse(g.press("exit", now: t0))
        XCTAssertEqual(g.pending(now: t0.addingTimeInterval(1)), "exit")
        XCTAssertTrue(g.press("exit", now: t0.addingTimeInterval(2)))
        XCTAssertNil(g.pending(now: t0.addingTimeInterval(2)))
    }

    func testLatePressOrDifferentActionRearmsInsteadOfConfirming() {
        var g = ConfirmGate()
        _ = g.press("exit", now: t0)
        XCTAssertFalse(g.press("exit", now: t0.addingTimeInterval(ConfirmGate.window + 1)))
        XCTAssertFalse(g.press("restart", now: t0.addingTimeInterval(ConfirmGate.window + 2)))
        XCTAssertEqual(g.pending(now: t0.addingTimeInterval(ConfirmGate.window + 2)), "restart")
    }
}

final class GameLibraryTests: XCTestCase {
    private let nes = ConsoleCatalog.all.first { $0.id == "nes" }!

    func testKeepsMatchingExtensionsCaseInsensitiveSkipsHiddenAndSorts() {
        let games = GameLibrary.games(fileNames: ["zelda.NES", ".hidden.nes", "readme.txt", "Alter Ego.nes"], for: nes)
        XCTAssertEqual(games.map(\.title), ["Alter Ego", "zelda"])
        XCTAssertEqual(games.first?.fileName, "Alter Ego.nes")
    }

    func testCountLabel() {
        XCTAssertEqual(GameLibrary.countLabel(0), "No games yet")
        XCTAssertEqual(GameLibrary.countLabel(1), "1 game")
        XCTAssertEqual(GameLibrary.countLabel(3), "3 games")
    }

    func testConsoleIdsAndFoldersAreUnique() {
        XCTAssertEqual(Set(ConsoleCatalog.all.map(\.id)).count, ConsoleCatalog.all.count)
        XCTAssertEqual(Set(ConsoleCatalog.all.map(\.folder)).count, ConsoleCatalog.all.count)
    }
}

final class FocusGridResizeTests: XCTestCase {
    func testResizeKeepsPositionWhenStillValidAndClampsWhenNot() {
        let g = FocusGrid(rowLengths: [5, 3])!.moved(.down).moved(.right).moved(.right)
        XCTAssertEqual(g.resized(rowLengths: [5, 4]).map { [$0.row, $0.column] }, [1, 2])
        XCTAssertEqual(g.resized(rowLengths: [5, 1]).map { [$0.row, $0.column] }, [1, 0])
        XCTAssertEqual(g.resized(rowLengths: [2]).map { [$0.row, $0.column] }, [0, 1])
        XCTAssertNil(g.resized(rowLengths: [2, 0]))
    }
}

final class PlexParsingTests: XCTestCase {
    func testPicksOwnedServerAndDirectHTTPSConnection() {
        let json = """
        [{"name":"Player","provides":"player","clientIdentifier":"p1"},
         {"name":"Friend","provides":"server","owned":false,"clientIdentifier":"f1","accessToken":"tf",
          "connections":[{"protocol":"https","uri":"https://friend:32400","relay":false}]},
         {"name":"OwnedServer","provides":"server","owned":true,"clientIdentifier":"s1","accessToken":"ts",
          "connections":[{"protocol":"https","uri":"https://relay:8443","relay":true},
                         {"protocol":"https","uri":"https://owned:32400","relay":false}]}]
        """
        let s = PlexParsing.server(fromResources: Data(json.utf8))
        XCTAssertEqual(s?.machineIdentifier, "s1")
        XCTAssertEqual(s?.baseURL.absoluteString, "https://owned:32400")
        XCTAssertEqual(s?.accessToken, "ts")
        XCTAssertNil(PlexParsing.server(fromResources: Data("{}".utf8)))
    }

    func testParsesEpisodesMoviesAndHubsWithProgress() {
        let json = """
        {"MediaContainer":{"Hub":[{"Metadata":[
          {"ratingKey":"10","type":"episode","title":"Pilot","grandparentTitle":"Show","parentIndex":1,"index":2,
           "thumb":"/t/10","duration":1000,"viewOffset":250},
          {"ratingKey":"20","type":"movie","title":"Film","year":1999,"art":"/a/20","duration":0},
          {"type":"movie","title":"No key"}]}]}}
        """
        let items = PlexParsing.continueItems(from: Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Show")
        XCTAssertEqual(items[0].detail, "S1 · E2 · Pilot")
        XCTAssertEqual(items[0].progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(items[1].detail, "1999")
        XCTAssertEqual(items[1].imagePath, "/a/20")
        XCTAssertEqual(items[1].progress, 0)
    }

    func testOnDeckShapeAndLimit() {
        let many = (1...30).map { #"{"ratingKey":"\#($0)","type":"movie","title":"M\#($0)"}"# }.joined(separator: ",")
        let items = PlexParsing.continueItems(from: Data(#"{"MediaContainer":{"Metadata":[\#(many)]}}"#.utf8), limit: 5)
        XCTAssertEqual(items.map(\.ratingKey), ["1", "2", "3", "4", "5"])
    }

    func testURLs() {
        let s = PlexServer(name: "S", machineIdentifier: "abc", baseURL: URL(string: "https://owned:32400")!, accessToken: "tok")
        let img = PlexParsing.imageURL(server: s, path: "/library/metadata/1/thumb/2", width: 640, height: 360)!.absoluteString
        XCTAssertTrue(img.hasPrefix("https://owned:32400/photo/:/transcode?width=640&height=360"))
        XCTAssertTrue(img.contains("X-Plex-Token=tok"))
        XCTAssertEqual(PlexParsing.webDetailsURL(server: s, ratingKey: "42")?.absoluteString,
                       "https://app.plex.tv/desktop/#!/server/abc/details?key=%2Flibrary%2Fmetadata%2F42")
    }
}

final class GameSizeTests: XCTestCase {
    func testSizesAttachToMatchingFiles() {
        let nes = ConsoleCatalog.all.first { $0.id == "nes" }!
        let games = GameLibrary.games(fileNames: ["a.nes", "b.nes"], for: nes, sizes: ["a.nes": 262_160])
        XCTAssertEqual(games.first { $0.fileName == "a.nes" }?.sizeBytes, 262_160)
        XCTAssertNil(games.first { $0.fileName == "b.nes" }?.sizeBytes)
    }
}

final class PlexConnectionRankTests: XCTestCase {
    func testRanksPublicDirectBeforeLocalBeforeRelay() {
        let json = #"[{"name":"OwnedServer","provides":"server","owned":false,"clientIdentifier":"s1","accessToken":"t","connections":[{"protocol":"https","uri":"https://relay","relay":true,"local":false},{"protocol":"https","uri":"https://private","relay":false,"local":true},{"protocol":"https","uri":"https://public","relay":false,"local":false}]}]"#
        let s = PlexParsing.server(fromResources: Data(json.utf8))
        XCTAssertEqual(s?.candidateURLs.map(\.absoluteString), ["https://public", "https://private", "https://relay"])
        XCTAssertEqual(s?.baseURL.absoluteString, "https://public")
    }
}

final class PlexServersTests: XCTestCase {
    func testListsEveryServerOwnedFirst() {
        let json = #"[{"name":"Shared","provides":"server","owned":false,"clientIdentifier":"a","accessToken":"t1","connections":[{"protocol":"https","uri":"https://a"}]},{"name":"Mine","provides":"server","owned":true,"clientIdentifier":"b","accessToken":"t2","connections":[{"protocol":"https","uri":"https://b"}]},{"name":"Phone","provides":"client","clientIdentifier":"c"}]"#
        XCTAssertEqual(PlexParsing.servers(fromResources: Data(json.utf8)).map(\.name), ["Mine", "Shared"])
    }
}

final class SwitchConsoleTests: XCTestCase {
    func testSwitchGamesAreAppBundles() {
        let sw = ConsoleCatalog.all.first { $0.id == "switch" }!
        XCTAssertTrue(sw.gamesAreApps)
        XCTAssertFalse(ConsoleCatalog.all.first { $0.id == "nes" }!.gamesAreApps)
        let games = GameLibrary.games(fileNames: ["Kirby.app", "notes.txt", "Mario Kart 8 Deluxe.app"], for: sw)
        XCTAssertEqual(games.map(\.title), ["Kirby", "Mario Kart 8 Deluxe"])
    }
}

final class PlexMergeTests: XCTestCase {
    func testMergesAcrossServersMostRecentFirstAndCaps() {
        func item(_ k: String, _ t: Double) -> ContinueItem {
            ContinueItem(ratingKey: k, title: k, detail: "", imagePath: nil, progress: 0, lastViewedAt: t)
        }
        let a = [(item("a1", 10), "A"), (item("a2", 30), "A")]
        let b = [(item("b1", 20), "B")]
        let m = PlexParsing.merged([a, b], limit: 2)
        XCTAssertEqual(m.map(\.0.ratingKey), ["a2", "b1"])
        XCTAssertEqual(m.map(\.1), ["A", "B"])
    }
}

final class RowSlideTests: XCTestCase {
    func testFirstTwoCardsDontSlideThenFocusedStaysInSecondSlot() {
        XCTAssertEqual(RowSlide.offset(focusedColumn: 0, step: 100), 0)
        XCTAssertEqual(RowSlide.offset(focusedColumn: 1, step: 100), 0)
        XCTAssertEqual(RowSlide.offset(focusedColumn: 5, step: 100), 400)
    }
}

final class SwitchCatalogTests: XCTestCase {
    private let json = #"{"generated":"x","games":[{"titleID":"0100AA","name":"Racer","publisher":"Pub","releaseDate":"2017-04-28","numberOfPlayers":4,"genres":["Racing","Party"],"description":"Fast.","card":"images/a-card.jpg","banner":"images/a-banner.jpg","bundleID":"b","scheme":"s","screenshots":[]},{"titleID":"0100BB","name":"Solo","releaseDate":"bad","numberOfPlayers":1,"genres":["Party"],"intro":"Hi.","card":"c","banner":"d"}]}"#

    func testDecodesAndBuildsTheTextUnderTheTitle() {
        let c = SwitchCatalog.decode(Data(json.utf8))!
        let racer = c.game("0100aa")!
        XCTAssertEqual(racer.metaText, "Pub  \u{2022}  2017  \u{2022}  1-4 players")
        XCTAssertEqual(racer.blurb, "Fast.")
        let solo = c.game("0100BB")!
        XCTAssertEqual(solo.metaText, "1 player")
        XCTAssertEqual(solo.blurb, "Hi.")
        XCTAssertNil(c.game("nope"))
    }

    func testGenreRowsNeedTwoItemsAndSortByCount() {
        let rows = GenreRows.build(["a", "b", "c"]) { ["a": ["X", "Y"], "b": ["X"], "c": ["Y", "Z"]][$0]! }
        XCTAssertEqual(rows.map(\.genre), ["X", "Y"])
        XCTAssertEqual(rows.first?.items, ["a", "b"])
    }
}

final class CatalogBlurbTests: XCTestCase {
    private func game(_ desc: String) -> CatalogGame {
        let json = #"{"games":[{"titleID":"1","name":"G","genres":[],"description":"DESC","card":"c","banner":"b"}]}"#
            .replacingOccurrences(of: "DESC", with: desc)
        return SwitchCatalog.decode(Data(json.utf8))!.games[0]
    }

    func testDropsLeadingStoreFootnotes() {
        XCTAssertEqual(game("*Upgrade notice.\\n*Another.\\n\\nThe real story.").blurb, "The real story.")
        XCTAssertEqual(game("*Upgradable after purchase.\\nTo upgrade, buy the pack.\\n\\nStory time.").blurb, "Story time.")
        XCTAssertEqual(game("Plain text.").blurb, "Plain text.")
        XCTAssertNil(game("*Only a footnote.").blurb)
        XCTAssertEqual(game("- Story\\nA kingdom in trouble.").blurb, "A kingdom in trouble.")
        XCTAssertEqual(game("- This sentence is long enough to be prose itself.").blurb, "- This sentence is long enough to be prose itself.")
    }
}

final class PlexBackdropTests: XCTestCase {
    func testEpisodesUseTheShowArtMoviesTheirOwn() {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"1","type":"episode","title":"E","grandparentTitle":"S","thumb":"/t","grandparentArt":"/ga"},{"ratingKey":"2","type":"movie","title":"M","art":"/a","thumb":"/mt"}]}}"#
        let items = PlexParsing.continueItems(from: Data(json.utf8))
        XCTAssertEqual(items.map(\.backdropPath), ["/ga", "/a"])
    }
}

final class InfoIntentTests: XCTestCase {
    func testInfoIsPlayPauseOnSites() {
        let netflix = ServiceCatalog.all.first { $0.id == "netflix" }!
        XCTAssertEqual(PlayerInput.command(for: .info, service: netflix), .press(.space))
    }

    func testCatalogScreenshotsAndReleaseText() {
        let json = #"{"games":[{"titleID":"1","name":"G","genres":[],"card":"c","banner":"b","releaseDate":"2023-10-20","screenshots":["https://a/1.jpg","http://insecure/2.jpg"]},{"titleID":"2","name":"H","genres":[],"card":"c","banner":"b"}]}"#
        let c = SwitchCatalog.decode(Data(json.utf8))!
        XCTAssertEqual(c.games[0].screenshots, ["https://a/1.jpg"])
        XCTAssertNotNil(c.games[0].releaseText)
        XCTAssertEqual(c.games[1].screenshots, [])
    }
}

final class PlexDetailFieldsTests: XCTestCase {
    func testSummaryRatingAndTimeLeft() {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"9","type":"movie","title":"M","summary":"A plot.","year":2026,"contentRating":"PG-13","duration":6000000,"viewOffset":3720000}]}}"#
        let item = PlexParsing.continueItems(from: Data(json.utf8))[0]
        XCTAssertEqual(item.summary, "A plot.")
        XCTAssertEqual(item.year, 2026)
        XCTAssertEqual(item.contentRating, "PG-13")
        XCTAssertEqual(item.remainingText, "38 min left")
    }
}

final class RemotePassthroughTests: XCTestCase {
    func testRemotePressesBecomeKeysTheAppKnowsAndHomeNeverPasses() {
        XCTAssertEqual(RemotePassthrough.key(for: .move(.left)), .left)
        XCTAssertEqual(RemotePassthrough.key(for: .select), .enter)
        XCTAssertEqual(RemotePassthrough.key(for: .back), .escape)
        XCTAssertEqual(RemotePassthrough.key(for: .info), .space)
        XCTAssertNil(RemotePassthrough.key(for: .home))
    }
}

final class HomeRoutingTests: XCTestCase {
    func testShellInFrontIsAlwaysItsOwnHome() {
        for source in HomeSource.allCases {
            XCTAssertEqual(HomeRouting.step(front: .shell, source: source), .shellHome)
        }
    }

    func testStreamingAppClosesAndOtherAppsHideFromAnyButton() {
        for source in HomeSource.allCases {
            XCTAssertEqual(HomeRouting.step(front: .streamingApp, source: source), .closeApp)
            XCTAssertEqual(HomeRouting.step(front: .other, source: source), .hideApp)
        }
    }

    func testRemoteOrKeyboardPausesASwitchGameButTheGameKeepsItsOwnButtons() {
        XCTAssertEqual(HomeRouting.step(front: .switchGame, source: .remoteOrKeyboard), .pauseGame)
        XCTAssertEqual(HomeRouting.step(front: .switchGame, source: .controllerHome), .leaveToGame)
        XCTAssertEqual(HomeRouting.step(front: .switchGame, source: .controllerMenuHold), .leaveToGame)
    }

    func testRetroGamesSaveAndQuitExceptOnAHeldStartButton() {
        XCTAssertEqual(HomeRouting.step(front: .retroArch, source: .remoteOrKeyboard), .saveAndQuitRetroArch)
        XCTAssertEqual(HomeRouting.step(front: .retroArch, source: .controllerHome), .saveAndQuitRetroArch)
        XCTAssertEqual(HomeRouting.step(front: .retroArch, source: .controllerMenuHold), .leaveToGame)
    }

    func testSourceNamesRoundTripForTheDebugChannel() {
        for source in HomeSource.allCases { XCTAssertEqual(HomeSource(rawValue: source.rawValue), source) }
    }
}

final class FocusGridJumpTests: XCTestCase {
    func testJumpsToARealItemAndRefusesOneThatIsNotThere() {
        let grid = FocusGrid(rowLengths: [3, 1])!
        let jumped = grid.at(row: 0, column: 2)
        XCTAssertEqual(jumped?.row, 0)
        XCTAssertEqual(jumped?.column, 2)
        XCTAssertNil(grid.at(row: 1, column: 1))
        XCTAssertNil(grid.at(row: 2, column: 0))
        XCTAssertNil(grid.at(row: -1, column: 0))
    }
}

final class DetailFocusTests: XCTestCase {
    func testCloseGameIsReachableOnlyForAPausedGame() {
        XCTAssertEqual(DetailFocus.play.moved(.right, paused: true, screenshots: 3), .close)
        XCTAssertEqual(DetailFocus.play.moved(.right, paused: false, screenshots: 3), .play)
        XCTAssertEqual(DetailFocus.close.moved(.left, paused: true, screenshots: 3), .play)
    }

    func testScreenshotsRowIsBelowTheButtonsAndStopsAtItsEdges() {
        XCTAssertEqual(DetailFocus.close.moved(.down, paused: true, screenshots: 2), .screenshot(0))
        XCTAssertEqual(DetailFocus.play.moved(.down, paused: false, screenshots: 0), .play)
        XCTAssertEqual(DetailFocus.screenshot(0).moved(.left, paused: false, screenshots: 2), .screenshot(0))
        XCTAssertEqual(DetailFocus.screenshot(1).moved(.right, paused: false, screenshots: 2), .screenshot(1))
        XCTAssertEqual(DetailFocus.screenshot(1).moved(.up, paused: true, screenshots: 2), .play)
    }
}

final class BluetoothPaneTests: XCTestCase {
    // The Bluetooth settings pane as Accessibility lists it (macOS 27).
    private let pane: [PaneItem] = [
        .init(.heading, "Bluetooth"), .init(.text, "This Mac is discoverable as \u{201C}Example\u{2019}s Mac mini\u{201D}"),
        .init(.heading, "My Devices"),
        .init(.text, "Owner\u{2019}s Magic Keyboard 2"), .init(.text, "Connected - 100%"), .init(.button, "Show Detail"),
        .init(.text, "Owner\u{2019}s AirPods"), .init(.text, "Not Connected"), .init(.button, "Show Detail"),
        .init(.button, "Help"),
        .init(.heading, "Nearby Devices"),
        .init(.text, "Xbox Wireless Controller"), .init(.text, "Living room TV"),
        .init(.heading, "AXToolbar"), .init(.text, "Bluetooth"),   // the window title, after the lists
    ]

    func testKnownDevicesCarryTheirConnectionAndBattery() {
        let known = BluetoothPane.devices(pane).filter(\.isKnown)
        XCTAssertEqual(known, [
            BluetoothDevice(name: "Owner\u{2019}s Magic Keyboard 2", isKnown: true, isConnected: true, battery: "100%"),
            BluetoothDevice(name: "Owner\u{2019}s AirPods", isKnown: true, isConnected: false),
        ])
    }

    func testEachNearbyTextIsADeviceAndTextsOutsideTheListsAreNot() {
        let nearby = BluetoothPane.devices(pane).filter { !$0.isKnown }.map(\.name)
        XCTAssertEqual(nearby, ["Xbox Wireless Controller", "Living room TV"])
        XCTAssertFalse(BluetoothPane.devices(pane).contains { $0.name.hasPrefix("This Mac") })
    }

    func testKindIsGuessedFromTheName() {
        XCTAssertEqual(BluetoothDevice.kind(of: "DualSense Wireless Controller"), .controller)
        XCTAssertEqual(BluetoothDevice.kind(of: "Siri Remote"), .remote)
        XCTAssertEqual(BluetoothDevice.kind(of: "Owner\u{2019}s AirPods Pro"), .headphones)
        XCTAssertEqual(BluetoothDevice.kind(of: "Magic Trackpad"), .pointer)
        XCTAssertEqual(BluetoothDevice.kind(of: "Living room TV"), .other)
    }
}

final class HIDPadLayoutTests: XCTestCase {
    private let hori = HIDPadLayout.layout(vendor: 0x0F0D, product: 0x00F6)

    func testHoriPadIsKnownAndOthersAreNot() {
        XCTAssertNotNil(hori)
        XCTAssertNil(HIDPadLayout.layout(vendor: 0x045E, product: 0x0B13))   // an Xbox pad: GameController's
    }

    func testGamesGetTheMapInNX2AppleNamesWithoutHomeOrCapture() {
        XCTAssertEqual(hori?.dmHIDMap, "A=2,B=1,X=4,Y=3,LS=11,RS=12,L=5,R=6,ZL=7,ZR=8,PLUS=10,MINUS=9")
    }

    func testShellActionsFollowNintendoConvention() {
        XCTAssertEqual(hori?.button(forUsage: 2), .a)
        XCTAssertEqual(hori?.button(forUsage: 1), .b)
        XCTAssertEqual(HIDPadLayout.action(for: .a), .select)
        XCTAssertEqual(HIDPadLayout.action(for: .b), .back)
        XCTAssertEqual(HIDPadLayout.action(for: .home), .home)
        XCTAssertNil(HIDPadLayout.action(for: .zl))
        XCTAssertNil(hori?.button(forUsage: 20))
    }

    func testHatGoesClockwiseFromUpAndCentresOutsideItsRange() {
        XCTAssertEqual(HIDPadLayout.hatVector(0).y, 1)
        XCTAssertEqual(HIDPadLayout.hatVector(2).x, 1)
        XCTAssertEqual(HIDPadLayout.hatVector(6).x, -1)
        XCTAssertEqual(HIDPadLayout.hatVector(8).x, 0)
        XCTAssertEqual(HIDPadLayout.hatVector(15).y, 0)
    }
}

final class ControllerRoutingTests: XCTestCase {
    func testGamesKeepTheControllerAndOtherAppsGetKeys() {
        XCTAssertEqual(ControllerRouting.target(shellActive: false, front: .switchGame), .game)
        XCTAssertEqual(ControllerRouting.target(shellActive: false, front: .retroArch), .game)
        XCTAssertEqual(ControllerRouting.target(shellActive: false, front: .streamingApp), .appAsKeys)
        XCTAssertEqual(ControllerRouting.target(shellActive: false, front: .other), .appAsKeys)
    }

    func testTheShellInFrontAlwaysGetsTheController() {
        XCTAssertEqual(ControllerRouting.target(shellActive: true, front: .streamingApp), .shell)
        XCTAssertEqual(ControllerRouting.target(shellActive: false, front: .shell), .shell)
    }
}

final class BluetoothListingTests: XCTestCase {
    private let devices = [
        BluetoothDevice(name: "Siri Remote", isKnown: false, isConnected: false),
        BluetoothDevice(name: "AirPods", isKnown: true, isConnected: false),
        BluetoothDevice(name: "Pro Controller", isKnown: true, isConnected: true, battery: "80%"),
    ]

    func testConnectedFirstThenRememberedThenNearby() {
        let rows = BluetoothPane.listing(devices)
        XCTAssertEqual(rows.map(\.title), ["Pro Controller", "AirPods", "Siri Remote"])
        XCTAssertEqual(rows.map(\.value), ["Connected \u{00B7} 80%", "Connect", "Pair"])
        XCTAssertEqual(rows.map(\.action), [.none, .connect, .pair])
    }

    func testTheListIsBounded() {
        let many = (0..<30).map { BluetoothDevice(name: "Device \($0)", isKnown: false, isConnected: false) }
        XCTAssertEqual(BluetoothPane.listing(many).count, 10)
    }
}

final class PlexHTPCLogTests: XCTestCase {
    func testScreensAreReadInOrderAndOtherLinesIgnored() {
        let text = """
        Nov 11, 2026 15:00:55.320 [0x2] INFO - [Web] ... INFO Navigating to screen: HomeTabbedScreen
        Nov 11, 2026 15:00:55.400 [0x2] INFO - [Web] ... INFO Navigated to screen: HomeTabbedScreen
        Nov 11, 2026 15:01:02.100 [0x2] DEBUG - Executed command
        Nov 11, 2026 15:01:03.000 [0x2] INFO - [Web] ... INFO Navigated to screen: ShowTabbedScreen
        """
        XCTAssertEqual(PlexHTPCLog.screens(in: text), ["HomeTabbedScreen", "ShowTabbedScreen"])
        XCTAssertEqual(PlexHTPCLog.screens(in: ""), [])
    }
}

final class PlexAppLinkTests: XCTestCase {
    func testOnlyEpisodesLinkToPlexHTPC() {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "title": "Pilot", "type": "episode", "grandparentTitle": "Show", "guid": "plex://episode/5e1"},
          {"ratingKey": "2", "title": "Home Movie", "type": "movie", "guid": "local://2"},
          {"ratingKey": "3", "title": "Old Film", "type": "movie"},
          {"ratingKey": "4", "title": "Sample Film", "type": "movie", "guid": "plex://movie/5d7"}
        ]}}
        """
        let items = PlexParsing.continueItems(from: Data(json.utf8), limit: 10)
        XCTAssertEqual(items[0].appLink?.absoluteString, "plex://episode/5e1")
        XCTAssertNil(items[1].appLink)
        XCTAssertNil(items[2].appLink)
        XCTAssertNil(items[3].appLink, "a movie's Plex ID opens the catalog page, not the library copy")
    }
}

final class GameScreenshotsTests: XCTestCase {
    func testUsableKeepsSecureAddressesInOrderWithoutRepeats() {
        let urls = GameScreenshots.usable(["https://example.test/a.jpg", "http://example.test/b.jpg", "",
                                           "not a url", "https://example.test/a.jpg", " https://example.test/c.jpg "])
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.test/a.jpg", "https://example.test/c.jpg"])
    }

    func testUsableIsBounded() {
        let raw = (0..<20).map { "https://example.test/\($0).jpg" }
        XCTAssertEqual(GameScreenshots.usable(raw).count, GameScreenshots.limit)
        XCTAssertEqual(GameScreenshots.usable(raw, limit: 3).count, 3)
    }

    func testUsableOfNothingIsEmpty() {
        XCTAssertTrue(GameScreenshots.usable([]).isEmpty)
        XCTAssertTrue(GameScreenshots.usable(["https://", "ftp://example.test/a.jpg"]).isEmpty)
    }

    func testShownIsOnlyWhatLoadedKeepingCatalogOrder() {
        let urls = GameScreenshots.usable(["https://example.test/a.jpg", "https://example.test/b.jpg", "https://example.test/c.jpg"])
        let loaded: Set<URL> = [urls[2], urls[0]]
        XCTAssertEqual(GameScreenshots.shown(urls, loaded: loaded), [urls[0], urls[2]])
    }

    func testNothingLoadedMeansNoPane() {
        let urls = GameScreenshots.usable(["https://example.test/a.jpg"])
        XCTAssertTrue(GameScreenshots.shown(urls, loaded: []).isEmpty)
    }
}
