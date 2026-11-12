// Owns: the shell's design tokens (color, type, spacing, radii, motion) and
// the shared focus treatment. Everything is designed on a 1920x1080 canvas
// and scaled to the real screen height, so it reads the same from the couch
// on any TV. Screens use these instead of their own literals.

import AppKit
import SwiftUI

enum DS {
    // MARK: Color — near-black canvas, glass surfaces, one warm accent.
    static let canvas = Color(red: 0.027, green: 0.027, blue: 0.031)
    static let surface = Color.white.opacity(0.07)
    static let surfaceStrong = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.10)
    static let text = Color.white
    static let text2 = Color.white.opacity(0.66)
    static let text3 = Color.white.opacity(0.42)
    static let accent = Color(red: 0.98, green: 0.76, blue: 0.44)

    // MARK: Type — SF Pro Display for titles, SF Pro Rounded for UI labels.
    static func display(_ size: CGFloat, _ s: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size * s, weight: weight, design: .default)
    }
    static func ui(_ size: CGFloat, _ s: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size * s, weight: weight, design: .rounded)
    }

    // MARK: Layout (design points at 1080 tall)
    static let page: CGFloat = 96
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 24

    // MARK: Motion
    static let focusSpring = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let slide = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let fade = Animation.easeInOut(duration: 0.45)

    /// Scale for the screen: designed at 1080 points tall.
    static func scale(_ size: CGSize) -> CGFloat { max(0.6, size.height / 1080) }
}

/// tvOS-style focus: lift, deep shadow, a hairline edge and a light sheen
/// that sweeps across once when focus arrives.
struct FocusLift: ViewModifier {
    let focused: Bool
    let radius: CGFloat
    let s: CGFloat
    var amount: CGFloat = 1.1

    @State private var sweep: CGFloat = -1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .rotationEffect(.degrees(18))
                        .offset(x: sweep * g.size.width * 1.2)
                        .opacity(focused ? 1 : 0)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.35 : 0.08), lineWidth: focused ? 2 * s : 1))
            .shadow(color: .black.opacity(focused ? 0.65 : 0.25), radius: (focused ? 34 : 10) * s, y: (focused ? 22 : 6) * s)
            .scaleEffect(focused ? amount : 1)
            .zIndex(focused ? 1 : 0)
            .animation(DS.focusSpring, value: focused)
            .onChange(of: focused) { _, now in
                guard now else { return }
                sweep = -1
                withAnimation(.easeOut(duration: 0.9)) { sweep = 1 }
            }
    }
}

extension View {
    func focusLift(_ focused: Bool, radius: CGFloat, s: CGFloat, amount: CGFloat = 1.1) -> some View {
        modifier(FocusLift(focused: focused, radius: radius, s: s, amount: amount))
    }
}

/// An image scaled to cover `size` exactly (explicit math; SwiftUI's
/// scaledToFill mis-placed large art in some containers).
struct CoverImage: View {
    let image: NSImage
    let size: CGSize

    var body: some View {
        let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
        let k = max(size.width / iw, size.height / ih)
        Image(nsImage: image).resizable().interpolation(.high)
            .frame(width: iw * k, height: ih * k)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}
