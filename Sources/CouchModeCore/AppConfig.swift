// Owns: a machine's app configuration as pure data: which catalog apps are
// added, in what order, and each one's settings; building the defaults for a
// first run; and resolving the list against the catalog for Home (unknown
// ids skipped, unmet requirements hidden). Does not read or write files
// (ConfigFile) and holds no secrets.

import Foundation

/// A per-app setting value. Only plain JSON scalars: anything else in a
/// config file makes it unreadable, so it is set aside rather than half-used.
public enum ConfigValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool), number(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        }
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
}

public struct AppEntry: Codable, Equatable, Sendable {
    public let id: String
    public var settings: [String: ConfigValue]

    public init(id: String, settings: [String: ConfigValue] = [:]) {
        self.id = id
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        settings = try c.decodeIfPresent([String: ConfigValue].self, forKey: .settings) ?? [:]
    }
    private enum Keys: String, CodingKey { case id, settings }
}

/// An added app that is in the catalog and may be shown, with its settings.
public struct ResolvedApp: Equatable, Sendable {
    public let app: CatalogApp
    public let settings: [String: ConfigValue]
}

public struct HomeApps: Equatable, Sendable {
    public let apps: [ResolvedApp]
    /// Config ids the catalog does not know (kept in the file, not shown).
    public let unknownIDs: [String]
    /// Apps left out because a requirement is not met.
    public let unmet: [(id: String, label: String)]

    public static func == (a: HomeApps, b: HomeApps) -> Bool {
        a.apps == b.apps && a.unknownIDs == b.unknownIDs && a.unmet.map(\.id) == b.unmet.map(\.id)
    }
}

public enum RequirementText {
    /// "RetroArch installed" -> "RetroArch".
    public static func name(_ label: String) -> String {
        label.hasSuffix(" installed") ? String(label.dropLast(" installed".count)) : label
    }
}

public enum AppConfigError: Error, Equatable { case tooLarge, malformed(String), badVersion(Int), emptyID }

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxBytes = 256 * 1024
    public static let maxApps = 500
    /// The per-console setting holding the games folder.
    public static let gamesFolderKey = "gamesFolder"

    public var version: Int
    public var apps: [AppEntry]
    /// The repo branch, tag or commit app packages are fetched from; nil means `main`.
    public var packageRef: String?

    public init(version: Int = AppConfig.currentVersion, apps: [AppEntry], packageRef: String? = nil) {
        self.version = version
        self.apps = apps
        self.packageRef = packageRef
    }

    // MARK: First run

    /// A fresh config from the catalog: every default app, in catalog order,
    /// with its default settings (a console's games folder). `migrated` are
    /// values already held elsewhere (older preferences) and win over defaults;
    /// ids the catalog does not know are ignored.
    public static func defaults(catalog: AppCatalog, migrated: [String: [String: ConfigValue]] = [:]) -> AppConfig {
        AppConfig(apps: catalog.apps.filter(\.defaultEnabled).map { entry(for: $0, migrated: migrated[$0.id] ?? [:]) })
    }

    /// A new entry for a catalog app with its default settings (a console's games folder).
    public static func entry(for app: CatalogApp, migrated: [String: ConfigValue] = [:]) -> AppEntry {
        var settings: [String: ConfigValue] = [:]
        if let c = app.console { settings[gamesFolderKey] = .string(c.defaultFolder) }
        for (k, v) in migrated { settings[k] = v }
        return AppEntry(id: app.id, settings: settings)
    }

    // MARK: Editing the list

    /// Appends a catalog app with its default settings; false when it is already added.
    @discardableResult
    public mutating func add(_ app: CatalogApp) -> Bool {
        guard !apps.contains(where: { $0.id == app.id }), apps.count < Self.maxApps else { return false }
        apps.append(Self.entry(for: app))
        return true
    }

    /// Removes an app (every entry with that id, settings included). The system screen (Settings) can't be removed,
    /// and an id the catalog doesn't know is left alone.
    @discardableResult
    public mutating func remove(id: String, catalog: AppCatalog) -> Bool {
        guard let app = catalog.app(id: id), app.kind != .system, apps.contains(where: { $0.id == id }) else { return false }
        apps.removeAll { $0.id == id }
        return true
    }

    /// Moves an app one place up (-1) or down (+1) past the nearest neighbour that `listed` says is shown (entries
    /// the list doesn't show, such as ids this version doesn't know, are stepped over and keep their relative order).
    /// Returns the app's new position among the listed ones, or nil when it can't move that way.
    @discardableResult
    public mutating func move(id: String, by step: Int, listed: (String) -> Bool) -> Int? {
        guard step == -1 || step == 1, let from = apps.firstIndex(where: { $0.id == id }) else { return nil }
        var j = from + step
        while apps.indices.contains(j), !listed(apps[j].id) || apps[j].id == id { j += step }
        guard apps.indices.contains(j) else { return nil }
        apps.swapAt(from, j)
        var seen = Set<String>(), position = 0
        for entry in apps where listed(entry.id) && seen.insert(entry.id).inserted {
            if entry.id == id { return position }
            position += 1
        }
        return nil
    }

    // MARK: Adding

    /// A catalog app that can be added, with whether this Mac meets its requirement.
    public struct Addable: Equatable, Sendable {
        public let app: CatalogApp
        /// nil when ready; else the requirement's label, e.g. "RetroArch installed".
        public let unmet: String?
        /// "Ready", or "needs RetroArch".
        public var status: String { unmet.map { "needs " + RequirementText.name($0) } ?? "Ready" }
    }

    /// Catalog apps not yet in the config (the system screen never is), in catalog order.
    public func addable(catalog: AppCatalog, requirementMet: (AppRequirement) -> Bool) -> [Addable] {
        let added = Set(apps.map(\.id))
        return catalog.apps.filter { !added.contains($0.id) && $0.kind != .system }.map { app in
            Addable(app: app, unmet: app.requires.first { !requirementMet($0) }?.label)
        }
    }

    // MARK: Reading and writing

    public static func parse(_ data: Data) throws -> AppConfig {
        guard data.count <= maxBytes else { throw AppConfigError.tooLarge }
        var config: AppConfig
        do { config = try JSONDecoder().decode(AppConfig.self, from: data) }
        catch { throw AppConfigError.malformed(String(describing: error).prefix(200).description) }
        guard config.version >= 1 else { throw AppConfigError.badVersion(config.version) }
        guard config.apps.count <= maxApps else { throw AppConfigError.tooLarge }
        // A ref that isn't a safe name is dropped (main is used), not a reason to set the whole config aside.
        if let ref = config.packageRef, !PackageSource.validRef(ref) { config.packageRef = nil }
        guard !config.apps.contains(where: { $0.id.isEmpty }) else { throw AppConfigError.emptyID }
        return config
    }

    /// Readable, stable bytes: indented, keys sorted, slashes unescaped.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self) + Data("\n".utf8)
    }

    // MARK: Settings

    public func setting(_ key: String, for id: String) -> ConfigValue? {
        apps.first { $0.id == id }?.settings[key]
    }

    /// Sets a value on an added app; false when that app is not in the config.
    @discardableResult
    public mutating func set(_ key: String, _ value: ConfigValue?, for id: String) -> Bool {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return false }
        apps[i].settings[key] = value
        return true
    }

    // MARK: Home

    /// The apps Home shows, in config order: the first entry of each id,
    /// skipping ids the catalog doesn't know and apps whose requirements fail.
    public func resolve(catalog: AppCatalog, requirementMet: (AppRequirement) -> Bool) -> HomeApps {
        var shown: [ResolvedApp] = [], unknown: [String] = [], unmet: [(id: String, label: String)] = []
        var seen = Set<String>()
        for entry in apps where seen.insert(entry.id).inserted {
            guard let app = catalog.app(id: entry.id) else { unknown.append(entry.id); continue }
            if let failed = app.requires.first(where: { !requirementMet($0) }) {
                unmet.append((app.id, failed.label))
                continue
            }
            shown.append(ResolvedApp(app: app, settings: entry.settings))
        }
        return HomeApps(apps: shown, unknownIDs: unknown, unmet: unmet)
    }
}
