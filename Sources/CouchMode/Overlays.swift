// Owns: the shell's full-screen interstitials (opening a streaming service,
// starting a game or app) and small shared chrome. Pure
// presentation; the coordinator decides when they show.

import AppKit
import SwiftUI
import CouchModeCore

/// The one loading / launch view: an item's art blurred behind a large title
/// and a slim animated progress bar. "Opening Netflix…", "Starting Kirby…",
/// and a stream screen while its reader works all use it.
struct InterstitialView: View {
    let title: String
    let subtitle: String
    let colors: [Color]
    var icon: NSImage? = nil
    var artwork: String? = nil
    /// Draws the shared header (the clock) over the card, as a stream screen's
    /// loading state does; launch cards cover the whole screen without it.
    var header: ScreenKind? = nil
    /// 0...1 fills the bar (a download); nil keeps the sweeping indeterminate bar.
    var progress: Double? = nil
    /// Result screens (an answer, not work in progress) leave the bar out.
    var showsBar = true
    /// A few short lines under the subtitle (an update's notes).
    var detail: String? = nil
    /// Remote-driven buttons under the card, `focusedButton` highlighted.
    var buttons: [String] = []
    var focusedButton = 0

    @State private var phase: CGFloat = -1

    /// A hairline track: a sweeping segment while the wait has no end in sight, a fill once progress is known.
    private func bar(s: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.14))
            if let progress {
                Capsule().fill(.white.opacity(0.9)).frame(width: 320 * s * max(0.02, min(1, progress)))
            } else {
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: 90 * s)
                    .offset(x: (phase + 1) / 2 * (320 - 90) * s)
            }
        }
        .frame(width: 320 * s, height: 4 * s)
        .clipShape(Capsule())
    }

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
                    if let detail, !detail.isEmpty {
                        Text(detail).font(DS.ui(24, s, .medium)).foregroundStyle(DS.text)
                            .multilineTextAlignment(.center).lineLimit(6)
                            .frame(maxWidth: 900 * s).padding(.top, 8 * s)
                    }
                    if showsBar { bar(s: s).padding(.top, 14 * s) }
                    if !buttons.isEmpty {
                        HStack(spacing: 24 * s) {
                            ForEach(Array(buttons.enumerated()), id: \.offset) { i, label in
                                let focused = i == focusedButton
                                Text(label).font(DS.ui(28, s, .bold))
                                    .foregroundStyle(focused ? Color.black : DS.text)
                                    .padding(.horizontal, 48 * s).padding(.vertical, 18 * s)
                                    .background(Capsule().fill(focused ? Color.white : DS.surfaceStrong))
                                    .scaleEffect(focused ? 1.08 : 1)
                                    .animation(DS.focusSpring, value: focusedButton)
                            }
                        }
                        .padding(.top, 20 * s)
                    }
                }
                if let header { ScreenHeader(header, s: s).pinnedToTop() }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 } }
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
