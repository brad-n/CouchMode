// Owns: the home screen's presentation and its state holder (HomeModel).
// tvOS-style: the focused item's art fills the screen behind a hero (title,
// details, action cue); rows of cards sit below and slide so the focused row
// always lands in the same place. No ScrollViews: positions are computed, so
// focus can never drift off-screen. Card focus rules live in CouchModeCore
// (FocusGrid, RowSlide); what a card DOES is decided by AppCoordinator.

import AppKit
import Combine
import SwiftUI
import CouchModeCore

enum HomeAction {
    case stream(Service)
    /// A Continue Watching title: Plex HTPC when it's installed (its own
    /// Continue Watching row comes first), else the title on Plex's website.
    case resume(URL)
    case console(Console)
    case allConsoles
    case settings
    case game(Console, Game)
    case none
}

/// How a card is drawn: wide art with a caption below, or an app tile.
enum CardStyle { case landscape, app }

struct HomeItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String          // SF Symbol name
    let colors: [Color]
    var style: CardStyle = .landscape
    let action: HomeAction
    /// Bundled card art (Resources/art/<name>.png).
    var artwork: String? = nil
    /// Remote card art (Plex) and watch progress 0...1.
    var imageURL: URL? = nil
    var progress: Double? = nil
    /// Full-screen art for the hero (Plex backdrops).
    var heroImageURL: URL? = nil
    /// Hero action cue, e.g. "Resume" or "Open".
    var cue: String = "Open"
    /// One line under the hero title when the subtitle isn't enough.
    var tagline: String? = nil
    /// Local art already loaded (Switch catalog card / banner).
    var cardImage: NSImage? = nil
    var heroImage: NSImage? = nil
    /// The service's brand color (catalog), behind its logo when it has no tvOS art.
    var brand: RGB? = nil
}

extension HomeItem {
    /// Shows and games have a details page (Info / Play-Pause).
    var hasDetails: Bool {
        switch action {
        case .resume, .game: return true
        default: return false
        }
    }
}

/// A quiet hint that Play/Pause (Info) opens details.
struct DetailsCue: View {
    let s: CGFloat
    var body: some View {
        HStack(spacing: 6 * s) {
            Image(systemName: "playpause.fill").font(.system(size: 15 * s, weight: .bold))
            Text("Details").font(DS.ui(17, s, .semibold))
        }
        .foregroundStyle(DS.text3)
        .padding(.horizontal, 12 * s).padding(.vertical, 7 * s)
        .background(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}

struct HomeRow: Identifiable {
    let id: String
    let title: String
    let items: [HomeItem]
}

/// Card artwork bundled with the app (packaging/art -> Contents/Resources/art).
enum Artwork {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func exists(_ name: String) -> Bool { image(name) != nil }

    @MainActor static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("art/\(name).png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

/// Older palette names, kept for the screens that still use them (overlays,
/// All Consoles); new work uses DS.
enum Theme {
    static let accent = DS.accent
    static let canvas = DS.canvas
    static let textPrimary = DS.text
    static let textSecondary = DS.text2
    static let textFaint = DS.text3
    static let neutralCard = [Color(red: 0.20, green: 0.20, blue: 0.22), Color(red: 0.10, green: 0.10, blue: 0.12)]
    static let consoleCards: [[Color]] = [
        [Color(red: 0.58, green: 0.18, blue: 0.20), Color(red: 0.22, green: 0.07, blue: 0.09)],
        [Color(red: 0.38, green: 0.30, blue: 0.58), Color(red: 0.14, green: 0.11, blue: 0.27)],
        [Color(red: 0.16, green: 0.30, blue: 0.56), Color(red: 0.05, green: 0.10, blue: 0.24)],
        [Color(red: 0.36, green: 0.50, blue: 0.24), Color(red: 0.12, green: 0.22, blue: 0.09)],
        [Color(red: 0.20, green: 0.48, blue: 0.40), Color(red: 0.06, green: 0.20, blue: 0.17)],
    ]
}

/// A recently played game for the home screen's Jump Back In row.
struct RecentGame {
    let console: Console
    let game: Game
    let played: Date
    let title: String
    var tagline: String? = nil
    var card: NSImage? = nil
    var hero: NSImage? = nil
    /// Open in the background: Play resumes it.
    var paused = false
}

/// What each streaming app is, for its tile and the hero: generic symbols and
/// our own words. A service's real icon is fetched at runtime (ServiceIcons),
/// never shipped; these are the look when it isn't there.
enum ServiceLook {
    static func symbol(_ id: String) -> String {
        switch id {
        case "plex": return "play.rectangle.on.rectangle.fill"
        case "appletv": return "tv.and.mediabox.fill"
        case "netflix": return "film.stack.fill"
        case "youtube": return "play.tv.fill"
        case "disney": return "sparkles.tv.fill"
        case "hulu": return "tv.fill"
        case "max": return "popcorn.fill"
        case "prime": return "movieclapper.fill"
        default: return "play.fill"
        }
    }
    /// Each service's own tile colours (by id, so adding a service never
    /// recolours the others).
    static func colors(_ id: String) -> [Color] {
        switch id {
        case "plex": return [Color(red: 0.86, green: 0.55, blue: 0.16), Color(red: 0.42, green: 0.22, blue: 0.05)]
        case "appletv": return [Color(red: 0.34, green: 0.35, blue: 0.38), Color(red: 0.10, green: 0.10, blue: 0.12)]
        case "netflix": return [Color(red: 0.62, green: 0.10, blue: 0.12), Color(red: 0.22, green: 0.03, blue: 0.05)]
        case "youtube": return [Color(red: 0.72, green: 0.16, blue: 0.14), Color(red: 0.26, green: 0.05, blue: 0.06)]
        case "disney": return [Color(red: 0.12, green: 0.24, blue: 0.62), Color(red: 0.04, green: 0.08, blue: 0.28)]
        case "hulu": return [Color(red: 0.10, green: 0.56, blue: 0.40), Color(red: 0.03, green: 0.22, blue: 0.16)]
        case "max": return [Color(red: 0.28, green: 0.20, blue: 0.70), Color(red: 0.09, green: 0.06, blue: 0.30)]
        case "prime": return [Color(red: 0.10, green: 0.44, blue: 0.70), Color(red: 0.03, green: 0.16, blue: 0.32)]
        default: return Theme.neutralCard
        }
    }

    static func tagline(_ id: String) -> String {
        switch id {
        case "plex": return "Your own library: every show and movie on your servers"
        case "appletv": return "Apple TV+ originals, plus sports and channels"
        case "netflix": return "Series, films and originals"
        case "youtube": return "Videos, channels and music"
        case "disney": return "Family favorites, plus Hulu"
        case "hulu": return "Current TV and originals"
        case "max": return "Prestige series and blockbusters"
        case "prime": return "Movies, series and live sports"
        default: return "Streaming"
        }
    }
}

@MainActor
enum HomeLayout {
    static func consoleColors(_ console: Console) -> [Color] {
        // Colors follow the catalog's order, so reordering Home doesn't recolor the cards.
        let i = ConsoleCatalog.make(from: AppConfigStore.shared.catalog.apps).firstIndex(of: console) ?? 0
        return Theme.consoleCards[i % Theme.consoleCards.count]
    }

    static func consoleItem(_ console: Console, count: Int) -> HomeItem {
        HomeItem(id: "console-" + console.id, title: console.name, subtitle: GameLibrary.countLabel(count),
                 symbol: "gamecontroller.fill", colors: consoleColors(console), action: .console(console),
                 artwork: Artwork.exists(console.id) ? console.id : nil,
                 tagline: count > 0 ? "Pick up where you left off" : "Add games to \(AppConfigStore.shared.gamesFolderText(for: console))")
    }

    /// Consoles that have games, then a card for the full list.
    static func playItems(_ consoles: [(Console, Int)]) -> [HomeItem] {
        consoles.filter { $0.1 > 0 }.map { consoleItem($0.0, count: $0.1) } + [
            HomeItem(id: "all-consoles", title: "All Consoles", subtitle: "\(consoles.count) systems",
                     symbol: "square.grid.3x3.fill", colors: Theme.neutralCard, action: .allConsoles,
                     tagline: "Every system, from the NES to the Switch"),
        ]
    }

    static func continueRow(_ entries: [ContinueEntry]) -> HomeRow {
        HomeRow(id: "continue", title: "Continue Watching", items: entries.compactMap { e in
            guard let details = e.details else { return nil }
            let pct = Int((e.item.progress * 100).rounded())
            return HomeItem(id: "continue-" + e.item.ratingKey, title: e.item.title, subtitle: e.item.detail,
                            symbol: "play.fill", colors: Theme.neutralCard, action: .resume(details),
                            imageURL: e.image, progress: e.item.progress, heroImageURL: e.backdrop ?? e.image,
                            cue: "Resume", tagline: pct > 0 ? "\(pct)% watched · Plex" : "Up next · Plex")
        })
    }

    /// Recently played games across every console.
    static func jumpBackRow(_ recent: [RecentGame]) -> HomeRow {
        HomeRow(id: "jump", title: "Jump Back In", items: recent.map { r in
            HomeItem(id: "game-\(r.console.id)-\(r.game.fileName)", title: r.title,
                     subtitle: r.console.name + " · " + (r.paused ? "Paused" : r.played.formatted(.relative(presentation: .named))),
                     symbol: "gamecontroller.fill", colors: consoleColors(r.console), action: .game(r.console, r.game),
                     artwork: Artwork.exists(r.console.id) ? r.console.id : nil, cue: r.paused ? "Resume" : "Play",
                     tagline: r.tagline, cardImage: r.card, heroImage: r.hero)
        })
    }

    /// `apps` are the config's apps in order (streams, native apps, Settings); `consoles` the config's consoles in order.
    static func rows(apps shown: [CatalogApp], services: [Service], consoles: [(Console, Int)], continueWatching: [ContinueEntry] = [],
                     recentGames: [RecentGame] = []) -> [HomeRow] {
        let apps = shown.compactMap { app -> HomeItem? in
            switch app.kind {
            case .stream, .native:
                guard let s = services.first(where: { $0.id == app.id }) else { return nil }
                return HomeItem(id: s.id, title: s.name, subtitle: "",
                                symbol: ServiceLook.symbol(s.id), colors: ServiceLook.colors(s.id),
                                style: .app, action: .stream(s), tagline: ServiceLook.tagline(s.id),
                                brand: app.brandColor.flatMap(RGB.init(hex:)))
            case .system where app.id == "settings":
                return HomeItem(id: "settings", title: "Settings", subtitle: "",
                                symbol: "gearshape.fill", colors: [Color(white: 0.34), Color(white: 0.16)],
                                style: .app, action: .settings, tagline: "Sound, controllers, start-up and power")
            default:
                return nil
            }
        }
        return [
            continueRow(continueWatching),
            jumpBackRow(recentGames),
            HomeRow(id: "apps", title: "Apps", items: apps),
            HomeRow(id: "play", title: "Play", items: playItems(consoles)),
        ]
    }
}

/// A connected remote or controller for the status bar.
struct InputDevice: Identifiable, Equatable {
    let id: String
    let symbol: String
    let battery: Int?       // percent, when the device reports it
}

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var rows: [HomeRow]
    @Published private(set) var focus: FocusGrid
    @Published var devices: [InputDevice] = []
    /// A short line over the bottom of the screen, e.g. "press again to…".
    @Published var notice: String?
    /// Quiet "Update available" line (UpdateNotice decides when); never a modal.
    @Published var updateNotice: String?

    init(rows: [HomeRow]) {
        let kept = rows.filter { !$0.items.isEmpty }
        self.rows = kept
        // Home always has the Apps row, so this cannot fail.
        self.focus = FocusGrid(rowLengths: kept.map(\.items.count))!
    }

    /// Refresh rows (Continue Watching, game counts); focus is kept, clamped.
    func update(rows newRows: [HomeRow]) {
        let kept = newRows.filter { !$0.items.isEmpty }
        guard let next = focus.resized(rowLengths: kept.map(\.items.count)) else { return }
        rows = kept
        focus = next
    }

    func move(_ d: Direction) { focus = focus.moved(d) }
    var focusedItem: HomeItem { rows[focus.row].items[focus.column] }
}

// MARK: - Geometry (design points; multiplied by the screen scale)

private enum HomeMetrics {
    static let heroTop: CGFloat = 120
    static let rowsTop: CGFloat = 556           // where the focused row's title sits
    static let rowTitle: CGFloat = 38
    static let landscape = CGSize(width: 384, height: 216)
    static let landscapeCaption: CGFloat = 70
    static let app = CGSize(width: TileLayout.width, height: TileLayout.height)
    static let gap: CGFloat = 40               // between cards
    static let rowGap: CGFloat = 54            // between rows

    static func cardSize(_ style: CardStyle) -> CGSize { style == .app ? app : landscape }

    static func rowHeight(_ row: HomeRow) -> CGFloat {
        let style = row.items.first?.style ?? .landscape
        return rowTitle + cardSize(style).height + (style == .app ? TileLayout.labelHeight : landscapeCaption)
    }
}

// MARK: - Views

struct HomeView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack(alignment: .topLeading) {
                HeroBackdrop(item: model.focusedItem, size: geo.size, s: s)
                HeroText(item: model.focusedItem, s: s)
                    .padding(.leading, DS.page * s).padding(.top, HomeMetrics.heroTop * s)
                    .frame(width: geo.size.width * 0.62, alignment: .leading)
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width, height: 220 * s)
                ScreenHeader(kind: .home, s: s, leading: { EmptyView() }, accessory: { devices(s) })
                    .frame(width: geo.size.width)
                rows(width: geo.size.width, s: s)
                    .offset(y: (HomeMetrics.rowsTop - rowsScroll) * s)
                    .animation(DS.slide, value: model.focus.row)
                if let notice = model.notice {
                    Text(notice)
                        .font(DS.ui(22, s, .semibold)).foregroundStyle(DS.text)
                        .padding(.horizontal, 30 * s).padding(.vertical, 16 * s)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 24 * s, y: 8 * s)
                        .frame(width: geo.size.width, height: geo.size.height - 56 * s, alignment: .bottom)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let line = model.updateNotice {
                    Text(line)
                        .font(DS.ui(18, s, .semibold)).foregroundStyle(DS.text2)
                        .padding(.horizontal, 22 * s).padding(.vertical, 10 * s)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                        .frame(width: geo.size.width - 2 * DS.page * s, height: geo.size.height - 56 * s, alignment: .bottomTrailing)
                        .padding(.leading, DS.page * s)
                        .transition(.opacity)
                }
            }
            .animation(DS.fade, value: model.notice)
            .animation(DS.fade, value: model.updateNotice)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(DS.canvas)
        .ignoresSafeArea()
    }

    /// How far the rows have slid up so the focused row sits at rowsTop.
    private var rowsScroll: CGFloat {
        model.rows.prefix(model.focus.row).reduce(0) { $0 + HomeMetrics.rowHeight($1) + HomeMetrics.rowGap }
    }

    private func rows(width: CGFloat, s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.rowGap * s) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { r, row in
                CardRow(row: row, rowIndex: r, focus: model.focus, width: width, s: s)
                    .opacity(r < model.focus.row ? 0 : (r == model.focus.row ? 1 : 0.78))
                    .animation(DS.fade, value: model.focus.row)
            }
        }
    }

    /// Connected controllers and remotes, before the shared header's clock.
    private func devices(_ s: CGFloat) -> some View {
        HStack(spacing: 18 * s) {
            ForEach(model.devices) { d in
                HStack(spacing: 6 * s) {
                    Image(systemName: d.symbol).font(.system(size: 24 * s, weight: .semibold))
                    if let b = d.battery { Text("\(b)%").font(DS.ui(17, s, .bold)).monospacedDigit() }
                }
                .foregroundStyle(d.battery.map { $0 <= 15 } == true ? Color.red : DS.text2)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(DS.fade, value: model.devices)
    }

    private func footer(_ s: CGFloat) -> some View {
        HStack(spacing: 26 * s) {
            Hint(keys: ["◀︎ ▶︎"], label: "Move", s: s)
            Hint(keys: ["Select"], label: "Open", s: s)
            Hint(keys: ["Back"], label: "Back", s: s)
            Hint(keys: ["Home"], label: "Home from anywhere", s: s)
        }
        .padding(.leading, DS.page * s).padding(.bottom, 30 * s)
    }
}

/// The focused item's art across the whole screen, darkened on the left for
/// the hero text and faded to the canvas at the bottom for the rows.
private struct HeroBackdrop: View {
    let item: HomeItem
    let size: CGSize
    let s: CGFloat
    /// The art slowly drifts and zooms, back and forth, so home never sits still.
    @State private var drift = false

    var body: some View {
        ZStack {
            DS.canvas
            Group {
                if let url = item.heroImageURL {
                    RemoteImage(url: url, cover: size)
                } else if let hero = item.heroImage ?? item.cardImage {
                    CoverImage(image: hero, size: size)
                } else if let name = item.artwork, let art = Artwork.image(name) {
                    CoverImage(image: art, size: size)
                } else {
                    // Apps and settings: a glow of their colors (the tile
                    // itself is drawn above the fades, below).
                    ZStack {
                        RadialGradient(colors: [item.colors.first?.opacity(0.75) ?? .clear, item.colors.last?.opacity(0.25) ?? .clear, DS.canvas],
                                       center: UnitPoint(x: 0.72, y: 0.3), startRadius: 0, endRadius: size.width * 0.55)
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            .scaleEffect(drift ? 1.07 : 1.0)
            .offset(x: drift ? -size.width * 0.012 : size.width * 0.008)
            .id(item.id)
            .transition(.opacity)
            // Text side and bottom fades.
            LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0), .init(color: .black.opacity(0.45), location: 0.42),
                                   .init(color: .clear, location: 0.75)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: DS.canvas.opacity(0.55), location: 0.42),
                                   .init(color: DS.canvas.opacity(0.94), location: 0.6), .init(color: DS.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            // Apps and settings: the product shot sits above the fades so it
            // keeps its full color.
            if item.style == .app {
                HeroTile(item: item, s: s)
                    .rotation3DEffect(.degrees(-16), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .offset(x: size.width * 0.21, y: -size.height * 0.1)
                    .id("tile-" + item.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(DS.fade, value: item.id)
        .onAppear { withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { drift = true } }
    }
}

/// The app tile's art drawn large for the hero's product shot (no name: the hero text carries it).
private struct HeroTile: View {
    let item: HomeItem
    let s: CGFloat

    var body: some View {
        let (w, h) = (620 * s, 372 * s)
        let shape = RoundedRectangle(cornerRadius: TileLayout.cornerRadius(tileWidth: w), style: .continuous)
        TileArt(item: item, size: CGSize(width: w, height: h))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 2 * s))
            .shadow(color: (item.colors.first ?? .black).opacity(0.55), radius: 60 * s, y: 30 * s)
    }
}

/// Title, details and the action cue for the focused item.
private struct HeroText: View {
    let item: HomeItem
    let s: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            Text(item.title)
                .font(DS.display(74, s))
                .foregroundStyle(DS.text)
                .lineLimit(2).minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 18 * s)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(DS.ui(26, s)).foregroundStyle(DS.text2).lineLimit(1)
            }
            if let tagline = item.tagline {
                Text(tagline).font(DS.ui(20, s, .medium)).foregroundStyle(DS.text3).lineLimit(2)
            }
            HStack(spacing: 14 * s) {
                Label(item.cue, systemImage: item.cue == "Open" ? "arrow.up.forward" : "play.fill")
                    .font(DS.ui(20, s, .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22 * s).padding(.vertical, 11 * s)
                    .background(Capsule().fill(.white))
                if let p = item.progress, p > 0 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white).frame(width: 180 * s * p)
                    }
                    .frame(width: 180 * s, height: 6 * s)
                }
                if item.hasDetails { DetailsCue(s: s) }
            }
            .padding(.top, 8 * s)
        }
        .id(item.id)
        .transition(.opacity.combined(with: .offset(y: 8 * s)))
        .animation(.easeOut(duration: 0.3), value: item.id)
    }
}

private struct CardRow: View {
    let row: HomeRow
    let rowIndex: Int
    let focus: FocusGrid
    let width: CGFloat
    let s: CGFloat

    private var focusedColumn: Int { focus.row == rowIndex ? focus.column : 0 }
    private var style: CardStyle { row.items.first?.style ?? .landscape }

    var body: some View {
        let card = HomeMetrics.cardSize(style)
        VStack(alignment: .leading, spacing: 14 * s) {
            Text(row.title)
                .font(DS.ui(24, s, .bold))
                .foregroundStyle(focus.row == rowIndex ? DS.text : DS.text2)
                .padding(.leading, DS.page * s)
            HStack(alignment: .top, spacing: HomeMetrics.gap * s) {
                ForEach(Array(row.items.enumerated()), id: \.element.id) { c, item in
                    let focused = focus.row == rowIndex && focus.column == c
                    if item.style == .app {
                        AppTile(item: item, focused: focused, size: card, s: s)
                    } else {
                        LandscapeCard(item: item, focused: focused, size: card, s: s)
                    }
                }
            }
            .padding(.leading, DS.page * s)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: -RowSlide.offset(focusedColumn: focusedColumn, step: (card.width + HomeMetrics.gap) * s))
            .frame(width: width, alignment: .leading)
            .animation(DS.slide, value: focusedColumn)
        }
    }
}

/// Wide art with title and subtitle underneath (tvOS "Up Next" style).
struct LandscapeCard: View {
    let item: HomeItem
    let focused: Bool
    let size: CGSize
    let s: CGFloat

    var body: some View {
        let w = size.width * s, h = size.height * s
        let shape = RoundedRectangle(cornerRadius: DS.cardRadius * s, style: .continuous)
        VStack(alignment: .leading, spacing: 12 * s) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: item.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let url = item.imageURL {
                    RemoteImage(url: url, cover: CGSize(width: w, height: h))
                } else if let card = item.cardImage {
                    CoverImage(image: card, size: CGSize(width: w, height: h))
                } else if let name = item.artwork, let art = Artwork.image(name) {
                    CoverImage(image: art, size: CGSize(width: w, height: h))
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 72 * s, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: w, height: h)
                }
                if let p = item.progress, p > 0 {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.28))
                        Capsule().fill(.white).frame(width: (w - 36 * s) * p)
                    }
                    .frame(width: w - 36 * s, height: 5 * s)
                    .padding(18 * s)
                }
            }
            .frame(width: w, height: h)
            .clipShape(shape)
            .focusLift(focused, radius: DS.cardRadius * s, s: s)
            VStack(alignment: .leading, spacing: 3 * s) {
                Text(item.title).font(DS.ui(21, s, .bold)).foregroundStyle(focused ? DS.text : DS.text2).lineLimit(1)
                Text(item.subtitle).font(DS.ui(16, s, .medium)).foregroundStyle(DS.text3).lineLimit(1)
            }
            .frame(width: w, alignment: .leading)
            .offset(y: focused ? 14 * s : 0)
            .animation(DS.focusSpring, value: focused)
        }
    }
}

private struct Hint: View {
    let keys: [String]
    let label: String
    let s: CGFloat

    var body: some View {
        HStack(spacing: 8 * s) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(DS.ui(14, s, .bold))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 9 * s).padding(.vertical, 4 * s)
                    .background(Capsule().fill(.white.opacity(0.09)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            Text(label).font(DS.ui(15, s, .medium)).foregroundStyle(DS.text3)
        }
    }
}
