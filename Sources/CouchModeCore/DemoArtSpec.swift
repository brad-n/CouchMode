// Owns: the description of one piece of generated demo artwork (what kind it
// is, which invented title it carries) and everything derived from it with no
// drawing: a stable seed, a motif, a palette, pixel sizes and the
// couchmode-demo:// address that names it. The app target draws it with
// CoreGraphics (DemoArtRenderer). Nothing here is a photo, a still or anyone's
// artwork: demo art is original shapes and colors computed from the title.

import Foundation

public enum DemoArtKind: String, CaseIterable, Hashable, Sendable {
    /// 16:9 card or tile with the title written on it.
    case tile
    /// A wide full-screen backdrop; no text (the screen writes its own).
    case hero
    /// A small square (profile pictures): the title's first letter.
    case square
}

public enum DemoMotif: Int, CaseIterable, Sendable {
    case sunrise, waves, hills, rings, lattice, beams, orbit, crescent
}

public struct DemoColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// From hue (any number, wraps at 1), saturation and brightness (0...1).
    public init(hue: Double, saturation: Double, brightness: Double) {
        let wrapped = hue - hue.rounded(.down)
        let h = wrapped * 6
        let sector = min(5, Int(h))
        let f = h - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: (red, green, blue) = (brightness, t, p)
        case 1: (red, green, blue) = (q, brightness, p)
        case 2: (red, green, blue) = (p, brightness, t)
        case 3: (red, green, blue) = (p, q, brightness)
        case 4: (red, green, blue) = (t, p, brightness)
        default: (red, green, blue) = (brightness, p, q)
        }
    }
}

public struct DemoPalette: Equatable, Sendable {
    /// Deep end of the background gradient.
    public let dark: DemoColor
    /// Middle of the background gradient.
    public let mid: DemoColor
    /// Soft shapes.
    public let light: DemoColor
    /// One bright accent (a sun, a moon, a beam).
    public let accent: DemoColor
}

public struct DemoArtSpec: Hashable, Sendable {
    public static let scheme = "couchmode-demo"

    public let kind: DemoArtKind
    /// The invented title the art carries (also what decides its look).
    public let title: String

    public init(kind: DemoArtKind, title: String) {
        self.kind = kind
        self.title = String(title.prefix(80))
    }

    /// FNV-1a over the title's UTF-8: the same on every run and machine
    /// (Swift's own hashValue is randomized per launch).
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public var seed: UInt64 { Self.fnv1a(title) }

    /// Repeatable pseudo-random number in 0..<1: number `index` of this
    /// art's sequence, for placing shapes.
    public func unit(_ index: Int) -> Double {
        var x = seed &+ UInt64(truncatingIfNeeded: index) &* 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    public var motif: DemoMotif { DemoMotif.allCases[Int(seed % UInt64(DemoMotif.allCases.count))] }

    public var palette: DemoPalette {
        let hue = unit(100)
        let shift = 0.07 + unit(101) * 0.12
        let accentHue = hue + 0.45 + unit(102) * 0.15
        return DemoPalette(
            dark: DemoColor(hue: hue, saturation: 0.62, brightness: 0.16 + unit(103) * 0.08),
            mid: DemoColor(hue: hue + shift, saturation: 0.55, brightness: 0.42 + unit(104) * 0.14),
            light: DemoColor(hue: hue - shift, saturation: 0.35, brightness: 0.85),
            accent: DemoColor(hue: accentHue, saturation: 0.50, brightness: 0.98))
    }

    /// Size of the picture to draw.
    public var pixelSize: (width: Int, height: Int) {
        switch kind {
        case .tile: return (640, 360)
        case .hero: return (1920, 1080)
        case .square: return (256, 256)
        }
    }

    /// couchmode-demo://art/<kind>?title=...
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "art"
        c.path = "/" + kind.rawValue
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        return c.url ?? URL(string: "\(Self.scheme)://art")!
    }

    /// The spec a demo address names; nil for any other address.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "art",
              let kind = DemoArtKind(rawValue: String(url.path.dropFirst())),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let title = comps.queryItems?.first(where: { $0.name == "title" })?.value else { return nil }
        self.init(kind: kind, title: title)
    }
}
