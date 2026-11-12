// Owns: which rows of a long vertical list are visible for the focused row:
// the first visible index, and whether more rows lie above or below. Pure;
// the Settings screen draws what this says.

import Foundation

public struct ListWindow: Equatable, Sendable {
    public let first: Int
    public let count: Int
    public let capacity: Int

    public init(first: Int, count: Int, capacity: Int) {
        self.count = max(0, count)
        self.capacity = max(1, capacity)
        self.first = min(max(0, first), max(0, self.count - self.capacity))
    }

    /// The window after focus moves to `focused`. It only slides when focus
    /// would leave the visible area, keeping one row of context on the
    /// leading and trailing side where the list has more (none if the
    /// capacity is under three rows).
    public static func following(_ current: ListWindow, focused: Int, count: Int, capacity: Int) -> ListWindow {
        let cap = max(1, capacity)
        let total = max(0, count)
        guard total > cap else { return ListWindow(first: 0, count: total, capacity: cap) }
        let f = min(max(0, focused), total - 1)
        let margin = cap >= 3 ? 1 : 0
        var first = min(max(0, current.first), total - cap)
        if f < first + margin { first = f - margin }
        if f > first + cap - 1 - margin { first = f - cap + 1 + margin }
        return ListWindow(first: first, count: total, capacity: cap)
    }

    public var range: Range<Int> { first..<min(count, first + capacity) }
    public var hasMoreAbove: Bool { first > 0 }
    public var hasMoreBelow: Bool { first + capacity < count }

    /// How many rows fit in `height` when each takes `rowHeight` (at least one).
    public static func capacity(height: Double, rowHeight: Double) -> Int {
        guard rowHeight > 0, height > 0 else { return 1 }
        return max(1, Int((height / rowHeight).rounded(.down)))
    }
}
