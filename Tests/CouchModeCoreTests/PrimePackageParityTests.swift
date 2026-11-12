import XCTest
import JavaScriptCore
@testable import CouchModeCore

/// The Prime package (apps/prime) against the frozen outputs of the former built-in Swift reader (Fixtures/golden): for every Prime fixture the package's
/// output, decoded the way the app decodes it, must equal what was frozen. The JS runs in
/// JavaScriptCore; its page-reading half is exercised against a tiny stand-in page.
final class PrimePackageParityTests: XCTestCase {
    private var context: JSContext!
    private var decoder: PackageDecoder!
    private var g: Golden!

    override func setUpWithError() throws {
        g = Golden("prime", function: name)
        let manifest = try PackageManifest.parse(Data(contentsOf: Self.appDirectory.appendingPathComponent("manifest.json")))
        decoder = PackageDecoder(manifest: manifest)
        context = try Self.makeContext()
    }

    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/prime")
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

    private func row(_ id: String, kind: StreamTitle.Kind, name: String) -> StreamTitle {
        StreamTitle(id: id, name: name, kind: kind, play: URL(string: "https://www.primevideo.com/detail/\(id)")!, page: URL(string: "https://www.primevideo.com/detail/\(id)"))
    }

    // MARK: Home

    private func assertHomeParity(_ read: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try g.next(file: file, line: line)
        let js = build("home", read)
        guard !(expected is NSNull) else { XCTAssertNil(decoder.home(js, serviceID: "prime"), file: file, line: line); return }
        let got = try XCTUnwrap(decoder.home(js, serviceID: "prime"), "package returned no home", file: file, line: line)
        Golden.assertEqual(got.home, expected, file: file, line: line)
        // Paging: the same rows can ask for more, from the same position.
        var cursors: [String: Any] = [:]
        for (rowID, text) in got.cursors {
            let object = try XCTUnwrap(StreamJSON.object(text))
            cursors[rowID] = ["target": object["target"] as? String ?? "", "token": object["token"] as? String ?? "", "start": StreamJSON.int(object["start"]) ?? -1] as [String: Any]
        }
        try g.expect(cursors, file: file, line: line)
    }

    func testHomeFixtureDecodesToWhatTheSwiftParserMakes() throws {
        try assertHomeParity(try fixture("prime-home-read"))
        let home = try XCTUnwrap(decoder.home(build("home", try fixture("prime-home-read")), serviceID: "prime")).home
        XCTAssertEqual(home.rows.map(\.kind), [.continueWatching, .standard, .ranked])
        XCTAssertEqual(home.rows.first { $0.id == "prime-row-2" }?.totalCount, 60)
    }

    func testHomeEdgeCasesMatch() throws {
        func home(more: String) -> String {
            #"{"hero":null,"rows":[{"id":"1","name":"A","type":"StandardCarousel","cw":false,"more":\#(more),"items":[{"id":"T1synth01","name":"X","type":"Movie"}]}],"profiles":[]}"#
        }
        for more in [#"{"total":1,"target":"t_1","token":"k_1","start":1}"#, #"{"total":9,"target":"t_1=","token":"k-1=","start":1}"#,
                     #"{"total":9,"target":"t 1","token":"k","start":1}"#, #"{"total":9,"target":"t&x=1","token":"k","start":1}"#,
                     #"{"total":9,"target":"t","token":"","start":1}"#, #"{"total":9,"target":"t","token":"k","start":-1}"#,
                     #"{"total":9,"target":"t","token":"k","start":99999}"#, #"{"total":9,"target":"t","token":"k"}"#,
                     #"{"total":9,"target":"t","token":"\#(String(repeating: "a", count: 5000))","start":1}"#, "null"] {
            try assertHomeParity(home(more: more))
        }
        for json in ["", "[]", "{}", #"{"rows":[]}"#, #"{"rows":[],"hero":{"id":"H1synth01","name":"Only Hero","type":"Movie"}}"#,
                     #"{"rows":[{"id":"1","name":"Top 10 movies","type":"X","items":[{"id":"T1synth01","name":"X","type":"Movie"}]}]}"#,
                     #"{"rows":[{"id":"1234","name":"Long id","type":"X","items":[{"id":"T1synth01","name":"X","type":"Movie"}]}]}"#] {
            try assertHomeParity(json)
        }
    }

    func testHomeIsBounded() throws {
        let items = (0..<60).map { #"{"id":"T\#(String(format: "%08d", $0))","name":"T\#($0)","type":"Movie"}"# }.joined(separator: ",")
        let rows = (1...30).map { #"{"id":"\#($0)","name":"R\#($0)","type":"X","items":[\#(items)]}"# }.joined(separator: ",")
        let read = #"{"rows":[\#(rows)],"profiles":[]}"#
        try assertHomeParity(read)
        let home = try XCTUnwrap(decoder.home(build("home", read), serviceID: "prime")).home
        XCTAssertEqual(home.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(home.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
    }

    // MARK: Search and more

    func testSearchFixtureMatches() throws {
        let read = try fixture("prime-search-read")
        try g.expect(decoder.titles(build("search", read)))
        XCTAssertEqual(decoder.titles(build("search", "{}")), [])
        let items = (0..<80).map { #"{"id":"R\#(String(format: "%08d", $0))","name":"R\#($0)","type":"Movie"}"# }
        let big = "[\(items.joined(separator: ","))]"
        try g.expect(decoder.titles(build("search", big)))
    }

    func testMoreMatches() throws {
        let cursorJS = #", {"target":"t_1","token":"k_1","start":20}"#
        for read in [#"{"items":[{"id":"M1synth01","name":"More One","type":"Movie"},{"id":"M2synth02","name":"More Two","type":"TV Show","title":"More Two - Season 1"},{"name":"no id"}],"hasMore":true,"token":"k_2=","start":40}"#,
                     #"{"items":[{"id":"M1synth01","name":"Last","type":"Movie"}],"hasMore":false,"token":"k_2","start":21}"#,
                     #"{"items":[],"hasMore":true,"start":21}"#, #"{"items":[],"hasMore":true,"token":"k_2","start":20}"#] {
            let expected = try XCTUnwrap(try g.next() as? [String: Any])
            let got = try XCTUnwrap(decoder.more(build("more", read, extra: cursorJS)))
            Golden.assertEqual(got.titles, try XCTUnwrap(expected["titles"]))
            if let next = expected["cursor"] as? [String: Any] {
                let object = try XCTUnwrap(StreamJSON.object(try XCTUnwrap(got.cursor)))
                XCTAssertEqual(object["target"] as? String, next["target"] as? String)
                XCTAssertEqual(object["token"] as? String, next["token"] as? String)
                XCTAssertEqual(StreamJSON.int(object["start"]), next["start"] as? Int)
            } else {
                XCTAssertNil(got.cursor)
            }
        }
        for read in ["", "[1]", #"{"hasMore":true}"#] {
            XCTAssertTrue(try g.nextIsNil())
            XCTAssertNil(decoder.more(build("more", read, extra: cursorJS)))
        }
    }

    // MARK: Details and episodes

    private func assertDetailsParity(_ name: String, row: StreamTitle, file: StaticString = #filePath, line: UInt = #line) throws {
        let read = try fixture(name)
        let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: row)), as: UTF8.self)
        let expected = try g.next(file: file, line: line)
        XCTAssertFalse(expected is NSNull, file: file, line: line)
        let got = try XCTUnwrap(decoder.details(build("details", read, extra: ", \(argument)")), "package returned no details", file: file, line: line)
        Golden.assertEqual(got, expected, name, file: file, line: line)
        try g.expect(decoder.episodes(build("episodes", read)), name, file: file, line: line)
    }

    func testEveryDetailsFixtureMatches() throws {
        try assertDetailsParity("prime-details-show-read", row: row("S2season02", kind: .show, name: "Show One"))
        try assertDetailsParity("prime-details-single-season-read", row: row("L1limited1", kind: .show, name: "Limited Show"))
        try assertDetailsParity("prime-details-movie-read", row: row("M1movie001", kind: .show, name: "Movie Four"))
        try assertDetailsParity("prime-details-offer-read", row: row("P2rent0001", kind: .movie, name: "Movie To Rent"))
    }

    func testDetailsKeepWhatTheRowAlreadyHad() throws {
        var full = row("S2season02", kind: .show, name: "Show One")
        full.synopsis = "From the row"; full.year = 2020; full.rating = "PG"
        full.tileArt = URL(string: "https://example.invalid/images/S/a/tile.jpg")
        let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: full)), as: UTF8.self)
        let read = try fixture("prime-details-show-read")
        try g.expect(decoder.details(build("details", read, extra: ", \(argument)")))
    }

    func testNonsenseGivesNothing() throws {
        for read in ["", "[]", "nope", "null"] {
            XCTAssertNil(decoder.details(build("details", read, extra: ", {}")))
            XCTAssertEqual(decoder.episodes(build("episodes", read)) ?? [], [])
        }
        try g.expect([StreamEpisode]())
    }

    func testRuntimeTextShapes() throws {
        for text in ["1 h 33 min", "55min", "2 h", "", "soon"] {
            let read = #"{"id":"M1movie001","name":"X","runtimeText":"\#(text)","episodes":[]}"#
            let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: row("M1movie001", kind: .movie, name: "X"))), as: UTF8.self)
            try g.expect(decoder.details(build("details", read, extra: ", \(argument)"))?.title.runtimeSeconds, text)
        }
    }

    // MARK: The page-reading half, against a stand-in page

    private func run(_ script: String, page: String) -> String {
        context.evaluateScript("""
        var document = { getElementById: id => id === 'dv-web-page-hydration-data' ? { textContent: \(StreamJSON.jsString(page)) } : null,
          querySelector: s => s.indexOf('active-profile') >= 0 ? { getAttribute: () => 'active-profile-Profile 1' } : null,
          querySelectorAll: () => [] };
        var getComputedStyle = () => ({ backgroundImage: '' });
        var location = { pathname: '/detail/S2season02' };
        """)
        return context.evaluateScript(script)?.toString() ?? "undefined"
    }

    func testHomeAndSearchAreReadFromThePagesOwnData() throws {
        let card = #"{"link":{"url":"/detail/H1synth01"},"displayTitle":"Hero Show","title":"Hero Show - Season 1","entityType":"TV Show","releaseYear":"2026","images":{"cover":{"url":"https://example.invalid/images/S/a/c._UR1,1_.jpg"}},"playbackActions":[{"resumeTime":60,"fallbackUrl":"/detail/H1play01"}],"progress":{"percentage":50}}"#
        let home = #"{"init":{"route":{"name":"home"},"preparations":{"body":{"containers":[{"containerType":"StandardHero","entities":[\#(card)]},{"containerType":"StandardCarousel","text":"Continue","isContinueWatching":true,"entities":[\#(card)]}]}}}}"#
        XCTAssertEqual(run("reader.homeReady()", page: home), "true")
        let json = run("reader.home()", page: home)
        let got = try XCTUnwrap(decoder.home(json, serviceID: "prime")).home
        XCTAssertEqual(got.rows.map(\.kind), [.continueWatching])
        XCTAssertEqual(got.hero?.name, "Hero Show")
        XCTAssertEqual(got.rows[0].titles[0].play.absoluteString, "https://www.primevideo.com/detail/H1play01?autoplay=1&t=60")
        XCTAssertEqual(got.rows[0].titles[0].runtimeSeconds, 120)
        XCTAssertEqual(got.currentProfileID, "Profile 1")

        let search = #"{"init":{"route":{"name":"search"},"preparations":{"body":{"containers":[{"containerType":"Grid","entities":[\#(card)]},{"containerType":"Shelf","entities":[\#(card)]}]}}}}"#
        XCTAssertEqual(run("reader.searchReady()", page: search), "true")
        XCTAssertEqual(decoder.titles(run("reader.search()", page: search))?.map(\.name), ["Hero Show"])
        XCTAssertEqual(run("reader.home()", page: "{}"), "", "no data is no answer")
    }

    func testDetailsAreReadFromThePagesOwnData() throws {
        let page = #"""
        {"init":{"route":{"name":"detail"},"preparations":{"body":{
          "atf":{"state":{"pageTitleId":"S2season02",
            "detail":{"headerDetail":{"S2season02":{"title":"Show One - Season 2","parentTitle":"Show One","titleType":"season","seasonNumber":2,"releaseYear":"2025",
              "ratingBadge":{"displayText":"TV-MA"},"synopsis":"About it.","images":{"heroshot":"https://example.invalid/images/S/a/hero.jpg"}}}},
            "action":{"atf":{"S2season02":{"primaryActions":[{"actionType":"PLAY","payload":{"playback":{"playbackURL":"/detail/S2ep000001?autoplay=1","resumeTime":30,"runTime":600,"label":"Resume S2 E1"}}}]}}},
            "seasons":{"x":[{"seasonLink":"/detail/S2season01","displayName":"Season 1","sequenceNumber":1},{"seasonLink":"/detail/S2season02","displayName":"Season 2","sequenceNumber":2,"isSelected":true}]}}},
          "btf":{"state":{"episodeList":{"cardTitleIds":["e1"]},"self":{"e1":{"link":"/detail/S2ep000001"}},
            "detail":{"detail":{"e1":{"episodeNumber":1,"title":"Pilot","synopsis":"First.","duration":600}}},
            "action":{"btf":{"e1":{"primaryActions":[{"actionType":"PLAY","payload":{"playback":{"playbackURL":"/detail/S2ep000001?autoplay=1","runTime":600,"resumeTime":30}}}]}}}}}}}}}
        """#
        XCTAssertEqual(run("reader.detailsReady()", page: page), "true")
        let argument = try String(decoding: JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: row("S2season02", kind: .show, name: "Show One"))), as: UTF8.self)
        let details = try XCTUnwrap(decoder.details(run("reader.details({title: \(argument)})", page: page)))
        XCTAssertEqual(details.seasons.map(\.name), ["Season 1", "Season 2"])
        XCTAssertEqual(details.currentSeasonID, "S2season02")
        XCTAssertEqual(details.seasons[1].episodes.map(\.name), ["Pilot"])
        XCTAssertEqual(details.title.episodeLabel, "S2 · E1")
        XCTAssertEqual(decoder.episodes(run("reader.season({})", page: page))?.count, 1)
        XCTAssertEqual(run("reader.details({title: {}})", page: "{}"), "")
    }

    func testTheProfileChecksReadThePageNotTheArguments() {
        XCTAssertEqual(run("reader.profileIsCurrent({profileID: 'Profile 1'})", page: "{}"), "true")
        XCTAssertEqual(run("reader.profileIsCurrent({profileID: 'Profile 2'})", page: "{}"), "false")
        XCTAssertEqual(run("reader.chooseProfile({profileID: 'Profile 1'})", page: "{}"), "true", "already current")
        XCTAssertEqual(run("reader.chooseProfile({profileID: 'Nobody'})", page: "{}"), "false")
    }
}
