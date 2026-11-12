// Owns: the one header every screen shares, drawn across the top: optional
// content on the left (a label, the Search chip), optional content before the
// clock (the profile chip, connected devices), and the clock itself, always
// at the same size and place. Which parts show is Core's ScreenHeaderPolicy.

import SwiftUI
import CouchModeCore

struct ScreenHeader<Leading: View, Accessory: View>: View {
    let kind: ScreenKind
    let s: CGFloat
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var accessory: () -> Accessory

    /// Height of the band the header occupies, in design points.
    static var band: CGFloat { 120 }

    @State private var now = Date()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        let style = ScreenHeaderPolicy.style(for: kind)
        HStack(spacing: 22 * s) {
            leading()
            Spacer(minLength: 0)
            accessory()
            Text(ClockText.time(now))
                .font(DS.ui(34, s)).monospacedDigit().foregroundStyle(DS.text)
        }
        .padding(.horizontal, DS.page * s)
        .frame(maxWidth: .infinity)
        .frame(height: Self.band * s)
        .overlay(alignment: .topTrailing) {
            if style.showsDate {
                Text(ClockText.date(now)).font(DS.ui(17, s, .medium)).foregroundStyle(DS.text2)
                    .padding(.trailing, DS.page * s).padding(.top, 88 * s)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 10 * s)
        .onReceive(tick) { now = $0 }
    }
}

extension ScreenHeader where Leading == EmptyView, Accessory == EmptyView {
    /// Clock only.
    init(_ kind: ScreenKind, s: CGFloat) {
        self.init(kind: kind, s: s, leading: { EmptyView() }, accessory: { EmptyView() })
    }
}

extension ScreenHeader where Accessory == EmptyView {
    init(_ kind: ScreenKind, s: CGFloat, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(kind: kind, s: s, leading: leading, accessory: { EmptyView() })
    }
}

extension View {
    /// Pins the shared header to the top of the screen.
    func pinnedToTop() -> some View { frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
}
