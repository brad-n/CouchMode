// Owns: this Mac's app list at run time: loads the bundled catalog and the
// machine's config.json (Application Support/<bundle id>, beside the icon
// cache), migrates older per-app preferences on the first run, hides apps
// whose requirements are unmet, and saves per-app setting changes. Everything
// that needs "which apps, in what order, with what settings" asks here.
// Global UI preferences (sounds, screensaver) stay in Prefs. Demo mode never
// touches the disk.

import AppKit
import Foundation
import os
import CouchModeCore

@MainActor
final class AppConfigStore {
    static let shared = AppConfigStore()

    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "config")

    let catalog: AppCatalog
    private(set) var config: AppConfig
    /// The apps Home shows, in config order, with unmet and unknown ones left out.
    private(set) var home: HomeApps
    private let file: ConfigFile?
    /// There was no config.json at launch: first-run setup shows before Home, and writes the file at Done.
    private(set) var needsSetup = false

    /// Streaming sites and native apps on Home, as services (user agents resolved).
    var services: [Service] { ServiceCatalog.make(from: home.apps.map(\.app), safariUserAgent: AppServices.safariUserAgent) }
    /// Consoles on Home, in config order.
    var consoles: [Console] { ConsoleCatalog.make(from: home.apps.map(\.app)) }

    private init() {
        catalog = Self.loadCatalog()
        let dir = Self.configDirectory()
        file = DemoMode.isOn ? nil : dir.map(ConfigFile.init(directory:))
        let catalog = catalog
        let defaults = { AppConfig.defaults(catalog: catalog, migrated: DemoMode.isOn ? [:] : Self.migratedPrefs()) }
        if let file, !FileManager.default.fileExists(atPath: file.url.path) {
            // First run: the defaults serve this run in memory; the file is written when setup reaches Done.
            config = defaults()
            needsSetup = true
            Self.log.info("no config yet: first-run setup")
        } else if let file {
            let outcome = file.load(defaults: defaults, now: Date())
            config = outcome.config
            Self.log(outcome, apps: outcome.config.apps.count)
        } else {
            config = defaults()
        }
        home = AppConfigStore.resolve(config, catalog: catalog)
    }

    // MARK: Settings

    func setting(_ key: String, for id: String) -> ConfigValue? { config.setting(key, for: id) }

    /// Saves a per-app setting (atomically). A failed write is logged; the value still applies for this run.
    func set(_ key: String, _ value: ConfigValue?, for id: String) {
        guard config.set(key, value, for: id) else {
            Self.log.error("setting \(key, privacy: .public) not saved: app \(id, privacy: .public) is not in the config")
            return
        }
        home = Self.resolve(config, catalog: catalog, quiet: true)
        do { try file?.save(config) }
        catch { Self.log.error("config not saved: \(error.localizedDescription, privacy: .public)") }
    }

    /// Where app packages are fetched from (`main` when the config says nothing).
    var packageRef: String? { config.packageRef }

    /// Applies an edit to the app list (add, remove, move), re-resolves Home and saves atomically. Returns what the
    /// edit returned; a failed save is logged and the change still applies for this run. Nothing is written when
    /// the edit changed nothing.
    @discardableResult
    func edit<T>(_ change: (inout AppConfig, AppCatalog) -> T?) -> T? {
        var next = config
        guard let result = change(&next, catalog), next != config else { return nil }
        config = next
        home = Self.resolve(config, catalog: catalog, quiet: true)
        do { try file?.save(config) }
        catch { Self.log.error("config not saved: \(error.localizedDescription, privacy: .public)") }
        return result
    }

    /// First-run setup reached Done: the chosen apps become the config (saved atomically), and Home follows them.
    /// A failed save is logged and the choices still apply for this run (setup shows again next launch).
    func applySetup(_ chosen: AppConfig) {
        config = chosen
        needsSetup = false
        home = Self.resolve(config, catalog: catalog, quiet: true)
        do { try file?.save(config) }
        catch { Self.log.error("config not saved: \(error.localizedDescription, privacy: .public)") }
        Self.log.info("setup saved: \(chosen.apps.count) apps")
    }

    /// Values older versions kept in UserDefaults, for a first config.
    var migratedPreferences: [String: [String: ConfigValue]] { Self.migratedPrefs() }

    /// Whether a requirement is met on this Mac.
    func requirementMet(_ r: AppRequirement) -> Bool {
        r.isMet(bundleInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                fileExists: { FileManager.default.fileExists(atPath: $0) }, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Where a console's games are, as written in the config (may start with ~).
    func gamesFolderText(for console: Console) -> String {
        config.setting(AppConfig.gamesFolderKey, for: console.id)?.string.flatMap { $0.isEmpty ? nil : $0 } ?? console.defaultFolder
    }

    func gamesFolder(for console: Console) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: PathText.expandingTilde(gamesFolderText(for: console), home: home))
    }

    // MARK: Loading

    private static func resolve(_ config: AppConfig, catalog: AppCatalog, quiet: Bool = false) -> HomeApps {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolved = config.resolve(catalog: catalog) {
            $0.isMet(bundleInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                     fileExists: { FileManager.default.fileExists(atPath: $0) }, home: home)
        }
        if !quiet {
            for u in resolved.unmet { log.info("app \(u.id, privacy: .public) hidden: requires \(u.label, privacy: .public)") }
            if !resolved.unknownIDs.isEmpty { log.info("config has \(resolved.unknownIDs.count) app id(s) this version does not know; kept, not shown") }
        }
        return resolved
    }

    private static func log(_ outcome: ConfigFile.Outcome, apps: Int) {
        switch outcome {
        case .loaded: log.info("config loaded: \(apps) apps")
        case .created: log.info("config created from catalog defaults: \(apps) apps")
        case .replacedCorrupt(_, let backup, let reason):
            log.error("config was unreadable (\(reason, privacy: .public)); renamed to \(backup.lastPathComponent, privacy: .public), fresh default written")
        case .unusable(_, let reason): log.error("config not usable on disk, using defaults this run: \(reason, privacy: .public)")
        }
    }

    /// Values older versions kept in UserDefaults, carried into the first config.
    private static func migratedPrefs() -> [String: [String: ConfigValue]] {
        var out: [String: [String: ConfigValue]] = [:]
        if let raw = UserDefaults.standard.string(forKey: "netflix51"), Netflix51(rawValue: raw) != nil {
            out["netflix", default: [:]]["netflix51"] = .string(raw)
        }
        return out
    }

    private static func configDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.brad.htpcshell")
    }

    /// The catalog bundled in the app (Resources/catalog.json); a build run from
    /// the repo (swift run) reads apps/catalog.json. A missing or invalid
    /// catalog is a broken build, so it stops here with the reason.
    private static func loadCatalog() -> AppCatalog {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("catalog.json"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("apps/catalog.json")]
        for url in candidates.compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do { return try AppCatalog.parse(data) }
            catch { fatalError("app catalog \(url.path) is invalid: \(error)") }
        }
        fatalError("app catalog not found: build-app.sh bundles apps/catalog.json as Resources/catalog.json")
    }
}
