// Owns: reading a title's own page on Netflix for the shell's details
// screen, as a proxy. netflix.com/title/<id> opens Netflix's details panel;
// the reader reads that panel (its synopsis, its season picker's list, the
// shown season's episode cards) and, to show another season, picks it in
// Netflix's own season picker and reads again. Learned on a real Mac
// (2026-11-11): each episode card's React props carry an `episode` record
// (videoId, number, title, runtimeSec, bookmark.position,
// contextualSynopsis.text, artwork.url) and its section a `seasonId`; the
// picker's toggle carries `options` (each season's videoId and title); a
// long season shows its first ten episodes until its section is expanded.
// No I/O here.

import Foundation

public enum NetflixDetails {
    /// Function body for callAsyncJavaScript: true once the details panel shows.
    public static let readyScript = #"return !!(document.querySelector('[data-uia="preview-modal-synopsis"]') || document.querySelector('[data-uia="episode-selector"]'));"#

    /// Function body for callAsyncJavaScript: the panel as a JSON string,
    /// {synopsis, currentSeasonId, seasonLabel, seasons:[{id,name,count}],
    /// episodes:[{id,number,name,synopsis,runtime,resume,art}]}, expanding a
    /// long season's list first; "" on any error. The episode list draws a
    /// moment after the panel, so for a show it is waited for; a movie has
    /// none; a title of unknown kind (a search result) waits briefly for a
    /// season picker to tell.
    public static func readScript(for kind: StreamTitle.Kind) -> String {
        let expect = kind == .show || kind == .episode ? "episodes" : kind == .movie ? "none" : "unknown"
        return """
    try {
      const expect = "\(expect)";
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const fiberOf = el => el && el[Object.keys(el).find(k => k.startsWith("__reactFiber"))];
      const propUp = (el, name, depth) => {
        for (let p = fiberOf(el), d = 0; p && d < depth; p = p.return, d++) {
          if (p.memoizedProps && p.memoizedProps[name] !== undefined) return p.memoizedProps[name];
        }
        return undefined;
      };
      const episodeCards = () => Array.from(document.querySelectorAll('[data-uia="titleCard--container"]')).filter(c => propUp(c, "episode", 6));
      const picker = () => document.querySelector('[data-uia="episode-selector"]');
      if (expect === "unknown") for (let i = 0; i < 5 && !picker(); i++) await sleep(200);
      if (expect === "episodes" || (expect === "unknown" && picker())) {
        for (let i = 0; i < 15 && episodeCards().length === 0; i++) await sleep(200);
      }
      const before = episodeCards().length;
      let expanded = false;
      for (const button of before ? document.querySelectorAll('[data-uia="section-expand"]') : []) {
        let box = button.parentElement;
        for (let up = 0; box && up < 6 && !box.querySelector('[data-uia="titleCard--container"]'); up++) box = box.parentElement;
        if (box && Array.from(box.querySelectorAll('[data-uia="titleCard--container"]')).some(c => propUp(c, "episode", 6))) { button.click(); expanded = true; break; }
      }
      for (let i = 0; expanded && i < 15 && episodeCards().length === before; i++) await sleep(200);
      const cards = episodeCards().slice(0, \(StreamLimits.maxEpisodesPerSeason));
      const toggle = document.querySelector('[data-uia="dropdown-toggle"]');
      const options = propUp(toggle, "options", 8) || [];
      const synopsis = document.querySelector('[data-uia="preview-modal-synopsis"]');
      return JSON.stringify({
        synopsis: synopsis ? synopsis.textContent.trim() : null,
        currentSeasonId: cards.length ? (propUp(cards[0], "seasonId", 8) || null) : null,
        seasonLabel: toggle ? toggle.textContent.trim() : null,
        seasons: options.slice(0, \(StreamLimits.maxSeasons)).map(s => ({ id: s && s.videoId, name: s && s.title, count: s && s.episodes && s.episodes.totalCount })),
        episodes: cards.map(c => {
          const e = propUp(c, "episode", 6);
          return { id: e.videoId, number: e.number, name: e.title, synopsis: e.contextualSynopsis && e.contextualSynopsis.text,
                   runtime: e.runtimeSec, resume: e.bookmark && e.bookmark.position, art: e.artwork && e.artwork.url };
        })
      });
    } catch (e) {
      return "";
    }
    """
    }

    /// Function body for callAsyncJavaScript: picks a season in Netflix's own
    /// season picker (by its name, as `seasons` gave it); true when picked or
    /// already shown.
    public static func chooseSeasonScript(seasonName: String) -> String {
        """
        // Netflix separates an item's name from its count with non-breaking spaces: compare words, not bytes.
        const norm = text => (text || "").replace(/\\s+/g, " ").trim();
        const name = norm(\(StreamJSON.jsString(seasonName)));
        const toggle = document.querySelector('[data-uia="dropdown-toggle"]');
        if (!toggle) return false;
        if (norm(toggle.textContent) === name) return true;
        const findItem = () => Array.from(document.querySelectorAll('[data-uia="dropdown-menu-item"]'))
          .find(e => { const t = norm(e.textContent); return t === name || t.startsWith(name + " "); });
        // The menu may already be open: clicking the toggle then would close it.
        let item = findItem();
        if (!item) {
          toggle.click();
          for (let i = 0; i < 20 && !(item = findItem()); i++) await new Promise(r => setTimeout(r, 150));
        }
        if (!item) return false;
        item.click();
        return true;
        """
    }

    /// Function body for callAsyncJavaScript: true when the shown episode
    /// cards belong to this season.
    public static func seasonShownScript(seasonID: String) -> String {
        """
        const want = \(StreamJSON.jsString(seasonID));
        const fiberOf = el => el && el[Object.keys(el).find(k => k.startsWith("__reactFiber"))];
        for (const card of document.querySelectorAll('[data-uia="titleCard--container"]')) {
          let episode = false, season = null;
          for (let p = fiberOf(card), d = 0; p && d < 8; p = p.return, d++) {
            const props = p.memoizedProps || {};
            if (props.episode) episode = true;
            if (props.seasonId !== undefined && season === null) season = props.seasonId;
          }
          if (episode) return String(season) === want;
        }
        return false;
        """
    }

    /// The row's title filled in from the panel: synopsis, seasons (the shown
    /// one with its episodes), the season Play continues in. Nil for anything
    /// that isn't readScript's answer.
    public static func details(fromRead json: String, title: StreamTitle) -> StreamTitleDetails? {
        guard let read = StreamJSON.object(json) else { return nil }
        var filled = title
        if let synopsis = (read["synopsis"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !synopsis.isEmpty {
            filled.synopsis = synopsis
        }
        let shownID = StreamJSON.numericID(read["currentSeasonId"])
        let shownEpisodes = episodes(in: read)
        var seasons: [StreamSeason] = []
        var seen = Set<String>()
        for entry in read["seasons"] as? [[String: Any]] ?? [] {
            guard let seasonID = StreamJSON.numericID(entry["videoId"] ?? entry["id"]),
                  let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  seen.insert(seasonID).inserted else { continue }
            seasons.append(StreamSeason(id: seasonID, name: name, episodes: seasonID == shownID ? shownEpisodes : []))
        }
        // A show without a picker (one season, or a limited series): its label names the one season.
        if seasons.isEmpty, !shownEpisodes.isEmpty {
            let label = (read["seasonLabel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            seasons = [StreamSeason(id: shownID ?? title.id, name: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Episodes",
                                    episodes: shownEpisodes)]
        }
        let current = seasons.first { $0.id == shownID }?.id ?? (seasons.count == 1 ? seasons[0].id : nil)
        return StreamTitleDetails(title: filled, seasons: seasons, currentSeasonID: current).bounded
    }

    /// Just the shown season's episodes from readScript's answer.
    public static func episodes(fromRead json: String) -> [StreamEpisode] {
        StreamJSON.object(json).map(episodes(in:)) ?? []
    }

    // MARK: Plumbing

    private static func episodes(in read: [String: Any]) -> [StreamEpisode] {
        var seen = Set<String>()
        var list: [StreamEpisode] = []
        for entry in read["episodes"] as? [[String: Any]] ?? [] {
            guard list.count < StreamLimits.maxEpisodesPerSeason,
                  let episodeID = StreamJSON.numericID(entry["id"]), let play = NetflixHome.playURL(videoID: episodeID),
                  seen.insert(episodeID).inserted else { continue }
            let number = StreamJSON.int(entry["number"])
            let name = StreamJSON.string(entry["name"])
            let art = StreamJSON.httpsURL(entry["art"])
            list.append(StreamEpisode(id: episodeID,
                                      name: name ?? number.map { "Episode \($0)" } ?? "Episode",
                                      number: number, synopsis: entry["synopsis"] as? String,
                                      runtimeSeconds: StreamJSON.int(entry["runtime"]), resumeSeconds: StreamJSON.int(entry["resume"]),
                                      play: play, art: art))
        }
        return list
    }

}
