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

    /// The reader for a service: its script package when the Mac's config says `reader: package` (or says nothing and the
    /// service has a package) and the package loads, else the built-in Swift reader.
    private static func reader(for service: Service, player: WebPlayer, builtin: () -> StreamSource) -> StreamSource {
        let store = AppConfigStore.shared
        let package = LayeredPackageStore().package(for: service.id)
        guard ReaderMode.from(store.setting(ReaderMode.settingKey, for: service.id), catalogDefault: store.catalog.app(id: service.id)?.reader,
                              packagePresent: package != nil) == .package else { return builtin() }
        guard let package else {
            Logger(subsystem: "local.brad.htpcshell", category: "package").error("\(service.id, privacy: .public): reader is package but none loaded; using the built-in reader")
            return builtin()
        }
        return ScriptReader(service: service, player: player, package: package)
    }

    /// The reader for a service that has one. nil for the rest.
    private static func makeSource(for service: Service, player: WebPlayer) -> StreamSource? {
        switch service.id {
        case NetflixHome.serviceID: return reader(for: service, player: player, builtin: { NetflixSource(service: service, player: player) })
        case HuluHome.serviceID: return reader(for: service, player: player, builtin: { HuluSource(service: service, player: player) })
        case DisneyHome.serviceID: return reader(for: service, player: player, builtin: { DisneySource(service: service, player: player) })
        case PrimeHome.serviceID: return reader(for: service, player: player, builtin: { PrimeSource(service: service, player: player) })
        case AppleTVHome.serviceID: return reader(for: service, player: player, builtin: { AppleTVSource(service: service, player: player) })
        default: return nil
        }
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
        for service in AppServices.all {
            if let source = Self.makeSource(for: service, player: player) { coordinator.registerStreamSource(source) }
        }
        // Apps added later (Settings > Apps) get their reader without a restart.
        coordinator.makeStreamSource = { [player] in Self.makeSource(for: $0, player: player) }
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
        coordinator.startPackageChecks()
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
