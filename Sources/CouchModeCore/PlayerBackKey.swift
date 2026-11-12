// Owns: which physical keys CouchMode takes as Back while a handed-off title plays on
// a service's own page (every other key goes to the site's player). Pure; no I/O.

public enum PlayerBackKey {
    /// macOS virtual key codes: Escape (what the remote and keyboard Back send) and Delete/Backspace.
    public static let escape: UInt16 = 53
    public static let delete: UInt16 = 51

    /// True when `keyCode` is Back for CouchMode: only while a handed-off title is on screen.
    public static func isBack(keyCode: UInt16, handedOffTitleShowing: Bool) -> Bool {
        handedOffTitleShowing && (keyCode == escape || keyCode == delete)
    }

    /// While a sign-in page is up during setup only Escape is Back: Delete is the person's to type with.
    public static func isSignInBack(keyCode: UInt16, signInShowing: Bool) -> Bool {
        signInShowing && keyCode == escape
    }
}
