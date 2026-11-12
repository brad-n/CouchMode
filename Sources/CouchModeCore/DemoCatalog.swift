// Owns: the invented sample content demo mode shows: made-up shows and
// movies for the streaming screens (homes, details, episodes, search), a few
// "Continue Watching" entries for Plex, and made-up games for the consoles.
// Every title, synopsis, name and number here is invented for CouchMode; none
// is a real person's history and none is a real service's catalog. Art is
// always a DemoArtSpec address, never a picture of anything. No I/O.

import Foundation

public struct DemoTitle: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isShow: Bool
    public let year: Int
    public let rating: String
    public let genre: String
    public let synopsis: String
    public let seasons: Int
}

public struct DemoGame: Equatable, Sendable {
    public let title: String
    public let publisher: String
    public let year: Int
    public let players: Int
    public let genres: [String]
    public let blurb: String

    /// The game as the Switch catalog file (catalog.json) would describe it.
    public func catalogJSON(titleID: String) -> Data {
        let object: [String: Any] = [
            "titleID": titleID, "name": title, "publisher": publisher, "releaseDate": "\(year)-06-15",
            "numberOfPlayers": players, "genres": genres, "description": blurb, "card": "", "banner": "",
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

public struct DemoContinue: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let progress: Double
    public let year: Int
    public let rating: String
    public let summary: String
    public let durationMinutes: Int
}

public enum DemoCatalog {
    public static let baseURL = "https://example.invalid"

    // MARK: Streaming

    public static let titles: [DemoTitle] = [
        t("lantern-harbor", "Lantern Harbor", true, 2023, "TV-14", "Drama", 3,
          "A ferry town keeps one lamp lit through every storm, and the oil is running low."),
        t("quiet-meridian", "The Quiet Meridian", false, 2022, "PG-13", "Mystery", 0,
          "A surveyor finds the line she was hired to draw already exists, and someone redraws it."),
        t("saltglass", "Saltglass", true, 2024, "TV-MA", "Thriller", 2,
          "Six salvage divers share one wreck and three different ideas of what is still down there."),
        t("borrowed-thunder", "Borrowed Thunder", false, 2021, "PG", "Comedy", 0,
          "A small-town forecaster promises a storm by accident and must now deliver one by Friday."),
        t("nine-rivers-north", "Nine Rivers North", true, 2022, "TV-PG", "Adventure", 4,
          "A mapmaking crew follows nine rivers to their sources and finds every map is wrong."),
        t("paper-moons", "Paper Moons", false, 2020, "PG", "Family", 0,
          "Two siblings fold a moon out of newspaper, and wake to find it has grown a tide."),
        t("hollow-pine", "Hollow Pine", true, 2023, "TV-14", "Mystery", 2,
          "When the mill closes, its night watchman starts a ledger of what the forest gives back."),
        t("understudy-hour", "The Understudy Hour", false, 2024, "R", "Comedy", 0,
          "The lead falls ill, the understudy is stuck in traffic, and the stage manager has a plan."),
        t("velvet-static", "Velvet Static", true, 2021, "TV-14", "Drama", 3,
          "A late-night radio host starts getting requests from listeners calling from tomorrow."),
        t("afterglow-station", "Afterglow Station", false, 2023, "PG-13", "Sci-Fi", 0,
          "The last train to a vanished colony still runs on time. This week it has a passenger."),
        t("copperleaf", "Copperleaf", true, 2020, "TV-G", "Family", 5,
          "A tiny orchard on the edge of town holds a surprising number of ordinary miracles."),
        t("marrow-and-tide", "Marrow & Tide", false, 2022, "R", "Drama", 0,
          "Two fishing families, one failing harbor, and a wedding neither side can afford to cancel."),
        t("little-orbit", "Little Orbit", true, 2024, "TV-Y7", "Animation", 2,
          "A very small satellite learns to make friends with the very large things it passes."),
        t("longest-tuesday", "The Longest Tuesday", false, 2021, "PG-13", "Comedy", 0,
          "Everything that can go wrong at a small-town wedding does so in one afternoon."),
        t("driftwood-kings", "Driftwood Kings", true, 2023, "TV-MA", "Crime", 3,
          "A beach-town salvage crew finds a locked chest and a map to people who want it back."),
        t("wren-street", "Wren Street", true, 2022, "TV-PG", "Comedy", 4,
          "The residents of one dead-end street hold a monthly meeting that never leaves item one."),
        t("glasswing", "Glasswing", false, 2024, "PG", "Fantasy", 0,
          "A glassblower's apprentice makes a moth that does not stay on the shelf."),
        t("midnight-orchard", "Midnight Orchard", true, 2021, "TV-14", "Mystery", 2,
          "Every autumn one tree blooms at midnight. This year, somebody is waiting under it."),
        t("tin-lantern", "Tin Lantern", false, 2020, "PG", "Adventure", 0,
          "A lamplighter's daughter follows a trail of small lights across a city going dark."),
        t("salt-road-diaries", "Salt Road Diaries", true, 2022, "TV-PG", "Documentary", 2,
          "On foot along an old trade road, with no narrator and a lot of weather."),
        t("echo-valley", "Echo Valley", false, 2023, "PG-13", "Thriller", 0,
          "A sound engineer records a canyon and hears her own voice answer a day early."),
        t("clockwork-garden", "The Clockwork Garden", true, 2024, "TV-Y", "Animation", 3,
          "A gardener of brass and springs teaches the seasons to keep time."),
        t("rooftop-weather", "Rooftop Weather", false, 2021, "PG-13", "Romance", 0,
          "Two neighbors meet each evening on adjoining rooftops to argue about tomorrow's forecast."),
        t("cinder-lake", "Cinder Lake", true, 2023, "TV-MA", "Thriller", 2,
          "A volcanologist returns to the town she evacuated and finds nobody left."),
    ]

    private static func t(_ id: String, _ name: String, _ show: Bool, _ year: Int, _ rating: String, _ genre: String,
                          _ seasons: Int, _ synopsis: String) -> DemoTitle {
        DemoTitle(id: id, name: name, isShow: show, year: year, rating: rating, genre: genre, synopsis: synopsis, seasons: seasons)
    }

    public static let profiles: [StreamProfile] = [
        StreamProfile(id: "alex", name: "Alex"),
        StreamProfile(id: "sam", name: "Sam"),
        StreamProfile(id: "kids", name: "Kids", isKids: true),
    ]

    static let episodeNames = ["Arrivals", "The Long Way Round", "Low Tide", "Open Windows", "A Small Fire",
                               "Crosswinds", "Homecoming", "The Last Light"]

    static func url(_ service: String, _ path: String) -> URL { URL(string: "\(baseURL)/\(service)/\(path)")! }

    /// A title as a service's home row would carry it.
    public static func streamTitle(_ d: DemoTitle, service: String, resume: Double? = nil) -> StreamTitle {
        let runtime = d.isShow ? 44 * 60 : 108 * 60
        var title = StreamTitle(
            id: d.id, name: d.name, kind: d.isShow ? .show : .movie, play: url(service, "watch/\(d.id)"),
            page: url(service, "title/\(d.id)"), episodeLabel: d.isShow && resume != nil ? "S1 · E\(Int(DemoArtSpec(kind: .tile, title: d.name).seed % 6) + 2)" : nil,
            synopsis: d.synopsis, year: d.year, rating: d.rating,
            seasonsLabel: d.isShow ? (d.seasons == 1 ? "1 Season" : "\(d.seasons) Seasons") : nil, runtimeSeconds: runtime,
            tileArt: DemoArtSpec(kind: .tile, title: d.name).url, heroArt: DemoArtSpec(kind: .hero, title: d.name).url)
        if let resume { title.resumeSeconds = Int(Double(runtime) * resume) }
        return title
    }

    /// Titles rotated by service, so two services' homes don't look identical.
    static func ordered(for service: String) -> [DemoTitle] {
        let shift = Int(DemoArtSpec.fnv1a(service) % UInt64(titles.count))
        return Array(titles[shift...] + titles[..<shift])
    }

    public static func home(serviceID service: String, currentProfileID: String? = nil) -> StreamHome {
        let list = ordered(for: service)
        func row(_ id: String, _ name: String, _ kind: StreamRow.Kind, _ slice: ArraySlice<DemoTitle>, resumes: [Double] = []) -> StreamRow {
            StreamRow(id: id, title: name, kind: kind, titles: slice.enumerated().map { i, d in
                streamTitle(d, service: service, resume: resumes.indices.contains(i) ? resumes[i] : nil)
            })
        }
        let rows = [
            row("continue", "Continue Watching", .continueWatching, list[1..<6], resumes: [0.62, 0.18, 0.85, 0.4, 0.07]),
            row("top", "Top 10 Today", .ranked, list[6..<16]),
            row("new", "New This Week", .standard, list[16..<24]),
            row("mystery", "Mysteries & Thrillers", .standard, ArraySlice(list.filter { ["Mystery", "Thriller", "Crime"].contains($0.genre) })),
            row("family", "Family Time", .standard, ArraySlice(list.filter { ["Family", "Animation", "Adventure"].contains($0.genre) })),
            row("comedy", "Comedies", .standard, ArraySlice(list.filter { $0.genre == "Comedy" || $0.genre == "Romance" })),
        ]
        let hero = streamTitle(list[0], service: service)
        let profile = currentProfileID.flatMap { id in profiles.first { $0.id == id }?.id } ?? profiles[0].id
        return StreamHome(serviceID: service, profiles: profiles, currentProfileID: profile, hero: hero, rows: rows)
    }

    /// The fuller facts for a title; a show gets its seasons (the first one's episodes included).
    public static func details(for title: StreamTitle, service: String) -> StreamTitleDetails {
        guard title.kind == .show, let d = titles.first(where: { $0.id == title.id }) else { return StreamTitleDetails(title: title) }
        var seasons = (1...max(1, d.seasons)).map { StreamSeason(id: "s\($0)", name: "Season \($0)") }
        seasons[0].episodes = episodes(season: 1, of: title, service: service)
        return StreamTitleDetails(title: title, seasons: seasons, currentSeasonID: "s1")
    }

    public static func episodes(season: Int, of title: StreamTitle, service: String) -> [StreamEpisode] {
        episodeNames.enumerated().map { i, name in
            let n = i + 1
            return StreamEpisode(
                id: "\(title.id)-s\(season)e\(n)", name: name, number: n,
                synopsis: "An invented episode of \(title.name): \(name.lowercased()) changes what everyone thought they knew.",
                runtimeSeconds: (40 + (n * 3) % 9) * 60, resumeSeconds: season == 1 && n == 2 ? 14 * 60 : nil,
                play: url(service, "watch/\(title.id)-s\(season)e\(n)"),
                art: DemoArtSpec(kind: .tile, title: "\(title.name) \(season).\(n)").url)
        }
    }

    /// Titles whose name contains the words typed; a few suggestions when nothing does.
    public static func search(_ query: String, service: String) -> [StreamTitle] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let hits = ordered(for: service).filter { d in
            let name = d.name.lowercased()
            return words.allSatisfy { name.contains($0) || d.genre.lowercased().contains($0) }
        }
        let shown = hits.isEmpty ? Array(ordered(for: service).prefix(4)) : hits
        return shown.prefix(StreamLimits.maxSearchResults).map { streamTitle($0, service: service) }
    }

    // MARK: Plex

    public static let plexContinue: [DemoContinue] = [
        DemoContinue(title: "Hollow Pine", detail: "S1 · E4 · The Night Ledger", progress: 0.35, year: 2023, rating: "TV-14",
                     summary: "The watchman follows the mill's old delivery route and finds it still has a stop.", durationMinutes: 47),
        DemoContinue(title: "The Quiet Meridian", detail: "2022", progress: 0.72, year: 2022, rating: "PG-13",
                     summary: "The surveyor compares her field notes against the line and the numbers disagree.", durationMinutes: 112),
        DemoContinue(title: "Copperleaf", detail: "S2 · E7 · Windfall", progress: 0.12, year: 2020, rating: "TV-G",
                     summary: "The orchard's biggest storm of the year brings a very small visitor.", durationMinutes: 24),
        DemoContinue(title: "Salt Road Diaries", detail: "S1 · E2 · Mile 40", progress: 0.58, year: 2022, rating: "TV-PG",
                     summary: "A ridge, a rain, and a village with an open door.", durationMinutes: 52),
        DemoContinue(title: "Paper Moons", detail: "2020", progress: 0.9, year: 2020, rating: "PG",
                     summary: "The paper moon is bigger this morning, and the tide has reached the stairs.", durationMinutes: 96),
    ]

    /// The samples as Plex Continue Watching items (most recent first); no image paths, the app attaches generated art.
    public static func continueItems() -> [ContinueItem] {
        plexContinue.enumerated().map { i, d in
            ContinueItem(ratingKey: "demo-\(i + 1)", title: d.title, detail: d.detail, imagePath: nil, progress: d.progress,
                         lastViewedAt: Double(1_000 - i), summary: d.summary, year: d.year, contentRating: d.rating,
                         durationMs: Double(d.durationMinutes) * 60_000, viewOffsetMs: Double(d.durationMinutes) * 60_000 * d.progress)
        }
    }

    // MARK: Games

    /// Consoles that have sample games, in the order they appear.
    public static let gameConsoleIDs = ["switch", "nes", "snes", "gameboy", "genesis"]

    public static func games(forConsole id: String) -> [DemoGame] {
        switch id {
        case "switch":
            return [
                g("Moonpetal Run", "Fernlight Studio", 2023, 2, ["Platformer", "Adventure"], "Sprint across a night garden where every flower is a trampoline and every shadow is a shortcut."),
                g("Kettle Kingdom", "Little Hearth Games", 2022, 1, ["Simulation", "Puzzle"], "Run a tiny tea shop on the back of a very patient tortoise, one pot at a time."),
                g("Starlit Courier", "Paper Rocket", 2024, 1, ["Adventure", "Platformer"], "Deliver letters between floating islands, and find out why nobody has answered in years."),
                g("Brickyard Racers", "Gearbox Garden", 2021, 4, ["Racing"], "Four-player kart races through a miniature city built entirely of wooden blocks."),
                g("Quill & Compass", "Inkwell Works", 2023, 1, ["Puzzle", "Adventure"], "Redraw an old map to open doors that only exist on paper."),
                g("Lantern Depths", "Fernlight Studio", 2024, 2, ["Adventure"], "Dive into a drowned library with a single lantern and a very patient octopus."),
                g("Cloudhopper", "Paper Rocket", 2022, 2, ["Platformer"], "Bounce between weather fronts and collect rainbows before they fade."),
                g("Pocket Foundry", "Little Hearth Games", 2024, 1, ["Simulation", "Puzzle"], "Smelt, shape and ship tiny metal gadgets from a workshop the size of a shoebox."),
            ]
        case "nes":
            return [
                g("Block Garden", "Sparrow Bits", 1989, 1, ["Puzzle"], "Stack falling planters to keep the garden in bloom."),
                g("Nimble Knight", "Sparrow Bits", 1988, 1, ["Platformer"], "A very small knight with a very large jump."),
                g("Turbo Tortoise", "Sparrow Bits", 1990, 2, ["Racing"], "Slow and steady wins, if you take the shortcuts."),
                g("Moon Mission", "Sparrow Bits", 1987, 1, ["Shooter"], "Defend the lunar greenhouse from space moths."),
            ]
        case "snes":
            return [
                g("Crystal Caravan", "Sparrow Bits", 1994, 2, ["Adventure", "RPG"], "Lead a caravan of misfit traders across a glass desert."),
                g("Pocket Pirates", "Sparrow Bits", 1993, 2, ["Platformer"], "Swashbuckle your way through twelve tiny islands."),
                g("Starlight Derby", "Sparrow Bits", 1995, 2, ["Racing"], "Race comets through the evening sky."),
                g("Tinker Town", "Sparrow Bits", 1996, 1, ["Simulation"], "Build a town one gear at a time."),
            ]
        case "gameboy":
            return [
                g("Pebble Quest", "Sparrow Bits", 1998, 1, ["RPG"], "Collect friendly pebbles and teach them to dance."),
                g("Sky Cart", "Sparrow Bits", 1999, 1, ["Racing"], "Pedal a cloud cart over the sleepy hills."),
                g("Inkblot", "Sparrow Bits", 2001, 1, ["Puzzle"], "Fill the page without crossing your own line."),
            ]
        case "genesis":
            return [
                g("Neon Skiff", "Sparrow Bits", 1992, 2, ["Shooter"], "Pilot a glowing skiff down a canal of light."),
                g("Cactus Courier", "Sparrow Bits", 1993, 1, ["Platformer"], "Deliver cactus mail across the dunes."),
                g("Ember Arena", "Sparrow Bits", 1994, 2, ["Fighting"], "Two lanterns, one arena, no mercy for wicks."),
            ]
        default:
            return []
        }
    }

    private static func g(_ title: String, _ publisher: String, _ year: Int, _ players: Int, _ genres: [String], _ blurb: String) -> DemoGame {
        DemoGame(title: title, publisher: publisher, year: year, players: players, genres: genres, blurb: blurb)
    }

    /// File name of a sample game in its console's folder (nothing exists there).
    public static func fileName(_ game: DemoGame, console: Console) -> String {
        game.title + "." + (console.extensions.first ?? "bin")
    }

    /// The sample game a file name belongs to, in any console.
    public static func game(fileName: String) -> DemoGame? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        for id in gameConsoleIDs {
            if let hit = games(forConsole: id).first(where: { $0.title == stem }) { return hit }
        }
        return nil
    }

    /// How long ago (seconds) each sample game was last played; the rest were not.
    public static func playedSecondsAgo(console id: String) -> [String: TimeInterval] {
        switch id {
        case "switch": return ["Moonpetal Run": 1_500, "Lantern Depths": 10_800, "Kettle Kingdom": 90_000]
        case "snes": return ["Crystal Caravan": 200_000]
        default: return [:]
        }
    }
}
