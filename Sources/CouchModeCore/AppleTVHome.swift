// Owns: reading Apple TV's home for the shell's home screen, as a proxy.
// Learned on a real Mac (2026-11-12): the site's home for the signed-in
// person is its channel canvas, one request,
//   canvases/channels/tvs.sbd.4000
// (see AppleTVSite) which holds shelves in order: a stage of featured titles
// (displayType "epicStage"), Up Next ("upNextLockup": the person's partly
// watched titles and next episodes, each with where they stopped), charts
// ("chart": Top 10 lists) and editorial rows ("lockup", "brick", "epicShowcase").
// The reader makes that same request from a quiet Apple TV page, signed in as the
// page does, and keeps the shelves. Apple TV has no profiles on the web, so the
// home reports a single one. No I/O here.
//
// extractScript's answer: {"rows":[{"id","name","type","items":[card]}]}  (cards: see AppleTVSite)

import Foundation

public enum AppleTVHome {
    public static let serviceID = AppleTVSite.serviceID
    /// The only profile: the site has no profile choice.
    public static let profileID = "main"

    private static let maxRows = StreamLimits.maxRows + 4
    private static let maxItems = StreamLimits.maxTitlesPerRow

    /// Function body: true once the page can make the requests.
    public static let readyScript = AppleTVSite.readyScript

    /// Function body for callAsyncJavaScript: the home's shelves as the JSON above;
    /// "" on any error, without a session or when too long.
    public static let extractScript = #"""
    try {
      \#(AppleTVSite.helpers)
      \#(AppleTVSite.cardFunction)
      const canvas = (await get("canvases/channels/\#(AppleTVSite.channelID)")).data.canvas;
      const rows = (canvas.shelves || []).filter(s => Array.isArray(s.items) && s.items.length)
        .map(s => ({ id: s.id || null, name: (s.header && s.header.title) || "", type: s.displayType || "",
                     items: s.items.slice(0, \#(maxItems)).map(card).filter(Boolean) }))
        .filter(r => r.items.length).slice(0, \#(maxRows));
      const out = JSON.stringify({ rows });
      return out.length > \#(AppleTVSite.maxScriptBytes) ? "" : out;
    } catch (e) {
      return "";
    }
    """#

    /// The home from extractScript's answer; nil when it isn't one (or has nothing to show).
    public static func parse(_ json: String) -> StreamHome? {
        guard let read = StreamJSON.object(json), let shelves = read["rows"] as? [[String: Any]] else { return nil }
        var hero: StreamTitle?
        var rows: [StreamRow] = []
        var seen = Set<String>()
        for shelf in shelves {
            let titles = (shelf["items"] as? [[String: Any]] ?? []).compactMap(AppleTVSite.title(fromCard:))
            let type = shelf["type"] as? String ?? ""
            if type == "epicStage" {
                if hero == nil { hero = titles.first }
                continue
            }
            guard !titles.isEmpty, let id = shelf["id"] as? String, (1...120).contains(id.count), seen.insert(id).inserted,
                  let name = StreamJSON.string(shelf["name"]) else { continue }
            rows.append(StreamRow(id: "appletv-row-\(id)", title: name, kind: rowKind(type), titles: titles))
        }
        let profile = StreamProfile(id: profileID, name: "Apple TV")
        let home = StreamHome(serviceID: serviceID, profiles: [profile], currentProfileID: profileID, hero: hero, rows: rows).bounded
        return home.rows.isEmpty && home.hero == nil ? nil : home
    }

    private static func rowKind(_ type: String) -> StreamRow.Kind {
        switch type {
        case "upNextLockup": return .continueWatching
        case "chart": return .ranked
        default: return .standard
        }
    }
}
