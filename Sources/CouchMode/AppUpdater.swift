// Owns: self-update through Sparkle. Starts the standard updater controller
// (feed URL and public key come from Info.plist) and exposes the two things
// Settings needs: check now, and the automatic-check switch. Does not decide
// when to install; Sparkle's own dialogs do that.

import Foundation
import Sparkle

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?

    /// Only a packaged build (one whose Info.plist names a feed) updates itself:
    /// `swift run` and demo mode never touch the network for updates.
    private init() {
        let packaged = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = packaged && !DemoMode.isOn
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// Starts the updater at launch (its scheduled checks begin then).
    func start() { _ = controller }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
