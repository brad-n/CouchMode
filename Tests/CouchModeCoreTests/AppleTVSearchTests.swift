// Owns: the checks for AppleTVSearch: how a search answer becomes titles, and what the search script asks.
import XCTest
@testable import CouchModeCore

final class AppleTVSearchTests: XCTestCase {
    func testFixtureBecomesTitlesWithAppleAddressesEachOnce() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "appletv-search-read", withExtension: "json", subdirectory: "Fixtures"))
        let titles = AppleTVSearch.titles(fromResults: try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(titles.map(\.name), ["Search Show A", "Search Movie B"], "the repeated id is dropped")
        XCTAssertEqual(titles.map(\.kind), [.show, .movie])
        XCTAssertEqual(titles[0].page?.absoluteString, "https://tv.apple.com/us/show/search-show-a/umc.cmc.synthsearch1")
        XCTAssertEqual(titles[0].play, titles[0].page, "a search result opens its details first; its play address is its page")
        XCTAssertEqual(titles[1].year, 2015)
        XCTAssertEqual(titles[1].runtimeSeconds, 5700)
        XCTAssertNotNil(titles[0].tileArt)
        XCTAssertNil(titles[1].tileArt)
    }

    func testSkipsBadIdsNamelessAndOffSiteAndCaps() {
        let page = "https://tv.apple.com/us/show/x/umc.cmc.a2"
        let json = #"[{"id":"bad id","name":"Bad","page":"\#(page)"},{"id":"umc.cmc.a1","name":" ","page":"\#(page)"},"#
            + #"{"id":"umc.cmc.a2","kind":"show","name":"Two","page":"\#(page)"},{"id":"umc.cmc.a3","name":"Off","page":"https://example.com/x"},{"name":"No id"}]"#
        XCTAssertEqual(AppleTVSearch.titles(fromResults: json).map(\.id), ["umc.cmc.a2"])
        XCTAssertEqual(AppleTVSearch.titles(fromResults: "not json"), [])
        let many = (1...(StreamLimits.maxSearchResults + 10)).map {
            #"{"id":"umc.cmc.s\#($0)","kind":"show","name":"T\#($0)","page":"https://tv.apple.com/us/show/t/umc.cmc.s\#($0)"}"#
        }
        XCTAssertEqual(AppleTVSearch.titles(fromResults: "[" + many.joined(separator: ",") + "]").count, StreamLimits.maxSearchResults)
    }

    func testScriptAsksTheSearchRequestAndQuotesTheQuery() {
        let script = AppleTVSearch.script(query: #"a "quoted" \ query"#)
        XCTAssertTrue(script.contains(#"get("search""#))
        XCTAssertTrue(script.contains(#""a \"quoted\" \\ query""#))
        XCTAssertTrue(script.contains("searchTerm"))
    }
}
