// Owns: whether macOS's "require password after the screen saver / display
// sleep" is on, read from `sysadminctl -screenLock status` output, and the
// words the shell uses about it (the Settings value, the explanation, the
// first-run note). Does not run anything; the app passes in the output.

import Foundation

public enum ScreenLockStatus: Equatable, Sendable {
    case off
    /// On, asking for the password after `delaySeconds` (0 = immediately).
    case on(delaySeconds: Int)

    /// Reads the tool's output. macOS prefixes each line with a timestamp and process id, so only the
    /// text after "screenLock" matters. nil when the output is none of the known forms.
    public static func parse(_ output: String) -> ScreenLockStatus? {
        for line in output.split(whereSeparator: \.isNewline).prefix(20) {
            guard let range = line.range(of: "screenLock", options: .caseInsensitive) else { continue }
            let rest = line[range.upperBound...].lowercased()
            if rest.contains(" is off") { return .off }
            if rest.contains(" is immediate") { return .on(delaySeconds: 0) }
            if rest.contains("delay is") {
                let digits = rest.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
                if let seconds = digits { return .on(delaySeconds: seconds) }
            }
        }
        return nil
    }

    public var isOn: Bool { if case .on = self { return true } else { return false } }

    /// The Settings row's value: "Off", "On (immediately)" or "On (after 5 min)".
    public var valueText: String {
        switch self {
        case .off: return "Off"
        case .on(let s) where s <= 0: return "On (immediately)"
        case .on(let s) where s < 60: return "On (after \(s) sec)"
        case .on(let s): return "On (after \((s + 30) / 60) min)"
        }
    }

    /// What to tell the person when it is on.
    public static let explanation = "macOS asks for your password after the TV goes idle, and a remote can't type it. "
        + "Turn it off in System Settings \u{203A} Lock Screen \u{203A} \u{201C}Require password after screen saver begins or display is turned off\u{201D} "
        + "\u{2192} Never, or run `sysadminctl -screenLock off` in Terminal."

    /// The note on the first-run Done step; nil when the lock is off or unknown.
    public static func setupNote(_ status: ScreenLockStatus?) -> String? {
        status?.isOn == true ? explanation : nil
    }
}
