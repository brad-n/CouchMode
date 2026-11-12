// Owns: what a streaming service is for the shell (address + browser identity)
// and how services are made from the app catalog. Does not own the list
// itself (apps/catalog.json) or how a service is shown.

import Foundation

public struct Service: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let url: URL
    public let userAgent: String
    /// The site ships its own remote-friendly TV interface, so arrow keys go
    /// straight to the site instead of our spatial-navigation layer.
    public let hasTVInterface: Bool
    /// A native TV app to launch instead of the website when it's installed
    /// (bundle identifier), e.g. Plex HTPC.
    public var nativeAppBundleID: String? = nil
    /// Elements our spatial navigation never lands on (a CSS selector):
    /// controls a TV interface doesn't have, such as carousel arrows on a
    /// site whose rows already scroll to the focused title.
    public var navigationSkip: String? = nil
}

public enum UserAgents {
    /// The fallback when the installed Safari's version can't be read; see `SafariUserAgent`.
    public static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    // YouTube only serves its TV ("leanback") interface to TV-like browsers.
    public static let smartTV = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/6.0 TV Safari/538.1"
}

public enum ServiceCatalog {
    /// The apps in the catalog that open a website or a native app, as services,
    /// with the Safari identity the app resolved at launch. Catalog order.
    public static func make(from apps: [CatalogApp], safariUserAgent safari: String) -> [Service] {
        apps.compactMap { app in
            guard app.kind == .stream || app.kind == .native,
                  let site = app.site, let url = URL(string: site.url) else { return nil }
            return Service(id: app.id, name: app.name, url: url, userAgent: userAgent(site.userAgent, safari: safari),
                           hasTVInterface: site.tvInterface, nativeAppBundleID: app.native?.bundleId,
                           navigationSkip: site.navigationSkip)
        }
    }

    /// `safari` and `smartTV` are names for the two identities we know; anything else is literal.
    static func userAgent(_ token: String, safari: String) -> String {
        switch token {
        case "safari": return safari
        case "smartTV": return UserAgents.smartTV
        default: return token
        }
    }
}
