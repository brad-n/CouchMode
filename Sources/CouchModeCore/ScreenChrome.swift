// Owns: the rules of the shared screen header: how the clock is written, and
// which header each screen gets. Drawing it is the app's ScreenHeader view.

import Foundation

/// Every screen the shell can show, for the choice of header.
public enum ScreenKind: Sendable, CaseIterable {
    case home, console, allConsoles, gameDetail, plexDetail, settings, bluetooth
    case streamHome, streamLoading, streamDetail, streamSearch
}

public enum HeaderStyle: Sendable, Equatable {
    /// Clock only.
    case timeOnly
    /// Clock, the date under it, and the connected devices beside it (Home).
    case timeDateAndDevices

    public var showsTime: Bool { true }
    public var showsDate: Bool { self == .timeDateAndDevices }
    public var showsDevices: Bool { self == .timeDateAndDevices }
}

public enum ScreenHeaderPolicy {
    /// Every screen has the clock; Home alone adds the date and devices.
    public static func style(for kind: ScreenKind) -> HeaderStyle {
        kind == .home ? .timeDateAndDevices : .timeOnly
    }

    /// Only a service's home has the Search and profile chips in its header.
    public static func hasChips(_ kind: ScreenKind) -> Bool { kind == .streamHome }
}

public enum ClockText {
    /// "8:57 PM" or "20:57": the time in the viewer's own hour cycle.
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale; f.timeZone = timeZone
        f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: date)
    }

    /// "Wednesday, Nov 11".
    public static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale; f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f.string(from: date)
    }
}
