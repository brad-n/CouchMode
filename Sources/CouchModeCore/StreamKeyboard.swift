// Owns: the on-screen keyboard for typing a streaming search with a remote or
// controller: its keys, which one is focused, and the text typed so far
// (capped at StreamLimits.maxQueryLength). Pure value type; does not own
// drawing or searching.

public struct StreamKeyboard: Equatable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case space, delete, clear
    }

    /// Keys per letter/digit row.
    public static let columns = 6

    /// a-z then 0-9 in rows of `columns`, then a row of the three actions.
    public static let layout: [[Key]] = {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(Key.character)
        var rows = stride(from: 0, to: chars.count, by: columns).map { Array(chars[$0..<min($0 + columns, chars.count)]) }
        rows.append([.space, .delete, .clear])
        return rows
    }()

    public private(set) var text = ""
    private var grid: FocusGrid

    public init() {
        grid = FocusGrid(rowLengths: Self.layout.map(\.count))!
    }

    public var focusedRow: Int { grid.row }
    public var focusedColumn: Int { grid.column }
    public var focusedKey: Key { Self.layout[grid.row][grid.column] }

    public mutating func move(_ direction: Direction) {
        grid = grid.moved(direction)
    }

    /// Focus a position; ignored when there's no such key.
    public mutating func focus(row: Int, column: Int) {
        if let next = grid.at(row: row, column: column) { grid = next }
    }

    /// Focus a key; ignored when the layout has no such key.
    public mutating func focus(key: Key) {
        for (r, row) in Self.layout.enumerated() {
            if let c = row.firstIndex(of: key) { focus(row: r, column: c); return }
        }
    }

    /// Types the focused key, or performs its action.
    public mutating func press() {
        switch focusedKey {
        case .character(let ch): append(ch)
        case .space: if !text.isEmpty, text.last != " " { append(" ") }
        case .delete: if !text.isEmpty { text.removeLast() }
        case .clear: text = ""
        }
    }

    /// Empties the text without moving focus (for Back).
    public mutating func clearText() { text = "" }

    private mutating func append(_ ch: Character) {
        guard text.count < StreamLimits.maxQueryLength else { return }
        text.append(ch)
    }
}
