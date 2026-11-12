// Owns: Hulu's reader for the shell's own streaming screens: which of
// Hulu's own pages each proxy action opens and reads, through the shared
// PageDriver (one action at a time, latest wins, bounded, logged):
//   home     -> /hub/home: the one discover request the page makes (HuluHome)
//   search   -> /search: type into the page's own search box, read its list (HuluSearch)
//   details  -> the title's page: the hub request the page makes (HuluDetails)
//   episodes -> the season request the page's season picker makes, read again
//   profile  -> the top bar's own "switch profile" choice, in place
// "More in a row" is nil on purpose: the home request already returns up to 50 titles for a row
// the discover service pages (a pagination.next link past that), and a row is capped at
// StreamLimits.maxTitlesPerRow (40), so a next page could never add a title the screens keep.

import Foundation
import CouchModeCore

@MainActor
final class HuluSource: StreamSource {
    private static let homeURL = URL(string: "https://www.hulu.com/hub/home")!
    /// Hulu lists search results as the page's answers arrive; none by then means none.
    private static let searchResultsWait: Duration = .seconds(8)
    /// A title's hub (and a season's progress) is a couple of requests.
    private static let titleRead = PageDriver.Timeouts(read: .seconds(12))
    private static let profileSwitchWait: Duration = .seconds(10)

    let service: Service
    private let driver: PageDriver

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func home() async -> StreamHome? {
        guard let json = await driver.read("home", open: Self.homeURL, ready: HuluHome.readyScript,
                                           script: HuluHome.extractScript, timeouts: Self.titleRead) else { return nil }
        return HuluHome.parse(json)
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let text = StreamSearch.normalized(query) else { return [] }
        let action = driver.begin("search")
        guard await driver.open(HuluSearch.pageURL, for: action),
              await driver.waitFor(HuluSearch.readyScript, for: action, what: "no search box"),
              await driver.yes(HuluSearch.typeScript(query: text), for: action, what: "couldn't type the query")
        else { return nil }
        guard await driver.waitFor(HuluSearch.resultsReadyScript, for: action, timeout: Self.searchResultsWait,
                                   what: "results", required: false) else {
            return driver.isCurrent(action) ? [] : nil
        }
        guard let json = await driver.text(HuluSearch.resultsScript, for: action, timeout: Self.titleRead.read,
                                           what: "results unreadable") else { return nil }
        return HuluSearch.titles(fromResults: json)
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        guard let page = title.page,
              let json = await driver.read("details", open: page, ready: HuluDetails.readyScript,
                                           script: HuluDetails.readScript, timeouts: Self.titleRead) else { return nil }
        return HuluDetails.details(fromRead: json, title: title)
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let page = title.page else { return nil }
        let action = driver.begin("episodes")
        // The title's page has to be what the page shows (another action may have moved it).
        if driver.view.url?.path != page.path {
            guard await driver.open(page, for: action),
                  await driver.waitFor(HuluDetails.readyScript, for: action, what: "no title page") else { return nil }
        }
        guard let json = await driver.text(HuluDetails.seasonScript(seasonID: season.id), for: action,
                                           timeout: Self.titleRead.read, what: "season unreadable") else { return nil }
        return HuluDetails.episodes(fromSeason: json)
    }

    func more(in row: StreamRow) async -> [StreamTitle]? { nil }

    func switchProfile(to profileID: String) async -> Bool {
        let action = driver.begin("profile")
        guard await driver.open(Self.homeURL, for: action),
              await driver.waitFor(HuluHome.profileListReadyScript, for: action, what: "no profile list"),
              await driver.yes(HuluHome.chooseProfileScript(profileID: profileID), for: action, what: "profile not in Hulu's list")
        else { return false }
        return await driver.waitFor(HuluHome.profileIsCurrentScript(profileID: profileID), for: action,
                                    timeout: Self.profileSwitchWait, what: "profile didn't switch")
    }
}
