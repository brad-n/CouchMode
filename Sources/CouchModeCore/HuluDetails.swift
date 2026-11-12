// Owns: reading a title's own page on Hulu for the shell's details screen,
// as a proxy. hulu.com/series/<id> (or /movie/<id>) is a page that, as it
// loads, asks Hulu's discover service for the title's hub (confirmed on mini
// 2, 2026-11-11, from the page's own requests):
//   https://discover.hulu.com/content/v5/hubs/series/<id>?schema=3
// whose details.entity has the title's facts (name, description, rating,
// premiere_date) and whose "Episodes" component lists the seasons as
// groupings ("<id>::<n>", "Season 1"), the first one's episodes included.
// Each episode has id, number, name, description, bundle.duration and its
// artwork; how far the profile is in each comes from the grouping's own
// p13n_href (the page's me/state request: progress_percentage, is_completed).
// Picking another season in the page's picker makes the page request that
// season's own address,
//   .../hubs/series/<id>/season/<n>?schema=3
// and the reader makes that same request. The page's React Query cache holds
// none of this (it is fetched outside it), so the scripts make the page's
// own requests, signed in, from the title's page. No I/O here.

import Foundation

public enum HuluDetails {
    /// Function body for callAsyncJavaScript: true once Hulu has the title's page up.
    public static let readyScript = #"return document.readyState === "complete" && /^\/(series|movie)\/[0-9a-f-]{36}$/i.test(location.pathname);"#

    private static let discover = "https://discover.hulu.com/content/v5/"

    /// JavaScript shared by both scripts: `get` (a signed-in discover request)
    /// and `episodesOf(grouping)` (its episodes with how far the profile is).
    private static let helpers = #"""
    const base = "\#(discover)";
    const get = async url => {
      if (!url.startsWith(base)) throw new Error("not discover");
      const response = await fetch(url, { credentials: "include" });
      if (!response.ok) throw new Error(String(response.status));
      return response.json();
    };
    const episodesOf = async grouping => {
      const items = (grouping.items || []).slice(0, \#(StreamLimits.maxEpisodesPerSeason));
      const state = {};
      if (items.length && grouping.p13n_href) {
        for (const s of (await get(grouping.p13n_href)).items || []) state[s.entity_id] = s;
      }
      return items.map(e => {
        const s = state[e.id] || {}, art = e.artwork && (e.artwork["video.horizontal.hero"] || Object.values(e.artwork)[0]);
        return { id: e.id || null, number: e.number || null, name: e.name || null, synopsis: e.description || null,
                 duration: (e.bundle && e.bundle.duration) || null, progress: s.is_completed ? null : (s.progress_percentage || null),
                 art: (art && art.path) || null };
      });
    };
    """#

    /// Function body for callAsyncJavaScript: the shown title page's hub as a
    /// JSON string, {name, description, rating, premiere, duration, genres,
    /// currentSeasonId, seasons:[{id,name,count,episodes|null}]}; "" on any
    /// error. Only the season the page shows carries its episodes.
    public static let readScript = #"""
    try {
      \#(helpers)
      const m = location.pathname.match(/^\/(series|movie)\/([0-9a-f-]{36})$/i);
      if (!m) return "";
      const hub = await get(base + "hubs/" + m[1] + "/" + m[2] + "?schema=3&limit=1999");
      const entity = (hub.details && hub.details.entity) || {};
      const groups = ((hub.components || []).find(c => c.theme === "collection_theme_groupings") || {}).items || [];
      const focus = (hub.components || []).map(c => c.focus_navigation && c.focus_navigation.collection_id).find(Boolean);
      const shown = groups.find(g => g.id === focus && (g.items || []).length) || groups.find(g => (g.items || []).length);
      const bundle = entity.bundle || (hub.details && hub.details.vod_items && hub.details.vod_items.focus && hub.details.vod_items.focus.entity && hub.details.vod_items.focus.entity.bundle) || {};
      const vod = hub.details && hub.details.vod_items && hub.details.vod_items.focus;
      const playing = vod && vod.entity && vod.entity._type === "episode" ? vod.entity : null;
      return JSON.stringify({
        playId: playing ? playing.id || null : null,
        playSeason: playing ? playing.season_short_display_name || null : null, playNumber: playing ? playing.number || null : null,
        name: entity.name || null, description: entity.description || null, rating: entity.rating && entity.rating.code || null,
        premiere: entity.premiere_date || null, duration: bundle.duration || null, genres: entity.genre_names || [],
        currentSeasonId: shown ? shown.id : null,
        seasons: groups.slice(0, \#(StreamLimits.maxSeasons)).map(g => ({
          id: g.id || null, name: g.name || null, count: g.pagination && g.pagination.total_count || null, episodes: null
        })),
        shownEpisodes: shown ? await episodesOf(shown) : []
      });
    } catch (e) {
      return "";
    }
    """#

    /// Function body for callAsyncJavaScript: the episodes of one season, as
    /// the page's own season request returns them: {"episodes":[...]}; "" on
    /// any error. `seasonID` is a season id readScript gave ("<series>::<n>").
    public static func seasonScript(seasonID: String) -> String {
        #"""
        try {
          \#(helpers)
          const m = \#(StreamJSON.jsString(seasonID)).match(/^([0-9a-f-]{36})::(\d{1,3})$/i);
          if (!m) return "";
          const grouping = await get(base + "hubs/series/" + m[1] + "/season/" + m[2] + "?schema=3&limit=\#(StreamLimits.maxEpisodesPerSeason)");
          return JSON.stringify({ episodes: await episodesOf(grouping) });
        } catch (e) {
          return "";
        }
        """#
    }

    /// The row's title filled in from the page: synopsis, year, rating,
    /// season count, a movie's length, and the seasons (the shown one with
    /// its episodes). Nil for anything that isn't readScript's answer.
    public static func details(fromRead json: String, title: StreamTitle) -> StreamTitleDetails? {
        guard let read = StreamJSON.object(json) else { return nil }
        var filled = title
        // What Play continues: a show from search only knew its own id, which isn't something to play.
        if title.kind == .show, let playID = StreamJSON.token(read["playId"]), let play = HuluHome.playURL(id: playID) {
            let season = StreamJSON.string(read["playSeason"]), number = StreamJSON.string(read["playNumber"])
            let label = season.flatMap { s in number.map { "\(s) · E\($0)" } } ?? title.episodeLabel
            filled = StreamTitle(id: title.id, name: title.name, kind: title.kind, play: play, page: title.page, episodeLabel: label,
                                 synopsis: title.synopsis, year: title.year, rating: title.rating, seasonsLabel: title.seasonsLabel,
                                 runtimeSeconds: title.runtimeSeconds, resumeSeconds: title.resumeSeconds, tileArt: title.tileArt,
                                 heroArt: title.heroArt)
        }
        if let synopsis = StreamJSON.string(read["description"]) { filled.synopsis = synopsis }
        if let rating = StreamJSON.string(read["rating"]) { filled.rating = rating }
        if let year = StreamJSON.string(read["premiere"]).flatMap({ Int($0.prefix(4)) }), (1900...2100).contains(year) { filled.year = year }
        let shownID = StreamJSON.string(read["currentSeasonId"])
        var seasons: [StreamSeason] = []
        var seen = Set<String>()
        for entry in read["seasons"] as? [[String: Any]] ?? [] {
            guard let id = StreamJSON.string(entry["id"]), let name = StreamJSON.string(entry["name"]), seen.insert(id).inserted else { continue }
            seasons.append(StreamSeason(id: id, name: name, episodes: id == shownID ? episodes(in: read, key: "shownEpisodes") : []))
        }
        if title.kind != .movie {
            filled.seasonsLabel = seasons.isEmpty ? nil : seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons"
        } else if let seconds = StreamJSON.int(read["duration"]), seconds > 0 {
            filled.runtimeSeconds = seconds
        }
        let current = seasons.first { $0.id == shownID }?.id ?? (seasons.count == 1 ? seasons[0].id : nil)
        return StreamTitleDetails(title: filled, seasons: seasons, currentSeasonID: current).bounded
    }

    /// Just the episodes from seasonScript's answer.
    public static func episodes(fromSeason json: String) -> [StreamEpisode] {
        StreamJSON.object(json).map { episodes(in: $0, key: "episodes") } ?? []
    }

    private static func episodes(in read: [String: Any], key: String) -> [StreamEpisode] {
        var seen = Set<String>()
        var list: [StreamEpisode] = []
        for entry in read[key] as? [[String: Any]] ?? [] {
            guard list.count < StreamLimits.maxEpisodesPerSeason,
                  let id = StreamJSON.token(entry["id"]), let play = HuluHome.playURL(id: id), seen.insert(id).inserted else { continue }
            let number = StreamJSON.int(entry["number"]) ?? StreamJSON.string(entry["number"]).flatMap { Int($0) }
            let runtime = StreamJSON.int(entry["duration"])
            let resume: Int? = {
                guard let runtime, runtime > 0, let progress = StreamJSON.int(entry["progress"]), (1...100).contains(progress) else { return nil }
                return runtime * progress / 100
            }()
            list.append(StreamEpisode(id: id, name: StreamJSON.string(entry["name"]) ?? number.map { "Episode \($0)" } ?? "Episode",
                                      number: number, synopsis: StreamJSON.string(entry["synopsis"]), runtimeSeconds: runtime,
                                      resumeSeconds: resume, play: play, art: HuluHome.imageURL(entry["art"] as? String, width: 640, height: 360)))
        }
        return list
    }
}
