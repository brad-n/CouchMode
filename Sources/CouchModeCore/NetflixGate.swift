// Owns: Netflix's own "Who's watching?" page (the profile gate) as the shell
// reads it: the scripts that tell the page is on the gate, read its tiles and
// press one tile, and the pure parse of that read into a StreamHome that asks
// who is watching (profiles, no rows). Netflix shows the gate instead of
// /browse when it wants the person to choose (a fresh session, or its "ask who's
// watching" setting). A tile is pressed exactly as a person would; a profile
// with a PIN or lock is only reported as locked, never opened, and nothing is
// ever typed. No I/O here.

import Foundation

public enum NetflixGate {
    /// Most tiles one read may hand back (a little over StreamLimits.maxProfiles, which bounds the home).
    static let maxTiles = 30

    /// The gate's tiles, in the page's order. Gate markers are required, because Netflix's top bar
    /// also lists profile links on /browse and those must never read as the gate. Two forms are known:
    /// the current one (a `button[data-uia="profile-selector+tile-<profile id>"]` per profile, with no
    /// link on it) and the older one (`a.profile-link` tiles carrying a /SwitchProfile?tkn= link).
    private static let tilesJS = #"""
    const NEW_TILES = 'button[data-uia^="profile-selector+tile"]';
    const OLD_TILES = '.choose-profile a.profile-link, .profiles-gate-container a.profile-link, a[data-uia^="action-select-profile"], a[data-uia="profile-link"]';
    const PREFIX = "profile-selector+tile-";
    const onGate = () => {
      const path = location.pathname.toLowerCase();
      return path.indexOf("profilesgate") >= 0 ||
        !!document.querySelector('.profile-gate-label, .choose-profile, .profiles-gate-container, [data-uia="profile-gate-label"], [data-uia="profile-gate-screen"]') ||
        document.querySelectorAll(NEW_TILES).length > 0;
    };
    const tiles = () => onGate() ? Array.from(document.querySelectorAll(NEW_TILES)).concat(Array.from(document.querySelectorAll(OLD_TILES))) : [];
    const fiberOf = (el) => el && el[Object.keys(el).find(k => k.startsWith("__reactFiber"))];
    const propUp = (el, name, depth) => {
      for (let p = fiberOf(el), d = 0; p && d < depth; p = p.return, d++) {
        if (p.memoizedProps && p.memoizedProps[name] !== undefined) return p.memoizedProps[name];
      }
      return undefined;
    };
    const token = (a) => {
      const uia = a.getAttribute("data-uia") || "";
      if (uia.indexOf(PREFIX) === 0) { const t = uia.slice(PREFIX.length); return /^[A-Za-z0-9-]{1,64}$/.test(t) ? t : null; }
      const m = /[?&]tkn=([A-Za-z0-9-]{1,64})(?:&|$)/.exec(a.getAttribute("href") || "");
      return m ? m[1] : null;
    };
    const locked = (a) => propUp(a, "isLocked", 6) === true || !!a.querySelector('[class*="lock" i], [data-uia*="lock" i]') || /lock|pin/i.test(a.getAttribute("aria-label") || "") || !!a.closest('[class*="locked" i]');
    """#

    /// Function body: true once the page is the gate and has drawn its tiles.
    public static let readyScript = #"""
    \#(tilesJS)
    return tiles().length > 0;
    """#

    /// Function body: true when the page is the gate, whether or not its tiles have drawn.
    public static let onGateScript = #"""
    \#(tilesJS)
    return onGate();
    """#

    /// A ready function body that is also satisfied by the gate, so any read can end there
    /// (Netflix shows the gate instead of a title, search or home page when it wants a choice).
    public static func readyOrGate(_ ready: String) -> String {
        "const a = (() => { \(ready) })(); if (a) return true; return (() => { \(readyScript) })();"
    }

    /// A read function body that answers with the gate's tiles when the page is the gate, else runs `read`.
    public static func readOrGate(_ read: String) -> String {
        "const g = (() => { \(extractScript) })(); if (g) return g; \(read)"
    }

    /// Function body: `{"gate":[{id,name,avatar,locked}]}` as a JSON string when the page is the
    /// gate, "" when it isn't (or on error). Reads only; presses nothing.
    public static let extractScript = #"""
    try {
      \#(tilesJS)
      const found = tiles().slice(0, \#(maxTiles));
      if (found.length === 0) return "";
      const gate = found.map((a, i) => {
        const nameEl = a.querySelector('.profile-name');
        const propName = propUp(a, "name", 4);
        const name = (typeof propName === "string" && propName !== "" ? propName
          : (nameEl && nameEl.textContent) || a.getAttribute("aria-label") || a.textContent || "").trim().slice(0, 64);
        const propAvatar = propUp(a, "avatarUrl", 4);
        const img = a.querySelector('img');
        const icon = a.querySelector('.profile-icon') || a.querySelector('[class*="avatar" i]');
        const bg = icon ? (getComputedStyle(icon).backgroundImage || "") : "";
        const m = /url\(["']?([^"')]+)["']?\)/.exec(bg);
        const avatar = typeof propAvatar === "string" && propAvatar !== "" ? propAvatar : (img && img.getAttribute("src")) || (m ? m[1] : "");
        const isLocked = locked(a);
        return { id: token(a) || (isLocked ? "locked-" + (i + 1) : ""), name: name, avatar: avatar, locked: isLocked };
      });
      return JSON.stringify({ gate: gate });
    } catch (e) {
      return "";
    }
    """#

    /// Function body: presses the one unlocked gate tile for `profileID`, the way a person would;
    /// false unless the page is the gate and exactly one tile has that id. Never types anything.
    public static func chooseScript(profileID: String) -> String {
        guard StreamJSON.token(profileID) != nil else { return "return false;" }
        return #"""
        \#(tilesJS)
        const id = \#(StreamJSON.jsString(profileID));
        const hits = tiles().filter(a => token(a) === id && !locked(a));
        if (hits.length !== 1) return false;
        // Netflix ignores scripted clicks on its pages, so the press is following the tile's own link
        // (its SwitchProfile address on netflix.com). The current tiles are buttons with no link, whose
        // profile's switch address is Netflix's own; a tile with neither is clicked.
        const link = hits[0].href ? new URL(hits[0].href, location.href) : null;
        if (link && link.origin === location.origin && link.pathname.toLowerCase() === "/switchprofile") { location.assign(link.href); }
        else if (/^[A-Za-z0-9]{1,64}$/.test(id)) { location.assign(location.origin + "/SwitchProfile?tkn=" + id); }
        else { hits[0].click(); }
        return true;
        """#
    }

    /// Function body: true once the page has left the gate (a tile was pressed and the site moved on).
    public static let leftGateScript = #"""
    \#(tilesJS)
    return !onGate();
    """#

    /// The gate as a home that asks who is watching, from extractScript's answer; nil when the
    /// answer isn't a gate (empty, malformed, or no usable tile).
    public static func parse(_ json: String) -> StreamHome? {
        guard let read = StreamJSON.object(json), let entries = read["gate"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var profiles: [StreamProfile] = []
        for entry in entries.prefix(maxTiles) {
            guard let id = StreamJSON.token(entry["id"]), let name = StreamJSON.string(entry["name"]),
                  seen.insert(id).inserted else { continue }
            profiles.append(StreamProfile(id: id, name: name, avatar: StreamJSON.httpsURL(entry["avatar"]),
                                          isLocked: entry["locked"] as? Bool ?? false))
        }
        guard !profiles.isEmpty else { return nil }
        var home = StreamHome(serviceID: NetflixHome.serviceID, profiles: profiles)
        home.asksWhoIsWatching = true
        return home.bounded
    }
}
