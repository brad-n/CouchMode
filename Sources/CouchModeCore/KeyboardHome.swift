// Owns: the keyboard's way back from a game: which keys mean Home (⌘⌫, or Escape held
// about a second, like the remote's held Home) and for which app in front they apply.
// Pure: key codes and times are passed in; the app target listens for the keys.

import Foundation

public enum KeyboardHome {
    /// macOS virtual key codes.
    public static let escape: UInt16 = 53
    public static let delete: UInt16 = 51

    /// ⌘⌫: Home, pressed once.
    public static func isHomeChord(keyCode: UInt16, command: Bool) -> Bool {
        command && keyCode == delete
    }

    /// The key whose hold (EscapeHold) is Home.
    public static func isHoldKey(keyCode: UInt16) -> Bool { keyCode == escape }

    /// Only games take these shortcuts from the keyboard: in any other app ⌘⌫ is
    /// Move to Trash and Escape is Cancel. (Other apps still have the remote's Home.)
    public static func appliesTo(front: FrontApp) -> Bool {
        switch front {
        case .switchGame, .retroArch: return true
        case .shell, .streamingApp, .other: return false
        }
    }
}

/// A held Escape. `keyDown` starts it (key repeats are ignored), `poll` is asked on a
/// timer and answers true once when the hold time has passed, `keyUp` cancels.
public struct EscapeHold: Equatable, Sendable {
    public static let holdTime: TimeInterval = 1.0

    private var downAt: Date?
    private var fired = false

    public init() {}

    public var isDown: Bool { downAt != nil }

    public mutating func keyDown(now: Date) {
        if downAt == nil { downAt = now; fired = false }
    }

    public mutating func keyUp() {
        downAt = nil
        fired = false
    }

    /// True exactly once per hold, when the key has been down for the hold time.
    public mutating func poll(now: Date) -> Bool {
        guard let downAt, !fired, now.timeIntervalSince(downAt) >= Self.holdTime else { return false }
        fired = true
        return true
    }
}
