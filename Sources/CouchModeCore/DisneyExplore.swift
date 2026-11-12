// Owns: what every Disney+ read shares, as a proxy for the signed-in site
// (disneyplus.com). Learned on a real Mac (2026-11-11): disneyplus.com is a
// single-page app whose views all come from its "explore" API,
//   https://disney.api.edge.bamgrid.com/explore/v1.21/<page|season|search|globalNav>...
// requested with the signed-in session's bearer token, which the page's SDK
// keeps in localStorage ("DTCI-DISNEYPLUS.WEB-PROD.token"). The reader makes the
// same requests from inside the page, so the token only ever exists inside the
// scripts here: it is never returned, logged, stored or committed. A title is
// an "entity-<uuid>" (its page, /browse/entity-<uuid>); its player is
// /play/<deeplinkId> of a playback action (a movie's equals its entity id, an
// episode has its own). Artwork is a ripcut image id that any size can be asked
// of. This file holds the address builders, the script pieces every read uses
// (the request helper and the one "card" every row, search and detail item is
// squeezed into) and the card -> StreamTitle rule. No I/O here.
//
// A card, the shape parse functions read:
// {"id" (entity uuid), "name", "desc", "year", "rating", "runtimeMs",
//  "season", "episode", "pct", "left", "playId", "tile", "wide"}
//   pct: percent watched; left: seconds remaining (Continue Watching only)
//   playId: set only where the site offers a playback action (Continue Watching)
//   tile / wide: ripcut image ids (16:9) that imageURL turns into addresses

import Foundation

public enum DisneyExplore {
    public static let serviceID = "disney"
    /// Largest answer a script hands back, in characters; bigger is treated as unreadable.
    static let maxScriptBytes = 900_000

    static let api = "https://disney.api.edge.bamgrid.com/explore/v1.21/"

    /// The quiet Disney page the reader works from. The explore requests need
    /// a Disney page (for its origin and token) but not any particular view,
    /// and /home starts a trailer playing, so the reader uses the search page,
    /// which plays nothing.
    public static let sessionPageURL = URL(string: "https://www.disneyplus.com/browse/search")!

    /// True when `url` is a Disney page the reader can run its requests in
    /// (not the player, and not another site).
    public static func isUsableSessionPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased(), host == "www.disneyplus.com" else { return false }
        let first = url.pathComponents.first { $0 != "/" }
        return first != "play" && first != "video"
    }

    // MARK: Addresses

    /// Disney+'s own player for a video id (an episode's or a movie's).
    public static func playURL(id: String) -> URL? {
        StreamJSON.token(id).flatMap { URL(string: "https://www.disneyplus.com/play/\($0)") }
    }

    /// Disney+'s own page for a title's entity id.
    public static func pageURL(entityID: String) -> URL? {
        StreamJSON.token(entityID).flatMap { URL(string: "https://www.disneyplus.com/browse/entity-\($0)") }
    }

    /// A 16:9 artwork address at a width: ripcut's compose with an image id.
    public static func imageURL(_ imageID: String?, width: Int) -> URL? {
        guard let id = StreamJSON.token(imageID), width > 0, width <= 4096 else { return nil }
        return URL(string: "https://disney.images.edge.bamgrid.com/ripcut-delivery/v2/variant/disney/\(id)/compose?format=jpeg&width=\(width)")
    }

    private static let avatarDomains = ["disney-plus.net", "bamgrid.com", "example.invalid"]

    /// A profile's avatar address as the page shows it: https and a Disney artwork host only.
    public static func avatarURL(_ address: String?) -> URL? {
        guard let url = StreamJSON.httpsURL(address), let host = url.host?.lowercased(),
              avatarDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    // MARK: Script pieces

    /// JavaScript every read starts with: `get(path)`, a signed-in explore
    /// request. It throws without a session, so a read's try/catch answers "".
    static let helpers = #"""
    const session = (() => {
      try { return JSON.parse(localStorage.getItem("DTCI-DISNEYPLUS.WEB-PROD.token") || "null"); } catch (e) { return null; }
    })();
    if (!session || typeof session.access_token !== "string") throw new Error("no session");
    const get = async path => {
      const response = await fetch("\#(api)" + path, {
        headers: { authorization: "Bearer " + session.access_token, accept: "application/json" }
      });
      if (!response.ok) throw new Error(String(response.status));
      return response.json();
    };
    """#

    /// JavaScript defining `card(item)`: a row, search or season item squeezed
    /// into the card above; null for anything that isn't a title with a page
    /// (a playlist, a collection page).
    static let cardFunction = #"""
    const image = o => (o && o["1.78"] && o["1.78"].imageId) || null;
    const card = item => {
      const v = item.visuals || {}, acts = item.actions || [], art = v.artwork || {}, std = art.standard || {}, m = v.metastringParts || {};
      const browse = acts.find(a => a.type === "browse" && /^entity-[0-9a-f-]{36}$/i.test(a.pageId || ""));
      if (!browse) return null;
      const play = acts.find(a => a.type === "playback");
      const progress = (item.personalization && item.personalization.userState && item.personalization.userState.progress) || {};
      const description = v.description || {};
      return {
        id: browse.pageId.slice(7), name: v.title || null,
        desc: String(description.medium || description.brief || description.full || "").slice(0, 400) || null,
        year: (m.releaseYearRange && m.releaseYearRange.startYear) || null,
        rating: (m.ratingInfo && m.ratingInfo.rating && m.ratingInfo.rating.text) || null,
        runtimeMs: v.durationMs || (m.runtime && m.runtime.runtimeMs) || null,
        season: v.seasonNumber || null, episode: v.episodeNumber || null,
        pct: progress.progressPercentage == null ? null : progress.progressPercentage,
        left: progress.secondsRemaining == null ? null : progress.secondsRemaining,
        playId: play ? play.deeplinkId || null : null,
        tile: image(std.tile) || image(std.thumbnail) || image(std.background),
        wide: image((art.hero || {}).background) || image(std.background) || image(std.tile)
      };
    };
    """#

    // MARK: Cards

    /// A title from a card; nil without a plain id and a name. A card with a
    /// playId (Continue Watching) plays that video; any other has no player
    /// address until its details are read, so it carries its page's address
    /// (Select opens the details first). A card that has a season is a show
    /// being continued; a length without one means a movie.
    static func title(fromCard card: [String: Any]) -> StreamTitle? {
        guard let id = StreamJSON.token(card["id"]), let name = StreamJSON.string(card["name"]), let page = pageURL(entityID: id) else { return nil }
        let season = StreamJSON.numericID(card["season"]), episode = StreamJSON.numericID(card["episode"])
        let runtimeMs = StreamJSON.int(card["runtimeMs"])
        let kind: StreamTitle.Kind = season != nil ? .show : (runtimeMs != nil ? .movie : .show)
        let runtime = runtimeMs.flatMap { $0 > 0 ? $0 / 1000 : nil }
        return StreamTitle(id: id, name: name, kind: kind, play: playURL(id: card["playId"] as? String ?? "") ?? page, page: page,
                           episodeLabel: season.flatMap { s in episode.map { "S\(s) · E\($0)" } },
                           synopsis: StreamJSON.string(card["desc"]), year: year(card["year"]), rating: StreamJSON.string(card["rating"]),
                           runtimeSeconds: runtime,
                           resumeSeconds: resumeSeconds(runtimeMs: runtimeMs, percent: StreamJSON.int(card["pct"]), left: StreamJSON.int(card["left"])),
                           tileArt: imageURL(card["tile"] as? String, width: 640), heroArt: imageURL(card["wide"] as? String, width: 1920))
    }

    static func year(_ value: Any?) -> Int? {
        let text = (value as? String) ?? StreamJSON.int(value).map(String.init)
        return text.flatMap { Int($0.prefix(4)) }.flatMap { (1900...2100).contains($0) ? $0 : nil }
    }

    /// Where playback resumes, in seconds: the percent watched when it is
    /// partway (1 to 99), else the seconds the site says are left. Nothing for
    /// unwatched, finished or nonsense numbers.
    static func resumeSeconds(runtimeMs: Int?, percent: Int?, left: Int?) -> Int? {
        guard let runtimeMs, runtimeMs > 0 else { return nil }
        let total = runtimeMs / 1000
        if let percent, percent != 0 {
            return (1...99).contains(percent) ? total * percent / 100 : nil
        }
        if let left, left > 0, left < total { return total - left }
        return nil
    }
}
