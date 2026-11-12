// Owns: choosing a service's tvOS app artwork from Apple's public catalog:
// the lookup address, which hosts may be fetched, picking the landscape art
// out of a lookup response, and checking a downloaded image is a usable
// landscape tile. Pure: the fetching and caching is the app's ServiceIcons.
// No artwork is stored anywhere in the repo; only app store ids (apps/catalog.json).

import Foundation

public enum TVArt {
    /// tvOS app icons are 400x240 points: 5:3.
    public static let aspect: Double = 5.0 / 3.0
    public static let aspectTolerance: Double = 0.06
    /// Smaller than this looks soft on a TV tile (a tile is 400 points wide, on a 2x screen at most).
    public static let minWidth = 400
    public static let maxWidth = 4096
    /// The largest art the catalog serves for these icons; asking for more returns this.
    public static let requestSize = "1280x768"
    public static let maxLookupBytes = 300_000

    public static let lookupHost = "itunes.apple.com"
    /// Apple's artwork CDN (is1-ssl.mzstatic.com, is2-ssl..., and so on).
    public static let artHostSuffix = "mzstatic.com"

    /// The lookup that returns an app's Apple TV (tvOS) artwork, for an app store id.
    public static func lookupURL(appStoreId: Int) -> URL? {
        guard appStoreId > 0 else { return nil }
        return URL(string: "https://\(lookupHost)/lookup?id=\(appStoreId)&entity=tvSoftware&country=us")
    }

    /// Only https addresses on Apple's artwork CDN are fetched.
    public static func isAllowedArtURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.port == nil, let host = url.host?.lowercased() else { return false }
        return host == artHostSuffix || host.hasSuffix("." + artHostSuffix)
    }

    /// The tvOS art address in a lookup response, resized to `requestSize`, or nil.
    /// The lookup's own icon fields are the iPhone icon unless the response is
    /// for the tvOS entity; tvOS art is a layered-image ("lsr") asset, so a
    /// path that is not one is a phone icon and is refused.
    public static func pickArtwork(fromLookup data: Data) -> URL? {
        guard data.count <= maxLookupBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]], let first = results.first else { return nil }
        for key in ["artworkUrl512", "artworkUrl100", "artworkUrl60"] {
            guard let text = first[key] as? String, let url = URL(string: text), isAllowedArtURL(url),
                  url.path.contains(".lsr/"), let sized = resized(url) else { continue }
            return sized
        }
        return nil
    }

    /// The same asset at `requestSize`: the last path component is "<w>x<h>bb.<ext>".
    static func resized(_ url: URL) -> URL? {
        let last = url.lastPathComponent
        guard last.range(of: #"^\d+x\d+bb\.(jpg|png)$"#, options: .regularExpression) != nil else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("\(requestSize)bb.jpg")
    }

    /// Whether a downloaded image is landscape tile art of a usable size.
    public static func isUsableTile(pixelWidth w: Int, pixelHeight h: Int) -> Bool {
        guard w >= minWidth, w <= maxWidth, h > 0 else { return false }
        return abs(Double(w) / Double(h) - aspect) <= aspect * aspectTolerance
    }
}
