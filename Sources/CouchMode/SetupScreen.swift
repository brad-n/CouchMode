// Owns: first-run setup on screen: the Welcome and Done launch cards and the
// choose-apps, games and sign-in lists (the shared header, SettingsView's
// focus and scrolling), driven by the remote or a controller only. It holds
// FirstRunSetup (Core: the steps, defaults and the config it writes) and
// turns presses into what the coordinator must do: open a service's site to
// sign in, save the config at Done, or leave. Reads the disk only to count
// games, off the main thread. Writes nothing itself.

import AppKit
import SwiftUI
import CouchModeCore

@MainActor
final class SetupScreen: ObservableObject {
    enum Action: Equatable { case none, signIn(String), finish, leave }

    @Published private(set) var session: FirstRunSetup
    let model: SettingsModel
    /// No config existed: Back at Welcome and Home do nothing (there is nowhere to go yet).
    let isFirstRun: Bool
    /// The service whose site is up for the person to sign in to (the coordinator shows its page).
    private(set) var signingIn: Service?

    init(session: FirstRunSetup, isFirstRun: Bool) {
        self.session = session
        self.isFirstRun = isFirstRun
        model = SettingsModel(title: "Choose your apps", icon: "square.grid.2x2.fill", rows: [])
        refresh()
    }

    // MARK: What is on this Mac

    /// Games per folder text, counted off the main thread (a folder that does not exist is absent).
    nonisolated static func scanFolders(_ folders: [String: [String]]) async -> [String: Int] {
        await Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var counts: [String: Int] = [:]
            for (folder, extensions) in folders {
                var isDirectory: ObjCBool = false
                let path = PathText.expandingTilde(folder, home: home)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).prefix(20_000)
                counts[folder] = names.filter { !$0.hasPrefix(".") && extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.count
            }
            return counts
        }.value
    }

    // MARK: Input

    func handle(_ intent: ShellIntent) -> Action {
        switch session.step {
        case .welcome, .done:
            switch intent {
            case .select:
                if session.step == .done { return .finish }
                session.advance(); refresh()
            case .back: return goBack()
            case .home: return isFirstRun ? .none : .leave
            case .move, .info: break
            }
        case .apps, .games, .signIn:
            switch intent {
            case .move(let d): model.move(d); updateFooter()
            case .back: return goBack()
            case .home: return isFirstRun ? .none : .leave
            case .info: break
            case .select:
                guard let id = model.selected?.id else { break }
                if id == "continue" { session.advance(); refresh() }
                else if id.hasPrefix("signin:") { return .signIn(String(id.dropFirst(7))) }
                else if let colon = id.firstIndex(of: ":") {
                    session.toggle(String(id[id.index(after: colon)...]))
                    refreshRows(keepingFocus: true)
                }
            }
        }
        return .none
    }

    private func goBack() -> Action {
        if session.back() { refresh(); return .none }
        return isFirstRun ? .none : .leave
    }

    // MARK: Signing in

    func beginSignIn(_ service: Service) {
        signingIn = service
        session.recordSignIn(service.id, signedIn: nil)
    }

    /// Back from the service's site. `signedIn` is the page's own answer, nil until/unless the package can tell.
    func endSignIn(signedIn: Bool?, for id: String) {
        if signingIn?.id == id { signingIn = nil }
        session.recordSignIn(id, signedIn: signedIn)
        refreshRows(keepingFocus: true)
    }

    func leaveSignIn() { signingIn = nil; refreshRows(keepingFocus: true) }

    // MARK: Rows

    private func refresh() {
        refreshRows(keepingFocus: false)
    }

    private func refreshRows(keepingFocus: Bool) {
        var rows: [SettingRow] = []
        switch session.step {
        case .apps:
            model.title = "Choose your apps"
            rows = session.apps.map { a in
                let on = session.isOn(a.app.id)
                let words = [on ? "On" : "Off", a.note].filter { !$0.isEmpty }.joined(separator: ", ")
                return SettingRow(id: "app:" + a.app.id, title: a.app.name, value: words,
                                  symbol: a.canToggle ? (on ? "checkmark.circle.fill" : "circle") : "minus.circle",
                                  heroSymbol: Self.symbol(a.app))
            }
        case .games:
            model.title = "Games"
            rows = session.consoles.map { c in
                let on = session.isOn(c.app.id)
                return SettingRow(id: "game:" + c.app.id, title: c.app.name, value: (on ? "On, " : "Off, ") + c.status,
                                  symbol: on ? "checkmark.circle.fill" : "circle", heroSymbol: Self.symbol(c.app))
            }
        case .signIn:
            model.title = "Sign in"
            rows = session.chosenStreams.map { a in
                SettingRow(id: "signin:" + a.app.id, title: "Sign in to " + a.app.name, value: session.status(of: a.app.id).label,
                           symbol: session.status(of: a.app.id) == .signedIn ? "checkmark.circle.fill" : "person.crop.circle.fill",
                           isAction: true, heroSymbol: Self.symbol(a.app))
            }
        case .welcome, .done: break
        }
        if session.step == .apps || session.step == .games || session.step == .signIn {
            rows.append(SettingRow(id: "continue", title: "Continue", value: session.step == .signIn ? "Skip any you like" : "",
                                   symbol: "arrow.right.circle.fill", isAction: true))
        }
        if keepingFocus { model.update(rows: rows) } else { model.reset(rows: rows) }
        updateFooter()
    }

    private func updateFooter() {
        switch session.step {
        case .apps:
            let id = model.selected?.id.dropFirst(4).description ?? ""
            if let a = session.apps.first(where: { $0.app.id == id }), !a.canToggle { model.footer = "\(a.app.name) can't be turned on here: \(a.note)." }
            else { model.footer = "Select an app to turn it on or off. You can change this later in Settings." }
        case .games:
            let id = model.selected?.id.dropFirst(5).description ?? ""
            if let c = session.consoles.first(where: { $0.app.id == id }) { model.footer = "Games folder: \(c.folder)" + (c.found ? "" : " (not found yet)") }
            else { model.footer = "Only consoles with an emulator on this Mac are listed." }
        case .signIn:
            model.footer = "Opens the service's own site. Sign in with a keyboard or mouse, once. Press Back to return here."
        case .welcome, .done: model.footer = nil
        }
    }

    private static func symbol(_ app: CatalogApp) -> String {
        switch app.kind {
        case .stream: return "play.tv.fill"
        case .native: return "app.fill"
        case .console: return "gamecontroller.fill"
        case .system: return "gearshape.fill"
        }
    }

    // MARK: Done card

    var doneDetail: String {
        let names = session.result().apps.compactMap { e in session.apps.first { $0.app.id == e.id }?.app.name ?? session.consoles.first { $0.app.id == e.id }?.app.name }
        return names.isEmpty ? "Settings is always on Home." : names.joined(separator: ", ")
    }

    // MARK: State

    func debugState() -> [String: String] {
        var state = ["screen": "setup", "step": session.step.rawValue, "selected": model.selected?.id ?? "", "rows": "\(model.rows.count)",
                     "chosen": session.chosen.sorted().joined(separator: ","), "first": "\(isFirstRun)",
                     "signingIn": signingIn?.id ?? "", "footer": model.footer ?? "",
                     "doneNote": session.doneNote ?? ""]
        state["signIn"] = session.chosenStreams.map { "\($0.app.id)=\(session.status(of: $0.app.id).label)" }.joined(separator: ",")
        state["list"] = model.rows.map { "\($0.id)=\($0.value)" }.joined(separator: "|")
        state["order"] = session.result().apps.map(\.id).joined(separator: ",")
        return state
    }
}

struct SetupView: View {
    @ObservedObject var screen: SetupScreen

    var body: some View {
        switch screen.session.step {
        case .welcome:
            InterstitialView(title: "CouchMode turns this Mac into a TV box", subtitle: "A few quick choices, then you're watching.",
                             colors: [DS.accent], icon: NSApp.applicationIconImage, header: .settings, showsBar: false,
                             buttons: ["Continue"], focusedButton: 0)
        case .done:
            InterstitialView(title: "You're all set", subtitle: "These go on Home", colors: [DS.accent], icon: NSApp.applicationIconImage,
                             header: .settings, showsBar: false, detail: screen.doneDetail, note: screen.session.doneNote,
                             buttons: ["Go to Home"], focusedButton: 0)
        case .apps, .games, .signIn:
            SettingsView(model: screen.model)
        }
    }
}
