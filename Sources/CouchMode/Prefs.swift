// Owns: the shell's global user preferences (UserDefaults), with defaults:
// sounds and screensaver. Per-app settings live in the config (AppConfigStore).

import Foundation
import CouchModeCore

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

    /// Netflix 5.1 audio: auto (follow the output's channel count), on, or off.
    /// Per app, so it lives in the machine's config (the Netflix entry), not here.
    @MainActor static var netflix51: Netflix51 {
        get { Netflix51(stored: AppConfigStore.shared.setting("netflix51", for: "netflix")?.string) }
        set { AppConfigStore.shared.set("netflix51", .string(newValue.rawValue), for: "netflix") }
    }

    static let screensaverChoices = [2, 5, 10, 20, 0]
}
