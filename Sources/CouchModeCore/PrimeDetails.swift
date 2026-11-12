// Owns: reading a Prime Video title's details and a season's episodes for the
// shell's details screen, as a proxy. Learned on a real Mac (2026-11-11): a
// title's page (/detail/<id>) carries its data in the page's state (see
// PrimeSite), under body.atf.state (above the fold) and body.btf.state:
//   pageTitleId                          the page's own id (a "gti")
//   detail.headerDetail[gti]             title ("Show - Season 2" on a season page),
//                                        parentTitle, synopsis, releaseYear, ratingBadge,
//                                        runtime ("1 h 33 min" on a movie), images, seasonNumber,
//                                        titleType ("movie" or "season")
//   action.atf[gti].primaryActions       the first PLAY action's payload.playback: playbackURL
//                                        (/detail/<id of what plays>?autoplay=1&t=<seconds>),
//                                        resumeTime, runTime and a label ("Resume S2 E3",
//                                        "Play Episode 1"). A title to rent, buy or get through
//                                        a channel has no PLAY primary action.
//   seasons[...]                         for a show with several seasons, each season's
//                                        seasonLink (/detail/<season id>), displayName,
//                                        sequenceNumber, isSelected
//   btf.episodeList.cardTitleIds         the loaded season's episodes (one page of them), each
//                                        with btf.detail.detail[id] (episodeNumber, title, synopsis,
//                                        duration, images) and its own PLAY action
// A season is its own page, so reading another season's episodes is opening that
// season's page, as the site's season picker does. The reader opens one page per
// action and reads that data. No I/O here.
//
// readScript's answer: {"id","name","title","type","titleType","seasonNumber","year","rating","desc",
//  "art","runtimeText","play":{"id","resume","run","label"}|null,"currentSeasonId","seasons":[{"id","name","number"}],
//  "episodes":[{"id","number","name","desc","run","resume","art","playId"}]}

import Foundation

public enum PrimeDetails {
    static let maxEpisodes = StreamLimits.maxEpisodesPerSeason

    /// Prime's own page for a title or season id.
    public static func pageURL(forID id: String) -> URL? { PrimeSite.pageURL(id: id) }

    /// Function body for callAsyncJavaScript: true once the page's data holds this title's details.
    public static let readyScript = #"""
    try {
      \#(PrimeSite.hydration)
      const d = hydration();
      const state = d && d.init && d.init.route && d.init.route.name === "detail" && d.init.preparations.body.atf.state;
      return !!state && !!state.pageTitleId && !!state.detail && !!state.detail.headerDetail && !!state.detail.headerDetail[state.pageTitleId];
    } catch (e) {
      return false;
    }
    """#

    /// Function body for callAsyncJavaScript: the title's page as the JSON above; "" on any error.
    public static let readScript = #"""
    try {
      \#(PrimeSite.hydration)
      \#(PrimeSite.cardFunction)
      const body = bodyOf();
      const A = body.atf.state, B = (body.btf && body.btf.state) || {};
      const gti = A.pageTitleId, h = A.detail.headerDetail[gti];
      const playOf = action => {
        const p = ((action && action.primaryActions) || []).find(a => a.actionType === "PLAY" && a.payload && a.payload.playback && !a.payload.playback.isTrailer);
        return p ? p.payload.playback : null;
      };
      const pb = playOf((A.action && A.action.atf && A.action.atf[gti]) || null);
      const play = pb && pathID(pb.playbackURL) ? { id: pathID(pb.playbackURL), resume: pb.resumeTime || 0, run: pb.runTime || null, label: pb.label || "" } : null;
      const seasonLists = Object.values(A.seasons || {}).filter(Array.isArray);
      const seasons = (seasonLists[0] || []).slice(0, \#(StreamLimits.maxSeasons)).map(s => ({
        id: pathID(s.seasonLink), name: s.displayName || null, number: s.sequenceNumber || null, selected: !!s.isSelected
      }));
      const selected = seasons.find(s => s.selected);
      const ids = ((B.episodeList && B.episodeList.cardTitleIds) || []).slice(0, \#(maxEpisodes));
      const episodes = ids.map(id => {
        const d = (B.detail && B.detail.detail && B.detail.detail[id]) || {};
        const self = (B.self && B.self[id]) || {};
        const epPlay = playOf((B.action && B.action.btf && B.action.btf[id]) || null);
        const images = d.images || {};
        return {
          id: pathID(self.link), number: d.episodeNumber || null, name: d.title || null, desc: String(d.synopsis || "").slice(0, 400) || null,
          run: (epPlay && epPlay.runTime) || d.duration || null, resume: (epPlay && epPlay.resumeTime) || 0,
          art: images.covershot || images.packshot || null, playId: epPlay ? pathID(epPlay.playbackURL) : null
        };
      });
      const images = h.images || {};
      const out = JSON.stringify({
        id: pathID(location.pathname), name: h.parentTitle || h.title || null, title: h.title || null, type: h.entityType || null,
        titleType: h.titleType || null, seasonNumber: h.seasonNumber || null, year: Number(h.releaseYear) || null,
        rating: (h.ratingBadge && h.ratingBadge.displayText) || null, desc: String(h.synopsis || "").slice(0, 1200) || null,
        art: images.heroshot || images.titleshot || images.packshot || null, runtimeText: h.runtime || "", play,
        currentSeasonId: selected ? selected.id : null,
        seasons: seasons.map(s => ({ id: s.id, name: s.name, number: s.number })), episodes
      });
      return out.length > \#(PrimeSite.maxScriptBytes) ? "" : out;
    } catch (e) {
      return "";
    }
    """#

    // MARK: Parsing

    /// The row's title filled in from the page: what it is (a movie or a show),
    /// synopsis, year, rating, a movie's length and place, a show's season count, the
    /// address Play uses (the page itself where Prime offers no playback), and the
    /// seasons (the open one carries its episodes; the others load when opened).
    /// Nil for anything that isn't readScript's answer.
    public static func details(fromRead json: String, title: StreamTitle) -> StreamTitleDetails? {
        guard let read = StreamJSON.object(json), read["name"] != nil || read["title"] != nil else { return nil }
        let isSeries = read["titleType"] as? String == "season" || !(read["episodes"] as? [[String: Any]] ?? []).isEmpty
        let play = read["play"] as? [String: Any]
        let resume = StreamJSON.int(play?["resume"]).flatMap { $0 > 0 ? $0 : nil }
        let run = StreamJSON.int(play?["run"]).flatMap { $0 > 0 ? $0 : nil } ?? seconds(fromRuntimeText: read["runtimeText"] as? String ?? "")
        var seasons = parseSeasons(read["seasons"] as? [[String: Any]] ?? [])
        let episodes = episodes(fromRead: json)
        var currentSeason = StreamJSON.string(read["currentSeasonId"]).flatMap { id in seasons.first { $0.id == id }?.id }
        let seasonNumber = StreamJSON.numericID(read["seasonNumber"]).flatMap { Int($0) }
        if seasons.isEmpty, isSeries, let id = (read["id"] as? String).flatMap({ PrimeSite.pageURL(id: $0) == nil ? nil : $0 }) {
            seasons = [StreamSeason(id: id, name: seasonNumber.map { "Season \($0)" } ?? "Season 1")]
            currentSeason = id
        }
        if let current = currentSeason, let i = seasons.firstIndex(where: { $0.id == current }) { seasons[i].episodes = episodes }
        var filled = StreamTitle(id: title.id, name: StreamJSON.string(read["name"]) ?? title.name, kind: isSeries ? .show : .movie,
                                 play: (play?["id"] as? String).flatMap { PrimeSite.playURL(id: $0, resumeSeconds: resume) } ?? title.page ?? title.play,
                                 page: title.page, episodeLabel: nil, synopsis: title.synopsis, year: title.year, rating: title.rating,
                                 seasonsLabel: nil, runtimeSeconds: title.runtimeSeconds, resumeSeconds: nil,
                                 tileArt: title.tileArt, heroArt: title.heroArt)
        if let synopsis = StreamJSON.string(read["desc"]) { filled.synopsis = synopsis }
        if let rating = StreamJSON.string(read["rating"]) { filled.rating = rating }
        if let year = PrimeSite.year(read["year"]) { filled.year = year }
        if let wide = PrimeSite.imageURL(read["art"] as? String, width: 1920) { filled.heroArt = wide }
        if filled.tileArt == nil { filled.tileArt = PrimeSite.imageURL(read["art"] as? String, width: 640) }
        filled.runtimeSeconds = run
        if play != nil { filled.resumeSeconds = resume }
        if isSeries {
            filled.seasonsLabel = seasons.isEmpty ? nil : seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons"
            if play != nil { filled.episodeLabel = episodeLabel(play?["label"] as? String, playID: play?["id"] as? String, episodes: episodes, season: seasonNumber) }
        }
        return StreamTitleDetails(title: filled, seasons: isSeries ? seasons : [], currentSeasonID: isSeries ? currentSeason : nil).bounded
    }

    /// Just the episodes from readScript's answer: each with a plain id and a player
    /// address, once, at most maxEpisodesPerSeason.
    public static func episodes(fromRead json: String) -> [StreamEpisode] {
        var seen = Set<String>()
        var list: [StreamEpisode] = []
        for entry in (StreamJSON.object(json)?["episodes"] as? [[String: Any]]) ?? [] {
            let resume = StreamJSON.int(entry["resume"]).flatMap { $0 > 0 ? $0 : nil }
            guard list.count < maxEpisodes, let id = entry["id"] as? String, PrimeSite.pageURL(id: id) != nil,
                  let play = (entry["playId"] as? String).flatMap({ PrimeSite.playURL(id: $0, resumeSeconds: resume) }),
                  seen.insert(id).inserted else { continue }
            let number = StreamJSON.numericID(entry["number"]).flatMap { Int($0) }
            let run = StreamJSON.int(entry["run"]).flatMap { $0 > 0 ? $0 : nil }
            list.append(StreamEpisode(id: id, name: StreamJSON.string(entry["name"]) ?? number.map { "Episode \($0)" } ?? "Episode",
                                      number: number, synopsis: StreamJSON.string(entry["desc"]), runtimeSeconds: run,
                                      resumeSeconds: run.flatMap { total in resume.flatMap { $0 < total ? $0 : nil } },
                                      play: play, art: PrimeSite.imageURL(entry["art"] as? String, width: 640)))
        }
        return list
    }

    private static func parseSeasons(_ entries: [[String: Any]]) -> [StreamSeason] {
        var seen = Set<String>()
        var seasons: [StreamSeason] = []
        for entry in entries {
            guard let id = entry["id"] as? String, PrimeSite.pageURL(id: id) != nil, seen.insert(id).inserted else { continue }
            let number = StreamJSON.numericID(entry["number"])
            seasons.append(StreamSeason(id: id, name: StreamJSON.string(entry["name"]) ?? number.map { "Season \($0)" } ?? "Season"))
        }
        return seasons
    }

    /// "S2 · E3" from the Play button's own label ("Resume S2 E3") or, for "Play Episode 3",
    /// from the page's season and that episode.
    private static func episodeLabel(_ label: String?, playID: String?, episodes: [StreamEpisode], season: Int?) -> String? {
        if let label, let m = label.range(of: #"S(\d{1,3})\s*E(\d{1,4})"#, options: .regularExpression) {
            let parts = label[m].dropFirst().split(whereSeparator: { $0 == "E" || $0 == " " })
            if parts.count == 2 { return "S\(parts[0]) · E\(parts[1])" }
        }
        var number = episodes.first { $0.play.path.hasSuffix("/" + (playID ?? "-")) }?.number
        if number == nil, let label, let m = label.range(of: #"Episode (\d{1,4})"#, options: .regularExpression) {
            number = Int(label[m].dropFirst("Episode ".count))
        }
        guard let number else { return nil }
        return "S\(season ?? 1) · E\(number)"
    }

    /// Seconds from the page's length text: "1 h 33 min", "55min", "2 h".
    static func seconds(fromRuntimeText text: String) -> Int? {
        func number(before unit: String) -> Int? {
            guard let r = text.range(of: #"(\d{1,3})\s*"# + unit, options: .regularExpression) else { return nil }
            return Int(text[r].prefix { $0.isNumber })
        }
        let hours = number(before: "h"), minutes = number(before: "min")
        guard hours != nil || minutes != nil else { return nil }
        return (hours ?? 0) * 3600 + (minutes ?? 0) * 60
    }
}
