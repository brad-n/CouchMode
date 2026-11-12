// Owns: the idle screensaver: a slow Ken Burns slideshow of the shell's own
// artwork (Continue Watching backdrops, console art) with the title of each
// slide and a large clock. The coordinator decides when it shows.

import AppKit
import SwiftUI

struct ScreensaverSlide: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    var url: URL? = nil
    var image: NSImage? = nil
}

struct ScreensaverView: View {
    let slides: [ScreensaverSlide]
    private static let slideSeconds: Double = 10

    @State private var index = 0
    @State private var now = Date()
    private let tick = Timer.publish(every: ScreensaverView.slideSeconds, on: .main, in: .common).autoconnect()
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let slide = current {
                    KenBurns(slide: slide, size: geo.size, seconds: Self.slideSeconds + 2)
                        .id(slide.id + "-\(index)")
                        .transition(.opacity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    if let slide = current {
                        VStack(alignment: .leading, spacing: 6 * s) {
                            Text(slide.title).font(DS.display(44, s, .bold)).foregroundStyle(.white)
                            Text(slide.subtitle).font(DS.ui(20, s, .medium)).foregroundStyle(.white.opacity(0.7))
                        }
                        .id("text-\(index)").transition(.opacity)
                    }
                    Spacer()
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 96 * s, weight: .thin, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.horizontal, DS.page * s).padding(.bottom, 70 * s)
                .shadow(color: .black.opacity(0.6), radius: 16 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onReceive(tick) { _ in
            guard !slides.isEmpty else { return }
            withAnimation(.easeInOut(duration: 1.8)) { index = (index + 1) % slides.count }
        }
        .onReceive(clock) { now = $0 }
    }

    private var current: ScreensaverSlide? { slides.isEmpty ? nil : slides[index % slides.count] }
}

/// One slide: slowly zooms and drifts for its whole time on screen.
private struct KenBurns: View {
    let slide: ScreensaverSlide
    let size: CGSize
    let seconds: Double
    @State private var moving = false

    var body: some View {
        Group {
            if let url = slide.url { RemoteImage(url: url, cover: size) }
            else if let image = slide.image { CoverImage(image: image, size: size) }
        }
        .scaleEffect(moving ? 1.14 : 1.0)
        .offset(x: moving ? -size.width * 0.025 : size.width * 0.02, y: moving ? -size.height * 0.015 : 0)
        .onAppear { withAnimation(.linear(duration: seconds)) { moving = true } }
    }
}
