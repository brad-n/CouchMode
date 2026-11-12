import XCTest
import JavaScriptCore
@testable import CouchModeCore

/// The Disney+ package (apps/disney) against the frozen outputs of the former built-in Swift reader (Fixtures/golden): for every Disney fixture the package's
/// output, decoded the way the app decodes it, must equal what was frozen, including the "more"
/// cursors. The JS runs in JavaScriptCore; its page-reading half runs against a stand-in page and a stand-in fetch.
final class DisneyPackageParityTests: XCTestCase {
    private var context: JSContext!
    private var decoder: PackageDecoder!
    private var manifest: PackageManifest!
    private var g: Golden!

    private static let showID = "00000000-0000-4000-8000-000000000102"

    override func setUpWithError() throws {
        g = Golden("disney", function: name)
        manifest = try PackageManifest.parse(Data(contentsOf: Self.appDirectory.appendingPathComponent("manifest.json")))
        decoder = PackageDecoder(manifest: manifest)
        context = try Self.makeContext()
    }

    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/disney")
    }

    static func makeContext() throws -> JSContext {
        let source = try String(contentsOf: appDirectory.appendingPathComponent("reader.js"), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, e in XCTFail("script error: \(e?.toString() ?? "?")") }
        context.evaluateScript(source)
        return context
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Runs `reader.build.<function>(JSON.parse(input), extra...)` and returns its JSON text ("" for null).
    private func build(_ function: String, _ input: String, extra: String = "") -> String {
        context.setObject(input, forKeyedSubscript: "__input" as NSString)
        let result = context.evaluateScript("(() => { let r; try { r = reader.build.\(function)(JSON.parse(__input)\(extra)); } catch (e) { return ''; } return r == null ? '' : JSON.stringify(r); })()")
        return result?.toString() ?? ""
    }

    private func rowTitle(kind: StreamTitle.Kind = .show, id: String = DisneyPackageParityTests.showID) -> StreamTitle {
        let page = URL(string: "https://www.disneyplus.com/browse/entity-\(id)")
        return StreamTitle(id: id, name: "Show B", kind: kind, play: page ?? URL(string: "https://www.disneyplus.com/browse/search")!, page: page,
                           synopsis: "Short.", year: 2000, tileArt: URL(string: "https://example.invalid/tile"))
    }

    // MARK: Home

    private func assertHomeParity(_ read: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try g.next(file: file, line: line)
        let js = build("home", read)
        guard !(expected is NSNull) else { XCTAssertNil(decoder.home(js, serviceID: "disney"), read, file: file, line: line); return }
        let got = try XCTUnwrap(decoder.home(js, serviceID: "disney"), "package returned no home", file: file, line: line)
        Golden.assertEqual(got.home, expected, file: file, line: line)
        // Paging: the same rows can ask for more, from the same position.
        var cursors: [String: Any] = [:]
        for (rowID, text) in got.cursors {
            let object = try XCTUnwrap(StreamJSON.object(text))
            cursors[rowID] = ["setID": object["setID"] as? String ?? "", "query": object["query"] as? String ?? "", "next": StreamJSON.int(object["next"]) ?? -1] as [String: Any]
        }
        try g.expect(cursors, file: file, line: line)
    }

    func testHomeFixtureDecodesToWhatTheSwiftParserMakes() throws {
        let read = try fixture("disney-home-read")
        try assertHomeParity(read)
        let got = try XCTUnwrap(decoder.home(build("home", read), serviceID: "disney"))
        XCTAssertEqual(got.home.rows.map(\.kind), [.standard, .continueWatching, .ranked])
        XCTAssertEqual(got.home.hero?.name, "Movie A")
        XCTAssertEqual(got.home.currentProfileID, "Profile 1")
        XCTAssertEqual(got.home.rows.first?.totalCount, 50)
        XCTAssertEqual(got.cursors.count, 1, "only the row the site holds more of can page")
    }

    func testHomeEdgeCasesMatch() throws {
        func home(more: String, items: String = #"[{"id":"t1","name":"X"}]"#) -> String {
            #"{"rows":[{"id":"r1","name":"A","style":"poster_vertical","items":\#(items),"more":\#(more)}],"profiles":[]}"#
        }
        for more in [#"{"total":1,"next":1,"q":"a=b"}"#, #"{"total":9,"next":1,"q":"a=b"}"#, #"{"total":9,"next":1,"q":"a=b&token=x y"}"#,
                     #"{"total":9,"next":1,"q":"https://x.invalid/?a=b"}"#, #"{"total":9,"next":-1,"q":"a=b"}"#, #"{"total":9,"next":100000,"q":"a=b"}"#,
                     #"{"total":9,"next":5000,"q":"a=b"}"#, #"{"total":9,"next":1}"#, #"{"total":9,"q":"a=b"}"#, "null",
                     #"{"total":9,"next":1,"q":"\#(String(repeating: "a", count: 801))"}"#] {
            try assertHomeParity(home(more: more))
        }
        // The total is measured against the kept titles; the cursor against the items the site sent.
        try assertHomeParity(home(more: #"{"total":2,"next":2,"q":"a=b"}"#, items: #"[{"id":"t1","name":"X"},{"name":"no id"}]"#))
        for json in ["", "[]", "{}", #"{"rows":[]}"#, #"{"rows":[],"profiles":[{"name":"P","current":true}]}"#,
                     #"{"rows":[{"id":"h","name":"","style":"hero_immersive","items":[{"id":"t1","name":"Only Hero"}]}]}"#,
                     #"{"rows":[{"id":"h","style":"hero_immersive","items":[{"name":"bad"}]},{"id":"h2","style":"hero_immersive","items":[{"id":"t2","name":"Second"}]}]}"#,
                     #"{"rows":[{"id":"a b","name":"Bad id","style":"x","items":[{"id":"t1","name":"X"}]}]}"#,
                     #"{"rows":[{"name":"No id","style":"x","items":[{"id":"t1","name":"X"}]}]}"#,
                     #"{"rows":[{"id":"r","name":"Top","style":"top_ranked","items":[{"id":"t1","name":"X"}]},{"id":"c","name":"CW","style":"continue_watching","items":[{"id":"t2","name":"Y"}]}]}"#] {
            try assertHomeParity(json)
        }
    }

    func testProfilesMatch() throws {
        let item = #"[{"id":"t1","name":"X"}]"#
        for profiles in [#"[{"name":"A","avatar":"https://example.invalid/a","current":true},{"name":"B","avatar":"https://evil.invalid/b"},{"name":"B"},{"name":"C","avatar":"http://example.invalid/c"}]"#,
                         #"[{"name":"  A  ","current":true},{"name":""},{"avatar":"https://example.invalid/z"}]"#,
                         #"[{"name":"\#(String(repeating: "n", count: 65))","current":true},{"name":"ok"}]"#,
                         #"[{"name":"A","avatar":"https://img.bamgrid.com/a.png","current":true}]"#] {
            try assertHomeParity(#"{"rows":[{"id":"r1","name":"A","style":"s","items":\#(item)}],"profiles":\#(profiles)}"#)
        }
    }

    func testHomeIsBounded() throws {
        let items = (0..<60).map { #"{"id":"t\#($0)","name":"T\#($0)","runtimeMs":3600000}"# }.joined(separator: ",")
        let rows = (1...30).map { #"{"id":"r\#($0)","name":"R\#($0)","style":"s","items":[\#(items)]}"# }.joined(separator: ",")
        let read = #"{"rows":[\#(rows)],"profiles":[]}"#
        try assertHomeParity(read)
        let home = try XCTUnwrap(decoder.home(build("home", read), serviceID: "disney")).home
        XCTAssertEqual(home.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(home.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    func testCardsBecomeTitlesTheSameWay() throws {
        var home = #"{"rows":[{"id":"r","name":"Cards","style":"s","items":["#
        let cards = [
            #"{"id":"t1","name":"Movie","runtimeMs":7200000,"year":2019,"rating":"PG","tile":"img-1","wide":"img-2"}"#,
            #"{"id":"t2","name":"Resume","season":2,"episode":5,"runtimeMs":3000000,"pct":50,"playId":"ep-1"}"#,
            #"{"id":"t3","name":"Left","season":"3","episode":"1","runtimeMs":3600000,"left":600,"playId":"bad id"}"#,
            #"{"id":"t4","name":"Done","runtimeMs":3600000,"pct":100}"#, #"{"id":"t5","name":"Odd pct","runtimeMs":3600000,"pct":33.5,"left":3000}"#,
            #"{"id":"t6","name":"Zero season","season":0,"episode":3,"runtimeMs":0}"#, #"{"id":"t7","name":"Year text","year":"2018-2020"}"#,
            #"{"id":"t8","name":"Year bad","year":"20"}"#, #"{"id":"t9","name":"Year range","year":1800,"desc":"  words  "}"#,
            #"{"id":"a b","name":"bad id"}"#, #"{"id":"t10","name":"   "}"#, #"{"id":"t11","name":"Pct zero","runtimeMs":3600000,"pct":0,"left":1200}"#,
            #"{"id":"t12","name":"Bad image","tile":"a/b","wide":""}"#
        ]
        home += cards.joined(separator: ",") + "]}],\"profiles\":[]}"
        try assertHomeParity(home)
    }

    // MARK: Search and more

    func testSearchFixtureMatches() throws {
        let read = try fixture("disney-search-read")
        try g.expect(decoder.titles(build("search", read)))
        XCTAssertFalse(try XCTUnwrap(decoder.titles(build("search", read))).isEmpty)
        XCTAssertEqual(decoder.titles(build("search", "{}")), [])
        let items = (0..<80).map { #"{"id":"r\#($0)","name":"R\#($0)"}"# } + [#"{"id":"r1","name":"Again"}"#, #"{"name":"no id"}"#]
        let big = "[\(items.joined(separator: ","))]"
        try g.expect(decoder.titles(build("search", big)))
    }

    func testMoreMatchesAndAdvancesTheCursor() throws {
        let cursorJS = #", {"setID":"s1","query":"a=b","next":30}"#
        let item = #"{"id":"00000000-0000-4000-8000-000000000301","name":"More One"}"#
        for read in [#"{"items":[\#(item),{"id":"m2","name":"More Two","season":1,"runtimeMs":100000},{"name":"no id"}],"count":3,"hasMore":true}"#,
                     #"{"items":[\#(item)],"count":1,"hasMore":false}"#, #"{"items":[],"count":0,"hasMore":true}"#, #"{"items":[\#(item)],"hasMore":true}"#,
                     #"{"items":[\#(item)],"count":4975,"hasMore":true}"#, #"{"items":[\#(item)],"count":4970,"hasMore":true}"#] {
            let expected = try XCTUnwrap(try g.next() as? [String: Any], read)
            let got = try XCTUnwrap(decoder.more(build("more", read, extra: cursorJS)), read)
            Golden.assertEqual(got.titles, try XCTUnwrap(expected["titles"]), read)
            if !(expected["cursor"] is NSNull) {
                let object = try XCTUnwrap(StreamJSON.object(try XCTUnwrap(got.cursor)), read)
                Golden.assertEqual(["setID": object["setID"] as? String ?? "", "query": object["query"] as? String ?? "", "next": StreamJSON.int(object["next"]) ?? -1] as [String: Any],
                                   try XCTUnwrap(expected["cursor"]), read)
            } else {
                XCTAssertNil(got.cursor, read)
            }
        }
        for read in ["", "[1]", #"{"count":1}"#] {
            XCTAssertTrue(try g.nextIsNil())
            XCTAssertNil(decoder.more(build("more", read, extra: cursorJS)))
        }
        XCTAssertNil(decoder.more(build("more", #"{"items":[]}"#, extra: #", {"setID":"a b","query":"x=1","next":0}"#)), "an odd cursor reads nothing")
    }

    // MARK: Details and episodes

    private func assertDetailsParity(_ name: String, row: StreamTitle, file: StaticString = #filePath, line: UInt = #line) throws {
        let read = try fixture(name)
        let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: row)), as: UTF8.self)
        let expected = try g.next(file: file, line: line)
        XCTAssertFalse(expected is NSNull, file: file, line: line)
        let got = try XCTUnwrap(decoder.details(build("details", read, extra: ", \(argument)")), "package returned no details", file: file, line: line)
        Golden.assertEqual(got, expected, name, file: file, line: line)
    }

    func testEveryDetailsFixtureMatches() throws {
        try assertDetailsParity("disney-details-read", row: rowTitle())
        try assertDetailsParity("disney-details-read", row: rowTitle(kind: .movie))
        try assertDetailsParity("disney-movie-details-read", row: rowTitle(kind: .show, id: "00000000-0000-4000-8000-000000000101"))
        let details = try XCTUnwrap(decoder.details(build("details", try fixture("disney-details-read"),
                                                          extra: ", " + String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: rowTitle())), as: UTF8.self))))
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(details.currentSeasonID, "00000000-0000-4000-8000-000000000302")
    }

    func testDetailsEdgeCasesMatch() throws {
        for read in [#"{"id":"a1","name":"X","series":false,"seasons":[]}"#, #"{"series":true,"seasons":[{"id":"s1","name":"Only"}]}"#,
                     #"{"series":true,"seasons":[{"id":"s1","name":"One"},{"id":"s1","name":"Dup"},{"id":"s2"},{"id":"s3","name":"Three"}],"currentSeasonId":"s3","seasonsLabel":" 3 Seasons "}"#,
                     #"{"series":true,"seasons":[{"id":"s1","name":"One"},{"id":"s2","name":"Two"}],"currentSeasonId":"nope"}"#,
                     #"{"series":false,"runtimeMs":6000000,"pct":25,"playId":"p-1","desc":"D","rating":"R","year":"2001","wide":"w1","tile":"t1"}"#,
                     #"{"runtimeMs":-5,"pct":50}"#, "{}"] {
            for kind in [StreamTitle.Kind.show, .movie] {
                let row = rowTitle(kind: kind)
                let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: row)), as: UTF8.self)
                try g.expect(decoder.details(build("details", read, extra: ", \(argument)")), read)
            }
        }
        for read in ["", "[]", "nope", "null"] {
            XCTAssertNil(decoder.details(build("details", read, extra: ", {}")))
            XCTAssertTrue(try g.nextIsNil())
        }
    }

    func testSeasonFixtureEpisodesMatch() throws {
        let read = try fixture("disney-season-read")
        let expected = try g.next()
        XCTAssertFalse((expected as? [Any])?.isEmpty ?? true)
        Golden.assertEqual(decoder.episodes(build("episodes", read)), expected)
        for odd in [#"{"episodes":[{"id":"e1","playId":"p1"},{"id":"e1","playId":"p2"},{"id":"e2"},{"id":"e3","playId":"p3","number":0,"name":"  "},{"id":"e4","playId":"p4","number":"7","durationMs":60000,"pct":10}]}"#,
                    "{}", "", "nope"] {
            try g.expect(decoder.episodes(build("episodes", odd)) ?? [], odd)
        }
        let many = (0..<130).map { #"{"id":"e\#($0)","playId":"p\#($0)"}"# }.joined(separator: ",")
        try g.expect(decoder.episodes(build("episodes", #"{"episodes":[\#(many)]}"#)))
    }

    // MARK: Pages and profiles

    func testTheManifestDescribesTheSwiftReadersPages() throws {
        try g.expect(manifest.url(for: .home))
        try g.expect(manifest.url(for: .search, .init(query: "x")))
        try g.expect(manifest.url(for: .restore))
        for url in ["https://www.disneyplus.com/browse/search", "https://www.disneyplus.com/", "https://www.disneyplus.com/browse/entity-x", "https://www.disneyplus.com/play/x",
                    "https://www.disneyplus.com/video/x", "http://www.disneyplus.com/", "https://evil.invalid/", "https://www.disneyplus.com/update-profile/1",
                    "https://www.disneyplus.com/select-profile"] {
            let u = URL(string: url)
            try g.expect(manifest.isReusableSitePage(u), url)
            try g.expect(manifest.isProfileForm(u), url)
        }
        XCTAssertFalse(manifest.isReusableSitePage(nil))
        XCTAssertEqual(manifest.pages[.profile]?.settled, "profileSettled")
        XCTAssertEqual(manifest.pages[.home]?.readTimeout, .seconds(20))
        XCTAssertEqual(manifest.pages[.profile]?.confirmTimeout, .seconds(15))
    }

    /// A stand-in page: the profile menu button named by `current`, its dropdown entries, and the picker's tiles.
    private func setPage(path: String, current: String?, others: [String] = [], tiles: [String] = [], token: Bool = true) {
        context.evaluateScript("""
        var __clicks = [];
        var MouseEvent = function (type) { this.type = type; };
        var window = {};
        var __el = (extra) => Object.assign({ dispatchEvent: function (e) { __clicks.push(e.type + ':' + (this.name || '')); }, focus: () => {}, blur: () => {},
          querySelector: () => null, getAttribute: () => null }, extra);
        var __active = \(current == nil ? "null" : "__el({ getAttribute: k => k === 'aria-label' ? " + StreamJSON.jsString("\(current!)'s profile. Menu") + " : null, name: 'active' })");
        var __others = \(StreamJSON.jsString(others.joined(separator: "|"))).split('|').filter(Boolean).map(n => __el({ textContent: ' ' + n + ' ', name: n }));
        var __tiles = \(StreamJSON.jsString(tiles.joined(separator: "|"))).split('|').filter(Boolean).map(n => __el({ getAttribute: k => k === 'aria-label' ? n : null, name: 'tile-' + n }));
        var localStorage = { getItem: () => \(token ? "JSON.stringify({ access_token: 'SYNTH-SECRET-TOKEN' })" : "null") };
        var location = { pathname: \(StreamJSON.jsString(path)) };
        var setTimeout = (f) => f();
        var URLSearchParams = function () { this.m = []; this.set = (k, v) => this.m.push(k + "=" + v); this.toString = () => this.m.join("&"); };
        var document = {
          querySelector: s => s === '[data-testid="dropdown-active-profile"]' ? __active : (s.indexOf('dropdown-option-') >= 0 ? (__others.length ? __others[0] : null) : null),
          querySelectorAll: s => s.indexOf('dropdown-profile-') >= 0 ? __others : (s.indexOf('profile-avatar-') >= 0 ? __tiles : [])
        };
        """)
    }

    private func call(_ expression: String) -> String { context.evaluateScript(expression)?.toString() ?? "undefined" }

    func testPageChecksMatchTheSwiftScripts() {
        setPage(path: "/browse/search", current: "Profile 1")
        XCTAssertEqual(call("reader.pageReady()"), "true")
        XCTAssertEqual(call("reader.homeReady()"), "true")
        XCTAssertEqual(call("reader.profileIsCurrent({profileID: 'Profile 1'})"), "true")
        XCTAssertEqual(call("reader.profileSettled({profileID: 'Profile 2'})"), "false")
        setPage(path: "/browse/search", current: nil)
        XCTAssertEqual(call("reader.pageReady()"), "false", "no profile menu yet")
        setPage(path: "/browse/search", current: "Profile 1", token: false)
        XCTAssertEqual(call("reader.pageReady()"), "false", "no session")
        setPage(path: "/update-profile/abc", current: nil, token: true)
        XCTAssertEqual(call("reader.pageReady()"), "false")
        XCTAssertEqual(call("reader.homeReady()"), "true", "a profile form ends the wait")
        XCTAssertEqual(call("reader.profileSettled({profileID: 'Profile 2'})"), "true", "a profile form is a settled switch")
    }

    func testChoosingAProfilePressesTheMenuEntryOnlyWhenItIsUnique() {
        setPage(path: "/browse/search", current: "Profile 1", others: ["Profile 2", "Profile 3", "Profile 3"])
        context.evaluateScript("var __c; reader.chooseProfile({profileID: 'Profile 1'}).then(v => { __c = v; });")
        XCTAssertEqual(call("String(__c)"), "true", "already current")
        XCTAssertEqual(call("__clicks.length"), "0")
        context.evaluateScript("var __r; reader.chooseProfile({profileID: 'Profile 2'}).then(v => { __r = v; });")
        XCTAssertEqual(call("String(__r)"), "true")
        XCTAssertEqual(call("__clicks.filter(c => c.indexOf('click') === 0).join()"), "click:Profile 2")
        context.evaluateScript("__clicks = []; var __s; reader.chooseProfile({profileID: 'Profile 3'}).then(v => { __s = v; });")
        XCTAssertEqual(call("String(__s)"), "false", "a name two entries share is never guessed")
        XCTAssertEqual(call("__clicks.filter(c => c.indexOf('click') === 0).length"), "0")
        context.evaluateScript("var __t; reader.chooseProfile({profileID: 'Nobody'}).then(v => { __t = v; });")
        XCTAssertEqual(call("String(__t)"), "false")
    }

    func testRestoringChoosesTheOneMatchingPickerTile() {
        setPage(path: "/select-profile", current: nil, tiles: ["Profile 1", "Profile 2"])
        XCTAssertEqual(call("reader.pickerReady()"), "true")
        XCTAssertEqual(call("reader.leftPicker()"), "false")
        XCTAssertEqual(call("reader.restoreProfile({profileID: 'Profile 1'})"), "true")
        XCTAssertEqual(call("__clicks.filter(c => c.indexOf('click') === 0).join()"), "click:tile-Profile 1")
        XCTAssertEqual(call("reader.restoreProfile({profileID: 'Nobody'})"), "false")
        setPage(path: "/select-profile", current: nil, tiles: ["Twin", "Twin"])
        XCTAssertEqual(call("reader.restoreProfile({profileID: 'Twin'})"), "false")
        setPage(path: "/browse/search", current: "Profile 1")
        XCTAssertEqual(call("reader.pickerReady()"), "false")
        XCTAssertEqual(call("reader.leftPicker()"), "true")
    }

    // MARK: The requests, against a stand-in fetch

    /// Runs `reader.<call>` with a fetch that answers from `routes` (path after the API root -> JSON) and records what it was asked.
    private func run(_ call: String, routes: [String: String]) -> String {
        context.setObject(routes, forKeyedSubscript: "__routes" as NSString)
        context.evaluateScript("""
        var __asked = [], __headers = [], __answer = 'pending';
        var fetch = (url, options) => { __asked.push(url); __headers.push(JSON.stringify(options && options.headers));
          const path = url.replace('https://disney.api.edge.bamgrid.com/explore/v1.21/', '');
          return Promise.resolve({ ok: __routes[path] !== undefined, status: 404, json: () => Promise.resolve(JSON.parse(__routes[path])) }); };
        \(call).then(v => { __answer = v; });
        """)
        return self.call("__answer")
    }

    private let browse = #"{"type":"browse","pageId":"entity-00000000-0000-4000-8000-000000000999"}"#

    private func item(_ title: String = "Synth Title", extra: String = "") -> String {
        #"{"visuals":{"title":"\#(title)","durationMs":3600000,"metastringParts":{"releaseYearRange":{"startYear":2020}}},"actions":[\#(browse),{"type":"playback","deeplinkId":"dl-1"}]\#(extra)}"#
    }

    func testTheHomeIsReadWithTheSessionsTokenWhichNeverLeavesThePage() throws {
        setPage(path: "/browse/search", current: "Profile 1", others: ["Profile 2"])
        let nav = #"{"data":{"nav":{"children":[{"action":{"deeplinkId":"home","pageId":"page-00000000-0000-4000-8000-000000000001"}}]}}}"#
        let page = #"{"data":{"page":{"containers":[{"type":"set","id":"set-1","style":{"name":"continue_watching"},"visuals":{"name":"Continue"},"items":[\#(item())],"pagination":{"hasMore":true,"totalCount":90,"currentOffset":0},"params":{"a":"b"}}]}}}"#
        let answer = run("reader.home({})", routes: ["globalNav": nav,
            "page/page-00000000-0000-4000-8000-000000000001?disableSmartFocus=true&enhancedContainersLimit=16&limit=30": page])
        XCTAssertNotEqual(answer, "pending", call("__asked.join()"))
        let got = try XCTUnwrap(decoder.home(answer, serviceID: "disney"), answer)
        XCTAssertEqual(got.home.rows.first?.kind, .continueWatching)
        XCTAssertEqual(got.home.rows.first?.titles.first?.play.absoluteString, "https://www.disneyplus.com/play/dl-1")
        XCTAssertEqual(got.home.currentProfileID, "Profile 1")
        XCTAssertEqual(got.home.profiles.map(\.name), ["Profile 1", "Profile 2"])
        XCTAssertEqual(got.cursors["disney-row-set-1"].flatMap(StreamJSON.object)?["next"] as? Int, 1)
        XCTAssertEqual(call("__asked.length"), "2", "globalNav, then the home page: one request each")
        XCTAssertTrue(call("__headers[0]").contains("Bearer SYNTH-SECRET-TOKEN"), "the page's own session signs the request")
        XCTAssertFalse(answer.contains("SYNTH-SECRET-TOKEN"), "the token stays inside the script")
    }

    func testSearchDetailsSeasonAndMoreAskTheSitesOwnRequests() throws {
        setPage(path: "/browse/search", current: "Profile 1")
        let results = #"{"data":{"page":{"containers":[{"items":[\#(item("Found"))]}]}}}"#
        let found = run("reader.search({query: 'a & b'})", routes: ["search?query=a%20%26%20b": results])
        XCTAssertEqual(decoder.titles(found)?.map(\.name), ["Found"], found)
        XCTAssertEqual(call("__asked.length"), "1")

        let showID = Self.showID
        let pageJSON = #"{"data":{"page":{"visuals":{"title":"Show B"},"actions":[{"type":"playback","deeplinkId":"dl-9","options":[{"type":"resume"}]}],"containers":[{"type":"episodes","focus":{"seasonId":"s-1"},"seasons":[{"id":"s-1","visuals":{"name":"Season 1"}}]}]}}}"#
        let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: rowTitle())), as: UTF8.self)
        let details = run("reader.details({title: \(argument)})", routes: ["page/entity-\(showID)?disableSmartFocus=true&enhancedContainersLimit=0&limit=1": pageJSON])
        let parsed = try XCTUnwrap(decoder.details(details), details)
        XCTAssertEqual(parsed.title.play.absoluteString, "https://www.disneyplus.com/play/dl-9")
        XCTAssertEqual(parsed.seasons.map(\.name), ["Season 1"])

        let seasonID = "00000000-0000-4000-8000-000000000302"
        let season = #"{"data":{"season":{"items":[{"id":"ep-1","visuals":{"episodeTitle":"Pilot","episodeNumber":1,"durationMs":1800000},"actions":[{"type":"playback","deeplinkId":"dl-e1"}]}]}}}"#
        let episodes = run("reader.season({seasonID: '\(seasonID)'})", routes: ["season/\(seasonID)?limit=100": season])
        XCTAssertEqual(decoder.episodes(episodes)?.map(\.name), ["Pilot"], episodes)
        XCTAssertEqual(run("reader.season({seasonID: 'not-a-uuid'})", routes: [:]), "", "only a plain uuid is asked for")

        let set = #"{"data":{"set":{"items":[\#(item("Further"))],"pagination":{"hasMore":false}}}}"#
        let more = run(#"reader.more({cursor: {setID: "set-1", query: "a=b", next: 30}})"#, routes: ["set/set-1?limit=30&offset=30&a=b": set])
        let batch = try XCTUnwrap(decoder.more(more), more)
        XCTAssertEqual(batch.titles.map(\.name), ["Further"])
        XCTAssertNil(batch.cursor)
        XCTAssertEqual(run(#"reader.more({cursor: {setID: "a b", query: "a=b", next: 0}})"#, routes: [:]), "")
        XCTAssertEqual(call("__asked.length"), "0", "an odd cursor makes no request")
    }

    func testFailuresAreNoAnswer() {
        setPage(path: "/browse/search", current: "Profile 1")
        XCTAssertEqual(run("reader.home({})", routes: [:]), "")
        XCTAssertEqual(run("reader.search({query: ''})", routes: [:]), "")
        setPage(path: "/browse/search", current: "Profile 1", token: false)
        XCTAssertEqual(run("reader.search({query: 'x'})", routes: ["search?query=x": #"{"data":{"page":{"containers":[]}}}"#]), "", "no session, no request")
        XCTAssertEqual(call("__asked.length"), "0")
    }
}
