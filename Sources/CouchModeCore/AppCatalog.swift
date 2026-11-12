// Owns: the app catalog as pure data: every app CouchMode knows (streaming
// sites, native Mac apps, game consoles, system screens), parsed and checked
// from apps/catalog.json. Does not read files, and says nothing about which
// apps a machine has added (see AppConfig).

import Foundation

public enum AppKind: String, Codable, Sendable { case stream, native, console, system }

/// A condition for showing an app, e.g. "RetroArch installed": met when the
/// bundle id resolves to an installed app or any of the paths exists.
public struct AppRequirement: Codable, Equatable, Sendable {
    public let label: String
    public var bundleId: String? = nil
    public var appPaths: [String]? = nil

    /// A requirement with neither a bundle id nor paths asks for nothing and is met.
    public func isMet(bundleInstalled: (String) -> Bool, fileExists: (String) -> Bool, home: String) -> Bool {
        if bundleId == nil && (appPaths ?? []).isEmpty { return true }
        if let id = bundleId, bundleInstalled(id) { return true }
        return (appPaths ?? []).contains { fileExists(PathText.expandingTilde($0, home: home)) }
    }
}

public struct AppSite: Codable, Equatable, Sendable {
    public let url: String
    /// `safari` (the installed Safari's identity), `smartTV`, or a literal user agent.
    public let userAgent: String
    public var tvInterface: Bool = false
    public var navigationSkip: String? = nil

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        url = try c.decode(String.self, forKey: .url)
        userAgent = try c.decode(String.self, forKey: .userAgent)
        tvInterface = try c.decodeIfPresent(Bool.self, forKey: .tvInterface) ?? false
        navigationSkip = try c.decodeIfPresent(String.self, forKey: .navigationSkip)
    }
    private enum Keys: String, CodingKey { case url, userAgent, tvInterface, navigationSkip }
}

public struct AppNative: Codable, Equatable, Sendable {
    public var bundleId: String? = nil
    public var appPath: String? = nil
}

public struct AppConsoleSpec: Codable, Equatable, Sendable {
    /// `retroarch` (plays through a libretro core) or `app` (each game is its own Mac app).
    public let emulator: String
    public var core: String? = nil
    public let extensions: [String]
    /// Where games live unless the machine's config says otherwise, e.g. `~/Games/nes`.
    public let defaultFolder: String
}

public struct CatalogApp: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: AppKind
    public var site: AppSite? = nil
    public var native: AppNative? = nil
    public var console: AppConsoleSpec? = nil
    public var requires: [AppRequirement] = []
    /// Added to a fresh config. Apps that are not default are only added by the user.
    public var defaultEnabled: Bool = true
    public var note: String? = nil
    /// A stream's default reader (`builtin` or `package`) when a Mac's config has no `reader` setting.
    public var reader: String? = nil

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AppKind.self, forKey: .kind)
        site = try c.decodeIfPresent(AppSite.self, forKey: .site)
        native = try c.decodeIfPresent(AppNative.self, forKey: .native)
        console = try c.decodeIfPresent(AppConsoleSpec.self, forKey: .console)
        requires = try c.decodeIfPresent([AppRequirement].self, forKey: .requires) ?? []
        defaultEnabled = try c.decodeIfPresent(Bool.self, forKey: .defaultEnabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note)
        reader = try c.decodeIfPresent(String.self, forKey: .reader)
    }
    private enum Keys: String, CodingKey { case id, name, kind, site, native, console, requires, defaultEnabled, note, reader }
}

public enum AppCatalogError: Error, Equatable, CustomStringConvertible {
    case tooLarge, malformed(String), unsupportedVersion(Int), duplicateID(String), invalid(id: String, why: String)
    public var description: String {
        switch self {
        case .tooLarge: return "catalog too large"
        case .malformed(let s): return "catalog is not valid JSON of the expected shape: \(s)"
        case .unsupportedVersion(let v): return "unsupported catalog version \(v)"
        case .duplicateID(let id): return "duplicate app id \(id)"
        case .invalid(let id, let why): return "app \(id): \(why)"
        }
    }
}

public struct AppCatalog: Equatable, Sendable {
    public static let supportedVersion = 1
    public static let maxBytes = 1_000_000
    public static let maxApps = 500

    public let version: Int
    public let apps: [CatalogApp]

    public func app(id: String) -> CatalogApp? { apps.first { $0.id == id } }

    private struct Wire: Decodable { let version: Int; let apps: [CatalogApp] }

    public static func parse(_ data: Data) throws -> AppCatalog {
        guard data.count <= maxBytes else { throw AppCatalogError.tooLarge }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw AppCatalogError.malformed(String(describing: error).prefix(200).description) }
        guard wire.version == supportedVersion else { throw AppCatalogError.unsupportedVersion(wire.version) }
        guard wire.apps.count <= maxApps else { throw AppCatalogError.tooLarge }
        var seen = Set<String>()
        for app in wire.apps {
            guard !app.id.isEmpty, !app.name.isEmpty else { throw AppCatalogError.invalid(id: app.id, why: "empty id or name") }
            guard seen.insert(app.id).inserted else { throw AppCatalogError.duplicateID(app.id) }
            if let why = problem(with: app) { throw AppCatalogError.invalid(id: app.id, why: why) }
        }
        return AppCatalog(version: wire.version, apps: wire.apps)
    }

    private static func problem(with app: CatalogApp) -> String? {
        switch app.kind {
        case .stream:
            guard let site = app.site else { return "stream needs a site" }
            return siteProblem(site)
        case .native:
            guard let native = app.native, native.bundleId != nil || native.appPath != nil else { return "native needs a bundleId or appPath" }
            return app.site.flatMap(siteProblem)
        case .console:
            guard let c = app.console else { return "console needs console settings" }
            guard c.emulator == "retroarch" || c.emulator == "app" else { return "unknown emulator \(c.emulator)" }
            guard !c.extensions.isEmpty, !c.defaultFolder.isEmpty else { return "console needs extensions and defaultFolder" }
            if c.emulator == "retroarch", (c.core ?? "").isEmpty { return "retroarch console needs a core" }
            if c.emulator == "app", c.core != nil { return "app console takes no core" }
            return nil
        case .system:
            return nil
        }
    }

    private static func siteProblem(_ site: AppSite) -> String? {
        guard let url = URL(string: site.url), let scheme = url.scheme, scheme == "https" || scheme == "http", url.host != nil
        else { return "site url is not an http(s) address" }
        return site.userAgent.isEmpty ? "site needs a userAgent" : nil
    }
}

public enum PathText {
    /// `~` and `~/x` become the home folder; anything else is unchanged.
    public static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }
}
