// Owns: the decision, for a service whose player is not a page of its own (it
// opens over the title's page), of when the person has left the player: the
// service's "player is showing" check has said yes, then said no twice in a
// row. Pure; the app asks the page once a second and feeds the answers in.

public struct PlayerShownWatch: Equatable, Sendable {
    /// One answer a second; a handoff is watched for at most this long (8 hours).
    public static let maxPolls = 8 * 3600
    private var sawPlayer = false
    private var goneAnswers = 0
    private var polls = 0

    public init() {}

    /// True once the watch has used up its polls.
    public var isExpired: Bool { polls >= Self.maxPolls }

    /// Feeds one answer (nil: the page didn't answer, which proves nothing either way).
    /// Returns true when the player has been left.
    public mutating func record(_ shown: Bool?) -> Bool {
        polls += 1
        guard let shown else { return false }
        if shown {
            sawPlayer = true
            goneAnswers = 0
            return false
        }
        guard sawPlayer else { return false }
        goneAnswers += 1
        return goneAnswers >= 2
    }
}
