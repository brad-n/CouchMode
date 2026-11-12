// Owns: a title's details screen: hero art behind a dark gradient, name,
// facts, synopsis, where it stands, the Play / Resume and "Open on <service>"
// buttons and, for shows, season tabs with a row of episode tiles that
// slides with focus. State and reader calls are StreamDetailModel's.

import SwiftUI
import CouchModeCore

struct StreamDetailView: View {
    @ObservedObject var model: StreamDetailModel

    private enum Metrics {
        static let top: CGFloat = 110
        static let episodeWidth: CGFloat = 300
        static let episodeHeight: CGFloat = 169
        static let episodeGap: CGFloat = 24
        static let episodeInset: CGFloat = 22
        static let captionHeight: CGFloat = 64
    }

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack(alignment: .topLeading) {
                StreamBackdrop(url: model.title.heroArt ?? model.title.tileArt, size: geo.size)
                VStack(alignment: .leading, spacing: 26 * s) {
                    Spacer().frame(height: Metrics.top * s)
                    StreamHeroText(title: model.title, s: s)
                    buttons(s)
                    if !model.seasons.isEmpty { seasonTabs(s) }
                    if !model.seasons.isEmpty || !model.episodes.isEmpty { episodes(s, width: geo.size.width) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, StreamLayout.page * s)
                ClockBadge(scale: s).frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, StreamLayout.page * s).padding(.top, 40 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .animation(DS.fade, value: model.title)
        }
        .ignoresSafeArea()
    }

    private func buttons(_ s: CGFloat) -> some View {
        HStack(spacing: 22 * s) {
            ForEach(Array(model.buttons.enumerated()), id: \.offset) { i, button in
                StreamPill(text: model.label(for: button), symbol: button == .play ? "play.fill" : "arrow.up.right",
                           focused: model.focus.target == .button(i), s: s)
            }
        }
        .padding(.top, 6 * s)
    }

    private func seasonTabs(_ s: CGFloat) -> some View {
        HStack(spacing: 14 * s) {
            ForEach(Array(model.seasons.enumerated()), id: \.element.id) { i, season in
                let focused = model.focus.target == .season(i)
                let shown = model.focus.season == i
                Text(season.name).font(DS.ui(21, s, .bold))
                    .foregroundStyle(focused ? Color.black : (shown ? DS.text : DS.text2))
                    .padding(.horizontal, 24 * s).padding(.vertical, 10 * s)
                    .background(Capsule().fill(focused ? Color.white : (shown ? DS.surfaceStrong : Color.clear)))
                    .scaleEffect(focused ? 1.06 : 1)
                    .animation(DS.focusSpring, value: focused)
            }
        }
        .animation(DS.focusSpring, value: model.focus.season)
    }

    private func episodes(_ s: CGFloat, width: CGFloat) -> some View {
        let eps = model.episodes
        var focusedIndex: Int? = nil
        if case .episode(let i) = model.focus.target { focusedIndex = i }
        let column = focusedIndex ?? 0
        let step = (Metrics.episodeWidth + Metrics.episodeGap) * s
        let window = StreamFocus.visibleWindow(count: eps.count, focusedColumn: column)
        let height = (Metrics.episodeHeight + Metrics.captionHeight + Metrics.episodeInset * 2) * s
        return ZStack(alignment: .leading) {
            ForEach(window, id: \.self) { i in
                episodeTile(eps[i], focused: focusedIndex == i, s: s)
                    .offset(x: CGFloat(i) * step - RowSlide.offset(focusedColumn: column, step: step))
            }
            if eps.isEmpty {
                Text(model.episodesLoading ? "Loading episodes…" : "No episodes to show")
                    .font(DS.ui(22, s, .medium)).foregroundStyle(DS.text3)
            }
        }
        .frame(width: width - StreamLayout.page * s, height: height, alignment: .leading)
        .animation(DS.slide, value: column)
    }

    private func episodeTile(_ ep: StreamEpisode, focused: Bool, s: CGFloat) -> some View {
        let size = CGSize(width: Metrics.episodeWidth * s, height: Metrics.episodeHeight * s)
        let progress: Double? = {
            guard let r = ep.resumeSeconds, let t = ep.runtimeSeconds, t > 0, r > 0 else { return nil }
            return min(1, Double(r) / Double(t))
        }()
        return VStack(alignment: .leading, spacing: 10 * s) {
            StreamArt(url: ep.art, name: ep.number.map { "Episode \($0)" } ?? ep.name, size: size, s: s)
                .overlay(alignment: .bottom) {
                    if let progress { StreamProgressBar(value: progress, width: size.width - 28 * s, s: s).padding(.bottom, 10 * s) }
                }
                .clipShape(RoundedRectangle(cornerRadius: StreamLayout.tileRadius * s, style: .continuous))
                .focusLift(focused, radius: StreamLayout.tileRadius * s, s: s, amount: 1.08)
            VStack(alignment: .leading, spacing: 2 * s) {
                Text([ep.number.map { "\($0)." }, ep.name].compactMap { $0 }.joined(separator: " "))
                    .font(DS.ui(20, s, .bold)).foregroundStyle(focused ? DS.text : DS.text2).lineLimit(1)
                if let runtime = ep.runtimeSeconds.flatMap({ StreamFacts.runtimeText(seconds: $0) }) {
                    Text(runtime).font(DS.ui(17, s, .medium)).foregroundStyle(DS.text3)
                }
            }
            .frame(width: size.width, height: Metrics.captionHeight * s, alignment: .topLeading)
        }
    }
}
