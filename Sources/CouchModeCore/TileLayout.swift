// Owns: the arithmetic of an Apple TV style app tile: its size at a screen
// scale, corner radius, where a logo sits on a full-bleed background, and
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
