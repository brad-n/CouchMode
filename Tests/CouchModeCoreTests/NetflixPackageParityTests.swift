import XCTest
import JavaScriptCore
@testable import CouchModeCore

/// The Netflix package (apps/netflix) against the built-in Swift reader: for every Netflix fixture (the browse
/// GraphQL cache, the details read, the search cards, the gate's tiles) the package's output, decoded the way the app
/// decodes it, must equal what the Swift parser produces. The JS runs in JavaScriptCore; its page-reading half runs
/// against a small stand-in page. Netflix 5.1 is not part of the reader and not covered here.
final class NetflixPackageParityTests: XCTestCase {
    private var context: JSContext!
    private var decoder: PackageDecoder!
    private var manifest: PackageManifest!
    private var g: Golden!

    override func setUpWithError() throws {
        g = Golden("netflix", function: name)
        manifest = try PackageManifest.parse(Data(contentsOf: Self.appDirectory.appendingPathComponent("manifest.json")))
        decoder = PackageDecoder(manifest: manifest)
        context = try Self.makeContext()
    }

    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/netflix")
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

    private func call(_ script: String) -> String { context.evaluateScript(script)?.toString() ?? "" }

    private let show = StreamTitle(id: "70000959", name: "A Show", kind: .show, play: URL(string: "https://www.netflix.com/watch/1")!,
                                   page: URL(string: "https://www.netflix.com/title/70000959"), tileArt: URL(string: "https://art.invalid/tile"))

    private func argument(_ title: StreamTitle) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: title)), as: UTF8.self)
    }

    // MARK: Home (the GraphQL cache)

    private func assertHomeParity(_ cache: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try g.next(file: file, line: line)
        let js = build("home", cache)
        let object = expected as? [String: Any]
        let empty = (object?["rows"] as? [Any])?.isEmpty == true && object?["hero"] is NSNull
        guard object != nil, !empty else { XCTAssertNil(decoder.home(js, serviceID: "netflix"), cache, file: file, line: line); return }
        let got = try XCTUnwrap(decoder.home(js, serviceID: "netflix"), "package returned no home", file: file, line: line)
        Golden.assertEqual(got.home, expected, file: file, line: line)
        XCTAssertTrue(got.cursors.isEmpty, "Netflix pages nothing", file: file, line: line)
    }

    func testBrowseFixtureDecodesToWhatTheSwiftParserMakes() throws {
        let cache = try fixture("netflix-browse-graphql")
        try assertHomeParity(cache)
        let got = try XCTUnwrap(decoder.home(build("home", cache), serviceID: "netflix")).home
        XCTAssertFalse(got.rows.isEmpty)
        XCTAssertNotNil(got.hero)
        XCTAssertFalse(got.profiles.isEmpty)
        XCTAssertNotNil(got.currentProfileID)
        XCTAssertTrue(got.rows.contains { $0.kind == .continueWatching })
        XCTAssertTrue(got.rows.contains { $0.totalCount != nil })
        XCTAssertTrue(got.rows.flatMap(\.titles).contains { $0.kind == .show && $0.play != $0.page })
        XCTAssertTrue(got.rows.flatMap(\.titles).contains { $0.resumeSeconds != nil })
        XCTAssertLessThan(build("home", cache).count, 900_000)
    }

    func testHomeEdgeCasesMatch() throws {
        func cache(_ extra: String = "") throws -> [String: Any] {
            var object = try XCTUnwrap(StreamJSON.object(try fixture("netflix-browse-graphql")))
            if !extra.isEmpty, let patch = StreamJSON.object(extra) { for (k, v) in patch { object[k] = v } }
            return object
        }
        func text(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        for json in ["", "[]", "{}", #"{"ROOT_QUERY":{}}"#, #"{"ROOT_QUERY":{"pinotBrowsePage({})":{"__ref":"nope"}}}"#,
                     #"{"ROOT_QUERY":{"pinotBrowsePage({})":{"__ref":"P"}},"P":{}}"#] {
            try assertHomeParity(json)
        }
        // No current profile, no profiles, no hero: each part of the cache is optional.
        var noRoot = try cache()
        var root = try XCTUnwrap(noRoot["ROOT_QUERY"] as? [String: Any])
        root["currentProfile"] = nil
        noRoot["ROOT_QUERY"] = root
        try assertHomeParity(try text(noRoot))
        var noProfiles = try cache()
        for key in noProfiles.keys where key.hasPrefix("Profile:") { noProfiles[key] = nil }
        try assertHomeParity(try text(noProfiles))
        var noSections = try cache()
        for key in noSections.keys where key.hasPrefix("PinotCarouselSection:") { noSections[key] = nil }
        try assertHomeParity(try text(noSections))
        var noTreatments = try cache()
        for key in noTreatments.keys where key.hasSuffix("Treatment:") || key.contains("EntityTreatment") { noTreatments[key] = nil }
        try assertHomeParity(try text(noTreatments))
    }

    func testHomeIsBoundedTheSameWay() throws {
        var cache: [String: Any] = [:]
        var edges: [[String: Any]] = []
        for s in 0..<30 {
            var nodes: [[String: Any]] = []
            for t in 0..<60 {
                let id = 80_000_000 + s * 100 + t
                cache["Movie:\(id)"] = ["videoId": id, "title": "T\(s)-\(t)"]
                cache["PinotStandardEntityTreatment:\(id)"] = ["unifiedEntity": ["__ref": "Movie:\(id)"], "displayString": "T\(s)-\(t)"]
                nodes.append(["node": ["__ref": "PinotStandardEntityTreatment:\(id)"]])
            }
            cache["PinotCarouselSection:\(s)"] = ["displayString": "Row \(s)", "entities": ["edges": nodes, "totalCount": 60]]
            edges.append(["node": ["__ref": "PinotCarouselSection:\(s)"]])
        }
        cache["PinotBrowsePage:1"] = ["sections({})": ["edges": edges]]
        cache["ROOT_QUERY"] = ["pinotBrowsePage({})": ["__ref": "PinotBrowsePage:1"]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: cache), as: UTF8.self)
        try assertHomeParity(text)
        let home = try XCTUnwrap(decoder.home(build("home", text), serviceID: "netflix")).home
        XCTAssertEqual(home.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(home.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    // MARK: The gate

    func testGateFixtureMatches() throws {
        let read = try fixture("netflix-gate-read")
        let expected = try g.next()
        XCTAssertFalse(expected is NSNull)
        let got = try XCTUnwrap(decoder.home(build("gate", read), serviceID: "netflix")).home
        Golden.assertEqual(got, expected)
        XCTAssertTrue(got.asksWhoIsWatching)
        XCTAssertEqual(got.profiles.map(\.name), ["Profile 1", "Profile 2", "Profile 3", "Profile 5"])
    }

    func testGateEdgeCasesMatch() throws {
        let many = (1...30).map { #"{"id":"SYNTH\#($0)","name":"Profile \#($0)"}"# }.joined(separator: ",")
        for read in ["", "{}", #"{"gate":[]}"#, #"{"ROOT_QUERY":{}}"#, #"{"gate":[{"id":"bad id!","name":"Profile 1"}]}"#, #"{"gate":[{"id":"a","name":"  "}]}"#,
                     #"{"gate":[{"id":"locked-2","name":"Locked","locked":true,"avatar":"https://art.invalid/a.png"}]}"#, #"{"gate":[\#(many)]}"#] {
            let got = decoder.home(build("gate", read), serviceID: "netflix")?.home
            try g.expect(got, read)
        }
    }

    // MARK: Search

    func testSearchFixtureMatches() throws {
        let read = try fixture("netflix-search-read")
        let expected = try g.next()
        let got = try XCTUnwrap(decoder.titles(build("search", read)))
        Golden.assertEqual(got, expected)
        XCTAssertEqual(got.map(\.id), ["70000548", "70000137", "70000222", "70000333"])
        XCTAssertNil(got[2].tileArt, "plain-http art is dropped")
        let cards = (1...(StreamLimits.maxSearchResults + 10)).map { #"{"id":"\#($0)","name":"T\#($0)"}"# }
        let big = "[" + cards.joined(separator: ",") + "]"
        try g.expect(decoder.titles(build("search", big)))
        XCTAssertEqual(decoder.titles(build("search", "[]")), [])
    }

    // MARK: Details and episodes

    private func assertDetailsParity(_ read: String, row: StreamTitle, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try g.next(file: file, line: line)
        XCTAssertFalse(expected is NSNull, file: file, line: line)
        let got = try XCTUnwrap(decoder.details(build("details", read, extra: ", \(try argument(row))")), "package returned no details", file: file, line: line)
        Golden.assertEqual(got, expected, read, file: file, line: line)
    }

    func testDetailsFixtureMatches() throws {
        let read = try fixture("netflix-details-read")
        try assertDetailsParity(read, row: show)
        var movie = show
        movie = StreamTitle(id: movie.id, name: movie.name, kind: .movie, play: movie.play, page: movie.page)
        try assertDetailsParity(read, row: movie)
        let details = try XCTUnwrap(decoder.details(build("details", read, extra: ", \(try argument(show))")))
        XCTAssertEqual(details.seasons.map(\.name), ["S1: Alpha", "S2: Bravo", "S3: Charlie"])
        XCTAssertEqual(details.currentSeasonID, "70001096")
        XCTAssertEqual(details.seasons.first?.episodes.count, 3)
        try g.expect(decoder.episodes(build("episodes", read)))
    }

    func testDetailsEdgeCasesMatch() throws {
        for read in [#"{"synopsis":"A movie.","currentSeasonId":null,"seasonLabel":null,"seasons":[],"episodes":[]}"#,
                     #"{"synopsis":null,"currentSeasonId":42,"seasonLabel":"Limited Series","seasons":[],"episodes":[{"id":7,"number":1,"name":"Part One","runtime":3000}]}"#,
                     #"{"synopsis":"  ","currentSeasonId":"42","seasonLabel":"  ","seasons":[],"episodes":[{"id":"7","number":3}]}"#,
                     #"{"currentSeasonId":2,"seasons":[{"id":1,"name":"One"},{"videoId":2,"name":" Two "},{"id":2,"name":"Dup"},{"id":3},{"id":"x","name":"Bad"}],"episodes":[{"id":9,"number":4},{"id":10,"name":"Ten","art":"http://art.invalid/x.jpg"},{"id":10,"name":"Again"},{"id":null,"name":"No id"},{"id":"12a","name":"Bad id"}]}"#,
                     #"{"currentSeasonId":99,"seasons":[{"id":1,"name":"One"},{"id":2,"name":"Two"}],"episodes":[{"id":5,"name":"Five"}]}"#,
                     #"{"seasons":[{"id":1,"name":"Only"}],"episodes":[]}"#, "{}"] {
            for kind in [StreamTitle.Kind.show, .movie, .other] {
                let row = StreamTitle(id: "70000959", name: "A Show", kind: kind, play: URL(string: "https://www.netflix.com/watch/1")!, page: URL(string: "https://www.netflix.com/title/70000959"))
                try g.expect(decoder.details(build("details", read, extra: ", \(try argument(row))")), read)
            }
            try g.expect(decoder.episodes(build("episodes", read)) ?? [], read)
        }
        for read in ["", "[]", "nope", "null"] {
            XCTAssertNil(decoder.details(build("details", read, extra: ", {}")))
            XCTAssertTrue(try g.nextIsNil())
        }
        let many = (0..<130).map { #"{"id":\#(1000 + $0),"name":"E\#($0)"}"# }.joined(separator: ",")
        let big = #"{"currentSeasonId":1,"seasons":[{"id":1,"name":"One"}],"episodes":[\#(many)]}"#
        try assertDetailsParity(big, row: show)
        try g.expect(decoder.episodes(build("episodes", big)))
    }

    // MARK: Pages

    func testTheManifestDescribesTheSwiftReadersPages() throws {
        XCTAssertEqual(manifest.url(for: .home)?.absoluteString, "https://www.netflix.com/browse")
        XCTAssertEqual(manifest.url(for: .profile)?.absoluteString, "https://www.netflix.com/browse")
        XCTAssertEqual(manifest.url(for: .details, .init(titlePage: show.page))?.absoluteString, "https://www.netflix.com/title/70000959")
        for query in ["stranger things", "  a   b ", "x&y=z", "café"] {
            try g.expect(manifest.url(for: .search, .init(query: query))?.absoluteString, query)
        }
        XCTAssertNil(manifest.pages[.more], "Netflix pages with a persisted query that is not available to us")
        XCTAssertFalse(manifest.definesPlayerShown)
        XCTAssertTrue(manifest.hostAllowed("www.netflix.com"))
        XCTAssertFalse(manifest.hostAllowed("evil.invalid"))
        XCTAssertFalse(manifest.isReusableSitePage(URL(string: "https://www.netflix.com/watch/70000959")))
        XCTAssertTrue(manifest.isReusableSitePage(URL(string: "https://www.netflix.com/browse")))
        for name in ["homeReady", "detailsReady", "searchReady", "profileIsCurrent", "chooseProfile", "home", "details", "season", "search"] {
            XCTAssertEqual(call("typeof reader.\(name)"), "function", name)
        }
        XCTAssertEqual(call("typeof reader.more"), "undefined")
        XCTAssertEqual(call("typeof reader.restoreProfile"), "undefined", "the gate is the home, not a restore")
    }

    // MARK: Reading a stand-in page

    /// A page with just enough of window / document / location for the script's page-reading half.
    private func setPage(path: String = "/browse", cache: String? = nil, tiles: [(token: String, name: String, locked: Bool)] = [], gate: Bool = false,
                         cards: [(id: String, name: String)] = []) {
        let tileJS = tiles.map { t in
            "{ href: 'https://www.netflix.com/SwitchProfile?tkn=\(t.token)', getAttribute(n) { return n === 'href' ? this.href : (n === 'aria-label' ? '' : null); }, textContent: '\(t.name)', locked: \(t.locked), " +
            "querySelector(s) { if (s === '.profile-name') return { textContent: '\(t.name)' }; if (s.indexOf('lock') >= 0) return this.locked ? {} : null; return null; }, closest() { return null; } }"
        }.joined(separator: ",")
        let cardJS = cards.map { c in
            "{ getAttribute(n) { return n === 'href' ? '/watch/1?jbv=\(c.id)' : (n === 'aria-label' ? '\(c.name)' : null); }, querySelector() { return { getAttribute: () => 'https://art.invalid/\(c.id).jpg' }; } }"
        }.joined(separator: ",")
        context.setObject(cache ?? "", forKeyedSubscript: "__cache" as NSString)
        context.evaluateScript("""
        var __nav = [], __clicks = [];
        var location = { pathname: '\(path)', origin: 'https://www.netflix.com', href: 'https://www.netflix.com\(path)', assign(u) { __nav.push(u); } };
        var URL = function (u) { const m = /^https:\\/\\/[^\\/]+(\\/[^?]*)/.exec(u); this.href = u; this.origin = 'https://www.netflix.com'; this.pathname = m[1]; };
        var getComputedStyle = () => ({ backgroundImage: 'url("https://art.invalid/avatar.png")' });
        var window = { netflix: \(cache == nil ? "{}" : "{ reactContext: { models: { graphql: { data: JSON.parse(__cache) } } } }") };
        var __tiles = [\(tileJS)], __cards = [\(cardJS)];
        __tiles.forEach(t => { t.click = () => __clicks.push(t.textContent); });
        var document = { querySelector(s) { return \(gate ? "s.indexOf('profile-gate-label') >= 0 ? {} : null" : "null"); },
          querySelectorAll(s) { if (s.indexOf('profile-link') >= 0) return __tiles; if (s.indexOf('standard-card') >= 0) return __cards; return []; } };
        """)
    }

    func testTheHomeReadsThePagesOwnCacheAndTheGateIsTheHomeWhenShown() async throws {
        let cache = try fixture("netflix-browse-graphql")
        setPage(cache: cache)
        XCTAssertEqual(call("reader.homeReady()"), "true")
        context.evaluateScript("var __answer = 'pending'; reader.home({}).then(v => { __answer = v; });")
        let answer = call("__answer")
        XCTAssertNotEqual(answer, "pending")
        try g.expect(decoder.home(answer, serviceID: "netflix")?.home)

        // The gate: its tiles are the home (profiles, no rows); nothing is pressed by reading.
        setPage(path: "/ProfilesGate", tiles: [("SYNTHPROFILE0001", "Profile 1", false), ("SYNTHPROFILE0002", "Profile 2", true)], gate: true)
        XCTAssertEqual(call("reader.homeReady()"), "true")
        context.evaluateScript("var __answer = 'pending'; reader.home({}).then(v => { __answer = v; });")
        let gate = try XCTUnwrap(decoder.home(call("__answer"), serviceID: "netflix")).home
        XCTAssertTrue(gate.asksWhoIsWatching)
        XCTAssertEqual(gate.profiles.map(\.name), ["Profile 1", "Profile 2"])
        XCTAssertEqual(gate.profiles.map(\.isLocked), [false, true])
        XCTAssertEqual(call("__clicks.length + __nav.length"), "0")

        setPage(path: "/browse")
        XCTAssertEqual(call("reader.homeReady()"), "false")
    }

    func testSearchReadsTheResultCards() throws {
        setPage(path: "/search", cards: [("70000548", "Sample Search"), ("70000137", "Other")])
        XCTAssertEqual(call("reader.searchReady()"), "true")
        context.evaluateScript("var __answer = 'pending'; reader.search({query: 'x'}).then(v => { __answer = v; });")
        XCTAssertEqual(decoder.titles(call("__answer"))?.map(\.id), ["70000548", "70000137"])
        setPage(path: "/search")
        XCTAssertEqual(call("reader.searchReady()"), "false")
    }

    func testChoosingAProfileFollowsTheTilesOwnLinkOrNetflixsSwitchAddressAndNeverTypes() {
        func choose(_ id: String) -> String {
            context.evaluateScript("var __answer = 'pending'; reader.chooseProfile({profileID: '\(id)'}).then(v => { __answer = v; });")
            return call("__answer")
        }
        setPage(path: "/ProfilesGate", tiles: [("SYNTHPROFILE0001", "Profile 1", false), ("SYNTHPROFILE0002", "Profile 2", true)], gate: true)
        XCTAssertEqual(choose("SYNTHPROFILE0001"), "true")
        XCTAssertEqual(call("__nav.join()"), "https://www.netflix.com/SwitchProfile?tkn=SYNTHPROFILE0001", "the tile's own link")
        // A locked tile is never pressed; Netflix's own switch address is what the Swift reader falls back to.
        setPage(path: "/ProfilesGate", tiles: [("SYNTHPROFILE0001", "Profile 1", false), ("SYNTHPROFILE0002", "Profile 2", true)], gate: true)
        XCTAssertEqual(choose("SYNTHPROFILE0002"), "true")
        XCTAssertEqual(call("__nav.join() + __clicks.length"), "https://www.netflix.com/SwitchProfile?tkn=SYNTHPROFILE00020")
        // Off the gate it is the switch address, with the same checks on the id as the Swift one.
        setPage(path: "/browse")
        XCTAssertEqual(choose("abc123"), "true")
        XCTAssertEqual(call("__nav.join()"), "https://www.netflix.com/SwitchProfile?tkn=abc123")
        setPage(path: "/browse")
        XCTAssertEqual(choose("bad id!"), "false")
        XCTAssertEqual(choose("has-dash"), "false", "the Swift switch address takes letters and digits only")
        XCTAssertEqual(call("__nav.length"), "0")
        XCTAssertEqual(call("reader.profileIsCurrent({profileID: 'abc123'})"), "false")
    }

    // MARK: The gate's current markup (a button per profile, no link)

    private static let synthTiles: [(token: String, name: String, locked: Bool)] =
        [("SYNTHPROFILE0000000000000001", "Profile 1", false), ("SYNTHPROFILE0000000000000002", "Profile 2", true), ("SYNTHPROFILE0000000000000003", "Profile 3", false)]

    /// A page showing the current gate: `button[data-uia="profile-selector+tile-<id>"]` with the name and avatar in the
    /// tile's React props, an <img> inside, and no href. `onGate` false is a title page with none of it.
    private func setButtonGate(path: String = "/title/70000959", onGate: Bool = true) {
        let tileJS = Self.synthTiles.map { t in
            "{ uia: 'profile-selector+tile-\(t.token)', textContent: '\(t.name)', __reactFiber$x: { memoizedProps: { type: 'button' }, return: { memoizedProps: { name: '\(t.name)', avatarUrl: 'https://art.invalid/\(t.token).png', isLocked: \(t.locked) }, return: null } }, " +
            "getAttribute(n) { return n === 'data-uia' ? this.uia : null; }, querySelector(s) { return s === 'img' ? { getAttribute: () => 'https://art.invalid/img.png' } : null; }, closest() { return null; } }"
        }.joined(separator: ",")
        context.evaluateScript("""
        var __nav = [], __clicks = [];
        var location = { pathname: '\(path)', origin: 'https://www.netflix.com', href: 'https://www.netflix.com\(path)', assign(u) { __nav.push(u); } };
        var URL = function (u) { const m = /^https:\\/\\/[^\\/]+(\\/[^?]*)/.exec(u); this.href = u; this.origin = 'https://www.netflix.com'; this.pathname = m[1]; };
        var getComputedStyle = () => ({ backgroundImage: '' });
        var window = { netflix: {} };
        var __tiles = \(onGate ? "[\(tileJS)]" : "[]"); __tiles.forEach(t => { t.click = () => __clicks.push(t.textContent); });
        var document = { querySelector(s) { return \(onGate ? "s.indexOf('profile-gate-screen') >= 0 ? {} : null" : "null"); },
          querySelectorAll(s) { return s.indexOf('profile-selector+tile') >= 0 ? __tiles : []; } };
        """)
    }

    private func readerAnswer(_ call: String) -> String {
        context.evaluateScript("var __answer = 'pending'; \(call).then(v => { __answer = v; });")
        return self.call("__answer")
    }

    func testTheCurrentGateMarkupIsReadWithNamesAvatarsLockAndIDs() throws {
        setButtonGate()
        XCTAssertEqual(call("reader.homeReady()"), "true")
        let home = try XCTUnwrap(decoder.home(readerAnswer("reader.home({})"), serviceID: "netflix")).home
        XCTAssertTrue(home.asksWhoIsWatching)
        XCTAssertEqual(home.profiles.map(\.name), ["Profile 1", "Profile 2", "Profile 3"])
        XCTAssertEqual(home.profiles.map(\.isLocked), [false, true, false])
        XCTAssertEqual(home.profiles.map(\.id), Self.synthTiles.map(\.token), "the id is the tile's data-uia suffix")
        XCTAssertEqual(home.profiles[0].avatar?.absoluteString, "https://art.invalid/SYNTHPROFILE0000000000000001.png")
        XCTAssertEqual(call("__nav.length + __clicks.length"), "0", "reading presses nothing")
    }

    func testSwiftAndPackageGateParseTheSameCurrentMarkup() throws {
        setButtonGate()
        let swift = try g.next()
        let package = try XCTUnwrap(decoder.home(readerAnswer("reader.home({})"), serviceID: "netflix")).home
        Golden.assertEqual(package, swift)
        XCTAssertEqual(package.profiles.map(\.isLocked), [false, true, false])
        // Same on a title page that is not the gate: neither reads a gate.
        setButtonGate(onGate: false)
        try g.expect(call("JSON.stringify(reader.extract.gate())"))
    }

    func testEveryReadReportsTheGate() throws {
        setButtonGate(path: "/title/70000959")
        XCTAssertEqual(call("reader.detailsReady()"), "true", "the gate ends the wait for a details panel")
        XCTAssertEqual(call("reader.searchReady()"), "true", "and for search results")
        let title = #"{title: {id: '70000959', kind: 'show'}}"#
        for read in ["reader.details(\(title))", "reader.season({seasonID: '70000960', title: {id: '70000959', kind: 'show'}})", "reader.search({query: 'x'})"] {
            let home = try XCTUnwrap(decoder.home(readerAnswer(read), serviceID: "netflix"), read).home
            XCTAssertTrue(home.asksWhoIsWatching, read)
            XCTAssertEqual(home.profiles.count, 3, read)
        }
        // Not the gate: the search read is the cards (none here), never a gate.
        setButtonGate(onGate: false)
        XCTAssertEqual(call("reader.detailsReady()"), "false")
        XCTAssertEqual(call("reader.searchReady()"), "false")
        XCTAssertNil(decoder.home(readerAnswer("reader.search({query: 'x'})"), serviceID: "netflix"))
    }

    func testTheDecoderKeepsADetailsGateAnswerFromBeingTakenAsDetails() throws {
        setButtonGate()
        let answer = readerAnswer(#"reader.details({title: {id: '70000959', kind: 'show'}})"#)
        XCTAssertNil(decoder.details(answer))
        XCTAssertNil(decoder.titles(answer))
        XCTAssertNotNil(decoder.home(answer, serviceID: "netflix"))
    }

    func testChoosingOnTheCurrentGateFollowsThatProfilesSwitchAddressAndNeverTypesOrOpensALockedOne() throws {
        setButtonGate()
        XCTAssertEqual(readerAnswer("reader.chooseProfile({profileID: 'SYNTHPROFILE0000000000000003'})"), "true")
        XCTAssertEqual(call("__nav.join()"), "https://www.netflix.com/SwitchProfile?tkn=SYNTHPROFILE0000000000000003")
        XCTAssertEqual(call("__clicks.length"), "0")
        // The Swift choose script did the same on the same page (frozen answers).
        for id in ["SYNTHPROFILE0000000000000001"] {
            setButtonGate()
            let result = readerAnswer("reader.chooseProfile({profileID: '\(id)'})")
            try g.expect([result, call("__nav.join()"), call("__clicks.length")], id)
        }
    }

    func testNothingIsTypedOrPlayed() throws {
        let source = try String(contentsOf: Self.appDirectory.appendingPathComponent("reader.js"), encoding: .utf8)
        for forbidden in [".value =", "KeyboardEvent", "dispatchEvent", "fetch(", "XMLHttpRequest", ".play()", "localStorage", "document.cookie"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}
