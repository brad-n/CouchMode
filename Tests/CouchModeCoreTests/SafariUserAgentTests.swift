// Owns: tests for building the Safari user agent from an installed version.

import XCTest
@testable import CouchModeCore

final class SafariUserAgentTests: XCTestCase {
    func testVersionIsUsedWithSafariTokens() {
        XCTAssertEqual(SafariUserAgent.string(forVersion: "27.2"),
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Safari/605.1.15")
    }

    func testThreePartVersionKept() {
        XCTAssertTrue(SafariUserAgent.string(forVersion: "26.0.1").contains("Version/26.0.1 Safari/605.1.15"))
    }

    func testGarbageEmptyAndNilGiveFallback() {
        for bad in ["", " ", "abc", "27.", ".2", "27.2 Safari/1 evil", "1.2.3.4", "27.2\nX: y", "１２", "27.2000"] {
            XCTAssertEqual(SafariUserAgent.string(forVersion: bad), UserAgents.safari, "input: \(bad)")
        }
        XCTAssertEqual(SafariUserAgent.string(forVersion: nil), UserAgents.safari)
    }

    func testVersionReadFromInfoPlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "27.2"], format: .xml, options: 0)
        XCTAssertEqual(SafariUserAgent.version(fromInfoPlist: data), "27.2")
        XCTAssertNil(SafariUserAgent.version(fromInfoPlist: Data("nope".utf8)))
    }

    func testCatalogUsesGivenAgentExceptYouTube() {
        let ua = SafariUserAgent.string(forVersion: "27.2")
        let services = ServiceCatalog.make(safariUserAgent: ua)
        XCTAssertEqual(services.first { $0.id == "netflix" }?.userAgent, ua)
        XCTAssertEqual(services.first { $0.id == "youtube" }?.userAgent, UserAgents.smartTV)
    }
}
