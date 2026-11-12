// Owns: the names of debug-only experiment flags the debug channel can switch.
// Flags are off by default and only honored while the debug channel is on.

import Foundation

public enum DebugFlag: String, CaseIterable, Sendable {
    /// Inject the media format probe (MSE hooks) into service pages.
    case mediaprobe
    /// Pretend macOS's screen lock is on (5 min), to see the Settings card without changing the Mac.
    case fakescreenlock

    public init?(name: String) { self.init(rawValue: name) }
}
