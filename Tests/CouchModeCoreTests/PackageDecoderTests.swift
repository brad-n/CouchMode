import XCTest
@testable import CouchModeCore

final class PackageDecoderTests: XCTestCase {
    private let decoder = PackageDecoder(siteHosts: ["example.invalid"], imageHosts: ["img.example.invalid"])

    private func title(_ id: String, play: String = "https://www.example.invalid/w/1", extra: String = "") -> String {
        #"{"id":"\#(id)","name":"N","kind":"movie","play":"\#(play)"\#(extra)}"#
    }

    private func home(_ rows: String, extra: String = "") -> String {
        #"{"profiles":[],"rows":[\#(rows)]\#(extra)}"#
    }

    func testTitlesWithOddIdsOrAddressesAreDropped() throws {
        let rows = #"{"id":"r1","title":"Row","kind":"standard","titles":["# + [title("ok-1_x"), title("bad id"), title("a", play: "http://www.example.invalid/w"),
                                                                           title("b", play: "https://evil.invalid/w"), title("c", play: "javascript:1")].joined(separator: ",") + "]}"
        let got = try XCTUnwrap(decoder.home(home(rows), serviceID: "s")).home
        XCTAssertEqual(got.rows[0].titles.map(\.id), ["ok-1_x"])
        XCTAssertEqual(got.serviceID, "s", "the service id is the manifest's, never the script's")
    }

    func testImagesMustBeHttpsOnTheImageHosts() throws {
        let t = title("t1", extra: #","tileArt":"https://img.example.invalid/a.jpg","heroArt":"https://www.example.invalid/a.jpg","page":"https://evil.invalid/p""#)
        let got = try XCTUnwrap(decoder.home(home(#"{"id":"r","title":"R","kind":"ranked","titles":[\#(t)]}"#), serviceID: "s")).home.rows[0].titles[0]
        XCTAssertNotNil(got.tileArt)
        XCTAssertNil(got.heroArt)
        XCTAssertNil(got.page)
    }

    func testBoundsHold() throws {
        let many = (0..<60).map { title("t\($0)") }.joined(separator: ",")
        let rows = (0..<30).map { #"{"id":"r\#($0)","title":"R","kind":"standard","titles":[\#(many)]}"# }.joined(separator: ",")
        let got = try XCTUnwrap(decoder.home(home(rows), serviceID: "s")).home
        XCTAssertEqual(got.rows.count, StreamLimits.maxRows)
        XCTAssertEqual(got.rows[0].titles.count, StreamLimits.maxTitlesPerRow)
        XCTAssertNil(decoder.home(String(repeating: " ", count: PackageDecoder.maxAnswerLength + 1), serviceID: "s"))
    }

    func testCursorsAreKeptOpaqueAndBounded() throws {
        let small = #"{"id":"r","title":"R","kind":"standard","titles":[\#(title("t1"))],"cursor":{"b":2,"a":"x"}}"#
        let big = #"{"id":"q","title":"R","kind":"standard","titles":[\#(title("t1"))],"cursor":"\#(String(repeating: "a", count: 9000))"}"#
        let got = try XCTUnwrap(decoder.home(home("\(small),\(big)"), serviceID: "s"))
        XCTAssertEqual(got.cursors["r"], #"{"a":"x","b":2}"#)
        XCTAssertNil(got.cursors["q"])
    }

    func testNothingToShowIsNil() {
        XCTAssertNil(decoder.home(home(""), serviceID: "s"))
        XCTAssertNil(decoder.home("{}", serviceID: "s"))
        XCTAssertNil(decoder.home("not json", serviceID: "s"))
        XCTAssertNil(decoder.titles("{}"))
        XCTAssertNil(decoder.episodes("{}"))
        XCTAssertNil(decoder.details("{}"))
        XCTAssertNil(decoder.more("[]"))
    }

    func testArgumentRoundTripsATitle() throws {
        let t = StreamTitle(id: "a1", name: "N", kind: .show, play: URL(string: "https://www.example.invalid/w")!,
                            page: URL(string: "https://www.example.invalid/p"), episodeLabel: "S1", synopsis: "s", year: 2020, rating: "R",
                            runtimeSeconds: 60, resumeSeconds: 30, tileArt: URL(string: "https://img.example.invalid/a.jpg"))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: PackageDecoder.argument(for: t)), as: UTF8.self)
        XCTAssertEqual(decoder.titles("[\(json)]"), [t])
    }
}
