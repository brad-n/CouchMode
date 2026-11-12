// Owns: the answer to "switch to this profile" that every reader gives the
// stream home (switched, failed, or landed on a page only the person can
// finish), and what the screen says and does about each. No I/O.

import Foundation

public enum ProfileSwitch: Equatable {
    /// The service now has the chosen profile.
    case switched
    /// The profile could not be chosen; the screen stays where it was.
    case failed
    /// The service asked for something only the person can give (a form on its own
    /// website). CouchMode never fills it in: the person finishes it on the website.
    case needsPerson

    /// A reader that only knows whether the switch happened.
    public init(succeeded: Bool) { self = succeeded ? .switched : .failed }

    /// The line to show after the switch, if any.
    public func notice(profileName: String, serviceName: String) -> String? {
        switch self {
        case .switched: return nil
        case .failed: return "Couldn't switch to \(profileName)"
        case .needsPerson: return "Finish this profile on \(serviceName)"
        }
    }

    /// Whether the screen hands the person the service's website, and leaves the home as it is.
    public var handsOffToWebsite: Bool { self == .needsPerson }
}

/// Remembers the profile that was active before a switch that ended on a form only the person can
/// finish, so a later read that finds the page still stuck on that form can switch back. Pure.
public struct UnfinishedSwitch: Equatable {
    public private(set) var previous: String?

    public init() {}

    /// Notes a switch's outcome. `from` is the profile that was active before it (its name).
    public mutating func record(_ result: ProfileSwitch, from: String?) {
        switch result {
        case .needsPerson: previous = from ?? previous
        case .switched: previous = nil
        case .failed: break
        }
    }

    /// The profile to switch back to: set only while the page is still on the unfinished form.
    public func profileToRestore(onForm: Bool) -> String? { onForm ? previous : nil }

    /// The restore was done (or given up on): one try only.
    public mutating func clear() { previous = nil }
}
