// Owns: the list of streaming services the shell can open, and how each one
// must be loaded (address + browser identity). Does not own how it is shown.

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
    public static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    // YouTube only serves its TV ("leanback") interface to TV-like browsers.
    public static let smartTV = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/6.0 TV Safari/538.1"
}

public enum ServiceCatalog {
    // Spike 2026-11-11 (WKWebView on the M2 mini): Netflix 4K, YouTube /tv 1440p,
    // Prime 1080p, Disney+ 720p. Max untested.
    public static let all: [Service] = [
        Service(id: "plex", name: "Plex", url: URL(string: "https://app.plex.tv/desktop")!, userAgent: UserAgents.safari,
                hasTVInterface: false, nativeAppBundleID: "tv.plex.htpc"),
        // tv.apple.com, not the Mac TV app: the app only lets a remote move
        // through its sidebar, while the site is reachable with spatial navigation.
        Service(id: "appletv", name: "Apple TV", url: URL(string: "https://tv.apple.com/")!, userAgent: UserAgents.safari, hasTVInterface: false),
        Service(id: "netflix", name: "Netflix", url: URL(string: "https://www.netflix.com/browse")!, userAgent: UserAgents.safari, hasTVInterface: false),
        Service(id: "youtube", name: "YouTube", url: URL(string: "https://www.youtube.com/tv")!, userAgent: UserAgents.smartTV, hasTVInterface: true),
        Service(id: "disney", name: "Disney+", url: URL(string: "https://www.disneyplus.com/")!, userAgent: UserAgents.safari, hasTVInterface: false),
        // Disney announced folding Hulu into Disney+ in 2026; hulu.com still serves
        // standalone subscribers, and bundle profiles also show inside Disney+.
        Service(id: "hulu", name: "Hulu", url: URL(string: "https://www.hulu.com/hub/home")!, userAgent: UserAgents.safari, hasTVInterface: false),
        Service(id: "max",name: "Max", url: URL(string: "https://play.max.com/")!, userAgent: UserAgents.safari, hasTVInterface: false),
        Service(id: "prime", name: "Prime Video", url: URL(string: "https://www.primevideo.com/")!, userAgent: UserAgents.safari, hasTVInterface: false,
                // The hero's "Move back/forward to title N" and each row's
                // "previous/next 5 titles" arrows: the rows scroll by themselves.
                navigationSkip: #"button[aria-label^="Move back to title"],button[aria-label^="Move forward to title"],button[aria-label^="next "][aria-label$=" titles"],button[aria-label^="previous "][aria-label$=" titles"]"#),
    ]
}
