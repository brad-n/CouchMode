// Owns: the Settings screen (tvOS style: a large icon and title on the left,
// a list on the right whose focused row turns white) and its state holder,
// also used for Remotes & Controllers. What each row does is the
// coordinator's job; this draws and tracks focus.

import SwiftUI
import CouchModeCore

struct SettingRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let symbol: String
    /// Rows that act on press (Sleep, Restart) rather than change a value.
    var isAction = false
}

@MainActor
final class SettingsModel: ObservableObject {
    let title: String
    /// The big icon when no row has its own.
    let icon: String
    @Published private(set) var rows: [SettingRow]
    @Published private(set) var index = 0
    /// Which rows show when the list is longer than the screen.
    @Published private(set) var window = ListWindow(first: 0, count: 0, capacity: 1)
    private var capacity = 1
    /// A line under the list: a status or a hint.
    @Published var footer: String?

    init(title: String = "Settings", icon: String = "gearshape.fill", rows: [SettingRow]) {
        self.title = title; self.icon = icon; self.rows = rows
        refreshWindow()
    }

    /// How many rows the screen has room for; the view reports it.
    func setCapacity(_ n: Int) {
        capacity = max(1, n)
        refreshWindow()
    }

    private func refreshWindow() {
        window = ListWindow.following(window, focused: index, count: rows.count, capacity: capacity)
    }

    /// New rows; the focused row stays focused if it's still there.
    func update(rows newRows: [SettingRow]) {
        let keep = selected?.id
        rows = newRows
        index = keep.flatMap { id in newRows.firstIndex { $0.id == id } } ?? min(index, max(0, newRows.count - 1))
        refreshWindow()
    }

    func move(_ d: Direction) {
        switch d {
        case .up: index = max(0, index - 1)
        case .down: index = min(rows.count - 1, index + 1)
        case .left, .right: break
        }
        refreshWindow()
    }

    var selected: SettingRow? { rows.indices.contains(index) ? rows[index] : nil }

    /// Focuses the row with this id, if it's there.
    func select(id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { index = i; refreshWindow() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// `.bluetooth` for Remotes & Controllers, which reuses this screen.
    var kind: ScreenKind = .settings

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            let footerH = (model.footer == nil ? 0 : Metrics.footer) * s
            let listHeight = geo.size.height - (ScreenHeader<EmptyView, EmptyView>.band + Metrics.bottom) * s - footerH
            ZStack {
                DS.canvas
                RadialGradient(colors: [Color(white: 0.22), DS.canvas], center: UnitPoint(x: 0.25, y: 0.45),
                               startRadius: 0, endRadius: geo.size.width * 0.5)
                HStack(spacing: 0) {
                    // Left: the big icon and title.
                    VStack(spacing: 30 * s) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.16)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 2 * s)
                            Image(systemName: model.selected?.symbol ?? model.icon)
                                .font(.system(size: 150 * s, weight: .semibold))
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                                .animation(.easeOut(duration: 0.25), value: model.index)
                        }
                        .frame(width: 330 * s, height: 330 * s)
                        .shadow(color: .black.opacity(0.5), radius: 40 * s, y: 24 * s)
                        Text(model.title).font(DS.display(56, s)).foregroundStyle(DS.text)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: geo.size.width * 0.42)
                    .padding(.top, ScreenHeader<EmptyView, EmptyView>.band * s)
                    .padding(.bottom, Metrics.bottom * s)

                    // Right: the list, inside the content area below the header.
                    VStack(alignment: .leading, spacing: 0) {
                        list(s: s, height: listHeight)
                        if let footer = model.footer {
                            Text(footer).font(DS.ui(20, s, .medium)).foregroundStyle(DS.text2)
                                .padding(.top, 14 * s).padding(.horizontal, 26 * s)
                                .frame(height: Metrics.footer * s - 14 * s, alignment: .topLeading)
                                .padding(.top, 14 * s)
                        }
                    }
                    .frame(width: 820 * s, alignment: .leading)
                    Spacer(minLength: 0)
                }
                ScreenHeader(kind, s: s).pinnedToTop()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { model.setCapacity(capacity(listHeight, s)) }
            .onChange(of: listHeight) { _, h in model.setCapacity(capacity(h, s)) }
        }
        .ignoresSafeArea()
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 76
        static let rowGap: CGFloat = 10
        static let bottom: CGFloat = 72
        static let footer: CGFloat = 64
        static let fade: CGFloat = 40
    }

    private func capacity(_ height: CGFloat, _ s: CGFloat) -> Int {
        ListWindow.capacity(height: Double(height / s) + Double(Metrics.rowGap), rowHeight: Double(Metrics.rowHeight + Metrics.rowGap))
    }

    /// Rows laid out at fixed offsets and slid as a whole (no ScrollView), clipped
    /// to the area with a fade on any edge that has more rows beyond it.
    private func list(s: CGFloat, height: CGFloat) -> some View {
        let step = (Metrics.rowHeight + Metrics.rowGap) * s
        let w = model.window
        let fade = Metrics.fade * s / max(1, height)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                SettingRowView(row: row, focused: i == model.index, s: s)
                    .offset(y: CGFloat(i - w.first) * step)
            }
        }
        .frame(width: 820 * s, height: height, alignment: .topLeading)
        .animation(DS.slide, value: w.first)
        .mask(
            LinearGradient(stops: [
                .init(color: w.hasMoreAbove ? .clear : .black, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: w.hasMoreBelow ? .clear : .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.horizontal, -60 * s)
        )
        .animation(.easeOut(duration: 0.2), value: w.hasMoreAbove)
        .animation(.easeOut(duration: 0.2), value: w.hasMoreBelow)
    }
}

private struct SettingRowView: View {
    let row: SettingRow
    let focused: Bool
    let s: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
        HStack(spacing: 18 * s) {
            Image(systemName: row.symbol)
                .font(.system(size: 26 * s, weight: .semibold))
                .frame(width: 40 * s)
            Text(row.title).font(DS.ui(26, s, .semibold))
            Spacer()
            Text(row.value).font(DS.ui(22, s, .medium)).opacity(0.7).lineLimit(1)
            Image(systemName: row.isAction ? "return" : "chevron.right")
                .font(.system(size: 18 * s, weight: .bold)).opacity(0.5)
        }
        .foregroundStyle(focused ? .black : DS.text)
        .padding(.horizontal, 26 * s)
        .frame(height: 76 * s)
        .background(shape.fill(focused ? Color.white : Color.white.opacity(0.06)))
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 22 * s, y: 12 * s)
        .scaleEffect(focused ? 1.04 : 1, anchor: .leading)
        .animation(DS.focusSpring, value: focused)
    }
}
