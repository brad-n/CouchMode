// Owns: the Apps row tile, tvOS home-screen style: the app's own landscape
// art edge to edge with no name inside, a name that appears below the focused
// tile, and the focus treatment (lift, soft shadow, parallax tilt, specular
// sheen). Also TileArt, the art alone, which the hero reuses. What art a
// service has is ServiceIcons'; the tile math is Core's TileLayout.

import AppKit
import SwiftUI
import CouchModeCore

/// The art of an app tile, full bleed: the service's tvOS app icon; else its
/// logo large and centered on a background of its own edge color; else a
/// system-style tile (soft gray, one large symbol, no text).
struct TileArt: View {
    @ObservedObject private var icons = ServiceIcons.shared
    let item: HomeItem
    let size: CGSize

    private var isService: Bool {
        if case .stream = item.action { return true }
        return false
    }

    var body: some View {
        ZStack {
            if DemoMode.isOn, isService, let demo = DemoArtRenderer.image(DemoArtSpec(kind: .hero, title: item.title)) {
                CoverImage(image: demo, size: size)
            } else if isService, let art = icons.tileArt(for: item.id) {
                CoverImage(image: art, size: size)
            } else if isService, let logo = icons.image(for: item.id) {
                logoTile(logo)
            } else {
                systemTile
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func logoTile(_ logo: NSImage) -> some View {
        let edge = icons.edgeColor(for: item.id) ?? item.brand
        let bg = edge.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? item.colors.first ?? .gray
        let r = TileLayout.logoRect(logo: (logo.size.width, logo.size.height), tile: (size.width, size.height), fraction: 0.56)
        return ZStack {
            bg
            LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.16)], startPoint: .top, endPoint: .bottom)
            if let r {
                Image(nsImage: logo).resizable().interpolation(.high)
                    .frame(width: r.w, height: r.h)
                    .shadow(color: .black.opacity(0.28), radius: size.height * 0.04, y: size.height * 0.02)
            }
        }
    }

    private var systemTile: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.46), Color(white: 0.24)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
            Image(systemName: item.symbol)
                .font(.system(size: size.height * 0.4, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: size.height * 0.03, y: size.height * 0.015)
        }
    }
}

struct AppTile: View {
    let item: HomeItem
    let focused: Bool
    let size: CGSize
    let s: CGFloat

    /// Slowly sweeps the focus "pointer" across the tile while it is focused, so the tilt and sheen keep moving.
    @State private var drift = false

    private var pointer: (x: Double, y: Double) {
        guard focused else { return (0, 0) }
        return drift ? (0.8, -0.5) : (-0.8, 0.5)
    }

    var body: some View {
        let w = size.width * s, h = size.height * s
        let shape = RoundedRectangle(cornerRadius: TileLayout.cornerRadius(tileWidth: w), style: .continuous)
        let tilt = TileLayout.tilt(pointerX: pointer.x, pointerY: pointer.y)
        let sheen = TileLayout.sheenCenter(pointerX: pointer.x, pointerY: pointer.y)
        ZStack(alignment: .top) {
            TileArt(item: item, size: CGSize(width: w, height: h))
                .overlay(
                    RadialGradient(colors: [.white.opacity(0.3), .clear], center: UnitPoint(x: sheen.x, y: sheen.y),
                                   startRadius: 0, endRadius: w * 0.55)
                        .opacity(focused ? 1 : 0)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(focused ? 0.22 : 0.07), lineWidth: 1))
                .rotation3DEffect(.degrees(tilt.aroundY), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(tilt.aroundX), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .shadow(color: .black.opacity(focused ? 0.55 : 0.22), radius: (focused ? 30 : 8) * s, y: (focused ? 20 : 5) * s)
                .scaleEffect(focused ? TileLayout.focusScale : 1)
                .animation(DS.focusSpring, value: focused)
            Text(item.title)
                .font(.system(size: 29 * s, weight: .medium))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .frame(width: w)
                .padding(.top, h * (1 + (TileLayout.focusScale - 1) / 2) + 16 * s)
                .opacity(focused ? 1 : 0)
                .animation(DS.focusSpring, value: focused)
        }
        .frame(width: w, height: (size.height + TileLayout.labelHeight) * s, alignment: .top)
        .zIndex(focused ? 1 : 0)
        .onChange(of: focused) { _, now in
            if now {
                drift = false
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { drift = true }
            } else {
                withAnimation(DS.focusSpring) { drift = false }
            }
        }
    }
}
