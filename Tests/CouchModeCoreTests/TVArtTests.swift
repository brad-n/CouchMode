// Owns: tests for TVArt (picking landscape tvOS art out of a lookup response),
// EdgeColor (dominant edge color), TileLayout (tile math) and the catalog's
// art fields. Every address and image here is invented.

import XCTest
@testable import CouchModeCore

final class TVArtTests: XCTestCase {
    private func lookup(_ fields: String) -> Data { Data(#"{"resultCount":1,"results":[{\#(fields)}]}"#.utf8) }
    private let tv = "https://is1-ssl.mzstatic.com/image/thumb/Purple1/v4/aa/bb/cc/App_Icon-marketing.lsr/512x512bb.jpg"
    private let phone = "https://is1-ssl.mzstatic.com/image/thumb/Purple1/v4/aa/bb/cc/AppIcon-0-1x.png/512x512bb.jpg"

    func testLookupURLAsksForTvSoftware() {
        XCTAssertEqual(TVArt.lookupURL(appStoreId: 42)?.absoluteString,
                       "https://itunes.apple.com/lookup?id=42&entity=tvSoftware&country=us")
        XCTAssertNil(TVArt.lookupURL(appStoreId: 0))
    }

    func testPicksTvArtResizedToLandscapeSize() {
        let url = TVArt.pickArtwork(fromLookup: lookup(#""artworkUrl512":"\#(tv)""#))
        XCTAssertEqual(url?.lastPathComponent, "1280x768bb.jpg")
        XCTAssertEqual(url?.host, "is1-ssl.mzstatic.com")
        XCTAssertTrue(url?.path.contains("App_Icon-marketing.lsr") ?? false)
    }

    func testFallsBackToSmallerFieldWhenLargerIsMissing() {
        XCTAssertNotNil(TVArt.pickArtwork(fromLookup: lookup(#""artworkUrl60":"\#(tv)""#)))
    }

    func testRefusesPhoneIconWrongHostAndMalformed() {
        XCTAssertNil(TVArt.pickArtwork(fromLookup: lookup(#""artworkUrl512":"\#(phone)""#)))
        XCTAssertNil(TVArt.pickArtwork(fromLookup: lookup(#""artworkUrl512":"https://img.example.test/x.lsr/512x512bb.jpg""#)))
        XCTAssertNil(TVArt.pickArtwork(fromLookup: lookup(#""artworkUrl512":"http://is1-ssl.mzstatic.com/x.lsr/512x512bb.jpg""#)))
        XCTAssertNil(TVArt.pickArtwork(fromLookup: lookup(#""artworkUrl512":"https://is1-ssl.mzstatic.com/x.lsr/cover.jpg""#)))
        XCTAssertNil(TVArt.pickArtwork(fromLookup: Data(#"{"resultCount":0,"results":[]}"#.utf8)))
        XCTAssertNil(TVArt.pickArtwork(fromLookup: Data("nope".utf8)))
        XCTAssertNil(TVArt.pickArtwork(fromLookup: Data(count: TVArt.maxLookupBytes + 1)))
    }

    func testArtHostMustBeTheCDNExactlyOrASubdomain() {
        func ok(_ s: String) -> Bool { TVArt.isAllowedArtURL(URL(string: s)!) }
        XCTAssertTrue(ok("https://is5-ssl.mzstatic.com/a.jpg"))
        XCTAssertTrue(ok("https://mzstatic.com/a.jpg"))
        XCTAssertFalse(ok("https://evilmzstatic.com/a.jpg"))
        XCTAssertFalse(ok("https://mzstatic.com.example.test/a.jpg"))
        XCTAssertFalse(ok("https://user@is1-ssl.mzstatic.com/a.jpg"))
        XCTAssertFalse(ok("https://is1-ssl.mzstatic.com:8443/a.jpg"))
    }

    func testLandscapeTileCheck() {
        XCTAssertTrue(TVArt.isUsableTile(pixelWidth: 1280, pixelHeight: 768))
        XCTAssertTrue(TVArt.isUsableTile(pixelWidth: 800, pixelHeight: 480))
        XCTAssertFalse(TVArt.isUsableTile(pixelWidth: 512, pixelHeight: 512), "square")
        XCTAssertFalse(TVArt.isUsableTile(pixelWidth: 480, pixelHeight: 800), "portrait")
        XCTAssertFalse(TVArt.isUsableTile(pixelWidth: 300, pixelHeight: 180), "too small")
        XCTAssertFalse(TVArt.isUsableTile(pixelWidth: 8000, pixelHeight: 4800), "too large")
        XCTAssertFalse(TVArt.isUsableTile(pixelWidth: 1280, pixelHeight: 0))
    }

    // MARK: EdgeColor

    private func image(_ w: Int, _ h: Int, edge: (UInt8, UInt8, UInt8), center: (UInt8, UInt8, UInt8), inset: Int = 6) -> [UInt8] {
        var px: [UInt8] = []
        for y in 0..<h { for x in 0..<w {
            let inside = x >= inset && x < w - inset && y >= inset && y < h - inset
            let c = inside ? center : edge
            px += [c.0, c.1, c.2, 255]
        } }
        return px
    }

    func testDominantEdgeIgnoresTheMiddle() {
        let px = image(40, 24, edge: (200, 20, 30), center: (255, 255, 255))
        let c = EdgeColor.dominant(rgba: px, width: 40, height: 24)
        XCTAssertEqual(c?.r ?? 0, 200.0 / 255, accuracy: 0.01)
        XCTAssertEqual(c?.g ?? 0, 20.0 / 255, accuracy: 0.01)
    }

    func testDominantEdgeIgnoresTransparentPixelsAndBadInput() {
        var px = image(10, 10, edge: (10, 20, 30), center: (0, 0, 0))
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 0 }
        XCTAssertNil(EdgeColor.dominant(rgba: px, width: 10, height: 10))
        XCTAssertNil(EdgeColor.dominant(rgba: [1, 2, 3], width: 10, height: 10))
        XCTAssertNil(EdgeColor.dominant(rgba: [], width: 0, height: 0))
    }

    func testMajorityEdgeColorWins() {
        var px = image(20, 20, edge: (0, 0, 255), center: (0, 0, 0))
        for x in 0..<20 { for y in 0..<2 { let i = (y * 20 + x) * 4; px[i] = 255; px[i + 2] = 0 } }   // a red top strip
        let c = EdgeColor.dominant(rgba: px, width: 20, height: 20)
        XCTAssertGreaterThan(c?.b ?? 0, 0.9)
    }

    func testHexColor() {
        XCTAssertEqual(RGB(hex: "#FF0000"), RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(RGB(hex: "00ff00"), RGB(r: 0, g: 1, b: 0))
        XCTAssertNil(RGB(hex: "#FFF"))
        XCTAssertNil(RGB(hex: "#GGGGGG"))
    }

    // MARK: TileLayout

    func testTileIsFiveByThreeWithTwelvePointCorners() {
        XCTAssertEqual(TileLayout.width / TileLayout.height, TVArt.aspect, accuracy: 0.001)
        XCTAssertEqual(TileLayout.cornerRadius(tileWidth: 400), 12, accuracy: 0.001)
    }

    func testLogoIsCenteredFittedAndNotMagnifiedPastLimit() {
        let r = TileLayout.logoRect(logo: (512, 512), tile: (400, 240), fraction: 0.6)!
        XCTAssertEqual(r.h, 144, accuracy: 0.001)
        XCTAssertEqual(r.w, 144, accuracy: 0.001)
        XCTAssertEqual(r.x, 128, accuracy: 0.001)
        XCTAssertEqual(r.y, 48, accuracy: 0.001)
        let tiny = TileLayout.logoRect(logo: (20, 20), tile: (400, 240))!
        XCTAssertEqual(tiny.w, 40, accuracy: 0.001, "at most 2x")
        XCTAssertNil(TileLayout.logoRect(logo: (0, 10), tile: (400, 240)))
    }

    func testTiltFollowsPointerAndClamps() {
        XCTAssertEqual(TileLayout.tilt(pointerX: 0, pointerY: 0).aroundY, 0)
        XCTAssertEqual(TileLayout.tilt(pointerX: 1, pointerY: 0).aroundY, TileLayout.maxTilt)
        XCTAssertEqual(TileLayout.tilt(pointerX: 9, pointerY: -9).aroundY, TileLayout.maxTilt)
        XCTAssertEqual(TileLayout.tilt(pointerX: 0, pointerY: 1).aroundX, -TileLayout.maxTilt, "pointer low tips the bottom toward you")
        XCTAssertEqual(TileLayout.sheenCenter(pointerX: -1, pointerY: 1).x, 0)
        XCTAssertEqual(TileLayout.sheenCenter(pointerX: -1, pointerY: 1).y, 1)
    }

    // MARK: Catalog fields

    func testCatalogCarriesStoreIdsAndBrandColorsAsDataOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try AppCatalog.parse(Data(contentsOf: root.appendingPathComponent("apps/catalog.json")))
        for id in ["netflix", "hulu", "disney", "prime", "max", "youtube", "appletv", "plex"] {
            let app = try XCTUnwrap(catalog.app(id: id), id)
            XCTAssertGreaterThan(app.appStoreId ?? 0, 0, id)
            XCTAssertNotNil(app.brandColor.flatMap(RGB.init(hex:)), id)
        }
    }

    func testCatalogRejectsBadStoreIdOrColor() {
        XCTAssertThrowsError(try AppCatalog.parse(Data(#"{"version":1,"apps":[{"id":"x","name":"X","kind":"system","appStoreId":0}]}"#.utf8)))
        XCTAssertThrowsError(try AppCatalog.parse(Data(#"{"version":1,"apps":[{"id":"x","name":"X","kind":"system","brandColor":"red"}]}"#.utf8)))
        XCTAssertNoThrow(try AppCatalog.parse(Data(##"{"version":1,"apps":[{"id":"x","name":"X","kind":"system","appStoreId":5,"brandColor":"#112233"}]}"##.utf8)))
    }
}
