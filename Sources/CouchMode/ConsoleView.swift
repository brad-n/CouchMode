// Owns: one console's game screen and its state holder, in SwitchTV's design
// (the TVPort project's tvOS app): the focused game's art fills the screen
// under a black-to-red split gradient, a hero shows its title and details,
// and poster rows (Recently Played, All Games) sit below. Used for Switch and
// every retro console. Launching is the coordinator's job.

import AppKit
import SwiftUI
import CouchModeCore

/// SwitchTV's palette (from its logo: a black and red split apple).
enum GameTheme {
    static let accent = Color(red: 0xEE / 255, green: 0x01 / 255, blue: 0x0D / 255)
    static let ink = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255)
    static let background = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)
    static let surface = Color(red: 0x19 / 255, green: 0x19 / 255, blue: 0x1B / 255)
    static let split = LinearGradient(stops: [.init(color: ink, location: 0), .init(color: ink.opacity(0.85), location: 0.45),
                                              .init(color: accent.opacity(0.28), location: 1)],
                                      startPoint: .leading, endPoint: .trailing)
    static let cardWidth: CGFloat = 400
    static let cardHeight: CGFloat = 225
    static let heroHeight: CGFloat = 470
    static let pagePadding: CGFloat = DS.page
}

/// Art and details for Switch games. SwitchTV's catalog (copied from TVPort
/// to ~/Games/switch/.catalog) gives name, publisher, genres, description,
/// card and banner; else the TVPort library banner (.art/<ID>.jpg); else the
/// build's own icon.
///
/// Everything here answers from memory. The files live in the games folder,
/// which may be on a drive that is slow, missing or waiting on a permission
/// prompt, so they are read by `preload` on a background thread after each
/// listing, and the screens redraw when it lands.
@MainActor
enum GameArt {
    /// Most images kept; the cache is cleared when it grows past this.
    private static let maxImages = 600
    private static var images: [String: NSImage] = [:]
    private static var titleIDs: [String: String] = [:]
    private static var bundleIDs: [String: String] = [:]
    /// Catalog per games folder, with the file date it was read at, so a
    /// rebuilt catalog (new game built) is picked up on the next listing.
    private static var catalogs: [String: (date: Date, catalog: SwitchCatalog)] = [:]

    /// Everything read for one folder, handed to the main actor in one piece.
    private struct Loaded: @unchecked Sendable {
        var titleIDs: [String: String] = [:]
        var bundleIDs: [String: String] = [:]
        var catalog: (date: Date, catalog: SwitchCatalog)?
        var images: [String: NSImage] = [:]
        var icons: [String: NSImage] = [:]
        var catalogUnchanged = false
    }

    static func titleID(_ appURL: URL) -> String? { titleIDs[appURL.path] }

    static func bundleID(_ appURL: URL) -> String? { bundleIDs[appURL.path] }

    static func info(_ appURL: URL) -> CatalogGame? {
        if DemoMode.isOn { return DemoMode.catalogGame(fileName: appURL.lastPathComponent) }
        guard let id = titleID(appURL) else { return nil }
        return catalogs[appURL.deletingLastPathComponent().path]?.catalog.game(id)
    }

    /// Reads the folder's catalog, the apps' ids, icons and art off the main thread, then keeps them.
    /// True when something new arrived (the screens should redraw).
    static func preload(folder: URL, appNames: [String]) async -> Bool {
        let known = catalogs[folder.path]?.date
        let names = Array(appNames.prefix(FolderLimits.maxNames))
        let loaded = await Task.detached(priority: .utility) { read(folder: folder, appNames: names, knownCatalogDate: known) }.value
        if images.count + loaded.images.count > maxImages { images.removeAll() }
        for (path, id) in loaded.titleIDs { titleIDs[path] = id }
        for (path, id) in loaded.bundleIDs { bundleIDs[path] = id }
        if let fresh = loaded.catalog { catalogs[folder.path] = fresh }
        for (path, image) in loaded.images { images[path] = image }
        AppIcons.store(loaded.icons)
        return !loaded.titleIDs.isEmpty || !loaded.images.isEmpty || loaded.catalog != nil
    }

    private nonisolated static func read(folder: URL, appNames: [String], knownCatalogDate: Date?) -> Loaded {
        var out = Loaded()
        let file = folder.appendingPathComponent(".catalog/catalog.json")
        let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        var catalog: SwitchCatalog?
        if let date, date != knownCatalogDate, let data = try? Data(contentsOf: file), let c = SwitchCatalog.decode(data) {
            out.catalog = (date, c)
            catalog = c
        }
        for name in appNames {
            let url = folder.appendingPathComponent(name)
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            out.bundleIDs[url.path] = bundleID
            guard let id = bundleID.split(separator: ".").last.map({ String($0).uppercased() }) else { continue }
            out.titleIDs[url.path] = id
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 512, height: 512)
            out.icons[url.path] = icon
            var files = [folder.appendingPathComponent(".art/\(id).jpg")]
            if let info = catalog?.game(id) {
                files += [folder.appendingPathComponent(".catalog/" + info.banner), folder.appendingPathComponent(".catalog/" + info.card)]
            }
            for f in files { if let image = NSImage(contentsOf: f) { out.images[f.path] = image } }
        }
        return out
    }

    private static func image(_ file: URL) -> NSImage? { images[file.path] }

    /// Wide art for the backdrop.
    static func banner(_ appURL: URL) -> NSImage? {
        if DemoMode.isOn { return DemoMode.gameArt(.hero, fileName: appURL.lastPathComponent) }
        let folder = appURL.deletingLastPathComponent()
        if let info = info(appURL), let img = image(folder.appendingPathComponent(".catalog/" + info.banner)) { return img }
        guard let id = titleID(appURL) else { return nil }
        return image(folder.appendingPathComponent(".art/\(id).jpg"))
    }

    /// 16:9 poster art for the card.
    static func card(_ appURL: URL) -> NSImage? {
        if DemoMode.isOn { return DemoMode.gameArt(.tile, fileName: appURL.lastPathComponent) }
        let folder = appURL.deletingLastPathComponent()
        if let info = info(appURL), let img = image(folder.appendingPathComponent(".catalog/" + info.card)) { return img }
        return banner(appURL)
    }
}

struct GameRowModel: Identifiable {
    let id: String
    let title: String
    let games: [Game]
}

@MainActor
final class ConsoleModel: ObservableObject {
    let console: Console
    let games: [Game]
    let folderPath: String
    /// What the folder is doing (loading, missing, blocked, slow) and what to tell the player about it.
    let state: FolderState
    let folderMessage: String?
    /// Real folder of the games, for app art (Switch builds).
    let folderURL: URL?
    let colors: [Color]
    let rows: [GameRowModel]
    let lastPlayed: [String: Date]
    /// The game that's open in the background (paused), by file name.
    let pausedGame: String?
    @Published private(set) var focus: FocusGrid?
    @Published var message: String?

    init(console: Console, games: [Game], folderPath: String, folderState: FolderState = .ready, folderMessage: String? = nil,
         folderURL: URL? = nil, colors: [Color],
         lastPlayed: [String: Date] = [:], pausedGame: String? = nil) {
        self.console = console
        self.games = games
        self.folderPath = folderPath
        self.state = folderState
        self.folderMessage = folderMessage
        self.folderURL = folderURL
        self.colors = colors
        self.lastPlayed = lastPlayed
        self.pausedGame = pausedGame
        // The paused game first (it's the one in progress), then most recent.
        let recent = games.filter { lastPlayed[$0.fileName] != nil }
            .sorted { a, b in
                let pa = a.fileName == pausedGame, pb = b.fileName == pausedGame
                return pa != pb ? pa : lastPlayed[a.fileName]! > lastPlayed[b.fileName]!
            }
            .prefix(10)
        var rows: [GameRowModel] = []
        if !recent.isEmpty { rows.append(GameRowModel(id: "recent", title: "Recently Played", games: Array(recent))) }
        if !games.isEmpty { rows.append(GameRowModel(id: "all", title: "All Games", games: games)) }
        // SwitchTV's genre rows: genres shared by at least two games.
        if console.gamesAreApps, let folderURL {
            let genreRows = GenreRows.build(games) { GameArt.info(folderURL.appendingPathComponent($0.fileName))?.genres ?? [] }
            rows += genreRows.map { GameRowModel(id: "genre-" + $0.genre, title: $0.genre, games: $0.items) }
        }
        self.rows = rows
        focus = FocusGrid(rowLengths: rows.map(\.games.count))
    }

    func move(_ d: Direction) { focus = focus?.moved(d) }

    /// Focuses the game's first card (e.g. after the screen is redrawn).
    func select(_ game: Game?) {
        guard let game else { return }
        for (r, row) in rows.enumerated() {
            if let c = row.games.firstIndex(of: game), let jumped = focus?.at(row: r, column: c) {
                focus = jumped
                return
            }
        }
    }

    var selected: Game? { focus.map { rows[$0.row].games[$0.column] } }

    func info(_ game: Game) -> CatalogGame? { appURL(game).flatMap(GameArt.info) }

    func appURL(_ game: Game) -> URL? {
        console.gamesAreApps ? folderURL?.appendingPathComponent(game.fileName) : nil
    }
}

enum SizeText {
    static func of(_ bytes: Int64?) -> String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

struct ConsoleView: View {
    @ObservedObject var model: ConsoleModel

    var body: some View {
        GeometryReader { geo in
            let s = max(0.6, geo.size.height / 1080)
            ZStack(alignment: .top) {
                GameBackdrop(model: model, size: geo.size)
                if let game = model.selected {
                    VStack(alignment: .leading, spacing: 0) {
                        HeroInfo(model: model, game: game, s: s)
                            .frame(height: GameTheme.heroHeight * s, alignment: .bottomLeading)
                        rows(s, width: geo.size.width)
                        footer(s)
                    }
                } else {
                    emptyState(s)
                }
                ScreenHeader(.console, s: s).pinnedToTop()
            }
            // Pinned to the screen: a wide poster row must never widen the page.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private func rows(_ s: CGFloat, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34 * s) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { r, row in
                        PosterRow(model: model, row: row, rowIndex: r, s: s, width: width).id(row.id)
                    }
                }
                .padding(.bottom, 40 * s)
            }
            .onChange(of: model.focus?.row) { _, r in
                guard let r, model.rows.indices.contains(r) else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(model.rows[r].id, anchor: .top) }
            }
        }
    }

    /// Only shown when there's something to say (e.g. a game couldn't start).
    @ViewBuilder private func footer(_ s: CGFloat) -> some View {
        if let note = model.folderMessage {
            Text(note)
                .font(.system(size: 18 * s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, GameTheme.pagePadding * s).padding(.bottom, 12 * s)
        }
        if let message = model.message {
            Text(message)
                .font(.system(size: 18 * s, weight: .semibold))
                .foregroundStyle(GameTheme.accent)
                .padding(.horizontal, GameTheme.pagePadding * s).padding(.bottom, 30 * s)
        }
    }

    private func emptyState(_ s: CGFloat) -> some View {
        VStack(spacing: 16 * s) {
            Text(model.console.name).font(.system(size: 56 * s, weight: .heavy)).foregroundStyle(.white)
            switch model.state {
            case .loading:
                Text("Loading games\u{2026}").font(.system(size: 30 * s, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            case .ready:
                Text("No games yet").font(.system(size: 30 * s, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                Text("Add game files to \(model.folderPath)").font(.system(size: 20 * s)).foregroundStyle(.white.opacity(0.6))
            case .notFound, .permissionDenied, .timedOut:
                Text(FolderMessages.tileLine(for: model.state) ?? "").font(.system(size: 30 * s, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                Text(model.folderMessage ?? "").font(.system(size: 20 * s)).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).padding(.horizontal, 120 * s)
                if model.state == .permissionDenied {
                    Text("Press Select to open System Settings").font(.system(size: 22 * s, weight: .semibold)).foregroundStyle(GameTheme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The focused game's art over the whole screen, under the split gradient
/// and a fade to the page; crossfades when the focus changes.
private struct GameBackdrop: View {
    @ObservedObject var model: ConsoleModel
    let size: CGSize

    var body: some View {
        ZStack {
            GameTheme.background
            ZStack {
                art
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
                GameTheme.split.opacity(0.88)
                LinearGradient(stops: [.init(color: .clear, location: 0.18), .init(color: GameTheme.background.opacity(0.9), location: 0.55),
                                       .init(color: GameTheme.background, location: 0.75)],
                               startPoint: .top, endPoint: .bottom)
            }
            .id(model.selected?.id ?? "none")
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.35), value: model.selected?.id)
    }

    @ViewBuilder private var art: some View {
        if let game = model.selected, let url = model.appURL(game) {
            if let banner = GameArt.banner(url) {
                cover(banner)
            } else {
                cover(AppIcons.icon(url)).blur(radius: 60).opacity(0.7)
            }
        } else if let console = Artwork.image(model.console.id) {
            cover(console)
        } else {
            LinearGradient(colors: model.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension GameBackdrop {
    /// The image scaled to cover the screen (explicit size from its aspect
    /// ratio; SwiftUI's scaledToFill placed it off to one side here).
    func cover(_ image: NSImage) -> some View {
        let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
        let scale = max(size.width / iw, size.height / ih)
        return Image(nsImage: image).resizable().frame(width: iw * scale, height: ih * scale)
    }
}

/// SwitchTV's hero: title; publisher • year • players; genres in red; the
/// first lines of the description. Games without catalog details show
/// size / last played and the console name instead.
private struct HeroInfo: View {
    @ObservedObject var model: ConsoleModel
    let game: Game
    let s: CGFloat

    var body: some View {
        let info = model.info(game)
        VStack(alignment: .leading, spacing: 14 * s) {
            Text(info?.name ?? game.title)
                .font(.system(size: 64 * s, weight: .heavy))
                .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
            Text(meta(info)).font(.system(size: 24 * s, weight: .semibold)).foregroundStyle(.white.opacity(0.68))
            HStack(spacing: 16 * s) {
                Text(genres(info))
                    .font(.system(size: 18 * s, weight: .bold))
                    .foregroundStyle(GameTheme.accent)
                DetailsCue(s: s)
            }
            if let blurb = info?.blurb {
                Text(blurb)
                    .font(.system(size: 20 * s))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(3)
                    .frame(maxWidth: 1000 * s, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GameTheme.pagePadding * s).padding(.bottom, 28 * s)
        .id(game.id).transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: game.id)
    }

    private func meta(_ info: CatalogGame?) -> String {
        var parts: [String] = []
        if let text = info?.metaText, !text.isEmpty { parts.append(text) }
        if let size = SizeText.of(game.sizeBytes) { parts.append(size) }
        if model.pausedGame == game.fileName {
            parts.append("Paused \u{2014} Play resumes, X closes")
        } else if let played = model.lastPlayed[game.fileName] {
            parts.append("Played " + played.formatted(.relative(presentation: .named)))
        } else if info == nil {
            parts.append("Not played yet")
        }
        return parts.joined(separator: "  \u{2022}  ")
    }

    private func genres(_ info: CatalogGame?) -> String {
        if let g = info?.genres, !g.isEmpty { return g.joined(separator: "  /  ") }
        return model.console.name
    }
}

private struct PosterRow: View {
    @ObservedObject var model: ConsoleModel
    let row: GameRowModel
    let rowIndex: Int
    let s: CGFloat
    let width: CGFloat

    /// The focused column in this row, or the row's remembered position (0).
    private var focusedColumn: Int { model.focus?.row == rowIndex ? (model.focus?.column ?? 0) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            Text(row.title)
                .font(.system(size: 26 * s, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, GameTheme.pagePadding * s)
            // tvOS-style: the row slides so the focused card stays near the left.
            HStack(spacing: 36 * s) {
                ForEach(Array(row.games.enumerated()), id: \.element.id) { c, game in
                    GameCard(model: model, game: game,
                             focused: model.focus?.row == rowIndex && model.focus?.column == c, s: s)
                }
            }
            .padding(.horizontal, GameTheme.pagePadding * s).padding(.vertical, 24 * s)   // room for the focus lift
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -RowSlide.offset(focusedColumn: focusedColumn, step: (GameTheme.cardWidth + 36) * s))
            .frame(width: width, alignment: .leading)
            .clipped()
            .animation(.easeOut(duration: 0.25), value: focusedColumn)
        }
    }
}

/// A 16:9 poster with the title under it; uses the shell's focus treatment
/// (lift, shadow, sheen), the same as the home screen's cards.
private struct GameCard: View {
    @ObservedObject var model: ConsoleModel
    let game: Game
    let focused: Bool
    let s: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
        VStack(alignment: .leading, spacing: 12 * s) {
            ZStack {
                GameTheme.surface
                poster
            }
            .frame(width: GameTheme.cardWidth * s, height: GameTheme.cardHeight * s)
            .clipShape(shape)
            .focusLift(focused, radius: 14 * s, s: s, amount: 1.08)
            Text(model.info(game)?.name ?? game.title)
                .font(DS.ui(19, s, .bold))
                .foregroundStyle(.white.opacity(focused ? 1 : 0.7)).lineLimit(1)
                .frame(width: GameTheme.cardWidth * s, alignment: .leading)
                .offset(y: focused ? 12 * s : 0)
                .animation(DS.focusSpring, value: focused)
        }
    }

    @ViewBuilder private var poster: some View {
        if let url = model.appURL(game) {
            if let card = GameArt.card(url) {
                Image(nsImage: card).resizable().scaledToFill()
            } else {
                // No banner: the game's own icon, blurred behind and crisp in front.
                let icon = AppIcons.icon(url)
                Image(nsImage: icon).resizable().scaledToFill().blur(radius: 24 * s).opacity(0.6)
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 130 * s, height: 130 * s)
                    .shadow(color: .black.opacity(0.5), radius: 12 * s, y: 6 * s)
            }
        } else {
            // Retro games: the console's art, darkened, with the title's initial.
            if let art = Artwork.image(model.console.id) {
                Image(nsImage: art).resizable().scaledToFill().opacity(0.45)
            } else {
                LinearGradient(colors: model.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Text(String(game.title.prefix(1)).uppercased())
                .font(.system(size: 110 * s, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 10 * s)
        }
    }
}
