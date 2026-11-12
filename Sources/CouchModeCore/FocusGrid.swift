// Owns: which home-screen card is highlighted. Pure value type: rows of
// varying length, moving with arrows/d-pad. Does not own what the cards are.

public struct FocusGrid: Equatable, Sendable {
    public private(set) var row: Int
    public private(set) var column: Int
    private let rowLengths: [Int]

    /// `rowLengths` must be non-empty and every row must have at least one item.
    public init?(rowLengths: [Int]) {
        guard !rowLengths.isEmpty, rowLengths.allSatisfy({ $0 > 0 }) else { return nil }
        self.rowLengths = rowLengths
        self.row = 0
        self.column = 0
    }

    /// Same position on a grid whose rows changed length (e.g. a game was
    /// added), clamped so it always points at a real item. Nil for an
    /// invalid shape, same as init.
    public func resized(rowLengths newLengths: [Int]) -> FocusGrid? {
        guard var next = FocusGrid(rowLengths: newLengths) else { return nil }
        next.row = min(row, newLengths.count - 1)
        next.column = min(column, newLengths[next.row] - 1)
        return next
    }

    /// The same grid focused on one item; nil if there's no such item.
    public func at(row: Int, column: Int) -> FocusGrid? {
        guard rowLengths.indices.contains(row), (0..<rowLengths[row]).contains(column) else { return nil }
        var next = self
        next.row = row
        next.column = column
        return next
    }

    /// Edges stop rather than wrap: on a TV, wrapping makes it easy to get lost.
    public func moved(_ direction: Direction) -> FocusGrid {
        var next = self
        switch direction {
        case .up: next.row = max(0, row - 1)
        case .down: next.row = min(rowLengths.count - 1, row + 1)
        case .left: next.column = max(0, column - 1)
        case .right: next.column = column + 1
        }
        next.column = min(next.column, next.rowLengths[next.row] - 1)
        return next
    }
}
