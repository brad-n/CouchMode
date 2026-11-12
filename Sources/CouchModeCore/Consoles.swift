// Owns: which retro consoles the shell offers, which files count as games for
// each, and which emulator core plays them. Does not touch the disk; the app
// passes in folder listings.

import Foundation

public struct Console: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Folder under the games directory, e.g. ~/Games/nes
    public let folder: String
    public let extensions: [String]
    /// libretro core file name inside RetroArch's cores folder; empty for
    /// consoles whose games are their own Mac apps (Switch via NX2Apple).
    public let coreFile: String

    /// Games are standalone .app bundles, launched directly, not via RetroArch.
    public var gamesAreApps: Bool { coreFile.isEmpty }
}

public enum ConsoleCatalog {
    // Order is the order on screen. Cores are libretro arm64 builds in
    // RetroArch's cores folder. Disc systems marked BIOS need the console's
    // own BIOS in RetroArch's system folder.
    public static let all: [Console] = [
        // NX2Apple builds each Switch game into its own Mac app (~/Games/switch).
        Console(id: "switch", name: "Nintendo Switch", folder: "switch", extensions: ["app"], coreFile: ""),
        Console(id: "nes", name: "NES", folder: "nes", extensions: ["nes"], coreFile: "nestopia_libretro.dylib"),
        Console(id: "snes", name: "Super Nintendo", folder: "snes", extensions: ["sfc", "smc"], coreFile: "snes9x_libretro.dylib"),
        Console(id: "n64", name: "Nintendo 64", folder: "n64", extensions: ["n64", "z64", "v64"], coreFile: "mupen64plus_next_libretro.dylib"),
        Console(id: "gamecube", name: "GameCube & Wii", folder: "gamecube", extensions: ["iso", "rvz", "gcm", "wbfs", "ciso"], coreFile: "dolphin_libretro.dylib"),
        Console(id: "gameboy", name: "Game Boy", folder: "gameboy", extensions: ["gb", "gbc", "gba"], coreFile: "mgba_libretro.dylib"),
        Console(id: "ds", name: "Nintendo DS", folder: "ds", extensions: ["nds"], coreFile: "melonds_libretro.dylib"),
        Console(id: "psx", name: "PlayStation", folder: "psx", extensions: ["cue", "chd", "pbp", "m3u"], coreFile: "pcsx_rearmed_libretro.dylib"),
        Console(id: "ps2", name: "PlayStation 2", folder: "ps2", extensions: ["iso", "chd"], coreFile: "pcsx2_libretro.dylib"),         // BIOS
        Console(id: "psp", name: "PSP", folder: "psp", extensions: ["iso", "cso", "pbp", "chd"], coreFile: "ppsspp_libretro.dylib"),
        Console(id: "mastersystem", name: "Master System & Game Gear", folder: "mastersystem", extensions: ["sms", "gg"], coreFile: "genesis_plus_gx_libretro.dylib"),
        Console(id: "genesis", name: "Genesis", folder: "genesis", extensions: ["md", "gen", "bin"], coreFile: "genesis_plus_gx_libretro.dylib"),
        Console(id: "segacd", name: "Sega CD & 32X", folder: "segacd", extensions: ["cue", "chd", "32x"], coreFile: "picodrive_libretro.dylib"),  // BIOS (CD)
        Console(id: "saturn", name: "Saturn", folder: "saturn", extensions: ["cue", "chd"], coreFile: "mednafen_saturn_libretro.dylib"),   // BIOS
        Console(id: "dreamcast", name: "Dreamcast", folder: "dreamcast", extensions: ["gdi", "chd", "cdi"], coreFile: "flycast_libretro.dylib"),
        Console(id: "tg16", name: "TurboGrafx-16", folder: "tg16", extensions: ["pce"], coreFile: "mednafen_pce_fast_libretro.dylib"),
        Console(id: "atari2600", name: "Atari 2600", folder: "atari2600", extensions: ["a26", "bin"], coreFile: "stella_libretro.dylib"),
        Console(id: "arcade", name: "Arcade & Neo Geo", folder: "arcade", extensions: ["zip"], coreFile: "fbneo_libretro.dylib"),
    ]
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
