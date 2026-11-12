// Owns: tests for the app catalog (parsing, validation, the shipped
// apps/catalog.json, services and consoles made from it) and the app config
// (defaults, migration, ordering, unknown ids, requirements, files on disk).

import XCTest
@testable import CouchModeCore

/// The repository's real catalog, found from this file's path.
enum TestCatalog {
    static let catalog: AppCatalog = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // swiftlint:disable:next force_try
        return try! AppCatalog.parse(Data(contentsOf: root.appendingPathComponent("apps/catalog.json")))
    }()
    static let services = ServiceCatalog.make(from: catalog.apps, safariUserAgent: UserAgents.safari)
    static let consoles = ConsoleCatalog.make(from: catalog.apps)
}

private func catalogJSON(_ apps: String, version: Int = 1) -> Data {
    Data(#"{"version":\#(version),"apps":[\#(apps)]}"#.utf8)
}

private let siteApp = #"{"id":"a","name":"A","kind":"stream","site":{"url":"https://a.example/","userAgent":"safari"}}"#
private let plexLike = #"{"id":"n","name":"N","kind":"native","native":{"bundleId":"com.example.n"}}"#
private let gameApp = #"{"id":"g","name":"G","kind":"console","console":{"emulator":"retroarch","core":"x_libretro.dylib","extensions":["x"],"defaultFolder":"~/Games/g"},"requires":[{"label":"Emu installed","bundleId":"com.example.emu","appPaths":["~/Applications/Emu.app"]}]}"#
private let sysApp = #"{"id":"s","name":"S","kind":"system"}"#

final class AppCatalogTests: XCTestCase {
    func testParsesEveryKindAndDefaults() throws {
        let c = try AppCatalog.parse(catalogJSON([siteApp, plexLike, gameApp, sysApp].joined(separator: ",")))
        XCTAssertEqual(c.apps.map(\.id), ["a", "n", "g", "s"])
        XCTAssertEqual(c.apps.map(\.kind), [.stream, .native, .console, .system])
        XCTAssertTrue(c.apps[0].defaultEnabled)
        XCTAssertEqual(c.apps[0].requires, [])
        XCTAssertEqual(c.apps[2].requires.first?.label, "Emu installed")
        XCTAssertEqual(c.apps[2].console?.defaultFolder, "~/Games/g")
        XCTAssertEqual(c.app(id: "g")?.name, "G")
        XCTAssertNil(c.app(id: "zzz"))
    }

    func testRejectsBadCatalogs() {
        func fails(_ data: Data, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try AppCatalog.parse(data), why, line: line)
        }
        fails(Data("not json".utf8), "garbage")
        fails(catalogJSON(siteApp, version: 2), "version")
        fails(catalogJSON(siteApp + "," + siteApp), "duplicate id")
        fails(catalogJSON(#"{"id":"a","name":"A","kind":"stream"}"#), "stream without site")
        fails(catalogJSON(#"{"id":"a","name":"A","kind":"stream","site":{"url":"ftp://x/","userAgent":"safari"}}"#), "non-http url")
        fails(catalogJSON(#"{"id":"a","name":"A","kind":"toaster"}"#), "unknown kind")
        fails(catalogJSON(#"{"id":"n","name":"N","kind":"native","native":{}}"#), "native without target")
        fails(catalogJSON(#"{"id":"g","name":"G","kind":"console","console":{"emulator":"retroarch","extensions":["x"],"defaultFolder":"~/g"}}"#), "retroarch without core")
        fails(catalogJSON(#"{"id":"g","name":"G","kind":"console","console":{"emulator":"app","core":"c","extensions":["app"],"defaultFolder":"~/g"}}"#), "app with core")
        fails(catalogJSON(#"{"id":"","name":"A","kind":"system"}"#), "empty id")
        fails(Data(repeating: 0x20, count: AppCatalog.maxBytes + 1), "too large")
    }

    func testShippedCatalogIsValidAndComplete() {
        let ids = TestCatalog.catalog.apps.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Array(ids.prefix(9)), ["plex", "appletv", "netflix", "youtube", "disney", "hulu", "max", "prime", "settings"])
        XCTAssertEqual(TestCatalog.services.map(\.id), ["plex", "appletv", "netflix", "youtube", "disney", "hulu", "max", "prime"])
        XCTAssertEqual(TestCatalog.consoles.count, 18)
        XCTAssertEqual(TestCatalog.consoles.first?.id, "switch")
        XCTAssertEqual(TestCatalog.consoles.last?.id, "arcade")
    }

    func testServicesComeFromCatalog() {
        let s = TestCatalog.services
        XCTAssertEqual(s.first { $0.id == "plex" }?.nativeAppBundleID, "tv.plex.htpc")
        XCTAssertEqual(s.first { $0.id == "plex" }?.url.absoluteString, "https://app.plex.tv/desktop")
        XCTAssertEqual(s.first { $0.id == "youtube" }?.userAgent, UserAgents.smartTV)
        XCTAssertEqual(s.first { $0.id == "youtube" }?.hasTVInterface, true)
        XCTAssertEqual(s.first { $0.id == "netflix" }?.userAgent, UserAgents.safari)
        XCTAssertNotNil(s.first { $0.id == "prime" }?.navigationSkip)
        XCTAssertNil(s.first { $0.id == "hulu" }?.navigationSkip)
    }

    func testConsolesComeFromCatalog() {
        let c = TestCatalog.consoles
        XCTAssertEqual(c.first { $0.id == "switch" }?.gamesAreApps, true)
        XCTAssertEqual(c.first { $0.id == "switch" }?.defaultFolder, "~/Games/switch")
        XCTAssertEqual(c.first { $0.id == "snes" }?.coreFile, "snes9x_libretro.dylib")
        XCTAssertEqual(c.first { $0.id == "snes" }?.extensions, ["sfc", "smc"])
        XCTAssertEqual(c.first { $0.id == "snes" }?.gamesAreApps, false)
    }

    func testRetroConsolesRequireRetroArchAndSwitchDoesNot() {
        for app in TestCatalog.catalog.apps where app.kind == .console {
            XCTAssertEqual(app.requires.map(\.label), app.id == "switch" ? [] : ["RetroArch installed"], app.id)
        }
    }

    func testRequirementMetByBundleOrPathOrNothing() {
        let r = AppRequirement(label: "x", bundleId: "b", appPaths: ["~/Applications/X.app", "/Applications/X.app"])
        XCTAssertTrue(r.isMet(bundleInstalled: { $0 == "b" }, fileExists: { _ in false }, home: "/h"))
        XCTAssertTrue(r.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == "/h/Applications/X.app" }, home: "/h"))
        XCTAssertTrue(r.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == "/Applications/X.app" }, home: "/h"))
        XCTAssertFalse(r.isMet(bundleInstalled: { _ in false }, fileExists: { _ in false }, home: "/h"))
        XCTAssertTrue(AppRequirement(label: "none").isMet(bundleInstalled: { _ in false }, fileExists: { _ in false }, home: "/h"))
    }

    func testTildeExpansion() {
        XCTAssertEqual(PathText.expandingTilde("~/Games/nes", home: "/Users/x"), "/Users/x/Games/nes")
        XCTAssertEqual(PathText.expandingTilde("~", home: "/Users/x"), "/Users/x")
        XCTAssertEqual(PathText.expandingTilde("/mnt/games", home: "/Users/x"), "/mnt/games")
        XCTAssertEqual(PathText.expandingTilde("~other/x", home: "/Users/x"), "~other/x")
    }
}

final class AppConfigTests: XCTestCase {
    private let catalog = TestCatalog.catalog

    func testDefaultsFollowCatalogOrderAndAddEveryDefaultApp() {
        let c = AppConfig.defaults(catalog: catalog)
        XCTAssertEqual(c.version, AppConfig.currentVersion)
        XCTAssertEqual(c.apps.map(\.id), catalog.apps.map(\.id))
        XCTAssertEqual(c.setting("gamesFolder", for: "nes"), .string("~/Games/nes"))
        XCTAssertEqual(c.setting("gamesFolder", for: "switch"), .string("~/Games/switch"))
        XCTAssertNil(c.setting("gamesFolder", for: "netflix"))
    }

    func testDefaultsSkipAppsThatAreNotDefault() throws {
        let off = #"{"id":"b","name":"B","kind":"system","defaultEnabled":false}"#
        let cat = try AppCatalog.parse(catalogJSON([sysApp, off].joined(separator: ",")))
        XCTAssertEqual(AppConfig.defaults(catalog: cat).apps.map(\.id), ["s"])
    }

    func testMigratedValuesWinAndUnknownMigrationIsIgnored() {
        let c = AppConfig.defaults(catalog: catalog, migrated: [
            "netflix": ["netflix51": .string("on")],
            "nes": ["gamesFolder": .string("/Volumes/Roms/nes")],
            "ghost": ["x": .bool(true)],
        ])
        XCTAssertEqual(c.setting("netflix51", for: "netflix"), .string("on"))
        XCTAssertEqual(c.setting("gamesFolder", for: "nes"), .string("/Volumes/Roms/nes"))
        XCTAssertEqual(c.setting("gamesFolder", for: "snes"), .string("~/Games/snes"))
        XCTAssertFalse(c.apps.contains { $0.id == "ghost" })
    }

    func testRoundTripKeepsScalarsAndOrder() throws {
        var c = AppConfig(apps: [AppEntry(id: "b"), AppEntry(id: "a", settings: ["s": .string("x"), "t": .bool(true), "n": .number(3)])])
        XCTAssertTrue(c.set("extra", .string("y"), for: "b"))
        XCTAssertFalse(c.set("extra", .string("y"), for: "nope"))
        let back = try AppConfig.parse(c.encoded())
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.apps.map(\.id), ["b", "a"])
        XCTAssertEqual(back.setting("t", for: "a"), .bool(true))
        XCTAssertEqual(back.setting("n", for: "a"), .number(3))
    }

    func testParseRejectsBadFiles() {
        for bad in ["", "nope", "{}", #"{"version":0,"apps":[]}"#, #"{"version":1,"apps":[{"id":""}]}"#,
                    #"{"version":1,"apps":[{"id":"a","settings":{"k":[1]}}]}"#, #"{"version":1,"apps":"x"}"#] {
            XCTAssertThrowsError(try AppConfig.parse(Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try AppConfig.parse(Data(repeating: 0x20, count: AppConfig.maxBytes + 1)))
        XCTAssertNoThrow(try AppConfig.parse(Data(#"{"version":1,"apps":[{"id":"a"}]}"#.utf8)))
    }

    func testHomeFollowsConfigOrder() {
        let c = AppConfig(apps: ["prime", "netflix", "settings", "snes", "nes"].map { AppEntry(id: $0) })
        let home = c.resolve(catalog: catalog) { _ in true }
        XCTAssertEqual(home.apps.map(\.app.id), ["prime", "netflix", "settings", "snes", "nes"])
        XCTAssertEqual(home.unknownIDs, [])
        XCTAssertEqual(home.apps.first?.app.kind, .stream)
    }

    func testAppsNotInConfigAreNotShown() {
        let home = AppConfig(apps: [AppEntry(id: "hulu")]).resolve(catalog: catalog) { _ in true }
        XCTAssertEqual(home.apps.map(\.app.id), ["hulu"])
    }

    func testUnknownIdsAreSkippedButStayInTheConfig() throws {
        let c = AppConfig(apps: [AppEntry(id: "netflix"), AppEntry(id: "future-app", settings: ["k": .string("v")]), AppEntry(id: "hulu")])
        let home = c.resolve(catalog: catalog) { _ in true }
        XCTAssertEqual(home.apps.map(\.app.id), ["netflix", "hulu"])
        XCTAssertEqual(home.unknownIDs, ["future-app"])
        XCTAssertEqual(c.apps.count, 3)
        XCTAssertEqual(try AppConfig.parse(c.encoded()).setting("k", for: "future-app"), .string("v"))
    }

    func testDuplicateIdsShowOnceFirstWins() {
        let c = AppConfig(apps: [AppEntry(id: "netflix", settings: ["a": .string("1")]), AppEntry(id: "hulu"), AppEntry(id: "netflix")])
        let home = c.resolve(catalog: catalog) { _ in true }
        XCTAssertEqual(home.apps.map(\.app.id), ["netflix", "hulu"])
        XCTAssertEqual(home.apps.first?.settings["a"], .string("1"))
    }

    func testUnmetRequirementsHideTheAppAndSayWhy() {
        let c = AppConfig.defaults(catalog: catalog)
        let home = c.resolve(catalog: catalog) { $0.label != "RetroArch installed" }
        XCTAssertEqual(home.apps.map(\.app.id), ["plex", "appletv", "netflix", "youtube", "disney", "hulu", "max", "prime", "settings", "switch"])
        XCTAssertEqual(home.unmet.count, 17)
        XCTAssertEqual(home.unmet.first?.label, "RetroArch installed")
        XCTAssertEqual(c.apps.count, catalog.apps.count)
    }

    func testDefaultConfigShowsTodaysHome() {
        let home = AppConfig.defaults(catalog: catalog).resolve(catalog: catalog) { _ in true }
        XCTAssertEqual(home.apps.prefix(9).map(\.app.id), ["plex", "appletv", "netflix", "youtube", "disney", "hulu", "max", "prime", "settings"])
        XCTAssertEqual(home.apps.count, catalog.apps.count)
    }
}

final class ConfigFileTests: XCTestCase {
    private var dir: URL!
    private let catalog = TestCatalog.catalog
    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("couchmode-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func testFirstRunWritesDefaultsIncludingMigratedValues() throws {
        let file = ConfigFile(directory: dir.appendingPathComponent("not-yet"))
        let out = file.load(defaults: { AppConfig.defaults(catalog: self.catalog, migrated: ["netflix": ["netflix51": .string("off")]]) }, now: stamp)
        guard case .created(let c) = out else { return XCTFail("\(out)") }
        let onDisk = try AppConfig.parse(Data(contentsOf: file.url))
        XCTAssertEqual(onDisk, c)
        XCTAssertEqual(onDisk.setting("netflix51", for: "netflix"), .string("off"))
        XCTAssertEqual(onDisk.apps.map(\.id), catalog.apps.map(\.id))
    }

    func testExistingFileIsLoadedAsIsAndNotRewritten() throws {
        let mine = AppConfig(apps: [AppEntry(id: "hulu"), AppEntry(id: "unknown-future")])
        let file = ConfigFile(directory: dir)
        try file.save(mine)
        let before = try Data(contentsOf: file.url)
        let out = file.load(defaults: { XCTFail("defaults must not be built"); return AppConfig(apps: []) }, now: stamp)
        XCTAssertEqual(out, .loaded(mine))
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }

    func testCorruptFileIsRenamedAndFreshDefaultWritten() throws {
        let file = ConfigFile(directory: dir)
        try Data("{ this is not json".utf8).write(to: file.url)
        let out = file.load(defaults: { AppConfig.defaults(catalog: self.catalog) }, now: stamp)
        guard case .replacedCorrupt(let c, let backup, _) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(backup.lastPathComponent, "config.json.bad-20270115T080000Z")
        XCTAssertEqual(try String(contentsOf: backup), "{ this is not json")
        XCTAssertEqual(try AppConfig.parse(Data(contentsOf: file.url)), c)
        XCTAssertEqual(names(), ["config.json", "config.json.bad-20270115T080000Z"])
    }

    func testTwoCorruptionsAtTheSameSecondKeepBothBackups() throws {
        let file = ConfigFile(directory: dir)
        for _ in 0..<2 {
            try Data("bad".utf8).write(to: file.url)
            _ = file.load(defaults: { AppConfig.defaults(catalog: self.catalog) }, now: stamp)
        }
        XCTAssertEqual(names().filter { $0.contains(".bad-") }.count, 2)
    }

    func testOversizedFileCountsAsCorrupt() throws {
        let file = ConfigFile(directory: dir)
        try Data(repeating: 0x20, count: AppConfig.maxBytes + 10).write(to: file.url)
        guard case .replacedCorrupt = file.load(defaults: { AppConfig.defaults(catalog: self.catalog) }, now: stamp) else { return XCTFail() }
    }

    func testSaveIsAtomicLeavesNoTempFilesAndReplaces() throws {
        let file = ConfigFile(directory: dir)
        try file.save(AppConfig(apps: [AppEntry(id: "a")]))
        try file.save(AppConfig(apps: [AppEntry(id: "b")]))
        XCTAssertEqual(names(), ["config.json"])
        XCTAssertEqual(try AppConfig.parse(Data(contentsOf: file.url)).apps.map(\.id), ["b"])
    }

    func testFailedSaveKeepsTheOldFile() throws {
        let file = ConfigFile(directory: dir)
        try file.save(AppConfig(apps: [AppEntry(id: "keep")]))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try file.save(AppConfig(apps: [AppEntry(id: "lost")])))
        XCTAssertEqual(try AppConfig.parse(Data(contentsOf: file.url)).apps.map(\.id), ["keep"])
    }

    func testUnwritableFolderGivesInMemoryDefaults() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let out = ConfigFile(directory: dir).load(defaults: { AppConfig.defaults(catalog: self.catalog) }, now: stamp)
        guard case .unusable(let c, _) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(c.apps.count, catalog.apps.count)
    }

    func testConfigHasNoSecretsOrPersonalPaths() throws {
        let text = String(decoding: try AppConfig.defaults(catalog: catalog).encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertTrue(text.contains("~/Games/nes"))
    }
}
