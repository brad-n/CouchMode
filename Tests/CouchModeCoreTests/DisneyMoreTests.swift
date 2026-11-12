import XCTest
@testable import CouchModeCore

final class DisneyMoreTests: XCTestCase {
    private let rowID = "disney-row-00000000-0000-4000-8000-0000000000a2"

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "disney-home-read", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testARowTheSiteHoldsMoreOfCarriesItsTotal() throws {
        let home = try XCTUnwrap(DisneyHome.parse(try fixture()))
        let rows = Dictionary(uniqueKeysWithValues: home.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows[rowID]?.totalCount, 50)
        XCTAssertTrue(StreamFocus.needsMore(row: try XCTUnwrap(rows[rowID]), focusedIndex: 2))
        XCTAssertNil(home.rows.first { $0.id != rowID }?.totalCount, "rows with no paging have no total")
    }

    func testATotalNoBiggerThanWhatIsLoadedIsIgnored() throws {
        let json = #"{"rows":[{"id":"r1","name":"A","style":"poster_vertical","items":[{"id":"t1","name":"X"}],"more":{"total":1,"next":1,"q":"a=b"}}],"profiles":[]}"#
        XCTAssertNil(DisneyHome.parse(json)?.rows.first?.totalCount)
        XCTAssertTrue(DisneyMore.cursors(fromHome: json).isEmpty)
    }

    func testCursorsComeFromTheHomeKeyedByRowID() throws {
        let cursors = DisneyMore.cursors(fromHome: try fixture())
        XCTAssertEqual(Array(cursors.keys), [rowID])
        let cursor = try XCTUnwrap(cursors[rowID])
        XCTAssertEqual(cursor.setID, "00000000-0000-4000-8000-0000000000a2")
        XCTAssertEqual(cursor.next, 30)
        XCTAssertTrue(cursor.query.hasPrefix("setStyle=poster_vertical"))
    }

    func testOddCursorsAreRefused() {
        func cursors(_ more: String) -> Int {
            DisneyMore.cursors(fromHome: #"{"rows":[{"id":"r1","name":"A","style":"s","items":[{"id":"t1","name":"X"}],"more":\#(more)}],"profiles":[]}"#).count
        }
        XCTAssertEqual(cursors(#"{"total":9,"next":1,"q":"a=b"}"#), 1)
        XCTAssertEqual(cursors(#"{"total":9,"next":1,"q":"a=b&token=x y"}"#), 0, "spaces")
        XCTAssertEqual(cursors(#"{"total":9,"next":1,"q":"https://x.invalid/?a=b"}"#), 0, "not a plain query")
        XCTAssertEqual(cursors(#"{"total":9,"next":-1,"q":"a=b"}"#), 0)
        XCTAssertEqual(cursors(#"{"total":9,"next":100000,"q":"a=b"}"#), 0)
        XCTAssertEqual(cursors(#"{"total":9,"next":1}"#), 0)
    }

    func testTheScriptAsksForTheSetAtTheCursorOnly() throws {
        let cursor = DisneyMore.Cursor(setID: "00000000-0000-4000-8000-0000000000a2", query: "setStyle=poster_vertical", next: 30)
        let script = try XCTUnwrap(DisneyMore.script(for: cursor))
        XCTAssertTrue(script.contains(#""set/" + "00000000-0000-4000-8000-0000000000a2" + "?limit=30&offset=30&" + "setStyle=poster_vertical""#))
        XCTAssertFalse(script.contains("method"), "a plain read: no POST")
        XCTAssertNil(DisneyMore.script(for: DisneyMore.Cursor(setID: "a b", query: "x=1", next: 0)))
    }

    func testTheNextBatchIsParsedAndTheCursorAdvances() throws {
        let cursor = DisneyMore.Cursor(setID: "s1", query: "a=b", next: 30)
        let read = #"{"items":[{"id":"00000000-0000-4000-8000-000000000301","name":"More One"},{"id":"00000000-0000-4000-8000-000000000302","name":"More Two"},{"name":"no id"}],"count":3,"hasMore":true}"#
        let result = try XCTUnwrap(DisneyMore.titles(fromRead: read, cursor: cursor))
        XCTAssertEqual(result.titles.map(\.name), ["More One", "More Two"])
        XCTAssertEqual(result.cursor?.next, 33, "advances by the items the site sent, kept or not")
        XCTAssertEqual(result.cursor?.setID, "s1")
    }

    func testTheCursorEndsWhenTheSiteHasNoMore() throws {
        let cursor = DisneyMore.Cursor(setID: "s1", query: "a=b", next: 30)
        let last = try XCTUnwrap(DisneyMore.titles(fromRead: #"{"items":[{"id":"00000000-0000-4000-8000-000000000301","name":"Last"}],"count":1,"hasMore":false}"#, cursor: cursor))
        XCTAssertEqual(last.titles.count, 1)
        XCTAssertNil(last.cursor)
        let empty = try XCTUnwrap(DisneyMore.titles(fromRead: #"{"items":[],"count":0,"hasMore":true}"#, cursor: cursor))
        XCTAssertTrue(empty.titles.isEmpty)
        XCTAssertNil(empty.cursor, "an empty batch ends it, however the site answers")
    }

    func testUnreadableAnswersAreNil() {
        let cursor = DisneyMore.Cursor(setID: "s1", query: "a=b", next: 30)
        XCTAssertNil(DisneyMore.titles(fromRead: "", cursor: cursor))
        XCTAssertNil(DisneyMore.titles(fromRead: "[1]", cursor: cursor))
        XCTAssertNil(DisneyMore.titles(fromRead: #"{"hasMore":true}"#, cursor: cursor))
    }
}
