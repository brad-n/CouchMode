// Owns: reading a title's details and a season's episodes on Disney+ for the
// shell's details screen, as a proxy. Learned on a real Mac (2026-11-11): a
// title's page (/browse/entity-<uuid>) asks the explore API for
//   page/entity-<uuid>
// whose page has the title's facts (title, description, rating, year, runtime
// for a movie, "N Seasons" for a show), its page-level actions (a playback
// action per choice: "resume" and "from_beginning" when partly watched, "play"
// otherwise; its deeplinkId is what /play/<id> plays) and, for a show, an
// "episodes" container listing the seasons (id, name, "8 Episodes") and which
// one the profile is in (focus.seasonId). With the page's items left out
// (enhancedContainersLimit=0) the season's episodes come from the request the
// page's season picker makes,
//   season/<seasonId>
// whose items carry the episode (title, number, runtime, artwork, progress)
// and its own playback action. The reader makes these same requests from a
// Disney page, signed in. No I/O here.
//
// readScript's answer: {"id","name","desc","year","rating","series","runtimeMs",
//  "pct","seasonsLabel","playId","resumes","tile","wide","currentSeasonId",
//  "seasons":[{"id","name","count"}]}
// seasonScript's answer: {"episodes":[{"id","playId","name","number","desc",
//  "durationMs","pct","left","art"}]}

import Foundation

public enum DisneyDetails {
    private static let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

    private static func isUUID(_ text: String) -> Bool { text.range(of: uuidPattern, options: .regularExpression) != nil }

    /// Function body for callAsyncJavaScript: the title's page as the JSON
    /// above; "" on any error. Nil for an id that isn't a plain uuid.
    public static func readScript(entityID: String) -> String? {
        guard isUUID(entityID) else { return nil }
        return #"""
        try {
          \#(DisneyExplore.helpers)
          const page = (await get("page/entity-" + \#(StreamJSON.jsString(entityID)) + "?disableSmartFocus=true&enhancedContainersLimit=0&limit=1")).data.page;
          const v = page.visuals || {}, m = v.metastringParts || {}, std = (v.artwork || {}).standard || {}, description = v.description || {};
          const image = o => (o && o["1.78"] && o["1.78"].imageId) || null;
          const plays = (page.actions || []).filter(a => a.type === "playback");
          const kindOf = a => ((a.options || [])[0] || {}).type;
          const play = plays.find(a => kindOf(a) === "resume") || plays[0] || null;
          const episodes = (page.containers || []).find(c => c.type === "episodes");
          const progress = (page.personalization && page.personalization.userState && page.personalization.userState.progress) || {};
          const out = JSON.stringify({
            id: \#(StreamJSON.jsString(entityID)), name: v.title || null,
            desc: String(description.full || description.medium || description.brief || "").slice(0, 1200) || null,
            year: (m.releaseYearRange && m.releaseYearRange.startYear) || null,
            rating: (m.ratingInfo && m.ratingInfo.rating && m.ratingInfo.rating.text) || null,
            series: !!episodes, runtimeMs: (m.runtime && m.runtime.runtimeMs) || null,
            pct: progress.progressPercentage == null ? null : progress.progressPercentage,
            seasonsLabel: m.seasonsAvailable || null,
            playId: play ? play.deeplinkId || null : null, resumes: !!play && kindOf(play) === "resume",
            tile: image(std.tile) || image(std.background), wide: image(std.background) || image(std.tile),
            currentSeasonId: (episodes && episodes.focus && episodes.focus.seasonId) || null,
            seasons: ((episodes && episodes.seasons) || []).slice(0, \#(StreamLimits.maxSeasons)).map(s => ({
              id: s.id || null, name: (s.visuals && s.visuals.name) || null, count: (s.visuals && s.visuals.episodeCountDisplayText) || null
            }))
          });
          return out.length > \#(DisneyExplore.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// Function body for callAsyncJavaScript: the episodes of one season as the
    /// JSON above; "" on any error. Nil for an id that isn't a plain uuid.
    public static func seasonScript(seasonID: String) -> String? {
        guard isUUID(seasonID) else { return nil }
        return #"""
        try {
          \#(DisneyExplore.helpers)
          const season = (await get("season/" + \#(StreamJSON.jsString(seasonID)) + "?limit=\#(StreamLimits.maxEpisodesPerSeason)")).data.season;
          const image = o => (o && o["1.78"] && o["1.78"].imageId) || null;
          const episodes = (season.items || []).slice(0, \#(StreamLimits.maxEpisodesPerSeason)).map(item => {
            const v = item.visuals || {}, std = (v.artwork || {}).standard || {}, description = v.description || {};
            const play = (item.actions || []).find(a => a.type === "playback");
            const progress = (item.personalization && item.personalization.userState && item.personalization.userState.progress) || {};
            return {
              id: item.id || null, playId: play ? play.deeplinkId || null : null, name: v.episodeTitle || v.title || null,
              number: v.episodeNumber || null, desc: String(description.medium || description.brief || "").slice(0, 400) || null,
              durationMs: v.durationMs || (v.metastringParts && v.metastringParts.runtime && v.metastringParts.runtime.runtimeMs) || null,
              pct: progress.progressPercentage == null ? null : progress.progressPercentage,
              left: progress.secondsRemaining == null ? null : progress.secondsRemaining,
              art: image(std.thumbnail) || image(std.tile)
            };
          });
          const out = JSON.stringify({ episodes });
          return out.length > \#(DisneyExplore.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// The row's title filled in from the page: what it is (a movie or a
    /// show), synopsis, year, rating, a movie's length and place, a show's
    /// season count, the address Play uses, and the seasons (their episodes
    /// arrive when one is opened). Nil for anything that isn't readScript's answer.
    public static func details(fromRead json: String, title: StreamTitle) -> StreamTitleDetails? {
        guard let read = StreamJSON.object(json) else { return nil }
        let isSeries = read["series"] as? Bool ?? (title.kind == .show)
        // Kind and Play address are fixed at creation, so the title is rebuilt with what the page knows.
        var filled = StreamTitle(id: title.id, name: title.name, kind: isSeries ? .show : .movie,
                                 play: DisneyExplore.playURL(id: read["playId"] as? String ?? "") ?? title.play, page: title.page,
                                 episodeLabel: title.episodeLabel, synopsis: title.synopsis, year: title.year, rating: title.rating,
                                 seasonsLabel: title.seasonsLabel, runtimeSeconds: title.runtimeSeconds, resumeSeconds: title.resumeSeconds,
                                 tileArt: title.tileArt, heroArt: title.heroArt)
        if let synopsis = StreamJSON.string(read["desc"]) { filled.synopsis = synopsis }
        if let rating = StreamJSON.string(read["rating"]) { filled.rating = rating }
        if let year = DisneyExplore.year(read["year"]) { filled.year = year }
        if let wide = DisneyExplore.imageURL(read["wide"] as? String, width: 1920) { filled.heroArt = wide }
        if filled.tileArt == nil { filled.tileArt = DisneyExplore.imageURL(read["tile"] as? String, width: 640) }
        var seasons: [StreamSeason] = []
        var seen = Set<String>()
        for entry in read["seasons"] as? [[String: Any]] ?? [] {
            guard let id = StreamJSON.token(entry["id"]), let name = StreamJSON.string(entry["name"]), seen.insert(id).inserted else { continue }
            seasons.append(StreamSeason(id: id, name: name))
        }
        if isSeries {
            filled.seasonsLabel = StreamJSON.string(read["seasonsLabel"]) ?? (seasons.isEmpty ? nil : seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons")
        } else {
            filled.seasonsLabel = nil
            let runtimeMs = StreamJSON.int(read["runtimeMs"])
            if let runtimeMs, runtimeMs > 0 { filled.runtimeSeconds = runtimeMs / 1000 }
            filled.resumeSeconds = DisneyExplore.resumeSeconds(runtimeMs: runtimeMs, percent: StreamJSON.int(read["pct"]), left: nil)
        }
        let focus = StreamJSON.token(read["currentSeasonId"])
        let current = seasons.first { $0.id == focus }?.id ?? (seasons.count == 1 ? seasons[0].id : nil)
        return StreamTitleDetails(title: filled, seasons: isSeries ? seasons : [], currentSeasonID: isSeries ? current : nil).bounded
    }

    /// Just the episodes from seasonScript's answer: each with a plain id and a
    /// player address, once, at most maxEpisodesPerSeason.
    public static func episodes(fromSeason json: String) -> [StreamEpisode] {
        var seen = Set<String>()
        var list: [StreamEpisode] = []
        for entry in (StreamJSON.object(json)?["episodes"] as? [[String: Any]]) ?? [] {
            guard list.count < StreamLimits.maxEpisodesPerSeason, let id = StreamJSON.token(entry["id"]),
                  let play = DisneyExplore.playURL(id: entry["playId"] as? String ?? ""), seen.insert(id).inserted else { continue }
            let number = StreamJSON.numericID(entry["number"]).flatMap { Int($0) }
            let runtimeMs = StreamJSON.int(entry["durationMs"])
            list.append(StreamEpisode(id: id, name: StreamJSON.string(entry["name"]) ?? number.map { "Episode \($0)" } ?? "Episode",
                                      number: number, synopsis: StreamJSON.string(entry["desc"]),
                                      runtimeSeconds: runtimeMs.flatMap { $0 > 0 ? $0 / 1000 : nil },
                                      resumeSeconds: DisneyExplore.resumeSeconds(runtimeMs: runtimeMs, percent: StreamJSON.int(entry["pct"]),
                                                                                  left: StreamJSON.int(entry["left"])),
                                      play: play, art: DisneyExplore.imageURL(entry["art"] as? String, width: 640)))
        }
        return list
    }
}
