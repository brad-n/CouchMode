// Owns: the in-memory state of debug-only experiment flags. Off at every
// launch, and ignored unless the debug channel is on.

import Foundation
import CouchModeCore

@MainActor
enum DebugFlags {
    private static var on: Set<DebugFlag> = []

    static func isOn(_ flag: DebugFlag) -> Bool { DebugServer.isEnabled && on.contains(flag) }

    static func set(_ flag: DebugFlag, _ value: Bool) {
        if value { on.insert(flag) } else { on.remove(flag) }
    }
}
