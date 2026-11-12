// Owns: watching the keyboard while a game is in front, for the one shortcut the Carbon
// hot key can't give: a held Escape returns to the shell (EscapeHold decides when).
// ⌘⌫ is also handled here as a second route, so Home works even if the hot key
// registration was lost. It never consumes a key: the game still gets its keys.
// Uses an active session event tap (Accessibility permission, which the remote already
// needs); a listen-only watcher would need a separate Input Monitoring permission.

import AppKit
import ApplicationServices
import os
import CouchModeCore

@MainActor
final class GameKeyboardExit {
    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "keyboard")
    private enum Timing { static let poll: TimeInterval = 0.1 }

    private var tap: CFMachPort?
    private var hold = EscapeHold()
    private var timer: Timer?
    private var inGame: (@MainActor () -> Bool)?
    private var home: (@MainActor () -> Void)?

    func start(inGame: @escaping @MainActor () -> Bool, home: @escaping @MainActor () -> Void) {
        self.inGame = inGame
        self.home = home
        install()
        // Accessibility may be granted after launch: try again whenever the shell comes to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
    }

    private func install() {
        guard tap == nil else { return }
        guard KeyInjector.isAllowed else { Self.log.error("no Accessibility permission: keyboard Home from games is off"); return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GameKeyboardExit>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.seen(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Self.log.error("key watcher not created")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
        tap = port
        Self.log.info("key watcher on")
    }

    private func seen(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelHold()
            return
        }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            if KeyboardHome.isHoldKey(keyCode: code) { cancelHold() }
            return
        }
        guard type == .keyDown, inGame?() == true else { return }
        if KeyboardHome.isHomeChord(keyCode: code, command: event.flags.contains(.maskCommand)) {
            home?()
        } else if KeyboardHome.isHoldKey(keyCode: code) {
            hold.keyDown(now: Date())
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: Timing.poll, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            }
        }
    }

    private func tick() {
        // The game left the front some other way (or the shell came up): nothing left to wait for.
        guard inGame?() == true else { return cancelHold() }
        if hold.poll(now: Date()) {
            cancelHold()
            home?()
        }
    }

    private func cancelHold() {
        hold.keyUp()
        timer?.invalidate()
        timer = nil
    }
}
