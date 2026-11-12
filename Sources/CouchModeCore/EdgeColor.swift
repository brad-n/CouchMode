// Owns: sampling the dominant color along the edge of an image, so a small
// logo can sit on a full-bleed background that matches it. Pure: works on
// RGBA bytes the app has already decoded.

import Foundation

public struct RGB: Equatable, Sendable {
    public let r: Double, g: Double, b: Double   // 0...1
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// "#RRGGBB" (or without the #), or nil.
    public init?(hex: String) {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, let v = UInt32(text, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

public enum EdgeColor {
    /// The most common color on a `border`-pixel frame around the image, as
    /// the average of the pixels in the winning bucket. Transparent pixels
    /// are ignored; nil when the frame is all transparent or the input is malformed.
    /// `rgba` is 4 bytes per pixel, row by row.
    public static func dominant(rgba: [UInt8], width: Int, height: Int, border: Int = 4) -> RGB? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, rgba.count >= width * height * 4, border > 0 else { return nil }
        struct Bucket { var n = 0, r = 0, g = 0, b = 0 }
        var buckets: [Int: Bucket] = [:]
        func add(_ x: Int, _ y: Int) {
            let i = (y * width + x) * 4
            guard rgba[i + 3] >= 200 else { return }
            let (r, g, b) = (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var bucket = buckets[key] ?? Bucket()
            bucket.n += 1; bucket.r += r; bucket.g += g; bucket.b += b
            buckets[key] = bucket
        }
        let t = min(border, (min(width, height) + 1) / 2)
        for y in 0..<height {
            if y < t || y >= height - t {
                for x in 0..<width { add(x, y) }
            } else {
                for x in 0..<min(t, width) { add(x, y) }
                for x in max(t, width - t)..<width { add(x, y) }
            }
        }
        guard let best = buckets.max(by: { $0.value.n != $1.value.n ? $0.value.n < $1.value.n : $0.key > $1.key })?.value else { return nil }
        let n = Double(best.n) * 255
        return RGB(r: Double(best.r) / n, g: Double(best.g) / n, b: Double(best.b) / n)
    }
}
