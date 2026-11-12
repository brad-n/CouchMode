// Owns: the arithmetic of an Apple TV style app tile: its size at a screen
// scale, corner radius, where a logo sits on a full-bleed background and what that background looks like, and
// the parallax tilt and sheen position that follow a focus "pointer".
// Pure: HomeView's tile draws what these return.

import Foundation

public enum TileLayout {
    /// A tvOS app icon: 400 x 240 points.
    public static let width: Double = 400
    public static let height: Double = 240
    /// Lift on focus.
    public static let focusScale: Double = 1.1
    /// ~12 pt at 400 pt wide.
    public static let cornerRatio: Double = 0.03
    /// The most a tile tilts, in degrees.
    public static let maxTilt: Double = 6
    /// Room under a tile for its name, in points.
    public static let labelHeight: Double = 64

    public static func cornerRadius(tileWidth: Double) -> Double { tileWidth * cornerRatio }

    /// Where a logo of `logo` size sits when fitted inside a `fraction` of the
    /// tile, centered: never magnified past its own pixels (`maxMagnify`).
    public static func logoRect(logo: (w: Double, h: Double), tile: (w: Double, h: Double),
                                fraction: Double = 0.62, maxMagnify: Double = 2) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard logo.w > 0, logo.h > 0, tile.w > 0, tile.h > 0, fraction > 0, fraction <= 1 else { return nil }
        let k = min(tile.w * fraction / logo.w, tile.h * fraction / logo.h, maxMagnify)
        let (w, h) = (logo.w * k, logo.h * k)
        return ((tile.w - w) / 2, (tile.h - h) / 2, w, h)
    }

    /// The margin of background kept around a trimmed glyph, as a share of its shorter side, that the
    /// tile fades out so the crop's edge does not show against the tile's own gradient.
    public static let glyphFeather: Double = 0.08

    /// Where a trimmed glyph sits on a full-bleed fallback tile, centered: at most
    /// `heightFraction` of the tile's height and `widthFraction` of its width
    /// (a wide wordmark is limited by width), and never magnified past
    /// `maxMagnify` times its own pixels, so a small source stays small, not blurry.
    public static func glyphRect(glyph: (w: Double, h: Double), tile: (w: Double, h: Double),
                                 heightFraction: Double = 0.6, widthFraction: Double = 0.7,
                                 maxMagnify: Double = 2) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard glyph.w > 0, glyph.h > 0, tile.w > 0, tile.h > 0, heightFraction > 0, heightFraction <= 1,
              widthFraction > 0, widthFraction <= 1, maxMagnify > 0 else { return nil }
        let k = min(tile.h * heightFraction / glyph.h, tile.w * widthFraction / glyph.w, maxMagnify)
        let (w, h) = (glyph.w * k, glyph.h * k)
        return ((tile.w - w) / 2, (tile.h - h) / 2, w, h)
    }

    /// The top and bottom colors of a fallback tile's background, from the icon's own
    /// top and bottom edge colors (so the trimmed glyph's backdrop matches the tile),
    /// eased a touch lighter above and darker below so even a flat icon gets some depth.
    public static func backdrop(top: RGB, bottom: RGB) -> (top: RGB, bottom: RGB) {
        func mix(_ c: RGB, _ to: Double, _ t: Double) -> RGB {
            RGB(r: c.r + (to - c.r) * t, g: c.g + (to - c.g) * t, b: c.b + (to - c.b) * t)
        }
        return (mix(top, 1, 0.02), mix(bottom, 0, 0.12))
    }

    /// Rotation for a pointer position in -1...1 on each axis (0 = center): the
    /// tile tips toward the pointer. Out-of-range input is clamped.
    public static func tilt(pointerX x: Double, pointerY y: Double) -> (aroundY: Double, aroundX: Double) {
        let cx = max(-1, min(1, x)), cy = max(-1, min(1, y))
        return (cx * maxTilt, -cy * maxTilt)
    }

    /// Where the specular highlight's center sits across the tile, 0...1 on each axis.
    public static func sheenCenter(pointerX x: Double, pointerY y: Double) -> (x: Double, y: Double) {
        ((max(-1, min(1, x)) + 1) / 2, (max(-1, min(1, y)) + 1) / 2)
    }
}
