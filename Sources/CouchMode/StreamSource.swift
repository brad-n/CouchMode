// Owns: the seam between the shell's own streaming screens and a service's
// reader (StreamSource), plus a fake reader with built-in sample data
// (SampleStreamSource) for checking the screens without a real service.
// A reader is a proxy: each call is the same one action on the real site,
// read back. Playback is never a source call; it is the title's own player.

import Foundation
import CouchModeCore

/// One service's reader, as a proxy: each call is the same one action on the real site, read back.
@MainActor protocol StreamSource: AnyObject {
    var service: Service { get }
    func home() async -> StreamHome?          // nil: couldn't read; the caller falls back to the website
    func details(for title: StreamTitle) async -> StreamTitleDetails?   // nil: show what the row had
    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]?
    func search(_ query: String) async -> [StreamTitle]?                // nil: search unavailable
    func more(in row: StreamRow) async -> [StreamTitle]?                // nil: nothing more
    func switchProfile(to profileID: String) async -> ProfileSwitch   // .needsPerson: landed on a page only the person can finish
    /// A JS function body that returns true while the service's player is showing, for a service whose
    /// player is not a page of its own. nil (the default): the player is the page at the play address.
    var playerShownScript: String? { get }
    /// A one-time line the reader has for the screen after a read (e.g. it undid an unfinished profile switch); nil by default.
    func takeNotice() -> String?
    /// The service's "who's watching" gate, when the last details, search or season read found the page on it
    /// (that read answers nil); taken once. nil by default.
    func takeGate() -> StreamHome?
}

extension StreamSource {
    var playerShownScript: String? { nil }
    func takeNotice() -> String? { nil }
    func takeGate() -> StreamHome? { nil }
}

@MainActor
final class SampleStreamSource: StreamSource {
    private enum Sample {
        static let delay: Duration = .milliseconds(300)
        static let base = "https://example.invalid"
        static let rowTotal = 30
        static let firstBatch = 12
        static let moreBatch = 8
        static let rankedCount = 10
        static let kidsProfile = "kids"
        static let lockedProfile = "locked"
        static let names = ["The Long Voyage", "Paper Lanterns", "Northbound", "Static Bloom", "Harbor Lights", "Quiet Engines",
                            "The Last Orchard", "Glass Season", "Midnight Ferry", "Copper Hills", "Wild Signal", "Open Water",
                            "Salt and Iron", "Second Sunrise", "The Cartographer", "Low Tide", "Ember Road", "Parallel Park",
                            "Winter Garden", "Small Hours", "Fault Lines", "Blue Hour", "Tin Soldiers", "Kite Season"]
    }

    let service: Service
    private var currentProfile = "me"

    init(service: Service) { self.service = service }

    private func pause() async { try? await Task.sleep(for: Sample.delay) }

    private func url(_ path: String) -> URL { URL(string: "\(Sample.base)/\(service.id)/\(path)")! }

    private func title(_ n: Int, prefix: String, resume: Bool = false) -> StreamTitle {
        let isShow = n % 2 == 0
        let runtime = isShow ? 2700 : 6300
        var t = StreamTitle(id: "\(prefix)-\(n)", name: Sample.names[n % Sample.names.count] + (n >= Sample.names.count ? " \(n / Sample.names.count + 1)" : ""),
                            kind: isShow ? .show : .movie, play: url("watch/\(prefix)-\(n)"), page: url("title/\(prefix)-\(n)"),
                            episodeLabel: isShow ? "S1 · E\(n % 5 + 1)" : nil,
                            synopsis: "A sample synopsis for checking how long descriptions wrap under the title, from the couch.",
                            year: 2018 + n % 7, rating: n % 3 == 0 ? "R" : "TV-14", seasonsLabel: isShow ? "2 Seasons" : nil,
                            runtimeSeconds: runtime)
        if resume { t.resumeSeconds = runtime * (n % 4 + 1) / 5 }
        return t
    }

    private func titles(_ range: Range<Int>, prefix: String) -> [StreamTitle] { range.map { title($0, prefix: prefix) } }

    func home() async -> StreamHome? {
        await pause()
        var hero = title(0, prefix: "hero")
        hero.synopsis = "Six strangers share one ferry crossing, and only some of them reach the other shore. Sample data for checking the hero."
        let rows = [
            StreamRow(id: "continue", title: "Continue Watching", kind: .continueWatching,
                      titles: (1...5).map { title($0, prefix: "cw", resume: true) }),
            StreamRow(id: "top10", title: "Top 10 Today", kind: .ranked, titles: titles(0..<Sample.rankedCount, prefix: "top")),
            StreamRow(id: "popular", title: "Popular", kind: .standard, titles: titles(0..<Sample.firstBatch, prefix: "pop")),
            StreamRow(id: "new", title: "New This Week", kind: .standard,
                      titles: titles(0..<Sample.firstBatch, prefix: "new"), totalCount: Sample.rowTotal),
        ]
        return StreamHome(serviceID: service.id, profiles: [
            StreamProfile(id: "me", name: "Me"),
            StreamProfile(id: Sample.kidsProfile, name: "Kids", isKids: true),
            StreamProfile(id: Sample.lockedProfile, name: "Guest", isLocked: true),
        ], currentProfileID: currentProfile, hero: hero, rows: rows)
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        await pause()
        var full = title
        full.synopsis = (title.synopsis ?? "") + " This is the fuller description from the title's own page."
        guard title.kind == .show else { return StreamTitleDetails(title: full) }
        let first = (1...3).map { n in
            StreamEpisode(id: "\(title.id)-s1e\(n)", name: "Episode \(n)", number: n, synopsis: "A sample episode.",
                          runtimeSeconds: 2700, resumeSeconds: n == 2 ? 900 : nil, play: url("watch/\(title.id)-s1e\(n)"))
        }
        return StreamTitleDetails(title: full, seasons: [StreamSeason(id: "s1", name: "Season 1", episodes: first),
                                                         StreamSeason(id: "s2", name: "Season 2")], currentSeasonID: "s1")
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        await pause()
        guard season.id == "s2" else { return season.episodes }
        let titleID: String = title.id
        return (1...4).map { n in
            StreamEpisode(id: "\(titleID)-s2e\(n)", name: "Second Season, Part \(n)", number: n, synopsis: "A sample episode.",
                          runtimeSeconds: 3000, play: self.url("watch/\(titleID)-s2e\(n)"))
        }
    }

    func search(_ query: String) async -> [StreamTitle]? {
        await pause()
        let pool = titles(0..<Sample.names.count, prefix: "search")
        let hits = pool.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return Array((hits.isEmpty ? Array(pool.prefix(4)) : hits).prefix(StreamLimits.maxSearchResults))
    }

    func more(in row: StreamRow) async -> [StreamTitle]? {
        await pause()
        let have = row.titles.count
        guard let total = row.totalCount, have < total else { return nil }
        return titles(have..<min(total, have + Sample.moreBatch), prefix: row.id == "new" ? "new" : "pop")
    }

    func switchProfile(to profileID: String) async -> ProfileSwitch {
        await pause()
        guard profileID != Sample.lockedProfile else { return .failed }
        currentProfile = profileID
        return .switched
    }
}
