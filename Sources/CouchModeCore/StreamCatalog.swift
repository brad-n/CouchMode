// Owns: what the shell's own streaming screens show, whichever service it
// came from: a service's home (its profiles, a featured title, rows of
// titles), a title's details (seasons and episodes) and search results, each
// title with its facts plus the service's own addresses for it (its player,
// its page). A reader per service fills these in from that service's website,
// as a proxy: each thing the player does on our screen (open the service,
// search, reach the end of a row, open a title) is the same one action on the
// real site, read back; nothing is fetched ahead or crawled. Playback always
// happens in the service's own player (StreamTitle.play / StreamEpisode.play),
// so nothing here touches video. No I/O and no service-specific rules here.

import Foundation

/// Caps that keep a home bounded however much a service sends.
public enum StreamLimits {
    public static let maxRows = 20
    public static let maxTitlesPerRow = 40
    public static let maxProfiles = 10
    public static let maxSeasons = 50
    public static let maxEpisodesPerSeason = 100
    public static let maxSearchResults = 60
    public static let maxQueryLength = 100
}

public struct StreamTitle: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable { case movie, show, episode, other }

    /// Unique within its service (e.g. Netflix's videoId).
    public let id: String
    public let name: String
    public let kind: Kind
    /// The service's own player for this title: plays it, or resumes it
    /// (for a show, its current episode).
    public let play: URL
    /// The service's own page for the title, for "open on the site".
    public var page: URL?
    /// A show's current episode, e.g. "S2 · E5"; nil otherwise.
    public var episodeLabel: String?
    public var synopsis: String?
    public var year: Int?
    /// The rating as the service shows it, e.g. "TV-14" or "R".
    public var rating: String?
    /// A show's season count as the service words it, e.g. "11 Seasons".
    public var seasonsLabel: String?
    /// Length of what Play starts (the episode, for a show).
    public var runtimeSeconds: Int?
    /// Where Play resumes, in seconds of what it starts.
    public var resumeSeconds: Int?
    /// A 16:9 tile image.
    public var tileArt: URL?
    /// A wide background image, when the service gives one.
    public var heroArt: URL?

    public init(id: String, name: String, kind: Kind, play: URL, page: URL? = nil, episodeLabel: String? = nil,
                synopsis: String? = nil, year: Int? = nil, rating: String? = nil, seasonsLabel: String? = nil,
                runtimeSeconds: Int? = nil, resumeSeconds: Int? = nil, tileArt: URL? = nil, heroArt: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.play = play
        self.page = page
        self.episodeLabel = episodeLabel
        self.synopsis = synopsis
        self.year = year
        self.rating = rating
        self.seasonsLabel = seasonsLabel
        self.runtimeSeconds = runtimeSeconds
        self.resumeSeconds = resumeSeconds
        self.tileArt = tileArt
        self.heroArt = heroArt
    }

    /// How much of what Play starts has been watched (0...1), when known.
    public var progress: Double? {
        guard let resume = resumeSeconds, let total = runtimeSeconds, total > 0, resume > 0 else { return nil }
        return min(1, Double(resume) / Double(total))
    }

    /// "38 min left" style remaining time, when partly watched.
    public var remainingText: String? {
        guard let resume = resumeSeconds, let total = runtimeSeconds, resume > 0, total > resume else { return nil }
        let minutes = Int((Double(total - resume) / 60).rounded())
        return minutes > 0 ? "\(minutes) min left" : nil
    }
}

public struct StreamRow: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// The profile's partly watched titles: Select plays straight away.
        case continueWatching
        /// A numbered chart (e.g. Top 10).
        case ranked
        case standard
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public var titles: [StreamTitle]
    /// How many titles the service says the row holds (it may send fewer).
    public var totalCount: Int?

    public init(id: String, title: String, kind: Kind, titles: [StreamTitle], totalCount: Int? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.titles = titles
        self.totalCount = totalCount
    }
}

public struct StreamProfile: Equatable, Sendable, Identifiable {
    /// The service's id for the profile (Netflix: its guid).
    public let id: String
    public let name: String
    public var avatar: URL?
    public var isKids: Bool
    /// Needs a PIN on the service's side.
    public var isLocked: Bool

    public init(id: String, name: String, avatar: URL? = nil, isKids: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.isKids = isKids
        self.isLocked = isLocked
    }
}

public enum StreamSearch {
    /// A query as the screens hand it to a reader: trimmed, inner whitespace
    /// collapsed, at most StreamLimits.maxQueryLength characters; nil when empty.
    public static func normalized(_ query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let text = String(words.joined(separator: " ").prefix(StreamLimits.maxQueryLength))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

public struct StreamEpisode: Equatable, Sendable, Identifiable {
    /// Unique within its service (e.g. Netflix's videoId of the episode).
    public let id: String
    public let name: String
    /// Its number within the season, when the service gives one.
    public var number: Int?
    public var synopsis: String?
    public var runtimeSeconds: Int?
    public var resumeSeconds: Int?
    /// The service's own player for this episode.
    public let play: URL
    public var art: URL?

    public init(id: String, name: String, number: Int? = nil, synopsis: String? = nil, runtimeSeconds: Int? = nil,
                resumeSeconds: Int? = nil, play: URL, art: URL? = nil) {
        self.id = id
        self.name = name
        self.number = number
        self.synopsis = synopsis
        self.runtimeSeconds = runtimeSeconds
        self.resumeSeconds = resumeSeconds
        self.play = play
        self.art = art
    }
}

public struct StreamSeason: Equatable, Sendable, Identifiable {
    public let id: String
    /// As the service words it, e.g. "Season 2" or "Limited Series".
    public let name: String
    public var episodes: [StreamEpisode]

    public init(id: String, name: String, episodes: [StreamEpisode] = []) {
        self.id = id
        self.name = name
        self.episodes = episodes
    }
}

/// A title as its own page on the service shows it: fuller facts, and for a
/// show its seasons (a season's episodes may arrive only when it's opened).
public struct StreamTitleDetails: Equatable, Sendable {
    public var title: StreamTitle
    public var seasons: [StreamSeason]
    /// The season Play continues in (the current episode's), when known.
    public var currentSeasonID: String?

    public init(title: StreamTitle, seasons: [StreamSeason] = [], currentSeasonID: String? = nil) {
        self.title = title
        self.seasons = seasons
        self.currentSeasonID = currentSeasonID
    }

    /// The same details within StreamLimits, empty seasons kept (their
    /// episodes may load when opened).
    public var bounded: StreamTitleDetails {
        var details = self
        details.seasons = seasons.prefix(StreamLimits.maxSeasons).map { season in
            var s = season
            s.episodes = Array(season.episodes.prefix(StreamLimits.maxEpisodesPerSeason))
            return s
        }
        return details
    }
}

public struct StreamHome: Equatable, Sendable {
    public let serviceID: String
    public var profiles: [StreamProfile]
    public var currentProfileID: String?
    /// The service's featured title (its billboard), when it has one.
    public var hero: StreamTitle?
    public var rows: [StreamRow]
    /// The site is on its own "who's watching" page: `profiles` are the ones it offers, there are
    /// no rows, and nothing here belongs to a profile yet. Screens open their picker at once.
    public var asksWhoIsWatching: Bool

    public init(serviceID: String, profiles: [StreamProfile] = [], currentProfileID: String? = nil,
                hero: StreamTitle? = nil, rows: [StreamRow] = [], asksWhoIsWatching: Bool = false) {
        self.serviceID = serviceID
        self.profiles = profiles
        self.currentProfileID = currentProfileID
        self.hero = hero
        self.rows = rows
        self.asksWhoIsWatching = asksWhoIsWatching
    }

    public var currentProfile: StreamProfile? { profiles.first { $0.id == currentProfileID } }

    /// The same home within StreamLimits, empty rows dropped: what screens show.
    public var bounded: StreamHome {
        var home = self
        home.profiles = Array(profiles.prefix(StreamLimits.maxProfiles))
        if asksWhoIsWatching { home.rows = []; home.hero = nil; return home }
        home.rows = rows.lazy
            .map { row in var r = row; r.titles = Array(row.titles.prefix(StreamLimits.maxTitlesPerRow)); return r }
            .filter { !$0.titles.isEmpty }
            .prefix(StreamLimits.maxRows)
            .map { $0 }
        return home
    }
}
