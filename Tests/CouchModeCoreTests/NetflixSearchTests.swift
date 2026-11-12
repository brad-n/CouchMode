import XCTest
@testable import CouchModeCore

final class NetflixSearchTests: XCTestCase {
    private let play: (String) -> URL? = { NetflixHome.playURL(videoID: $0) }
    private let page: (String) -> URL? = { NetflixHome.pageURL(videoID: $0) }

    func testSearchPageCarriesTheTidiedQuery() {
        XCTAssertEqual(NetflixSearch.pageURL(query: "  stranger   things ")?.absoluteString,
                       "https://www.netflix.com/search?q=stranger%20things")
        XCTAssertNil(NetflixSearch.pageURL(query: "   "))
    }

    func testResultCardsBecomeTitlesWithNetflixAddresses() {
        let json = #"[{"id":"70000548","name":"Sample Search","art":"https://art.invalid/1.jpg"},{"id":"70000137","name":"Sample Search Result","art":null}]"#
        let titles = NetflixSearch.titles(fromResults: json, play: play, page: page)
        XCTAssertEqual(titles.map(\.name), ["Sample Search", "Sample Search Result"])
        XCTAssertEqual(titles.first?.play.absoluteString, "https://www.netflix.com/watch/70000548")
        XCTAssertEqual(titles.first?.page?.absoluteString, "https://www.netflix.com/title/70000548")
        XCTAssertEqual(titles.first?.tileArt?.absoluteString, "https://art.invalid/1.jpg")
        XCTAssertNil(titles.last?.tileArt)
    }

    func testSkipsBadCardsAndDuplicates() {
        let json = #"[{"id":null,"name":"No id"},{"id":"12a","name":"Bad id"},{"id":"1","name":"  "},{"id":"2","name":"Two","art":"http://plain.invalid/x.jpg"},{"id":"2","name":"Two again"}]"#
        let titles = NetflixSearch.titles(fromResults: json, play: play, page: page)
        XCTAssertEqual(titles.map(\.id), ["2"])
        XCTAssertNil(titles.first?.tileArt, "plain-http art is dropped")
        XCTAssertEqual(NetflixSearch.titles(fromResults: "not json", play: play, page: page), [])
    }

    func testCapsResults() {
        let cards = (1...(StreamLimits.maxSearchResults + 10)).map { #"{"id":"\#($0)","name":"T\#($0)"}"# }
        let titles = NetflixSearch.titles(fromResults: "[" + cards.joined(separator: ",") + "]", play: play, page: page)
        XCTAssertEqual(titles.count, StreamLimits.maxSearchResults)
    }

    func testScriptsLookForTheResultCards() {
        XCTAssertTrue(NetflixSearch.readyScript.contains(#"data-uia="standard-card""#))
        XCTAssertTrue(NetflixSearch.resultsScript.contains("jbv="))
    }
}
