import XCTest
@testable import CouchModeCore

final class PrimeSearchTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "prime-search-read", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testResultsBecomeTitlesOnceEach() throws {
        let titles = PrimeSearch.titles(fromResults: try fixture())
        XCTAssertEqual(titles.map(\.name), ["Result One", "Result Two", "Result To Rent"], "a repeated id is listed once")
        XCTAssertEqual(titles.map(\.kind), [.movie, .show, .movie])
        XCTAssertEqual(titles[0].play.absoluteString, "https://www.primevideo.com/detail/R1movie001?autoplay=1")
        XCTAssertEqual(titles[2].play, titles[2].page, "a title to rent opens its page")
    }

    func testResultsAreCapped() {
        let items = (0..<(StreamLimits.maxSearchResults + 20)).map { #"{"id":"R\#(String(format: "%08d", $0))","name":"R\#($0)","type":"Movie"}"# }
        XCTAssertEqual(PrimeSearch.titles(fromResults: "[\(items.joined(separator: ","))]").count, StreamLimits.maxSearchResults)
    }

    func testBadDataIsEmpty() {
        XCTAssertEqual(PrimeSearch.titles(fromResults: ""), [])
        XCTAssertEqual(PrimeSearch.titles(fromResults: "{}"), [])
    }

    func testSearchAddressEncodesTheQuery() throws {
        let url = try XCTUnwrap(PrimeSearch.pageURL(query: "the & garden é"))
        XCTAssertEqual(url.host, "www.primevideo.com")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.primevideo.com/search/?phrase="))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "phrase" }?.value, "the & garden é")
        XCTAssertNil(PrimeSearch.pageURL(query: "   "))
    }
}
