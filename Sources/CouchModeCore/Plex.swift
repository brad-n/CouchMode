// Owns: reading Plex's JSON (plex.tv resources, a server's continue-watching
// list) into plain values, and building Plex URLs. No networking, no tokens
// stored here; the app's PlexClient does I/O and passes data in.

import Foundation

public struct PlexServer: Equatable, Sendable {
    public let name: String
    public let machineIdentifier: String
    public let baseURL: URL
    public let accessToken: String
    /// Every address for the server, best first; the app probes them and
    /// moves `baseURL` to the first that answers.
    public var candidateURLs: [URL] = []

    public init(name: String, machineIdentifier: String, baseURL: URL, accessToken: String, candidateURLs: [URL] = []) {
        self.name = name
        self.machineIdentifier = machineIdentifier
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.candidateURLs = candidateURLs
    }

    public func using(_ url: URL) -> PlexServer {
        PlexServer(name: name, machineIdentifier: machineIdentifier, baseURL: url, accessToken: accessToken, candidateURLs: candidateURLs)
    }
}

public struct ContinueItem: Equatable, Sendable, Identifiable {
    public let ratingKey: String
    public let title: String          // what to show big: show name or movie title
    public let detail: String         // "S2 · E5 · Episode Title" or year
    public let imagePath: String?     // server-relative image path (16:9 preferred)
    public let progress: Double       // 0...1
    public var lastViewedAt: Double = 0   // Unix seconds; orders items across servers
    public var backdropPath: String? = nil   // wide background art for a full-screen hero
    public var summary: String? = nil        // the episode's or movie's synopsis
    public var year: Int? = nil
    public var contentRating: String? = nil  // e.g. "TV-14"
    public var durationMs: Double = 0
    public var viewOffsetMs: Double = 0
    /// The title's universal Plex ID ("plex://episode/5e..."), when Plex
    /// matched it; other agents give "local://..." or "com.plexapp...".
    public var guid: String? = nil

    /// A link Plex HTPC opens on this title's page in the library: episodes
    /// only. An episode's Plex ID opens the show's page from the library with
    /// that episode focused; a movie's opens Plex's general catalog page,
    /// which can't resume the library's copy (seen on a real Mac), so movies and
    /// unmatched titles get none.
    public var appLink: URL? { guid.flatMap { $0.hasPrefix("plex://episode/") ? URL(string: $0) : nil } }

    /// "38 min left" style remaining time, when known.
    public var remainingText: String? {
        guard durationMs > 0, viewOffsetMs > 0 else { return nil }
        let minutes = Int(((durationMs - viewOffsetMs) / 60_000).rounded())
        return minutes > 0 ? "\(minutes) min left" : nil
    }
    public var id: String { ratingKey }
}

public enum PlexParsing {
    /// The best server from plex.tv's /api/v2/resources: an owned server
    /// first, reached by a direct HTTPS connection (relay as a last resort).
    public static func server(fromResources data: Data) -> PlexServer? { servers(fromResources: data).first }

    /// Every server the account can reach, owned ones first, each with its
    /// addresses ranked best-first.
    public static func servers(fromResources data: Data) -> [PlexServer] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let servers = list.filter { ($0["provides"] as? String ?? "").contains("server") }
        let ordered = servers.filter { $0["owned"] as? Bool == true } + servers.filter { $0["owned"] as? Bool != true }
        return ordered.compactMap { s in
            guard let id = s["clientIdentifier"] as? String,
                  let token = s["accessToken"] as? String,
                  let conns = s["connections"] as? [[String: Any]] else { return nil }
            let urls = rankedConnections(conns)
            guard let first = urls.first else { return nil }
            return PlexServer(name: s["name"] as? String ?? "Plex", machineIdentifier: id, baseURL: first,
                              accessToken: token, candidateURLs: urls)
        }
    }

    /// Connection order: direct public HTTPS, then direct local/private
    /// HTTPS, then plain HTTP, then Plex relays last.
    static func rankedConnections(_ conns: [[String: Any]]) -> [URL] {
        func rank(_ c: [String: Any]) -> Int {
            let relay = c["relay"] as? Bool == true
            let local = c["local"] as? Bool == true
            let https = c["protocol"] as? String == "https"
            return (relay ? 100 : 0) + (local ? 10 : 0) + (https ? 0 : 1)
        }
        return conns.sorted { rank($0) < rank($1) }.compactMap { ($0["uri"] as? String).flatMap(URL.init(string:)) }
    }

    /// Items from a server's /hubs/continueWatching or /library/onDeck reply.
    /// Bounded to `limit` items.
    public static func continueItems(from data: Data, limit: Int = 20) -> [ContinueItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else { return [] }
        let hubMetadata = (container["Hub"] as? [[String: Any]])?.flatMap { $0["Metadata"] as? [[String: Any]] ?? [] }
        let metadata = hubMetadata ?? (container["Metadata"] as? [[String: Any]] ?? [])
        return metadata.prefix(limit).compactMap(item)
    }

    static func item(_ m: [String: Any]) -> ContinueItem? {
        guard let key = m["ratingKey"] as? String, let title = m["title"] as? String else { return nil }
        let duration = (m["duration"] as? NSNumber)?.doubleValue ?? 0
        let offset = (m["viewOffset"] as? NSNumber)?.doubleValue ?? 0
        let progress = duration > 0 ? min(1, max(0, offset / duration)) : 0
        let viewed = (m["lastViewedAt"] as? NSNumber)?.doubleValue ?? 0
        if m["type"] as? String == "episode" {
            var parts: [String] = []
            if let s = m["parentIndex"] as? NSNumber { parts.append("S\(s.intValue)") }
            if let e = m["index"] as? NSNumber { parts.append("E\(e.intValue)") }
            parts.append(title)
            return ContinueItem(ratingKey: key, title: m["grandparentTitle"] as? String ?? title,
                                detail: parts.joined(separator: " · "),
                                imagePath: (m["thumb"] as? String) ?? (m["grandparentArt"] as? String),
                                progress: progress, lastViewedAt: viewed,
                                backdropPath: (m["grandparentArt"] as? String) ?? (m["art"] as? String) ?? (m["thumb"] as? String),
                                summary: m["summary"] as? String, year: (m["year"] as? NSNumber)?.intValue,
                                contentRating: m["contentRating"] as? String, durationMs: duration, viewOffsetMs: offset,
                                guid: m["guid"] as? String)
        }
        let year = (m["year"] as? NSNumber).map { "\($0.intValue)" } ?? ""
        return ContinueItem(ratingKey: key, title: title, detail: year,
                            imagePath: (m["art"] as? String) ?? (m["thumb"] as? String), progress: progress,
                            lastViewedAt: viewed, backdropPath: (m["art"] as? String) ?? (m["thumb"] as? String),
                            summary: m["summary"] as? String, year: (m["year"] as? NSNumber)?.intValue,
                            contentRating: m["contentRating"] as? String, durationMs: duration, viewOffsetMs: offset,
                            guid: m["guid"] as? String)
    }

    /// Merges per-server lists into one, most recently watched first, capped.
    public static func merged<T>(_ lists: [[(ContinueItem, T)]], limit: Int) -> [(ContinueItem, T)] {
        Array(lists.flatMap { $0 }.sorted { $0.0.lastViewedAt > $1.0.lastViewedAt }.prefix(limit))
    }

    /// A resized image from the server's transcoder.
    public static func imageURL(server: PlexServer, path: String, width: Int, height: Int) -> URL? {
        var c = URLComponents(url: server.baseURL.appendingPathComponent("photo/:/transcode"), resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "width", value: "\(width)"), URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"), URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path), URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
        ]
        return c?.url
    }

    /// Plex Web's page for one title on one server.
    public static func webDetailsURL(server: PlexServer, ratingKey: String) -> URL? {
        let key = "/library/metadata/\(ratingKey)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://app.plex.tv/desktop/#!/server/\(server.machineIdentifier)/details?key=\(key)")
    }
}
