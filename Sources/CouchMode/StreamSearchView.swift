// Owns: the shell's own streaming search screen: an on-screen keyboard, the
// typed query, and a grid of result tiles, driven by a remote or controller.
// It debounces typing, runs the service's search for the latest query only,
// and shows idle / searching / no-results / unavailable states. It does not
// own how a search is performed (the caller's `search` closure, a service's
// reader) or what choosing a title does (`onChoose`).

import CouchModeCore
import SwiftUI
import os

@MainActor
final class StreamSearchModel: ObservableObject {
    enum Zone: Equatable { case keyboard, results }
    enum Phase: Equatable {
        case idle
        case searching
        case results
        case empty(query: String)
        case unavailable
    }

    /// How long typing must pause before a search runs.
    static let searchDebounce: Duration = .milliseconds(600)
    /// Result tiles per grid row.
    static let resultColumns = 3

    let serviceName: String
    @Published private(set) var keyboard = StreamKeyboard()
    @Published private(set) var zone: Zone = .keyboard
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [StreamTitle] = []
    @Published private(set) var resultFocus: FocusGrid?

    private let search: @MainActor (String) async -> [StreamTitle]?
    private let onChoose: @MainActor (StreamTitle) -> Void
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?
    private var lastQuery: String?
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "stream")

    init(serviceName: String,
         search: @escaping @MainActor (String) async -> [StreamTitle]?,
         onChoose: @escaping @MainActor (StreamTitle) -> Void,
         debounce: Duration = StreamSearchModel.searchDebounce) {
        self.serviceName = serviceName
        self.search = search
        self.onChoose = onChoose
        self.debounce = debounce
    }

    deinit { searchTask?.cancel() }

    var text: String { keyboard.text }

    /// Index into `results` of the focused tile, when the grid has focus.
    var focusedResultIndex: Int? {
        guard zone == .results, let g = resultFocus else { return nil }
        return g.row * Self.resultColumns + g.column
    }

    /// True when the intent was used; false only for Back on an untouched
    /// keyboard, so the caller leaves the screen.
    func handle(_ intent: ShellIntent) -> Bool {
        switch intent {
        case .move(let direction):
            move(direction)
        case .select:
            select()
        case .back:
            if zone == .results {
                zone = .keyboard
            } else if !keyboard.text.isEmpty {
                clearText()
            } else {
                return false
            }
        case .home, .info:
            break
        }
        return true
    }

    // MARK: Input

    private func move(_ direction: Direction) {
        switch zone {
        case .keyboard:
            let rowEnd = StreamKeyboard.layout[keyboard.focusedRow].count - 1
            if direction == .right, keyboard.focusedColumn == rowEnd, resultFocus != nil {
                zone = .results
            } else {
                keyboard.move(direction)
            }
        case .results:
            guard let grid = resultFocus else { zone = .keyboard; return }
            if direction == .left, grid.column == 0 {
                zone = .keyboard
            } else {
                resultFocus = grid.moved(direction)
            }
        }
    }

    private func select() {
        switch zone {
        case .keyboard:
            let before = keyboard.text
            keyboard.press()
            if keyboard.text != before { textChanged() }
        case .results:
            guard let i = focusedResultIndex, results.indices.contains(i) else { return }
            log.info("search chose \(self.results[i].id, privacy: .public) on \(self.serviceName, privacy: .public)")
            onChoose(results[i])
        }
    }

    private func clearText() {
        keyboard.clearText()
        textChanged()
    }

    // MARK: Searching

    private func textChanged() {
        searchTask?.cancel()
        guard let query = StreamSearch.normalized(keyboard.text) else {
            lastQuery = nil
            phase = .idle
            setResults([])
            return
        }
        // Typing only a trailing space changes nothing the reader would see.
        if query == lastQuery, phase != .searching { return }
        searchTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.run(query)
        }
    }

    private func run(_ query: String) async {
        lastQuery = query
        phase = .searching
        log.info("search \(query.count) chars on \(self.serviceName, privacy: .public)")
        let found = await search(query)
        // A newer keystroke cancelled this one: its results are stale.
        guard !Task.isCancelled, lastQuery == query else { return }
        withAnimation(DS.fade) {
            guard let found else {
                phase = .unavailable
                setResults([])
                return
            }
            let bounded = Self.bounded(found)
            setResults(bounded)
            phase = bounded.isEmpty ? .empty(query: query) : .results
        }
    }

    /// Unique by id, in order, within StreamLimits.maxSearchResults.
    static func bounded(_ titles: [StreamTitle]) -> [StreamTitle] {
        var seen = Set<String>()
        var out: [StreamTitle] = []
        for title in titles where seen.insert(title.id).inserted {
            out.append(title)
            if out.count == StreamLimits.maxSearchResults { break }
        }
        return out
    }

    private func setResults(_ titles: [StreamTitle]) {
        results = titles
        guard !titles.isEmpty else {
            resultFocus = nil
            zone = .keyboard
            return
        }
        let columns = Self.resultColumns
        var lengths = Array(repeating: columns, count: titles.count / columns)
        if titles.count % columns > 0 { lengths.append(titles.count % columns) }
        // New results start at the top; the old position means nothing.
        resultFocus = FocusGrid(rowLengths: lengths)
    }

    // MARK: Sample

    /// A model with a fake search (about 0.3 s): any text finds a few
    /// titles; "none" finds nothing; "off" is unavailable.
    static func sample() -> StreamSearchModel {
        let log = Logger(subsystem: "local.brad.htpcshell", category: "stream")
        let base = URL(string: "https://example.com/watch")!
        let kinds: [(String, StreamTitle.Kind, Int, String?)] = [
            ("Nights", .movie, 2019, "R"), ("Harbor", .show, 2021, "TV-14"), ("Signal", .movie, 2015, "PG-13"),
            ("Winter Line", .show, 2023, "TV-MA"), ("Paper Moon", .movie, 1973, "PG"),
            ("The Long Way", .show, 2018, "TV-PG"), ("Ember", .episode, 2022, nil),
        ]
        return StreamSearchModel(
            serviceName: "Sample",
            search: { query in
                try? await Task.sleep(for: .milliseconds(300))
                switch query.lowercased() {
                case "none": return []
                case "off": return nil
                default:
                    return kinds.enumerated().map { i, k in
                        StreamTitle(id: "sample-\(i)", name: "\(query.capitalized) \(k.0)", kind: k.1,
                                    play: base.appendingPathComponent("\(i)"), year: k.2, rating: k.3)
                    }
                }
            },
            onChoose: { title in log.info("sample chose \(title.id, privacy: .public)") })
    }
}

// MARK: - View

struct StreamSearchView: View {
    @ObservedObject var model: StreamSearchModel

    // Design points at 1080 tall.
    private let keySize: CGFloat = 80
    private let keyGap: CGFloat = 12
    private let paneGap: CGFloat = 64
    private let tileGap: CGFloat = 28
    private let tileInset: CGFloat = 28
    private let captionHeight: CGFloat = 58
    private let edgeFade: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let s = DS.scale(geo.size)
            ZStack {
                DS.canvas.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 36 * s) {
                    header(s)
                    HStack(alignment: .top, spacing: paneGap * s) {
                        keyboard(s)
                        resultsPane(s)
                    }
                }
                .padding(.horizontal, DS.page * s)
                .padding(.vertical, 72 * s)
            }
        }
    }

    // MARK: Header

    private func header(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            HStack {
                Label("Search \(model.serviceName)", systemImage: "magnifyingglass")
                    .font(DS.ui(24, s, .semibold))
                    .foregroundStyle(DS.text3)
                Spacer()
                ClockBadge(scale: s)
            }
            HStack(spacing: 6 * s) {
                if model.text.isEmpty {
                    Text("Type a title")
                        .font(DS.display(68, s))
                        .foregroundStyle(DS.text3.opacity(0.6))
                } else {
                    Text(model.text)
                        .font(DS.display(68, s))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .truncationMode(.head)
                }
                Caret(s: s, active: model.zone == .keyboard)
                Spacer(minLength: 0)
            }
            .frame(height: 84 * s)
            Rectangle().fill(DS.hairline).frame(height: max(1, s))
        }
    }

    // MARK: Keyboard

    private func keyboard(_ s: CGFloat) -> some View {
        let width = (CGFloat(StreamKeyboard.columns) * keySize + CGFloat(StreamKeyboard.columns - 1) * keyGap) * s
        return VStack(spacing: keyGap * s) {
            ForEach(Array(StreamKeyboard.layout.enumerated()), id: \.offset) { r, row in
                let isActions = row.count < StreamKeyboard.columns
                let w = isActions
                    ? (width - CGFloat(row.count - 1) * keyGap * s) / CGFloat(row.count)
                    : keySize * s
                HStack(spacing: keyGap * s) {
                    ForEach(Array(row.enumerated()), id: \.offset) { c, key in
                        KeyCap(key: key,
                               focused: model.zone == .keyboard && model.keyboard.focusedRow == r && model.keyboard.focusedColumn == c,
                               resting: model.zone == .results && model.keyboard.focusedRow == r && model.keyboard.focusedColumn == c,
                               size: CGSize(width: w, height: keySize * s), s: s)
                    }
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    // MARK: Results

    private func resultsPane(_ s: CGFloat) -> some View {
        ZStack {
            switch model.phase {
            case .idle:
                StatusPanel(symbol: "text.magnifyingglass", title: "Find something to watch",
                            detail: "Pick letters and pause: results appear on their own.", s: s)
            case .unavailable:
                StatusPanel(symbol: "exclamationmark.magnifyingglass", title: "Search isn't available for \(model.serviceName) yet",
                            detail: nil, s: s)
            case .empty(let query):
                StatusPanel(symbol: "film.stack", title: "No results for \u{201C}\(query)\u{201D}",
                            detail: "Check the spelling, or try fewer words.", s: s)
            case .searching where model.results.isEmpty:
                StatusPanel(symbol: nil, title: "Searching \(model.serviceName)\u{2026}", detail: nil, s: s)
            case .searching, .results:
                resultsGrid(s)
                    .opacity(model.phase == .searching ? 0.45 : 1)
                    .animation(DS.fade, value: model.phase == .searching)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func resultsGrid(_ s: CGFloat) -> some View {
        GeometryReader { geo in
            let inset = tileInset * s, gap = tileGap * s
            let columns = CGFloat(StreamSearchModel.resultColumns)
            let tileW = (geo.size.width - 2 * inset - (columns - 1) * gap) / columns
            let tileH = tileW * 9 / 16
            let rowStep = tileH + captionHeight * s + gap
            let rows = (model.results.count + StreamSearchModel.resultColumns - 1) / StreamSearchModel.resultColumns
            let focusRow = model.resultFocus.map { model.zone == .results ? $0.row : 0 } ?? 0
            let offset = RowSlide.offset(focusedColumn: focusRow, step: rowStep)
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<StreamSearchModel.resultColumns, id: \.self) { c in
                            let i = r * StreamSearchModel.resultColumns + c
                            if model.results.indices.contains(i) {
                                ResultTile(title: model.results[i], focused: model.focusedResultIndex == i,
                                           size: CGSize(width: tileW, height: tileH), captionHeight: captionHeight * s, s: s)
                            } else {
                                Color.clear.frame(width: tileW, height: tileH)
                            }
                        }
                    }
                }
            }
            .padding(inset)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .offset(y: -offset)
            .animation(DS.slide, value: focusRow)
            .clipped()
            .mask(edgeMask(s))
        }
    }

    private func edgeMask(_ s: CGFloat) -> some View {
        GeometryReader { g in
            let f = min(0.5, edgeFade * s / max(g.size.height, 1))
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: f),
                                   .init(color: .black, location: 1 - f), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Parts

/// A blinking text cursor; steady while focus is elsewhere.
private struct Caret: View {
    let s: CGFloat
    let active: Bool
    @State private var on = true
    private let tick = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        Capsule().fill(DS.accent)
            .frame(width: 5 * s, height: 56 * s)
            .opacity(active ? (on ? 1 : 0.15) : 0.35)
            .onReceive(tick) { _ in if active { withAnimation(.easeInOut(duration: 0.25)) { on.toggle() } } }
    }
}

private struct KeyCap: View {
    let key: StreamKeyboard.Key
    let focused: Bool
    let resting: Bool
    let size: CGSize
    let s: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.cardRadius * s, style: .continuous)
        ZStack {
            shape.fill(focused ? DS.accent : (resting ? DS.surfaceStrong : DS.surface))
            label
        }
        .frame(width: size.width, height: size.height)
        .overlay(shape.strokeBorder(focused ? .white.opacity(0.5) : (resting ? DS.accent.opacity(0.6) : DS.hairline),
                                    lineWidth: focused ? 2 * s : max(1, s)))
        .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: 22 * s, y: 12 * s)
        .scaleEffect(focused ? 1.12 : 1)
        .zIndex(focused ? 1 : 0)
        .animation(DS.focusSpring, value: focused)
    }

    @ViewBuilder private var label: some View {
        let color = focused ? DS.canvas : DS.text
        switch key {
        case .character(let ch):
            Text(String(ch).uppercased()).font(DS.ui(34, s, .bold)).foregroundStyle(color)
        case .space:
            action("Space", "space", color)
        case .delete:
            action("Delete", "delete.left", color)
        case .clear:
            action("Clear", "xmark.circle", color)
        }
    }

    private func action(_ name: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10 * s) {
            Image(systemName: symbol).font(.system(size: 24 * s, weight: .semibold))
            Text(name).font(DS.ui(24, s, .bold))
        }
        .foregroundStyle(focused ? color : DS.text2)
    }
}

private struct StatusPanel: View {
    let symbol: String?
    let title: String
    let detail: String?
    let s: CGFloat

    var body: some View {
        VStack(spacing: 18 * s) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 76 * s, weight: .light))
                    .foregroundStyle(DS.text3)
            } else {
                ProgressView().controlSize(.large).colorScheme(.dark).scaleEffect(1.6 * s)
                    .frame(height: 76 * s)
            }
            Text(title).font(DS.ui(34, s, .bold)).foregroundStyle(DS.text2).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(DS.ui(24, s, .medium)).foregroundStyle(DS.text3).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 48 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

private struct ResultTile: View {
    let title: StreamTitle
    let focused: Bool
    let size: CGSize
    let captionHeight: CGFloat
    let s: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.cardRadius * s, style: .continuous)
        VStack(alignment: .leading, spacing: 12 * s) {
            ZStack {
                DS.surface
                if let art = title.tileArt {
                    RemoteImage(url: art, cover: size)
                } else {
                    placeholder
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .focusLift(focused, radius: DS.cardRadius * s, s: s, amount: 1.08)
            VStack(alignment: .leading, spacing: 3 * s) {
                if title.tileArt != nil {
                    Text(title.name).font(DS.ui(21, s, .bold)).foregroundStyle(focused ? DS.text : DS.text2).lineLimit(1)
                }
                Text(subtitle).font(DS.ui(16, s, .medium)).foregroundStyle(DS.text3).lineLimit(1)
            }
            .frame(width: size.width, height: captionHeight - 12 * s, alignment: .topLeading)
            .offset(y: focused ? 10 * s : 0)
            .animation(DS.focusSpring, value: focused)
        }
        .frame(width: size.width, alignment: .leading)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [DS.surfaceStrong, DS.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10 * s) {
                Image(systemName: title.kind == .movie ? "film" : "tv")
                    .font(.system(size: 30 * s, weight: .regular))
                    .foregroundStyle(DS.text3)
                Text(title.name)
                    .font(DS.ui(26, s, .bold))
                    .foregroundStyle(focused ? DS.text : DS.text2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 22 * s)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch title.kind {
        case .movie: parts.append("Movie")
        case .show: parts.append(title.seasonsLabel ?? "Series")
        case .episode: parts.append(title.episodeLabel ?? "Episode")
        case .other: break
        }
        if let year = title.year { parts.append(String(year)) }
        if let rating = title.rating { parts.append(rating) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
