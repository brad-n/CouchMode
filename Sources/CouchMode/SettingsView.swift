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
    /// A line under the list: a status or a hint.
    @Published var footer: String?

    init(title: String = "Settings", icon: String = "gearshape.fill", rows: [SettingRow]) {
        self.title = title; self.icon = icon; self.rows = rows
    }

    /// New rows; the focused row stays focused if it's still there.
    func update(rows newRows: [SettingRow]) {
        let keep = selected?.id
        rows = newRows
        index = keep.flatMap { id in newRows.firstIndex { $0.id == id } } ?? min(index, max(0, newRows.count - 1))
    }

    func move(_ d: Direction) {
        switch d {
        case .up: index = max(0, index - 1)
        case .down: index = min(rows.count - 1, index + 1)
        case .left, .right: break
        }
    }

    var selected: SettingRow? { rows.indices.contains(index) ? rows[index] : nil }

    /// Focuses the row with this id, if it's there.
    func select(id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { index = i }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
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

                    // Right: the list.
                    VStack(alignment: .leading, spacing: 10 * s) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            SettingRowView(row: row, focused: i == model.index, s: s)
                        }
                        if let footer = model.footer {
                            Text(footer).font(DS.ui(20, s, .medium)).foregroundStyle(DS.text2)
                                .padding(.top, 14 * s).padding(.horizontal, 26 * s)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 820 * s, alignment: .leading)
                    Spacer(minLength: 0)
                }
                ClockBadge(scale: s)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                    .padding(.trailing, DS.page * s).padding(.top, 56 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
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
