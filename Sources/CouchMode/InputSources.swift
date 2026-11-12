// Owns: turning physical input (keyboard, game controllers) into ShellIntents.
// It does not decide what an intent does; the sink does.

import AppKit
import GameController
import CouchModeCore

typealias IntentSink = @MainActor (ShellIntent) -> Void

/// Keyboard: ⌘⌫ is Home everywhere. Other keys become intents only on the
/// shell's own screens; on a streaming site the real keys go to the site.
@MainActor
final class KeyboardInput {
    private var monitor: Any?

    func start(wantsIntents: @escaping @MainActor () -> Bool, interceptsBack: @escaping @MainActor () -> Bool,
               sink: @escaping IntentSink) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let deleteKey: UInt16 = 51
            if event.modifierFlags.contains(.command) && event.keyCode == deleteKey {
                sink(.home); return nil
            }
            // A handed-off title: Escape and Delete are Back for the shell; other keys stay the player's.
            if PlayerBackKey.isBack(keyCode: event.keyCode, handedOffTitleShowing: interceptsBack()) {
                sink(.back); return nil
            }
            guard wantsIntents(), let intent = Self.shellIntent(event.keyCode) else { return event }
            sink(intent); return nil
        }
    }

    private static func shellIntent(_ code: UInt16) -> ShellIntent? {
        switch code {
        case 123: return .move(.left)
        case 124: return .move(.right)
        case 125: return .move(.down)
        case 126: return .move(.up)
        case 36, 76: return .select       // Return, keypad Enter
        case 53: return .back             // Escape
        case 34: return .info             // I
        default: return nil
        }
    }
}

/// Game controllers: d-pad or left stick move (repeating while held),
/// A = select, B = back, Menu = home. Holding Menu works from ANY app
/// (Plex HTPC, a game) like Apple TV's Home button: the shell listens in the
/// background but ignores everything else while another app is in front.
@MainActor
final class ControllerInput {
    private enum Timing {
        static let firstRepeat: TimeInterval = 0.40
        static let repeatEvery: TimeInterval = 0.12
        static let stickThreshold: Float = 0.6
        static let homeHold: TimeInterval = 0.8
    }

    private var sink: IntentSink?
    private var onHome: (@MainActor (HomeSource) -> Void)?
    /// Types a key into the app in front (Apple TV remote driving Plex HTPC etc.).
    private var passthrough: (@MainActor (Key) -> Void)?
    /// Where a controller's presses go right now (ControllerRouting), set by main.
    var controllerTarget: (@MainActor () -> ControllerTarget)?
    private var target: ControllerTarget { shellActive ? .shell : controllerTarget?() ?? .game }
    private var held: Direction?
    /// The held direction goes to the app in front as arrow keys.
    private var heldGoesToApp = false
    private var repeatTimer: Timer?
    private var menuTimer: Timer?
    private var menuHoldFired = false

    /// Input only drives the shell while it is the active app.
    private var shellActive: Bool { NSApp.isActive }

    func start(sink: @escaping IntentSink, onHome: @escaping @MainActor (HomeSource) -> Void,
               passthrough: @escaping @MainActor (Key) -> Void) {
        self.sink = sink
        self.onHome = onHome
        self.passthrough = passthrough
        // Needed so a held Menu reaches us while Plex HTPC or a game is in front.
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let c = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ controller: GCController) {
        // The Home / TV button (Siri Remote, Xbox, PlayStation) means "back
        // to the shell" from any app, like on Apple TV. A game controller's is
        // the game's own while a Switch game is in front (HomeRouting).
        if let home = controller.physicalInputProfile.buttons[GCInputButtonHome] {
            let source: HomeSource = controller.extendedGamepad == nil ? .remoteOrKeyboard : .controllerHome
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { if pressed { self?.onHome?(source) } }
            }
        }
        if controller.extendedGamepad == nil, let remote = controller.microGamepad {
            attachRemote(remote)
            return
        }
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.directional(x: x, y: y, threshold: 0.5) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.directional(x: x, y: y, threshold: Timing.stickThreshold) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.controllerPress(.select) } }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.controllerPress(.back) } }
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.menu(pressed: pressed) }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.controllerPress(.info) } }
        }
    }

    /// A pad read as raw HID (HIDGamepads), by its Switch labels: the same
    /// rules as a controller's buttons (games keep theirs; a held + returns
    /// to the shell from apps). Its Home counts as the remote's: NX2Apple
    /// reads a raw HID pad's buttons by DM_HID_MAP, which has no Home, so a
    /// game never sees it and the shell pauses the game instead.
    func hidButton(_ button: HIDPadLayout.Button, pressed: Bool) {
        switch HIDPadLayout.action(for: button) {
        case .select?: if pressed { controllerPress(.select) }
        case .back?: if pressed { controllerPress(.back) }
        case .info?: if pressed { controllerPress(.info) }
        case .menu?: menu(pressed: pressed)
        case .home?: if pressed { onHome?(.remoteOrKeyboard) }
        case nil: break
        }
    }

    func hidDirection(x: Float, y: Float, stick: Bool) {
        directional(x: x, y: y, threshold: stick ? Timing.stickThreshold : 0.5)
    }

    /// Siri Remote (and other simple remotes): touch surface or click ring
    /// moves, click = select, Play/Pause = info (details; play/pause on sites),
    /// Back = back (hold = home). While another app is in front, presses
    /// become that app's keys (arrows, Return, Esc, Space); Home still
    /// returns to the shell.
    private func attachRemote(_ remote: GCMicroGamepad) {
        remote.reportsAbsoluteDpadValues = false   // swipes act like a d-pad
        remote.allowsRotation = false
        remote.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.directional(x: x, y: y, threshold: 0.5, fromRemote: true) }
        }
        remote.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.remote(.select) } }
        }
        remote.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.remote(.info) } }   // Play/Pause
        }
        remote.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.back(pressed: pressed) }
        }
    }

    /// A controller button: the shell's intent, the key a non-game app in
    /// front understands, or nothing while a game reads the controller.
    private func controllerPress(_ intent: ShellIntent) {
        switch target {
        case .shell: sink?(intent)
        case .appAsKeys: if let key = RemotePassthrough.key(for: intent) { passthrough?(key) }
        case .game: break
        }
    }

    /// A remote press: the shell's intent when it's in front, else the key
    /// the app in front understands.
    private func remote(_ intent: ShellIntent) {
        if shellActive { sink?(intent) }
        else if let key = RemotePassthrough.key(for: intent) { passthrough?(key) }
    }

    /// Remote Back: short press = back (or Esc in the app in front); hold = home anywhere.
    private func back(pressed: Bool) {
        if pressed {
            menuHoldFired = false
            menuTimer?.invalidate()
            menuTimer = Timer.scheduledTimer(withTimeInterval: Timing.homeHold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuHoldFired = true
                    self?.onHome?(.remoteOrKeyboard)
                }
            }
        } else {
            menuTimer?.invalidate()
            if !menuHoldFired { remote(.back) }
        }
    }

    /// Short press (shell in front) = Home. Hold for 0.8 s = back to the shell
    /// from an app in front, but not from a game, where it's a game button.
    private func menu(pressed: Bool) {
        if pressed {
            menuHoldFired = false
            menuTimer?.invalidate()
            menuTimer = Timer.scheduledTimer(withTimeInterval: Timing.homeHold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuHoldFired = true
                    self?.onHome?(.controllerMenuHold)
                }
            }
        } else {
            menuTimer?.invalidate()
            if !menuHoldFired && shellActive { sink?(.home) }
        }
    }

    private func directional(x: Float, y: Float, threshold: Float, fromRemote: Bool = false) {
        // A remote drives any app in front; a game controller drives the shell
        // or a non-game app (ControllerRouting), never a game (it reads the pad).
        let toApp = !shellActive && (fromRemote || target == .appAsKeys)
        guard shellActive || toApp else { held = nil; repeatTimer?.invalidate(); return }
        let dir: Direction?
        if abs(x) < threshold && abs(y) < threshold { dir = nil }
        else if abs(x) > abs(y) { dir = x > 0 ? .right : .left }
        else { dir = y > 0 ? .up : .down }
        guard dir != held else { return }
        held = dir
        heldGoesToApp = toApp
        repeatTimer?.invalidate()
        guard let dir else { return }
        emitMove(dir)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Timing.firstRepeat, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeating(dir) }
        }
    }

    private func emitMove(_ dir: Direction) {
        if shellActive { sink?(.move(dir)) }
        else if heldGoesToApp, let key = RemotePassthrough.key(for: .move(dir)) { passthrough?(key) }
    }

    private func startRepeating(_ dir: Direction) {
        guard held == dir else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Timing.repeatEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.held == dir else { return }
                self.emitMove(dir)
            }
        }
    }
}
