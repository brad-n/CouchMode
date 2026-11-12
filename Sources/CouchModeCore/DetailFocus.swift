// Owns: where focus goes on a game's details page. The buttons sit in one
// row (Play, or Resume plus Close Game for a paused game) and the
// screenshots in a row below. Edges stop rather than wrap, as everywhere.

public enum DetailFocus: Equatable, Sendable {
    case play
    /// Close Game, only shown for a paused game.
    case close
    case screenshot(Int)

    public func moved(_ direction: Direction, paused: Bool, screenshots: Int) -> DetailFocus {
        switch (direction, self) {
        case (.down, .play), (.down, .close): return screenshots > 0 ? .screenshot(0) : self
        case (.up, .screenshot): return .play
        case (.right, .play) where paused: return .close
        case (.left, .close): return .play
        case (.left, .screenshot(let i)) where i > 0: return .screenshot(i - 1)
        case (.right, .screenshot(let i)) where i < screenshots - 1: return .screenshot(i + 1)
        default: return self
        }
    }
}
