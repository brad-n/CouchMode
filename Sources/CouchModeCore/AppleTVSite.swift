// Owns: what every Apple TV read shares, as a proxy for the signed-in site
// (tv.apple.com). Learned on a real Mac (2026-11-12): tv.apple.com is a web app
// whose views come from its own API, same-origin,
//   /api/uts/v3/canvases/channels/<channel id>   a channel's home: shelves of items
//   /api/uts/v3/search?searchTerm=<text>         search: shelves of items
//   /api/uts/v3/shows/<id>  /movies/<id>         a title's facts, seasons, play state
//   /api/uts/v3/shows/<id>/episodes              a window of episodes
// The page configures MusicKit with a developer token and the signed-in person's
// user token. The signed-in views (Up Next, where you stopped) are only filled in
// when the requests carry both, so the reader makes them from inside the page the
// way the page does; the tokens only ever exist inside the scripts: they are never
// returned, logged, stored or committed. The query values below (storefront, version,
// the two utsc keys) are the public site configuration every anonymous page load
// sends too, not secrets. A title is an "umc.cmc.<id>" (movie or show); an episode
// "umc.cmc.<id>" with a showId; each has a page address at tv.apple.com. The same
// page address with action=play opens the service's player as a dialog over that
// page (not a page of its own; see playerShownScript). Artwork is an
// is1-ssl.mzstatic.com address template with {w}, {h} and {f} to fill in.
// This file holds the address builders, the script pieces every read uses (the
// session check, the request helper and the one "card" every shelf and search item is
// squeezed into) and the card -> StreamTitle rule. No I/O here.
//
// A card, the shape parse functions read:
// {"id" (show or movie id), "kind" ("movie"|"show"), "name", "year", "rating", "desc",
//  "runtime" (seconds of what Play starts), "season", "episode" (the show's current episode),
//  "resume" (seconds), "page" (the title's page address), "episodeURL" (the episode's page,
//  when the item is one), "canPlay" (true when Apple's own player can play it for this account),
//  "tile" / "wide": {"u" (address template), "w", "h"} landscape art}

import Foundation

public enum AppleTVSite {
    public static let serviceID = "appletv"
    /// Largest answer a script hands back, in characters; bigger is treated as unreadable.
    static let maxScriptBytes = 900_000
    static let origin = "https://tv.apple.com"
    /// The channel whose home the reader shows: Apple's own.
    static let channelID = "tvs.sbd.4000"

    /// The quiet Apple TV page the reader works from. The API requests need a tv.apple.com page
    /// (for its origin and MusicKit) but not any particular view; the home and title pages start a
    /// preview playing, the search page plays nothing.
    public static let sessionPageURL = URL(string: "https://tv.apple.com/us/search")!

    /// True when `url` is an Apple TV page the reader can run its requests in
    /// (not another site; not a page that has a player dialog open over it).
    public static func isUsableSessionPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host?.lowercased() == "tv.apple.com" else { return false }
        return !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { $0.name == "action" }
    }

    // MARK: Addresses

    /// An id made of letters, digits, dots and dashes (umc.cmc.<id>), at most 64 long.
    static func isID(_ text: String) -> Bool {
        (4...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// An Apple TV page address from the API (https, tv.apple.com, no query tricks); nil otherwise.
    static func pageURL(_ address: Any?) -> URL? {
        guard let url = StreamJSON.httpsURL(address), url.host?.lowercased() == "tv.apple.com", url.user == nil, url.port == nil,
              (address as? String)?.count ?? 0 < 400 else { return nil }
        return url
    }

    /// The service's play address for a page: the page with action=play, which opens its player over it.
    public static func playURL(page: URL) -> URL? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false), page.host?.lowercased() == "tv.apple.com" else { return nil }
        var items = (parts.queryItems ?? []).filter { $0.name != "action" }
        items.append(URLQueryItem(name: "action", value: "play"))
        parts.queryItems = items
        return parts.url
    }

    private static let imageDomains = ["mzstatic.com", "example.invalid"]

    /// A 16:9 image address at a width from the API's template ({w}, {h}, {f} are filled in); nil for
    /// anything but https on Apple's image host or with an unfilled template.
    public static func imageURL(_ template: Any?, width: Int) -> URL? {
        guard let text = template as? String, width > 0, width <= 4096 else { return nil }
        let height = width * 9 / 16
        let filled = text.replacingOccurrences(of: "{w}", with: String(width)).replacingOccurrences(of: "{h}", with: String(height))
            .replacingOccurrences(of: "{f}", with: "jpg").replacingOccurrences(of: "{c}", with: "sr")
        guard !filled.contains("{"), filled.count < 400, let url = StreamJSON.httpsURL(filled), let host = url.host?.lowercased(),
              imageDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    /// The page's player check: Apple's player is a dialog (dialog.playback-view) opened over the
    /// title's page; the page's address doesn't change. Checked on a real Mac.
    public static let playerShownScript = #"""
    const dialog = document.querySelector("dialog.playback-view");
    return !!dialog && dialog.open === true;
    """#

    // MARK: Script pieces

    /// Function body: true once the page has what the requests need: MusicKit configured with a
    /// developer token and a signed-in user's token (the tokens are only tested, never returned).
    public static let readyScript = #"""
    try {
      if (location.hostname !== "tv.apple.com") return false;
      const kit = MusicKit.getInstance();
      const user = kit.musicUserToken || (document.cookie.match(/(?:^|; )media-user-token=([^;]+)/) || [])[1];
      return typeof kit.developerToken === "string" && kit.developerToken.length > 0 && typeof user === "string" && user.length > 0;
    } catch (e) {
      return false;
    }
    """#

    /// JavaScript every read starts with: `get(path, extra)`, a signed-in UTS request. It throws without a session
    /// or on an error status, so a read's try/catch answers "".
    static let helpers = #"""
    const kit = MusicKit.getInstance();
    const userToken = kit.musicUserToken || (document.cookie.match(/(?:^|; )media-user-token=([^;]+)/) || [])[1];
    if (typeof kit.developerToken !== "string" || !kit.developerToken || typeof userToken !== "string" || !userToken) throw new Error("no session");
    const get = async (path, extra) => {
      const query = new URLSearchParams({ caller: "web", locale: "en-US", pfm: "web", sf: "143441", v: "101",
        utscf: "OjAAAAEAAAAAAAMAEAAAACMAKwAtADgA", utsk: "6e3013c6d6fae3c2::::::228b20cf2959f76f" });
      for (const key of Object.keys(extra || {})) query.set(key, extra[key]);
      const response = await fetch("/api/uts/v3/" + path + "?" + query, {
        credentials: "include",
        headers: { authorization: "Bearer " + kit.developerToken, "media-user-token": userToken, accept: "application/json" }
      });
      if (!response.ok) throw new Error(String(response.status));
      return response.json();
    };
    """#

    /// JavaScript defining `landscape(images, keys)`: the first of the named images that is wider than tall, as
    /// {u, w, h} (its address template and size); null when there is none.
    static let imageFunction = #"""
    const landscape = (images, keys) => {
      for (const key of keys) {
        const o = images && images[key];
        if (o && typeof o.url === "string" && o.width > o.height * 1.3) return { u: o.url, w: o.width, h: o.height };
      }
      return null;
    };
    const tileKeys = ["shelfItemImage", "shelfImageBackground", "contentImage16X9", "coverArt16X9", "posterArt", "transitionImage", "contentImage"];
    const wideKeys = ["shelfImageBackground", "contentImage16X9", "transitionImage", "contentImage", "posterArt", "shelfItemImage"];
    """#

    /// JavaScript defining `entitled(playable)`: true when Apple's own player can play it for this account (it is
    /// on Apple's channel, the person is entitled and it isn't a hand-off to another app).
    static let entitledFunction = #"""
    const entitled = p => !!p && p.isEntitledToPlay === true && p.channelId === "\#(channelID)" && !p.punchoutUrls;
    """#

    /// JavaScript defining `card(item)`: a shelf or search item squeezed into the card above; null for anything
    /// that isn't a movie, a show or an episode of one (a person, a sports event, an upsell).
    static let cardFunction = #"""
    \#(imageFunction)
    \#(entitledFunction)
    const card = item => {
      let kind = null, id = null, page = null, name = null, episodeURL = null;
      if (item.type === "Movie" || item.type === "Show") { kind = item.type === "Movie" ? "movie" : "show"; id = item.id; page = item.url; name = item.title; }
      else if (item.type === "Episode" && item.showId) { kind = "show"; id = item.showId; page = item.showUrl; name = item.showTitle || item.title; episodeURL = item.url; }
      else return null;
      const p = item.playable || null, event = p && p.playEvent && p.playEvent.isDone !== true ? p.playEvent : null;
      const total = event ? event.contentMediaLengthInSeconds : null;
      return {
        id, kind, name, page, episodeURL,
        year: typeof item.releaseDate === "number" ? new Date(item.releaseDate).getUTCFullYear() : null,
        rating: (item.rating && item.rating.displayName) || null,
        desc: String(item.description || item.heroDescription || "").slice(0, 400) || null,
        runtime: total || item.duration || null,
        season: item.type === "Episode" ? item.seasonNumber || null : null, episode: item.type === "Episode" ? item.episodeNumber || null : null,
        resume: event ? event.contentPlayCursorInSeconds : null,
        canPlay: entitled(p),
        tile: landscape(item.images, tileKeys), wide: landscape(item.images, wideKeys)
      };
    };
    """#

    // MARK: Cards

    /// A title from a card; nil without a plain id, a name and a page on tv.apple.com. Play starts what the
    /// card says it can (the episode being continued, else the title); anything else plays by opening its page.
    static func title(fromCard card: [String: Any]) -> StreamTitle? {
        guard let id = card["id"] as? String, isID(id), let name = StreamJSON.string(card["name"]), let page = pageURL(card["page"]) else { return nil }
        let kind: StreamTitle.Kind = card["kind"] as? String == "movie" ? .movie : .show
        let canPlay = card["canPlay"] as? Bool == true
        let playPage = pageURL(card["episodeURL"]) ?? page
        let runtime = StreamJSON.int(card["runtime"]).flatMap { $0 > 0 ? $0 : nil }
        let season = StreamJSON.numericID(card["season"]), episode = StreamJSON.numericID(card["episode"])
        return StreamTitle(id: id, name: name, kind: kind, play: (canPlay ? playURL(page: playPage) : nil) ?? page, page: page,
                           episodeLabel: season.flatMap { s in episode.map { "S\(s) · E\($0)" } },
                           synopsis: StreamJSON.string(card["desc"]), year: year(card["year"]), rating: StreamJSON.string(card["rating"]),
                           runtimeSeconds: runtime, resumeSeconds: resumeSeconds(runtime: runtime, cursor: StreamJSON.int(card["resume"])),
                           tileArt: image(card["tile"], width: 640), heroArt: image(card["wide"], width: 1920))
    }

    /// The address for an image object {"u","w","h"} at a width.
    static func image(_ object: Any?, width: Int) -> URL? {
        imageURL((object as? [String: Any])?["u"], width: width)
    }

    static func year(_ value: Any?) -> Int? {
        StreamJSON.int(value).flatMap { (1900...2100).contains($0) ? $0 : nil }
    }

    /// Where playback resumes, in seconds: the play cursor when it is partway through what plays; nothing
    /// for unwatched, finished or nonsense numbers.
    static func resumeSeconds(runtime: Int?, cursor: Int?) -> Int? {
        guard let runtime, runtime > 0, let cursor, cursor > 0, cursor < runtime else { return nil }
        return cursor
    }
}
