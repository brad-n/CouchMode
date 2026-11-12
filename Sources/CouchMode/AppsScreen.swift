// Owns: Settings > Apps: the list of added apps (select one to move it up or
// down, or remove it), the catalog apps that can still be added with their
// requirement status, and the app-package updates (versions in use, and a
// check against GitHub). It edits the config through AppConfigStore, which
// saves it; the coordinator is told so Home refreshes at once. It draws with
// the same SettingsView and ListWindow scrolling as the Settings list.
// Removing a stream app never touches its website data or sign-in.

import Foundation
import CouchModeCore

@MainActor
final class AppsScreen {
    enum Pane: Equatable { case list, actions(String), add, updates }
    enum Exit { case settings, home }

    let model: SettingsModel
    private(set) var pane: Pane = .list
    private var confirm = ConfirmGate()
    private var checking = false
    /// Last result of "Check for app updates" (this run).
    private var updateLine: String?

    private let store: AppConfigStore
    /// The config changed: refresh Home.
    private let changed: () -> Void
    /// Run the check against GitHub; the coordinator owns the network call and what follows it.
    private let runCheck: (@escaping (String) -> Void) -> Void
    /// A service was added: give it its reader if it has one.
    private let added: (String) -> Void

    init(store: AppConfigStore, changed: @escaping () -> Void, added: @escaping (String) -> Void,
         runCheck: @escaping (@escaping (String) -> Void) -> Void) {
        self.store = store; self.changed = changed; self.added = added; self.runCheck = runCheck
        model = SettingsModel(title: "Apps", icon: "square.grid.2x2.fill", rows: [])
        showList()
    }

    // MARK: Input

    func handle(_ intent: ShellIntent) -> Exit? {
        switch intent {
        case .move(let d): model.move(d)
        case .home: return .home
        case .info: break
        case .back:
            switch pane {
            case .list: return .settings
            case .actions(let id): showList(select: "app:\(id)")
            case .add: showList(select: "add")
            case .updates: showList(select: "updates")
            }
        case .select:
            guard let row = model.selected else { break }
            select(row.id)
        }
        return nil
    }

    private func select(_ rowID: String) {
        switch pane {
        case .list:
            if rowID.hasPrefix("app:") { showActions(String(rowID.dropFirst(4))) }
            else if rowID == "add" { showAdd() }
            else if rowID == "updates" { showUpdates() }
        case .actions(let id):
            switch rowID {
            case "up": move(id, by: -1)
            case "down": move(id, by: 1)
            case "remove": remove(id)
            default: break
            }
        case .add:
            guard rowID.hasPrefix("add:"), let app = store.catalog.app(id: String(rowID.dropFirst(4))) else { return }
            addApp(app)
        case .updates:
            if rowID == "check" { check() }
        }
    }

    // MARK: Panes

    private var listedIDs: [String] {
        var seen = Set<String>()
        return store.config.apps.map(\.id).filter { store.catalog.app(id: $0) != nil && seen.insert($0).inserted }
    }

    private func showList(select id: String? = nil) {
        pane = .list
        model.footer = "Select an app to move or remove it."
        var rows: [SettingRow] = listedIDs.compactMap { id in
            guard let app = store.catalog.app(id: id) else { return nil }
            let unmet = app.requires.first { !store.requirementMet($0) }
            return SettingRow(id: "app:\(id)", title: app.name, value: unmet.map { "needs " + RequirementText.name($0.label) } ?? "",
                              symbol: Self.symbol(app))
        }
        rows.append(SettingRow(id: "add", title: "Add an app\u{2026}", value: "\(addable().count) available", symbol: "plus.circle.fill"))
        rows.append(SettingRow(id: "updates", title: "Check for app updates", value: updateLine ?? "", symbol: "arrow.down.circle.fill"))
        model.update(rows: rows)
        if let id { model.select(id: id) }
    }

    private func showActions(_ id: String) {
        guard let app = store.catalog.app(id: id) else { return showList() }
        pane = .actions(id)
        var rows = [SettingRow(id: "up", title: "Move up", value: "", symbol: "arrow.up.circle.fill", isAction: true),
                    SettingRow(id: "down", title: "Move down", value: "", symbol: "arrow.down.circle.fill", isAction: true)]
        if app.kind != .system {
            rows.append(SettingRow(id: "remove", title: "Remove", value: confirm.pending(now: Date()) == "remove:\(id)" ? "Press again to remove" : "",
                                   symbol: "minus.circle.fill", isAction: true))
        }
        model.update(rows: rows)
        model.footer = "\(app.name): \(positionText(id))."
    }

    private func showAdd() {
        pane = .add
        let list = addable()
        var rows = list.map { SettingRow(id: "add:\($0.app.id)", title: $0.app.name, value: $0.status, symbol: Self.symbol($0.app), isAction: true) }
        if rows.isEmpty { rows = [SettingRow(id: "none", title: "Every app is already added", value: "", symbol: "checkmark.circle.fill")] }
        model.update(rows: rows)
        model.footer = "Select an app to add it to the end of Home."
    }

    private func showUpdates() {
        pane = .updates
        refreshUpdates()
        model.footer = updateLine ?? "Fetches app packages from GitHub when a newer one is published."
    }

    private func refreshUpdates() {
        var rows = [SettingRow(id: "check", title: "Check now", value: checking ? "Checking\u{2026}" : "", symbol: "arrow.down.circle.fill", isAction: true)]
        for p in LayeredPackageStore().installed() {
            rows.append(SettingRow(id: "pkg:\(p.id)", title: store.catalog.app(id: p.id)?.name ?? p.id, value: "\(p.version) (\(p.source))",
                                   symbol: "shippingbox.fill"))
        }
        model.update(rows: rows)
    }

    // MARK: Actions

    private func addable() -> [AppConfig.Addable] {
        store.config.addable(catalog: store.catalog) { store.requirementMet($0) }
    }

    private func positionText(_ id: String) -> String {
        guard let i = listedIDs.firstIndex(of: id) else { return "" }
        return "position \(i + 1) of \(listedIDs.count)"
    }

    private func move(_ id: String, by step: Int) {
        let known = store.catalog
        guard store.edit({ c, _ in c.move(id: id, by: step, listed: { known.app(id: $0) != nil }) }) != nil else {
            model.footer = step < 0 ? "Already first." : "Already last."
            return
        }
        changed()
        model.footer = "\(known.app(id: id)?.name ?? id): \(positionText(id))."
    }

    private func remove(_ id: String) {
        guard confirm.press("remove:\(id)", now: Date()) else {
            showActions(id)
            model.select(id: "remove")
            return
        }
        let position = listedIDs.firstIndex(of: id) ?? 0
        guard store.edit({ c, cat in c.remove(id: id, catalog: cat) ? true : nil }) != nil else { return }
        changed()
        let name = store.catalog.app(id: id)?.name ?? id
        // Focus stays where the app was (the next one slides up into its place).
        let ids = listedIDs
        showList(select: ids.isEmpty ? nil : "app:\(ids[min(position, ids.count - 1)])")
        model.footer = "Removed \(name). Its sign-in stays; add it back any time."
    }

    private func addApp(_ app: CatalogApp) {
        guard store.edit({ c, _ in c.add(app) ? true : nil }) != nil else { return }
        changed()
        added(app.id)
        let note = app.requires.first { !store.requirementMet($0) }.map { " It shows once \(RequirementText.name($0.label)) is installed." } ?? ""
        showAdd()
        model.footer = "Added \(app.name).\(note)"
    }

    private func check() {
        guard !checking else { return }
        checking = true
        refreshUpdates()
        model.footer = "Checking GitHub\u{2026}"
        runCheck { [weak self] line in
            guard let self else { return }
            self.checking = false
            self.updateLine = line
            if self.pane == .updates { self.refreshUpdates(); self.model.footer = line }
        }
    }

    // MARK: State

    func debugState() -> [String: String] {
        let paneName: String
        switch pane {
        case .list: paneName = "list"
        case .actions(let id): paneName = "actions:\(id)"
        case .add: paneName = "add"
        case .updates: paneName = "updates"
        }
        return ["screen": "apps", "pane": paneName, "selected": model.selected?.id ?? "", "rows": "\(model.rows.count)",
                "footer": model.footer ?? "", "order": store.config.apps.map(\.id).joined(separator: ","),
                "window": "\(model.window.first)+\(model.window.capacity)/\(model.window.count)"]
    }

    private static func symbol(_ app: CatalogApp) -> String {
        switch app.kind {
        case .stream: return "play.tv.fill"
        case .native: return "app.fill"
        case .console: return "gamecontroller.fill"
        case .system: return "gearshape.fill"
        }
    }
}
