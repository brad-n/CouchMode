import XCTest
@testable import CouchModeCore

final class PrimeMoreTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "prime-home-read", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func home(more: String) -> String {
        #"{"hero":null,"rows":[{"id":"1","name":"A","type":"StandardCarousel","cw":false,"more":\#(more),"items":[{"id":"T1synth01","name":"X","type":"Movie"}]}],"profiles":[]}"#
    }

    func testARowThePageHoldsMoreOfCarriesItsTotal() throws {
        let rows = try XCTUnwrap(PrimeHome.parse(try fixture())).rows
        XCTAssertEqual(rows.first { $0.id == "prime-row-2" }?.totalCount, 60)
        XCTAssertTrue(StreamFocus.needsMore(row: try XCTUnwrap(rows.first { $0.id == "prime-row-2" }), focusedIndex: 4))
        XCTAssertNil(rows.first { $0.id == "prime-row-1" }?.totalCount)
    }

    func testATotalNoBiggerThanWhatIsLoadedIsIgnored() {
        let json = home(more: #"{"total":1,"target":"t_1","token":"k_1","start":1}"#)
        XCTAssertNil(PrimeHome.parse(json)?.rows.first?.totalCount)
        XCTAssertTrue(PrimeMore.cursors(fromHome: json).isEmpty)
    }

    func testCursorsComeFromTheHomeKeyedByRowID() throws {
        let cursors = PrimeMore.cursors(fromHome: try fixture())
        XCTAssertEqual(Array(cursors.keys), ["prime-row-2"])
        XCTAssertEqual(cursors["prime-row-2"], PrimeMore.Cursor(target: "synth-target_id=", token: "synth-token_A=", start: 20))
    }

    func testOddCursorsAreRefused() {
        func count(_ more: String) -> Int { PrimeMore.cursors(fromHome: home(more: more)).count }
        XCTAssertEqual(count(#"{"total":9,"target":"t_1=","token":"k-1=","start":1}"#), 1)
        XCTAssertEqual(count(#"{"total":9,"target":"t 1","token":"k","start":1}"#), 0, "space")
        XCTAssertEqual(count(#"{"total":9,"target":"t&x=1","token":"k","start":1}"#), 0, "would add a parameter")
        XCTAssertEqual(count(#"{"total":9,"target":"t","token":"","start":1}"#), 0)
        XCTAssertEqual(count(#"{"total":9,"target":"t","token":"k","start":-1}"#), 0)
        XCTAssertEqual(count(#"{"total":9,"target":"t","token":"k","start":99999}"#), 0)
        XCTAssertEqual(count(#"{"total":9,"target":"t","token":"k"}"#), 0)
        XCTAssertEqual(count(#"{"total":9,"target":"t","token":"\#(String(repeating: "a", count: 5000))","start":1}"#), 0, "too long")
    }

    func testTheScriptMakesTheOnePaginationPost() throws {
        let script = try XCTUnwrap(PrimeMore.script(for: PrimeMore.Cursor(target: "t_1=", token: "k-1=", start: 20)))
        XCTAssertTrue(script.contains("/api/paginateCollection"))
        XCTAssertTrue(script.contains(#""t_1=""#))
        XCTAssertNil(PrimeMore.script(for: PrimeMore.Cursor(target: "a b", token: "k", start: 0)))
    }

    func testTheNextBatchIsParsedAndTheCursorAdvances() throws {
        let cursor = PrimeMore.Cursor(target: "t_1", token: "k_1", start: 20)
        let read = #"{"items":[{"id":"M1synth01","name":"More One","type":"Movie"},{"id":"M2synth02","name":"More Two","type":"TV Show","title":"More Two - Season 1"},{"name":"no id"}],"hasMore":true,"token":"k_2=","start":40}"#
        let result = try XCTUnwrap(PrimeMore.titles(fromRead: read, cursor: cursor))
        XCTAssertEqual(result.titles.map(\.name), ["More One", "More Two"])
        XCTAssertEqual(result.cursor, PrimeMore.Cursor(target: "t_1", token: "k_2=", start: 40))
    }

    func testTheCursorEndsWhenThePageHasNoMore() throws {
        let cursor = PrimeMore.Cursor(target: "t_1", token: "k_1", start: 20)
        let last = try XCTUnwrap(PrimeMore.titles(fromRead: #"{"items":[{"id":"M1synth01","name":"Last","type":"Movie"}],"hasMore":false,"token":"k_2","start":21}"#, cursor: cursor))
        XCTAssertEqual(last.titles.count, 1)
        XCTAssertNil(last.cursor)
        let noToken = try XCTUnwrap(PrimeMore.titles(fromRead: #"{"items":[],"hasMore":true,"start":21}"#, cursor: cursor))
        XCTAssertNil(noToken.cursor, "no next token ends it")
        let stuck = try XCTUnwrap(PrimeMore.titles(fromRead: #"{"items":[],"hasMore":true,"token":"k_2","start":20}"#, cursor: cursor))
        XCTAssertNil(stuck.cursor, "an answer that doesn't move on ends it")
    }

    func testUnreadableAnswersAreNil() {
        let cursor = PrimeMore.Cursor(target: "t_1", token: "k_1", start: 20)
        XCTAssertNil(PrimeMore.titles(fromRead: "", cursor: cursor))
        XCTAssertNil(PrimeMore.titles(fromRead: "[1]", cursor: cursor))
        XCTAssertNil(PrimeMore.titles(fromRead: #"{"hasMore":true}"#, cursor: cursor))
    }

    func testOnlyThePrimeHomePageIsTheHomePage() {
        XCTAssertTrue(PrimeHome.isHomePage(URL(string: "https://www.primevideo.com/")))
        XCTAssertTrue(PrimeHome.isHomePage(URL(string: "https://www.primevideo.com")))
        XCTAssertFalse(PrimeHome.isHomePage(URL(string: "https://www.primevideo.com/detail/ABC123")))
        XCTAssertFalse(PrimeHome.isHomePage(URL(string: "https://www.primevideo.com/?x=1")))
        XCTAssertFalse(PrimeHome.isHomePage(URL(string: "https://example.invalid/")))
        XCTAssertFalse(PrimeHome.isHomePage(nil))
    }
}
