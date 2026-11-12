// Owns: finding the glyph inside an icon image: the box around what is not
// the icon's own background, so a tile can show the logo large instead of a
// small icon-in-a-card. Handles a gradient background, transparent padding,
// and a rounded square sitting on a solid border (trimmed in a second pass).
// Pure: works on RGBA bytes the app has already decoded.

import Foundation

public enum LogoTrim {
    /// How far (largest channel difference, 0...1) a pixel must be from the
    /// background color to count as glyph. Above a soft gradient's spread.
    public static let tolerance = 0.16
    /// A first-pass box at least this share of both sides looks like a frame
    /// (a square on a border) rather than a glyph, so it is checked once more inside.
    static let frameShare = 0.7
    /// The second pass starts this far in from the frame, clear of rounded corners.
    static let frameInset = 0.1
    /// The frame's inner edge must be this solid a color to be trusted.
    static let solidShare = 0.85

    /// The glyph's box, or nil when the image is malformed or has no glyph (one flat color).
    /// `rgba` is 4 bytes per pixel, row by row.
    public static func glyphBounds(rgba: [UInt8], width: Int, height: Int) -> PixelRect? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, rgba.count >= width * height * 4 else { return nil }
        let whole = PixelRect(x: 0, y: 0, w: width, h: height)
        guard let first = bounds(rgba: rgba, width: width, in: whole, height: height) else { return nil }
        let side = Double(min(width, height))
        guard Double(first.w) >= side * frameShare, Double(first.h) >= side * frameShare else { return first }
        let inset = Int((Double(min(first.w, first.h)) * frameInset).rounded())
        let inner = PixelRect(x: first.x + inset, y: first.y + inset, w: first.w - 2 * inset, h: first.h - 2 * inset)
        guard inner.w > 8, inner.h > 8,
              let ring = EdgeColor.dominantSolid(rgba: rgba, width: width, height: height, region: inner, border: 2),
              ring.share >= solidShare,
              let second = bounds(rgba: rgba, width: width, in: inner, height: height) else { return first }
        return second
    }

    /// The box of pixels in `region` that differ from the region's own edge color
    /// (every opaque pixel when that edge is transparent).
    static func bounds(rgba: [UInt8], width: Int, in region: PixelRect, height: Int) -> PixelRect? {
        guard region.w > 0, region.h > 0, region.x >= 0, region.y >= 0,
              region.x + region.w <= width, region.y + region.h <= height else { return nil }
        let edge = EdgeColor.dominantSolid(rgba: rgba, width: width, height: height, region: region, border: 2)?.color
        var rows = [Int](repeating: 0, count: region.h), cols = [Int](repeating: 0, count: region.w)
        let limit = tolerance * 255
        for y in 0..<region.h {
            for x in 0..<region.w {
                let i = ((region.y + y) * width + region.x + x) * 4
                guard rgba[i + 3] >= 128 else { continue }
                if let edge {
                    let d = max(abs(Double(rgba[i]) - edge.r * 255), abs(Double(rgba[i + 1]) - edge.g * 255),
                                abs(Double(rgba[i + 2]) - edge.b * 255))
                    if d <= limit { continue }
                }
                rows[y] += 1; cols[x] += 1
            }
        }
        // A line needs a few glyph pixels, so a speck of noise does not stretch the box.
        let need = max(2, min(region.w, region.h) / 200)
        guard let top = rows.firstIndex(where: { $0 >= need }), let bottom = rows.lastIndex(where: { $0 >= need }),
              let left = cols.firstIndex(where: { $0 >= need }), let right = cols.lastIndex(where: { $0 >= need }) else { return nil }
        return PixelRect(x: region.x + left, y: region.y + top, w: right - left + 1, h: bottom - top + 1)
    }
}
