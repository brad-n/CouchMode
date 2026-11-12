// Owns: Close Game from a paused game's tile (Home, a console screen): which keys ask
// for it, and the press-again confirm. Closing loses unsaved progress, so the first
// press only asks. Pure; the clock is passed in.

import Foundation

public struct CloseGameFlow: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The focused tile is not a paused game.
        case nothing
        /// First press: show "press again to close".
        case askToConfirm
        /// Second press in time: close the game.
        case close
    }

    private var gate = ConfirmGate()

    public init() {}

    /// X and Delete close a paused game from its tile. ⌘⌫ stays Home.
    public static func isCloseKey(keyCode: UInt16, command: Bool) -> Bool {
        !command && (keyCode == 7 || keyCode == KeyboardHome.delete)
    }

    public mutating func press(game: String, isPaused: Bool, now: Date) -> Outcome {
        guard isPaused else { return .nothing }
        return gate.press("close-" + game, now: now) ? .close : .askToConfirm
    }

    /// The game file whose close is waiting for a second press.
    public func pending(now: Date) -> String? {
        gate.pending(now: now).map { String($0.dropFirst("close-".count)) }
    }

    /// Focus moved away: a later press asks again.
    public mutating func disarm() { gate = ConfirmGate() }
}
