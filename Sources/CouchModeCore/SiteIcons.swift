// Owns: choosing a service's own icon from what its site declares (page
// links and the web app manifest), and the weekly cache-freshness rule.
// Pure: fetching and caching the file is the app's ServiceIcons.

import Foundation

public struct IconCandidate: Equatable, Sendable {
    public enum Kind: Sendable { case appleTouch, manifest, icon }
    public let href: String
    /// The largest side the site declares, if it declares one.
    public let size: Int?
    public let type: String?
    public let kind: Kind
    /// A maskable icon: the glyph sits in a safe zone inside extra background, so it
    /// needs trimming (LogoTrim) before it is shown large.
    public let padded: Bool
    public init(href: String, size: Int?, type: String?, kind: Kind, padded: Bool = false) {
        self.href = href; self.size = size; self.type = type; self.kind = kind; self.padded = padded
    }
}

public enum SiteIcons {
    /// Smaller than this looks soft on a TV tile.
    public static let minSide = 180
    /// Larger than this is not an icon (a guard on what is downloaded and decoded).
    public static let maxSide = 2048

    /// Some sites put a megabyte of script ahead of the manifest link.
    public static let maxMarkup = 4_000_000

    public struct Page: Equatable, Sendable {
        public var icons: [IconCandidate]
        public var manifest: String?
    }

    /// The icon and manifest links in a page's markup.
    public static func parsePage(_ html: String) -> Page {
        var page = Page(icons: [], manifest: nil)
        let tag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        let attr = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
        let ns = html as NSString
        for m in tag.matches(in: html, range: NSRange(location: 0, length: min(ns.length, maxMarkup))) {
            let text = ns.substring(with: m.range) as NSString
            var a: [String: String] = [:]
            for x in attr.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let key = text.substring(with: x.range(at: 1)).lowercased()
                let r = x.range(at: 2).location != NSNotFound ? x.range(at: 2) : x.range(at: 3)
                a[key] = text.substring(with: r).replacingOccurrences(of: "&amp;", with: "&")
            }
            guard let href = a["href"], !href.isEmpty, let rel = a["rel"]?.lowercased() else { continue }
            let words = rel.split(whereSeparator: { $0 == " " }).map(String.init)
            if words.contains("manifest") { page.manifest = page.manifest ?? href; continue }
            let kind: IconCandidate.Kind
            if words.contains("apple-touch-icon") || words.contains("apple-touch-icon-precomposed") { kind = .appleTouch }
            else if words.contains("icon") { kind = .icon }
            else { continue }
            page.icons.append(IconCandidate(href: href, size: largestSide(of: a["sizes"]), type: a["type"], kind: kind))
        }
        return page
    }

    /// The icons a web app manifest lists; maskable-only ones are marked `padded` (they are often the largest).
    public static func parseManifest(_ data: Data) -> [IconCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["icons"] as? [[String: Any]] else { return [] }
        return list.prefix(40).compactMap { item in
            guard let src = item["src"] as? String, !src.isEmpty else { return nil }
            let purpose = (item["purpose"] as? String)?.lowercased().split(separator: " ").map(String.init) ?? []
            let padded = !purpose.isEmpty && !purpose.contains("any")
            return IconCandidate(href: src, size: largestSide(of: item["sizes"] as? String), type: item["type"] as? String,
                                 kind: .manifest, padded: padded)
        }
    }

    /// "192x192 512x512" gives 512; "any" or nothing gives nil.
    public static func largestSide(of sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let sides = sizes.lowercased().split(separator: " ").compactMap { part -> Int? in
            let xy = part.split(separator: "x")
            guard xy.count == 2, let w = Int(xy[0]), let h = Int(xy[1]) else { return nil }
            return max(w, h)
        }
        return sides.max()
    }

    /// The best icon: https, PNG, not declared too small; the largest wins
    /// (so 512 and up are preferred, padded or not: the app trims padding), then
    /// an unpadded icon, then touch icon over manifest over plain icon. An icon with no declared size ranks last; the app checks
    /// its real size once downloaded.
    public static func best(_ candidates: [IconCandidate], relativeTo base: URL) -> URL? {
        func rank(_ k: IconCandidate.Kind) -> Int { k == .appleTouch ? 2 : k == .manifest ? 1 : 0 }
        let usable: [(URL, IconCandidate)] = candidates.compactMap { c in
            guard let url = URL(string: c.href, relativeTo: base)?.absoluteURL, url.scheme == "https", url.host != nil else { return nil }
            if let size = c.size, size < minSide { return nil }
            if let type = c.type?.lowercased(), !type.isEmpty, type != "image/png" { return nil }
            let ext = url.pathExtension.lowercased()
            if ["svg", "ico", "jpg", "jpeg", "webp", "gif", "avif"].contains(ext) { return nil }
            return (url, c)
        }
        return usable.max { a, b in
            let (sa, sb) = (a.1.size ?? 0, b.1.size ?? 0)
            if sa != sb { return sa < sb }
            return a.1.padded != b.1.padded ? a.1.padded : rank(a.1.kind) < rank(b.1.kind)
        }?.0
    }

    /// Whether a downloaded image is a usable icon.
    public static func isUsable(pixelWidth: Int, pixelHeight: Int) -> Bool {
        min(pixelWidth, pixelHeight) >= minSide && max(pixelWidth, pixelHeight) <= maxSide
    }
}

public enum IconCacheRule {
    public static let maxAge: TimeInterval = 7 * 86_400

    /// A cached icon is reused for a week; a missing or future-dated one is not.
    public static func isFresh(fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < maxAge
    }
}
