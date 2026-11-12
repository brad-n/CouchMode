// Owns: tests for SiteIcons (choosing a service's own icon from the links a
// page and its web app manifest declare) and IconCacheRule (weekly refresh).
// All markup here is invented.

import XCTest
@testable import CouchModeCore

final class SiteIconsTests: XCTestCase {
    private let base = URL(string: "https://www.example.test/browse")!

    func testReadsIconAndManifestLinksFromHTML() {
        let html = """
        <html><head>
        <link rel="apple-touch-icon" sizes="180x180" href="/img/touch-180.png">
        <LINK REL='shortcut icon' href='/favicon.ico'>
        <link rel="icon" type="image/png" sizes="32x32" href="/img/f32.png">
        <link rel="manifest" href="/site.webmanifest?v=2&amp;x=1">
        <link rel="stylesheet" href="/a.css">
        </head></html>
        """
        let page = SiteIcons.parsePage(html)
        XCTAssertEqual(page.icons.count, 3)
        XCTAssertEqual(page.icons[0], IconCandidate(href: "/img/touch-180.png", size: 180, type: nil, kind: .appleTouch))
        XCTAssertEqual(page.icons[2].size, 32)
        XCTAssertEqual(page.manifest, "/site.webmanifest?v=2&x=1")
    }

    func testFindsLinksAfterAHugeInlineScript() {
        let html = "<head><script>" + String(repeating: "x", count: 900_000) + "</script><link rel=\"manifest\" href=\"/m.json\"></head>"
        XCTAssertEqual(SiteIcons.parsePage(html).manifest, "/m.json")
    }

    func testReadsManifestIcons() {
        let json = #"{"icons":[{"src":"a-192.png","sizes":"192x192","type":"image/png"},{"src":"/a-512.png","sizes":"512x512"},{"src":"m.png","sizes":"512x512","purpose":"maskable"}]}"#
        let icons = SiteIcons.parseManifest(Data(json.utf8))
        XCTAssertEqual(icons.map(\.href), ["a-192.png", "/a-512.png"])
        XCTAssertEqual(icons.map(\.size), [192, 512])
        XCTAssertTrue(icons.allSatisfy { $0.kind == .manifest })
    }

    func testMalformedManifestGivesNothing() {
        XCTAssertTrue(SiteIcons.parseManifest(Data("nope".utf8)).isEmpty)
        XCTAssertTrue(SiteIcons.parseManifest(Data(#"{"icons":5}"#.utf8)).isEmpty)
    }

    func testPicksTheLargestAndPrefersFiveTwelveOrMore() {
        let c = [
            IconCandidate(href: "/t180.png", size: 180, type: nil, kind: .appleTouch),
            IconCandidate(href: "/m512.png", size: 512, type: "image/png", kind: .manifest),
            IconCandidate(href: "/m192.png", size: 192, type: "image/png", kind: .manifest),
        ]
        XCTAssertEqual(SiteIcons.best(c, relativeTo: base)?.absoluteString, "https://www.example.test/m512.png")
    }

    func testTiesGoToTheTouchIcon() {
        let c = [
            IconCandidate(href: "/m.png", size: 180, type: "image/png", kind: .manifest),
            IconCandidate(href: "/t.png", size: 180, type: nil, kind: .appleTouch),
        ]
        XCTAssertEqual(SiteIcons.best(c, relativeTo: base)?.lastPathComponent, "t.png")
    }

    func testSkipsNonPNGInsecureTooSmallAndOpaqueSchemes() {
        let c = [
            IconCandidate(href: "/a.svg", size: 512, type: "image/svg+xml", kind: .icon),
            IconCandidate(href: "/a.ico", size: 256, type: nil, kind: .icon),
            IconCandidate(href: "/a.jpg", size: 512, type: nil, kind: .appleTouch),
            IconCandidate(href: "http://www.example.test/a.png", size: 512, type: nil, kind: .appleTouch),
            IconCandidate(href: "data:image/png;base64,AAAA", size: 512, type: "image/png", kind: .icon),
            IconCandidate(href: "/small.png", size: 64, type: "image/png", kind: .icon),
        ]
        XCTAssertNil(SiteIcons.best(c, relativeTo: base))
    }

    func testUnknownSizeIsUsableOnlyAfterKnownOnes() {
        let c = [
            IconCandidate(href: "/touch", size: nil, type: nil, kind: .appleTouch),
            IconCandidate(href: "/k.png", size: 200, type: "image/png", kind: .icon),
        ]
        XCTAssertEqual(SiteIcons.best(c, relativeTo: base)?.lastPathComponent, "k.png")
        XCTAssertEqual(SiteIcons.best([c[0]], relativeTo: base)?.lastPathComponent, "touch")
    }

    func testResolvesRelativeAndProtocolRelativeAddresses() {
        let rel = IconCandidate(href: "icons/i.png", size: 300, type: nil, kind: .appleTouch)
        XCTAssertEqual(SiteIcons.best([rel], relativeTo: base)?.absoluteString, "https://www.example.test/icons/i.png")
        let pr = IconCandidate(href: "//cdn.example.test/i.png", size: 300, type: nil, kind: .appleTouch)
        XCTAssertEqual(SiteIcons.best([pr], relativeTo: base)?.absoluteString, "https://cdn.example.test/i.png")
    }

    func testSizesAttributeForms() {
        XCTAssertEqual(SiteIcons.largestSide(of: "192x192 512x512"), 512)
        XCTAssertEqual(SiteIcons.largestSide(of: "180X180"), 180)
        XCTAssertNil(SiteIcons.largestSide(of: "any"))
        XCTAssertNil(SiteIcons.largestSide(of: nil))
    }

    func testCacheIsFreshForAWeek() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        XCTAssertTrue(IconCacheRule.isFresh(fetchedAt: now.addingTimeInterval(-6 * day), now: now))
        XCTAssertFalse(IconCacheRule.isFresh(fetchedAt: now.addingTimeInterval(-7 * day), now: now))
        XCTAssertFalse(IconCacheRule.isFresh(fetchedAt: nil, now: now))
        // A date in the future (clock change) is not trusted.
        XCTAssertFalse(IconCacheRule.isFresh(fetchedAt: now.addingTimeInterval(day), now: now))
    }

    func testIconMustBeBigEnoughOnceDecoded() {
        XCTAssertTrue(SiteIcons.isUsable(pixelWidth: 180, pixelHeight: 180))
        XCTAssertFalse(SiteIcons.isUsable(pixelWidth: 120, pixelHeight: 180))
        XCTAssertFalse(SiteIcons.isUsable(pixelWidth: 4000, pixelHeight: 4000))
    }
}
