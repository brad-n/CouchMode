// Owns: the details screen for a Continue Watching item: its full-screen
// backdrop, title, episode, year / rating / time left, the synopsis and a
// Resume button with progress. Resuming is the coordinator's job.

import SwiftUI
import CouchModeCore

struct PlexDetailView: View {
    let entry: ContinueEntry

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            let item = entry.item
            ZStack(alignment: .topLeading) {
                DS.canvas
                if let url = entry.backdrop ?? entry.image { RemoteImage(url: url, cover: geo.size) }
                LinearGradient(stops: [.init(color: .black.opacity(0.88), location: 0), .init(color: .black.opacity(0.55), location: 0.45),
                                       .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, DS.canvas.opacity(0.85)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 20 * s) {
                    Spacer()
                    Text("PLEX").font(DS.ui(18, s, .heavy)).tracking(4 * s).foregroundStyle(DS.accent)
                    Text(item.title).font(DS.display(78, s)).foregroundStyle(DS.text)
                        .lineLimit(2).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.5), radius: 18 * s)
                    // Episodes show "S2 · E5 · Title"; a movie's detail is just its year, already in the line below.
                    if !item.detail.isEmpty, item.detail != item.year.map(String.init) {
                        Text(item.detail).font(DS.ui(28, s, .semibold)).foregroundStyle(DS.text).lineLimit(1)
                    }
                    Text(meta(item)).font(DS.ui(22, s, .medium)).foregroundStyle(DS.text2)
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary).font(DS.ui(22, s, .regular)).foregroundStyle(DS.text2)
                            .lineLimit(5).frame(maxWidth: 980 * s, alignment: .leading)
                    }
                    HStack(spacing: 22 * s) {
                        Label(item.progress > 0 ? "Resume" : "Play", systemImage: "play.fill")
                            .font(DS.ui(24, s, .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 40 * s).padding(.vertical, 16 * s)
                            .background(Capsule().fill(.white))
                            .shadow(color: .black.opacity(0.5), radius: 20 * s, y: 10 * s)
                        if item.progress > 0 {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.22))
                                Capsule().fill(.white).frame(width: 260 * s * item.progress)
                            }
                            .frame(width: 260 * s, height: 7 * s)
                        }
                    }
                    .padding(.top, 10 * s)
                    Spacer().frame(height: 110 * s)
                }
                .padding(.horizontal, DS.page * s)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                ClockBadge(scale: s).padding(.trailing, DS.page * s)
                    .frame(width: geo.size.width, alignment: .trailing).padding(.top, 56 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private func meta(_ item: ContinueItem) -> String {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        if let r = item.contentRating { parts.append(r) }
        if let left = item.remainingText { parts.append(left) }
        return parts.joined(separator: "  •  ")
    }
}
