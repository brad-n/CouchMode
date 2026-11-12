// Owns: Prime Video's reader for the shell's own streaming screens: which of
// Prime's own pages each proxy action opens and reads, through the shared
// PageDriver (one action at a time, latest wins, bounded, logged). Every Prime
// page carries its own data as JSON in the page (the hydration script tag), so
// each action opens the one page the person's action needs and reads that; no
// request is made and no token is touched:
//   home     -> /: the rows, Continue Watching with progress, and the top bar's
//               profile list (PrimeHome)
//   search   -> /search/?phrase=<text>: the page's result grids (PrimeSearch)
//   details  -> /detail/<id>: the title's page: facts, the play action, seasons
//               and the open season's episodes (PrimeDetails)
//   episodes -> /detail/<season id>: the season's own page, as the site's season
//               picker opens it (PrimeDetails)
//   profile  -> the top bar's own "switch profile" button for that profile, then
//               the page reloads as that profile
// Playback is never started here: Play hands the title's /detail/<id>?autoplay=1
// address to the service's own page, whose player opens over it, so this source
// also says how to tell the player is showing (playerShownScript). Titles to rent,
// buy or get through a channel have no playback action: Play opens their page.
//   more     -> POST /api/paginateCollection: the one request the page makes at the end of a
//               carousel (PrimeMore), run in the home page; the row's cursor is kept here in memory

import Foundation
import CouchModeCore

@MainActor
final class PrimeSource: StreamSource {
    /// Prime's pages are server-rendered with their data inside: a normal page load, not a request chain.
    private static let pageRead = PageDriver.Timeouts(read: .seconds(12))
    private static let profileSwitchWait: Duration = .seconds(15)
    /// How long a search page may take to say it has no results before that is the answer.
    private static let searchReadyWait: Duration = .seconds(8)

    let service: Service
    private let driver: PageDriver
    /// Where each row's next batch starts; cleared whenever the home is read again or the profile switches.
    private var cursors: [String: PrimeMore.Cursor] = [:]

    var playerShownScript: String? { PrimeSite.playerShownScript }

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func home() async -> StreamHome? {
        cursors = [:]
        guard let json = await driver.read("home", open: PrimeHome.homeURL, ready: PrimeHome.readyScript,
                                           script: PrimeHome.extractScript, timeouts: Self.pageRead) else { return nil }
        cursors = PrimeMore.cursors(fromHome: json)
        return PrimeHome.parse(json)
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let url = PrimeSearch.pageURL(query: query) else { return [] }
        let action = driver.begin("search")
        guard await driver.open(url, for: action) else { return nil }
        // A search with no matches is a valid answer ([]), not a failure.
        guard await driver.waitFor(PrimeSearch.readyScript, for: action, timeout: Self.searchReadyWait, what: "results",
                                   required: false) else { return driver.isCurrent(action) ? [] : nil }
        guard let json = await driver.text(PrimeSearch.resultsScript, for: action, timeout: Self.pageRead.read,
                                           what: "results unreadable") else { return nil }
        return PrimeSearch.titles(fromResults: json)
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        guard let page = title.page,
              let json = await driver.read("details", open: page, ready: PrimeDetails.readyScript,
                                           script: PrimeDetails.readScript, timeouts: Self.pageRead) else { return nil }
        return PrimeDetails.details(fromRead: json, title: title)
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let page = PrimeDetails.pageURL(forID: season.id),
              let json = await driver.read("episodes", open: page, ready: PrimeDetails.readyScript,
                                           script: PrimeDetails.readScript, timeouts: Self.pageRead) else { return nil }
        return PrimeDetails.episodes(fromRead: json)
    }

    func more(in row: StreamRow) async -> [StreamTitle]? {
        guard let cursor = cursors[row.id], let script = PrimeMore.script(for: cursor) else { return nil }
        cursors[row.id] = nil   // one request per reach; a successful read puts the next cursor back
        let action = driver.begin("more")
        // The request is the home page's own, so it runs in that page (opened again when another is showing).
        if !PrimeHome.isHomePage(driver.view.url) {
            guard await driver.open(PrimeHome.homeURL, for: action) else { return nil }
        }
        guard await driver.waitFor(PrimeHome.readyScript, for: action, what: "never ready"),
              let json = await driver.text(script, for: action, timeout: Self.pageRead.read, what: "more unreadable"),
              let batch = PrimeMore.titles(fromRead: json, cursor: cursor) else { return nil }
        cursors[row.id] = batch.cursor
        return batch.titles
    }

    func switchProfile(to profileID: String) async -> Bool {
        cursors = [:]
        let action = driver.begin("profile")
        guard await driver.open(PrimeHome.homeURL, for: action),
              await driver.waitFor(PrimeHome.readyScript, for: action, what: "never ready"),
              await driver.yes(PrimeHome.chooseProfileScript(profileID: profileID), for: action, what: "profile not in Prime's menu")
        else { return false }
        return await driver.waitFor(PrimeHome.profileIsCurrentScript(profileID: profileID), for: action,
                                    timeout: Self.profileSwitchWait, what: "profile didn't switch")
    }
}
