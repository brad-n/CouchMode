// Owns: first-run setup as pure data: the order of its steps, which apps and
// consoles it offers on this Mac (and why one is off), the default choices
// given what is installed and which games folders have games, the sign-in
// status shown per service, and the config it writes (a sensible order:
// streaming services, then native apps such as Plex, then games, then
// Settings). Does not read the disk or draw anything; the app passes in what
// it found and wires the screens. Nothing here writes a file: the caller
// saves the result of `result()` only when the person reaches Done.

import Foundation

public enum SetupStep: String, CaseIterable, Sendable { case welcome, apps, games, signIn, done }

/// What the setup shows beside a service the person opened to sign in to.
public enum SignInStatus: Equatable, Sendable {
    case notVisited, opened, signedIn, notYet

    /// The row's words; empty before the service has been opened.
    public var label: String {
        switch self {
        case .notVisited: return ""
        case .opened: return "Opened"
        case .signedIn: return "Signed in"
        case .notYet: return "Not yet"
        }
    }

    /// After the person comes back: `signedIn` is the page's own answer, or nil when the package can't tell.
    public static func after(signedIn: Bool?) -> SignInStatus {
        switch signedIn {
        case .some(true): return .signedIn
        case .some(false): return .notYet
        case .none: return .opened
        }
    }
}

/// A streaming service or native app the setup offers.
public struct SetupApp: Equatable, Sendable {
    public let app: CatalogApp
    /// Why it can't be turned on here (a requirement that is not met); nil when it can.
    public let unmet: String?
    /// A native app that is not installed (it opens its website instead): turned off by default, can still be turned on.
    public let notInstalled: Bool

    public var canToggle: Bool { unmet == nil }
    /// "" when nothing needs saying; else why it is off or what it will do.
    public var note: String {
        if let unmet { return "needs " + RequirementText.name(unmet) }
        if notInstalled { return "not installed, opens its website" }
        return ""
    }
}

/// A console the setup offers (its emulator is installed) with its games folder.
public struct SetupConsole: Equatable, Sendable {
    public let app: CatalogApp
    /// The folder as the config would hold it (may start with ~).
    public let folder: String
    /// Games found there; nil when the folder does not exist.
    public let gameCount: Int?

    public var found: Bool { gameCount != nil }
    public var hasGames: Bool { (gameCount ?? 0) > 0 }
    /// "12 games", "Folder is empty" or "Folder not found".
    public var status: String {
        guard let n = gameCount else { return "Folder not found" }
        return n == 0 ? "Folder is empty" : GameLibrary.countLabel(n)
    }
}

public struct FirstRunSetup: Equatable, Sendable {
    public let apps: [SetupApp]
    public let consoles: [SetupConsole]
    public private(set) var step: SetupStep = .welcome
    public private(set) var chosen: Set<String>
    public private(set) var signIn: [String: SignInStatus] = [:]
    /// The config already on this Mac (a second run); nil on the first.
    public let existing: AppConfig?
    private let catalog: AppCatalog
    private let migrated: [String: [String: ConfigValue]]

    /// - `requirementMet`: whether a catalog requirement holds on this Mac.
    /// - `nativeInstalled`: whether a native app (Plex HTPC) is installed.
    /// - `gameCount`: the games in a console's folder (text as the config holds it); nil when it does not exist.
    /// - `migrated`: values older versions kept elsewhere, carried into a new entry.
    public init(catalog: AppCatalog, existing: AppConfig?, requirementMet: (AppRequirement) -> Bool,
                nativeInstalled: (CatalogApp) -> Bool, gameCount: (CatalogApp, String) -> Int?,
                migrated: [String: [String: ConfigValue]] = [:]) {
        self.catalog = catalog
        self.existing = existing
        self.migrated = migrated
        apps = catalog.apps.filter { $0.kind == .stream || $0.kind == .native }.map { app in
            SetupApp(app: app, unmet: app.requires.first { !requirementMet($0) }?.label,
                     notInstalled: app.kind == .native && !nativeInstalled(app))
        }
        consoles = catalog.apps.compactMap { app in
            guard app.kind == .console, let spec = app.console, app.requires.allSatisfy(requirementMet) else { return nil }
            let folder = existing?.setting(AppConfig.gamesFolderKey, for: app.id)?.string.flatMap { $0.isEmpty ? nil : $0 } ?? spec.defaultFolder
            return SetupConsole(app: app, folder: folder, gameCount: gameCount(app, folder))
        }
        if let existing {
            // A second run shows the current choices.
            let added = Set(existing.apps.map(\.id))
            chosen = Set((apps.filter { $0.canToggle }.map(\.app.id) + consoles.map(\.app.id)).filter(added.contains))
        } else {
            chosen = Self.defaultChoices(apps: apps, consoles: consoles)
        }
    }

    /// Streaming services on, a native app on when installed, a console on only when its folder has games.
    /// Anything with an unmet requirement is off.
    public static func defaultChoices(apps: [SetupApp], consoles: [SetupConsole]) -> Set<String> {
        var on = Set<String>()
        for a in apps where a.canToggle && a.app.defaultEnabled && (a.app.kind == .stream || !a.notInstalled) { on.insert(a.app.id) }
        for c in consoles where c.hasGames { on.insert(c.app.id) }
        return on
    }

    // MARK: Choosing

    public func isOn(_ id: String) -> Bool { chosen.contains(id) }

    /// Flips an offered app or console; false for an id that is not offered or cannot be turned on.
    @discardableResult
    public mutating func toggle(_ id: String) -> Bool {
        let offered = apps.contains { $0.app.id == id && $0.canToggle } || consoles.contains { $0.app.id == id }
        guard offered else { return false }
        if chosen.remove(id) == nil { chosen.insert(id) }
        return true
    }

    /// The chosen streaming services, in catalog order: the ones that can be signed in to.
    public var chosenStreams: [SetupApp] { apps.filter { $0.app.kind == .stream && chosen.contains($0.app.id) } }

    // MARK: Steps

    /// The steps this run goes through: games only when a console is offered, sign-in only when a service is chosen.
    public var steps: [SetupStep] {
        SetupStep.allCases.filter {
            switch $0 {
            case .games: return !consoles.isEmpty
            case .signIn: return !chosenStreams.isEmpty
            default: return true
            }
        }
    }

    /// Moves to the next step; false at Done (the caller finishes).
    @discardableResult
    public mutating func advance() -> Bool {
        guard let next = steps.first(where: { Self.position($0) > Self.position(step) }) else { return false }
        step = next
        return true
    }

    /// Moves to the previous step; false at Welcome (the caller leaves).
    @discardableResult
    public mutating func back() -> Bool {
        guard let previous = steps.last(where: { Self.position($0) < Self.position(step) }) else { return false }
        step = previous
        return true
    }

    /// Where a step sits in the full order (a step left out of `steps` still has a place, so moving never gets stuck).
    private static func position(_ s: SetupStep) -> Int { SetupStep.allCases.firstIndex(of: s) ?? 0 }

    // MARK: Signing in

    public func status(of id: String) -> SignInStatus { signIn[id] ?? .notVisited }

    public mutating func recordSignIn(_ id: String, signedIn: Bool?) {
        guard chosenStreams.contains(where: { $0.app.id == id }) else { return }
        signIn[id] = SignInStatus.after(signedIn: signedIn)
    }

    // MARK: The config written at Done

    /// The config for the choices: chosen apps (kept entries keep their settings), Settings always, and what the
    /// setup did not offer (an unknown id, a console whose emulator is missing) left as it was. Order: streaming
    /// services, native apps, games, Settings, then unknown ids; inside a group the existing order is kept and new
    /// apps follow in catalog order.
    public func result() -> AppConfig {
        let old = existing?.apps ?? []
        var oldIndex: [String: Int] = [:]
        for (i, e) in old.enumerated() where oldIndex[e.id] == nil { oldIndex[e.id] = i }
        let offered = Set(apps.map(\.app.id) + consoles.map(\.app.id))
        var keep = Set<String>()
        for id in chosen { keep.insert(id) }
        for catalogApp in catalog.apps where catalogApp.kind == .system { keep.insert(catalogApp.id) }
        // What the setup never offered stays as it was.
        for e in old where !offered.contains(e.id) && catalog.app(id: e.id)?.kind != .system { keep.insert(e.id) }

        var rows: [(rank: Int, order: Int, entry: AppEntry)] = []
        var seen = Set<String>()
        for e in old where keep.contains(e.id) && seen.insert(e.id).inserted {
            rows.append((Self.rank(catalog.app(id: e.id)), oldIndex[e.id] ?? 0, e))
        }
        for (i, catalogApp) in catalog.apps.enumerated() where keep.contains(catalogApp.id) && seen.insert(catalogApp.id).inserted {
            rows.append((Self.rank(catalogApp), 100_000 + i, AppConfig.entry(for: catalogApp, migrated: migrated[catalogApp.id] ?? [:])))
        }
        rows.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }
        return AppConfig(apps: rows.map(\.entry), packageRef: existing?.packageRef)
    }

    private static func rank(_ app: CatalogApp?) -> Int {
        switch app?.kind {
        case .stream: return 0
        case .native: return 1
        case .console: return 2
        case .system: return 3
        case nil: return 4
        }
    }
}
