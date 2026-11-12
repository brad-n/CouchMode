import XCTest
@testable import CouchModeCore

final class LogoTrimTests: XCTestCase {
    /// A synthetic image: every pixel from `paint(x, y)` as (r, g, b, a).
    private func image(_ w: Int, _ h: Int, _ paint: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<h { for x in 0..<w { let p = paint(x, y); out += [p.0, p.1, p.2, p.3] } }
        return out
    }

    private func inBox(_ x: Int, _ y: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }

    func testGlyphOnVerticalGradientIsBoxed() {
        let w = 200, h = 200
        let px = image(w, h) { x, y in
            if self.inBox(x, y, 40, 70, 160, 130) { return (255, 255, 255, 255) }
            let v = UInt8(40 - y * 25 / h)   // 40 at top to ~16 at bottom
            return (v, v, v, 255)
        }
        XCTAssertEqual(LogoTrim.glyphBounds(rgba: px, width: w, height: h), PixelRect(x: 40, y: 70, w: 120, h: 60))
    }

    func testTransparentPaddingIsTrimmed() {
        let w = 100, h = 100
        let px = image(w, h) { x, y in self.inBox(x, y, 30, 20, 70, 80) ? (200, 30, 30, 255) : (0, 0, 0, 0) }
        XCTAssertEqual(LogoTrim.glyphBounds(rgba: px, width: w, height: h), PixelRect(x: 30, y: 20, w: 40, h: 60))
    }

    func testRoundedSquareOnSolidBorderTrimsToTheGlyph() {
        let w = 300, h = 300
        // White border; an 80% blue square with cut corners; a white glyph in the middle.
        let px = image(w, h) { x, y in
            if self.inBox(x, y, 100, 120, 200, 180) { return (255, 255, 255, 255) }
            let inSquare = self.inBox(x, y, 30, 30, 270, 270)
            let corner = (x < 50 || x >= 250) && (y < 50 || y >= 250) && !(self.inBox(x, y, 40, 40, 260, 260))
            return inSquare && !corner ? (20, 60, 200, 255) : (255, 255, 255, 255)
        }
        XCTAssertEqual(LogoTrim.glyphBounds(rgba: px, width: w, height: h), PixelRect(x: 100, y: 120, w: 100, h: 60))
    }

    func testBigGlyphFillingTheImageIsNotClippedByTheFrameCheck() {
        let w = 200, h = 200
        // Dark background, a glyph covering 90% of both sides with a busy (not solid) inner area.
        let px = image(w, h) { x, y in
            guard self.inBox(x, y, 10, 10, 190, 190) else { return (20, 20, 20, 255) }
            return (x + y) % 2 == 0 ? (255, 255, 255, 255) : (200, 40, 40, 255)
        }
        XCTAssertEqual(LogoTrim.glyphBounds(rgba: px, width: w, height: h), PixelRect(x: 10, y: 10, w: 180, h: 180))
    }

    func testFlatImageHasNoGlyph() {
        let px = image(50, 50) { _, _ in (30, 30, 30, 255) }
        XCTAssertNil(LogoTrim.glyphBounds(rgba: px, width: 50, height: 50))
    }

    func testSingleStrayPixelIsIgnored() {
        let px = image(100, 100) { x, y in x == 5 && y == 5 ? (255, 255, 255, 255) : (30, 30, 30, 255) }
        XCTAssertNil(LogoTrim.glyphBounds(rgba: px, width: 100, height: 100))
    }

    func testMalformedInputGivesNil() {
        XCTAssertNil(LogoTrim.glyphBounds(rgba: [], width: 10, height: 10))
        XCTAssertNil(LogoTrim.glyphBounds(rgba: [0, 0, 0, 255], width: 0, height: 1))
        XCTAssertNil(LogoTrim.glyphBounds(rgba: [UInt8](repeating: 0, count: 40), width: 5000, height: 1))
    }

    func testEdgeSolidShareTellsSolidFromBusy() {
        let solid = image(40, 40) { _, _ in (10, 10, 10, 255) }
        let busy = image(40, 40) { x, y in (x + y) % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        XCTAssertEqual(EdgeColor.dominantSolid(rgba: solid, width: 40, height: 40, region: nil, border: 2)?.share ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(EdgeColor.dominantSolid(rgba: busy, width: 40, height: 40, region: nil, border: 2)?.share ?? 0, 0.5, accuracy: 0.05)
        XCTAssertNil(EdgeColor.dominantSolid(rgba: solid, width: 40, height: 40, region: PixelRect(x: 30, y: 30, w: 20, h: 20)))
    }
}
