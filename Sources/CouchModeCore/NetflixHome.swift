// Owns: reading Netflix's signed-in home (netflix.com/browse) into the
// shell's own StreamHome. The page keeps its data in a normalized GraphQL
// cache (Apollo style, window.netflix.reactContext.models.graphql.data):
// flat records that point at each other by {"__ref": key}. This follows
// those references from the browse page to its sections, treatments, titles
// and profiles, and builds Netflix's own player/page/profile-switch
// addresses. Pure: the cache arrives as JSON data and nothing is fetched.

import Foundation

public enum NetflixHome {
    public static let serviceID = "netflix"
    /// Largest cache (in characters) the extract script will hand back.
    public static let maxCacheBytes = 4 << 20

    // MARK: Addresses

    public static func playURL(videoID: String) -> URL? { titleURL("watch", videoID) }
    public static func pageURL(videoID: String) -> URL? { titleURL("title", videoID) }

    public static func switchProfileURL(profileID: String) -> URL? {
        guard (1...64).contains(profileID.count), profileID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return URL(string: "https://www.netflix.com/SwitchProfile?tkn=\(profileID)")
    }

    private static func titleURL(_ path: String, _ id: String) -> URL? {
        guard (1...20).contains(id.count), id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://www.netflix.com/\(path)/\(id)")
    }

    // MARK: Page script

    /// A JavaScript function body (for callAsyncJavaScript) returning the
    /// GraphQL cache as a JSON string, or "" when absent, too long or on error.
    public static let extractScript: String = """
    try {
      var data = window.netflix.reactContext.models.graphql.data;
      if (!data) { return ""; }
      var text = JSON.stringify(data);
      if (typeof text !== "string" || text.length > \(maxCacheBytes)) { return ""; }
      return text;
    } catch (e) {
      return "";
    }
    """

    // MARK: Parsing

    public static func parse(graphQLCache: Data) -> StreamHome? {
        guard graphQLCache.count <= maxCacheBytes * 4,
              let cache = (try? JSONSerialization.jsonObject(with: graphQLCache)) as? [String: Any],
              let root = cache["ROOT_QUERY"] as? [String: Any],
              let pageKey = root.keys.sorted().first(where: { $0.hasPrefix("pinotBrowsePage(") })
                  .flatMap({ refKey(root[$0]) }),
              let page = cache[pageKey] as? [String: Any]
        else { return nil }
        let reader = Reader(cache: cache)

        var home = StreamHome(serviceID: serviceID)
        home.profiles = reader.profiles()
        home.currentProfileID = refKey(root["currentProfile"])
            .flatMap { (cache[$0] as? [String: Any])?["guid"] as? String }

        let sectionsKey = page.keys.sorted().first { $0.hasPrefix("sections(") }
        let edges = (sectionsKey.flatMap { page[$0] } as? [String: Any])?["edges"] as? [Any] ?? []
        for (index, edge) in edges.enumerated() {
            guard let key = refKey((edge as? [String: Any])?["node"]),
                  let section = cache[key] as? [String: Any] else { continue }
            switch key.prefix(while: { $0 != ":" }) {
            case "PinotSingleItemSection":
                if home.hero == nil, let hero = reader.hero(section) { home.hero = hero }
            case "PinotCarouselSection":
                if let row = reader.row(section, index: index) { home.rows.append(row) }
            default: break
            }
        }
        return home.bounded
    }

    private static func refKey(_ value: Any?) -> String? {
        (value as? [String: Any])?["__ref"] as? String
    }

    private struct Reader {
        let cache: [String: Any]

        func resolve(_ value: Any?) -> [String: Any]? {
            guard let dict = value as? [String: Any] else { return nil }
            if let key = dict["__ref"] as? String { return cache[key] as? [String: Any] }
            return dict
        }

        func profiles() -> [StreamProfile] {
            cache.keys.filter { $0.hasPrefix("Profile:") }.compactMap { key -> StreamProfile? in
                guard let p = cache[key] as? [String: Any],
                      let guid = p["guid"] as? String, !guid.isEmpty,
                      let name = p["name"] as? String else { return nil }
                return StreamProfile(id: guid, name: name, avatar: image(resolve(p["icon"])),
                                     isKids: p["isKids"] as? Bool ?? false,
                                     isLocked: p["isPinLocked"] as? Bool ?? false)
            }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        }

        func hero(_ section: [String: Any]) -> StreamTitle? {
            guard let treatment = resolve(section["entity"]),
                  let entityRef = refKey(treatment["promotedEntity"]),
                  var title = title(entityRef: entityRef, name: treatment["displayString"] as? String)
            else { return nil }
            title.heroArt = image(resolve(treatment["contextualArtwork"]))
            title.synopsis = resolve(treatment["contextualSynopsis"])?["text"] as? String
            return title
        }

        func row(_ section: [String: Any], index: Int) -> StreamRow? {
            guard let name = section["displayString"] as? String, !name.isEmpty,
                  let entities = section["entities"] as? [String: Any] else { return nil }
            var titles: [StreamTitle] = []
            var kind = StreamRow.Kind.standard
            for edge in entities["edges"] as? [Any] ?? [] {
                guard let key = refKey((edge as? [String: Any])?["node"]),
                      let treatment = cache[key] as? [String: Any],
                      let entityRef = refKey(treatment["unifiedEntity"]),
                      var t = title(entityRef: entityRef, name: treatment["displayString"] as? String)
                else { continue }
                t.tileArt = image(resolve(treatment["contextualArtwork"]))
                titles.append(t)
                if titles.count == 1 {
                    switch key.prefix(while: { $0 != ":" }) {
                    case "PinotContinueWatchingEntityTreatment": kind = .continueWatching
                    case "PinotRankedBoxshotEntityTreatment": kind = .ranked
                    default: break
                    }
                }
            }
            return StreamRow(id: "netflix-row-\(index)", title: name, kind: kind, titles: titles,
                             totalCount: entities["totalCount"] as? Int)
        }

        func title(entityRef: String, name: String?) -> StreamTitle? {
            let type = String(entityRef.prefix(while: { $0 != ":" }))
            guard type == "Movie" || type == "Show",
                  let entity = cache[entityRef] as? [String: Any],
                  let id = StreamJSON.int(entity["videoId"]),
                  let page = NetflixHome.pageURL(videoID: String(id)) else { return nil }
            guard let displayName = [name, entity["title"] as? String].compactMap({ $0 }).first(where: { !$0.isEmpty })
            else { return nil }

            // What Play starts: the movie itself, or a show's current episode.
            var playID = id
            var playable = entity
            if type == "Show", let episode = resolve(entity["currentEpisode"]), let epID = StreamJSON.int(episode["videoId"]) {
                playID = epID
                playable = episode
            }
            guard let play = NetflixHome.playURL(videoID: String(playID)) else { return nil }
            var t = StreamTitle(id: String(id), name: displayName, kind: type == "Show" ? .show : .movie,
                                play: play, page: page)
            t.year = StreamJSON.int(entity["releaseYear"])
            t.rating = resolve(entity["contentAdvisory"])?["certificationValue"] as? String
            t.seasonsLabel = entity["numSeasonsLabel"] as? String
            t.runtimeSeconds = StreamJSON.int(playable["runtimeSec"])
            t.resumeSeconds = StreamJSON.int((playable["bookmark"] as? [String: Any])?["position"])
            return t
        }

        /// The url of the widest `artwork(...)` image in a record (widths are
        /// encoded in the key's params); the first in key order if none say.
        func image(_ record: [String: Any]?) -> URL? {
            guard let record else { return nil }
            var best: (width: Int, url: URL)?
            for key in record.keys.sorted() where key.hasPrefix("artwork(") {
                guard let img = record[key] as? [String: Any], let s = img["url"] as? String,
                      let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else { continue }
                let width = key.range(of: #""width":(\d+)"#, options: .regularExpression)
                    .flatMap { Int(key[$0].dropFirst(8)) } ?? 0
                if best == nil || width > best!.width { best = (width, url) }
            }
            if let best { return best.url }
            if let s = record["url"] as? String, let url = URL(string: s), url.scheme == "https" { return url }
            return nil
        }

        private func refKey(_ value: Any?) -> String? {
            (value as? [String: Any])?["__ref"] as? String
        }
    }
}
