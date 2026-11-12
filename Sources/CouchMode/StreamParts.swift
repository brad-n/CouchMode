// Owns: the pieces the stream home and details screens share: layout
// constants, a title's tile (art or a placeholder, progress, rank), the
// backdrop under a dark gradient, the hero text block, a pill button and the
// loading state. Pure presentation, DS tokens only.

import SwiftUI
import CouchModeCore

/// Design points at 1080 tall (multiplied by the screen scale).
enum StreamLayout {
    static let tileWidth: CGFloat = 340
    static let tileHeight: CGFloat = 191
    static let tileGap: CGFloat = 26
    static let tileStep: CGFloat = tileWidth + tileGap
    static let tileRadius: CGFloat = 16
    static let page: CGFloat = DS.page
    static let synopsisWidth: CGFloat = 900
    static let progressHeight: CGFloat = 6
    static let progressWidth: CGFloat = 320
}

/// A 16:9 image that covers its frame, or the name on a surface when there is no art.
struct StreamArt: View {
    let url: URL?
    let name: String
    let size: CGSize
    let s: CGFloat

    var body: some View {
        ZStack {
            DS.surface
            LinearGradient(colors: [DS.surfaceStrong, DS.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(name).font(DS.ui(22, s, .bold)).foregroundStyle(DS.text2)
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                .padding(.horizontal, 22 * s)
            if let url { RemoteImage(url: url, cover: size) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

struct StreamProgressBar: View {
    let value: Double
    let width: CGFloat
    let s: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(DS.accent).frame(width: width * CGFloat(min(1, max(0, value))))
        }
        .frame(width: width, height: StreamLayout.progressHeight * s)
    }
}

/// A title's tile in a row: art, a progress bar when partly watched, a rank number in a chart.
struct StreamTile: View {
    let title: StreamTitle
    var rank: Int? = nil
    let focused: Bool
    let s: CGFloat

    var body: some View {
        let size = CGSize(width: StreamLayout.tileWidth * s, height: StreamLayout.tileHeight * s)
        StreamArt(url: title.tileArt, name: title.name, size: size, s: s)
            .overlay(alignment: .bottom) {
                if let progress = title.progress {
                    StreamProgressBar(value: progress, width: size.width - 28 * s, s: s).padding(.bottom, 12 * s)
                }
            }
            .overlay(alignment: .topLeading) {
                if let label = title.episodeLabel {
                    Text(label).font(DS.ui(18, s, .bold)).foregroundStyle(DS.text)
                        .padding(.horizontal, 10 * s).padding(.vertical, 4 * s)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .padding(10 * s)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let rank {
                    Text("\(rank)").font(DS.display(84, s)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 12 * s).padding(.leading, 14 * s).padding(.bottom, 2 * s)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StreamLayout.tileRadius * s, style: .continuous))
            .focusLift(focused, radius: StreamLayout.tileRadius * s, s: s, amount: 1.1)
    }
}

/// The hero art filling the screen under a dark gradient (the page's canvas shows without art).
struct StreamBackdrop: View {
    let url: URL?
    let size: CGSize

    var body: some View {
        ZStack {
            DS.canvas
            if let url { RemoteImage(url: url, cover: size).transition(.opacity) }
            LinearGradient(stops: [.init(color: DS.canvas.opacity(0.95), location: 0), .init(color: DS.canvas.opacity(0.55), location: 0.5),
                                   .init(color: DS.canvas.opacity(0.2), location: 1)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, DS.canvas.opacity(0.7), DS.canvas], startPoint: .center, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(DS.fade, value: url)
    }
}

/// Name, facts, where the show or film stands, and the synopsis.
struct StreamHeroText: View {
    let title: StreamTitle
    var showSynopsis = true
    let s: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            Text(title.name).font(DS.display(66, s)).foregroundStyle(DS.text)
                .lineLimit(2).minimumScaleFactor(0.6).shadow(color: .black.opacity(0.5), radius: 12 * s)
            let facts = StreamFacts.line(for: title)
            if !facts.isEmpty { Text(facts).font(DS.ui(24, s, .medium)).foregroundStyle(DS.text2) }
            if let remaining = title.remainingText {
                HStack(spacing: 16 * s) {
                    if let progress = title.progress { StreamProgressBar(value: progress, width: StreamLayout.progressWidth * s, s: s) }
                    Text(remaining)
                        .font(DS.ui(21, s, .semibold)).foregroundStyle(DS.text)
                }
            }
            if showSynopsis, let synopsis = title.synopsis, !synopsis.isEmpty {
                Text(synopsis).font(DS.ui(22, s, .regular)).foregroundStyle(DS.text2)
                    .lineLimit(3).frame(maxWidth: StreamLayout.synopsisWidth * s, alignment: .leading)
            }
        }
    }
}

/// A capsule button, white when focused (as on a game's details).
struct StreamPill: View {
    let text: String
    let symbol: String
    let focused: Bool
    let s: CGFloat

    var body: some View {
        Label(text, systemImage: symbol)
            .font(DS.ui(24, s, .bold))
            .foregroundStyle(focused ? .black : DS.text)
            .padding(.horizontal, 36 * s).padding(.vertical, 15 * s)
            .background(Capsule().fill(focused ? Color.white : DS.surfaceStrong))
            .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 20 * s, y: 10 * s)
            .scaleEffect(focused ? 1.08 : 1)
            .animation(DS.focusSpring, value: focused)
    }
}

/// "Loading <service>" while a reader works: a name and a soft pulse.
struct StreamLoading: View {
    let text: String
    let s: CGFloat
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22 * s) {
            Circle().fill(DS.accent).frame(width: 18 * s, height: 18 * s).scaleEffect(pulse ? 1.5 : 0.8).opacity(pulse ? 0.35 : 1)
            Text(text).font(DS.ui(26, s, .semibold)).foregroundStyle(DS.text2)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}
