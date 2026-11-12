// Owns: launching other Mac apps full screen from the shell (e.g. Plex HTPC)
// and telling the shell when they quit, so it can take the screen back.
// Closing them on Home is the coordinator's (HomeRouting), for any app of a
// service, however it was opened.

import AppKit
import os

@MainActor
final class AppLauncher {
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "apps")
    private var observer: NSObjectProtocol?

    /// Stops watching for the launched app to quit (it's being restarted
    /// on purpose, so the shell shouldn't come back).
    func stopWatching() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Opens the app (or brings it forward if running), handing it `url` to
    /// open when given. `onExit` runs once, when that app quits. (When an
    /// app needs care with links, like Plex HTPC, its own adapter decides.)
    func launch(bundleID: String, opening url: URL? = nil, onExit: @escaping @MainActor () -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == bundleID else { return }
            MainActor.assumeIsolated {
                if let o = self?.observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
                self?.observer = nil
                onExit()
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // macOS only lets an app take focus from the active one: hand it over.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [log] _, error in
            if let error { log.error("launch \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
        if let url {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: done)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: done)
        }
    }
}
