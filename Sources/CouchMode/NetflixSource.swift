// Owns: Netflix's reader for the shell's own streaming screens: which of
// Netflix's own pages each proxy action opens and reads, through the shared
// PageDriver (one action at a time, latest wins, bounded, logged):
//   home     -> /browse's page data (NetflixHome)
//   search   -> its search page's result cards (NetflixSearch)
//   details  -> the title's page, its details panel (NetflixDetails)
//   episodes -> pick the season in that panel's own season picker, read again
//   profile  -> on Netflix's "Who's watching?" gate: press that profile's tile (NetflixGate); else
//               its profile switch address, so the next home is that profile's
//   gate     -> when /browse lands on that gate, home is the gate's profiles with no rows
//               (StreamHome.asksWhoIsWatching), so the screen opens its picker
// "More in a row" is nil on purpose: the page's rows are Pinot carousels with a total and an
// endCursor, but the page pages them with a persisted GraphQL query (its id lives in the page's
// script bundle, not in the page's data), and a row is only drawn when the page's UI is, so there
// is no request this reader can make as the page makes it. (The row total is still set; the
// screens ask once, get nothing, and stop.)

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
    /// The gate the last details, search or season read ran into (taken once by the screen).
    private var gateSeen: StreamHome?

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func home() async -> StreamHome? {
        // /browse may land on the gate (which has no home data): ready is either, and the read is
        // the gate's tiles when it is the gate, else the page data. One open, one read.
        guard let json = await driver.read("home", open: Self.browseURL,
                                           ready: NetflixGate.readyOrGate(Self.pageDataReady),
                                           script: NetflixGate.readOrGate(NetflixHome.extractScript))
        else { return nil }
        if let gate = NetflixGate.parse(json) { return gate }
        return NetflixHome.parse(graphQLCache: Data(json.utf8))
    }

    func takeGate() -> StreamHome? {
        defer { gateSeen = nil }
        return gateSeen
    }

    /// A read's answer that is the gate's profiles instead of the page's data: kept for the screen, and the read is nil.
    private func sawGate(_ json: String) -> Bool {
        guard let gate = NetflixGate.parse(json) else { return false }
        gateSeen = gate
        return true
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let url = NetflixSearch.pageURL(query: query) else { return [] }
        let action = driver.begin("search")
        guard await driver.open(url, for: action) else { return nil }
        gateSeen = nil
        guard await driver.waitFor(NetflixGate.readyOrGate(NetflixSearch.readyScript), for: action, timeout: Self.searchResultsWait,
                                   what: "results", required: false) else {
            return driver.isCurrent(action) ? [] : nil
        }
        guard let json = await driver.text(NetflixGate.readOrGate(NetflixSearch.resultsScript), for: action, what: "results unreadable") else { return nil }
        if sawGate(json) { return nil }
        return NetflixSearch.titles(fromResults: json,
                                    play: { NetflixHome.playURL(videoID: $0) },
                                    page: { NetflixHome.pageURL(videoID: $0) })
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        gateSeen = nil
        guard let page = title.page,
              let json = await driver.read("details", open: page, ready: NetflixGate.readyOrGate(NetflixDetails.readyScript),
                                           script: NetflixGate.readOrGate(NetflixDetails.readScript(for: title.kind)), timeouts: Self.panel)
        else { return nil }
        if sawGate(json) { return nil }
        return NetflixDetails.details(fromRead: json, title: title)
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let page = title.page else { return nil }
        let action = driver.begin("episodes")
        gateSeen = nil
        // The title's panel has to be what the page shows (another action may have moved it).
        if driver.view.url?.path != page.path {
            guard await driver.open(page, for: action),
                  await driver.waitFor(NetflixGate.readyOrGate(NetflixDetails.readyScript), for: action, what: "no details panel") else { return nil }
        }
        // The page may be the gate instead of the title's panel: that is the answer (the screen asks who is watching).
        if await WebPage.run(NetflixGate.onGateScript, in: driver.view, timeout: .seconds(5)) as? Bool == true {
            if let json = await WebPage.text(NetflixGate.extractScript, in: driver.view, timeout: .seconds(5)) { _ = sawGate(json) }
            return nil
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

    func switchProfile(to profileID: String) async -> ProfileSwitch {
        // On the gate the choice is one press of that profile's tile (the script says no when the
        // page isn't the gate); the next home() reads that profile's home.
        let tile = driver.begin("profile")
        if await WebPage.run(NetflixGate.chooseScript(profileID: profileID), in: driver.view, timeout: .seconds(5)) as? Bool == true {
            return ProfileSwitch(succeeded: await driver.waitFor(NetflixGate.leftGateScript, for: tile, timeout: .seconds(15),
                                                                 what: "gate didn't close"))
        }
        guard let url = NetflixHome.switchProfileURL(profileID: profileID) else { return .failed }
        return ProfileSwitch(succeeded: await driver.open(url, for: tile))
    }
}
