// Owns: the opt-in demo mode switch and the few facts the app swaps in when
// it is on: sample games and history in place of the games folder, sample
// Plex Continue Watching, sample settings values, and the rule that nothing
// is launched. Demo mode exists so screenshots and trials show only invented
// content; it is off unless `defaults write local.brad.htpcshell DemoMode
// -bool true` (read once at launch). The content itself is in CouchModeCore
// (DemoCatalog); the art is drawn by DemoArtRenderer.

import AppKit
import Foundation
import CouchModeCore

enum DemoMode {
    static let defaultsKey = "DemoMode"

    /// True when the app was started in demo mode. Read once, so it can't change under a running screen.
    static let isOn: Bool = UserDefaults.standard.bool(forKey: defaultsKey)

    /// Sample games for a console, as the games folder would list them.
    static func games(for console: Console) -> [Game] {
        let list = DemoCatalog.games(forConsole: console.id)
        return GameLibrary.games(fileNames: list.map { DemoCatalog.fileName($0, console: console) }, for: console)
    }

    /// When each sample game was "last played", relative to now.
    static func lastPlayed(for console: Console, now: Date = Date()) -> [String: Date] {
        var out: [String: Date] = [:]
        for (title, ago) in DemoCatalog.playedSecondsAgo(console: console.id) {
            out[title + "." + (console.extensions.first ?? "bin")] = now.addingTimeInterval(-ago)
        }
        return out
    }

    /// A sample game's catalog entry, as SwitchTV's catalog file would give it.
    static func catalogGame(fileName: String) -> CatalogGame? {
        guard let game = DemoCatalog.game(fileName: fileName) else { return nil }
        let id = "DEMO" + String(DemoArtSpec.fnv1a(game.title) & 0xFFFF, radix: 16, uppercase: true)
        return try? JSONDecoder().decode(CatalogGame.self, from: game.catalogJSON(titleID: id))
    }

    /// Generated art for a sample game: a wide backdrop or a titled card.
    @MainActor static func gameArt(_ kind: DemoArtKind, fileName: String) -> NSImage? {
        guard let game = DemoCatalog.game(fileName: fileName) else { return nil }
        return DemoArtRenderer.image(DemoArtSpec(kind: kind, title: game.title))
    }

    /// Sample Continue Watching for Plex: art is generated, links point nowhere.
    static func plexContinueWatching() -> [ContinueEntry] {
        DemoCatalog.continueItems().map { item in
            ContinueEntry(item: item, image: DemoArtSpec(kind: .tile, title: item.title).url,
                          backdrop: DemoArtSpec(kind: .hero, title: item.title).url,
                          details: URL(string: "\(DemoCatalog.baseURL)/plex/\(item.ratingKey)"), source: nil)
        }
    }

    /// Values for the Settings screen that would otherwise name this Mac's own devices and disk.
    enum SettingsValue {
        static let audio = "Living Room Speakers"
        static let controllers = "2 connected"
        static let storage = "412 GB free of 994 GB"
    }

    /// What a card does in demo mode: nothing that starts another app or opens a real website.
    static let launchNotice = "Demo mode: this would open the real app"
}
