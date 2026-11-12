// Owns: deciding from the service page's address whether the person has left the player page.
import Foundation

public enum PlayerExit {
    /// Labels that make up a site's registrable domain (hulu.com, netflix.com).
    private static let registrableLabels = 2

    /// True when `current` is on the same site as `playURL` (same host or a subdomain of the
    /// same registrable domain) and its first path component differs from the play address's
    /// (`watch` on Netflix and Hulu). A nil address, another site, or a play address with no
    /// path component is never "left".
    public static func hasLeftPlayer(playURL: URL, current: URL?) -> Bool {
        guard let current, let playHost = playURL.host?.lowercased(), let host = current.host?.lowercased(),
              let playFirst = firstComponent(of: playURL),
              registrable(playHost) == registrable(host) else { return false }
        return firstComponent(of: current) != playFirst
    }

    /// True when `current` is on the player page itself (same site, same first path component).
    /// Leaving only counts after this has been seen, since the page the handoff replaces
    /// (the site's home) also differs from the play address.
    public static func isOnPlayer(playURL: URL, current: URL?) -> Bool {
        guard let current, let playHost = playURL.host?.lowercased(), let host = current.host?.lowercased(),
              let playFirst = firstComponent(of: playURL),
              registrable(playHost) == registrable(host) else { return false }
        return firstComponent(of: current) == playFirst
    }

    private static func firstComponent(of url: URL) -> String? {
        url.pathComponents.first { $0 != "/" }
    }

    private static func registrable(_ host: String) -> String {
        host.split(separator: ".").suffix(registrableLabels).joined(separator: ".")
    }
}
