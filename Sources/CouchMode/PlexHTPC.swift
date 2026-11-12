// Owns: Plex HTPC (the native Plex app, which the remote drives) as the
// shell opens it: plainly (the Plex tile), or on a Continue Watching title's
// page. Learned on a real Mac (macOS 27, Plex HTPC 1.71 in Qt full screen):
//
// - A title opens by the app's own navigation, asked through its web
//   inspector (PlexInspector explains why not a plex:// link): the library
//   copy's page, Resume focused, with no key presses. The inspector is a
//   plex.ini setting the app reads when it starts, so the shell turns it on
//   before starting the app and restarts a copy that runs without it.
// - Only when that navigation can't be asked (another Plex version?): an
//   episode's Plex ID link ("plex://episode/...") opens its show's page, and
//   a movie is reached the way a person would, Right to its place in Plex's
//   own Continue Watching row and Select. Only Right and Select are ever
//   pressed: Back on Plex's Home opens an exit menu that offers Power Off.
// - A link that arrives before the app's interface has loaded is dropped, so
//   a cold app is started plainly and the link waits for its Home (its log
//   says "Navigated to screen: HomeTabbedScreen") plus a few seconds: a link
//   that lands while the window is still going full screen knocks the window
//   off the visible screen. If the window does end up off screen, the shell
//   takes the front and hands it back, which makes macOS show the app.

import AppKit
import os
import CouchModeCore

@MainActor
final class PlexHTPC {
    static let bundleID = "tv.plex.htpc"

    private enum Timing {
        static let poll: Duration = .milliseconds(500)
        static let homeAttempts = 60        // 30 s for a cold start to show Home
        static let pageAttempts = 20        // 10 s for a title's page
        static let quitAttempts = 20        // 10 s for a running copy to quit
        static let settle: Duration = .seconds(3)          // full screen done, rows drawn
        static let keyGap: Duration = .milliseconds(300)
        static let handBack: Duration = .milliseconds(800)
        static let showPoll: Duration = .milliseconds(300)
        static let showAttempts = 10        // 3 s for the window to come forward
    }
    /// At most this much of the log is read per look.
    private static let maxRead: UInt64 = 1 << 20

    private let apps: AppLauncher
    private let inspector = PlexInspectorClient()
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "plexhtpc")
    private var supportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Plex HTPC")
    }
    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Plex HTPC/Plex HTPC.log")
    }
    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first { !$0.isTerminated }
    }

    init(apps: AppLauncher) { self.apps = apps }

    var isInstalled: Bool { apps.isInstalled(Self.bundleID) }

    /// Opens Plex HTPC (or brings it forward). `onExit` runs when it quits.
    func open(onExit: @escaping @MainActor () -> Void) {
        ensureInspectorSetting()
        apps.launch(bundleID: Self.bundleID, onExit: onExit)
    }

    /// Opens Plex HTPC on a Continue Watching title's page: by the app's own
    /// navigation to the library copy (`source`, from PlexInspector.sourceURI)
    /// when it can be asked, else by its Plex ID `link`, else by its `index`
    /// in Plex's own row. `takeFront` brings the shell forward; `onExit` runs
    /// when the app quits.
    func open(continueAt index: Int, source: String?, link: URL?, takeFront: @escaping @MainActor () -> Void,
              onExit: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let source {
                switch await self.openBySource(source, takeFront: takeFront, onExit: onExit) {
                case .opened(let screen):
                    return self.log.info("Continue Watching opened on \(screen, privacy: .public)")
                case .failed(let why):
                    // Plex was asked: pressing keys over whatever it's doing would only make it worse.
                    return self.log.error("Continue Watching: Plex didn't open the title: \(why, privacy: .public)")
                case .unavailable(let why):
                    self.log.error("Continue Watching: Plex's own navigation unavailable (\(why, privacy: .public)); opening it another way")
                }
            }
            if let link {
                let report = await self.openByLink(link, takeFront: takeFront, onExit: onExit)
                self.log.info("Continue Watching by link: \(report, privacy: .public)")
            } else {
                await self.openByPosition(index, onExit: onExit)
            }
        }
    }

    /// For the debug channel: a title by link in the app as it is now.
    func openTitle(_ link: URL, takeFront: @escaping @MainActor () -> Void) async -> String {
        await openByLink(link, takeFront: takeFront, onExit: {})
    }

    // MARK: By the app's own navigation

    private func openBySource(_ source: String, takeFront: @escaping @MainActor () -> Void,
                              onExit: @escaping @MainActor () -> Void) async -> PlexInspector.Outcome {
        let ready = running != nil ? await inspector.pageSocket() != nil : false
        if !ready {
            // Not running, or running without the inspector (started before the setting): start it with it.
            guard await startFresh(onExit: onExit) else { return .unavailable("Plex HTPC never showed its Home") }
        }
        let outcome = await inspector.run(PlexInspector.openScript(sourceURI: source))
        if case .unavailable = outcome { return outcome }
        guard let app = running else { return outcome }
        // Opened, or asked and stuck: either way Plex is what the player wants in front now.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            apps.launch(bundleID: Self.bundleID, onExit: onExit)   // brings it forward, re-arms onExit
            for _ in 0..<Timing.showAttempts where !Self.windowOnScreen(app) {
                try? await Task.sleep(for: Timing.showPoll)
            }
        }
        if !Self.windowOnScreen(app), !(await handBack(app, takeFront: takeFront)) {
            log.error("Plex HTPC's window stayed off screen after opening a title")
        }
        return outcome
    }

    // MARK: By link

    private func openByLink(_ link: URL, takeFront: @escaping @MainActor () -> Void,
                            onExit: @escaping @MainActor () -> Void) async -> String {
        if running.map({ !Self.windowOnScreen($0) }) ?? true {
            // Not running, or running without its window: start it plainly.
            guard await startFresh(onExit: onExit) else { return "Plex HTPC never showed its Home" }
            try? await Task.sleep(for: Timing.settle)
        }
        guard let app = running else { return "Plex HTPC isn't running" }
        let start = logSize()
        apps.launch(bundleID: Self.bundleID, opening: link, onExit: onExit)
        let opened = await waitForScreen(since: start, where: { $0 != PlexHTPCLog.home }, attempts: Timing.pageAttempts)
        let report = "page \(opened ? "opened" : "not opened"), window \(Self.windowOnScreen(app) ? "on" : "off") screen"
        guard !Self.windowOnScreen(app) else { return report }
        guard await handBack(app, takeFront: takeFront) else {
            log.error("\(report, privacy: .public); handed back: still off screen")
            return report + "; handed back: still off screen"
        }
        return report + "; handed back: on screen"
    }

    // MARK: By position

    private func openByPosition(_ index: Int, onExit: @escaping @MainActor () -> Void) async {
        guard await startFresh(onExit: onExit) else { return log.error("Plex HTPC never showed its Home; not opening the title") }
        try? await Task.sleep(for: Timing.settle)
        for _ in 0..<index {
            guard inFront() else { return }
            KeyInjector.press(.right)
            try? await Task.sleep(for: Timing.keyGap)
        }
        guard inFront() else { return }
        KeyInjector.press(.enter)
        log.info("opened Continue Watching title \(index) in Plex HTPC by position")
    }

    // MARK: Plumbing

    /// Quits a running copy (it could be on any screen, or windowless), then
    /// starts the app (inspector on) and waits for its Home. Its exit isn't
    /// the player leaving Plex, so the shell isn't told.
    private func startFresh(onExit: @escaping @MainActor () -> Void) async -> Bool {
        if let app = running {
            apps.stopWatching()
            app.terminate()
            for _ in 0..<Timing.quitAttempts where !app.isTerminated { try? await Task.sleep(for: Timing.poll) }
            guard app.isTerminated else { log.error("Plex HTPC didn't quit"); return false }
        }
        ensureInspectorSetting()
        let start = logSize()
        apps.launch(bundleID: Self.bundleID, onExit: onExit)
        return await waitForScreen(since: start, where: { $0 == PlexHTPCLog.home }, attempts: Timing.homeAttempts)
    }

    /// Turns on the app's web inspector (127.0.0.1 only) in plex.ini, which
    /// the app reads when it starts. Only while it isn't running, so the app
    /// can't write over it on its way out.
    private func ensureInspectorSetting() {
        guard running == nil else { return }
        let ini = supportURL.appendingPathComponent("plex.ini")
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else {
            return log.error("plex.ini not readable; Plex HTPC's own navigation stays off")
        }
        guard let updated = PlexInspector.enablingInspector(in: text) else { return }
        do {
            try updated.write(to: ini, atomically: true, encoding: .utf8)
            log.info("plex.ini: web inspector on for 127.0.0.1:\(PlexInspector.port)")
        } catch {
            log.error("plex.ini not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// When the app's window went off the visible screen: the shell takes the
    /// front and hands it back, which makes macOS show the app again.
    private func handBack(_ app: NSRunningApplication, takeFront: @escaping @MainActor () -> Void) async -> Bool {
        takeFront()
        try? await Task.sleep(for: Timing.handBack)
        NSApp.yieldActivation(to: app)
        app.activate()
        for _ in 0..<Timing.showAttempts {
            try? await Task.sleep(for: Timing.showPoll)
            if Self.windowOnScreen(app) { return true }
        }
        return false
    }

    /// Plex HTPC is the app in front (the player hasn't left for the shell).
    private func inFront() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID else {
            log.info("Plex HTPC is no longer in front; stopped")
            return false
        }
        return true
    }

    /// Whether the app has a full-size window on the visible screen (window
    /// bounds and owners need no permission, unlike window titles).
    static func windowOnScreen(_ app: NSRunningApplication) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = (b["Width"] as? NSNumber)?.doubleValue, let height = (b["Height"] as? NSNumber)?.doubleValue else { return false }
            return width >= 1000 && height >= 700
        }
    }

    /// Waits until the log, past `start`, shows a screen matching `want`.
    private func waitForScreen(since start: UInt64, where want: (String) -> Bool, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            try? await Task.sleep(for: Timing.poll)
            if PlexHTPCLog.screens(in: logText(since: start)).contains(where: want) { return true }
        }
        return false
    }

    private func logSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The log written since `start` (the app may start a new log file at
    /// launch; then all of it is new), at most `maxRead` of it.
    private func logText(since start: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size >= start ? start : 0
        try? handle.seek(toOffset: max(from, size > Self.maxRead ? size - Self.maxRead : 0))
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
