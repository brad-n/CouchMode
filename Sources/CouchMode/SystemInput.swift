// Owns: input that reaches beyond the shell's own window.
// - GlobalHotKeys: ⌘⌫ and the keyboard's Home key return to the shell from
//   any app (Carbon hot keys: system-wide, no permission needed).
// - KeyInjector: types a key into the app in front, so the Apple TV remote
//   can drive Plex HTPC and other launched apps. Needs macOS Accessibility
//   permission for this app, asked for once.
// - PointerPark: moves the mouse pointer off a screen edge before a game
//   takes the screen (an edge pulls up the Dock over a full-screen game).
// - ShellActivation: brings the shell to the front from behind another app.

import AppKit
import ApplicationServices
import Carbon
import os
import CouchModeCore

@MainActor
final class GlobalHotKeys {
    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "hotkeys")
    nonisolated(unsafe) private static var action: (() -> Void)?
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func register(onHome: @escaping @MainActor () -> Void) {
        Self.action = { DispatchQueue.main.async { MainActor.assumeIsolated { onHome() } } }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            GlobalHotKeys.action?()
            return noErr
        }, 1, &spec, nil, &handler)
        add(UInt32(kVK_Delete), modifiers: UInt32(cmdKey), id: 1)    // ⌘⌫
        add(UInt32(kVK_Home), modifiers: 0, id: 2)                    // Home key
    }

    private func add(_ key: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4854_5043), id: id)   // 'HTPC'
        let status = RegisterEventHotKey(key, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
        else { Self.log.error("hot key \(id) not registered: \(status)") }
    }
}

enum KeyInjector {
    /// Whether macOS lets this app type into other apps.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow CouchMode to control this computer" prompt.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Presses and releases a key in whatever app is in front.
    static func press(_ key: Key) { press(code: KeyCodes.of(key).0, command: false, holdMilliseconds: 0) }

    static let maxHoldMilliseconds = 5000

    /// A key (optionally with ⌘) down, repeating while held, then up. Used by the debug channel to stand in for a keyboard.
    static func press(code: UInt16, command: Bool, holdMilliseconds: Int) {
        guard isAllowed else { return }
        // A private source starts from no modifiers, so the key carries only the flags set here.
        let source = CGEventSource(stateID: .privateState)
        func post(down: Bool, repeating: Bool = false) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            // Command rides only on the key's press.
            event.flags = command && down ? .maskCommand : []
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.post(tap: .cghidEventTap)
        }
        post(down: true)
        // Auto-repeat while held, every 90 ms, as a keyboard does; then release.
        let repeats = holdMilliseconds / 90
        for i in 0..<repeats {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90 * (i + 1))) { post(down: true, repeating: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(holdMilliseconds, 0))) { post(down: false) }
    }
}

/// Keeps the mouse pointer out of the picture. A pointer resting on a screen
/// edge pulls the Dock or menu bar up over a full-screen game, so before a
/// game or app takes the screen it moves to the middle, where games (and the
/// shell) hide it once it's idle. Away from the edges it's left alone.
enum PointerPark {
    private static let edge: CGFloat = 4

    static func offEdges(_ screen: NSScreen?) {
        guard let frame = (screen ?? NSScreen.main)?.frame else { return }
        let p = NSEvent.mouseLocation
        let onEdge = p.x <= frame.minX + edge || p.x >= frame.maxX - edge || p.y <= frame.minY + edge || p.y >= frame.maxY - edge
        guard onEdge else { return }
        // Quartz's global coordinates start at the top left of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: mainHeight - frame.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// macOS hands the front to an app only when the active app yields it, so a
/// shell sitting behind Plex HTPC or a game can't simply activate itself.
/// With the Accessibility permission (the one the remote already uses) it
/// asks for the front directly. Retries for up to 3 seconds, since the app in
/// front may be quitting or hiding meanwhile.
@MainActor
enum ShellActivation {
    private static let attempts = 12
    private static let interval: TimeInterval = 0.25
    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "activation")

    static func bringForward(_ window: NSWindow) { attempt(0, window) }

    private static func attempt(_ n: Int, _ window: NSWindow) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        if !NSApp.isActive && KeyInjector.isAllowed {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive { return }
        guard n + 1 < attempts else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            log.error("could not take the front from \(front, privacy: .public) (Accessibility allowed: \(KeyInjector.isAllowed))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { MainActor.assumeIsolated { attempt(n + 1, window) } }
    }
}
