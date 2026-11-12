// Owns: the button layouts of gamepads macOS pairs but its GameController
// framework doesn't support (such as HORI's licensed Switch pad), which the
// shell and NX2Apple's games read as raw HID. A pad is only read when its
// USB vendor:product ID is listed here, so a pad GameController supports
// is never read twice. Buttons go by their Switch labels.

import Foundation

public struct HIDPadLayout: Equatable, Sendable {
    public enum Button: String, CaseIterable, Sendable {
        case a = "A", b = "B", x = "X", y = "Y", l = "L", r = "R", zl = "ZL", zr = "ZR"
        case minus = "MINUS", plus = "PLUS", ls = "LS", rs = "RS", home = "HOME", capture = "CAPTURE"
    }

    /// What a pad button does in the shell (Nintendo convention: A on the
    /// right confirms, B below it goes back).
    public enum Action: Equatable, Sendable { case select, back, info, menu, home }

    public let name: String
    /// HID button usage (1...32) of each Switch-labelled button.
    public let usages: [Button: Int]

    public init(name: String, usages: [Button: Int]) { self.name = name; self.usages = usages }

    public func button(forUsage usage: Int) -> Button? { usages.first { $0.value == usage }?.key }

    /// NX2Apple's DM_HID_MAP for this layout. Its names, in its order; Home
    /// and Capture aren't among them (the game reads those itself).
    public var dmHIDMap: String {
        let order: [Button] = [.a, .b, .x, .y, .ls, .rs, .l, .r, .zl, .zr, .plus, .minus]
        return order.compactMap { b in usages[b].map { "\(b.rawValue)=\($0)" } }.joined(separator: ",")
    }

    public static func action(for button: Button) -> Action? {
        switch button {
        case .a: return .select
        case .b: return .back
        case .x, .y: return .info
        case .plus: return .menu
        case .home: return .home
        case .l, .r, .zl, .zr, .minus, .ls, .rs, .capture: return nil
        }
    }

    /// A hat switch value as a direction vector (x right, y up, as
    /// GameController reports a d-pad): 0 up, clockwise to 7 up-left;
    /// anything else is centred.
    public static func hatVector(_ value: Int) -> (x: Float, y: Float) {
        switch value {
        case 0: return (0, 1)
        case 1: return (1, 1)
        case 2: return (1, 0)
        case 3: return (1, -1)
        case 4: return (0, -1)
        case 5: return (-1, -1)
        case 6: return (-1, 0)
        case 7: return (-1, 1)
        default: return (0, 0)
        }
    }

    /// HORI's wireless Switch pad ("Lic Pro Controller"): face buttons
    /// bottom, right, left, top (B, A, Y, X), as SDL's controller database
    /// lists it and as pressing each button on a real pad showed (2026-11-11).
    private static let horiSwitchPad: [Button: Int] = [
        .b: 1, .a: 2, .y: 3, .x: 4, .l: 5, .r: 6, .zl: 7, .zr: 8,
        .minus: 9, .plus: 10, .ls: 11, .rs: 12, .home: 13, .capture: 14,
    ]

    public static let known: [String: HIDPadLayout] = [
        "0f0d:00f6": HIDPadLayout(name: "HORI wireless pad for Switch", usages: horiSwitchPad),
    ]

    public static func layout(vendor: Int, product: Int) -> HIDPadLayout? {
        known[String(format: "%04x:%04x", vendor, product)]
    }
}
