// Owns: turning the JSON a reader package's script returns into the shared
// streaming vocabulary (StreamHome, StreamTitleDetails, StreamTitle,
// StreamEpisode), and a title into JSON for the script. The script only
// returns data; every value is checked here: ids are plain tokens, addresses
// are https on the service's own hosts (images on its image hosts), text and
// numbers are bounded, and StreamLimits caps every list. A title, episode or
// row that fails a check is dropped, not repaired. Also holds the opaque
// paging cursor a row carries (kept as JSON text, size-bounded, never read).

import Foundation

public struct PackageDecoder: Sendable {
    public let siteHosts: [String]
    public let imageHosts: [String]

    /// Largest answer taken from a script, in characters.
    public static let maxAnswerLength = 1_000_000
    /// Largest paging cursor kept, in characters.
    public static let maxCursorLength = 8_192

    public init(siteHosts: [String], imageHosts: [String]) {
        self.siteHosts = siteHosts
        self.imageHosts = imageHosts
    }

    public init(manifest: PackageManifest) {
        self.init(siteHosts: manifest.siteHosts, imageHosts: manifest.imageHosts)
    }

    // MARK: Entry points

    /// The home (for service `serviceID`, the manifest's id rather than the script's say-so) and each row's
    /// cursor by row id; nil when the answer isn't a home with something to show.
    public func home(_ json: String, serviceID: String) -> (home: StreamHome, cursors: [String: String])? {
        guard json.count <= Self.maxAnswerLength, let read = StreamJSON.object(json) else { return nil }
        var rows: [StreamRow] = []
        var cursors: [String: String] = [:]
        for entry in read["rows"] as? [[String: Any]] ?? [] {
            guard let row = row(entry), !rows.contains(where: { $0.id == row.id }) else { continue }
            rows.append(row)
            if let cursor = cursorText(entry["cursor"]) { cursors[row.id] = cursor }
        }
        var profiles: [StreamProfile] = []
        for entry in read["profiles"] as? [[String: Any]] ?? [] {
            if let p = profile(entry), !profiles.contains(where: { $0.id == p.id }) { profiles.append(p) }
        }
        let current = StreamJSON.string(read["currentProfileID"]).flatMap { id in profiles.contains { $0.id == id } ? id : nil }
        let hero = (read["hero"] as? [String: Any]).flatMap(title)
        let home = StreamHome(serviceID: serviceID, profiles: profiles, currentProfileID: current, hero: hero, rows: rows,
                              asksWhoIsWatching: read["asksWhoIsWatching"] as? Bool == true).bounded
        guard home.asksWhoIsWatching ? !home.profiles.isEmpty : !(home.rows.isEmpty && home.hero == nil) else { return nil }
        return (home, cursors.filter { key, _ in home.rows.contains { $0.id == key } })
    }

    public func details(_ json: String) -> StreamTitleDetails? {
        guard json.count <= Self.maxAnswerLength, let read = StreamJSON.object(json),
              let t = (read["title"] as? [String: Any]).flatMap(title) else { return nil }
        var seen = Set<String>()
        var seasons: [StreamSeason] = []
        for entry in read["seasons"] as? [[String: Any]] ?? [] {
            guard let id = Self.seasonID(entry["id"]), seen.insert(id).inserted, let name = text(entry["name"], max: 100) else { continue }
            seasons.append(StreamSeason(id: id, name: name, episodes: episodes(entry["episodes"] as? [Any] ?? [])))
        }
        let current = Self.seasonID(read["currentSeasonID"]).flatMap { id in seasons.contains { $0.id == id } ? id : nil }
        return StreamTitleDetails(title: t, seasons: seasons, currentSeasonID: current).bounded
    }

    /// The episodes of a season's answer (a JSON array); nil when it isn't one.
    public func episodes(_ json: String) -> [StreamEpisode]? {
        guard json.count <= Self.maxAnswerLength,
              let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] else { return nil }
        return episodes(list)
    }

    /// Titles from a search answer (a JSON array): each once, at most maxSearchResults; nil when it isn't an array.
    public func titles(_ json: String) -> [StreamTitle]? {
        guard json.count <= Self.maxAnswerLength,
              let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] else { return nil }
        return Array(distinct(list.compactMap { ($0 as? [String: Any]).flatMap(title) }).prefix(StreamLimits.maxSearchResults))
    }

    /// A "more" answer: the next titles and, when the row has still more, its next cursor.
    public func more(_ json: String) -> (titles: [StreamTitle], cursor: String?)? {
        guard json.count <= Self.maxAnswerLength, let read = StreamJSON.object(json), let list = read["titles"] as? [Any] else { return nil }
        let titles = Array(list.compactMap { ($0 as? [String: Any]).flatMap(title) }.prefix(StreamLimits.maxTitlesPerRow))
        return (titles, cursorText(read["cursor"]))
    }

    // MARK: Pieces

    private func row(_ entry: [String: Any]) -> StreamRow? {
        guard let id = Self.id(entry["id"]), let name = entry["title"] as? String, name.count <= 200,
              let kind = (entry["kind"] as? String).flatMap(StreamRow.Kind.init(rawValue:)) else { return nil }
        let titles = (entry["titles"] as? [[String: Any]] ?? []).compactMap(title)
        guard !titles.isEmpty else { return nil }
        let total = StreamJSON.int(entry["totalCount"]).flatMap { (1...100_000).contains($0) ? $0 : nil }
        return StreamRow(id: id, title: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, titles: titles, totalCount: total)
    }

    private func profile(_ entry: [String: Any]) -> StreamProfile? {
        guard let id = text(entry["id"], max: 128), let name = text(entry["name"], max: 128) else { return nil }
        return StreamProfile(id: id, name: name, avatar: imageURL(entry["avatar"]), isKids: entry["isKids"] as? Bool == true,
                             isLocked: entry["isLocked"] as? Bool == true)
    }

    func title(_ e: [String: Any]) -> StreamTitle? {
        guard let id = Self.id(e["id"]), let name = text(e["name"], max: 300), let kind = (e["kind"] as? String).flatMap(StreamTitle.Kind.init(rawValue:)),
              let play = siteURL(e["play"]) else { return nil }
        return StreamTitle(id: id, name: name, kind: kind, play: play, page: siteURL(e["page"]), episodeLabel: text(e["episodeLabel"], max: 32),
                           synopsis: text(e["synopsis"], max: 2_000), year: year(e["year"]), rating: text(e["rating"], max: 32),
                           seasonsLabel: text(e["seasonsLabel"], max: 32), runtimeSeconds: seconds(e["runtimeSeconds"]),
                           resumeSeconds: seconds(e["resumeSeconds"]), tileArt: imageURL(e["tileArt"]), heroArt: imageURL(e["heroArt"]))
    }

    private func episodes(_ list: [Any]) -> [StreamEpisode] {
        var seen = Set<String>()
        var out: [StreamEpisode] = []
        for case let e as [String: Any] in list {
            guard out.count < StreamLimits.maxEpisodesPerSeason, let id = Self.id(e["id"]), let name = text(e["name"], max: 300),
                  let play = siteURL(e["play"]), seen.insert(id).inserted else { continue }
            out.append(StreamEpisode(id: id, name: name, number: StreamJSON.int(e["number"]).flatMap { (0...10_000).contains($0) ? $0 : nil },
                                     synopsis: text(e["synopsis"], max: 2_000), runtimeSeconds: seconds(e["runtimeSeconds"]),
                                     resumeSeconds: seconds(e["resumeSeconds"]), play: play, art: imageURL(e["art"])))
        }
        return out
    }

    private func distinct(_ titles: [StreamTitle]) -> [StreamTitle] {
        var seen = Set<String>()
        return titles.filter { seen.insert($0.id).inserted }
    }

    // MARK: Checks

    /// An id: 1 to 132 ASCII letters, digits, dots, dashes or underscores (Apple TV's "umc.cmc.<id>" and "appletv-row-<shelf id>").
    static func id(_ value: Any?) -> String? {
        guard let s = value as? String, (1...132).contains(s.count), s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
        else { return nil }
        return s
    }

    /// A season id: an id that may also hold colons (Hulu's "<series>::<n>"). It only goes back to the script, never into an address.
    static func seasonID(_ value: Any?) -> String? {
        guard let s = value as? String, (1...64).contains(s.count), s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" || $0 == ".") })
        else { return nil }
        return s
    }

    private func text(_ value: Any?, max: Int) -> String? {
        guard let s = StreamJSON.string(value), s.count <= max else { return nil }
        return s
    }

    private func year(_ value: Any?) -> Int? { StreamJSON.int(value).flatMap { (1900...2100).contains($0) ? $0 : nil } }

    private func seconds(_ value: Any?) -> Int? { StreamJSON.int(value).flatMap { (0...10_000_000).contains($0) ? $0 : nil } }

    private func siteURL(_ value: Any?) -> URL? {
        guard let url = StreamJSON.httpsURL(value), (value as? String)?.count ?? 0 <= 2_048, PackageManifest.host(url.host, within: siteHosts) else { return nil }
        return url
    }

    private func imageURL(_ value: Any?) -> URL? {
        guard let url = StreamJSON.httpsURL(value), (value as? String)?.count ?? 0 <= 2_048, PackageManifest.host(url.host, within: imageHosts) else { return nil }
        return url
    }

    /// A cursor as JSON text, kept opaque; nil when absent or too big.
    private func cursorText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= Self.maxCursorLength + 2 else { return nil }
        let wrapped = String(decoding: data, as: UTF8.self)
        return String(wrapped.dropFirst().dropLast())
    }

    // MARK: To the script

    /// A title as the JSON the script's details function receives.
    public static func argument(for title: StreamTitle) -> [String: Any] {
        var out: [String: Any] = ["id": title.id, "name": title.name, "kind": title.kind.rawValue, "play": title.play.absoluteString]
        func put(_ key: String, _ value: Any?) { if let value { out[key] = value } }
        put("page", title.page?.absoluteString); put("episodeLabel", title.episodeLabel); put("synopsis", title.synopsis)
        put("year", title.year); put("rating", title.rating); put("seasonsLabel", title.seasonsLabel)
        put("runtimeSeconds", title.runtimeSeconds); put("resumeSeconds", title.resumeSeconds)
        put("tileArt", title.tileArt?.absoluteString); put("heroArt", title.heroArt?.absoluteString)
        return out
    }
}
