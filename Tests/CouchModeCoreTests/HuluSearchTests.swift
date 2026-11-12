import XCTest
@testable import CouchModeCore

final class HuluSearchTests: XCTestCase {
    func testSearchIsHulusOwnSearchPage() {
        XCTAssertEqual(HuluSearch.pageURL.absoluteString, "https://www.hulu.com/search")
    }

    func testResultsBecomeSeriesAndMovieTitlesWithHuluAddresses() {
        let json = #"[{"href":"/series/00000000-0000-4000-8000-000000000001","name":"Show A","art":"https://img.hulu.invalid/a?x=1"},{"href":"/movie/00000000-0000-4000-8000-000000000002","name":" Movie B ","art":null}]"#
        let titles = HuluSearch.titles(fromResults: json)
        XCTAssertEqual(titles.map(\.name), ["Show A", "Movie B"])
        XCTAssertEqual(titles.map(\.kind), [.show, .movie])
        XCTAssertEqual(titles[0].page?.absoluteString, "https://www.hulu.com/series/00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(titles[1].page?.absoluteString, "https://www.hulu.com/movie/00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(titles[1].play.absoluteString, "https://www.hulu.com/watch/00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(titles[0].tileArt?.host, "img.hulu.invalid")
        XCTAssertNil(titles[1].tileArt)
    }

    func testCapturedResultsBecomeTitles() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hulu-search-read", withExtension: "json", subdirectory: "Fixtures"))
        let titles = HuluSearch.titles(fromResults: try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(titles.map(\.name), ["Show A", "Show B", "Show C", "Show D", "Show E", "Movie A"])
        XCTAssertEqual(titles.map(\.kind), [.show, .show, .show, .show, .show, .movie])
        XCTAssertTrue(titles.allSatisfy { $0.tileArt != nil && $0.page != nil })
    }

    func testSkipsOtherLinksBadIdsNamelessAndDuplicates() {
        let json = #"[{"href":"/account","name":"Account"},{"href":"/network/abc","name":"Network"},{"href":"/series/bad id","name":"Bad"},{"href":"/series/a1","name":"  "},{"href":"/series/a2","name":"Two","art":"https://evil.example/x.jpg"},{"href":"/series/a2","name":"Again"},{"href":"/series/a3/extra","name":"Extra"},{"href":null,"name":"x"}]"#
        let titles = HuluSearch.titles(fromResults: json)
        XCTAssertEqual(titles.map(\.id), ["a2"])
        XCTAssertNil(titles.first?.tileArt, "art from a host that isn't Hulu's is dropped")
        XCTAssertEqual(HuluSearch.titles(fromResults: "not json"), [])
    }

    func testCapsResults() {
        let cards = (1...(StreamLimits.maxSearchResults + 10)).map { #"{"href":"/series/s\#($0)","name":"T\#($0)"}"# }
        XCTAssertEqual(HuluSearch.titles(fromResults: "[" + cards.joined(separator: ",") + "]").count, StreamLimits.maxSearchResults)
    }

    func testScriptsUseThePagesOwnSearchBoxAndQuoteTheQuery() {
        XCTAssertTrue(HuluSearch.readyScript.contains("search-bar-input"))
        XCTAssertTrue(HuluSearch.resultsReadyScript.contains("instant-search-item-link"))
        XCTAssertTrue(HuluSearch.resultsScript.contains("list-item-content-title"))
        let typed = HuluSearch.typeScript(query: #"a "quoted" \ query"#)
        XCTAssertTrue(typed.contains(#""a \"quoted\" \\ query""#))
    }
}
