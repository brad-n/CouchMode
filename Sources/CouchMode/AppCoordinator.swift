// Owns: which screen is showing (home or a streaming service) and what each
// intent does in that screen. The single entry point for all input.

import AppKit
import GameController
import SwiftUI
import WebKit
import os
import CouchModeCore

/// A borderless window can't take keyboard focus unless it says so.
final class ShellWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppCoordinator {
    private enum Screen {
        case home, service(Service), console(ConsoleModel), allConsoles(AllConsolesModel), settings(SettingsModel)
        case bluetooth(SettingsModel)
        case detail(GameDetailModel)
        case plexDetail(ContinueEntry)
        case streamHome(StreamHomeModel), streamDetail(StreamDetailModel)
        case streamSearch(StreamSearchModel, home: StreamHomeModel)
    }

    private let window: ShellWindow
    private let container = NSView()
    private let homeModel: HomeModel
    private let homeView: NSHostingView<HomeView>
    private let player: WebPlayer
    private let system: SystemActions
    private let settings: SystemSettings
    private let games: GameLauncher
    private let plex: PlexClient
    private let apps = AppLauncher()
    private lazy var plexApp = PlexHTPC(apps: apps)
    private let bluetooth = BluetoothSettings()
    private var bluetoothRefresh: Timer?
    private var bluetoothRows: [BluetoothListRow] = []
    private let sounds = UISound()
    private var lastInput = Date()
    private var screensaver: NSView?
    private var continueWatching: [ContinueEntry] = []
    private var screen: Screen = .home
    /// Readers for services with their own stream screens, by service id.
    private var streamSources: [String: StreamSource] = [:]
    /// The stream screen to come back to when the service's own player is closed with Back.
    private var streamReturn: Screen?
    /// Where Back from a title's details goes when it isn't the service's home (its search).
    private var streamDetailBack: Screen?
    /// Each service's home as last read (bounded by StreamLimits), shown at once on the next visit.
    private var streamHomeCache: [String: StreamHome] = [:]
    /// The service's own page, kept behind a stream screen for its reader (setBackstage).
    private var backstage: WKWebView?
    /// Watches for the service's player to start, to drop the "Starting…" card (revealWhenPlaying).
    private var revealTask: Task<Void, Never>?
    /// Watches the service page's address during a Play handoff (watchPlayerExit).
    private var playerExitObservation: NSKeyValueObservation?
    /// Asks the page once a second whether an overlay player is still showing (PlayerShownWatch).
    private var playerShownTask: Task<Void, Never>?
    private let streamLog = Logger(subsystem: "local.brad.htpcshell", category: "stream")
    private var confirm = ConfirmGate()
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "coordinator")

    init(homeModel: HomeModel, player: WebPlayer, system: SystemActions, settings: SystemSettings,
         games: GameLauncher, plex: PlexClient) {
        self.games = games
        self.plex = plex
        self.homeModel = homeModel
        self.player = player
        self.system = system
        self.settings = settings
        homeView = NSHostingView(rootView: HomeView(model: homeModel))
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        window = ShellWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        install(homeView)
        player.onPlayPauseRequested = { [weak self] in self?.player.press(.space) }
        player.onFirstLoad = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self, case .service(let s) = self.screen, s.id == id else { return }
                self.hideOverlay()
            }
        }
        // Whenever the shell is back in front, it owns the whole screen again
        // (a system prompt or another app can bring the Dock back).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
                // Back from a game (Home, its own "Back to console mode", or any
                // other way): a Switch game behind the shell pauses, and the
                // screens show which game is paused.
                self?.games.pauseIfBehind()
                if self?.games.isRunningGame == true { self?.redrawGameScreens() }
            }
        }
        games.onExit = { [weak self] in self?.gameDidExit() }
        // A game left open by an earlier run of the shell (e.g. paused, then
        // the shell restarted) is still Home's and Play's to manage.
        games.adoptOpenAppGame()
        // Once a launched game or app takes the screen, drop the "Starting…" card.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideOverlay(animated: false) }
        }
        if let plexService = AppServices.all.first(where: { $0.id == "plex" }) {
            plex.tokenFromPlexWeb = { [weak player] done in
                guard let player else { return done(nil) }
                // Every token Plex Web holds: the signed-in account plus each Plex Home user.
                let js = "js:JSON.stringify([localStorage.getItem('myPlexAccessToken')].concat(((JSON.parse(localStorage.getItem('users') || '{}').users) || []).map(u => u.authToken)).filter(Boolean))"
                player.readLocalStorage(js, in: plexService, done: done)
            }
        }
    }

    var isHomeShowing: Bool { if case .home = screen { return true } else { return false } }

    /// Keyboard keys become shell intents on our own screens (home, game
    /// lists). On a streaming site the real keys go to the site instead.
    var wantsKeyboardIntents: Bool { if case .service = screen { return false } else { return true } }

    /// A handed-off title is on the service's page: Escape/Delete are Back for the shell.
    var interceptsBackKey: Bool { if streamReturn != nil, case .service = screen { return true } else { return false } }

    /// Home from any button, whatever app is in front and however it was
    /// opened: that app steps aside (HomeRouting) and the shell shows Home.
    func homeRequested(_ source: HomeSource) {
        lastInput = Date()
        let (front, app) = frontApp()
        let step = HomeRouting.step(front: front, source: source)
        log.info("home from \(source.rawValue, privacy: .public): \(String(describing: front), privacy: .public) -> \(String(describing: step), privacy: .public)")
        switch step {
        case .shellHome:
            if NSApp.isActive { handle(.home) } else { returnToShell() }
        case .leaveToGame:
            return
        case .closeApp:
            app?.terminate()
            returnToShell()
        case .hideApp:
            app?.hide()
            returnToShell()
        case .pauseGame:
            if let app { games.pause(app) }
            returnToShell()
        case .saveAndQuitRetroArch:
            if let app { games.saveAndQuit(app) }
            returnToShell()
        }
    }

    /// Where a game controller's presses go now (ControllerRouting).
    func controllerTarget() -> ControllerTarget {
        ControllerRouting.target(shellActive: NSApp.isActive, front: frontApp().0)
    }

    /// The kind of app in front, for Home.
    private func frontApp() -> (FrontApp, NSRunningApplication?) {
        guard !NSApp.isActive, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return (.shell, nil) }
        if let id = app.bundleIdentifier, AppServices.all.contains(where: { $0.nativeAppBundleID == id }) {
            return (.streamingApp, app)
        }
        if games.isRetroArch(app) { return (.retroArch, app) }
        if games.isAppGame(app) { return (.switchGame, app) }
        return (.other, app)
    }

    /// Home, in front, with nothing left over from before (card, screensaver).
    private func returnToShell() {
        hideOverlay(animated: false)
        if screensaver != nil { hideScreensaver() }
        goHome()
        ShellActivation.bringForward(window)
    }

    /// Before the shell goes away: a paused (frozen) game runs again, so
    /// macOS can quit it on restart or the player finds it on the desktop.
    func willTerminate() { games.unfreezeAppGame(show: true) }

    // MARK: Connected remotes and controllers

    /// Keeps the status bar's device icons current.
    func watchInputDevices() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
        // Battery levels change slowly; a light poll keeps them honest.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        refreshDevices()
    }

    /// Pads GameController doesn't support, read as raw HID (set by main).
    var hidPads: HIDGamepads?

    func inputDevicesChanged() { refreshDevices() }

    private func refreshDevices() {
        let controllers = GCController.controllers().enumerated().map { i, c in
            let isRemote = c.extendedGamepad == nil && c.microGamepad != nil
            let level = c.battery.map { Int(($0.batteryLevel * 100).rounded()) }
            return InputDevice(id: "\(i)-\(c.vendorName ?? "controller")",
                               symbol: isRemote ? "appletvremote.gen4.fill" : "gamecontroller.fill",
                               battery: (level ?? 0) > 0 ? level : nil)
        }
        let raw = (hidPads?.connected ?? []).enumerated().map { i, pad in
            InputDevice(id: "hid-\(i)-\(pad.name)", symbol: "gamecontroller.fill", battery: nil)
        }
        homeModel.devices = controllers + raw
    }

    // MARK: Launch intro

    /// The bloom-and-greeting intro over home, then a soft reveal.
    private func playIntro() {
        let intro = NSHostingView(rootView: IntroView())
        intro.frame = container.bounds
        intro.autoresizingMask = [.width, .height]
        container.addSubview(intro)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.8; intro.animator().alphaValue = 0 },
                                                completionHandler: { intro.removeFromSuperview() })
        }
    }

    // MARK: Screensaver

    /// Checks idle time; the screensaver only starts from the home screen.
    func startIdleWatch() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private func checkIdle() {
        let minutes = Prefs.screensaverMinutes
        guard minutes > 0, screensaver == nil, isHomeShowing, NSApp.isActive,
              Date().timeIntervalSince(lastInput) > Double(minutes) * 60 else { return }
        showScreensaver()
    }

    private func screensaverSlides() -> [ScreensaverSlide] {
        let shows = continueWatching.compactMap { e -> ScreensaverSlide? in
            guard let url = e.backdrop ?? e.image else { return nil }
            return ScreensaverSlide(id: "cw-" + e.item.ratingKey, title: e.item.title, subtitle: e.item.detail, url: url)
        }
        // Switch games' banners first (the richest art), then the console scenes.
        var consoles: [ScreensaverSlide] = []
        if let sw = ConsoleCatalog.all.first(where: { $0.gamesAreApps }) {
            for g in games.games(for: sw) {
                let url = games.folder(for: sw).appendingPathComponent(g.fileName)
                guard let banner = GameArt.banner(url) else { continue }
                consoles.append(ScreensaverSlide(id: "switch-" + g.fileName, title: GameArt.info(url)?.name ?? g.title,
                                                 subtitle: sw.name, image: banner))
            }
        }
        consoles += ConsoleCatalog.all.compactMap { c -> ScreensaverSlide? in
            guard let art = Artwork.image(c.id) else { return nil }
            return ScreensaverSlide(id: "console-" + c.id, title: c.name, subtitle: "Play", image: art)
        }
        // Interleave so shows and consoles alternate.
        var out: [ScreensaverSlide] = []
        for i in 0..<max(shows.count, consoles.count) {
            if i < shows.count { out.append(shows[i]) }
            if i < consoles.count { out.append(consoles[i]) }
        }
        return out
    }

    func showScreensaver() {
        let host = NSHostingView(rootView: ScreensaverView(slides: screensaverSlides()))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.alphaValue = 0
        container.addSubview(host)
        NSAnimationContext.runAnimationGroup { $0.duration = 1.2; host.animator().alphaValue = 1 }
        screensaver = host
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func hideScreensaver() {
        guard let v = screensaver else { return }
        screensaver = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; v.animator().alphaValue = 0 },
                                            completionHandler: { v.removeFromSuperview() })
    }

    /// Tells Plex Web which Plex Home profile to pick: the one whose token
    /// reaches the servers. The token stays inside that page's own storage.
    private func rememberPlexProfile() {
        guard let token = plex.workingToken,
              let s = AppServices.all.first(where: { $0.id == "plex" }),
              let tokenJSON = try? JSONSerialization.data(withJSONObject: [token]),
              let tokenLiteral = String(data: tokenJSON, encoding: .utf8) else { return }
        let js = """
        (function () {
          const t = \(tokenLiteral)[0];
          const users = (JSON.parse(localStorage.getItem('users') || '{}').users) || [];
          const me = users.find(u => u.authToken === t);
          if (me && me.title) localStorage.setItem('shellPlexUser', me.title);
          return !!me;
        })();
        """
        player.evaluate(js, in: s)
    }

    /// Re-reads Plex's Continue Watching and redraws home. Safe to call often.
    func refreshContinueWatching() {
        if DemoMode.isOn {
            continueWatching = DemoMode.plexContinueWatching()
            return refreshHome()
        }
        Task { [weak self] in
            guard let self else { return }
            continueWatching = await plex.continueWatching()
            rememberPlexProfile()
            refreshHome()
        }
    }

    func show() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        playIntro()
    }

    func handle(_ intent: ShellIntent) {
        lastInput = Date()
        // Any input while the screensaver shows only wakes the screen.
        if screensaver != nil { hideScreensaver(); return }
        if case .service = screen {} else {
            switch intent {
            case .move: sounds.play(.move)
            case .select, .info: sounds.play(.select)
            case .back, .home: sounds.play(.back)
            }
        }
        switch screen {
        case .home: handleHome(intent)
        case .service(let s): handlePlayer(intent, service: s)
        case .console(let model): handleConsole(intent, model: model)
        case .allConsoles(let model): handleAllConsoles(intent, model: model)
        case .settings(let model): handleSettings(intent, model: model)
        case .bluetooth(let model): handleBluetooth(intent, model: model)
        case .detail(let model): handleDetail(intent, model: model)
        case .plexDetail(let entry): handlePlexDetail(intent, entry: entry)
        case .streamHome(let model): handleStreamHome(intent, model: model)
        case .streamDetail(let model): handleStreamDetail(intent, model: model)
        case .streamSearch(let search, let home): handleStreamSearch(intent, search: search, home: home)
        }
    }

    private func handleHome(_ intent: ShellIntent) {
        switch intent {
        case .move(let d): homeModel.move(d)
        case .select: open(homeModel.focusedItem.action)
        case .info:
            // Details for a Jump Back In game or a Continue Watching item.
            let item = homeModel.focusedItem
            if case .game(let c, let g) = item.action { showDetail(g, in: consoleModel(c)) }
            if case .resume = item.action,
               let entry = continueWatching.first(where: { "continue-" + $0.item.ratingKey == item.id }) {
                show(NSHostingView(rootView: PlexDetailView(entry: entry)))
                screen = .plexDetail(entry)
            }
        case .back, .home: break
        }
    }

    private func handlePlayer(_ intent: ShellIntent, service: Service) {
        // Opened from a stream screen: Back stops playback and returns to it.
        if intent == .back, streamReturn != nil { return endStreamPlayback(service) }
        switch PlayerInput.command(for: intent, service: service) {
        case .press(let key): player.press(key)
        case .goBackInPage: if !player.goBack() { goHome() }
        case .returnHome: goHome()
        }
    }

    // MARK: Stream screens

    /// A reader for its service: opening that service shows the shell's own screens.
    func registerStreamSource(_ source: StreamSource) {
        streamSources[source.service.id] = source
        log.info("registered stream source service=\(source.service.id, privacy: .public)")
    }

    private func showStreamHome(_ s: Service) {
        guard let source = streamSources[s.id] else { return showWeb(s) }
        let cached = streamHomeCache[s.id]
        let model = StreamHomeModel(source: source, showing: cached)
        // A gate is never kept: the next visit must not show it (or the rows before it) as current.
        model.onRead = { [weak self] home in self?.streamHomeCache[s.id] = home.asksWhoIsWatching ? nil : home }
        model.onNeedsPerson = { [weak self, weak model] line in
            guard let self, let model, case .streamHome(let shown) = self.screen, shown === model else { return }
            self.showWebsiteForPerson(s, line: line)
        }
        show(NSHostingView(rootView: StreamHomeView(model: model)))
        setBackstage(player.view(for: s))
        screen = .streamHome(model)
        log.info("stream home service=\(s.id, privacy: .public) cached=\(cached != nil)")
        // Shown at once from the last visit; re-read behind it (the cached rows stay if that fails).
        if cached != nil { return model.refresh() }
        Task { [weak self] in
            let read = await model.load()
            guard let self, case .streamHome(let shown) = self.screen, shown === model, !read else { return }
            // The reader couldn't read the home: the website, as before.
            self.log.error("stream home unreadable service=\(s.id, privacy: .public); showing the website")
            self.showWeb(s)
            self.showOverlay(InterstitialView(title: s.name, subtitle: "Showing \(s.name)'s website", colors: Self.colors(for: s)), timeout: 3)
        }
    }

    /// A title's details. `back` is the screen Back returns to (the search it
    /// was chosen from); nil returns to the service's home.
    private func showStreamDetails(_ title: StreamTitle, from home: StreamHomeModel, back: Screen? = nil) {
        let model = StreamDetailModel(title: title, home: home)
        streamDetailBack = back
        show(NSHostingView(rootView: StreamDetailView(model: model)))
        screen = .streamDetail(model)
        model.load()
    }

    /// Back to the stream home from its details.
    private func showStreamHomeAgain(_ model: StreamHomeModel) {
        show(NSHostingView(rootView: StreamHomeView(model: model)))
        screen = .streamHome(model)
    }

    private func closeStreamScreens() {
        if case .streamDetail(let model) = screen { model.close() }
        if case .streamDetail(let model)? = streamReturn { model.close() }
    }

    /// The service's search, done on its own site by its reader (a proxy):
    /// choosing a result opens its details, and Back there returns here.
    private func openStreamSearch(from home: StreamHomeModel) {
        let source = home.source
        var search: StreamSearchModel!
        search = StreamSearchModel(serviceName: home.service.name,
                                   search: { [weak source] query in await source?.search(query) },
                                   onChoose: { [weak self] title in
                                       guard let self else { return }
                                       self.showStreamDetails(title, from: home, back: .streamSearch(search, home: home))
                                   })
        showStreamSearch(search, home: home)
        log.info("stream search service=\(home.service.id, privacy: .public)")
    }

    private func showStreamSearch(_ search: StreamSearchModel, home: StreamHomeModel) {
        show(NSHostingView(rootView: StreamSearchView(model: search)))
        screen = .streamSearch(search, home: home)
    }

    private func handleStreamSearch(_ intent: ShellIntent, search: StreamSearchModel, home: StreamHomeModel) {
        if intent == .home { return goHome() }
        // The search model answers everything but leaving: Back with nothing left to undo.
        if !search.handle(intent) { showStreamHomeAgain(home) }
    }

    /// Shows the service's page as a website visit (as "Open on <service>" does) for something only
    /// the person can finish, such as a profile form: the page the switch landed on when it is
    /// still on the service's site, else the service's home. Back returns to the stream home.
    private func showWebsiteForPerson(_ s: Service, line: String) {
        let landed = player.view(for: s).url
        let url = landed.flatMap { PlayerExit.hasLeftSite(playURL: s.url, current: $0) ? nil : $0 } ?? s.url
        playStream(url, service: s, subtitle: line)
    }

    /// Hands a title, episode or page to the service's own web player (DRM untouched),
    /// remembering the stream screen to come back to.
    private func playStream(_ url: URL, service s: Service, watchForExit: Bool = false, subtitle: String = "Starting…") {
        if DemoMode.isOn { return }   // demo titles have no player
        stopWatchingPlayer()
        streamReturn = screen
        let page = player.view(for: s)
        let leaving = page.url
        player.load(url, in: s)
        // The page takes the screen still quiet: revealWhenPlaying lets its media
        // play once the player's page has replaced the one that was backstage.
        showWeb(s, keepQuiet: true)
        showOverlay(InterstitialView(title: s.name, subtitle: subtitle, colors: Self.colors(for: s)),
                    timeout: TimeInterval(Reveal.timeout.components.seconds))
        revealWhenPlaying(page, service: s, leaving: leaving)
        if watchForExit {
            if let script = streamSources[s.id]?.playerShownScript { watchPlayerShown(page, script: script, playURL: url, service: s) }
            else { watchPlayerExit(page, playURL: url, service: s) }
        }
    }

    /// For a service whose player opens over a page (no page of its own to leave): returns to our
    /// screen once the service's check has said the player is showing and then that it is not, twice
    /// in a row, or the page leaves the service's site.
    private func watchPlayerShown(_ page: WKWebView, script: String, playURL: URL, service s: Service) {
        playerShownTask = Task { [weak self] in
            var watch = PlayerShownWatch()
            while !watch.isExpired {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.streamReturn != nil, case .service(let shown) = self.screen, shown.id == s.id else { return }
                let left = PlayerExit.hasLeftSite(playURL: playURL, current: page.url)
                let answer = await WebPage.run(script, in: page, timeout: .seconds(1)) as? Bool
                if left || watch.record(answer) {
                    self.streamLog.info("left player, returning service=\(s.id, privacy: .public)")
                    self.endStreamPlayback(s)
                    return
                }
            }
        }
    }

    /// Watches the service page's address while a real Play is on screen: leaving the player
    /// by the service's own back arrow, Escape or the episode ending returns to our screen
    /// the same way Back does. KVO on `url` also fires for in-page (pushState) navigations.
    private func watchPlayerExit(_ page: WKWebView, playURL: URL, service s: Service) {
        // The page being replaced also differs from the player, so leaving counts only once the player was reached.
        var reachedPlayer = false
        playerExitObservation = page.observe(\.url, options: [.initial, .new]) { [weak self] page, _ in
            MainActor.assumeIsolated {
                if PlayerExit.isOnPlayer(playURL: playURL, current: page.url) { reachedPlayer = true }
                guard reachedPlayer, let self, self.streamReturn != nil, case .service(let shown) = self.screen, shown.id == s.id,
                      PlayerExit.hasLeftPlayer(playURL: playURL, current: page.url) else { return }
                self.streamLog.info("left player, returning service=\(s.id, privacy: .public)")
                self.endStreamPlayback(s)
            }
        }
    }

    private func stopWatchingPlayer() {
        playerExitObservation?.invalidate()
        playerExitObservation = nil
        playerShownTask?.cancel()
        playerShownTask = nil
    }

    private enum Reveal {
        static let poll: Duration = .milliseconds(300)
        /// Longest wait for the player's page to replace the old one before media is allowed anyway.
        static let replaceWait: Duration = .seconds(2)
        /// A page that plays nothing (Open on Netflix) shows this long after it loads.
        static let pageGrace: Duration = .seconds(4)
        static let timeout: Duration = .seconds(12)
    }

    /// Allows the page's media once the player's page has replaced `leaving`
    /// (allowing it earlier let the old page's trailer play for a moment), then
    /// drops the "Starting…" card the moment a video in the page is rolling,
    /// or once a page that plays nothing has loaded, at
    /// most Reveal.timeout. (The page was loaded backstage, so its first-load
    /// signal never comes again.) Leaving the player first keeps it quiet.
    private func revealWhenPlaying(_ page: WKWebView, service s: Service, leaving: URL?) {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var allowed = false
            var allowedAt = start
            var nudged = false
            while clock.now - start < Reveal.timeout {
                try? await Task.sleep(for: Reveal.poll)
                guard !Task.isCancelled, let self, case .service(let shown) = self.screen, shown.id == s.id else { return }
                if !allowed {
                    guard page.url != leaving || clock.now - start >= Reveal.replaceWait else { continue }
                    self.unquiet(page)
                    allowed = true
                    allowedAt = clock.now
                    continue
                }
                let video = PlayNudge.state(fromProbe: await WebPage.run(PlayNudge.probeScript, in: page, timeout: Reveal.poll) as? String)
                if video == .rolling { break }
                // A title that loaded paused (a resume point): press the player's own Play, once.
                let waited = clock.now - allowedAt
                let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
                if PlayNudge.shouldPress(state: video, secondsSinceAllowed: seconds, alreadyPressed: nudged) {
                    nudged = true
                    self.streamLog.info("loaded paused, pressing play service=\(s.id, privacy: .public)")
                    self.player.press(.space)
                }
                if !page.isLoading, clock.now - start >= Reveal.pageGrace { break }
            }
            guard !Task.isCancelled, let self else { return }
            self.unquiet(page)
            self.hideOverlay()
        }
    }

    /// Back from the service's player: stop playback by loading the site's home
    /// (which also refreshes its data), restore the stream screen with its focus,
    /// and re-read the stream home in the background since progress changed.
    private func endStreamPlayback(_ s: Service) {
        guard let back = streamReturn else { return }
        streamReturn = nil
        stopWatchingPlayer()
        revealTask?.cancel()
        hideOverlay(animated: false)
        player.deactivate()
        player.load(s.url, in: s)
        switch back {
        case .streamHome(let model):
            showStreamHomeAgain(model)
            setBackstage(player.view(for: s))
            model.refresh()
        case .streamDetail(let model):
            show(NSHostingView(rootView: StreamDetailView(model: model)))
            setBackstage(player.view(for: s))
            screen = back
            model.home.refresh()
        default:
            goHome()
        }
        log.info("back from player service=\(s.id, privacy: .public)")
    }

    private func handleStreamHome(_ intent: ShellIntent, model: StreamHomeModel) {
        if model.picker != nil {
            switch intent {
            case .move(let d): model.movePicker(d)
            case .select: model.chooseProfile()
            case .back: if model.asksWhoIsWatching { goHome() } else { model.closePicker() }
            case .home: goHome()
            case .info: break
            }
            return
        }
        switch intent {
        case .home, .back: goHome()
        case .move(let d): if !model.isLoading { model.move(d) }
        case .select:
            guard !model.isLoading else { return }
            switch model.target {
            case .search: openStreamSearch(from: model)
            case .profile: model.openPicker()
            case .title:
                guard let title = model.focusedTitle else { return }
                if model.focusedRow?.kind == .continueWatching { playStream(title.play, service: model.service, watchForExit: true) }
                else { showStreamDetails(title, from: model) }
            }
        case .info:
            if let title = model.focusedTitle, !model.isLoading { showStreamDetails(title, from: model) }
        }
    }

    private func handleStreamDetail(_ intent: ShellIntent, model: StreamDetailModel) {
        switch intent {
        case .move(let d): model.move(d)
        case .select:
            switch model.activation {
            case .open(let url): playStream(url, service: model.service, watchForExit: true)
            case .page(let url): playStream(url, service: model.service)
            case .none: break
            }
        case .back:
            model.close()
            if case .streamSearch(let search, let home)? = streamDetailBack {
                streamDetailBack = nil
                showStreamSearch(search, home: home)
            } else {
                showStreamHomeAgain(model.home)
            }
        case .home: goHome()
        case .info: break
        }
    }

    private func handleConsole(_ intent: ShellIntent, model: ConsoleModel) {
        guard !games.isRunningRetroArch else { return }
        switch intent {
        case .move(let d): model.move(d)
        case .back, .home: goHome()
        case .select:
            guard let game = model.selected else { return }
            launch(game, from: model)
        case .info:
            guard let game = model.selected else { return }
            showDetail(game, in: model)
        }
    }

    /// Starts a game from a console screen (or its details), with the
    /// Starting card, or says why it couldn't.
    private func launch(_ game: Game, from model: ConsoleModel) {
        play(game, on: model.console) { [weak model] in model?.message = $0 }
    }

    /// Starts a game (or resumes the paused one) behind a Starting card.
    /// `say` shows the player a line when it can't yet, and nil clears it:
    /// when a different Switch game is open, pressing again within a few
    /// seconds closes it and starts this one, as on a Switch.
    private func play(_ game: Game, on c: Console, say: @escaping @MainActor (String?) -> Void) {
        let url = games.folder(for: c).appendingPathComponent(game.fileName)
        let title = c.gamesAreApps ? (GameArt.info(url)?.name ?? game.title) : game.title
        let card = { (subtitle: String, timeout: TimeInterval) in
            self.showOverlay(InterstitialView(title: title, subtitle: subtitle, colors: HomeLayout.consoleColors(c),
                                              icon: c.gamesAreApps ? AppIcons.icon(url) : nil, artwork: c.id),
                             timeout: timeout)
        }
        PointerPark.offEdges(window.screen)
        switch games.launch(game, on: c) {
        case .started:
            card("Starting…", 30)
            say(nil)
        case .resumed:
            card("Resuming…", 8)
            say(nil)
        case .otherGameOpen(let other):
            let otherName = GameArt.info(other)?.name ?? other.deletingPathExtension().lastPathComponent
            let action = "close-for-" + game.fileName
            if confirm.press(action, now: Date()) {
                card("Closing \(otherName)…", 30)
                say(nil)
                games.closeAppGame { [weak self] in self?.play(game, on: c, say: say) }
                return
            }
            say("\(otherName) is paused. Press again to close it and play \(title).")
            clearWhenUnconfirmed(action) { say(nil) }
        case .failed:
            say(c.gamesAreApps ? "Couldn't open \(title)." : "Couldn't start the game. Is RetroArch installed?")
        }
    }

    /// Clears a "press again" hint once its window has passed without the
    /// second press (and nothing else has re-armed the same action).
    private func clearWhenUnconfirmed(_ action: String, clear: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + ConfirmGate.window + 0.1) { [weak self] in
            guard let self, self.confirm.pending(now: Date()) != action else { return }
            clear()
        }
    }

    private func consoleModel(_ c: Console) -> ConsoleModel {
        let list = games.games(for: c)
        return ConsoleModel(console: c, games: list, folderPath: "~/Games/" + c.folder,
                            folderURL: games.folder(for: c), colors: HomeLayout.consoleColors(c),
                            lastPlayed: games.lastPlayed(for: c),
                            pausedGame: list.first { games.isOpen($0, on: c) }?.fileName)
    }

    /// Close Game on a paused game's details: press again to confirm (its
    /// unsaved progress is lost, as on a Switch), then back to its console.
    private func closePaused(from model: GameDetailModel) {
        let action = "close-" + model.game.fileName
        guard confirm.press(action, now: Date()) else {
            model.message = "Press again to close it. Progress the game hasn't saved will be lost."
            clearWhenUnconfirmed(action) { [weak model] in model?.message = nil }
            return
        }
        model.message = "Closing…"
        games.closeAppGame { [weak self] in
            guard let self, case .detail(let shown) = self.screen, shown === model else { return }
            let fresh = self.consoleModel(model.console.console)
            fresh.select(model.game)
            self.show(NSHostingView(rootView: ConsoleView(model: fresh)))
            self.screen = .console(fresh)
        }
    }

    private func showDetail(_ game: Game, in model: ConsoleModel) {
        let detail = GameDetailModel(console: model, game: game, paused: games.isOpen(game, on: model.console))
        detail.loadScreenshots()
        show(NSHostingView(rootView: GameDetailView(model: detail)))
        screen = .detail(detail)
    }

    private func handlePlexDetail(_ intent: ShellIntent, entry: ContinueEntry) {
        switch intent {
        case .select: if let url = entry.details { open(.resume(url)) }
        case .back, .home: goHome()
        case .move, .info: break
        }
    }

    private func handleDetail(_ intent: ShellIntent, model: GameDetailModel) {
        guard !games.isRunningRetroArch else { return }
        switch intent {
        case .move(let d): model.move(d)
        case .select where model.focus == .play:
            play(model.game, on: model.console.console) { [weak model] in model?.message = $0 }
        case .select where model.focus == .close: closePaused(from: model)
        case .select, .info: break
        case .back:
            show(NSHostingView(rootView: ConsoleView(model: model.console)))
            screen = .console(model.console)
        case .home: goHome()
        }
    }

    private func handleAllConsoles(_ intent: ShellIntent, model: AllConsolesModel) {
        switch intent {
        case .move(let d): model.move(d)
        case .back, .home: goHome()
        case .select: open(model.selected.action)
        case .info: break
        }
    }

    private func gameDidExit() {
        hideOverlay(animated: false)
        redrawGameScreens()
        ShellActivation.bringForward(window)
    }

    /// Home's Jump Back In and a console screen show what was just played and
    /// which game is paused; redraw whichever is showing.
    private func redrawGameScreens() {
        if isHomeShowing { refreshHome() }
        if case .console(let model) = screen {
            let fresh = consoleModel(model.console)
            fresh.select(model.selected)
            fresh.message = model.message
            show(NSHostingView(rootView: ConsoleView(model: fresh)))
            screen = .console(fresh)
        }
    }

    private func open(_ action: HomeAction) {
        // Demo mode starts nothing: no other app, no real website, no player.
        if DemoMode.isOn, Self.startsOutsideTheShell(action, hasStreamScreens: { streamSources[$0.id] != nil }) {
            homeModel.notice = DemoMode.launchNotice
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.homeModel.notice = nil }
            return
        }
        switch action {
        case .console(let c):
            let model = consoleModel(c)
            show(NSHostingView(rootView: ConsoleView(model: model)))
            screen = .console(model)
        case .allConsoles:
            let items = ConsoleCatalog.all.map { HomeLayout.consoleItem($0, count: games.games(for: $0).count) }
            let model = AllConsolesModel(items: items)
            show(NSHostingView(rootView: AllConsolesView(model: model)))
            screen = .allConsoles(model)
        case .stream(let s) where s.nativeAppBundleID.map(apps.isInstalled) == true:
            showOverlay(InterstitialView(title: s.name, subtitle: "Starting…", colors: Self.colors(for: s)), timeout: 20)
            PointerPark.offEdges(window.screen)
            apps.launch(bundleID: s.nativeAppBundleID!) { [weak self] in self?.gameDidExit() }
            log.info("launched native app for service=\(s.id, privacy: .public)")
        case .stream(let s) where streamSources[s.id] != nil:
            showStreamHome(s)
        case .stream(let s):
            showWeb(s)
        case .resume(let url):
            guard let s = AppServices.all.first(where: { $0.id == "plex" }) else { return }
            // Plex HTPC, which the remote drives, opened on the title's own
            // page in the library (PlexHTPC explains how, and its fallbacks).
            if s.nativeAppBundleID == PlexHTPC.bundleID, plexApp.isInstalled {
                // Its place in the row, for the fallback: Plex's own Continue Watching has the same titles in the same order.
                let row = continueWatching.filter { $0.details != nil }
                let index = row.firstIndex { $0.details == url } ?? 0
                showOverlay(InterstitialView(title: row.indices.contains(index) ? row[index].item.title : s.name,
                                             subtitle: "Opening in Plex\u{2026}", colors: Self.colors(for: s)), timeout: 30)
                PointerPark.offEdges(window.screen)
                let entry = row.indices.contains(index) ? row[index] : nil
                plexApp.open(continueAt: index, source: entry?.source, link: entry?.item.appLink, takeFront: { [weak self] in
                    guard let self else { return }
                    ShellActivation.bringForward(self.window)
                }, onExit: { [weak self] in self?.gameDidExit() })
                return
            }
            // The page's helper presses Play once it sees this flag (one-press resume).
            let autoplay = URL(string: url.absoluteString + "&shellAutoplay=1") ?? url
            player.load(autoplay, in: s)
            showWeb(s)
        case .game(let c, let g):
            play(g, on: c) { [weak self] in self?.homeModel.notice = $0 }
        case .settings:
            let model = SettingsModel(rows: settingRows())
            show(NSHostingView(rootView: SettingsView(model: model)))
            screen = .settings(model)
        case .none: break
        }
    }

    /// True for a card that would start another app, open a real website or play something.
    private static func startsOutsideTheShell(_ action: HomeAction, hasStreamScreens: (Service) -> Bool) -> Bool {
        switch action {
        case .resume: return true
        case .stream(let s): return !hasStreamScreens(s)
        default: return false
        }
    }

    static func homeRows(games: GameLauncher, continueWatching: [ContinueEntry] = []) -> [HomeRow] {
        HomeLayout.rows(services: AppServices.all,
                        consoles: ConsoleCatalog.all.map { ($0, games.games(for: $0).count) },
                        continueWatching: continueWatching,
                        recentGames: recentGames(games))
    }

    /// The 10 most recently played games that are still installed, across
    /// consoles; a paused game first, as a Switch keeps the open software first.
    static func recentGames(_ games: GameLauncher) -> [RecentGame] {
        var out: [RecentGame] = []
        for c in ConsoleCatalog.all {
            let played = games.lastPlayed(for: c)
            guard !played.isEmpty else { continue }
            for g in games.games(for: c) {
                guard let date = played[g.fileName] else { continue }
                if c.gamesAreApps {
                    let url = games.folder(for: c).appendingPathComponent(g.fileName)
                    let info = GameArt.info(url)
                    out.append(RecentGame(console: c, game: g, played: date, title: info?.name ?? g.title,
                                          tagline: info?.metaText, card: GameArt.card(url) ?? AppIcons.icon(url),
                                          hero: GameArt.banner(url), paused: games.isOpen(g, on: c)))
                } else {
                    out.append(RecentGame(console: c, game: g, played: date, title: g.title,
                                          card: DemoMode.isOn ? DemoMode.gameArt(.tile, fileName: g.fileName) : nil,
                                          hero: DemoMode.isOn ? DemoMode.gameArt(.hero, fileName: g.fileName) : nil))
                }
            }
        }
        return Array(out.sorted { ($0.paused ? 1 : 0, $0.played) > ($1.paused ? 1 : 0, $1.played) }.prefix(10))
    }

    private func refreshHome() {
        homeModel.update(rows: Self.homeRows(games: games, continueWatching: continueWatching))
    }

    // MARK: Settings

    private func settingRows() -> [SettingRow] {
        let pending = confirm.pending(now: Date())
        let controllers = GCController.controllers().count + (hidPads?.connected.count ?? 0)
        let saver = Prefs.screensaverMinutes
        let demo = DemoMode.isOn
        return [
            SettingRow(id: "audio", title: "Sound Output", value: demo ? DemoMode.SettingsValue.audio : settings.currentAudioOutput()?.name ?? "None", symbol: "speaker.wave.2.fill"),
            SettingRow(id: "bluetooth", title: "Remotes & Controllers", value: demo ? DemoMode.SettingsValue.controllers : controllers == 1 ? "1 connected" : "\(controllers) connected",
                       symbol: "gamecontroller.fill"),
            SettingRow(id: "remoteapps", title: "Remote in Other Apps",
                       value: KeyInjector.isAllowed ? "On" : "Needs permission", symbol: "appletvremote.gen4.fill"),
            SettingRow(id: "login", title: "Start at Login", value: settings.startsAtLogin ? "On" : "Off", symbol: "power.circle.fill"),
            SettingRow(id: "sounds", title: "Interface Sounds", value: Prefs.uiSounds ? "On" : "Off", symbol: "speaker.badge.exclamationmark.fill"),
            SettingRow(id: "screensaver", title: "Screensaver", value: saver == 0 ? "Off" : "After \(saver) min", symbol: "sparkles.tv.fill"),
            SettingRow(id: "storage", title: "Storage", value: demo ? DemoMode.SettingsValue.storage : Self.storageText(), symbol: "internaldrive.fill"),
            SettingRow(id: "version", title: "Version", value: Self.versionText(), symbol: "info.circle.fill"),
            SettingRow(id: "update", title: "Check for Updates", value: AppUpdater.shared.isAvailable ? "" : "Not in this build",
                       symbol: "arrow.down.circle.fill", isAction: true),
            SettingRow(id: "autoupdate", title: "Automatically Check", value: AppUpdater.shared.automaticallyChecks ? "On" : "Off",
                       symbol: "clock.arrow.circlepath"),
            SettingRow(id: "sleep", title: "Sleep", value: "Turn off the screen", symbol: "moon.fill", isAction: true),
            SettingRow(id: "restart", title: "Restart", value: pending == "restart" ? "Press again to restart" : "",
                       symbol: "arrow.clockwise", isAction: true),
            SettingRow(id: "desktop", title: "Exit to Desktop", value: pending == "desktop" ? "Press again to exit" : "",
                       symbol: "rectangle.portrait.and.arrow.right", isAction: true),
        ]
    }

    /// "54 GB free of 228 GB" for the startup disk.
    static func storageText() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return "Unknown" }
        // Whole gigabytes read better on a TV than "46.19 GB".
        let gb = { (bytes: Double) in "\(Int((bytes / 1_000_000_000).rounded())) GB" }
        return "\(gb(Double(free))) free of \(gb(Double(total)))"
    }

    /// The build the shell is running: release version, build count and commit, from the bundle.
    static func versionText() -> String {
        let info = Bundle.main.infoDictionary
        return AppVersion.text(short: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String,
                               sha: info?["CouchModeGitSHA"] as? String)
    }

    private func handleSettings(_ intent: ShellIntent, model: SettingsModel) {
        switch intent {
        case .move(let d): model.move(d)
        case .back, .home: goHome()
        case .info: break
        case .select:
            guard let row = model.selected else { return }
            switch row.id {
            case "audio":
                if let next = Cycle.next(after: settings.currentAudioOutput(), in: settings.audioOutputs()) { settings.setAudioOutput(next) }
            case "bluetooth": openBluetooth(); return
            case "remoteapps":
                if !KeyInjector.requestPermission() { system.openAccessibilitySettings() }
            case "login": settings.setStartsAtLogin(!settings.startsAtLogin)
            case "sounds": Prefs.uiSounds.toggle()
            case "screensaver":
                Prefs.screensaverMinutes = Cycle.next(after: Prefs.screensaverMinutes, in: Prefs.screensaverChoices) ?? 5
            case "update": AppUpdater.shared.checkForUpdates()
            case "autoupdate": AppUpdater.shared.automaticallyChecks.toggle()
            case "sleep": system.sleep()
            case "restart":
                // A frozen game couldn't answer macOS's quit request and would stall the restart.
                if confirm.press("restart", now: Date()) { games.unfreezeAppGame(show: false); system.restart() }
            case "desktop": if confirm.press("desktop", now: Date()) { NSApp.terminate(nil) }   // willTerminate shows a paused game
            default: break
            }
            model.update(rows: settingRows())
            // Clear a "press again" hint once its window passes.
            if confirm.pending(now: Date()) != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + ConfirmGate.window + 0.1) { [weak self, weak model] in
                    guard let self, let model else { return }
                    model.update(rows: self.settingRows())
                }
            }
        }
    }

    // MARK: Remotes & Controllers

    private static let pairingHint = "Pairing something new? Put it in pairing mode first. Xbox: hold the pair button. "
        + "PlayStation: hold PS and Create. Switch Pro: hold the sync button. Siri Remote: hold Back and Volume Up near the Mac."

    /// The shell's own Bluetooth list, worked with the remote: System Settings
    /// stays open behind the shell (it keeps scanning) and is read every 2 s.
    private func openBluetooth() {
        bluetooth.open()
        let model = SettingsModel(title: "Remotes & Controllers", icon: "gamecontroller.fill", rows: bluetoothSettingRows())
        model.footer = Self.pairingHint
        show(NSHostingView(rootView: SettingsView(model: model, kind: .bluetooth)))
        screen = .bluetooth(model)
        bluetoothRefresh?.invalidate()
        bluetoothRefresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model, case .bluetooth(let shown) = self.screen, shown === model else { return }
                model.update(rows: self.bluetoothSettingRows())
            }
        }
    }

    private func closeBluetooth() {
        bluetoothRefresh?.invalidate()
        bluetoothRefresh = nil
        bluetooth.close()
    }

    private func bluetoothSettingRows() -> [SettingRow] {
        bluetoothRows = BluetoothPane.listing(bluetooth.devices())
        let devices = bluetoothRows.map {
            SettingRow(id: $0.id, title: $0.title, value: $0.value, symbol: Self.symbol(for: $0.kind), isAction: $0.action != .none)
        }
        let searching = devices.isEmpty
            ? [SettingRow(id: "bt-searching", title: "Looking for devices\u{2026}", value: "", symbol: "dot.radiowaves.left.and.right")] : []
        return searching + devices + [SettingRow(id: "bt-settings", title: "Open Bluetooth Settings", value: "Needs a mouse",
                                                 symbol: "gearshape.fill", isAction: true)]
    }

    private static func symbol(for kind: BluetoothDevice.Kind) -> String {
        switch kind {
        case .controller: return "gamecontroller.fill"
        case .remote: return "appletvremote.gen4.fill"
        case .headphones: return "headphones"
        case .keyboard: return "keyboard.fill"
        case .pointer: return "computermouse.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    private func handleBluetooth(_ intent: ShellIntent, model: SettingsModel) {
        switch intent {
        case .move(let d): model.move(d)
        case .back:
            closeBluetooth()
            open(.settings)
            if case .settings(let settingsModel) = screen { settingsModel.select(id: "bluetooth") }
        case .home: goHome()
        case .info: break
        case .select:
            guard let row = model.selected else { return }
            if row.id == "bt-settings" { closeBluetooth(); system.openBluetoothSettings(); return }
            guard let item = bluetoothRows.first(where: { $0.id == row.id }), item.action != .none,
                  let device = bluetooth.devices().first(where: { $0.id == item.id }) else { return }
            model.footer = item.action == .pair ? "Pairing with \(device.name)\u{2026}" : "Connecting to \(device.name)\u{2026}"
            Task { [weak self, weak model] in
                guard let self else { return }
                let pressed = await self.bluetooth.connect(device)
                ShellActivation.bringForward(self.window)
                model?.footer = pressed
                    ? "Asked \(device.name) to connect: it shows Connected when it's ready."
                    : "Couldn't reach \(device.name)'s Connect from here. Is it in pairing mode? Open Bluetooth Settings works with a mouse."
                model?.update(rows: self.bluetoothSettingRows())
            }
        }
    }

    private func goHome() {
        if case .bluetooth = screen { closeBluetooth() }
        refreshHome()
        refreshContinueWatching()
        // A service's page off screen stays quiet (no trailer sound from behind Home).
        revealTask?.cancel()
        stopWatchingPlayer()
        if let page = player.activeView { quiet(page) }
        player.deactivate()
        closeStreamScreens()
        streamDetailBack = nil
        setBackstage(nil)
        streamReturn = nil
        install(homeView)
        screen = .home
        window.makeFirstResponder(homeView)
    }

    /// Shows a service's website in the shell (never its native app).
    /// The service's own page on screen. Its media plays again unless
    /// `keepQuiet` (Play, which allows it once the player's page is in).
    private func showWeb(_ s: Service, keepQuiet: Bool = false) {
        let v = player.view(for: s)
        if backstage === v { setBackstage(nil) }
        install(v)
        if !keepQuiet { unquiet(v) }
        if !player.hasLoaded(s) {
            showOverlay(InterstitialView(title: s.name, subtitle: "Opening…", colors: Self.colors(for: s)), timeout: 15)
        }
        player.activate(s)
        screen = .service(s)
        window.makeFirstResponder(v)
        log.info("open service=\(s.id, privacy: .public)")
    }

    private func show(_ view: NSView) {
        install(view)
        window.makeFirstResponder(view)
    }

    private static func colors(for s: Service) -> [Color] { ServiceLook.colors(s.id) }

    /// Exactly one child view is in the window at a time (plus an optional
    /// overlay, and the backstage page behind a stream screen).
    private func install(_ view: NSView) {
        screensaver = nil
        // Crossfade between screens rather than cutting.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.25
        container.layer?.add(fade, forKey: kCATransition)
        overlay = nil
        container.subviews.forEach { if $0 !== backstage { $0.removeFromSuperview() } }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    /// Keeps a service's own page in the window behind the shell's stream
    /// screens (nil takes it away). WebKit slows the timers and stops the
    /// animation of a page that isn't in a window, which stalled the reader's
    /// clicks on Netflix's season picker; behind our screen it runs normally,
    /// with its media suspended so no trailer plays or sounds back there.
    /// WebKit counts suspensions (each needs its own resume, seen on a real Mac),
    /// so a page is suspended exactly once going backstage and resumed exactly
    /// once leaving it, whatever it leaves for (the player, the website, Home).
    private func setBackstage(_ page: WKWebView?) {
        guard backstage !== page, !DemoMode.isOn else { return }   // demo mode keeps every real site out of the window
        // A page leaving backstage stays quiet until it's shown (showWeb, revealWhenPlaying).
        backstage?.removeFromSuperview()
        backstage = page
        guard let page else { return }
        quiet(page)
        page.frame = container.bounds
        page.autoresizingMask = [.width, .height]
        container.addSubview(page, positioned: .below, relativeTo: nil)
    }

    /// Pages whose media the shell has suspended: each suspend is matched by
    /// exactly one resume (WebKit counts them).
    private var quietPages: Set<ObjectIdentifier> = []

    private func quiet(_ page: WKWebView) {
        guard quietPages.insert(ObjectIdentifier(page)).inserted else { return }
        page.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    private func unquiet(_ page: WKWebView) {
        guard quietPages.remove(ObjectIdentifier(page)) != nil else { return }
        page.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }

    // MARK: Interstitials

    private var overlay: NSView?
    private var overlayTimeout: DispatchWorkItem?

    /// Full-screen "Opening…"/"Starting…" card over the current screen, removed
    /// by hideOverlay or after `timeout` seconds at the latest.
    private func showOverlay(_ view: InterstitialView, timeout: TimeInterval) {
        hideOverlay(animated: false)
        let host = NSHostingView(rootView: view)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.alphaValue = 0
        container.addSubview(host)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; host.animator().alphaValue = 1 }
        overlay = host
        let work = DispatchWorkItem { [weak self] in self?.hideOverlay() }
        overlayTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func hideOverlay(animated: Bool = true) {
        overlayTimeout?.cancel()
        guard let o = overlay else { return }
        overlay = nil
        guard animated else { o.removeFromSuperview(); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; o.animator().alphaValue = 0 },
                                            completionHandler: { o.removeFromSuperview() })
    }
}

// MARK: Debug control (only reachable when DebugServer is enabled)

extension AppCoordinator: DebugControllable {
    var displayID: CGDirectDisplayID? {
        (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func debugState() -> [String: String] {
        var state = screenState()
        state["front"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        state["game"] = games.debugStatus
        // Seconds since the last input, so tests that take over the screen can wait for a quiet moment.
        state["idle"] = "\(Int(Date().timeIntervalSince(lastInput)))"
        return state
    }

    func debugPlexLink(_ link: URL, _ done: @escaping @MainActor (String) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            done(await self.plexApp.openTitle(link) { [weak self] in
                guard let self else { return }
                ShellActivation.bringForward(self.window)
            })
        }
    }

    func debugHID() -> String {
        let pads = (hidPads?.connected ?? []).map { "\($0.name): DM_HID_MAP=\($0.layout.dmHIDMap)" }
        return (["pads:"] + pads + ["recent:"] + (hidPads?.recentEvents ?? [])).joined(separator: "\n")
    }

    func debugPlay(consoleId: String, fileName: String) -> Bool {
        guard let c = ConsoleCatalog.all.first(where: { $0.id == consoleId }),
              let g = games.games(for: c).first(where: { $0.fileName == fileName }) else { return false }
        if !isHomeShowing { goHome() }
        open(.game(c, g))
        return true
    }

    private func screenState() -> [String: String] {
        switch screen {
        case .home:
            return ["screen": "home", "focused": homeModel.focusedItem.id, "plex": plex.status,
                    "continueWatching": "\(continueWatching.count)"]
        case .settings(let model):
            return ["screen": "settings", "selected": model.selected?.id ?? ""]
        case .bluetooth(let model):
            return ["screen": "bluetooth", "selected": model.selected?.id ?? "", "rows": "\(model.rows.count)",
                    "footer": model.footer ?? ""]
        case .plexDetail(let entry):
            return ["screen": "plexDetail", "item": entry.item.title]
        case .detail(let model):
            return ["screen": "detail", "game": model.game.fileName, "focus": "\(model.focus)",
                    "screenshots": "\(model.screenshots.count)"]
        case .allConsoles(let model):
            return ["screen": "allConsoles", "selected": model.selected.id]
        case .console(let model):
            return ["screen": "console", "console": model.console.id, "selected": model.selected?.fileName ?? "",
                    "games": "\(model.games.count)", "running": "\(games.isRunningGame)"]
        case .streamHome(let model):
            return ["screen": "streamHome", "service": model.service.id, "loading": "\(model.isLoading)",
                    "target": "\(model.target)", "rows": "\(model.rows.count)", "picker": model.picker.map(String.init) ?? ""]
        case .streamDetail(let model):
            return ["screen": "streamDetail", "service": model.service.id, "title": model.title.name,
                    "target": "\(model.focus.target)", "seasons": "\(model.seasons.count)", "episodes": "\(model.episodes.count)"]
        case .streamSearch(let search, let home):
            return ["screen": "streamSearch", "service": home.service.id, "query": search.keyboard.text,
                    "phase": "\(search.phase)", "results": "\(search.results.count)"]
        case .service(let s):
            let v = player.activeView
            return ["screen": "service", "service": s.id, "url": v?.url?.absoluteString ?? "",
                    "loading": "\(v?.isLoading ?? false)", "progress": String(format: "%.2f", v?.estimatedProgress ?? 0),
                    "title": v?.title ?? "", "lastEvent": player.lastNavigationEvent]
        }
    }

    func debugOpen(serviceId: String) -> Bool {
        guard let s = AppServices.all.first(where: { $0.id == serviceId }) else { return false }
        if !isHomeShowing { goHome() }
        open(.stream(s))
        return true
    }

    func debugStream(serviceId: String) -> Bool {
        guard let s = AppServices.all.first(where: { $0.id == serviceId }) else { return false }
        registerStreamSource(SampleStreamSource(service: s))
        if !isHomeShowing { goHome() }
        showStreamHome(s)
        return true
    }

    func debugSnapshot(_ done: @escaping @MainActor (Data?) -> Void) {
        if let web = player.activeView, case .service = screen {
            web.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated { done(image.flatMap(Self.png)) }
            }
            return
        }
        let shown = container.subviews.first ?? homeView
        guard let rep = shown.bitmapImageRepForCachingDisplay(in: shown.bounds) else { return done(nil) }
        shown.cacheDisplay(in: shown.bounds, to: rep)
        done(rep.representation(using: .png, properties: [:]))
    }

    func debugEval(_ js: String, _ done: @escaping @MainActor (String) -> Void) {
        guard let web = player.activeView, !wantsKeyboardIntents else { return done(#"{"error":"no service open"}"#) }
        Self.evaluate(js, in: web, done)
    }

    /// For building readers: a script in a service's own page, even while a
    /// stream screen covers it.
    func debugPeek(serviceId: String, _ js: String, _ done: @escaping @MainActor (String) -> Void) {
        guard let s = AppServices.all.first(where: { $0.id == serviceId }) else { return done(#"{"error":"unknown service"}"#) }
        Self.evaluate(js, in: player.view(for: s), done)
    }

    /// What the media probe recorded in a service's page (JSON text).
    func debugMediaFormats(serviceId: String, _ done: @escaping @MainActor (String) -> Void) {
        guard let s = AppServices.all.first(where: { $0.id == serviceId }) else { return done(#"{"error":"unknown service"}"#) }
        guard DebugServer.isEnabled else { return done(#"{"error":"debug channel off"}"#) }
        player.view(for: s).evaluateJavaScript(MediaProbeScript.readExpression) { value, _ in
            MainActor.assumeIsolated { done((value as? String) ?? #"{"error":"probe not present"}"#) }
        }
    }

    /// Switches a debug-only flag; a flag that changes a service's scripts reloads that service.
    func debugFlag(name: String, on: Bool) -> Bool {
        guard let flag = DebugFlag(name: name) else { return false }
        DebugFlags.set(flag, on)
        switch flag {
        case .mediaprobe:
            for s in AppServices.all { player.reinstallDebugScripts(for: s) }
        case .netflix51:
            if let s = AppServices.all.first(where: { $0.id == "netflix" }) { player.reinstallDebugScripts(for: s) }
        }
        return true
    }

    func debugMedia(serviceId: String, suspend: Bool?, _ done: @escaping @MainActor (String) -> Void) {
        guard let s = AppServices.all.first(where: { $0.id == serviceId }) else { return done("unknown service") }
        let page = player.view(for: s)
        let report = {
            page.requestMediaPlaybackState { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .none: done("none")
                    case .playing: done("playing")
                    case .paused: done("paused")
                    case .suspended: done("suspended")
                    @unknown default: done("unknown")
                    }
                }
            }
        }
        guard let suspend else { return report() }
        // Through the shell's own idempotent quiet/unquiet, so repeated calls
        // never stack WebKit's counted suspensions.
        if suspend { quiet(page) } else { unquiet(page) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { report() } }
    }

    private static func evaluate(_ js: String, in web: WKWebView, _ done: @escaping @MainActor (String) -> Void) {
        web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value): done(Self.json(value))
                case .failure(let error): done(Self.json(["error": error.localizedDescription]))
                }
            }
        }
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func json(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: d, as: UTF8.self)
        }
        let wrapped = (try? JSONSerialization.data(withJSONObject: ["value": "\(value)"])) ?? Data("null".utf8)
        return String(decoding: wrapped, as: UTF8.self)
    }
}
