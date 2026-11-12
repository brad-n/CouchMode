// Owns: the games folder on disk and running games: RetroArch for retro
// consoles, and Switch games, which are Mac apps of their own (NX2Apple
// builds). The only code that knows RetroArch's install path, cores folder
// and command line, and the NX2Apple front-end contract. Shell-specific
// RetroArch settings live in our own config file, appended on launch and
// never saved into RetroArch's own settings.

import AppKit
import Darwin
import os
import CouchModeCore

@MainActor
final class GameLauncher {
    enum LaunchResult: Equatable {
        case started
        /// The game was already open (paused): it came back to the front.
        case resumed
        /// A different Switch game is open; it has to close first.
        case otherGameOpen(URL)
        case failed
    }

    /// The Switch game that is open, playing or paused in the background.
    private struct AppGame {
        let url: URL
        let bundleID: String
        /// Frozen by the shell's Home (SIGSTOP): no sound, no work.
        var frozen = false
        /// Hidden and about to be frozen.
        var freezing = false
    }

    private enum Timing {
        /// How long a hidden game gets to let go of the screen before it's frozen.
        static let freezeAfterHide: TimeInterval = 1.5
        /// Polite quit, then SIGTERM, then SIGKILL, for a game that won't close.
        static let quitGrace: TimeInterval = 8
        static let killGrace: TimeInterval = 14
    }

    private let log = Logger(subsystem: "local.brad.htpcshell", category: "games")
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var retroArch: Process?
    private var appGame: AppGame?
    /// Bumped by every resume, so a freeze scheduled before it is dropped.
    private var freezeGeneration = 0
    /// What to do once the closing Switch game is gone (at most one).
    private var afterAppGameExit: [@MainActor () -> Void] = []

    /// Runs on the main actor whenever a game (RetroArch or a Switch game) quits.
    var onExit: (@MainActor () -> Void)?
    /// NX2Apple's DM_HID_MAP for the raw HID pad that's connected, if any
    /// (HIDPadLayout): without it a game guesses 8BitDo's numbering.
    var hidMap: (@MainActor () -> String?)?

    static let retroArchBundleID = "com.libretro.dist.RetroArch"

    var gamesDirectory: URL { home.appendingPathComponent("Games") }
    private var coresDirectory: URL { home.appendingPathComponent("Library/Application Support/RetroArch/cores") }
    private var shellConfig: URL { home.appendingPathComponent("Library/Application Support/HTPCShell/retroarch-shell.cfg") }

    private var retroArchBinary: URL? {
        let candidates = [home.appendingPathComponent("Applications/RetroArch.app"), URL(fileURLWithPath: "/Applications/RetroArch.app")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?
            .appendingPathComponent("Contents/MacOS/RetroArch")
    }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appDidTerminate(ended?.bundleIdentifier) }
        }
    }

    func folder(for console: Console) -> URL { gamesDirectory.appendingPathComponent(console.folder) }

    func games(for console: Console) -> [Game] {
        if DemoMode.isOn { return DemoMode.games(for: console) }
        let dir = folder(for: console)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var sizes: [String: Int64] = [:]
        for n in names where !console.gamesAreApps {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
            if let size = attrs?[.size] as? NSNumber { sizes[n] = size.int64Value }
        }
        return GameLibrary.games(fileNames: names, for: console, sizes: sizes)
    }

    var isRunningGame: Bool { isRunningRetroArch || appGame != nil }
    var isRunningRetroArch: Bool { retroArch?.isRunning ?? false }

    /// The open Switch game's app, if any (playing or paused).
    var openAppGameURL: URL? { appGame?.url }

    /// True when this game is the Switch game that's open in the background.
    func isOpen(_ game: Game, on console: Console) -> Bool {
        console.gamesAreApps && appGame?.url == folder(for: console).appendingPathComponent(game.fileName)
    }

    /// Short status for the debug channel.
    var debugStatus: String {
        if isRunningRetroArch { return "retroarch" }
        guard let g = appGame else { return "none" }
        return g.url.deletingPathExtension().lastPathComponent + (g.frozen ? " (frozen)" : " (open)")
    }

    // MARK: Which app is which

    func isRetroArch(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == Self.retroArchBundleID || app.processIdentifier == retroArch?.processIdentifier
    }

    /// A Switch game: an app inside one of the app-games folders.
    func isAppGame(_ app: NSRunningApplication) -> Bool {
        guard let parent = app.bundleURL?.deletingLastPathComponent().standardizedFileURL.path else { return false }
        return ConsoleCatalog.all.contains { $0.gamesAreApps && folder(for: $0).standardizedFileURL.path == parent }
    }

    // MARK: Recently played (UserDefaults: console id -> file name -> date)

    private static let lastPlayedKey = "lastPlayed"

    func lastPlayed(for console: Console) -> [String: Date] {
        if DemoMode.isOn { return DemoMode.lastPlayed(for: console) }
        let all = UserDefaults.standard.dictionary(forKey: Self.lastPlayedKey) as? [String: [String: Date]] ?? [:]
        return all[console.id] ?? [:]
    }

    private func markPlayed(_ game: Game, on console: Console) {
        var all = UserDefaults.standard.dictionary(forKey: Self.lastPlayedKey) as? [String: [String: Date]] ?? [:]
        var forConsole = all[console.id] ?? [:]
        forConsole[game.fileName] = Date()
        // Bounded: keep the 50 most recent per console.
        if forConsole.count > 50 {
            for (k, _) in forConsole.sorted(by: { $0.value < $1.value }).prefix(forConsole.count - 50) { forConsole[k] = nil }
        }
        all[console.id] = forConsole
        UserDefaults.standard.set(all, forKey: Self.lastPlayedKey)
    }

    // MARK: Starting games

    /// Starts the game full screen, or brings it back if it's the open
    /// Switch game. `onExit` runs when it quits.
    func launch(_ game: Game, on console: Console) -> LaunchResult {
        if DemoMode.isOn { return .failed }   // demo games are not files; nothing is ever started
        let result = console.gamesAreApps
            ? launchApp(folder(for: console).appendingPathComponent(game.fileName))
            : launchRetroArch(game, on: console)
        if result == .started || result == .resumed { markPlayed(game, on: console) }
        return result
    }

    private func launchRetroArch(_ game: Game, on console: Console) -> LaunchResult {
        // A paused Switch game can stay paused; only one RetroArch at a time.
        guard !isRunningRetroArch, let binary = retroArchBinary else {
            log.error("cannot launch: RetroArch missing or already running")
            return .failed
        }
        writeShellConfig()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["-f",
                       "-L", coresDirectory.appendingPathComponent(console.coreFile).path,
                       "--appendconfig", shellConfig.path,
                       folder(for: console).appendingPathComponent(game.fileName).path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onExit?() } }
        }
        do {
            try p.run()
            retroArch = p
            log.info("launched \(game.fileName, privacy: .public) core=\(console.coreFile, privacy: .public)")
            return .started
        } catch {
            log.error("launch failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Opens a game that is its own Mac app, or resumes it if it's open.
    private func launchApp(_ url: URL) -> LaunchResult {
        if let open = appGame {
            guard open.url == url else { return .otherGameOpen(open.url) }
            if let app = liveApp(open) { resume(app); return .resumed }
            appGame = nil   // gone without a termination notice: start it fresh
        }
        guard !isRunningRetroArch, FileManager.default.fileExists(atPath: url.path),
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return .failed }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // NX2Apple front-end contract (engine docs/frontends.md): skip the
        // game's own settings window (saved choices still apply), and give its
        // Home menu a "Back to console mode" row that hands focus back to us.
        config.arguments = ["--no-launcher"]
        config.environment = [
            "DM_LAUNCHER": "0",
            "DM_HOME_MENU_LAUNCHER": "1",
            "DM_LAUNCHER_BUNDLE_ID": Bundle.main.bundleIdentifier ?? "local.brad.htpcshell",
            // Full screen, on the same display as the shell.
            "DM_FULLSCREEN": "1",
        ]
        if let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            config.environment["DM_SCREEN"] = screen.stringValue
        }
        if let map = hidMap?() { config.environment["DM_HID_MAP"] = map }
        appGame = AppGame(url: url, bundleID: bundleID)
        // macOS only lets an app take focus from the active one: hand it over.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self, log] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    log.error("launch \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    guard let self, self.appGame?.url == url else { return }
                    self.appGame = nil
                    self.onExit?()
                }
            }
        }
        log.info("launched app \(url.lastPathComponent, privacy: .public)")
        return .started
    }

    // MARK: Switch games in the background

    /// Takes charge of a Switch game that is already open (the shell
    /// restarted, or it was opened from Finder), so Home and Play treat it
    /// like one the shell started.
    func adoptOpenAppGame() {
        guard appGame == nil,
              let app = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated && isAppGame($0) }) else { return }
        adopt(app)
    }

    private func adopt(_ app: NSRunningApplication) {
        guard let url = app.bundleURL, let id = app.bundleIdentifier else { return }
        if appGame?.bundleID == id { return }
        appGame = AppGame(url: url, bundleID: id, frozen: Self.isStopped(app.processIdentifier))
        log.info("adopted open game \(url.lastPathComponent, privacy: .public)")
    }

    /// The shell is in front: a Switch game still running behind it (the
    /// shell came up some other way, or the game went back to console mode
    /// itself) pauses, as it would for Home.
    func pauseIfBehind() {
        guard let open = appGame, !open.frozen, !open.freezing, let app = liveApp(open), !app.isActive else { return }
        pause(app)
    }

    /// Home from the remote or keyboard while a Switch game is in front: the
    /// game hides (letting go of input), then is frozen so its sound and work
    /// stop, as a Switch pauses for its Home menu. Play resumes it.
    func pause(_ app: NSRunningApplication) {
        adopt(app)
        if appGame?.freezing == true { return }
        appGame?.freezing = true
        app.hide()
        let pid = app.processIdentifier
        let generation = freezeGeneration
        let deadline = Date().addingTimeInterval(Timing.freezeAfterHide)
        func tryFreeze() {
            guard generation == freezeGeneration, !app.isTerminated, appGame?.bundleID == app.bundleIdentifier else { return }
            if !app.isHidden && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { tryFreeze() } }
                return
            }
            appGame?.freezing = false
            if kill(pid, SIGSTOP) == 0 {
                appGame?.frozen = true
                log.info("paused \(app.bundleURL?.lastPathComponent ?? "game", privacy: .public)")
            }
        }
        tryFreeze()
    }

    /// Brings the open Switch game back: unfrozen, shown, in front, and told
    /// to resume (which also covers a game the player paused from its own
    /// Home menu's "Back to console mode").
    private func resume(_ app: NSRunningApplication) {
        freezeGeneration += 1
        appGame?.freezing = false
        if appGame?.frozen == true { kill(app.processIdentifier, SIGCONT); appGame?.frozen = false }
        NSApp.yieldActivation(to: app)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("org.nxnative.resume.\(app.processIdentifier)"), object: nil, deliverImmediately: true)
        app.unhide()
        app.activate()
        log.info("resumed \(app.bundleURL?.lastPathComponent ?? "game", privacy: .public)")
    }

    /// Quits the open Switch game (unfrozen first, so it exits as ⌘Q does:
    /// unsaved progress is lost, as on a Switch) and runs `then` once it's
    /// gone. Asked again while it's closing, only the latest `then` runs.
    func closeAppGame(then: @escaping @MainActor () -> Void) {
        guard let open = appGame, let app = liveApp(open) else { appGame = nil; then(); return }
        let alreadyClosing = !afterAppGameExit.isEmpty
        afterAppGameExit = [then]
        if alreadyClosing { return }
        freezeGeneration += 1
        appGame?.freezing = false
        let pid = app.processIdentifier
        if open.frozen { kill(pid, SIGCONT); appGame?.frozen = false }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("org.nxnative.quit.\(pid)"), object: nil, deliverImmediately: true)
        escalateQuit(app, pid: pid)
        log.info("closing \(open.url.lastPathComponent, privacy: .public)")
    }

    /// Lets a frozen game run again before the shell goes away (restart,
    /// exit to the desktop), so macOS can quit it or the player can find it.
    func unfreezeAppGame(show: Bool) {
        guard let open = appGame, let app = liveApp(open) else { return }
        if open.frozen { kill(app.processIdentifier, SIGCONT); appGame?.frozen = false }
        if show { resume(app) }
    }

    private func appDidTerminate(_ bundleID: String?) {
        guard let bundleID, bundleID == appGame?.bundleID else { return }
        appGame = nil
        onExit?()
        let pending = afterAppGameExit
        afterAppGameExit = []
        pending.forEach { $0() }
    }

    /// The live process for the open game. LaunchServices lists the game
    /// under its engine process (dmhost), not the launcher that started it.
    private func liveApp(_ game: AppGame) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: game.bundleID).first { !$0.isTerminated }
    }

    private static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) == SSTOP
    }

    // MARK: RetroArch

    /// Home while a retro game is in front: RetroArch quits as ⌘Q does,
    /// which saves a state (savestate_auto_save) that the next start of that
    /// game loads. If it doesn't answer, it's asked harder.
    func saveAndQuit(_ app: NSRunningApplication) {
        app.terminate()
        escalateQuit(app, pid: app.processIdentifier)
        log.info("quitting RetroArch with an auto save state")
    }

    private func escalateQuit(_ app: NSRunningApplication, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.quitGrace) {
            if !app.isTerminated { kill(pid, SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.killGrace) {
            if !app.isTerminated { app.forceTerminate() }
        }
    }

    /// Couch-friendly RetroArch settings: full screen, no confirm-to-quit,
    /// Start+Select quits back to the shell, L3+R3 opens RetroArch's menu,
    /// and a game picks up where it was left (auto save state on quit, loaded
    /// on start). RetroArch would save these into its own settings on exit,
    /// so that's turned off for shell launches.
    private func writeShellConfig() {
        let settings = [
            "video_fullscreen = \"true\"",
            "quit_press_twice = \"false\"",
            "input_quit_gamepad_combo = \"4\"",          // 4 = Start + Select
            "input_menu_toggle_gamepad_combo = \"2\"",   // 2 = L3 + R3
            "pause_nonactive = \"false\"",
            "savestate_auto_save = \"true\"",
            "savestate_auto_load = \"true\"",
            "config_save_on_exit = \"false\"",
            "notification_show_remap_load = \"false\"",
            "notification_show_config_override_load = \"false\"",
        ].joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: shellConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settings.write(to: shellConfig, atomically: true, encoding: .utf8)
        } catch {
            log.error("could not write RetroArch config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
