// Owns: "press again to confirm" for actions that are hard to undo from the
// couch (exit to desktop, restart). The first press arms; a second press of
// the SAME action within the window confirms. The clock is passed in.

import Foundation

public struct ConfirmGate: Equatable, Sendable {
    public static let window: TimeInterval = 4

    private var armed: (action: String, at: Date)?

    public init() {}

    public static func == (a: ConfirmGate, b: ConfirmGate) -> Bool {
        a.armed?.action == b.armed?.action && a.armed?.at == b.armed?.at
    }

    /// Returns true when this press confirms the action.
    public mutating func press(_ action: String, now: Date) -> Bool {
        if let armed, armed.action == action, now.timeIntervalSince(armed.at) <= Self.window {
            self.armed = nil
            return true
        }
        armed = (action, now)
        return false
    }

    /// The action currently waiting for its second press, if still in time.
    public func pending(now: Date) -> String? {
        guard let armed, now.timeIntervalSince(armed.at) <= Self.window else { return nil }
        return armed.action
    }
}
