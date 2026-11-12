// Owns: a game's details screen (SwitchTV's DetailView design): the banner
// behind the split gradient, title, publisher / date / players, genre
// badges, the description, a Play button and a row of screenshots. A paused
// game's Play reads Resume, with Close Game beside it (as a Switch closes
// software). Focus is a button or one of the screenshots below them.
// Launching and closing are the coordinator's job.

import AppKit
import SwiftUI
import CouchModeCore

@MainActor
final class GameDetailModel: ObservableObject {
    let console: ConsoleModel
    let game: Game
    let info: CatalogGame?
    /// Open in the background: Play resumes it, and it can be closed here.
    let paused: Bool
    @Published private(set) var focus: DetailFocus = .play
    /// e.g. "Press again to close…".
    @Published var message: String?

    init(console: ConsoleModel, game: Game, paused: Bool = false) {
        self.console = console
        self.game = game
        self.info = console.info(game)
        self.paused = paused
    }

    var screenshots: [URL] { (info?.screenshots ?? []).compactMap(URL.init(string:)).prefix(8).map { $0 } }

    var focusedScreenshot: Int? { if case .screenshot(let i) = focus { return i } else { return nil } }

    func move(_ d: Direction) { focus = focus.moved(d, paused: paused, screenshots: screenshots.count) }
}

struct GameDetailView: View {
    @ObservedObject var model: GameDetailModel

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack(alignment: .topLeading) {
                GameTheme.background
                if let url = model.console.appURL(model.game), let banner = GameArt.banner(url) {
                    CoverImage(image: banner, size: CGSize(width: geo.size.width, height: geo.size.height * 0.85))
                } else if let art = Artwork.image(model.console.console.id) {
                    CoverImage(image: art, size: CGSize(width: geo.size.width, height: geo.size.height * 0.85))
                }
                GameTheme.split.opacity(0.92)
                LinearGradient(colors: [.clear, GameTheme.background.opacity(0.85), GameTheme.background],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 22 * s) {
                    Spacer().frame(height: 110 * s)
                    Text(model.info?.name ?? model.game.title)
                        .font(DS.display(70, s)).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.6)
                    Text(meta).font(DS.ui(24, s, .medium)).foregroundStyle(.white.opacity(0.7))
                    if let genres = model.info?.genres, !genres.isEmpty {
                        HStack(spacing: 12 * s) {
                            ForEach(genres, id: \.self) { g in
                                Text(g).font(DS.ui(17, s, .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 16 * s).padding(.vertical, 6 * s)
                                    .background(Capsule().fill(GameTheme.accent.opacity(0.85)))
                            }
                        }
                    }
                    if let blurb = model.info?.blurb {
                        Text(blurb).font(DS.ui(21, s, .regular)).foregroundStyle(.white.opacity(0.72))
                            .lineLimit(6).frame(maxWidth: 1050 * s, alignment: .leading)
                    }
                    HStack(spacing: 22 * s) {
                        button(model.paused ? "Resume" : "Play", symbol: "play.fill", focused: model.focus == .play, s: s)
                        if model.paused {
                            button("Close Game", symbol: "xmark", focused: model.focus == .close, s: s)
                        }
                    }
                    .padding(.top, 8 * s)
                    if let message = model.message {
                        Text(message).font(DS.ui(19, s, .semibold)).foregroundStyle(GameTheme.accent)
                    }
                    if !model.screenshots.isEmpty { screenshots(s, width: geo.size.width) }
                }
                .padding(.horizontal, GameTheme.pagePadding * s)
                ScreenHeader(.gameDetail, s: s).pinnedToTop()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private var meta: String {
        var parts = [model.info?.publisher, model.info?.releaseText, model.info?.playersText].compactMap { $0 }
        if let size = SizeText.of(model.game.sizeBytes) { parts.append(size) }
        if parts.isEmpty { parts.append(model.console.console.name) }
        return parts.joined(separator: "  •  ")
    }

    private func button(_ title: String, symbol: String, focused: Bool, s: CGFloat) -> some View {
        Label(title, systemImage: symbol)
            .font(DS.ui(24, s, .bold))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, 40 * s).padding(.vertical, 16 * s)
            .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.15)))
            .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 20 * s, y: 10 * s)
            .scaleEffect(focused ? 1.08 : 1)
            .animation(DS.focusSpring, value: focused)
    }

    private func screenshots(_ s: CGFloat, width: CGFloat) -> some View {
        let w: CGFloat = 480, h: CGFloat = 270
        return VStack(alignment: .leading, spacing: 12 * s) {
            Text("Screenshots").font(DS.ui(22, s, .bold)).foregroundStyle(.white.opacity(model.focusedScreenshot != nil ? 1 : 0.6))
            HStack(spacing: 28 * s) {
                ForEach(Array(model.screenshots.enumerated()), id: \.offset) { i, url in
                    let focused = model.focus == .screenshot(i)
                    ZStack {
                        GameTheme.surface
                        Image(systemName: "photo").font(.system(size: 40 * s)).foregroundStyle(.white.opacity(0.25))
                        RemoteImage(url: url, cover: CGSize(width: w * s, height: h * s))
                    }
                    .frame(width: w * s, height: h * s)
                    .clipShape(RoundedRectangle(cornerRadius: 14 * s, style: .continuous))
                    .focusLift(focused, radius: 14 * s, s: s, amount: 1.08)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 18 * s)
            .offset(x: -RowSlide.offset(focusedColumn: model.focusedScreenshot ?? 0, step: (w + 28) * s))
            .frame(width: width - GameTheme.pagePadding * s, alignment: .leading)
            .animation(DS.slide, value: model.focus)
        }
    }
}
