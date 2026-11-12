// Owns: reading another app's on-screen interface through macOS
// Accessibility (the permission the remote already uses): a bounded
// snapshot of its element tree, and pressing one of its elements. Nothing
// here knows what any app's interface means; callers do.

import AppKit
import ApplicationServices

/// One element of another app's interface, as Accessibility reports it.
struct AXNode {
    let element: AXUIElement
    let role: String
    let subrole: String?
    let title: String?
    /// AXDescription: the label a button or image speaks.
    let label: String?
    let value: String?
    let identifier: String?
    let actions: [String]
    let children: [AXNode]

    /// Every node below this one, depth first (this one included).
    var all: [AXNode] { [self] + children.flatMap(\.all) }

    /// The text a person sees for it: title, else label, else value.
    var text: String { [title, label, value].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
}

@MainActor
enum AccessibilityTree {
    private enum Limits {
        static let maxNodes = 3000
        static let maxDepth = 40
        static let messagingTimeout: Float = 1.0   // seconds per Accessibility call
    }

    /// A snapshot of the app's windows, bounded in size and depth; nil when
    /// the permission is missing or the app isn't running.
    static func snapshot(pid: pid_t) -> AXNode? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Limits.messagingTimeout)
        var budget = Limits.maxNodes
        return node(app, depth: 0, budget: &budget)
    }

    /// Presses the element (a button's click) the way assistive tech does.
    @discardableResult
    static func press(_ node: AXNode) -> Bool {
        AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success
    }

    /// Where the element is on screen, in global display coordinates (origin
    /// at the top left of the main display, as CGEvent uses).
    static func frame(of node: AXNode) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node.element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(node.element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Moves and sizes a window (global display coordinates, top left).
    @discardableResult
    static func setFrame(of window: AXNode, to frame: CGRect) -> Bool {
        var origin = frame.origin, size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let ext = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, pos)
        let sized = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, ext)
        return moved == .success && sized == .success
    }

    /// An indented text listing, for the debug channel.
    static func listing(_ root: AXNode) -> String {
        var lines: [String] = []
        func walk(_ n: AXNode, _ depth: Int) {
            var line = String(repeating: "  ", count: depth) + n.role
            if let s = n.subrole { line += "/" + s }
            for (k, v) in [("title", n.title), ("label", n.label), ("value", n.value), ("id", n.identifier)] {
                if let v, !v.isEmpty { line += " \(k)=\"\(v.prefix(60))\"" }
            }
            let acts = n.actions.filter { $0 != "AXScrollToVisible" }
            if !acts.isEmpty { line += " [" + acts.joined(separator: ",") + "]" }
            lines.append(line)
            n.children.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        return lines.joined(separator: "\n")
    }

    private static func node(_ el: AXUIElement, depth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        var kids: [AXNode] = []
        if depth < Limits.maxDepth, budget > 0 {
            for child in elements(el, kAXChildrenAttribute) {
                guard budget > 0 else { break }
                kids.append(node(child, depth: depth + 1, budget: &budget))
            }
        }
        var names: CFArray?
        let actions = AXUIElementCopyActionNames(el, &names) == .success ? (names as? [String] ?? []) : []
        return AXNode(element: el, role: string(el, kAXRoleAttribute) ?? "?", subrole: string(el, kAXSubroleAttribute),
                      title: string(el, kAXTitleAttribute), label: string(el, kAXDescriptionAttribute),
                      value: string(el, kAXValueAttribute), identifier: string(el, kAXIdentifierAttribute),
                      actions: actions, children: kids)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }
}
