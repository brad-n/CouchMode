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
