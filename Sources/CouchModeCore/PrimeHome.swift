// Owns: reading Prime Video's signed-in home into the shell's own StreamHome,
// and its profile list and switching, as a proxy. Learned on a real Mac
// (2026-11-11), see PrimeSite for the page data. The home page's data holds
// body.containers: "StandardHero" is the billboard, one container has
// isContinueWatching with each title's position (progress.percentage and the
// play action's resumeTime), the rest are carousels (a "Top 10" one is a
// chart). The reader opens the home page and reads that data; nothing more is
// requested, and the rows hold what the page held ("more in a row" isn't read).
// Profiles are in the top bar's own markup: the current one in a
// data-testid="active-profile-<name>" element, the others as the bar's own
// "switch profile" forms (a button with the name, in a form posting to
// /profiles/switch), each with an avatar span whose image is a CSS background
// (kid profiles use a kid-<n>.png avatar). The forms carry a token that this
// reader never reads or returns: choosing a profile clicks the form's own button.
// A profile's id here is its name (a name two profiles share is left out). No I/O here.
//
// extractScript's answer, the shape parse(_:) reads:
// {"hero":card|null, "rows":[{"id","name","type","cw","items":[card]}],
//  "profiles":[{"name","avatar","current","kids"}]}   (card: see PrimeSite)

import Foundation

public enum PrimeHome {
    public static let serviceID = PrimeSite.serviceID
    public static let homeURL = URL(string: "https://www.primevideo.com/")!
    static let maxContainers = StreamLimits.maxRows + 4
    static let maxItems = StreamLimits.maxTitlesPerRow

    /// Function body for callAsyncJavaScript: true once the page's data holds its
    /// rows and the top bar has drawn the current profile (so no "who's watching"
    /// screen is in the way).
    public static let readyScript = #"""
    try {
      \#(PrimeSite.hydration)
      const body = bodyOf();
      return !!body && Array.isArray(body.containers) && body.containers.length > 0 && !!document.querySelector('[data-testid^="active-profile-"]');
    } catch (e) {
      return false;
    }
    """#

    /// Function body for callAsyncJavaScript: the home as the JSON above, or ""
    /// when it can't be read (no data, too much data).
    public static let extractScript = #"""
    try {
      \#(PrimeSite.hydration)
      \#(PrimeSite.cardFunction)
      const body = bodyOf();
      if (!body || !Array.isArray(body.containers)) return "";
      const containers = body.containers.slice(0, \#(maxContainers));
      const heroContainer = containers.find(c => c.containerType === "StandardHero");
      const hero = heroContainer ? ((heroContainer.entities || []).map(card).find(Boolean) || null) : null;
      const rows = containers.map((c, i) => ({
        id: String(i), name: c.text || "", type: c.containerType || "", cw: !!c.isContinueWatching,
        items: (c.entities || []).slice(0, \#(maxItems)).map(card).filter(Boolean)
      })).filter(r => r.items.length);
      const avatarOf = el => {
        if (!el) return null;
        const m = /url\("([^"]+)"\)/.exec(getComputedStyle(el).backgroundImage || "");
        return m ? m[1] : null;
      };
      const profiles = [];
      const active = document.querySelector('[data-testid^="active-profile-"]');
      if (active) {
        profiles.push({ name: active.getAttribute("data-testid").slice("active-profile-".length), avatar: avatarOf(active), current: true, kids: false });
      }
      const seen = new Set(profiles.map(p => p.name));
      for (const form of Array.from(document.querySelectorAll('form[action="/profiles/switch"]')).slice(0, 40)) {
        const name = ((form.querySelector("button") || {}).textContent || "").trim();
        if (!name || seen.has(name)) continue;
        seen.add(name);
        const icon = form.querySelector('[data-testid^="pv-nav-profile-icon-"]');
        const avatar = avatarOf(icon);
        profiles.push({ name, avatar, current: false, kids: !!avatar && /\/kid-[0-9]+\.png$/.test(avatar) });
        if (profiles.length >= \#(StreamLimits.maxProfiles)) break;
      }
      const out = JSON.stringify({ hero, rows, profiles });
      return out.length > \#(PrimeSite.maxScriptBytes) ? "" : out;
    } catch (e) {
      return "";
    }
    """#

    // MARK: Switching profile

    /// Function body for callAsyncJavaScript: presses the top bar's own button for
    /// profile `profileID` (its name); true when pressed (or already current).
    public static func chooseProfileScript(profileID: String) -> String {
        #"""
        const name = \#(StreamJSON.jsString(profileID));
        const active = document.querySelector('[data-testid^="active-profile-"]');
        if (active && active.getAttribute("data-testid") === "active-profile-" + name) return true;
        const buttons = Array.from(document.querySelectorAll('form[action="/profiles/switch"] button')).filter(b => b.textContent.trim() === name);
        if (buttons.length === 0) return false;
        buttons[0].click();
        return true;
        """#
    }

    /// Function body for callAsyncJavaScript: true once the page's current profile is `profileID`.
    public static func profileIsCurrentScript(profileID: String) -> String {
        #"""
        const active = document.querySelector('[data-testid^="active-profile-"]');
        return !!active && active.getAttribute("data-testid") === "active-profile-" + \#(StreamJSON.jsString(profileID));
        """#
    }

    // MARK: Parsing

    /// The home from extractScript's answer; nil when it isn't one (or has nothing to show).
    public static func parse(_ json: String) -> StreamHome? {
        guard let read = StreamJSON.object(json), let containers = read["rows"] as? [[String: Any]] else { return nil }
        var rows: [StreamRow] = []
        for container in containers {
            let type = container["type"] as? String ?? ""
            let titles = (container["items"] as? [[String: Any]] ?? []).compactMap(PrimeSite.title(fromCard:))
            guard type != "StandardHero", !titles.isEmpty, let id = StreamJSON.string(container["id"]),
                  (1...3).contains(id.count), id.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let name = StreamJSON.string(container["name"]) ?? ""
            rows.append(StreamRow(id: "prime-row-\(id)", title: name, kind: rowKind(name: name, continueWatching: container["cw"] as? Bool == true),
                                  titles: titles))
        }
        let hero = (read["hero"] as? [String: Any]).flatMap(PrimeSite.title(fromCard:))
        let (profiles, currentID) = profiles(from: read["profiles"] as? [[String: Any]] ?? [])
        let home = StreamHome(serviceID: serviceID, profiles: profiles, currentProfileID: currentID, hero: hero, rows: rows).bounded
        return home.rows.isEmpty && home.hero == nil ? nil : home
    }

    private static func rowKind(name: String, continueWatching: Bool) -> StreamRow.Kind {
        if continueWatching { return .continueWatching }
        return name.range(of: #"^top\s*10\b"#, options: [.regularExpression, .caseInsensitive]) != nil ? .ranked : .standard
    }

    /// Profiles by name; a name that is empty, too long or shared is left out.
    private static func profiles(from entries: [[String: Any]]) -> ([StreamProfile], String?) {
        let names = entries.compactMap { StreamJSON.string($0["name"]) }
        var profiles: [StreamProfile] = []
        var currentID: String?
        for entry in entries {
            guard let name = StreamJSON.string(entry["name"]), name.count <= 64, names.filter({ $0 == name }).count == 1 else { continue }
            profiles.append(StreamProfile(id: name, name: name, avatar: PrimeSite.avatarURL(entry["avatar"] as? String),
                                          isKids: entry["kids"] as? Bool == true))
            if entry["current"] as? Bool == true { currentID = name }
        }
        return (profiles, currentID)
    }
}
