// Owns: "press to cycle" choice logic used by System cards (e.g. audio output):
// each press moves to the next option, wrapping at the end.

public enum Cycle {
    /// The option after `current`; the first option when `current` is absent
    /// or unknown; nil when there are no options.
    public static func next<T: Equatable>(after current: T?, in options: [T]) -> T? {
        guard !options.isEmpty else { return nil }
        guard let current, let i = options.firstIndex(of: current) else { return options[0] }
        return options[(i + 1) % options.count]
    }
}
