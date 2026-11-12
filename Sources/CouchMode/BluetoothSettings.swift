// Owns: macOS's Bluetooth settings, driven from the shell through
// Accessibility so a remote can connect and pair devices. macOS lets only
// its own settings pair controllers, remotes and headphones (an app can't
// pair Bluetooth LE HID devices), and the settings show a device's Connect
// button only under a mouse pointer; each device's context menu has
// Connect without one. Reading the page is BluetoothPane's (CouchModeCore).

import AppKit
import ApplicationServices
import os
import CouchModeCore

@MainActor
final class BluetoothSettings {
    private static let bundleID = "com.apple.systempreferences"
    private static let paneURL = URL(string: "x-apple.systempreferences:com.apple.Bluetooth")!
    private enum Timing {
        /// How long a context menu gets to appear before it's read.
        static let menuAppears: Duration = .milliseconds(400)
        static let menuAttempts = 5
    }
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "bluetooth")

    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first { !$0.isTerminated }
    }

    /// Opens System Settings on its Bluetooth page without bringing it
    /// forward (the shell stays in front; the page keeps scanning).
    func open() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.open(Self.paneURL, configuration: config) { [log] _, error in
            if let error { log.error("open Bluetooth settings failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Quits System Settings, when the shell's Bluetooth screen closes.
    func close() { app?.terminate() }

    /// The devices the page lists now (empty until it has loaded).
    func devices() -> [BluetoothDevice] {
        guard let root = snapshot() else { return [] }
        return BluetoothPane.devices(Self.items(root))
    }

    /// The titles of the device's context menu, read and then dismissed:
    /// for the debug channel.
    func menuTitles(for device: BluetoothDevice) async -> [String] {
        guard await bringForward(), let menu = await openMenu(for: device) else { return [] }
        let titles = menu.items.map(\.text)
        cancel(menu.menu)
        return titles
    }

    /// Connects (or pairs) a listed device with its context menu's Connect.
    /// False when the device or the menu item isn't there. System Settings
    /// comes forward for it (a background app's menus won't open: AXError
    /// -25204); the caller takes the screen back afterwards.
    func connect(_ device: BluetoothDevice) async -> Bool {
        guard await bringForward() else { return false }
        if !device.isKnown { return await connectNearby(device) }
        guard let menu = await openMenu(for: device) else { return false }
        guard let item = menu.items.first(where: { $0.text == "Connect" }) else {
            log.error("no Connect in the menu of \(device.name, privacy: .public): \(menu.items.map(\.text), privacy: .public)")
            cancel(menu.menu)
            return false
        }
        let ok = AccessibilityTree.press(item)
        log.info("connect \(device.name, privacy: .public): \(ok ? "pressed" : "press failed", privacy: .public)")
        return ok
    }

    /// The buttons that appear on a nearby device's row under the pointer,
    /// read without pressing: for the debug channel.
    func hoverButtons(for device: BluetoothDevice) async -> [String] {
        guard await bringForward() else { return [] }
        return await hovering(device) { buttons in buttons.map(\.text) } ?? []
    }

    /// A nearby (new) device: the settings show its Connect button only
    /// under the pointer and it has no context menu, so the pointer rests on
    /// its row while the button is pressed, then goes back.
    private func connectNearby(_ device: BluetoothDevice) async -> Bool {
        let pressed = await hovering(device) { buttons -> Bool? in
            guard let connect = buttons.first(where: { $0.text == "Connect" }) else { return nil }
            return AccessibilityTree.press(connect)
        }
        log.info("connect nearby \(device.name, privacy: .public): \(pressed == true ? "pressed" : "no Connect button", privacy: .public)")
        return pressed == true
    }

    /// Rests the pointer on the device's row until `use` gets a result from
    /// the row's buttons (at most about 2 s), then puts the pointer back.
    private func hovering<T>(_ device: BluetoothDevice, _ use: ([AXNode]) -> T?) async -> T? {
        // The settings window opens small, with Nearby Devices below its
        // edge, where the pointer would rest on whatever is behind: make it
        // as tall as the screen first (it doesn't scroll for Accessibility).
        if let before = snapshot(), let window = before.all.first(where: { $0.role == kAXWindowRole as String }),
           let current = AccessibilityTree.frame(of: window), let screen = NSScreen.main?.visibleFrame {
            let top = (NSScreen.screens.first?.frame.height ?? screen.maxY) - screen.maxY   // menu bar, in top-left coordinates
            AccessibilityTree.setFrame(of: window, to: CGRect(x: current.minX, y: top + 20, width: current.width, height: screen.height - 40))
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let root = snapshot(), let row = Self.row(device, in: root), let frame = AccessibilityTree.frame(of: row) else {
            log.error("\(device.name, privacy: .public) is not on the Bluetooth page")
            return nil
        }
        let home = CGEvent(source: nil)?.location
        let spot = CGPoint(x: frame.midX, y: frame.midY)
        defer { if let home { CGWarpMouseCursorPosition(home) } }
        for _ in 0..<10 {
            CGWarpMouseCursorPosition(spot)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: spot, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(200))
            guard let now = snapshot(), let rowNow = Self.row(device, in: now) else { continue }
            if let result = use(Self.buttons(near: rowNow, in: now)) { return result }
        }
        return nil
    }

    /// The device's name text on the page.
    private static func row(_ device: BluetoothDevice, in root: AXNode) -> AXNode? {
        root.all.first { $0.role == kAXStaticTextRole as String && $0.text == device.name }
    }

    /// Buttons in the same group as the device's name (its row's controls).
    private static func buttons(near row: AXNode, in root: AXNode) -> [AXNode] {
        func parent(of target: AXNode, in node: AXNode) -> AXNode? {
            if node.children.contains(where: { CFEqual($0.element, target.element) }) { return node }
            for child in node.children { if let p = parent(of: target, in: child) { return p } }
            return nil
        }
        guard let group = parent(of: row, in: root) else { return [] }
        return group.all.filter { $0.role == kAXButtonRole as String && !$0.text.isEmpty }
    }

    /// Hands the front to System Settings and waits (at most about 1.5 s)
    /// until it has it.
    private func bringForward() async -> Bool {
        guard let app else { return false }
        NSApp.yieldActivation(to: app)
        app.activate()
        for _ in 0..<15 {
            if app.isActive { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log.error("System Settings did not come forward")
        return false
    }

    // MARK: Accessibility

    private func snapshot() -> AXNode? {
        guard let app else { return nil }
        return AccessibilityTree.snapshot(pid: app.processIdentifier)
    }

    /// The page as BluetoothPane reads it: headings, texts and buttons in order.
    private static func items(_ root: AXNode) -> [PaneItem] {
        root.all.compactMap { n in
            switch n.role {
            case kAXHeadingRole as String: return PaneItem(.heading, n.text)
            case kAXStaticTextRole as String: return PaneItem(.text, n.text)
            case kAXButtonRole as String: return PaneItem(.button, n.text)
            // The lists end where the window's scroll bar, toolbar or menu bar begin.
            case kAXScrollBarRole as String, kAXToolbarRole as String, kAXMenuBarRole as String: return PaneItem(.heading, n.role)
            default: return nil
            }
        }
    }

    /// Opens the device row's context menu and returns it with its items.
    private func openMenu(for device: BluetoothDevice) async -> (menu: AXNode, items: [AXNode])? {
        guard let root = snapshot(),
              let row = root.all.first(where: { $0.role == kAXStaticTextRole as String && $0.text == device.name
                                                && $0.actions.contains(kAXShowMenuAction as String) }) else {
            log.error("\(device.name, privacy: .public) is not on the Bluetooth page")
            return nil
        }
        // Just after System Settings comes forward the action can still fail
        // with "cannot complete" (AXError -25204): a few tries, 300 ms apart.
        var shown = AXError.cannotComplete
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            shown = AXUIElementPerformAction(row.element, kAXShowMenuAction as CFString)
            if shown != .cannotComplete { break }
        }
        guard shown == .success else {
            log.error("could not open the menu of \(device.name, privacy: .public): AXError \(shown.rawValue)")
            return nil
        }
        for _ in 0..<Timing.menuAttempts {
            try? await Task.sleep(for: Timing.menuAppears)
            if let root = snapshot(), let menu = Self.contextMenu(in: root) {
                return (menu, menu.all.filter { $0.role == kAXMenuItemRole as String && !$0.text.isEmpty })
            }
        }
        log.error("no context menu appeared for \(device.name, privacy: .public)")
        return nil
    }

    /// The open context menu: a menu anywhere but under the menu bar, whose
    /// menus (the Apple menu, File, Edit…) are always in the tree.
    private static func contextMenu(in node: AXNode) -> AXNode? {
        if node.role == kAXMenuBarRole as String { return nil }
        if node.role == kAXMenuRole as String { return node }
        for child in node.children { if let menu = contextMenu(in: child) { return menu } }
        return nil
    }

    private func cancel(_ menu: AXNode) {
        AXUIElementPerformAction(menu.element, kAXCancelAction as CFString)
    }
}
