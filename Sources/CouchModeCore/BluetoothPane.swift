// Owns: what macOS's Bluetooth settings list, read from its interface (a
// flat list of headings and texts, in screen order, as Accessibility gives
// them) into devices the shell can show and connect. English settings only:
// the section headings are matched by their English text.

public struct PaneItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case heading, text, button }
    public let kind: Kind
    public let text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

public struct BluetoothDevice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case controller, remote, headphones, keyboard, pointer, other }
    public let name: String
    /// Remembered by this Mac ("My Devices"); otherwise it's nearby and new.
    public let isKnown: Bool
    public let isConnected: Bool
    /// "100%", when the settings show a battery level.
    public let battery: String?
    public var id: String { (isKnown ? "known:" : "nearby:") + name }
    public var kind: Kind { BluetoothDevice.kind(of: name) }

    public init(name: String, isKnown: Bool, isConnected: Bool, battery: String? = nil) {
        self.name = name; self.isKnown = isKnown; self.isConnected = isConnected; self.battery = battery
    }

    /// A best guess from the name, for its icon.
    public static func kind(of name: String) -> Kind {
        let n = name.lowercased()
        let has = { (words: [String]) in words.contains { n.contains($0) } }
        if has(["controller", "dualsense", "dualshock", "xbox", "joy-con", "gamepad", "8bitdo"]) { return .controller }
        if has(["remote"]) { return .remote }
        if has(["airpods", "headphone", "beats", "buds", "earbuds", "headset", "speaker"]) { return .headphones }
        if has(["keyboard"]) { return .keyboard }
        if has(["trackpad", "mouse"]) { return .pointer }
        return .other
    }
}

public enum BluetoothPane {
    public static let myDevicesHeading = "My Devices"
    public static let nearbyHeading = "Nearby Devices"

    /// Devices in screen order: "My Devices" rows are a name, a status
    /// ("Connected - 100%", "Not Connected") and a Show Detail button;
    /// "Nearby Devices" rows are a name each.
    public static func devices(_ items: [PaneItem]) -> [BluetoothDevice] {
        enum Section { case mine, nearby }
        var section: Section?
        var pendingName: String?
        var out: [BluetoothDevice] = []
        for item in items {
            switch item.kind {
            case .heading:
                section = item.text == myDevicesHeading ? .mine : item.text == nearbyHeading ? .nearby : nil
                pendingName = nil
            case .button:
                pendingName = nil
            case .text where section == .mine:
                if let name = pendingName {
                    out.append(device(name: name, status: item.text))
                    pendingName = nil
                } else {
                    pendingName = item.text
                }
            case .text where section == .nearby:
                if !item.text.isEmpty { out.append(BluetoothDevice(name: item.text, isKnown: false, isConnected: false)) }
            case .text:
                break
            }
        }
        return out
    }

    private static func device(name: String, status: String) -> BluetoothDevice {
        let connected = status.hasPrefix("Connected")
        let battery = status.split(separator: "-").last.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.hasSuffix("%") ? $0 : nil }
        return BluetoothDevice(name: name, isKnown: true, isConnected: connected, battery: battery)
    }
}

/// One row of the shell's Remotes & Controllers list.
public struct BluetoothListRow: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, connect, pair }
    public let id: String
    public let title: String
    public let value: String
    public let kind: BluetoothDevice.Kind
    public let action: Action
}

extension BluetoothPane {
    /// The list a remote can work: connected devices first, then the ones
    /// this Mac remembers (select to connect), then nearby new ones (select
    /// to pair). Bounded, so a crowded room can't push the list off screen.
    public static func listing(_ devices: [BluetoothDevice], limit: Int = 10) -> [BluetoothListRow] {
        let connected = devices.filter { $0.isKnown && $0.isConnected }
        let remembered = devices.filter { $0.isKnown && !$0.isConnected }
        let nearby = devices.filter { !$0.isKnown }
        let rows = connected.map { d in
            BluetoothListRow(id: d.id, title: d.name, value: d.battery.map { "Connected \u{00B7} \($0)" } ?? "Connected",
                             kind: d.kind, action: .none)
        } + remembered.map { d in
            BluetoothListRow(id: d.id, title: d.name, value: "Connect", kind: d.kind, action: .connect)
        } + nearby.map { d in
            BluetoothListRow(id: d.id, title: d.name, value: "Pair", kind: d.kind, action: .pair)
        }
        return Array(rows.prefix(limit))
    }
}
