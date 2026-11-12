// Owns: actions on the Mac itself (sleep). The only place the shell runs
// another program, always with an argument array and a time limit.

import Foundation
import os

@MainActor
final class SystemActions {
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "system")
    private let commandTimeout: TimeInterval = 10

    func sleep() { run("/usr/bin/pmset", ["sleepnow"]) }

    /// Asks loginwindow for a normal restart (apps get to save; no admin rights needed).
    func restart() { run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrrst»"]) }

    /// Opens macOS's Bluetooth settings for pairing. Game controllers and most
    /// headphones are Bluetooth LE HID devices, which an app cannot pair itself.
    func openBluetoothSettings() { run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Bluetooth"]) }

    /// Privacy & Security > Accessibility, where the remote-in-other-apps permission lives.
    func openAccessibilitySettings() {
        run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout) {
                if p.isRunning { p.terminate() }
            }
        } catch {
            log.error("\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
