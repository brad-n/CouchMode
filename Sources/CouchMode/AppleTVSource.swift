// Owns: Apple TV's reader for the shell's own streaming screens: which Apple TV
// page or request each proxy action uses, through the shared PageDriver (one
// action at a time, latest wins, bounded, logged). tv.apple.com is a web app whose
// views all come from its own API (see AppleTVSite), so every read works from one
// quiet Apple TV page (the search page, which plays nothing; the home and title
// pages start a preview) and makes the same request the site makes for that view,
// signed in with the page's own MusicKit session (the tokens stay inside the scripts):
//   home     -> canvases/channels/tvs.sbd.4000: Up Next with progress, charts, rows (AppleTVHome)
//   search   -> search?searchTerm=<text>: the request the search page makes (AppleTVSearch)
//   details  -> shows/<id> or movies/<id>: the request a title's page makes (AppleTVDetails)
//   episodes -> shows/<id>/episodes?selectedSeasonId=<season id>, then the next windows with
//               selectedEpisodeId=<last id> until the season ends (at most 6 requests), the
//               requests the page's season picker and episode shelf make (AppleTVDetails)
//   profile  -> none: Apple TV has no profiles on the web, so the one profile is always current
//               and any other choice is .failed
// Playback is never started here: Play hands the title's own address with action=play to the
// service's own page, whose player opens as a dialog over it (not a page of its own), so this
// source also says how to tell the player is showing (playerShownScript). Titles this account
// can't play with Apple's own player (to buy, rent, or on another service) have no playback
// action: Play opens their page. "More in a row" isn't read (nil): rows hold what the home
// request returned.

import Foundation
import CouchModeCore

@MainActor
final class AppleTVSource: StreamSource {
    /// A signed-in request chain: the page's own session, one request (a season may take a few).
    private static let homeRead = PageDriver.Timeouts(read: .seconds(15))
    private static let titleRead = PageDriver.Timeouts(read: .seconds(15))
    /// How long to look for an already-loaded Apple TV page before opening one.
    private static let alreadyReadyWait: Duration = .seconds(2)

    let service: Service
    private let driver: PageDriver

    var playerShownScript: String? { AppleTVSite.playerShownScript }

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func home() async -> StreamHome? {
        let action = driver.begin("home")
        guard await prepare(action),
              let json = await driver.text(AppleTVHome.extractScript, for: action, timeout: Self.homeRead.read, what: "home unreadable")
        else { return nil }
        return AppleTVHome.parse(json)
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let text = StreamSearch.normalized(query) else { return [] }
        let action = driver.begin("search")
        guard await prepare(action),
              let json = await driver.text(AppleTVSearch.script(query: text), for: action, timeout: Self.titleRead.read,
                                           what: "results unreadable") else { return nil }
        return AppleTVSearch.titles(fromResults: json)
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        guard let script = AppleTVDetails.readScript(id: title.id, kind: title.kind) else { return nil }
        let action = driver.begin("details")
        guard await prepare(action),
              let json = await driver.text(script, for: action, timeout: Self.titleRead.read, what: "details unreadable") else { return nil }
        return AppleTVDetails.details(fromRead: json, title: title)
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let script = AppleTVDetails.seasonScript(showID: title.id, seasonID: season.id) else { return nil }
        let action = driver.begin("episodes")
        guard await prepare(action),
              let json = await driver.text(script, for: action, timeout: Self.titleRead.read, what: "season unreadable") else { return nil }
        let list = AppleTVDetails.episodes(fromSeason: json)
        return list.isEmpty ? nil : list
    }

    func more(in row: StreamRow) async -> [StreamTitle]? { nil }

    /// Apple TV has one profile on the web: choosing it is already the case, anything else can't be done.
    func switchProfile(to profileID: String) async -> ProfileSwitch {
        ProfileSwitch(succeeded: profileID == AppleTVHome.profileID)
    }

    /// Makes sure the service's page is a quiet Apple TV page the requests can run in: the one already
    /// there when it is (the player's page and other sites are not), else the search page.
    private func prepare(_ action: PageDriver.Action) async -> Bool {
        if AppleTVSite.isUsableSessionPage(driver.view.url),
           await driver.waitFor(AppleTVHome.readyScript, for: action, timeout: Self.alreadyReadyWait, what: "page not ready", required: false) {
            return true
        }
        guard driver.isCurrent(action), await driver.open(AppleTVSite.sessionPageURL, for: action) else { return false }
        return await driver.waitFor(AppleTVHome.readyScript, for: action, what: "never ready")
    }
}
