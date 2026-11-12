// Owns: the generic reader that runs any service's script package as that
// service's StreamSource. For each user action it does what the manifest says:
// open the action's page (one action at a time through PageDriver: latest wins,
// bounded, logged), wait for the package's ready function, call the package's
// action function inside the service's own page, and decode the JSON it
// returns into the shared vocabulary with PackageDecoder, which enforces the
// id, address and size rules. The script only returns data; it never plays
// anything and never runs outside the service's page. A row's paging cursor is
// opaque text the script returned, kept in memory only and handed back to it.
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

    func home() async -> StreamHome? {
        cursors = [:]
        guard let json = await read("home", .home, call: "home") else { return nil }
        guard let result = decoder.home(json, serviceID: service.id) else { return failed("home", "answer not usable") }
        cursors = result.cursors
        return result.home
    }

    func details(for title: StreamTitle) async -> StreamTitleDetails? {
        guard title.page != nil, let json = await read("details", .details, .init(titlePage: title.page), call: "details",
                                                        args: ["title": PackageDecoder.argument(for: title)]) else { return nil }
        return decoder.details(json) ?? failed("details", "answer not usable")
    }

    func episodes(in season: StreamSeason, of title: StreamTitle) async -> [StreamEpisode]? {
        guard let json = await read("episodes", .season, .init(seasonID: season.id), call: "season") else { return nil }
        return decoder.episodes(json) ?? failed("episodes", "answer not usable")
    }

    func search(_ query: String) async -> [StreamTitle]? {
        guard let page = manifest.pages[.search] else { return nil }
        guard let url = manifest.url(for: .search, .init(query: query)) else { return [] }
        let action = driver.begin("search")
        guard await driver.open(url, for: action, timeout: manifest.loadTimeout) else { return nil }
        // A search with no matches is a valid answer ([]), not a failure, when the manifest says readiness is optional.
        guard await driver.waitFor(readyBody(page.ready), for: action, timeout: page.readyTimeout ?? manifest.readyTimeout, what: "results",
                                   required: page.readyRequired) else { return driver.isCurrent(action) && !page.readyRequired ? [] : nil }
        guard let json = await driver.text(body(call: "reader.search()"), for: action, timeout: manifest.readTimeout, what: "results unreadable")
        else { return nil }
        return decoder.titles(json) ?? failed("search", "answer not usable")
    }

    func more(in row: StreamRow) async -> [StreamTitle]? {
        guard let cursor = cursors[row.id], let page = manifest.pages[.more], let url = manifest.url(for: .more) else { return nil }
        cursors[row.id] = nil   // one request per reach; a successful read puts the next cursor back
        let action = driver.begin("more")
        // The request is the page's own, so it runs in that page (opened again when another is showing).
        if !(page.reuseIfOpen && isOpen(url)) {
            guard await driver.open(url, for: action, timeout: manifest.loadTimeout) else { return nil }
        }
        guard await driver.waitFor(readyBody(page.ready), for: action, timeout: manifest.readyTimeout, what: "never ready"),
              let json = await driver.text(body(call: "reader.more(\(argument(rawCursor: cursor)))"), for: action,
                                           timeout: manifest.readTimeout, what: "more unreadable") else { return nil }
        guard let batch = decoder.more(json) else { return failed("more", "answer not usable") }
        cursors[row.id] = batch.cursor
        return batch.titles
    }

    func switchProfile(to profileID: String) async -> ProfileSwitch {
        cursors = [:]
        guard let page = manifest.pages[.profile], let url = manifest.url(for: .profile) else { return .failed }
        let action = driver.begin("profile")
        guard await driver.open(url, for: action, timeout: manifest.loadTimeout),
              await driver.waitFor(readyBody(page.ready), for: action, timeout: manifest.readyTimeout, what: "never ready"),
              await driver.yes(body(call: "reader.chooseProfile(\(argument(["profileID": profileID])))", fallback: "false"), for: action,
                               timeout: manifest.readTimeout, what: "profile not offered by the page")
        else { return .failed }
        return ProfileSwitch(succeeded: await driver.waitFor(body(call: "reader.profileIsCurrent(\(argument(["profileID": profileID])))", fallback: "false"),
                                                             for: action, timeout: page.confirmTimeout ?? manifest.readyTimeout, what: "profile didn't switch"))
    }

    // MARK: Running the package

    /// The usual whole action: open the page the manifest names, wait for its ready function, call the action function.
    private func read(_ name: String, _ kind: PackageManifest.PageKind, _ fill: PackageManifest.Fill = .init(),
                      call function: String, args: [String: Any] = [:]) async -> String? {
        guard let page = manifest.pages[kind], let url = manifest.url(for: kind, fill) else { return nil }
        let timeouts = PageDriver.Timeouts(load: manifest.loadTimeout, ready: page.readyTimeout ?? manifest.readyTimeout, read: manifest.readTimeout)
        return await driver.read(name, open: url, ready: readyBody(page.ready),
                                 script: body(call: "reader.\(function)(\(argument(args)))"), timeouts: timeouts)
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
