// Owns: Netflix's reader for the shell's own streaming screens: which of
// Netflix's own pages each proxy action opens and reads, through the shared
// PageDriver (one action at a time, latest wins, bounded, logged):
//   home     -> /browse's page data (NetflixHome)
//   search   -> its search page's result cards (NetflixSearch)
//   details  -> the title's page, its details panel (NetflixDetails)
//   episodes -> pick the season in that panel's own season picker, read again
//   profile  -> its profile switch address, so the next home is that profile's
// "More in a row" isn't read yet (nil): rows hold what the home page loaded.

import Foundation
import CouchModeCore

@MainActor
final class NetflixSource: StreamSource {
    private static let browseURL = URL(string: "https://www.netflix.com/browse")!
    private static let pageDataReady = "return !!(window.netflix && window.netflix.reactContext && window.netflix.reactContext.models && window.netflix.reactContext.models.graphql);"
    /// Netflix draws search results after its page loads; none by then means none.
    private static let searchResultsWait: Duration = .seconds(8)
    /// Reading a details panel waits for its episode list, then expands a long season's.
    private static let panel = PageDriver.Timeouts(read: .seconds(10))

    let service: Service
    private let driver: PageDriver

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func home() async -> StreamHome? {
        guard let json = await driver.read("home", open: Self.browseURL, ready: Self.pageDataReady,
                                           script: NetflixHome.extractScript) else { return nil }
        return NetflixHome.parse(graphQLCache: Data(json.utf8))
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let url = NetflixSearch.pageURL(query: query) else { return [] }
        let action = driver.begin("search")
        guard await driver.open(url, for: action) else { return nil }
        guard await driver.waitFor(NetflixSearch.readyScript, for: action, timeout: Self.searchResultsWait,
                                   what: "results", required: false) else {
            return driver.isCurrent(action) ? [] : nil
        }
        guard let json = await driver.text(NetflixSearch.resultsScript, for: action, what: "results unreadable") else { return nil }
        return NetflixSearch.titles(fromResults: json,
                                    play: { NetflixHome.playURL(videoID: $0) },
                                    page: { NetflixHome.pageURL(videoID: $0) })
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        guard let page = title.page,
              let json = await driver.read("details", open: page, ready: NetflixDetails.readyScript,
                                           script: NetflixDetails.readScript(for: title.kind), timeouts: Self.panel)
        else { return nil }
        return NetflixDetails.details(fromRead: json, title: title)
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let page = title.page else { return nil }
        let action = driver.begin("episodes")
        // The title's panel has to be what the page shows (another action may have moved it).
        if driver.view.url?.path != page.path {
            guard await driver.open(page, for: action),
                  await driver.waitFor(NetflixDetails.readyScript, for: action, what: "no details panel") else { return nil }
        }
        guard await driver.yes(NetflixDetails.chooseSeasonScript(seasonName: season.name), for: action,
                               what: "season not in Netflix's picker"),
              await driver.waitFor(NetflixDetails.seasonShownScript(seasonID: season.id), for: action,
                                   what: "season didn't show"),
              let json = await driver.text(NetflixDetails.readScript(for: .show), for: action,
                                           timeout: Self.panel.read, what: "episodes unreadable")
        else { return nil }
        return NetflixDetails.episodes(fromRead: json)
    }

    func more(in row: StreamRow) async -> [StreamTitle]? { nil }

    func switchProfile(to profileID: String) async -> Bool {
        guard let url = NetflixHome.switchProfileURL(profileID: profileID) else { return false }
        return await driver.open(url, for: driver.begin("profile"))
    }
}
