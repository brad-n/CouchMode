// Owns: the composition root: builds the real parts and wires them together.
// Nothing else constructs windows, players or input sources.

import AppKit
import CouchModeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private let keyboard = KeyboardInput()
    private let controllers = ControllerInput()
    private let hotKeys = GlobalHotKeys()
    private let hidPads = HIDGamepads()
    private let debugServer = DebugServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SystemSettings()
        settings.migrateLoginItemAfterRename()
        let games = GameLauncher()
        let home = HomeModel(rows: AppCoordinator.homeRows(games: games))
        let player = WebPlayer()
        let coordinator = AppCoordinator(homeModel: home, player: player, system: SystemActions(), settings: settings, games: games, plex: PlexClient())
        self.coordinator = coordinator
        // Services with the shell's own screens: their reader drives the service's own page (a proxy).
        if let netflix = ServiceCatalog.all.first(where: { $0.id == NetflixHome.serviceID }) {
            coordinator.registerStreamSource(NetflixSource(service: netflix, player: player))
        }
        if let hulu = ServiceCatalog.all.first(where: { $0.id == HuluHome.serviceID }) {
            coordinator.registerStreamSource(HuluSource(service: hulu, player: player))
        }
        if let disney = ServiceCatalog.all.first(where: { $0.id == DisneyHome.serviceID }) {
            coordinator.registerStreamSource(DisneySource(service: disney, player: player))
        }
        // Demo mode: every web service (not Plex's app) opens the shell's own screens on invented titles.
        if DemoMode.isOn {
            for service in ServiceCatalog.all where service.id != "plex" {
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
