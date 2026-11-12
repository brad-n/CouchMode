// Owns: reading a title's details and a season's episodes on Apple TV for the
// shell's details screen, as a proxy. Learned on a real Mac (2026-11-12): a
// title's page asks the API for
//   shows/<id>  or  movies/<id>
// whose answer has the title's facts (description, rating, release date, a
// movie's length), for a show its seasons (id, number, name) and the "smart"
// episode Play continues with (the one in progress, else the next), the play
// state of what plays (where it stopped) and whether this account can play it.
// A season's episodes come from
//   shows/<id>/episodes?selectedSeasonId=<season id>
// which answers a window of episodes across the whole show, indexed in order,
// starting at the first of that season and about ten long; the next window is
//   shows/<id>/episodes?selectedEpisodeId=<last episode id>
// The reader makes these same requests from an Apple TV page, signed in, and for a
// season keeps asking for the next window until the season ends, at most
// maxWindows requests, so a long season may be cut short. No I/O here.
//
// readScript's answer: {"id","kind","name","desc","year","rating","runtime","resume","canPlay","page","episodeURL",
//  "season","episode","tile","wide","currentSeasonId","seasons":[{"id","name"}]}
// seasonScript's answer: {"episodes":[{"id","name","number","desc","runtime","resume","url","canPlay","art"}]}

import Foundation

public enum AppleTVDetails {
    /// Most requests one season read may make (each answers about ten episodes).
    static let maxWindows = 6

    /// Function body for callAsyncJavaScript: the title's page data as the JSON
    /// above; "" on any error. Nil for an id that isn't a plain id.
    public static func readScript(id: String, kind: StreamTitle.Kind) -> String? {
        guard AppleTVSite.isID(id), kind == .movie || kind == .show else { return nil }
        let path = (kind == .movie ? "movies/" : "shows/") + id
        return #"""
        try {
          \#(AppleTVSite.helpers)
          \#(AppleTVSite.imageFunction)
          \#(AppleTVSite.entitledFunction)
          const data = (await get(\#(StreamJSON.jsString(path)))).data;
          const c = data.content || {}, smart = data.smartEpisode || null;
          const playables = Object.values(data.playables || {}).filter(p => p && p.contentType !== "Extra");
          const event = playables.map(p => p.playEvent).find(e => e && e.isDone !== true && e.contentPlayCursorInSeconds > 0) || null;
          const seasons = Object.values(data.seasons || {}).filter(s => s && typeof s.id === "string")
            .sort((a, b) => (a.seasonNumber || 0) - (b.seasonNumber || 0)).slice(0, \#(StreamLimits.maxSeasons))
            .map(s => ({ id: s.id, name: s.title || (s.seasonNumber ? "Season " + s.seasonNumber : null) }));
          const out = JSON.stringify({
            id: \#(StreamJSON.jsString(id)), kind: \#(StreamJSON.jsString(kind == .movie ? "movie" : "show")), name: c.title || null,
            desc: String(c.description || c.heroDescription || "").slice(0, 1200) || null,
            year: typeof c.releaseDate === "number" ? new Date(c.releaseDate).getUTCFullYear() : null,
            rating: (c.rating && c.rating.displayName) || null,
            runtime: c.duration || (event && event.contentMediaLengthInSeconds) || (smart && smart.duration) || null,
            resume: event ? event.contentPlayCursorInSeconds : null,
            canPlay: playables.some(entitled),
            page: c.url || null, episodeURL: smart ? smart.url || null : null,
            season: smart ? smart.seasonNumber || null : null, episode: smart ? smart.episodeNumber || null : null,
            tile: landscape(c.images, tileKeys), wide: landscape(c.images, wideKeys),
            currentSeasonId: smart ? smart.seasonId || null : null, seasons
          });
          return out.length > \#(AppleTVSite.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// Function body for callAsyncJavaScript: the episodes of one season as the JSON above;
    /// "" on any error. Nil for ids that aren't plain ids.
    public static func seasonScript(showID: String, seasonID: String) -> String? {
        guard AppleTVSite.isID(showID), AppleTVSite.isID(seasonID) else { return nil }
        return #"""
        try {
          \#(AppleTVSite.helpers)
          \#(AppleTVSite.imageFunction)
          \#(AppleTVSite.entitledFunction)
          const base = "shows/" + \#(StreamJSON.jsString(showID)) + "/episodes", season = \#(StreamJSON.jsString(seasonID));
          const list = [], seen = new Set();
          let extra = { selectedSeasonId: season };
          for (let n = 0; n < \#(maxWindows); n++) {
            const data = (await get(base, extra)).data, episodes = data.episodes || [];
            let added = 0;
            for (const e of episodes) {
              if (e.seasonId !== season || seen.has(e.id) || list.length >= \#(StreamLimits.maxEpisodesPerSeason)) continue;
              seen.add(e.id); added++;
              const p = ((data.episodesPlayables || {})[e.id] || [])[0] || null, event = p && p.playEvent && p.playEvent.isDone !== true ? p.playEvent : null;
              list.push({
                id: e.id, name: e.title || null, number: e.episodeNumber || null, desc: String(e.description || "").slice(0, 400) || null,
                runtime: (event && event.contentMediaLengthInSeconds) || e.duration || null, resume: event ? event.contentPlayCursorInSeconds : null,
                url: e.url || null, canPlay: entitled(p), art: landscape(e.images, tileKeys)
              });
            }
            const last = episodes[episodes.length - 1];
            if (!last || last.seasonId !== season || added === 0 || list.length >= \#(StreamLimits.maxEpisodesPerSeason)
                || last.episodeIndex >= data.totalEpisodeCount - 1) break;
            extra = { selectedEpisodeId: last.id };
          }
          list.sort((a, b) => (a.number || 0) - (b.number || 0));
          const out = JSON.stringify({ episodes: list });
          return out.length > \#(AppleTVSite.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// The row's title filled in from the page: what it is (a movie or a show), synopsis, year,
    /// rating, a movie's length and place, a show's season count and current episode with its place,
    /// the address Play uses (the page's player when this account can play it, else the page itself),
    /// and the seasons (their episodes arrive when one is opened). Nil for anything that isn't
    /// readScript's answer.
    public static func details(fromRead json: String, title: StreamTitle) -> StreamTitleDetails? {
        guard let read = StreamJSON.object(json), read["id"] as? String == title.id else { return nil }
        let isShow = read["kind"] as? String != "movie"
        let page = AppleTVSite.pageURL(read["page"]) ?? title.page
        let playPage = AppleTVSite.pageURL(read["episodeURL"]) ?? page
        let canPlay = read["canPlay"] as? Bool == true
        let play = canPlay ? playPage.flatMap { AppleTVSite.playURL(page: $0) } : nil
        var filled = StreamTitle(id: title.id, name: title.name, kind: isShow ? .show : .movie, play: play ?? page ?? title.play,
                                 page: page, episodeLabel: nil, synopsis: title.synopsis, year: title.year, rating: title.rating,
                                 seasonsLabel: nil, runtimeSeconds: title.runtimeSeconds, resumeSeconds: title.resumeSeconds,
                                 tileArt: title.tileArt, heroArt: title.heroArt)
        if let synopsis = StreamJSON.string(read["desc"]) { filled.synopsis = synopsis }
        if let rating = StreamJSON.string(read["rating"]) { filled.rating = rating }
        if let year = AppleTVSite.year(read["year"]) { filled.year = year }
        if let wide = AppleTVSite.image(read["wide"], width: 1920) { filled.heroArt = wide }
        if filled.tileArt == nil { filled.tileArt = AppleTVSite.image(read["tile"], width: 640) }
        let runtime = StreamJSON.int(read["runtime"]).flatMap { $0 > 0 ? $0 : nil }
        filled.runtimeSeconds = runtime ?? title.runtimeSeconds
        filled.resumeSeconds = AppleTVSite.resumeSeconds(runtime: filled.runtimeSeconds, cursor: StreamJSON.int(read["resume"]))
        var seasons: [StreamSeason] = []
        var seen = Set<String>()
        for entry in read["seasons"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, AppleTVSite.isID(id), seen.insert(id).inserted else { continue }
            seasons.append(StreamSeason(id: id, name: StreamJSON.string(entry["name"]) ?? "Season \(seasons.count + 1)"))
        }
        if isShow {
            let season = StreamJSON.numericID(read["season"]), episode = StreamJSON.numericID(read["episode"])
            filled.episodeLabel = season.flatMap { s in episode.map { "S\(s) · E\($0)" } } ?? title.episodeLabel
            filled.seasonsLabel = seasons.isEmpty ? nil : seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons"
        } else {
            filled.runtimeSeconds = runtime ?? title.runtimeSeconds
        }
        let focus = read["currentSeasonId"] as? String
        let current = seasons.first { $0.id == focus }?.id ?? (seasons.count == 1 ? seasons[0].id : nil)
        return StreamTitleDetails(title: filled, seasons: isShow ? seasons : [], currentSeasonID: isShow ? current : nil).bounded
    }

    /// Just the episodes from seasonScript's answer: each with a plain id and a play address, once, at
    /// most maxEpisodesPerSeason. An episode this account can't play carries its page as the address.
    public static func episodes(fromSeason json: String) -> [StreamEpisode] {
        var seen = Set<String>()
        var list: [StreamEpisode] = []
        for entry in (StreamJSON.object(json)?["episodes"] as? [[String: Any]]) ?? [] {
            guard list.count < StreamLimits.maxEpisodesPerSeason, let id = entry["id"] as? String, AppleTVSite.isID(id),
                  let page = AppleTVSite.pageURL(entry["url"]), seen.insert(id).inserted else { continue }
            let number = StreamJSON.numericID(entry["number"]).flatMap { Int($0) }
            let runtime = StreamJSON.int(entry["runtime"]).flatMap { $0 > 0 ? $0 : nil }
            let play = (entry["canPlay"] as? Bool == true ? AppleTVSite.playURL(page: page) : nil) ?? page
            list.append(StreamEpisode(id: id, name: StreamJSON.string(entry["name"]) ?? number.map { "Episode \($0)" } ?? "Episode",
                                      number: number, synopsis: StreamJSON.string(entry["desc"]), runtimeSeconds: runtime,
                                      resumeSeconds: AppleTVSite.resumeSeconds(runtime: runtime, cursor: StreamJSON.int(entry["resume"])),
                                      play: play, art: AppleTVSite.image(entry["art"], width: 640)))
        }
        return list
    }
}
