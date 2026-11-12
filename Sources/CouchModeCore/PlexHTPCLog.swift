// Owns: reading Plex HTPC's log for what the app is showing. Each screen it
// opens is a line "... Navigated to screen: <Name>" (HomeTabbedScreen, the
// show page ShowTabbedScreen, the player VisualMediaPlaybackScreen...).
// Leaving the player is not logged, so this is only good for "it opened".

public enum PlexHTPCLog {
    public static let home = "HomeTabbedScreen"
    private static let marker = "Navigated to screen: "

    /// The screens opened in this stretch of log text, in order.
    public static func screens(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let r = line.range(of: marker) else { return nil }
            let name = line[r.upperBound...].prefix { !$0.isWhitespace }
            return name.isEmpty ? nil : String(name)
        }
    }
}
