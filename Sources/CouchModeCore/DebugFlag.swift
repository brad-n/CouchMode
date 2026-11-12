// Owns: the names of debug-only experiment flags the debug channel can switch.
// Flags are off by default and only honored while the debug channel is on.

import Foundation

public enum DebugFlag: String, CaseIterable, Sendable {
    /// Ask Netflix's player for Dolby Digital Plus 5.1 audio (formats list only).
    case netflix51

    public init?(name: String) { self.init(rawValue: name) }
}
