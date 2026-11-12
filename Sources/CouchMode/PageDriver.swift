// Owns: driving one streaming service's own page for its reader (the proxy
// behind the shell's stream screens), one action at a time: open an address,
// wait for something to show, read a script's answer. A newer action
// supersedes an older one still waiting (the latest thing the player did
// wins), every step is bounded, and a failed step is logged once with its
// service, action and step (an action that was simply superseded isn't a
// failure). Every service's reader uses this, so a fix to how pages are
// driven reaches them all; what to open and read is each reader's business.

import WebKit
import os
import CouchModeCore

@MainActor
final class PageDriver {
    /// One proxy action; its steps give up quietly once a newer action began.
    struct Action {
        fileprivate let id: Int
        let name: String
    }

    struct Timeouts {
        var load: Duration = .seconds(20)
        var ready: Duration = .seconds(10)
        var read: Duration = .seconds(8)
        static let standard = Timeouts()
    }

    let service: Service
    private let player: WebPlayer
    private var generation = 0
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "stream")

    init(service: Service, player: WebPlayer) {
        self.service = service
        self.player = player
    }

    /// The service's own page (the same view its player uses).
    var view: WKWebView { player.view(for: service) }

    func begin(_ name: String) -> Action {
        generation += 1
        return Action(id: generation, name: name)
    }

    func isCurrent(_ action: Action) -> Bool { action.id == generation && !Task.isCancelled }

    /// Opens `url`; false when it didn't load in time or a newer action began.
    func open(_ url: URL, for action: Action, timeout: Duration = Timeouts.standard.load) async -> Bool {
        let loaded = await WebPage.open(url, in: view, timeout: timeout)
        return succeeded(loaded, action, "page didn't load")
    }

    /// Waits for `script` (a function body returning a boolean) to say yes.
    /// `required: false` for something that may rightly never show (no search results).
    func waitFor(_ script: String, for action: Action, timeout: Duration = Timeouts.standard.ready,
                 what: String, required: Bool = true) async -> Bool {
        let shown = await WebPage.waitFor(script, in: view, timeout: timeout)
        return required ? succeeded(shown, action, what) : shown && isCurrent(action)
    }

    /// A script's answer as non-empty text (JSON for a parser).
    func text(_ script: String, for action: Action, timeout: Duration = Timeouts.standard.read, what: String) async -> String? {
        let answer = await WebPage.text(script, in: view, timeout: timeout)
        guard succeeded(answer.map { !$0.isEmpty } ?? false, action, what) else { return nil }
        return answer
    }

    /// A script's answer as a yes or no (a step that did something on the page).
    func yes(_ script: String, for action: Action, timeout: Duration = Timeouts.standard.read, what: String) async -> Bool {
        let answer = await WebPage.run(script, in: view, timeout: timeout) as? Bool
        return succeeded(answer == true, action, what)
    }

    /// The usual whole proxy action: open `url` (nil keeps the page as it
    /// is), wait until `ready` says so (nil: don't wait), then read `script`.
    func read(_ name: String, open url: URL?, ready: String?, script: String,
              timeouts: Timeouts = .standard) async -> String? {
        let action = begin(name)
        if let url { guard await open(url, for: action, timeout: timeouts.load) else { return nil } }
        if let ready { guard await waitFor(ready, for: action, timeout: timeouts.ready, what: "never ready") else { return nil } }
        return await text(script, for: action, timeout: timeouts.read, what: "unreadable")
    }

    /// True when the step worked and the action is still the latest; logs a
    /// real failure (not a superseded action) once.
    private func succeeded(_ worked: Bool, _ action: Action, _ what: String) -> Bool {
        guard isCurrent(action) else { return false }
        if !worked { log.error("\(self.service.id, privacy: .public) \(action.name, privacy: .public): \(what, privacy: .public)") }
        return worked
    }
}
