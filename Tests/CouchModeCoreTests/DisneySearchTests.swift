import XCTest
@testable import CouchModeCore

final class DisneySearchTests: XCTestCase {
    func testFixtureBecomesTitlesWithDisneyAddresses() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "disney-search-read", withExtension: "json", subdirectory: "Fixtures"))
        let titles = DisneySearch.titles(fromResults: try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(titles.map(\.name), ["Show A", "Movie B", "Movie C"])
        XCTAssertEqual(titles.map(\.kind), [.show, .movie, .movie])
        XCTAssertEqual(titles[0].page?.absoluteString, "https://www.disneyplus.com/browse/entity-00000000-0000-4000-8000-000000000601")
        XCTAssertEqual(titles[1].year, 2015)
        XCTAssertEqual(titles[1].runtimeSeconds, 5700)
        XCTAssertNotNil(titles[0].tileArt)
        XCTAssertNil(titles[2].tileArt)
    }

    func testSkipsBadIdsNamelessAndDuplicatesAndCaps() {
        let json = #"[{"id":"bad id","name":"Bad"},{"id":"a1","name":" "},{"id":"a2","name":"Two"},{"id":"a2","name":"Again"},{"name":"No id"}]"#
        XCTAssertEqual(DisneySearch.titles(fromResults: json).map(\.id), ["a2"])
        XCTAssertEqual(DisneySearch.titles(fromResults: "not json"), [])
        let many = (1...(StreamLimits.maxSearchResults + 10)).map { #"{"id":"s\#($0)","name":"T\#($0)"}"# }
        XCTAssertEqual(DisneySearch.titles(fromResults: "[" + many.joined(separator: ",") + "]").count, StreamLimits.maxSearchResults)
    }

    func testScriptAsksTheSearchRequestAndQuotesTheQuery() {
        let script = DisneySearch.script(query: #"a "quoted" \ query"#)
        XCTAssertTrue(script.contains("search?query="))
        XCTAssertTrue(script.contains(#""a \"quoted\" \\ query""#))
        XCTAssertTrue(script.contains("encodeURIComponent"))
    }
}
