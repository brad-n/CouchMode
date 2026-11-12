// Owns: deciding whether a handed-off title that loaded paused gets the player's own Play
// pressed once. Pure; the coordinator reads the page and presses the key.

public enum PlayNudge {
    /// What the page's `<video>` elements show.
    public enum VideoState: Equatable, Sendable {
        /// A video is playing (not paused, ready).
        case rolling
        /// A video is ready to play (readyState >= 3) and paused, and none is rolling.
        case readyPaused
        /// No video, or none ready yet.
        case other
    }

    /// Seconds after media is allowed before a paused, ready video is nudged (autoplay gets this long).
    public static let graceSeconds = 3.5

    /// True only once per handoff, after the grace, when a ready video sits paused and none rolls.
    public static func shouldPress(state: VideoState, secondsSinceAllowed: Double, alreadyPressed: Bool) -> Bool {
        !alreadyPressed && secondsSinceAllowed >= graceSeconds && state == .readyPaused
    }

    /// Page script (function body) returning "rolling", "paused" or "other" (see `state(fromProbe:)`).
    public static let probeScript = """
    const vs = Array.from(document.querySelectorAll('video'));
    if (vs.some(v => !v.paused && v.readyState >= 3)) return 'rolling';
    if (vs.some(v => v.paused && v.readyState >= 3)) return 'paused';
    return 'other';
    """

    public static func state(fromProbe value: String?) -> VideoState {
        switch value {
        case "rolling": return .rolling
        case "paused": return .readyPaused
        default: return .other
        }
    }
}
