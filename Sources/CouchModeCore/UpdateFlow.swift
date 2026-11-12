// Owns: the in-app software update screen as a state machine. Sparkle's
// events go in (UpdateFlow.Event); what the screen shows (phase, buttons,
// focus) and what a remote press does (UpdateFlow.Action) come out. Pure:
// talking to Sparkle and drawing belong to the app target.

import Foundation

public struct UpdateFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case available(version: String, notes: String)
        case downloading(fraction: Double?)
        case installing
        case upToDate
        /// No feed yet, no network or the server is down: a friendly line, not an error.
        case unreachable
        case failed(String)
    }

    public enum Button: Equatable, Sendable {
        case installNow, later, ok

        public var label: String {
            switch self {
            case .installNow: return "Install now"
            case .later: return "Later"
            case .ok: return "OK"
            }
        }
    }

    /// What the app must do after a press.
    public enum Action: Equatable, Sendable {
        case none
        case install        // reply "install" to Sparkle
        case later          // reply "dismiss" to Sparkle; the Home notice stays
        case cancel         // stop the check or download
        case acknowledge    // OK on a result line
    }

    public enum Event: Equatable, Sendable {
        case checkStarted
        case found(version: String, notes: String, userInitiated: Bool)
        case notFound
        case failed(UpdateFailure)
        case expectedLength(UInt64)
        case received(UInt64)
        case extracting
        case installing
        case dismissed
    }

    public private(set) var phase: Phase = .idle
    /// A found update that was not installed: drives the Home notice.
    public private(set) var pendingVersion: String?
    private var focusIndex = 0
    private var expected: UInt64 = 0
    private var got: UInt64 = 0

    public init() {}

    public var buttons: [Button] {
        switch phase {
        case .available: return [.installNow, .later]
        case .upToDate, .unreachable, .failed: return [.ok]
        case .idle, .checking, .downloading, .installing: return []
        }
    }

    public var focused: Button? {
        let b = buttons
        return b.indices.contains(focusIndex) ? b[focusIndex] : nil
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .checkStarted:
            enter(.checking)
        case .found(let version, let notes, let userInitiated):
            pendingVersion = version
            if userInitiated || phase == .checking { enter(.available(version: version, notes: notes)) }
        case .notFound:
            guard phase != .idle else { return }   // an automatic check says nothing
            pendingVersion = nil
            enter(.upToDate)
        case .failed(let failure):
            guard phase != .idle else { return }
            switch failure {
            case .unreachable: enter(.unreachable)
            case .other(let message): enter(.failed(message))
            }
        case .expectedLength(let n):
            if case .downloading = phase { expected = n }
        case .received(let n):
            guard case .downloading = phase else { return }
            got += n
            enter(.downloading(fraction: expected > 0 ? min(1, Double(got) / Double(expected)) : nil), keepProgress: true)
        case .extracting, .installing:
            switch phase {
            case .downloading, .installing: enter(.installing)
            default: break
            }
        case .dismissed:
            if phase != .installing { enter(.idle) }
        }
    }

    public mutating func press(_ intent: ShellIntent) -> Action {
        switch phase {
        case .idle, .installing: return .none
        case .checking, .downloading:
            switch intent {
            case .back, .home: enter(.idle); return .cancel
            default: return .none
            }
        case .available:
            switch intent {
            case .move(.left): focusIndex = max(0, focusIndex - 1); return .none
            case .move(.right): focusIndex = min(buttons.count - 1, focusIndex + 1); return .none
            case .back, .home: return later()
            case .select:
                if focused == .later { return later() }
                pendingVersion = nil
                enter(.downloading(fraction: nil))
                return .install
            default: return .none
            }
        case .upToDate, .unreachable, .failed:
            switch intent {
            case .select, .back, .home: enter(.idle); return .acknowledge
            default: return .none
            }
        }
    }

    private mutating func later() -> Action {
        enter(.idle)
        return .later
    }

    private mutating func enter(_ next: Phase, keepProgress: Bool = false) {
        phase = next
        focusIndex = 0
        if !keepProgress { expected = 0; got = 0 }
    }
}

extension UpdateFlow.Phase {
    public var title: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking\u{2026}"
        case .available(let version, _): return "Update available: \(version)"
        case .downloading: return "Downloading\u{2026}"
        case .installing: return "Installing\u{2026}"
        case .upToDate: return "You\u{2019}re up to date"
        case .unreachable: return "Can\u{2019}t reach updates"
        case .failed: return "Update problem"
        }
    }

    public var subtitle: String {
        switch self {
        case .idle: return ""
        case .checking: return "Looking for a new version"
        case .available: return "A new version of CouchMode is ready"
        case .downloading: return "Back to cancel"
        case .installing: return "CouchMode will restart"
        case .upToDate: return "This is the latest version of CouchMode"
        case .unreachable: return "No update is available to check right now. Try again later."
        case .failed(let message): return message
        }
    }
}

/// Which Sparkle errors read as "can't reach updates" and which are real problems.
public enum UpdateFailure: Equatable, Sendable {
    case unreachable
    case other(String)

    public static let maxMessage = 120
    static let sparkleDomain = "SUSparkleErrorDomain"
    static let generic = "The update didn\u{2019}t finish."

    /// A missing or unreadable feed (404 before the first release, no network,
    /// a timeout) is `unreachable`. Anything else keeps a short message.
    public static func classify(domain: String, code: Int, message: String) -> UpdateFailure {
        if domain == NSURLErrorDomain { return .unreachable }
        if domain == sparkleDomain, code == 1000 || code == 1002 { return .unreachable }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .other(generic) }
        return .other(trimmed.count > maxMessage ? String(trimmed.prefix(maxMessage - 1)) + "\u{2026}" : trimmed)
    }
}

/// Appcast release notes (HTML or plain text) shortened to a few plain lines for a TV.
public enum ReleaseNotes {
    static let maxInput = 20_000

    public static func summary(html: String?, maxLines: Int, maxChars: Int) -> String {
        guard var text = html.map({ String($0.prefix(maxInput)) }), !text.isEmpty else { return "" }
        for block in ["script", "style"] {
            while let open = text.range(of: "<\(block)", options: .caseInsensitive),
                  let close = text.range(of: "</\(block)>", options: .caseInsensitive, range: open.lowerBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        // Block tags end a line; every other tag disappears.
        var out = ""
        var tag = ""
        var inTag = false
        for ch in text {
            if inTag {
                if ch == ">" {
                    inTag = false
                    let name = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).prefix { $0.isLetter || $0.isNumber }
                    if ["p", "br", "li", "div", "h1", "h2", "h3", "h4", "ul", "ol", "tr"].contains(String(name)) { out.append("\n") }
                } else { tag.append(ch) }
            } else if ch == "<" { inTag = true; tag = "" } else { out.append(ch) }
        }
        let decoded = out
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        let lines = decoded.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(max(0, maxLines))
        let joined = lines.joined(separator: "\n")
        guard joined.count > maxChars else { return joined }
        return String(joined.prefix(max(0, maxChars - 1))) + "\u{2026}"
    }
}

/// When Home shows "Update available" and when nothing may. The notice is a
/// quiet line on Home only: never over a playing title, a game or another screen.
public enum UpdateNotice {
    public enum Context: Equatable, Sendable { case home, game, playback, otherScreen, updateScreen }

    public static func context(onHome: Bool, gameRunning: Bool, servicePlaying: Bool, updateScreenOpen: Bool) -> Context {
        if updateScreenOpen { return .updateScreen }
        if servicePlaying { return .playback }
        if onHome { return gameRunning ? .game : .home }
        return .otherScreen
    }

    public static func line(pending: String?, context: Context) -> String? {
        guard pending != nil, context == .home else { return nil }
        return "Update available \u{2014} open Settings to install"
    }

    /// Only a person pressing "Check for Updates" may put the update screen up.
    public static func mayOpenScreen(userInitiated: Bool) -> Bool { userInitiated }
}
