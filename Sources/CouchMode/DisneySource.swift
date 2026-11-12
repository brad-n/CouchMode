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
//   restore  -> /select-profile, choosing the earlier profile, once, when a switch ended on
//               Disney's profile form and the person backed out without finishing it
// Playback is never started here: Play hands the title's /play/<id> address to
// the service's own player page. "More in a row" isn't read (nil): rows hold
// what the home request returned.

import Foundation
import os
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
    /// Where each row's next batch starts; cleared whenever the home is read again or the profile switches.
    private var cursors: [String: DisneyMore.Cursor] = [:]
    /// The profile (name) the last home showed as current, and the one to switch back to if a
    /// switch ends on a form the person backs out of.
    private var shownProfile: String?
    private var unfinished = UnfinishedSwitch()
    private var noticeLine: String?
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "disney")

    init(service: Service, player: WebPlayer) {
        self.service = service
        driver = PageDriver(service: service, player: player)
    }

    func takeNotice() -> String? {
        defer { noticeLine = nil }
        return noticeLine
    }

    func home() async -> StreamHome? {
        cursors = [:]
        await restoreUnfinishedSwitch()
        if let home = await readHome() { return home }
        // Opening the session page lands on the profile form while that profile is unfinished:
        // the page only shows it once the read has tried, so look again here.
        guard unfinished.previous != nil, DisneyHome.isProfileForm(driver.view.url) else { return nil }
        await restoreUnfinishedSwitch()
        return await readHome()
    }

    /// One read of the home. The wait for the page ends as soon as it is ready or has landed on a
    /// profile form (which never gets ready); on the form nothing is read and nil comes back.
    private func readHome() async -> StreamHome? {
        let action = driver.begin("home")
        guard await driver.open(DisneyExplore.sessionPageURL, for: action, timeout: Self.homeRead.load),
              await driver.waitFor(DisneyHome.readyOrFormScript, for: action, timeout: Self.homeRead.ready, what: "never ready"),
              !DisneyHome.isProfileForm(driver.view.url),
              let json = await driver.text(DisneyHome.extractScript, for: action, timeout: Self.homeRead.read, what: "unreadable")
        else { return nil }
        cursors = DisneyMore.cursors(fromHome: json)
        let home = DisneyHome.parse(json)
        shownProfile = home?.currentProfileID
        return home
    }

    /// A switch that ended on Disney's profile form leaves the page stuck there when the person
    /// backs out unfinished. Choose the profile that was active before, on the site's own
    /// "who's watching" page (one try; success or not, the memory is cleared).
    private func restoreUnfinishedSwitch() async {
        guard let name = unfinished.profileToRestore(onForm: DisneyHome.isProfileForm(driver.view.url)) else { return }
        unfinished.clear()
        let action = driver.begin("restore")
        guard await driver.open(DisneyHome.selectProfileURL, for: action),
              await driver.waitFor(DisneyHome.pickerReadyScript, for: action, what: "no profile tiles"),
              await driver.yes(DisneyHome.choosePickerProfileScript(profileID: name), for: action, what: "profile not on Disney+'s picker"),
              await driver.waitFor(DisneyHome.leftPickerScript, for: action, timeout: Self.profileSwitchWait, what: "picker didn't close")
        else {
            log.error("couldn't switch back after an unfinished profile form")
            return
        }
        noticeLine = "Switched back to \(name)"
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

    func more(in row: StreamRow) async -> [StreamTitle]? {
        guard let cursor = cursors[row.id], let script = DisneyMore.script(for: cursor) else { return nil }
        cursors[row.id] = nil   // one request per reach; a successful read puts the next cursor back
        let action = driver.begin("more")
        guard await prepare(action),
              let json = await driver.text(script, for: action, timeout: Self.titleRead.read, what: "more unreadable"),
              let batch = DisneyMore.titles(fromRead: json, cursor: cursor) else { return nil }
        cursors[row.id] = batch.cursor
        return batch.titles
    }

    /// Presses the profile in the top bar's menu, nothing more. Some profiles land on Disney's own
    /// "update this profile" form, which asks for details only the person can give: that is
    /// `.needsPerson`, and the form is left alone (never filled in or submitted).
    func switchProfile(to profileID: String) async -> ProfileSwitch {
        cursors = [:]
        let before = shownProfile
        let result = await pressProfile(profileID)
        unfinished.record(result, from: before)
        return result
    }

    private func pressProfile(_ profileID: String) async -> ProfileSwitch {
        let action = driver.begin("profile")
        guard await prepare(action),
              await driver.yes(DisneyHome.chooseProfileScript(profileID: profileID), for: action, what: "profile not in Disney+'s menu")
        else { return .failed }
        guard await driver.waitFor(DisneyHome.profileSettledScript(profileID: profileID), for: action,
                                   timeout: Self.profileSwitchWait, what: "profile didn't switch") else { return .failed }
        if DisneyHome.isProfileForm(driver.view.url) { return .needsPerson }
        return ProfileSwitch(succeeded: await driver.yes(DisneyHome.profileIsCurrentScript(profileID: profileID), for: action,
                                                         what: "profile didn't switch"))
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
