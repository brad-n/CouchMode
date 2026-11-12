import XCTest
import JavaScriptCore
@testable import CouchModeCore

/// The Apple TV package (apps/appletv) against the frozen outputs of the former built-in Swift reader (Fixtures/golden): for every Apple TV fixture the package's
/// output, decoded the way the app decodes it, must equal what was frozen. The JS runs in
/// JavaScriptCore; its page-reading half is exercised against a stand-in page and a stand-in API.
final class AppleTVPackageParityTests: XCTestCase {
    private var context: JSContext!
    private var decoder: PackageDecoder!
    private var manifest: PackageManifest!
    private var g: Golden!

    override func setUpWithError() throws {
        g = Golden("appletv", function: name)
        manifest = try PackageManifest.parse(Data(contentsOf: Self.appDirectory.appendingPathComponent("manifest.json")))
        decoder = PackageDecoder(manifest: manifest)
        let source = try String(contentsOf: Self.appDirectory.appendingPathComponent("reader.js"), encoding: .utf8)
        context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, e in XCTFail("script error: \(e?.toString() ?? "?")") }
        context.evaluateScript(source)
    }

    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/appletv")
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

    private let showPage = "https://tv.apple.com/us/show/x/"
    private func row(_ id: String, kind: StreamTitle.Kind, name: String) -> StreamTitle {
        StreamTitle(id: id, name: name, kind: kind, play: URL(string: "\(showPage)\(id)")!, page: URL(string: "\(showPage)\(id)"))
    }
    private func argument(_ title: StreamTitle) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: title)), as: UTF8.self)
    }

    // MARK: Manifest

    func testManifestIsValidAndAllActionsUseTheQuietSessionPage() throws {
        XCTAssertEqual(manifest.id, "appletv")
        XCTAssertTrue(manifest.definesPlayerShown)
        for kind in [PackageManifest.PageKind.home, .details, .season, .search, .profile] {
            try g.expect(manifest.url(for: kind, .init(query: "x")), "\(kind)")
            XCTAssertEqual(manifest.pages[kind]?.reuseSitePage, kind != .home)
        }
        XCTAssertNil(manifest.pages[.more], "rows hold what the home request returned")
    }

    // MARK: Home

    private func assertHomeParity(_ read: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let js = build("home", read)
        let expected = try g.next(file: file, line: line)
        guard !(expected is NSNull) else { XCTAssertNil(decoder.home(js, serviceID: "appletv"), file: file, line: line); return }
        let got = try XCTUnwrap(decoder.home(js, serviceID: "appletv"), "package returned no home", file: file, line: line)
        Golden.assertEqual(got.home, expected, file: file, line: line)
        XCTAssertTrue(got.cursors.isEmpty, file: file, line: line)
    }

    private func card(_ id: String, kind: String = "show", name: String = "T", page: String? = nil, extra: String = "") -> String {
        let p = page ?? "https://tv.apple.com/us/show/t/\(id)"
        return #"{"id":"\#(id)","kind":"\#(kind)","name":"\#(name)","page":"\#(p)"\#(extra)}"#
    }

    private func home(_ shelves: [(String, String, String, [String])]) -> String {
        let json = shelves.map { #"{"id":"\#($0.0)","name":"\#($0.1)","type":"\#($0.2)","items":[\#($0.3.joined(separator: ","))]}"# }
        return #"{"rows":[\#(json.joined(separator: ","))]}"#
    }

    func testHomeFixtureDecodesToWhatTheSwiftParserMakes() throws {
        let read = try fixture("appletv-home-read")
        try assertHomeParity(read)
        let got = try XCTUnwrap(decoder.home(build("home", read), serviceID: "appletv")).home
        XCTAssertEqual(got.rows.map(\.kind), [.continueWatching, .ranked, .standard])
        XCTAssertEqual(got.hero?.name, "Stage Show")
        XCTAssertEqual(got.profiles.count, 1)
        XCTAssertEqual(got.rows[0].titles[0].play.absoluteString, "https://tv.apple.com/us/episode/pilot/umc.cmc.synthep0001?showId=umc.cmc.synthshow1&action=play")
    }

    func testHomeEdgeCasesMatch() throws {
        try assertHomeParity(home([("a", "Row", "lockup", [card("umc.cmc.one1"), card("bad id"), card("ab"), card("umc.cmc.off1", page: "https://example.com/x"),
                                                         card("umc.cmc.port1", page: "https://tv.apple.com:8443/x"), card("umc.cmc.http1", page: "http://tv.apple.com/x")]),
                                   ("a", "Repeated id", "lockup", [card("umc.cmc.two2")]), ("b", "  ", "lockup", [card("umc.cmc.three3")]),
                                   ("c", "Empty", "lockup", []), ("", "No id", "lockup", [card("umc.cmc.four4")]),
                                   ("d", "Charts", "chart", [card("umc.cmc.five5")]), ("e", "Up next", "upNextLockup", [card("umc.cmc.six6")])]))
        try assertHomeParity(home([("s1", "", "epicStage", [card("umc.cmc.stage1"), card("umc.cmc.stage2")]), ("s2", "", "epicStage", [card("umc.cmc.stage3")])]))
        try assertHomeParity(home([("s1", "", "epicStage", [card("umc.cmc.stage1")]), ("r", "Row", "brick", [card("umc.cmc.one1")])]))
        let longID = String(repeating: "x", count: 120)
        try assertHomeParity(home([(longID, "Long id", "lockup", [card("umc.cmc.one1")]), (longID + "y", "Too long", "lockup", [card("umc.cmc.two2")])]))
        for json in ["", "[]", "{}", #"{"rows":[]}"#, #"{"rows":"nope"}"#, "null", #"{"rows":[{"id":"a","name":"A","type":"lockup","items":[{"id":"x"}]}]}"#] {
            try assertHomeParity(json)
        }
    }

    func testHomeIsBounded() throws {
        let titles = (1...(StreamLimits.maxTitlesPerRow + 10)).map { card("umc.cmc.t\($0)") }
        let rows = (1...(StreamLimits.maxRows + 5)).map { ("s\($0)", "Row \($0)", "lockup", titles) }
        try assertHomeParity(home(rows))
        let got = try XCTUnwrap(decoder.home(build("home", home(rows)), serviceID: "appletv")).home
        XCTAssertEqual(got.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(got.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    // MARK: Cards: facts, play address, art

    func testCardFactsAndPlayAddressesMatch() throws {
        let tile = #"{"u":"https://is1-ssl.mzstatic.com/image/thumb/a/{w}x{h}{c}.{f}","w":1920,"h":1080}"#
        let page = "https://tv.apple.com/us/show/t/umc.cmc.t1"
        let episode = "https://tv.apple.com/us/episode/e/umc.cmc.e1?showId=umc.cmc.t1"
        let extras = [
            #","canPlay":true"#, #","canPlay":true,"episodeURL":"\#(episode)","season":2,"episode":"3","runtime":3000,"resume":750"#,
            #","canPlay":true,"episodeURL":"\#(episode)&action=play""#, #","canPlay":true,"episodeURL":"https://example.com/e""#,
            #","canPlay":true,"episodeURL":"\#(episode)&action=stop&b=1#frag""#, #","canPlay":false,"episodeURL":"\#(episode)""#,
            #","canPlay":true,"episodeURL":"\#(page)?""#, #","canPlay":true,"episodeURL":"\#(page)?flag&a=b%20c""#, #","canPlay":true,"episodeURL":"\#(page)?%61ction=x""#,
            #","runtime":100,"resume":100"#, #","runtime":100,"resume":0"#, #","runtime":100,"resume":99.0"#, #","runtime":-5,"resume":3"#, #","runtime":"100","resume":3"#,
            #","season":0,"episode":1"#, #","season":"7","episode":"08""#, #","season":null,"episode":1"#, #","season":1,"episode":""#,
            #","year":1899"#, #","year":1900"#, #","year":2100"#, #","year":2101"#, #","year":2022.5"#, #","rating":" PG ","desc":"  A synopsis. ""#, #","rating":"","desc":null"#,
            #","tile":\#(tile),"wide":\#(tile)"#, #","tile":{"u":"https://evil.example.com/{w}x{h}.{f}","w":2,"h":1}"#,
            #","tile":{"u":"http://is1-ssl.mzstatic.com/{w}x{h}.{f}","w":2,"h":1}"#, #","tile":{"u":"https://is1-ssl.mzstatic.com/{w}x{h}{z}.{f}","w":2,"h":1}"#,
            #","tile":{"u":"https://is1-ssl.mzstatic.com:8443/a/{w}x{h}.{f}"}"#, #","tile":{"u":"https://IMG.MZSTATIC.COM/a/{w}x{h}.{f}"}"#,
            #","tile":{"u":"https://mzstatic.com.evil.example/a/{w}x{h}.{f}"}"#, #","tile":{"u":"https://evilmzstatic.com/a.jpg"}"#, #","tile":{"u":"https://example.invalid/{w}x{h}.{f}"}"#,
            #","tile":"https://example.invalid/a.jpg""#, #","tile":{"u":5}"#,
        ]
        for extra in extras {
            try assertHomeParity(home([("a", "Row", "lockup", [card("umc.cmc.t1", name: "Name", page: page, extra: extra), card("umc.cmc.m1", kind: "movie", extra: extra)])]))
        }
    }

    // MARK: Search

    private func assertSearchParity(_ read: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try g.expect(decoder.titles(build("search", read)) ?? [], file: file, line: line)
    }

    func testSearchFixtureMatches() throws {
        let read = try fixture("appletv-search-read")
        try assertSearchParity(read)
        XCTAssertEqual(decoder.titles(build("search", read))?.map(\.name), ["Search Show A", "Search Movie B"])
    }

    func testSearchEdgeCasesAndBoundsMatch() throws {
        for read in ["", "nope", "{}", "null", "[]", #"[{"id":"x"},"junk",5,null]"#, "[" + [card("umc.cmc.a1"), card("umc.cmc.a1"), card("bad id"), card("umc.cmc.a2", page: "https://example.com/x")].joined(separator: ",") + "]"] {
            try assertSearchParity(read)
        }
        let many = (1...(StreamLimits.maxSearchResults + 10)).map { card("umc.cmc.s\($0)") }
        try assertSearchParity("[" + many.joined(separator: ",") + "]")
        XCTAssertEqual(decoder.titles(build("search", "[" + many.joined(separator: ",") + "]"))?.count, StreamLimits.maxSearchResults)
    }

    // MARK: Details and episodes

    private func assertDetailsParity(_ name: String, row: StreamTitle, file: StaticString = #filePath, line: UInt = #line) throws {
        let read = try fixture(name)
        let expected = try g.next(file: file, line: line)
        XCTAssertFalse(expected is NSNull, file: file, line: line)
        let got = try XCTUnwrap(decoder.details(build("details", read, extra: ", \(argument(row))")), "package returned no details", file: file, line: line)
        Golden.assertEqual(got, expected, name, file: file, line: line)
    }

    func testEveryDetailsFixtureMatches() throws {
        try assertDetailsParity("appletv-details-show-read", row: row("umc.cmc.synthshow1", kind: .show, name: "Synthetic Series"))
        try assertDetailsParity("appletv-details-movie-read", row: row("umc.cmc.synthrent1", kind: .movie, name: "Rent This One"))
    }

    func testDetailsKeepWhatTheRowAlreadyHad() throws {
        var full = row("umc.cmc.synthshow1", kind: .show, name: "Synthetic Series")
        full.synopsis = "From the row"; full.year = 2020; full.rating = "PG"; full.episodeLabel = "S9 · E9"
        full.runtimeSeconds = 100; full.resumeSeconds = 50
        full.tileArt = URL(string: "https://example.invalid/tile.jpg"); full.heroArt = URL(string: "https://example.invalid/hero.jpg")
        try assertDetailsParity("appletv-details-show-read", row: full)
        var movie = row("umc.cmc.synthrent1", kind: .movie, name: "Rent This One")
        movie.synopsis = full.synopsis; movie.year = full.year; movie.rating = full.rating; movie.runtimeSeconds = 100; movie.resumeSeconds = 50
        movie.tileArt = full.tileArt; movie.heroArt = full.heroArt
        try assertDetailsParity("appletv-details-movie-read", row: movie)
    }

    func testDetailsEdgeCasesMatch() throws {
        let r = row("umc.cmc.x1", kind: .show, name: "X")
        let reads = [
            #"{"id":"umc.cmc.x1","kind":"show","seasons":[{"id":"umc.cmc.s1","name":null}]}"#,
            #"{"id":"umc.cmc.x1","kind":"show","seasons":[{"id":"umc.cmc.s1","name":"One"},{"id":"umc.cmc.s2","name":" "},{"id":"umc.cmc.s1","name":"Dup"},{"id":"bad id","name":"Bad"}],"currentSeasonId":"umc.cmc.s2"}"#,
            #"{"id":"umc.cmc.x1","kind":"show","seasons":[{"id":"umc.cmc.s1","name":"One"},{"id":"umc.cmc.s2","name":"Two"}],"currentSeasonId":"umc.cmc.zz"}"#,
            #"{"id":"umc.cmc.x1","kind":"movie","seasons":[{"id":"umc.cmc.s1","name":"One"}],"runtime":600,"resume":30,"canPlay":true,"page":"https://tv.apple.com/us/movie/x/umc.cmc.x1"}"#,
            #"{"id":"umc.cmc.x1","kind":"show","canPlay":true,"page":"https://example.com/x","episodeURL":"https://tv.apple.com/us/episode/e/umc.cmc.e1","season":1,"episode":2}"#,
            #"{"id":"umc.cmc.x1","kind":"show","canPlay":true,"page":null,"episodeURL":null}"#,
            #"{"id":"umc.cmc.x1","kind":"show","desc":"  ","rating":null,"year":3000,"wide":{"u":"https://evil.example.com/{w}.jpg"},"tile":{"u":"https://example.invalid/{w}x{h}.{f}"}}"#,
        ]
        for read in reads {
            try g.expect(decoder.details(build("details", read, extra: ", \(try argument(r))")), read)
        }
        for read in ["", "[]", "nope", "null", #"{"id":"umc.cmc.other","kind":"show"}"#] {
            XCTAssertTrue(try g.nextIsNil())
            XCTAssertNil(decoder.details(build("details", read, extra: ", \(try argument(r))")), read)
        }
    }

    func testSeasonFixtureMatches() throws {
        let read = try fixture("appletv-season-read")
        let expected = try g.next()
        Golden.assertEqual(decoder.episodes(build("season", read)), expected)
        XCTAssertEqual((expected as? [[String: Any]])?.map { $0["number"] as? Int }, [1, 2, 3, 5])
    }

    func testSeasonEdgeCasesAndBoundsMatch() throws {
        let page = "https://tv.apple.com/us/episode/e/umc.cmc.e"
        func episode(_ n: Int, extra: String = "") -> String { #"{"id":"umc.cmc.e\#(n)","name":"E\#(n)","number":\#(n),"url":"\#(page)\#(n)"\#(extra)}"# }
        let reads = [
            "{\"episodes\":[\(episode(1)),\(episode(1)),{\"id\":\"bad id\",\"url\":\"\(page)1\"},{\"id\":\"umc.cmc.e9\",\"url\":\"https://example.com/x\"},{\"id\":\"umc.cmc.e8\"}]}",
            "{\"episodes\":[{\"id\":\"umc.cmc.e1\",\"name\":null,\"number\":1,\"url\":\"\(page)1\"},{\"id\":\"umc.cmc.e2\",\"name\":\" \",\"url\":\"\(page)2\"},{\"id\":\"umc.cmc.e3\",\"number\":null,\"url\":\"\(page)3\"}]}",
            "{\"episodes\":[\(episode(1, extra: #","canPlay":true,"runtime":2000,"resume":500,"desc":"Text","art":{"u":"https://example.invalid/{w}x{h}.{f}"}"#))]}",
            "{\"episodes\":[\(episode(1, extra: #","canPlay":true,"runtime":2000,"resume":2000"#))]}",
            "", "nope", "[]", "{}", "null", #"{"episodes":"x"}"#,
        ]
        for read in reads { try g.expect(decoder.episodes(build("season", read)) ?? [], read) }
        let many = (1...(StreamLimits.maxEpisodesPerSeason + 20)).map { episode($0) }
        let big = "{\"episodes\":[\(many.joined(separator: ","))]}"
        try g.expect(decoder.episodes(build("season", big)))
        XCTAssertEqual(decoder.episodes(build("season", big))?.count, StreamLimits.maxEpisodesPerSeason)
    }

    // MARK: Play address and ids

    func testPlayAddressRuleMatchesSwift() throws {
        for address in ["https://tv.apple.com/us/movie/x/umc.cmc.m1", "https://tv.apple.com/us/movie/x/umc.cmc.m1?action=play", "https://tv.apple.com/us/episode/e/umc.cmc.e1?showId=umc.cmc.s1",
                        "https://tv.apple.com/us/episode/e/umc.cmc.e1?action=stop&showId=umc.cmc.s1&action=play", "https://tv.apple.com/us/show/x/umc.cmc.s1#top", "https://TV.APPLE.COM/us/show/x/umc.cmc.s1?a=1"] {
            let json = home([("a", "Row", "lockup", [card("umc.cmc.t1", page: address, extra: #","canPlay":true"#)])])
            try g.expect(decoder.home(build("home", json), serviceID: "appletv")?.home.rows.first?.titles.first?.play, address)
        }
    }

    func testDotsAndLongRowIdsSurviveTheDecoder() throws {
        let got = try XCTUnwrap(decoder.home(build("home", try fixture("appletv-home-read")), serviceID: "appletv")).home
        XCTAssertEqual(got.rows[0].id, "appletv-row-uts.col.UpNext")
        XCTAssertEqual(got.rows[0].titles[0].id, "umc.cmc.synthshow1")
    }

    // MARK: The page-reading half, against a stand-in page and API

    /// Installs a stand-in tv.apple.com page: MusicKit with tokens, a cookie-less document, and a fetch that
    /// answers each path from `answers` and records every request (path and headers' presence only).
    private func standIn(answers: [String: String], tokens: Bool = true) {
        context.setObject(answers, forKeyedSubscript: "__answers" as NSString)
        context.evaluateScript("""
        var URLSearchParams = class { constructor(init) { this.m = {}; if (typeof init === 'string') init.split('&').forEach(p => { const i = p.indexOf('='); if (i > 0) this.m[decodeURIComponent(p.slice(0, i))] = decodeURIComponent(p.slice(i + 1)); }); else Object.keys(init || {}).forEach(k => { this.m[k] = String(init[k]); }); }
          set(k, v) { this.m[k] = String(v); } get(k) { return k in this.m ? this.m[k] : null; }
          toString() { return Object.keys(this.m).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(this.m[k])).join('&'); } };
        var location = { hostname: 'tv.apple.com', search: '' };
        var document = { cookie: '', querySelector: s => s === 'dialog.playback-view' ? (globalThis.__dialog || null) : null };
        var MusicKit = { getInstance: () => ({ developerToken: \(tokens ? "'dev-token'" : "''"), musicUserToken: \(tokens ? "'user-token'" : "''") }) };
        var __requests = [];
        var fetch = async (url, options) => {
          const path = url.split('?')[0].replace('/api/uts/v3/', '');
          const query = new URLSearchParams(url.split('?')[1]);
          __requests.push(path + '|' + (query.get('selectedSeasonId') || query.get('selectedEpisodeId') || query.get('searchTerm') || ''));
          const answer = __answers[path + '|' + (query.get('selectedEpisodeId') || '')] || __answers[path];
          if (!options.headers.authorization || !options.headers['media-user-token']) return { ok: false, status: 401 };
          return answer ? { ok: true, json: async () => JSON.parse(answer) } : { ok: false, status: 404 };
        };
        """)
    }

    private func answer(_ call: String) -> String {
        context.evaluateScript("var __out = 'pending'; (\(call)).then(v => { __out = v; }).catch(e => { __out = 'THROW'; });")
        return context.evaluateScript("__out")?.toString() ?? "undefined"
    }

    private func requests() -> [String] {
        (context.evaluateScript("__requests")?.toArray() as? [String]) ?? []
    }

    private let shelfItem = #"{"type":"Show","id":"umc.cmc.s1","title":"Show One","url":"https://tv.apple.com/us/show/one/umc.cmc.s1","releaseDate":1640995200000,"rating":{"displayName":"TV-MA"},"description":"About.","images":{"shelfItemImage":{"url":"https://example.invalid/{w}x{h}.{f}","width":1600,"height":900}},"playable":{"isEntitledToPlay":true,"channelId":"tvs.sbd.4000","playEvent":{"isDone":false,"contentPlayCursorInSeconds":60,"contentMediaLengthInSeconds":600}}}"#

    func testReadyNeedsBothTokens() {
        standIn(answers: [:])
        XCTAssertEqual(context.evaluateScript("reader.ready()")?.toString(), "true")
        standIn(answers: [:], tokens: false)
        XCTAssertEqual(context.evaluateScript("reader.homeReady()")?.toString(), "false")
        standIn(answers: [:])
        context.evaluateScript("location.hostname = 'example.com'")
        XCTAssertEqual(context.evaluateScript("reader.searchReady()")?.toString(), "false")
        standIn(answers: [:])
        context.evaluateScript("location.search = '?showId=a&action=play'")
        XCTAssertEqual(context.evaluateScript("reader.ready()")?.toString(), "false", "a page with the player dialog open is not one to read from")
        context.evaluateScript("location.search = '?showId=a'")
        XCTAssertEqual(context.evaluateScript("reader.ready()")?.toString(), "true")
    }

    func testHomeIsOneRequestAndNoTokenIsReturned() throws {
        let canvas = #"{"data":{"canvas":{"shelves":[{"id":"uts.col.UpNext","displayType":"upNextLockup","header":{"title":"Continue Watching"},"items":[\#(shelfItem),{"type":"Person","id":"p"}]}]}}}"#
        standIn(answers: ["canvases/channels/tvs.sbd.4000": canvas])
        let json = answer("reader.home()")
        XCTAssertEqual(requests(), ["canvases/channels/tvs.sbd.4000|"])
        XCTAssertFalse(json.contains("token"))
        let home = try XCTUnwrap(decoder.home(json, serviceID: "appletv")).home
        XCTAssertEqual(home.rows.first?.kind, .continueWatching)
        XCTAssertEqual(home.rows.first?.titles.first?.play.absoluteString, "https://tv.apple.com/us/show/one/umc.cmc.s1?action=play")
        XCTAssertEqual(home.rows.first?.titles.first?.resumeSeconds, 60)
        XCTAssertEqual(home.rows.first?.titles.first?.year, 2022)
    }

    func testNoSessionOrNoAnswerIsNoAnswer() {
        standIn(answers: [:], tokens: false)
        XCTAssertEqual(answer("reader.home()"), "")
        XCTAssertTrue(requests().isEmpty)
        standIn(answers: [:])
        XCTAssertEqual(answer("reader.home()"), "")
        XCTAssertEqual(answer("reader.search({query: ''})"), "")
        XCTAssertEqual(answer("reader.details({title: {id: 'bad id', kind: 'show'}})"), "")
        XCTAssertEqual(answer("reader.season({seasonID: 'umc.cmc.s1', title: {}})"), "")
    }

    func testSearchAsksTheSearchRequestWithTheQuery() throws {
        let canvas = #"{"data":{"canvas":{"shelves":[{"items":[\#(shelfItem)]},{"items":[\#(shelfItem)]}]}}}"#
        standIn(answers: ["search": canvas])
        let titles = try XCTUnwrap(decoder.titles(answer(#"reader.search({query: "show one"})"#)))
        XCTAssertEqual(requests(), ["search|show one"])
        XCTAssertEqual(titles.map(\.name), ["Show One"])
    }

    func testDetailsAndAShortSeasonAreReadFromTheTitlesRequests() throws {
        let show = #"{"data":{"content":{"title":"Show One","description":"Long.","url":"https://tv.apple.com/us/show/one/umc.cmc.s1"},"smartEpisode":{"url":"https://tv.apple.com/us/episode/e/umc.cmc.e1","seasonNumber":1,"episodeNumber":2,"seasonId":"umc.cmc.se1"},"playables":{"a":{"isEntitledToPlay":true,"channelId":"tvs.sbd.4000"}},"seasons":{"b":{"id":"umc.cmc.se2","seasonNumber":2},"a":{"id":"umc.cmc.se1","seasonNumber":1}}}}"#
        let episodes = #"{"data":{"totalEpisodeCount":2,"episodes":[{"id":"umc.cmc.e1","seasonId":"umc.cmc.se1","episodeIndex":0,"episodeNumber":1,"title":"Pilot","url":"https://tv.apple.com/us/episode/p/umc.cmc.e1"},{"id":"umc.cmc.e2","seasonId":"umc.cmc.se1","episodeIndex":1,"episodeNumber":2,"url":"https://tv.apple.com/us/episode/q/umc.cmc.e2"}]}}"#
        standIn(answers: ["shows/umc.cmc.s1": show, "shows/umc.cmc.s1/episodes": episodes])
        let r = row("umc.cmc.s1", kind: .show, name: "Show One")
        let details = try XCTUnwrap(decoder.details(answer("reader.details({title: \(try argument(r))})")))
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(details.currentSeasonID, "umc.cmc.se1")
        XCTAssertEqual(details.title.episodeLabel, "S1 · E2")
        XCTAssertEqual(details.title.play.absoluteString, "https://tv.apple.com/us/episode/e/umc.cmc.e1?action=play")
        let list = try XCTUnwrap(decoder.episodes(answer("reader.season({seasonID: 'umc.cmc.se1', title: \(try argument(r))})")))
        XCTAssertEqual(list.map(\.name), ["Pilot", "Episode 2"])
        XCTAssertEqual(requests(), ["shows/umc.cmc.s1|", "shows/umc.cmc.s1/episodes|umc.cmc.se1"], "one request per action when the season fits one window")
    }

    func testASeasonMakesAtMostSixRequests() {
        func window(_ from: Int) -> String {
            let list = (from..<(from + 10)).map { #"{"id":"umc.cmc.e\#($0)","seasonId":"umc.cmc.se1","episodeIndex":\#($0),"episodeNumber":\#($0 + 1),"url":"https://tv.apple.com/us/episode/p/umc.cmc.e\#($0)"}"# }
            return #"{"data":{"totalEpisodeCount":500,"episodes":[\#(list.joined(separator: ","))]}}"#
        }
        var answers = ["shows/umc.cmc.s1/episodes": window(0)]
        for n in 1..<10 { answers["shows/umc.cmc.s1/episodes|umc.cmc.e\(n * 10 - 1)"] = window(n * 10) }
        standIn(answers: answers)
        let r = row("umc.cmc.s1", kind: .show, name: "Show One")
        let list = decoder.episodes(answer("reader.season({seasonID: 'umc.cmc.se1', title: \((try? argument(r)) ?? "{}")})"))
        XCTAssertEqual(requests().count, 6, "the reader's window budget")
        XCTAssertEqual(list?.count, 60)
    }

    func testProfileIsTheOneProfile() {
        XCTAssertEqual(context.evaluateScript("reader.chooseProfile({profileID: 'main'})")?.toString(), "true")
        XCTAssertEqual(context.evaluateScript("reader.profileIsCurrent({profileID: 'main'})")?.toString(), "true")
        XCTAssertEqual(context.evaluateScript("reader.chooseProfile({profileID: 'other'})")?.toString(), "false")
        XCTAssertEqual(context.evaluateScript("reader.profileIsCurrent({profileID: 'other'})")?.toString(), "false")
    }

    func testPlayerShownIsTheOpenPlaybackDialog() {
        standIn(answers: [:])
        XCTAssertEqual(context.evaluateScript("reader.playerShown()")?.toString(), "false")
        context.evaluateScript("globalThis.__dialog = { open: false }")
        XCTAssertEqual(context.evaluateScript("reader.playerShown()")?.toString(), "false")
        context.evaluateScript("globalThis.__dialog = { open: true }")
        XCTAssertEqual(context.evaluateScript("reader.playerShown()")?.toString(), "true")
    }
}
