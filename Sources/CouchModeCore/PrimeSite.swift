// Owns: what every Prime Video read shares, as a proxy for the signed-in site
// (www.primevideo.com). Learned on a real Mac (2026-11-11): every page the site
// serves (home "/", a title's /detail/<id>, /search/?phrase=) carries its own
// data as JSON in a script tag, <script id="dv-web-page-hydration-data">, at
// init.preparations.body, so a read opens the page and reads that tag; no
// request and no token is involved. A title is /detail/<id>; the same address
// with ?autoplay=1[&t=<seconds>] is the service's play address, and its player
// is not a page of its own: it opens over that page (see PrimeSite.playerShownScript).
// Artwork addresses are Amazon image addresses whose file name takes a size
// modifier: <stem>._SX<width>_.jpg gives a clean image of that width (a row's own
// cover address has a badge overlay composed into it, which this drops).
// This file holds the address builders, the script pieces every read uses (the
// page's data and the one "card" every row, search and detail item is squeezed
// into) and the card -> StreamTitle rule. No I/O here.
//
// A card, the shape parse functions read:
// {"id" (the /detail/ id), "name", "title" (name plus " - Season N" on a season),
//  "type" ("Movie", "TV Show", ...), "year", "rating", "desc", "art" (image address),
//  "pct" (percent watched), "resume" (seconds), "playId" (the /detail/ id of what Play
//  starts; null where the site offers no playback: rent, buy, channel)}

import Foundation

public enum PrimeSite {
    public static let serviceID = "prime"
    /// Largest answer a script hands back, in characters; bigger is treated as unreadable.
    static let maxScriptBytes = 900_000
    static let origin = "https://www.primevideo.com"

    /// The page's own state, or null (a function body piece: `hydration()`).
    static let hydration = #"""
    const hydration = () => {
      const el = document.getElementById("dv-web-page-hydration-data");
      return el ? JSON.parse(el.textContent) : null;
    };
    const bodyOf = () => { const d = hydration(); return d && d.init && d.init.preparations && d.init.preparations.body; };
    """#

    /// JavaScript for the player check: true while Prime's player is open. Prime's
    /// player is an element on the title's page (#dv-web-player); the page marks it
    /// full-screen (class dv-player-fullscreen) while it is open and removes the class
    /// when it closes. Checked on a real Mac: the page's address does not change.
    public static let playerShownScript = #"""
    const player = document.getElementById("dv-web-player");
    return !!player && player.classList.contains("dv-player-fullscreen");
    """#

    // MARK: Addresses

    private static func isPageID(_ id: String) -> Bool {
        (4...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Prime's own page for a /detail/ id.
    public static func pageURL(id: String) -> URL? {
        isPageID(id) ? URL(string: "\(origin)/detail/\(id)") : nil
    }

    /// Prime's play address for a /detail/ id: its page with autoplay, at a position when partly watched.
    public static func playURL(id: String, resumeSeconds: Int?) -> URL? {
        guard isPageID(id) else { return nil }
        let at = resumeSeconds.flatMap { $0 > 0 && $0 < 1_000_000 ? "&t=\($0)" : nil } ?? ""
        return URL(string: "\(origin)/detail/\(id)?autoplay=1\(at)")
    }

    private static let imageDomains = ["media-amazon.com", "ssl-images-amazon.com", "example.invalid"]

    private static func isImageHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return imageDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// An image address at a width: the file's stem with a size modifier and the file's own
    /// extension (the server answers a png file only under .png). Any modifier it already has
    /// is dropped (a row's own cover has a badge overlay composed into its modifier, which can
    /// itself contain slashes).
    public static func imageURL(_ address: String?, width: Int) -> URL? {
        guard let address, let url = StreamJSON.httpsURL(address), isImageHost(url), width > 0, width <= 4096,
              let path = address.range(of: "/images/") else { return nil }
        let rest = address[path.upperBound...]
        guard let dot = rest.lastIndex(of: "."), ["jpg", "jpeg", "png"].contains(rest[rest.index(after: dot)...].lowercased()) else { return nil }
        let ext = rest[rest.index(after: dot)...].lowercased()
        let stem: Substring
        if let modifier = rest.range(of: "._") { stem = rest[..<modifier.lowerBound] }
        else { stem = rest[..<dot] }
        guard !stem.isEmpty, !stem.contains("?"), !stem.hasSuffix("/") else { return nil }
        return URL(string: "\(address[..<path.upperBound])\(stem)._SX\(width)_.\(ext)")
    }

    /// A profile's avatar address as the page shows it: https and an Amazon image host only.
    public static func avatarURL(_ address: String?) -> URL? {
        guard let url = StreamJSON.httpsURL(address), isImageHost(url) else { return nil }
        return url
    }

    // MARK: Script pieces

    /// JavaScript defining `card(entity)`: a row or search item squeezed into the
    /// card above; null for anything that isn't a /detail/ title (a channel or offer tile).
    static let cardFunction = #"""
    const pathID = u => { const m = /^\/detail\/([A-Za-z0-9_-]{4,64})(?:[\/?#]|$)/.exec(typeof u === "string" ? u : ""); return m ? m[1] : null; };
    const card = e => {
      const id = pathID(e.link && e.link.url);
      if (!id) return null;
      const pb = (e.playbackActions && e.playbackActions[0]) || null;
      const images = e.images || {};
      const art = (images.cover && images.cover.url) || (images.hero && images.hero.url) || null;
      return {
        id, name: e.displayTitle || e.title || null, title: e.title || null, type: e.entityType || null,
        year: Number(e.releaseYear) || null,
        rating: (e.maturityRatingBadge && e.maturityRatingBadge.displayText) || null,
        desc: String(e.synopsis || "").slice(0, 400) || null, art,
        pct: e.progress && typeof e.progress.percentage === "number" ? e.progress.percentage : null,
        resume: pb && typeof pb.resumeTime === "number" ? pb.resumeTime : null,
        playId: pb ? pathID(pb.fallbackUrl) : null
      };
    };
    """#

    // MARK: Cards

    /// A title from a card; nil without a plain id and a name. A card with a playId plays
    /// that video (at the resume position); any other has no player until it is opened, so
    /// Play opens its page.
    static func title(fromCard card: [String: Any]) -> StreamTitle? {
        guard let id = card["id"] as? String, let page = pageURL(id: id), let name = StreamJSON.string(card["name"]) else { return nil }
        let resume = StreamJSON.int(card["resume"]).flatMap { $0 > 0 ? $0 : nil }
        let play = (card["playId"] as? String).flatMap { playURL(id: $0, resumeSeconds: resume) } ?? page
        var runtime: Int?
        if let resume, let pct = percent(card["pct"]), pct > 0, pct < 100 { runtime = Int((Double(resume) * 100 / pct).rounded()) }
        let kind: StreamTitle.Kind
        switch card["type"] as? String {
        case "Movie": kind = .movie
        case "TV Show": kind = .show
        default: kind = .other
        }
        return StreamTitle(id: id, name: name, kind: kind, play: play, page: page,
                           episodeLabel: seasonLabel(inTitle: card["title"] as? String), synopsis: StreamJSON.string(card["desc"]),
                           year: year(card["year"]), rating: StreamJSON.string(card["rating"]),
                           runtimeSeconds: runtime, resumeSeconds: runtime == nil ? nil : resume,
                           tileArt: imageURL(card["art"] as? String, width: 640), heroArt: imageURL(card["art"] as? String, width: 1920))
    }

    /// "S2" from a season's title "Show - Season 2"; nil for any other.
    static func seasonLabel(inTitle title: String?) -> String? {
        guard let title, let range = title.range(of: #" - Season (\d{1,3})$"#, options: .regularExpression) else { return nil }
        return title[range].split(separator: " ").last.map { "S\($0)" }
    }

    static func percent(_ value: Any?) -> Double? {
        if let d = value as? Double, d.isFinite { return d }
        return StreamJSON.int(value).map(Double.init)
    }

    static func year(_ value: Any?) -> Int? {
        StreamJSON.int(value).flatMap { (1900...2100).contains($0) ? $0 : nil }
    }
}
