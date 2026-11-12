// Owns: the launch intro: a soft light blooms out of the dark, the greeting
// and date appear, then the coordinator fades it away over the home screen.
// Original abstract motif (no logos).

import SwiftUI

struct IntroView: View {
    @State private var bloom = false
    @State private var text = false

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack {
                Color.black
                // The bloom: two soft, warm-to-cool light fields that grow and settle.
                Circle()
                    .fill(RadialGradient(colors: [DS.accent.opacity(0.85), DS.accent.opacity(0.0)],
                                         center: .center, startRadius: 0, endRadius: 360 * s))
                    .frame(width: 720 * s, height: 720 * s)
                    .scaleEffect(bloom ? 1.25 : 0.2)
                    .opacity(bloom ? 0.55 : 0)
                    .offset(x: -90 * s, y: -30 * s)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.45, green: 0.55, blue: 1.0).opacity(0.7), .clear],
                                         center: .center, startRadius: 0, endRadius: 300 * s))
                    .frame(width: 600 * s, height: 600 * s)
                    .scaleEffect(bloom ? 1.15 : 0.2)
                    .opacity(bloom ? 0.45 : 0)
                    .offset(x: 110 * s, y: 40 * s)
                VStack(spacing: 14 * s) {
                    Text(Greeting.now())
                        .font(DS.display(76, s, .bold))
                        .foregroundStyle(.white)
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(DS.ui(26, s, .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .opacity(text ? 1 : 0)
                .offset(y: text ? 0 : 18 * s)
                .blur(radius: text ? 0 : 8 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 1.4)) { bloom = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.35)) { text = true }
        }
    }
}

enum Greeting {
    static func now(_ date: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: date)
        return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }
}
