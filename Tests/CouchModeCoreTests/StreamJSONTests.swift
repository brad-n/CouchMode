import XCTest
@testable import CouchModeCore

final class StreamJSONTests: XCTestCase {
    func testNumbersAndIDs() {
        XCTAssertEqual(StreamJSON.int(42), 42)
        XCTAssertEqual(StreamJSON.int(42.0), 42)
        XCTAssertNil(StreamJSON.int(4.5), "a fraction isn't a whole number")
        XCTAssertNil(StreamJSON.int("42"))
        XCTAssertEqual(StreamJSON.numericID(81006558), "81006558")
        XCTAssertEqual(StreamJSON.numericID("81006558"), "81006558")
        XCTAssertNil(StreamJSON.numericID(0))
        XCTAssertNil(StreamJSON.numericID("12a"))
        XCTAssertEqual(StreamJSON.token("ae0f0f99-4698-407b-bc04-00906774ec4b"), "ae0f0f99-4698-407b-bc04-00906774ec4b")
        XCTAssertNil(StreamJSON.token("a/b"))
        XCTAssertNil(StreamJSON.token(String(repeating: "a", count: 65)))
    }

    func testTextAndAddresses() {
        XCTAssertEqual(StreamJSON.string("  Hulu \n"), "Hulu")
        XCTAssertNil(StreamJSON.string("   "))
        XCTAssertEqual(StreamJSON.httpsURL("https://img.example/a.jpg")?.host, "img.example")
        XCTAssertNil(StreamJSON.httpsURL("http://img.example/a.jpg"))
        XCTAssertNil(StreamJSON.httpsURL("not a url"))
    }

    func testJSONAndQuoting() {
        XCTAssertEqual(StreamJSON.object(#"{"a":1}"#)?["a"] as? Int, 1)
        XCTAssertNil(StreamJSON.object("[1]"))
        XCTAssertEqual(StreamJSON.objects(#"[{"a":1},{"a":2}]"#).count, 2)
        XCTAssertTrue(StreamJSON.objects("nope").isEmpty)
        XCTAssertEqual(StreamJSON.jsString(#"say "hi"/now"#), #""say \"hi\"/now""#)
    }
}
