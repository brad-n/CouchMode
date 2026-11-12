// Owns: where focus is on the shell's own streaming screens. A service home
// is a top bar (Search, Profile) above rows of titles; a title's details are
// a buttons row, then for shows a seasons row (tabs) and an episodes row.
// Also when a row near its end should ask the service for more, how much of
// a row is worth drawing, and the facts line under a title. Pure values: no
// I/O, no views. Edges stop rather than wrap, as everywhere in the shell.

import Foundation

public enum StreamHomeTarget: Equatable, Sendable {
    case search
    case profile
    case title(row: Int, index: Int)
}

public struct StreamHomeFocus: Equatable, Sendable {
    private enum Bar: Equatable, Sendable { case search, profile }

    private var grid: FocusGrid?
    /// Set while the top bar has focus.
    private var bar: Bar?
    /// Where Up from the first row lands (the bar item last used).
    private var lastBar: Bar = .search

    /// `rowLengths` are the loaded rows' title counts (every row non-empty,
    /// as StreamHome.bounded gives). Without content, focus is on the top bar.
    public init(rowLengths: [Int]) {
        grid = FocusGrid(rowLengths: rowLengths)
        bar = grid == nil ? .search : nil
    }

    public var target: StreamHomeTarget {
        if let bar { return bar == .search ? .search : .profile }
        guard let grid else { return .search }
        return .title(row: grid.row, index: grid.column)
    }

    public func moved(_ direction: Direction) -> StreamHomeFocus {
        var next = self
        if bar != nil {
            switch direction {
            case .left: next.bar = .search
            case .right: next.bar = .profile
            case .down: if grid != nil { next.bar = nil }
            case .up: break
            }
            if let now = next.bar { next.lastBar = now }
            return next
        }
        guard let grid else { return self }
        if direction == .up, grid.row == 0 {
            next.bar = lastBar
        } else {
            next.grid = grid.moved(direction)
        }
        return next
    }

    /// The same focus on a home whose rows changed (more titles loaded, a
    /// refresh), clamped to real titles. From no content it lands on the
    /// first title; the top bar keeps focus if it had it.
    public func resized(rowLengths newLengths: [Int]) -> StreamHomeFocus {
        var next = StreamHomeFocus(rowLengths: newLengths)
        next.lastBar = lastBar
        guard next.grid != nil else {
            next.bar = bar ?? lastBar
            return next
        }
        guard let old = grid else { return next }
        next.grid = old.resized(rowLengths: newLengths) ?? next.grid
        next.bar = bar
        return next
    }

    /// Focus on one title; nil if there is no such title.
    public func at(row: Int, index: Int) -> StreamHomeFocus? {
        guard let grid, let moved = grid.at(row: row, column: index) else { return nil }
        var next = self
        next.grid = moved
        next.bar = nil
        return next
    }

    /// The focus on a re-read home: stays on the same title (row id + title id) when it is still
    /// there, even if the service moved it (Continue Watching puts the just-watched title first);
    /// otherwise the old position, clamped (`resized`).
    public func refocused(from oldRows: [StreamRow], to newRows: [StreamRow]) -> StreamHomeFocus {
        let lengths = newRows.map(\.titles.count)
        let fallback = resized(rowLengths: lengths)
        guard case .title(let r, let i) = target, oldRows.indices.contains(r), oldRows[r].titles.indices.contains(i),
              let newRow = newRows.firstIndex(where: { $0.id == oldRows[r].id }),
              let newIndex = newRows[newRow].titles.firstIndex(where: { $0.id == oldRows[r].titles[i].id }),
              let found = fallback.at(row: newRow, index: newIndex) else { return fallback }
        return found
    }
}

public enum StreamFocus {
    /// A row asks for more when focus is within this many titles of its end.
    public static let moreThreshold = 3
    /// Tiles drawn after / before the focused one in a row (the screen shows
    /// about six), so a row with 40 titles never builds 40 views.
    public static let tilesAhead = 9
    public static let tilesBehind = 2

    /// True when focus is within the last `moreThreshold` loaded titles, the
    /// service says it holds more, and the row is below its cap.
    public static func needsMore(row: StreamRow, focusedIndex: Int) -> Bool {
        let loaded = row.titles.count
        guard let total = row.totalCount, total > loaded, loaded < StreamLimits.maxTitlesPerRow else { return false }
        return focusedIndex >= loaded - moreThreshold
    }

    /// Which titles of a row to draw for the focused column.
    public static func visibleWindow(count: Int, focusedColumn: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let column = min(max(0, focusedColumn), count - 1)
        return max(0, column - tilesBehind)..<min(count, column + tilesAhead + 1)
    }
}

public enum StreamDetailTarget: Equatable, Sendable {
    case button(Int)
    case season(Int)
    case episode(Int)
}

public struct StreamDetailFocus: Equatable, Sendable {
    public private(set) var target: StreamDetailTarget
    /// The season whose episodes show: the last season tab focused.
    public private(set) var season: Int
    private let buttons: Int
    private let seasons: Int
    private let episodes: Int

    public init(buttons: Int, seasons: Int = 0, episodes: Int = 0, season: Int = 0) {
        self.buttons = max(0, buttons)
        self.seasons = max(0, seasons)
        self.episodes = max(0, episodes)
        self.season = min(max(0, season), max(0, seasons - 1))
        target = .button(0)
    }

    public func moved(_ direction: Direction) -> StreamDetailFocus {
        var next = self
        switch (direction, target) {
        case (.left, .button(let i)): next.target = .button(max(0, i - 1))
        case (.right, .button(let i)): next.target = .button(min(max(0, buttons - 1), i + 1))
        case (.down, .button):
            if seasons > 0 { next.target = .season(season) } else if episodes > 0 { next.target = .episode(0) }
        case (.left, .season(let i)):
            next.target = .season(max(0, i - 1))
            next.season = max(0, i - 1)
        case (.right, .season(let i)):
            let to = min(seasons - 1, i + 1)
            next.target = .season(to)
            next.season = to
        case (.up, .season): next.target = .button(0)
        case (.down, .season): if episodes > 0 { next.target = .episode(0) }
        case (.left, .episode(let i)): next.target = .episode(max(0, i - 1))
        case (.right, .episode(let i)): next.target = .episode(min(episodes - 1, i + 1))
        case (.up, .episode): next.target = seasons > 0 ? .season(season) : .button(0)
        default: break
        }
        return next
    }

    /// The same focus once the rows changed size (details or a season's
    /// episodes arrived), clamped to what exists.
    public func resized(buttons: Int, seasons: Int, episodes: Int) -> StreamDetailFocus {
        var next = StreamDetailFocus(buttons: buttons, seasons: seasons, episodes: episodes, season: season)
        switch target {
        case .button(let i): next.target = .button(min(i, max(0, next.buttons - 1)))
        case .season: next.target = next.seasons > 0 ? .season(next.season) : .button(0)
        case .episode(let i):
            if next.episodes > 0 { next.target = .episode(min(i, next.episodes - 1)) }
            else { next.target = next.seasons > 0 ? .season(next.season) : .button(0) }
        }
        return next
    }
}

/// How a title's facts read under its name.
public enum StreamFacts {
    /// "2021 · TV-14 · 2 Seasons" (runtime when it isn't a show), then the
    /// current episode ("S1 · E7") when known; empty if none are known.
    public static func line(for title: StreamTitle) -> String {
        let last = title.seasonsLabel ?? title.runtimeSeconds.flatMap { runtimeText(seconds: $0) }
        return [title.year.map(String.init), title.rating, last, title.episodeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// "1 h 52 min", "45 min"; nil under a minute.
    public static func runtimeText(seconds: Int) -> String? {
        let minutes = seconds / 60
        guard minutes > 0 else { return nil }
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
