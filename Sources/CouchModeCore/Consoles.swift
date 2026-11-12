// Owns: what a console is (which files count as games, which emulator core
// plays them) and how consoles are made from the app catalog; the list itself
// is apps/catalog.json. Does not touch the disk; the app
// passes in folder listings.

import Foundation

public struct Console: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Where the games are unless the machine's config says otherwise, e.g. ~/Games/nes
    public let defaultFolder: String
    public let extensions: [String]
    /// libretro core file name inside RetroArch's cores folder; empty for
    /// consoles whose games are their own Mac apps (Switch via NX2Apple).
    public let coreFile: String

    /// Games are standalone .app bundles, launched directly, not via RetroArch.
    public var gamesAreApps: Bool { coreFile.isEmpty }
}

public enum ConsoleCatalog {
    /// The console apps in the catalog, in catalog order.
    public static func make(from apps: [CatalogApp]) -> [Console] {
        apps.compactMap { app in
            guard app.kind == .console, let c = app.console else { return nil }
            return Console(id: app.id, name: app.name, defaultFolder: c.defaultFolder, extensions: c.extensions, coreFile: c.core ?? "")
        }
    }
}

public struct Game: Equatable, Sendable, Identifiable {
    public let title: String
    public let fileName: String
    public var sizeBytes: Int64? = nil
    public var id: String { fileName }
}

public enum GameLibrary {
    /// Games for a console from a folder's file names: matching extensions
    /// only (case-insensitive), hidden files skipped, sorted by title.
    public static func games(fileNames: [String], for console: Console, sizes: [String: Int64] = [:]) -> [Game] {
        fileNames
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> Game? in
                let url = URL(fileURLWithPath: name)
                guard console.extensions.contains(url.pathExtension.lowercased()) else { return nil }
                return Game(title: url.deletingPathExtension().lastPathComponent, fileName: name, sizeBytes: sizes[name])
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func countLabel(_ n: Int) -> String {
        n == 0 ? "No games yet" : n == 1 ? "1 game" : "\(n) games"
    }
}
