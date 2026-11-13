// Owns: the "All Consoles" screen and its state holder: every system as a
// card in a 4-column grid, the focused console's art behind a hero, the grid
// sliding a row at a time (computed offsets, like home). Opening a console is
// the coordinator's job.

import SwiftUI
import CouchModeCore

@MainActor
final class AllConsolesModel: ObservableObject {
    static let columns = 4
    let items: [HomeItem]
    @Published private(set) var focus: FocusGrid

    init(items: [HomeItem]) {
        self.items = items
        let full = items.count / Self.columns
        let rest = items.count % Self.columns
        let lengths = Array(repeating: Self.columns, count: full) + (rest > 0 ? [rest] : [])
        // The catalog is never empty, so the grid always has a shape.
        self.focus = FocusGrid(rowLengths: lengths)!
    }

    func move(_ d: Direction) { focus = focus.moved(d) }

    /// Keeps the focus where it was when the screen is redrawn with fresh items.
    func restoreFocus(from old: AllConsolesModel) {
        if let moved = focus.at(row: old.focus.row, column: old.focus.column) { focus = moved }
    }
    var selected: HomeItem { items[focus.row * Self.columns + focus.column] }
    var rows: [[HomeItem]] { stride(from: 0, to: items.count, by: Self.columns).map { Array(items[$0..<min($0 + Self.columns, items.count)]) } }
}

struct AllConsolesView: View {
    @ObservedObject var model: AllConsolesModel
    private static let card = CGSize(width: 384, height: 216)
    private static let rowHeight: CGFloat = 216 + 70 + 44    // card + caption + gap

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack(alignment: .topLeading) {
                backdrop(geo.size)
                VStack(alignment: .leading, spacing: 10 * s) {
                    Text("All Consoles").font(DS.ui(22, s, .bold)).foregroundStyle(DS.text2)
                    Text(model.selected.title).font(DS.display(68, s)).foregroundStyle(DS.text)
                        .id(model.selected.id).transition(.opacity)
                    Text(model.selected.subtitle).font(DS.ui(24, s)).foregroundStyle(DS.text2)
                }
                .padding(.leading, DS.page * s).padding(.top, 110 * s)
                .animation(.easeOut(duration: 0.25), value: model.selected.id)
                ScreenHeader(.allConsoles, s: s).pinnedToTop()
                grid(width: geo.size.width, s: s)
                    .offset(y: (420 - CGFloat(model.focus.row) * Self.rowHeight) * s)
                    .animation(DS.slide, value: model.focus.row)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(DS.canvas)
        .ignoresSafeArea()
    }

    private func backdrop(_ size: CGSize) -> some View {
        ZStack {
            DS.canvas
            if let name = model.selected.artwork, let art = Artwork.image(name) {
                CoverImage(image: art, size: size).id(name).transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.3), location: 0.5),
                                   .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: DS.canvas.opacity(0.7), location: 0.35),
                                   .init(color: DS.canvas.opacity(0.96), location: 0.5), .init(color: DS.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .animation(DS.fade, value: model.selected.id)
    }

    private func grid(width: CGFloat, s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 44 * s) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { r, row in
                HStack(alignment: .top, spacing: 40 * s) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { c, item in
                        LandscapeCard(item: item, focused: r == model.focus.row && c == model.focus.column,
                                      size: Self.card, s: s)
                    }
                }
                .opacity(r < model.focus.row ? 0 : 1)
                .animation(DS.fade, value: model.focus.row)
            }
        }
        .padding(.leading, DS.page * s)
        .frame(width: width, alignment: .leading)
    }
}
