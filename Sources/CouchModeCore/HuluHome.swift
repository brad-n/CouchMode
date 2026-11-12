// Owns: reading Hulu's signed-in home (hulu.com/hub/home) into the shell's
// own StreamHome, as a proxy. Learned on a real Mac (2026-11-11): hulu.com is a
// Next.js app; its home draws from one request to Hulu's discover service
// (the address is in the page's own data, __NEXT_DATA__ -> GlobalNav ->
// defaultNavItem.discoverHref, e.g. discover.hulu.com/content/v5/view_hubs/
// home?schema=3), which returns every row ("components", 53 of them) with
// its titles. The reader makes that same request from the page (signed in,
// as the page does when it loads) and keeps only what the screens use.
// Profiles come from the page's store (profile_manager). No I/O here.
//
// extractScript's answer, the shape parse(_:) reads:
// {"rows":[{"id","name","items":[{"id","type","name","subtitle","body",
//   "action","eab","tile","wide"}]}],
//  "profiles":[{"id","name","kids"}], "currentProfileId"}
//   type: "series" | "movie" | "episode" | other (networks, hubs)
//   eab: "EAB::<uuid to play>::..." (the episode a series resumes)
//   tile / wide: image addresses without size (imageURL adds one)

import Foundation

public enum HuluHome {
    public static let serviceID = "hulu"
    /// Rows and titles per row the script hands back (StreamLimits bound the screens further).
    static let maxComponents = 30
    static let maxItemsPerComponent = 40

    /// Function body for callAsyncJavaScript: true once the page's data and profile store are there.
    public static let readyScript = #"return !!document.getElementById("__NEXT_DATA__") && !!(window.store && window.store.getState().profile_manager);"#

    /// Function body for callAsyncJavaScript: the home as the JSON above, or "" when it can't be read.
    public static let extractScript = """
    try {
      const next = document.getElementById("__NEXT_DATA__");
      if (!next) return "";
      const props = JSON.parse(next.textContent).props.pageProps;
      const navQuery = (props.dehydratedState.queries || []).find(q => q.queryKey && q.queryKey[0] === "GlobalNav");
      const href = navQuery && navQuery.state.data.nav.defaultNavItem.discoverHref;
      if (!href || !/^https:\\/\\/discover\\.hulu\\.com\\//.test(href)) return "";
      const response = await fetch(href, { credentials: "include" });
      if (!response.ok) return "";
      const hub = await response.json();
      const path = art => (art && art.image && art.image.path) || null;
      const pick = item => {
        const v = item.visuals || {}, art = v.artwork || {}, m = item.metrics_info || {}, p = item.personalization || {};
        return { id: item.id || null, type: m.target_type || null, name: v.headline || m.target_name || null,
                 subtitle: v.subtitle || null, body: v.body || null, action: v.action_text || null, eab: p.eab || null,
                 tile: path(art.horizontal_tile) || path(art.horizontal), wide: path(art.horizontal) || path(art.horizontal_tile) };
      };
      const rows = (hub.components || []).slice(0, \(maxComponents)).map(c => ({
        id: c.id || null, name: c.name || null, items: (c.items || []).slice(0, \(maxItemsPerComponent)).map(pick)
      }));
      const state = (window.store && window.store.getState) ? window.store.getState() : props.initialState;
      const manager = (state && state.profile_manager) || {};
      return JSON.stringify({
        rows,
        profiles: (manager.profiles || []).map(p => ({ id: String(p.id), name: p.name || "", kids: !!p.is_kids })),
        currentProfileId: manager.currentProfileId ? String(manager.currentProfileId) : null
      });
    } catch (e) {
      return "";
    }
    """

    // MARK: Switching profile
    // Learned on a real Mac (2026-11-11): the page's top bar lists the profiles
    // other than the current one (a.ProfileList__profile-item, labelled
    // "Switch profile to <name>"); choosing one switches the profile in place
    // (the page's store's currentProfileId changes, no new page) and the next
    // read of the home is that profile's. The list has names, not ids, so the
    // name comes from the page's own profile list by id (and a name two
    // profiles share is refused rather than guessed).

    /// Function body for callAsyncJavaScript: true once the top bar lists profiles to switch to.
    public static let profileListReadyScript = #"return document.querySelectorAll("a.ProfileList__profile-item").length > 0 && !!(window.store && window.store.getState().profile_manager);"#

    /// Function body for callAsyncJavaScript: chooses profile `profileID` in
    /// the top bar's own list; true when chosen (or already the current one).
    public static func chooseProfileScript(profileID: String) -> String {
        #"""
        const manager = window.store.getState().profile_manager || {};
        const id = \#(StreamJSON.jsString(profileID));
        if (String(manager.currentProfileId) === id) return true;
        const profiles = manager.profiles || [];
        const profile = profiles.find(p => String(p.id) === id);
        if (!profile || !profile.name || profiles.filter(p => p.name === profile.name).length !== 1) return false;
        const item = Array.from(document.querySelectorAll("a.ProfileList__profile-item"))
          .find(a => a.getAttribute("aria-label") === "Switch profile to " + profile.name);
        if (!item) return false;
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
          item.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        return true;
        """#
    }

    /// Function body for callAsyncJavaScript: true once the page's current profile is `profileID`.
    public static func profileIsCurrentScript(profileID: String) -> String {
        #"return String(((window.store.getState().profile_manager) || {}).currentProfileId) === \#(StreamJSON.jsString(profileID));"#
    }

    // MARK: Addresses

    /// Hulu's own player for a video (an episode or a movie) id.
    public static func playURL(id: String) -> URL? {
        StreamJSON.token(id).flatMap { URL(string: "https://www.hulu.com/watch/\($0)") }
    }

    /// Hulu's own page for a series or movie id; nil for anything else (an episode has none of its own).
    public static func pageURL(kind: StreamTitle.Kind, id: String) -> URL? {
        guard let id = StreamJSON.token(id) else { return nil }
        switch kind {
        case .show: return URL(string: "https://www.hulu.com/series/\(id)")
        case .movie: return URL(string: "https://www.hulu.com/movie/\(id)")
        case .episode, .other: return nil
        }
    }

    /// Hosts Hulu's artwork is served from (and .invalid, which fixtures use and which never resolves).
    private static let imageDomains = ["hulu.com", "hulustream.com", "huluim.com", "hulu.invalid"]

    /// An artwork address at a size: https and a Hulu host only; the size is
    /// the `operations` parameter Hulu's own pages use (an existing one is replaced).
    public static func imageURL(_ address: String?, width: Int, height: Int) -> URL? {
        guard let address, var parts = URLComponents(string: address), parts.scheme == "https",
              let host = parts.host?.lowercased(),
              imageDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let operations = #"[{"resize":"\#(width)x\#(height)|max"},{"format":"jpeg"}]"#
        let others = (parts.queryItems ?? []).filter { $0.name != "operations" }
        // Encode each value fully, so the JSON's own characters can't be read as query syntax.
        let strict = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":,-_.~"))
        let query = (others.map { ($0.name, $0.value ?? "") } + [("operations", operations)]).map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: strict) ?? "")"
        }
        parts.percentEncodedQuery = query.joined(separator: "&")
        return parts.url
    }

    // MARK: Parsing

    /// The home from extractScript's answer; nil when it isn't one (or has nothing to show).
    public static func parse(_ json: String) -> StreamHome? {
        guard let read = StreamJSON.object(json), let components = read["rows"] as? [[String: Any]] else { return nil }
        var hero: StreamTitle?
        var rows: [StreamRow] = []
        for component in components {
            let name = StreamJSON.string(component["name"]) ?? ""
            let titles = (component["items"] as? [[String: Any]] ?? []).compactMap(title(from:))
            if name == "Spotlight" {
                if hero == nil { hero = titles.first }
                continue
            }
            guard !titles.isEmpty, let id = StreamJSON.token(component["id"]) else { continue }
            rows.append(StreamRow(id: "hulu-row-\(id)", title: name, kind: rowKind(name), titles: titles))
        }
        let profiles = (read["profiles"] as? [[String: Any]] ?? []).compactMap { entry -> StreamProfile? in
            guard let id = StreamJSON.token(entry["id"]), let name = StreamJSON.string(entry["name"]) else { return nil }
            return StreamProfile(id: id, name: name, isKids: entry["kids"] as? Bool ?? false)
        }
        let home = StreamHome(serviceID: serviceID, profiles: profiles, currentProfileID: StreamJSON.token(read["currentProfileId"]),
                              hero: hero, rows: rows).bounded
        return home.rows.isEmpty && home.hero == nil ? nil : home
    }

    private static func rowKind(_ name: String) -> StreamRow.Kind {
        if name.hasPrefix("Continue Watching") { return .continueWatching }
        if name.range(of: #"^Top \d+"#, options: .regularExpression) != nil { return .ranked }
        return .standard
    }

    private static func title(from item: [String: Any]) -> StreamTitle? {
        let kind: StreamTitle.Kind
        switch item["type"] as? String {
        case "series": kind = .show
        case "movie": kind = .movie
        case "episode": kind = .episode
        default: return nil
        }
        guard let id = StreamJSON.token(item["id"]), let name = StreamJSON.string(item["name"]),
              let eab = item["eab"] as? String, let playID = playableID(fromEAB: eab), let play = playURL(id: playID)
        else { return nil }
        // The label marks the episode you're on: an episode tile is that episode; a show has
        // one only when Hulu offers to resume it (a recommendation's "S1 E1" is just where it starts).
        let resumes = (StreamJSON.string(item["action"]) ?? "").lowercased().hasPrefix("resume")
        let label = kind == .episode || resumes ? episodeLabel(item["subtitle"] as? String) : nil
        return StreamTitle(id: id, name: name, kind: kind, play: play, page: pageURL(kind: kind, id: id),
                           episodeLabel: label, synopsis: StreamJSON.string(item["body"]),
                           tileArt: imageURL(item["tile"] as? String, width: 640, height: 360),
                           heroArt: imageURL(item["wide"] as? String, width: 1920, height: 1080))
    }

    /// The uuid an "EAB::<uuid>::..." names, which is what Hulu's player plays.
    static func playableID(fromEAB eab: String) -> String? {
        let parts = eab.components(separatedBy: "::")
        guard parts.count >= 2, parts[0] == "EAB", parts[1].range(of: uuidPattern, options: .regularExpression) != nil else { return nil }
        return parts[1]
    }

    static let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    /// "S1 · E7" from a subtitle starting "S1 E7".
    static func episodeLabel(_ subtitle: String?) -> String? {
        guard let subtitle, let match = subtitle.range(of: #"^S(\d+) E(\d+)"#, options: .regularExpression) else { return nil }
        let numbers = subtitle[match].split(separator: " ").map { $0.dropFirst() }
        return numbers.count == 2 ? "S\(numbers[0]) · E\(numbers[1])" : nil
    }
}
