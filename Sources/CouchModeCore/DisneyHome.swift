// Owns: reading Disney+'s signed-in home into the shell's own StreamHome, and
// its profile list and switching, as a proxy. Learned on a real Mac
// (2026-11-11), see DisneyExplore for the API. The home is the explore page
// for the nav item whose deeplinkId is "home" (its page id comes from
// globalNav, the first request the site itself makes), asked with
//   page/<pageId>?disableSmartFocus=true&enhancedContainersLimit=N&limit=M
// the parameters the site's own page requests use. Its containers are rows:
// "hero_immersive" is the billboard, "continue_watching" has progress,
// "top_ranked" is the Top 10 chart, the rest are standard shelves; a shelf of
// playlists holds no title pages and is dropped. Only the first N containers
// carry their items (as on the site, the rest load as they are scrolled to);
// a row the site holds more of notes its total and paging params for DisneyMore.
// Profiles are not in any request the page makes while browsing: the top bar's
// profile menu (data-testid dropdown-active-profile) lists the profiles other
// than the current one (dropdown-profile-<n>, each with the name as its text
// and an avatar image) when it is hovered open, and the current one is named
// in the menu button's aria-label ("<name>'s profile. ..."). Choosing one
// switches the profile; the menu has names, not ids, so a profile's id here is
// its name (a name two profiles share is left out rather than guessed). No I/O here.
//
// extractScript's answer, the shape parse(_:) reads:
// {"rows":[{"id","name","style","items":[card],"more":{"total","next","q"}|null}], "profiles":[{"name","avatar","current"}]}
// (card: see DisneyExplore)

import Foundation

public enum DisneyHome {
    public static let serviceID = DisneyExplore.serviceID
    /// Containers whose items the page request asks for, rows kept, and items per row.
    static let maxContainers = 16
    static let maxRows = StreamLimits.maxRows + 4
    static let maxItems = 30

    /// Function body for callAsyncJavaScript: true once the page is signed in
    /// (a session is kept) and has drawn its profile menu (so no "who's
    /// watching" screen is in the way).
    public static let readyScript = #"""
    try {
      const session = JSON.parse(localStorage.getItem("DTCI-DISNEYPLUS.WEB-PROD.token") || "null");
      return !!session && typeof session.access_token === "string" && !!document.querySelector('[data-testid="dropdown-active-profile"]');
    } catch (e) {
      return false;
    }
    """#

    /// Function body: true once the page is ready (see readyScript) or is on a profile form, which
    /// never becomes ready; a read that waits on this ends at once on the form.
    public static let readyOrFormScript = #"""
    const first = location.pathname.split("/").filter(Boolean)[0];
    if ([\#(profileFormPaths.map { StreamJSON.jsString($0) }.joined(separator: ", "))].includes(first)) return true;
    return (() => {
      \#(readyScript)
    })();
    """#

    /// JavaScript for the profile menu: `menuOpen()` opens it the way a
    /// hover does and waits (bounded) for its entries, `menuClose()` lets it
    /// go, `currentName()` is the current profile's name.
    static let menu = #"""
    const active = () => document.querySelector('[data-testid="dropdown-active-profile"]');
    const fire = (el, types) => types.forEach(t => el.dispatchEvent(new MouseEvent(t, { bubbles: true, view: window })));
    const currentName = () => {
      const button = active();
      const m = button && (button.getAttribute("aria-label") || "").match(/^(.+?)['’]s profile\./);
      return m ? m[1].trim() : null;
    };
    const menuOpen = async () => {
      const button = active();
      if (!button) return false;
      fire(button, ["pointerover", "mouseover", "pointerenter", "mouseenter", "mousemove"]);
      button.focus();
      for (let i = 0; i < 15; i++) {
        if (document.querySelector('[data-testid^="dropdown-option-"]')) return true;
        await new Promise(r => setTimeout(r, 100));
      }
      return false;
    };
    const menuClose = () => {
      const button = active();
      if (!button) return;
      const list = document.querySelector('[data-testid="account-dropdown-list"]');
      fire(button, ["pointerout", "mouseout", "pointerleave", "mouseleave"]);
      if (list) fire(list, ["pointerout", "mouseout", "pointerleave", "mouseleave"]);
      button.blur();
    };
    """#

    /// Function body for callAsyncJavaScript: the home as the JSON above, or
    /// "" when it can't be read (no session, a request that fails, too much data).
    public static let extractScript = #"""
    try {
      \#(DisneyExplore.helpers)
      \#(DisneyExplore.cardFunction)
      \#(menu)
      const findHome = (node, depth) => {
        if (!node || depth > 6) return null;
        const a = node.action;
        if (a && a.deeplinkId === "home" && /^page-[0-9a-f-]{36}$/i.test(a.pageId || "")) return a.pageId;
        for (const child of node.children || []) { const found = findHome(child, depth + 1); if (found) return found; }
        return null;
      };
      const pageId = findHome((await get("globalNav")).data.nav, 0);
      if (!pageId) return "";
      const page = (await get("page/" + pageId + "?disableSmartFocus=true&enhancedContainersLimit=\#(maxContainers)&limit=\#(maxItems)")).data.page;
      \#(DisneyMore.noteFunction)
      const rows = (page.containers || []).filter(c => c.type === "set" && c.style && c.items && c.items.length)
        .map(c => ({ id: c.id || null, name: (c.visuals && c.visuals.name) || "", style: c.style.name || "",
                     items: c.items.slice(0, \#(maxItems)).map(card).filter(Boolean),
                     more: c.pagination && c.pagination.hasMore ? moreNote(c) : null }))
        .filter(r => r.items.length).slice(0, \#(maxRows));
      const profiles = [];
      const current = currentName();
      if (current && await menuOpen()) {
        const avatar = el => { const img = el && el.querySelector("img"); return img ? img.getAttribute("src") : null; };
        profiles.push({ name: current, avatar: avatar(active()), current: true });
        for (const b of Array.from(document.querySelectorAll('[data-testid^="dropdown-profile-"]')).slice(0, \#(StreamLimits.maxProfiles))) {
          profiles.push({ name: b.textContent.trim(), avatar: avatar(b), current: false });
        }
        menuClose();
      }
      const out = JSON.stringify({ rows, profiles });
      return out.length > \#(DisneyExplore.maxScriptBytes) ? "" : out;
    } catch (e) {
      return "";
    }
    """#

    // MARK: Switching profile

    /// Function body for callAsyncJavaScript: chooses profile `profileID` (its
    /// name) in the top bar's own menu; true when chosen (or already current).
    public static func chooseProfileScript(profileID: String) -> String {
        #"""
        \#(menu)
        const name = \#(StreamJSON.jsString(profileID));
        if (currentName() === name) return true;
        if (!(await menuOpen())) return false;
        const matches = Array.from(document.querySelectorAll('[data-testid^="dropdown-profile-"]')).filter(b => b.textContent.trim() === name);
        if (matches.length !== 1) { menuClose(); return false; }
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
          matches[0].dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        return true;
        """#
    }

    /// The first path part of Disney's own "update this profile" form (seen after choosing a profile
    /// that still needs details only the person can give): /update-profile/<id>.
    static let profileFormPaths = ["update-profile"]

    /// True when `url` is one of Disney's own profile forms, which the person has to finish.
    public static func isProfileForm(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host?.lowercased() == "www.disneyplus.com",
              let first = url.pathComponents.first(where: { $0 != "/" }) else { return false }
        return profileFormPaths.contains(first)
    }

    /// Function body for callAsyncJavaScript: true once a profile switch has settled: the page is
    /// on a profile form, or its current profile is `profileID`.
    public static func profileSettledScript(profileID: String) -> String {
        #"""
        \#(menu)
        const first = location.pathname.split("/").filter(Boolean)[0];
        return [\#(profileFormPaths.map { StreamJSON.jsString($0) }.joined(separator: ", "))].includes(first)
          || currentName() === \#(StreamJSON.jsString(profileID));
        """#
    }

    // MARK: Switching back from an unfinished form

    /// Disney's own "who's watching" page: the site's way to choose a profile.
    public static let selectProfileURL = URL(string: "https://www.disneyplus.com/select-profile")!

    /// Function body: true once the "who's watching" page has drawn its profile tiles.
    public static let pickerReadyScript = #"""
    return document.querySelectorAll('[data-testid^="profile-avatar-"]').length > 0;
    """#

    /// Function body: true once the page has left the "who's watching" page (a profile was chosen).
    public static let leftPickerScript = #"""
    return !location.pathname.split("/").includes("select-profile");
    """#

    /// Function body: chooses the profile named `profileID` on the "who's watching" page (a tile
    /// is labelled with its name); false unless exactly one tile has that name.
    public static func choosePickerProfileScript(profileID: String) -> String {
        #"""
        const name = \#(StreamJSON.jsString(profileID));
        const tiles = Array.from(document.querySelectorAll('[data-testid^="profile-avatar-"]')).filter(e => e.getAttribute("aria-label") === name);
        if (tiles.length !== 1) return false;
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
          tiles[0].dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        return true;
        """#
    }

    /// Function body for callAsyncJavaScript: true once the page's current profile is `profileID`.
    public static func profileIsCurrentScript(profileID: String) -> String {
        #"""
        \#(menu)
        return currentName() === \#(StreamJSON.jsString(profileID));
        """#
    }

    // MARK: Parsing

    /// The home from extractScript's answer; nil when it isn't one (or has nothing to show).
    public static func parse(_ json: String) -> StreamHome? {
        guard let read = StreamJSON.object(json), let containers = read["rows"] as? [[String: Any]] else { return nil }
        var hero: StreamTitle?
        var rows: [StreamRow] = []
        for container in containers {
            let titles = (container["items"] as? [[String: Any]] ?? []).compactMap(DisneyExplore.title(fromCard:))
            let style = container["style"] as? String ?? ""
            if style == "hero_immersive" {
                if hero == nil { hero = titles.first }
                continue
            }
            guard !titles.isEmpty, let id = StreamJSON.token(container["id"]) else { continue }
            rows.append(StreamRow(id: "disney-row-\(id)", title: StreamJSON.string(container["name"]) ?? "", kind: rowKind(style), titles: titles,
                                totalCount: DisneyMore.total(container, loaded: titles.count)))
        }
        let (profiles, currentID) = profiles(from: read["profiles"] as? [[String: Any]] ?? [])
        let home = StreamHome(serviceID: serviceID, profiles: profiles, currentProfileID: currentID, hero: hero, rows: rows).bounded
        return home.rows.isEmpty && home.hero == nil ? nil : home
    }

    private static func rowKind(_ style: String) -> StreamRow.Kind {
        switch style {
        case "continue_watching": return .continueWatching
        case "top_ranked": return .ranked
        default: return .standard
        }
    }

    /// Profiles by name; a name that is empty, too long or shared is left out.
    private static func profiles(from entries: [[String: Any]]) -> ([StreamProfile], String?) {
        let names = entries.compactMap { StreamJSON.string($0["name"]) }
        var profiles: [StreamProfile] = []
        var currentID: String?
        for entry in entries {
            guard let name = StreamJSON.string(entry["name"]), name.count <= 64, names.filter({ $0 == name }).count == 1 else { continue }
            profiles.append(StreamProfile(id: name, name: name, avatar: DisneyExplore.avatarURL(entry["avatar"] as? String)))
            if entry["current"] as? Bool == true { currentID = name }
        }
        return (profiles, currentID)
    }
}
