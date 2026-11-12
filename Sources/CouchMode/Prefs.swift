// Owns: the shell's own user preferences (UserDefaults), with defaults.

import Foundation

enum Prefs {
    private static let soundsKey = "uiSounds"
    private static let screensaverKey = "screensaverMinutes"

    /// Quiet interface sounds on focus/select/back. On by default.
    static var uiSounds: Bool {
        get { UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundsKey) }
    }

    /// Minutes idle on the home screen before the screensaver; 0 = off.
    static var screensaverMinutes: Int {
        get { UserDefaults.standard.object(forKey: screensaverKey) as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: screensaverKey) }
    }

    static let screensaverChoices = [2, 5, 10, 20, 0]
}
