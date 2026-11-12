import XCTest
import JavaScriptCore
@testable import CouchModeCore

/// The Hulu package (apps/hulu) against the built-in Swift reader: for every Hulu fixture the package's output,
/// decoded the way the app decodes it, must equal what the Swift parser produces. The JS runs in JavaScriptCore;
/// its page-reading half is exercised against a small stand-in page.
final class HuluPackageParityTests: XCTestCase {
    private var context: JSContext!
    private var decoder: PackageDecoder!
    private var manifest: PackageManifest!

    override func setUpWithError() throws {
        manifest = try PackageManifest.parse(Data(contentsOf: Self.appDirectory.appendingPathComponent("manifest.json")))
        decoder = PackageDecoder(manifest: manifest)
        context = try Self.makeContext()
    }

    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/hulu")
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

    private let seriesID = "00000000-0000-4000-8000-000000000001"
    private var show: StreamTitle {
        StreamTitle(id: seriesID, name: "Show A", kind: .show, play: URL(string: "https://www.hulu.com/watch/x")!,
                    page: URL(string: "https://www.hulu.com/series/\(seriesID)"))
    }

    // MARK: Home

    private func assertHomeParity(_ read: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let js = build("home", read)
        guard let expected = HuluHome.parse(read) else { XCTAssertNil(decoder.home(js, serviceID: "hulu"), file: file, line: line); return }
        let got = try XCTUnwrap(decoder.home(js, serviceID: "hulu"), "package returned no home", file: file, line: line)
        XCTAssertEqual(got.home, expected, file: file, line: line)
        XCTAssertTrue(got.cursors.isEmpty, "Hulu's home has no paging", file: file, line: line)
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

    func testHomeFixtureDecodesToWhatTheSwiftParserMakes() throws {
        let read = try fixture("hulu-home-read")
        try assertHomeParity(read)
        let got = try XCTUnwrap(decoder.home(build("home", read), serviceID: "hulu")).home
        XCTAssertEqual(got.rows.map(\.kind), [.standard, .standard, .continueWatching, .ranked])
        XCTAssertEqual(got.currentProfile?.name, "Profile 1")
        XCTAssertEqual(got.profiles.map(\.isKids), [false, false, false, true])
        XCTAssertNotNil(got.hero)
    }

    func testHomeEdgeCasesMatch() throws {
        try assertHomeParity(home(rows: [("1", "Mixed", [
            item(id: "a1", type: "network"), item(id: "a2", type: "hub"), item(id: "a3", type: "series"),
            item(id: "a4", type: "movie"), item(id: "a5", type: "episode", subtitle: "S2 E5 - Name"),
            item(id: "a6", type: "series", eab: nil), item(id: "a7", type: "series", eab: "EAB::NULL::1::2"),
            item(id: "bad id!", type: "series"),
        ]), ("2", "Only networks", [item(id: "b1", type: "network")])]))
        try assertHomeParity(home(rows: [("1", "Mixed", [
            item(id: "c1", type: "series", subtitle: "S1 E7 - Name", action: "Resume Episode"),
            item(id: "c2", type: "series", subtitle: "S1 E1 - Name", action: "Start Watching"),
            item(id: "c3", type: "series", subtitle: "S23 E1 - Name", action: "Watch Latest Season"),
            item(id: "c4", type: "episode", subtitle: "S2 E5 - Name", action: "Watch Episode"),
            item(id: "c5", type: "episode", subtitle: "Season 2", action: nil),
        ])]))
        try assertHomeParity(home(rows: [("1", "Spotlight", [item(id: "h1", type: "network"), item(id: "h2", type: "movie", name: "Movie H")]),
                                         ("2", "Spotlight", [item(id: "h3", type: "movie", name: "Movie I")]),
                                         ("3", "Popular", [item(id: "p1")])]))
        try assertHomeParity(home(rows: [("1", "Continue Watching for Profile 1", [item(id: "c1")]), ("2", "Top 10 Movies", [item(id: "c2")]),
                                         ("3", "Top Picks", [item(id: "c3")]), ("4", "Comedy", [item(id: "c4")]), ("", "No id", [item(id: "c5")])]))
        let many = (1...15).map { #"{"id":"\#($0)","name":"Profile \#($0)","kids":\#($0 == 4 ? "true" : "false")}"# }
        try assertHomeParity(#"{"rows":[{"id":"1","name":"Popular","items":[\#(item())]}],"profiles":[{"id":"bad id","name":"X","kids":false},{"id":"7","name":"","kids":false},\#(many.joined(separator: ","))],"currentProfileId":"3"}"#)
        for json in ["", "[]", "{}", #"{"profiles":[]}"#, #"{"rows":[{"id":"1","name":"Networks","items":[]}],"profiles":[]}"#, "null"] {
            try assertHomeParity(json)
        }
    }

    func testHomeIsBounded() throws {
        let titles = (1...(StreamLimits.maxTitlesPerRow + 10)).map { item(id: "t\($0)") }
        let rows = (1...(StreamLimits.maxRows + 5)).map { ("\($0)", "Row \($0)", titles) }
        try assertHomeParity(home(rows: rows))
        let got = try XCTUnwrap(decoder.home(build("home", home(rows: rows)), serviceID: "hulu")).home
        XCTAssertEqual(got.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(got.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    func testARealSizedHomeFitsTheAnswerLimit() throws {
        // 30 components of 40 titles with long artwork addresses, like the live home: the app keeps 20 rows, and the text must stay under the script's cap.
        let art = "https://img2.hulu.com/user/v3/artwork/00000000-0000-4000-8000-000000000001?base_image_bucket_name=image_manager&base_image=" + String(repeating: "x", count: 120)
        let titles = (1...StreamLimits.maxTitlesPerRow).map { item(id: "00000000-0000-4000-8000-\(String(format: "%012d", $0))", name: "Title number \($0)", tile: art) }
        let rows = (1...30).map { ("\($0)", "Row \($0)", titles) }
        let read = home(rows: rows)
        try assertHomeParity(read)
        XCTAssertLessThan(build("home", read).count, 900_000)
    }

    // MARK: Images (the `operations` parameter)

    func testImageAddressesMatch() throws {
        let addresses = [
            "https://img2.hulu.com/user/v3/artwork/x?a=1", "https://img.hulu.invalid/x", "https://img.hulu.invalid/x?base_image_bucket_name=image_manager&base_image=art-1",
            #"https://img2.hulu.com/x?base_image=1&operations=%5B%7B%22resize%22:%22200x200%7Cmax%22%7D%5D"#,
            "https://img2.hulu.com/x?a=b%20c&d=e+f&flag", "https://img2.hulu.com:8443/x?q=(a)!*'", "https://img2.hulu.com/x#frag", "https://img2.hulu.com",
            "https://IMG2.HULU.COM/x?a=1", "https://x.huluim.com/p/q.jpg?z=%C3%A9", "http://img2.hulu.com/x", "https://evilhulu.com/x",
            "https://hulu.com.evil.example/x", "https://example.com/x", "not an address", "",
        ]
        for address in addresses {
            let json = home(rows: [("1", "Row", [item(tile: address)])])
            let expected = HuluHome.parse(json)?.rows.first?.titles.first
            let got = decoder.home(build("home", json), serviceID: "hulu")?.home.rows.first?.titles.first
            XCTAssertEqual(got?.tileArt, expected?.tileArt, address)
            XCTAssertEqual(got?.heroArt, expected?.heroArt, address)
            if address == addresses[0] {
                XCTAssertTrue(try XCTUnwrap(got?.tileArt).absoluteString.contains("640x360"))
                XCTAssertTrue(try XCTUnwrap(got?.heroArt).absoluteString.contains("1920x1080"))
            }
        }
    }

    // MARK: Details and episodes

    private func argument(_ title: StreamTitle) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: title)), as: UTF8.self)
    }

    private func assertDetailsParity(_ read: String, row: StreamTitle, file: StaticString = #filePath, line: UInt = #line) throws {
        let js = build("details", read, extra: ", \(try argument(row))")
        guard let expected = HuluDetails.details(fromRead: read, title: row) else { XCTAssertNil(decoder.details(js), file: file, line: line); return }
        XCTAssertEqual(try XCTUnwrap(decoder.details(js), "package returned no details", file: file, line: line), expected, file: file, line: line)
    }

    func testEveryDetailsFixtureMatches() throws {
        let read = try fixture("hulu-details-read")
        try assertDetailsParity(read, row: show)
        // A show from search only knew its own id; details name the episode Play continues.
        let fromSearch = StreamTitle(id: seriesID, name: "Show A", kind: .show, play: URL(string: "https://www.hulu.com/watch/\(seriesID)")!)
        try assertDetailsParity(read, row: fromSearch)
        let details = try XCTUnwrap(decoder.details(build("details", read, extra: ", \(try argument(fromSearch))")))
        XCTAssertEqual(details.title.episodeLabel, "S1 · E3")
        XCTAssertEqual(details.currentSeasonID, "\(seriesID)::1")
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(details.seasons[0].episodes.count, 10)
        XCTAssertEqual(details.seasons[0].episodes.first { $0.number == 3 }?.resumeSeconds, 1434 * 40 / 100)
    }

    func testDetailsEdgeCasesMatch() throws {
        let movie = StreamTitle(id: "m1", name: "Movie A", kind: .movie, play: URL(string: "https://www.hulu.com/watch/m1")!)
        var full = show
        full.synopsis = "From the row"; full.year = 2001; full.rating = "PG"; full.seasonsLabel = "9 Seasons"; full.episodeLabel = "S9 · E9"
        full.tileArt = URL(string: "https://img.hulu.invalid/a")
        let reads = [
            #"{"name":"Movie A","description":"Placeholder.","rating":"R","premiere":"2026-08-07T19:00:00Z","duration":6253,"genres":[],"currentSeasonId":null,"seasons":[],"shownEpisodes":[]}"#,
            #"{"description":"x","currentSeasonId":null,"seasons":[{"id":"s::1","name":"Limited Series"}],"shownEpisodes":[]}"#,
            #"{"seasons":[{"id":"a::1","name":"Season 1"},{"id":"a::1","name":"Again"},{"id":"a::2","name":""}],"currentSeasonId":"a::1","shownEpisodes":[{"id":"bad id","name":"Bad"},{"id":"e1","number":"2","name":"Two","progress":150,"duration":100},{"id":"e1","name":"Dup"},{"id":"e2","number":null,"name":null},{"id":"e3","number":3,"name":" ","progress":50,"duration":200,"synopsis":" About "}]}"#,
            #"{"premiere":"1850-01-01","duration":0,"playId":"p1","playSeason":"S2","playNumber":"4","seasons":[],"shownEpisodes":[]}"#,
            #"{"playId":"p1","playSeason":"S2","playNumber":4,"seasons":[{"id":"a::1","name":"S"},{"id":"a::2","name":"T"}],"currentSeasonId":"nope"}"#,
            #"{"playId":"bad id","rating":" ","description":""}"#, "{}", "[]", "", "nope", "null",
        ]
        for read in reads {
            for row in [show, movie, full] { try assertDetailsParity(read, row: row) }
        }
        let list = (1...(StreamLimits.maxEpisodesPerSeason + 20)).map { #"{"id":"e\#($0)","number":"\#($0)","name":"E"}"# }
        try assertDetailsParity(#"{"currentSeasonId":"a::1","seasons":[{"id":"a::1","name":"S"}],"shownEpisodes":[\#(list.joined(separator: ","))]}"#, row: show)
    }

    func testSeasonFixtureMatches() throws {
        let read = try fixture("hulu-season-read")
        let expected = HuluDetails.episodes(fromSeason: read)
        XCTAssertEqual(expected.count, 6)
        XCTAssertEqual(decoder.episodes(build("season", read)), expected)
        for json in ["nope", "[]", "{}", #"{"episodes":[{"id":"e1","number":"x"}]}"#] {
            XCTAssertEqual(decoder.episodes(build("season", json)) ?? [], HuluDetails.episodes(fromSeason: json), json)
        }
        let list = (1...(StreamLimits.maxEpisodesPerSeason + 20)).map { #"{"id":"e\#($0)","number":"\#($0)","name":"E"}"# }
        let big = #"{"episodes":[\#(list.joined(separator: ","))]}"#
        XCTAssertEqual(decoder.episodes(build("season", big)), HuluDetails.episodes(fromSeason: big))
    }

    // MARK: Search

    func testSearchFixtureMatches() throws {
        let read = try fixture("hulu-search-read")
        let expected = HuluSearch.titles(fromResults: read)
        XCTAssertEqual(expected.count, 6)
        XCTAssertEqual(decoder.titles(build("search", read)), expected)
        let reads = [
            #"[{"href":"/series/00000000-0000-4000-8000-000000000001","name":"Show A","art":"https://img.hulu.invalid/a?x=1"},{"href":"/movie/00000000-0000-4000-8000-000000000002","name":" Movie B ","art":null}]"#,
            #"[{"href":"/account","name":"Account"},{"href":"/network/abc","name":"Network"},{"href":"/series/bad id","name":"Bad"},{"href":"/series/a1","name":"  "},{"href":"/series/a2","name":"Two","art":"https://evil.example/x.jpg"},{"href":"/series/a2","name":"Again"},{"href":"/series/a3/extra","name":"Extra"},{"href":null,"name":"x"}]"#,
            "not json", "{}", "[]",
        ]
        for json in reads { XCTAssertEqual(decoder.titles(build("search", json)) ?? [], HuluSearch.titles(fromResults: json), json) }
        let cards = (1...(StreamLimits.maxSearchResults + 10)).map { #"{"href":"/series/s\#($0)","name":"T\#($0)"}"# }
        let big = "[" + cards.joined(separator: ",") + "]"
        XCTAssertEqual(decoder.titles(build("search", big)), HuluSearch.titles(fromResults: big))
    }

    // MARK: The manifest

    func testManifestAsksForWhatTheSwiftReaderOpens() throws {
        XCTAssertEqual(manifest.url(for: .home)?.absoluteString, "https://www.hulu.com/hub/home")
        XCTAssertEqual(manifest.url(for: .search, .init(query: "show a"))?.absoluteString, HuluSearch.pageURL.absoluteString)
        XCTAssertEqual(manifest.url(for: .profile)?.absoluteString, "https://www.hulu.com/hub/home")
        XCTAssertEqual(manifest.url(for: .details, .init(titlePage: show.page))?.absoluteString, show.page?.absoluteString)
        XCTAssertEqual(manifest.url(for: .season, .init(titlePage: show.page, seasonID: "\(seriesID)::2"))?.absoluteString, show.page?.absoluteString)
        XCTAssertTrue(try XCTUnwrap(manifest.pages[.season]).reuseIfOpen)
        XCTAssertFalse(manifest.definesPlayerShown)
        XCTAssertEqual(manifest.readTimeout, .seconds(12))
    }

    // MARK: The page-reading half, against a stand-in page

    /// Installs a stand-in page: its elements, store and fetch. Promises settle when each script call returns.
    private func install(nextData: String? = nil, store: String = "null", fetchJSON: String = "{}", links: String = "[]", location: String = "/") {
        context.evaluateScript("""
        var __log = { fetches: [], typed: [], clicks: [] };
        var __links = \(links).map(l => ({ getAttribute: n => n === 'href' ? l.href : null,
          querySelector: s => s.indexOf('title') >= 0 ? { textContent: l.name } : { getAttribute: () => l.art } }));
        var __box = { focus: () => {}, dispatchEvent: () => {}, __reactProps$x: {} };
        var __items = [{ getAttribute: () => 'Switch profile to Profile 2', dispatchEvent: e => { __log.clicks.push(e.type); } }];
        var document = {
          readyState: 'complete',
          getElementById: id => id === '__NEXT_DATA__' && \(nextData.map { StreamJSON.jsString($0) } ?? "null") !== null ? { textContent: \(nextData.map { StreamJSON.jsString($0) } ?? "''") } : null,
          querySelector: s => s.indexOf('search-bar-input') >= 0 ? __box : null,
          querySelectorAll: s => s.indexOf('instant-search-item-link') >= 0 ? __links : s.indexOf('ProfileList') >= 0 ? __items : []
        };
        var window = { store: { getState: () => (\(store)) } };
        var location = { pathname: '\(location)' };
        var HTMLInputElement = function() {}; HTMLInputElement.prototype = {};
        Object.defineProperty(HTMLInputElement.prototype, 'value', { set: function(v) { __log.typed.push(v); }, configurable: true });
        var Event = function(type) { this.type = type; }; var MouseEvent = Event;
        var setTimeout = f => { f(); return 0; };
        var fetch = async url => { __log.fetches.push(url); return { ok: true, json: async () => (\(fetchJSON)) }; };
        """)
    }

    /// Calls an async reader function and returns its text answer.
    private func call(_ expression: String) -> String {
        context.evaluateScript("var __out = 'pending'; Promise.resolve(\(expression)).then(v => { __out = v; });")
        return context.objectForKeyedSubscript("__out")?.toString() ?? "undefined"
    }

    private func fetches() -> [String] {
        (context.evaluateScript("__log.fetches")?.toArray() as? [String]) ?? []
    }

    private let storeJS = #"{ profile_manager: { currentProfileId: 1001, profiles: [{ id: 1001, name: 'Profile 1', is_kids: false, email: 'a@b.invalid', birthdate: '2000-01-01' }, { id: 1002, name: 'Profile 2', is_kids: true, token: 'secret' }] } }"#

    func testHomeIsOneDiscoverRequestAndOnlyProfileIdNameAndKidsAreReadFromTheStore() throws {
        let next = #"{"props":{"pageProps":{"dehydratedState":{"queries":[{"queryKey":["GlobalNav"],"state":{"data":{"nav":{"defaultNavItem":{"discoverHref":"https://discover.hulu.com/content/v5/view_hubs/home?schema=3"}}}}}]}}}}"#
        let hub = #"{"components":[{"id":"7","name":"Popular","items":[{"id":"00000000-0000-4000-8000-000000000042","metrics_info":{"target_type":"series","target_name":"Show Z"},"visuals":{"headline":"Show Z","body":"About.","artwork":{"horizontal_tile":{"image":{"path":"https://img.hulu.invalid/t"}}}},"personalization":{"eab":"EAB::00000000-0000-4000-8000-000000000099::1::2"}}]}]}"#
        install(nextData: next, store: storeJS, fetchJSON: hub)
        XCTAssertEqual(call("reader.homeReady()"), "true")
        let json = call("reader.home()")
        XCTAssertEqual(fetches(), ["https://discover.hulu.com/content/v5/view_hubs/home?schema=3"])
        XCTAssertFalse(json.contains("a@b.invalid") || json.contains("birthdate") || json.contains("secret"))
        let got = try XCTUnwrap(decoder.home(json, serviceID: "hulu")).home
        XCTAssertEqual(got.rows.first?.titles.first?.name, "Show Z")
        XCTAssertEqual(got.profiles.map(\.name), ["Profile 1", "Profile 2"])
        XCTAssertEqual(got.profiles.map(\.isKids), [false, true])
        XCTAssertEqual(got.currentProfileID, "1001")
    }

    func testHomeRefusesAnAddressOffTheDiscoverService() {
        install(nextData: #"{"props":{"pageProps":{"dehydratedState":{"queries":[{"queryKey":["GlobalNav"],"state":{"data":{"nav":{"defaultNavItem":{"discoverHref":"https://evil.example/x"}}}}}]}}}}"#, store: storeJS)
        XCTAssertEqual(call("reader.home()"), "")
        XCTAssertEqual(fetches(), [])
        install()
        XCTAssertEqual(call("reader.home()"), "")
        XCTAssertEqual(call("reader.homeReady()"), "false")
    }

    func testDetailsAskOnlyDiscoverAndOnlyForTheShownTitle() throws {
        let hub = #"{"details":{"entity":{"name":"Show A","description":"About.","rating":{"code":"TV14"},"premiere_date":"2020-01-01T00:00:00Z"}},"components":[{"theme":"collection_theme_groupings","items":[{"id":"\#(seriesID)::1","name":"Season 1","items":[{"id":"e1","number":"1","name":"One","description":"First.","bundle":{"duration":600}}]}]}]}"#
        install(fetchJSON: hub, location: "/series/\(seriesID)")
        XCTAssertEqual(call("reader.detailsReady()"), "true")
        let details = try XCTUnwrap(decoder.details(call("reader.details({title: \(try argument(show))})")))
        XCTAssertEqual(fetches(), ["https://discover.hulu.com/content/v5/hubs/series/\(seriesID)?schema=3&limit=1999"])
        XCTAssertEqual(details.title.rating, "TV14")
        XCTAssertEqual(details.seasons.first?.episodes.map(\.name), ["One"])
        context.evaluateScript(#"fetch = async url => { __log.fetches.push(url); return { ok: true, json: async () => ({ items: [{ id: "e9", number: "9", name: "Nine" }] }) }; };"#)
        // A season: its own address, and only for a well-formed season id.
        let episodes = try XCTUnwrap(decoder.episodes(call(#"reader.season({seasonID: "\#(seriesID)::2"})"#)))
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(fetches().last, "https://discover.hulu.com/content/v5/hubs/series/\(seriesID)/season/2?schema=3&limit=100")
        let before = fetches().count
        XCTAssertEqual(call(#"reader.season({seasonID: "../x"})"#), "")
        XCTAssertEqual(fetches().count, before)
        install(location: "/account")
        XCTAssertEqual(call("reader.detailsReady()"), "false")
        XCTAssertEqual(call("reader.details({title: {}})"), "")
    }

    func testSearchTypesIntoThePagesOwnBoxThenReadsWhatItLists() throws {
        let links = #"[{"href":"/series/s1","name":"Show A","art":"https://img.hulu.invalid/a"},{"href":"/account","name":"Me","art":null},{"href":"/movie/m1","name":"Movie B","art":null}]"#
        install(links: links)
        XCTAssertEqual(call("reader.searchReady()"), "true")
        // The stand-in lists everything, so filter as the page's selector would.
        context.evaluateScript("__links = __links.filter(l => /^\\/(series|movie)\\//.test(l.getAttribute('href')));")
        let titles = try XCTUnwrap(decoder.titles(call(#"reader.search({query: "show a"})"#)))
        XCTAssertEqual(titles.map(\.name), ["Show A", "Movie B"])
        XCTAssertEqual(context.evaluateScript("__log.typed")?.toArray() as? [String], ["show a"])
        // Nothing listed is an answer, not a failure.
        context.evaluateScript("__links = []; Date.now = (() => { let t = 0; return () => (t += 5000); })();")
        XCTAssertEqual(call(#"reader.search({query: "zzz"})"#), "[]")
        install()
        context.evaluateScript("document.querySelector = () => null;")
        XCTAssertEqual(call(#"reader.search({query: "x"})"#), "", "no search box to type in")
        XCTAssertEqual(call("reader.searchReady()"), "false")
    }

    func testTheProfileChecksReadThePageNotTheArguments() {
        install(store: storeJS)
        XCTAssertEqual(call("reader.profileListReady()"), "true")
        XCTAssertEqual(call("reader.profileIsCurrent({profileID: '1001'})"), "true")
        XCTAssertEqual(call("reader.profileIsCurrent({profileID: '1002'})"), "false")
        XCTAssertEqual(call("reader.chooseProfile({profileID: '1001'})"), "true", "already current")
        XCTAssertEqual(context.evaluateScript("__log.clicks.length")?.toInt32(), 0)
        XCTAssertEqual(call("reader.chooseProfile({profileID: '1002'})"), "true")
        XCTAssertEqual(context.evaluateScript("__log.clicks")?.toArray() as? [String], ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
        XCTAssertEqual(call("reader.chooseProfile({profileID: 'nobody'})"), "false")
        // A name two profiles share is refused rather than guessed.
        install(store: #"{ profile_manager: { currentProfileId: 1, profiles: [{ id: 1, name: 'A' }, { id: 2, name: 'Profile 2' }, { id: 3, name: 'Profile 2' }] } }"#)
        XCTAssertEqual(call("reader.chooseProfile({profileID: '2'})"), "false")
    }
}
