// Owns: the composition root: builds the real parts and wires them together.
// Nothing else constructs windows, players or input sources.

import AppKit
import os
import CouchModeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private let keyboard = KeyboardInput()
    private let controllers = ControllerInput()
    private let hotKeys = GlobalHotKeys()
    private let hidPads = HIDGamepads()
    private let debugServer = DebugServer()

    /// The reader for a service: its script package when the Mac's config says `reader: package` and the package loads,
    /// else the built-in Swift reader (the default).
    private static func reader(for service: Service, player: WebPlayer, builtin: () -> StreamSource) -> StreamSource {
        let store = AppConfigStore.shared
        guard ReaderMode.from(store.setting(ReaderMode.settingKey, for: service.id), catalogDefault: store.catalog.app(id: service.id)?.reader) == .package else { return builtin() }
        guard let package = BundledPackageStore().package(for: service.id) else {
            Logger(subsystem: "local.brad.htpcshell", category: "package").error("\(service.id, privacy: .public): reader is package but none loaded; using the built-in reader")
            return builtin()
        }
        return ScriptReader(service: service, player: player, package: package)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start()
        let settings = SystemSettings()
        settings.migrateLoginItemAfterRename()
        let games = GameLauncher()
        let home = HomeModel(rows: AppCoordinator.homeRows(games: games))
        let player = WebPlayer()
        let coordinator = AppCoordinator(homeModel: home, player: player, system: SystemActions(), settings: settings, games: games, plex: PlexClient())
        self.coordinator = coordinator
        // Services with the shell's own screens: their reader drives the service's own page (a proxy).
        if let netflix = AppServices.all.first(where: { $0.id == NetflixHome.serviceID }) {
            coordinator.registerStreamSource(NetflixSource(service: netflix, player: player))
        }
        if let hulu = AppServices.all.first(where: { $0.id == HuluHome.serviceID }) {
            coordinator.registerStreamSource(HuluSource(service: hulu, player: player))
        }
        if let disney = AppServices.all.first(where: { $0.id == DisneyHome.serviceID }) {
            coordinator.registerStreamSource(DisneySource(service: disney, player: player))
        }
        if let prime = AppServices.all.first(where: { $0.id == PrimeHome.serviceID }) {
            coordinator.registerStreamSource(Self.reader(for: prime, player: player, builtin: { PrimeSource(service: prime, player: player) }))
        }
        if let appletv = AppServices.all.first(where: { $0.id == AppleTVHome.serviceID }) {
            coordinator.registerStreamSource(AppleTVSource(service: appletv, player: player))
        }
        // Demo mode: every web service (not Plex's app) opens the shell's own screens on invented titles.
        if DemoMode.isOn {
            for service in AppServices.all where service.id != "plex" {
                coordinator.registerStreamSource(DemoStreamSource(service: service))
            }
        }
        keyboard.start(wantsIntents: { coordinator.wantsKeyboardIntents }, interceptsBack: { coordinator.interceptsBackKey }, sink: { coordinator.handle($0) })
        controllers.start(sink: { coordinator.handle($0) }, onHome: { coordinator.homeRequested($0) },
                          passthrough: { KeyInjector.press($0) })
        hotKeys.register(onHome: { coordinator.homeRequested(.remoteOrKeyboard) })
        controllers.controllerTarget = { coordinator.controllerTarget() }
        hidPads.onButton = { [controllers] in controllers.hidButton($0, pressed: $1) }
        hidPads.onDirection = { [controllers] in controllers.hidDirection(x: $0, y: $1, stick: $2) }
        hidPads.onChange = { coordinator.inputDevicesChanged() }
        games.hidMap = { [hidPads] in hidPads.connected.first?.layout.dmHIDMap }
        coordinator.hidPads = hidPads
        hidPads.start()
        coordinator.show()
        coordinator.refreshContinueWatching()
        ServiceIcons.shared.refreshIfNeeded(AppServices.all)
        coordinator.startIdleWatch()
        coordinator.watchInputDevices()
        if DebugServer.isEnabled {
            debugServer.start(target: coordinator)
            // GET /screen needs Screen Recording: ask at startup, once, rather
            // than at the first capture. Only the debug channel uses it, so a
            // shell without it never shows the prompt.
            _ = ScreenCapture.ensurePermission()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { coordinator?.willTerminate() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
