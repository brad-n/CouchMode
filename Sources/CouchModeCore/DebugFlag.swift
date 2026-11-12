// Owns: the names of debug-only experiment flags the debug channel can switch.
// Flags are off by default and only honored while the debug channel is on.

import Foundation

public enum DebugFlag: String, CaseIterable, Sendable {
    /// Inject the media format probe (MSE hooks) into service pages.
    case mediaprobe

    public init?(name: String) { self.init(rawValue: name) }
}
