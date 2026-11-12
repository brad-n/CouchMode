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

public enum AppConfigError: Error, Equatable { case tooLarge, malformed(String), badVersion(Int), emptyID }

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxBytes = 256 * 1024
    public static let maxApps = 500
    /// The per-console setting holding the games folder.
    public static let gamesFolderKey = "gamesFolder"

    public var version: Int
    public var apps: [AppEntry]

    public init(version: Int = AppConfig.currentVersion, apps: [AppEntry]) {
        self.version = version
        self.apps = apps
    }

    // MARK: First run

    /// A fresh config from the catalog: every default app, in catalog order,
    /// with its default settings (a console's games folder). `migrated` are
    /// values already held elsewhere (older preferences) and win over defaults;
    /// ids the catalog does not know are ignored.
    public static func defaults(catalog: AppCatalog, migrated: [String: [String: ConfigValue]] = [:]) -> AppConfig {
        let entries = catalog.apps.filter(\.defaultEnabled).map { app -> AppEntry in
            var settings: [String: ConfigValue] = [:]
            if let c = app.console { settings[gamesFolderKey] = .string(c.defaultFolder) }
            for (k, v) in migrated[app.id] ?? [:] { settings[k] = v }
            return AppEntry(id: app.id, settings: settings)
        }
        return AppConfig(apps: entries)
    }

    // MARK: Reading and writing

    public static func parse(_ data: Data) throws -> AppConfig {
        guard data.count <= maxBytes else { throw AppConfigError.tooLarge }
        let config: AppConfig
        do { config = try JSONDecoder().decode(AppConfig.self, from: data) }
        catch { throw AppConfigError.malformed(String(describing: error).prefix(200).description) }
        guard config.version >= 1 else { throw AppConfigError.badVersion(config.version) }
        guard config.apps.count <= maxApps else { throw AppConfigError.tooLarge }
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
