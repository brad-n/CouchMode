// Owns: the shell's full-screen interstitials (opening a streaming service,
// starting a game or app) and small shared chrome (the clock badge). Pure
// presentation; the coordinator decides when they show.

import AppKit
import SwiftUI

/// "Opening Netflix…" / "Starting Kirby…": the item's art blurred behind a
/// large title and a slim animated progress bar.
struct InterstitialView: View {
    let title: String
    let subtitle: String
    let colors: [Color]
    var icon: NSImage? = nil
    var artwork: String? = nil

    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack {
                DS.canvas
                if let name = artwork, let art = Artwork.image(name) {
                    CoverImage(image: art, size: geo.size).blur(radius: 50 * s).opacity(0.55)
                } else if let icon {
                    CoverImage(image: icon, size: geo.size).blur(radius: 80 * s).opacity(0.45)
                }
                RadialGradient(colors: [(colors.first ?? DS.accent).opacity(0.5), .clear],
                               center: .center, startRadius: 0, endRadius: geo.size.width * 0.45)
                Color.black.opacity(0.25)
                VStack(spacing: 24 * s) {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .frame(width: 200 * s, height: 200 * s)
                            .shadow(color: .black.opacity(0.55), radius: 30 * s, y: 16 * s)
                    }
                    Text(title).font(DS.display(64, s)).foregroundStyle(DS.text)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 120 * s)
                    Text(subtitle).font(DS.ui(22, s, .medium)).foregroundStyle(DS.text2)
                    // Indeterminate progress: a bright segment sweeping a hairline track.
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(.white.opacity(0.9))
                            .frame(width: 90 * s)
                            .offset(x: (phase + 1) / 2 * (320 - 90) * s)
                    }
                    .frame(width: 320 * s, height: 4 * s)
                    .clipShape(Capsule())
                    .padding(.top, 14 * s)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 } }
    }
}

/// Time at the top right of every screen, like Apple TV's status area.
struct ClockBadge: View {
    let scale: CGFloat
    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 34 * scale, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary.opacity(0.9))
            .shadow(color: .black.opacity(0.5), radius: 8 * scale)
            .onReceive(tick) { now = $0 }
    }
}

/// App icons for games that are their own Mac apps (Switch builds), cached.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ url: URL) -> NSImage {
        if let hit = cache[url.path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 512, height: 512)
        cache[url.path] = image
        return image
    }
}
