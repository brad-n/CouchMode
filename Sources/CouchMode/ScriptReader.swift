// Owns: the generic reader that runs any service's script package as that
// service's StreamSource. For each user action it does what the manifest says:
// open the action's page (one action at a time through PageDriver: latest wins,
// bounded, logged), wait for the package's ready function, call the package's
// action function inside the service's own page, and decode the JSON it
// returns into the shared vocabulary with PackageDecoder, which enforces the
// id, address and size rules. The script only returns data; it never plays
// anything and never runs outside the service's page. A row's paging cursor is
// opaque text the script returned, kept in memory only and handed back to it.
// Stateful steps stay here, in Swift, with the package supplying only page checks:
// the earlier profile (UnfinishedSwitch), switching back to it when a switch ended
// on a profile form the person backed out of, and the notice that says so.
// What a package must define: agents/add-a-streaming-service.md.

import Foundation
import os
import CouchModeCore

@MainActor
final class ScriptReader: StreamSource {
    let service: Service
    private let driver: PageDriver
    private let manifest: PackageManifest
    private let source: String
    private let decoder: PackageDecoder
    private var cursors: [String: String] = [:]
    /// The profile the last home showed as current, and the one to switch back to if a switch ends on a form the person backs out of.
    private var shownProfile: String?
    private var unfinished = UnfinishedSwitch()
    private var noticeLine: String?
    /// The gate the last details, search or season read ran into (taken once by the screen).
    private var gateSeen: StreamHome?
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "stream")

    var playerShownScript: String? { manifest.definesPlayerShown ? body(call: "reader.playerShown()", fallback: "false") : nil }

    init(service: Service, player: WebPlayer, package: ReaderPackage) {
        self.service = service
        driver = PageDriver(service: service, player: player)
        manifest = package.manifest
        source = package.source
        decoder = PackageDecoder(manifest: package.manifest)
    }

    // MARK: StreamSource

    func takeNotice() -> String? {
        defer { noticeLine = nil }
        return noticeLine
    }

    func takeGate() -> StreamHome? {
        defer { gateSeen = nil }
        return gateSeen
    }

    /// A read's answer that is the service's "who's watching" gate (a home that asks) instead of what was asked for:
    /// kept for the screen, and that read is nil. Any read may end there; only a package that says so ever does.
    private func sawGate(_ json: String) -> Bool {
        guard json.contains("asksWhoIsWatching"), let gate = decoder.home(json, serviceID: service.id)?.home, gate.asksWhoIsWatching else { return false }
        gateSeen = gate
        return true
    }

    func home() async -> StreamHome? {
        cursors = [:]
        await restoreUnfinishedSwitch()
        if let home = await readHome() { return home }
        // Opening the page lands on the profile form while that profile is unfinished: the page only shows it once the read has tried, so look again.
        guard unfinished.previous != nil, manifest.isProfileForm(driver.view.url) else { return nil }
        await restoreUnfinishedSwitch()
        return await readHome()
    }

    /// One read of the home. The wait ends as soon as the page is ready or is on a profile form (which never gets ready); on the form nothing is read.
    private func readHome() async -> StreamHome? {
        guard let page = manifest.pages[.home], let url = manifest.url(for: .home) else { return nil }
        let action = driver.begin("home")
        guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout),
              await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "never ready"),
              !manifest.isProfileForm(driver.view.url),
              let json = await driver.text(body(call: "reader.home({})"), for: action, timeout: page.readTimeout ?? manifest.readTimeout, what: "unreadable")
        else { return nil }
        guard let result = decoder.home(json, serviceID: service.id) else { return failed("home", "answer not usable") }
        cursors = result.cursors
        shownProfile = result.home.currentProfileID
        return result.home
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        gateSeen = nil
        guard title.page != nil, let json = await read("details", .details, .init(titlePage: title.page), call: "details",
                                                        args: ["title": PackageDecoder.argument(for: title)]) else { return nil }
        if sawGate(json) { return nil }
        return decoder.details(json) ?? failed("details", "answer not usable")
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let page = manifest.pages[.season], let url = manifest.url(for: .season, .init(titlePage: title.page, seasonID: season.id)) else { return nil }
        let action = driver.begin("episodes")
        gateSeen = nil
        // A season that is a request from the title's own page (not a page of its own) reuses that page when it is showing.
        if !(page.reuseIfOpen && isOpen(url)), !(await reuseCurrentPage(action, page)) {
            guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout) else { return nil }
        }
        guard await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "never ready"),
              let json = await driver.text(body(call: "reader.season(\(argument(["seasonID": season.id, "title": PackageDecoder.argument(for: title)])))"), for: action,
                                           timeout: page.readTimeout ?? manifest.readTimeout, what: "unreadable") else { return nil }
        if sawGate(json) { return nil }
        return decoder.episodes(json) ?? failed("episodes", "answer not usable")
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let page = manifest.pages[.search] else { return nil }
        guard let text = StreamSearch.normalized(query), let url = manifest.url(for: .search, .init(query: text)) else { return [] }
        let action = driver.begin("search")
        gateSeen = nil
        if !(await reuseCurrentPage(action, page)) {
            guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout) else { return nil }
            // A search with no matches is a valid answer ([]), not a failure, when the manifest says readiness is optional.
            guard await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "results",
                                       required: page.readyRequired) else { return driver.isCurrent(action) && !page.readyRequired ? [] : nil }
        }
        guard let json = await driver.text(body(call: "reader.search(\(argument(["query": text])))"), for: action,
                                           timeout: page.readTimeout ?? manifest.readTimeout, what: "results unreadable")
        else { return nil }
        if sawGate(json) { return nil }
        return decoder.titles(json) ?? failed("search", "answer not usable")
    }

    func more(in row: StreamRow) async -> [StreamTitle]? {
        guard let cursor = cursors[row.id], let page = manifest.pages[.more], let url = manifest.url(for: .more) else { return nil }
        cursors[row.id] = nil   // one request per reach; a successful read puts the next cursor back
        let action = driver.begin("more")
        // The request is the page's own, so it runs in that page (opened again when another is showing).
        if !(page.reuseIfOpen && isOpen(url)), !(await reuseCurrentPage(action, page)) {
            guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout) else { return nil }
        }
        guard await driver.waitFor(readyBody(page.ready), for: action, timeout: manifest.readyTimeout, what: "never ready"),
              let json = await driver.text(body(call: "reader.more(\(argument(rawCursor: cursor)))"), for: action,
                                           timeout: page.readTimeout ?? manifest.readTimeout, what: "more unreadable") else { return nil }
        guard let batch = decoder.more(json) else { return failed("more", "answer not usable") }
        cursors[row.id] = batch.cursor
        return batch.titles
    }

    /// Presses the profile in the service's own menu, nothing more. A profile that lands on the service's own form
    /// (a path the manifest lists) is `.needsPerson`: the form is left alone, never filled in or submitted.
    func switchProfile(to profileID: String) async -> ProfileSwitch {
        cursors = [:]
        let before = shownProfile
        let result = await pressProfile(profileID)
        unfinished.record(result, from: before)
        return result
    }

    private func pressProfile(_ profileID: String) async -> ProfileSwitch {
        guard let page = manifest.pages[.profile], let url = manifest.url(for: .profile) else { return .failed }
        let action = driver.begin("profile")
        if !(await reuseCurrentPage(action, page)) {
            guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout),
                  await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "never ready")
            else { return .failed }
        }
        guard await driver.yes(body(call: "reader.chooseProfile(\(argument(["profileID": profileID])))", fallback: "false"), for: action,
                               timeout: manifest.readTimeout, what: "profile not offered by the page") else { return .failed }
        let confirm = page.confirmTimeout ?? manifest.readyTimeout
        guard let settled = page.settled else {
            return ProfileSwitch(succeeded: await driver.waitFor(body(call: "reader.profileIsCurrent(\(argument(["profileID": profileID])))", fallback: "false"),
                                                                 for: action, timeout: confirm, what: "profile didn't switch"))
        }
        guard await driver.waitFor(body(call: "reader.\(settled)(\(argument(["profileID": profileID])))", fallback: "false"), for: action,
                                   timeout: confirm, what: "profile didn't switch") else { return .failed }
        if manifest.isProfileForm(driver.view.url) { return .needsPerson }
        return ProfileSwitch(succeeded: await driver.yes(body(call: "reader.profileIsCurrent(\(argument(["profileID": profileID])))", fallback: "false"),
                                                         for: action, timeout: manifest.readTimeout, what: "profile didn't switch"))
    }

    /// A switch that ended on the service's profile form leaves the page stuck there when the person backs out unfinished.
    /// Choose the profile that was active before, on the service's own "who's watching" page (one try; success or not, the memory is cleared).
    private func restoreUnfinishedSwitch() async {
        guard let page = manifest.pages[.restore], let url = manifest.url(for: .restore),
              let name = unfinished.profileToRestore(onForm: manifest.isProfileForm(driver.view.url)) else { return }
        unfinished.clear()
        let action = driver.begin("restore")
        guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout),
              await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "no profile tiles"),
              await driver.yes(body(call: "reader.restoreProfile(\(argument(["profileID": name])))", fallback: "false"), for: action,
                               timeout: manifest.readTimeout, what: "profile not on the picker"),
              await driver.waitFor(body(call: "reader.\(page.settled ?? "restored")(\(argument(["profileID": name])))", fallback: "false"), for: action,
                                   timeout: page.confirmTimeout ?? manifest.readyTimeout, what: "picker didn't close")
        else {
            log.error("\(self.service.id, privacy: .public): couldn't switch back after an unfinished profile form")
            return
        }
        noticeLine = "Switched back to \(name)"
    }

    /// True when the page already showing is a usable page of the service (reuseSitePage) that says it is ready within a moment.
    private func reuseCurrentPage(_ action: PageDriver.Action, _ page: PackageManifest.Page) async -> Bool {
        guard page.reuseSitePage, manifest.isReusableSitePage(driver.view.url),
              await driver.waitFor(readyBody(page.ready), for: action, timeout: .seconds(2), what: "page not ready", required: false) else { return false }
        return driver.isCurrent(action)
    }

    // MARK: Running the package

    /// The usual whole action: open the page the manifest names, wait for its ready function, call the action function.
    private func read(_ name: String, _ kind: PackageManifest.PageKind, _ fill: PackageManifest.Fill = .init(),
                      call function: String, args: [String: Any] = [:]) async -> String? {
        guard let page = manifest.pages[kind], let url = manifest.url(for: kind, fill) else { return nil }
        let action = driver.begin(name)
        if !(await reuseCurrentPage(action, page)) {
            guard driver.isCurrent(action), await driver.open(url, for: action, timeout: manifest.loadTimeout),
                  await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "never ready")
            else { return nil }
        }
        return await driver.text(body(call: "reader.\(function)(\(argument(args)))"), for: action,
                                 timeout: page.readTimeout ?? manifest.readTimeout, what: "unreadable")
    }

    /// A function body for callAsyncJavaScript: the package's script, then the call; "" (or `fallback`) on any error.
    private func body(call: String, fallback: String = #""""#) -> String {
        "try { \(source)\nconst answer = await \(call); return answer; } catch (e) { return \(fallback); }"
    }

    private func readyBody(_ function: String) -> String {
        "try { \(source)\nreturn typeof reader[\(StreamJSON.jsString(function))] === \"function\" && (await reader[\(StreamJSON.jsString(function))]()) === true; } catch (e) { return false; }"
    }

    private func argument(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The call's argument for a cursor the script itself returned (already JSON text, size-bounded by the decoder).
    private func argument(rawCursor: String) -> String { "{\"cursor\":\(rawCursor)}" }

    /// True when the service's page is already at `url` (same place, no query).
    private func isOpen(_ url: URL) -> Bool {
        guard let current = driver.view.url, manifest.hostAllowed(current.host), current.query == nil,
              current.scheme == url.scheme, current.host?.lowercased() == url.host?.lowercased() else { return false }
        func path(_ u: URL) -> String { u.path.isEmpty ? "/" : u.path }
        return path(current) == path(url)
    }

    private func failed<T>(_ action: String, _ what: String) -> T? {
        log.error("\(self.service.id, privacy: .public) \(action, privacy: .public): \(what, privacy: .public)")
        return nil
    }
}
