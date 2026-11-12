// Owns: self-update through Sparkle with CouchMode's own screens. Starts the
// updater with the TV user driver (UpdateDriver), holds the update flow state
// (UpdateFlow, from Core) that the update screen and the Home notice read,
// and turns remote presses into replies to Sparkle. Does not draw anything.

import Combine
import Foundation
import Sparkle
import CouchModeCore
import os

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var flow = UpdateFlow()

    /// Called after every change, so the coordinator can close the screen or refresh the Home notice.
    var onChange: (() -> Void)?

    // Sparkle's replies for the moment on screen; each is used once.
    var foundReply: ((SPUUserUpdateChoice) -> Void)?
    var cancelHandler: (() -> Void)?
    var acknowledgement: (() -> Void)?

    private var updater: SPUUpdater?
    private var driver: UpdateDriver?
    /// True while the debug channel shows a made-up update: presses never reach Sparkle.
    private var isFake = false
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "updater")

    /// Only a packaged build (one whose Info.plist names a feed) updates itself:
    /// `swift run` and demo mode never touch the network for updates.
    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil, !DemoMode.isOn else { return }
        let driver = UpdateDriver(updater: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
        } catch {
            log.error("updater start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts the updater at launch (its scheduled checks begin then).
    func start() { _ = updater }

    var isAvailable: Bool { updater != nil }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// The version waiting to be installed, if a check found one and it was not installed.
    var pendingVersion: String? { flow.pendingVersion }

    // MARK: Events

    func apply(_ event: UpdateFlow.Event) {
        flow.apply(event)
        onChange?()
    }

    /// "Check for Updates" from Settings: the screen shows at once, Sparkle's answers fill it in.
    func beginUserCheck() {
        isFake = false
        apply(.checkStarted)
        guard let updater else {
            apply(.failed(.other("Updates are off in this build.")))
            return
        }
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        } else {
            apply(.failed(.other("An update is already in progress. Try again in a moment.")))
        }
    }

    /// A remote press on the update screen.
    func press(_ intent: ShellIntent) {
        let action = flow.press(intent)
        if !isFake {
            switch action {
            case .none: break
            case .install: take(&foundReply)?(.install)
            case .later: take(&foundReply)?(.dismiss)
            case .cancel: take(&cancelHandler)?()
            case .acknowledge: take(&acknowledgement)?()
            }
        }
        onChange?()
    }

    private func take<T>(_ slot: inout T?) -> T? {
        defer { slot = nil }
        return slot
    }

    // MARK: Debug

    /// Shows a made-up state on the update screen (debug channel only). Nothing reaches Sparkle.
    func debugShow(_ state: String) -> Bool {
        var f = UpdateFlow()
        switch state {
        case "checking": f.apply(.checkStarted)
        case "available":
            f.apply(.checkStarted)
            f.apply(.found(version: "9.9.9", notes: ReleaseNotes.summary(html: "<ul><li>Faster Home screen</li><li>Updates install from the couch</li></ul>",
                                                       maxLines: 5, maxChars: 400),
                           userInitiated: true))
        case "downloading":
            f.apply(.checkStarted)
            f.apply(.found(version: "9.9.9", notes: "", userInitiated: true))
            _ = f.press(.select)
            f.apply(.expectedLength(1000))
            f.apply(.received(420))
        case "installing":
            f.apply(.checkStarted)
            f.apply(.found(version: "9.9.9", notes: "", userInitiated: true))
            _ = f.press(.select)
            f.apply(.installing)
        case "uptodate": f.apply(.checkStarted); f.apply(.notFound)
        case "unreachable": f.apply(.checkStarted); f.apply(.failed(.unreachable))
        case "failed": f.apply(.checkStarted); f.apply(.failed(.other("The update could not be unpacked.")))
        default: return false
        }
        isFake = true
        flow = f
        onChange?()
        return true
    }
}
