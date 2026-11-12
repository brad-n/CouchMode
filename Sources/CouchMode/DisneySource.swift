// Owns: Disney+'s reader for the shell's own streaming screens: which Disney+
// page or request each proxy action uses, through the shared PageDriver (one
// action at a time, latest wins, bounded, logged). Disney+ is a single-page
// app whose views all come from its explore API, so every read works from one
// quiet Disney page (the search page, which plays nothing) and makes the same
// request the site makes for that view, signed in with the page's own session:
//   home     -> globalNav, then page/<home page id>: the rows (DisneyHome)
//   profiles -> the top bar's profile menu, read on the home action (DisneyHome)
//   search   -> search?query=<text>: the same request the search page makes (DisneySearch)
//   details  -> page/entity-<id>: the request the title's page makes (DisneyDetails)
//   episodes -> season/<seasonId>: the request the page's season picker makes
//   profile  -> the top bar's own profile menu, choosing the profile in place
// Playback is never started here: Play hands the title's /play/<id> address to
// the service's own player page. "More in a row" isn't read (nil): rows hold
// what the home request returned.

import Foundation
import CouchModeCore

@MainActor
final class DisneySource: StreamSource {
    /// The home is a globalNav request, a large page request and the profile menu.
    private static let homeRead = PageDriver.Timeouts(read: .seconds(20))
    private static let titleRead = PageDriver.Timeouts(read: .seconds(12))
    private static let profileSwitchWait: Duration = .seconds(15)
    /// How long to look for an already-loaded Disney page before opening one.
    private static let alreadyReadyWait: Duration = .seconds(2)

    let service: Service
    private let driver: PageDriver

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func home() async -> StreamHome? {
        guard let json = await driver.read("home", open: DisneyExplore.sessionPageURL, ready: DisneyHome.readyScript,
                                           script: DisneyHome.extractScript, timeouts: Self.homeRead) else { return nil }
        return DisneyHome.parse(json)
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let text = StreamSearch.normalized(query) else { return [] }
        let action = driver.begin("search")
        guard await prepare(action),
              let json = await driver.text(DisneySearch.script(query: text), for: action, timeout: Self.titleRead.read,
                                           what: "results unreadable") else { return nil }
        return DisneySearch.titles(fromResults: json)
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        guard let script = DisneyDetails.readScript(entityID: title.id) else { return nil }
        let action = driver.begin("details")
        guard await prepare(action),
              let json = await driver.text(script, for: action, timeout: Self.titleRead.read, what: "details unreadable") else { return nil }
        return DisneyDetails.details(fromRead: json, title: title)
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let script = DisneyDetails.seasonScript(seasonID: season.id) else { return nil }
        let action = driver.begin("episodes")
        guard await prepare(action),
              let json = await driver.text(script, for: action, timeout: Self.titleRead.read, what: "season unreadable") else { return nil }
        return DisneyDetails.episodes(fromSeason: json)
    }

    func more(in row: StreamRow) async -> [StreamTitle]? { nil }

    func switchProfile(to profileID: String) async -> Bool {
        let action = driver.begin("profile")
        guard await prepare(action),
              await driver.yes(DisneyHome.chooseProfileScript(profileID: profileID), for: action, what: "profile not in Disney+'s menu")
        else { return false }
        return await driver.waitFor(DisneyHome.profileIsCurrentScript(profileID: profileID), for: action,
                                    timeout: Self.profileSwitchWait, what: "profile didn't switch")
    }

    /// Makes sure the service's page is a signed-in Disney page the requests
    /// can run in: the one already there when it is (the player page and other
    /// sites are not), else the quiet session page.
    private func prepare(_ action: PageDriver.Action) async -> Bool {
        if DisneyExplore.isUsableSessionPage(driver.view.url),
           await driver.waitFor(DisneyHome.readyScript, for: action, timeout: Self.alreadyReadyWait, what: "page not ready", required: false) {
            return true
        }
        guard driver.isCurrent(action), await driver.open(DisneyExplore.sessionPageURL, for: action) else { return false }
        return await driver.waitFor(DisneyHome.readyScript, for: action, what: "never ready")
    }
}
