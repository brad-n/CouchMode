// Owns: tests for editing a Mac's app list (add, remove, move), what can be
// added and its requirement status, the package ref in the config, and the
// default reader once a package is present.

import XCTest
@testable import CouchModeCore

private func catalog() throws -> AppCatalog {
    try AppCatalog.parse(Data("""
    {"version":1,"apps":[
     {"id":"a","name":"A","kind":"stream","site":{"url":"https://a.example/","userAgent":"safari"}},
     {"id":"b","name":"B","kind":"stream","site":{"url":"https://b.example/","userAgent":"safari"}},
     {"id":"c","name":"C","kind":"stream","site":{"url":"https://c.example/","userAgent":"safari"},"reader":"builtin"},
     {"id":"settings","name":"Settings","kind":"system"},
     {"id":"nes","name":"NES","kind":"console","console":{"emulator":"retroarch","core":"x.dylib","extensions":["nes"],"defaultFolder":"~/Games/nes"},
      "requires":[{"label":"RetroArch installed","bundleId":"com.example.retro"}]},
     {"id":"ps","name":"PS","kind":"console","console":{"emulator":"app","extensions":["app"],"defaultFolder":"~/Games/ps"}}
    ]}
    """.utf8))
}

private func config(_ ids: [String]) -> AppConfig { AppConfig(apps: ids.map { AppEntry(id: $0) }) }

final class AppListEditTests: XCTestCase {
    func testAddAppendsWithDefaultsOnce() throws {
        let cat = try catalog()
        var c = config(["a", "settings"])
        XCTAssertTrue(c.add(cat.app(id: "nes")!))
        XCTAssertEqual(c.apps.map(\.id), ["a", "settings", "nes"])
        XCTAssertEqual(c.setting("gamesFolder", for: "nes"), .string("~/Games/nes"))
        XCTAssertFalse(c.add(cat.app(id: "nes")!), "already added")
        XCTAssertEqual(c.apps.count, 3)
    }

    func testRemoveKeepsSettingsAndUnknowns() throws {
        let cat = try catalog()
        var c = config(["a", "future", "settings", "b"])
        XCTAssertTrue(c.remove(id: "a", catalog: cat))
        XCTAssertFalse(c.remove(id: "settings", catalog: cat), "Settings can't be removed")
        XCTAssertFalse(c.remove(id: "future", catalog: cat), "unknown ids are left alone")
        XCTAssertFalse(c.remove(id: "c", catalog: cat), "not added")
        XCTAssertEqual(c.apps.map(\.id), ["future", "settings", "b"])
    }

    func testMoveStepsOverUnlistedEntries() {
        let listed: (String) -> Bool = { $0 != "future" }
        var c = config(["a", "future", "b", "settings"])
        XCTAssertEqual(c.move(id: "b", by: -1, listed: listed), 0)
        XCTAssertEqual(c.apps.map(\.id), ["b", "future", "a", "settings"])
        XCTAssertNil(c.move(id: "b", by: -1, listed: listed), "already first")
        XCTAssertEqual(c.move(id: "b", by: 1, listed: listed), 1)
        XCTAssertEqual(c.apps.map(\.id), ["a", "future", "b", "settings"])
        XCTAssertNil(c.move(id: "settings", by: 1, listed: listed), "already last")
        XCTAssertNil(c.move(id: "zzz", by: 1, listed: listed))
        XCTAssertNil(c.move(id: "a", by: 2, listed: listed), "one step at a time")
    }

    func testMoveThereAndBackRestoresOrderAndSettings() {
        var c = AppConfig(apps: [AppEntry(id: "a", settings: ["k": .string("v")]), AppEntry(id: "b"), AppEntry(id: "settings")])
        let before = c
        XCTAssertEqual(c.move(id: "a", by: 1, listed: { _ in true }), 1)
        XCTAssertEqual(c.move(id: "a", by: -1, listed: { _ in true }), 0)
        XCTAssertEqual(c, before)
    }

    func testAddableListsUnaddedWithRequirementStatus() throws {
        let cat = try catalog()
        let c = config(["a", "settings"])
        let list = c.addable(catalog: cat) { $0.bundleId != "com.example.retro" }
        XCTAssertEqual(list.map(\.app.id), ["b", "c", "nes", "ps"], "settings and added apps are not offered")
        XCTAssertEqual(list.first { $0.app.id == "nes" }?.status, "needs RetroArch")
        XCTAssertEqual(list.first { $0.app.id == "b" }?.status, "Ready")
        let met = c.addable(catalog: cat) { _ in true }
        XCTAssertEqual(met.first { $0.app.id == "nes" }?.status, "Ready")
    }

    func testRequirementName() {
        XCTAssertEqual(RequirementText.name("RetroArch installed"), "RetroArch")
        XCTAssertEqual(RequirementText.name("Dolphin"), "Dolphin")
    }

    func testPackageRefRoundTripsAndBadRefIsDropped() throws {
        var c = config(["a"])
        XCTAssertFalse(String(decoding: try c.encoded(), as: UTF8.self).contains("packageRef"), "absent unless set")
        c.packageRef = "release/1.0"
        XCTAssertEqual(try AppConfig.parse(c.encoded()).packageRef, "release/1.0")
        let bad = Data(#"{"version":1,"apps":[],"packageRef":"../evil"}"#.utf8)
        XCTAssertNil(try AppConfig.parse(bad).packageRef)
    }

    func testReaderDefaultsToPackageOncePresent() {
        XCTAssertEqual(ReaderMode.from(nil, packagePresent: true), .package)
        XCTAssertEqual(ReaderMode.from(nil, packagePresent: false), .builtin)
        XCTAssertEqual(ReaderMode.from(.string("builtin"), packagePresent: true), .builtin, "explicit setting wins")
        XCTAssertEqual(ReaderMode.from(.string("package"), packagePresent: false), .package)
        XCTAssertEqual(ReaderMode.from(nil, catalogDefault: "builtin", packagePresent: true), .builtin, "catalog default wins")
        XCTAssertEqual(ReaderMode.from(.number(3), packagePresent: true), .builtin, "anything odd is builtin")
    }
}
