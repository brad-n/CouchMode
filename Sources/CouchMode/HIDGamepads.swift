// Owns: gamepads macOS pairs but GameController doesn't support (such as
// HORI's licensed Switch pad), read as raw HID through IOKit, the way
// NX2Apple's games read them. Only pads with a known layout
// (HIDPadLayout.known) are read, so no pad is ever read twice. What a
// press does is ControllerInput's, as for any controller.

import Foundation
import IOKit.hid
import os
import CouchModeCore

@MainActor
final class HIDGamepads {
    struct Pad {
        let name: String
        let layout: HIDPadLayout
    }

    private enum Limits {
        static let recentEvents = 40
    }

    private let log = Logger(subsystem: "local.brad.htpcshell", category: "hidpads")
    private var manager: IOHIDManager?
    private var pads: [ObjectIdentifier: Pad] = [:]
    private var recent: [String] = []
    private var hat: (x: Float, y: Float) = (0, 0)
    private var stick: (x: Float, y: Float) = (0, 0)

    /// A Switch-labelled button went down (true) or up (false).
    var onButton: ((HIDPadLayout.Button, Bool) -> Void)?
    /// Direction, x right and y up, -1...1; `stick` is true for the analog
    /// stick (which wants a dead zone), false for the d-pad.
    var onDirection: ((Float, Float, Bool) -> Void)?
    /// A known pad connected or went away.
    var onChange: (() -> Void)?

    var connected: [Pad] { Array(pads.values) }
    /// The last presses, with their raw HID usages, for the debug channel.
    var recentEvents: [String] { recent }

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<HIDGamepads>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<HIDGamepads>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx else { return }
            let me = Unmanaged<HIDGamepads>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.input(value) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { log.error("could not open HID gamepads: \(result)") }
        manager = m
    }

    private func added(_ device: IOHIDDevice) {
        let vendor = Self.int(device, kIOHIDVendorIDKey), product = Self.int(device, kIOHIDProductIDKey)
        guard let layout = HIDPadLayout.layout(vendor: vendor, product: product) else { return }
        let name = Self.string(device, kIOHIDProductKey) ?? layout.name
        pads[ObjectIdentifier(device)] = Pad(name: name, layout: layout)
        note(String(format: "connected %@ (%04x:%04x)", name, vendor, product))
        onChange?()
    }

    private func removed(_ device: IOHIDDevice) {
        guard let pad = pads.removeValue(forKey: ObjectIdentifier(device)) else { return }
        note("disconnected \(pad.name)")
        onChange?()
    }

    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard let pad = pads[ObjectIdentifier(IOHIDElementGetDevice(element))] else { return }
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        let v = IOHIDValueGetIntegerValue(value)
        if page == UInt32(kHIDPage_Button) {
            let button = pad.layout.button(forUsage: Int(usage))
            if v != 0 { note("usage \(usage) = \(button?.rawValue ?? "not mapped")") }
            if let button { onButton?(button, v != 0) }
            return
        }
        guard page == UInt32(kHIDPage_GenericDesktop) else { return }
        switch Int(usage) {
        case kHIDUsage_GD_Hatswitch:
            hat = HIDPadLayout.hatVector(v - IOHIDElementGetLogicalMin(element))
            onDirection?(hat.x, hat.y, false)
        case kHIDUsage_GD_X, kHIDUsage_GD_Y:
            let lo = IOHIDElementGetLogicalMin(element), hi = IOHIDElementGetLogicalMax(element)
            guard hi > lo else { return }
            let n = Float(v - lo) / Float(hi - lo) * 2 - 1
            if Int(usage) == kHIDUsage_GD_X { stick.x = n } else { stick.y = -n }   // HID y grows downward
            // The d-pad wins while it's held.
            if hat == (0, 0) { onDirection?(stick.x, stick.y, true) }
        default:
            break
        }
    }

    private func note(_ line: String) {
        log.info("\(line, privacy: .public)")
        recent.append(line)
        if recent.count > Limits.recentEvents { recent.removeFirst(recent.count - Limits.recentEvents) }
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
