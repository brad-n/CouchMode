// Owns: an OPT-IN remote-control channel for development, so the shell can be
// driven and inspected over SSH without someone at the screen.
//  - Opt-in: off unless `defaults write local.brad.htpcshell DebugControl -bool true`.
//  - Listens on 127.0.0.1 only; reach it with `ssh <host> curl ...`.
//  - Requests are bounded (size + time).
// Endpoints (HTTP/1.0, one request per connection):
//   GET  /state                     -> JSON: screen, service, url, focused card
//   GET  /intent?i=up|down|left|right|select|back|home|info
//   GET  /homehold                  -> same as holding the controller's Menu button
//   GET  /accessibility             -> request the Accessibility permission (remote in other apps)
//   GET  /inject?key=up|down|left|right|return|esc|space -> type a key into the app in front
//   GET  /open?service=<id>         -> open a service directly
//   GET  /stream?service=<id>&sample=1 -> the shell's own stream screens on built-in sample data
//   GET  /snapshot                 -> PNG of what the shell is drawing
//   GET  /screen                    -> PNG of the real screen (needs Screen Recording permission)
//   POST /eval  (body = JS function body; use `return`) -> JSON result
//   POST /peek?service=<id> (body = JS function body) -> JSON result, in that
//        service's own page even behind a stream screen (for building readers)

import AppKit
import CoreGraphics
import Foundation
import Network
import os
import CouchModeCore

@MainActor
protocol DebugControllable: AnyObject {
    func debugState() -> [String: String]
    func handle(_ intent: ShellIntent)
    func homeRequested(_ source: HomeSource)
    func debugPlay(consoleId: String, fileName: String) -> Bool
    func debugHID() -> String
    func debugPlexLink(_ link: URL, _ done: @escaping @MainActor (String) -> Void)
    func showScreensaver()
    func debugOpen(serviceId: String) -> Bool
    func debugStream(serviceId: String) -> Bool
    func debugSnapshot(_ done: @escaping @MainActor (Data?) -> Void)
    var displayID: CGDirectDisplayID? { get }
    func debugEval(_ js: String, _ done: @escaping @MainActor (String) -> Void)
    func debugPeek(serviceId: String, _ js: String, _ done: @escaping @MainActor (String) -> Void)
    func debugMedia(serviceId: String, suspend: Bool?, _ done: @escaping @MainActor (String) -> Void)
}

@MainActor
final class DebugServer {
    static let defaultsKey = "DebugControl"
    private enum Limits {
        static let port: NWEndpoint.Port = 47800
        static let maxRequestBytes = 256 * 1024
        static let requestTimeout: TimeInterval = 20
    }

    private var listener: NWListener?
    private weak var target: DebugControllable?
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "debug")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    func start(target: DebugControllable) {
        self.target = target
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Limits.port)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            l.start(queue: .main)
            listener = l
            log.info("debug control listening on 127.0.0.1:\(Limits.port.rawValue)")
        } catch {
            log.error("debug control failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + Limits.requestTimeout) { conn.cancel() }
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if buf.count > Limits.maxRequestBytes { return self.reply(conn, 413, "too large") }
                if let req = HTTPRequest(buf) { return self.route(req, conn) }
                if isComplete || error != nil { return self.reply(conn, 400, "bad request") }
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let target else { return reply(conn, 503, "no target") }
        switch (req.method, req.path) {
        case ("GET", "/state"):
            replyJSON(conn, target.debugState())
        case ("GET", "/screensaver"):
            target.showScreensaver()
            replyJSON(conn, target.debugState())
        case ("GET", "/accessibility"):
            // Shows macOS's Accessibility prompt; reports whether it's granted.
            replyJSON(conn, ["allowed": "\(KeyInjector.requestPermission())"])
        case ("GET", "/inject"):
            // Types a key into the app in front, as the remote would.
            let keys: [String: Key] = ["up": .up, "down": .down, "left": .left, "right": .right,
                                       "return": .enter, "esc": .escape, "space": .space]
            guard let key = keys[req.query["key"] ?? ""] else { return reply(conn, 400, "unknown key") }
            KeyInjector.press(key)
            replyJSON(conn, ["allowed": "\(KeyInjector.isAllowed)"])
        case ("GET", "/ax"):
            // Another app's interface as Accessibility sees it (bounded), to
            // learn its layout: /ax?bundle=com.apple.systempreferences
            guard let id = req.query["bundle"],
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                return reply(conn, 404, "app not running")
            }
            guard let root = AccessibilityTree.snapshot(pid: app.processIdentifier) else {
                return reply(conn, 403, "Accessibility permission needed")
            }
            send(conn, 200, "text/plain; charset=utf-8", Data(AccessibilityTree.listing(root).utf8))
        case ("GET", "/bt"):
            // The shell's view of the Bluetooth page: do=open | scan | menu (read
            // a device's context menu, then dismiss it; nothing is pressed).
            let bt = BluetoothSettings()
            switch req.query["do"] ?? "scan" {
            case "open":
                bt.open()
                replyJSON(conn, ["opened": "true"])
            case "menu":
                guard let name = req.query["name"], let device = bt.devices().first(where: { $0.name == name }) else {
                    return reply(conn, 404, "no such device on the page")
                }
                Task { @MainActor [weak self] in
                    let titles = await bt.menuTitles(for: device)
                    self?.replyJSON(conn, ["menu": titles.joined(separator: " | ")])
                }
            case "hover":
                // A nearby device's row under the pointer: which buttons appear (none pressed).
                guard let name = req.query["name"], let device = bt.devices().first(where: { $0.name == name }) else {
                    return reply(conn, 404, "no such device on the page")
                }
                Task { @MainActor [weak self] in
                    let titles = await bt.hoverButtons(for: device)
                    self?.replyJSON(conn, ["buttons": titles.joined(separator: " | ")])
                }
            default:
                let list = bt.devices().map { "\($0.isKnown ? "known" : "nearby") \($0.isConnected ? "connected" : "-") \($0.kind) \($0.name)" }
                send(conn, 200, "text/plain; charset=utf-8", Data(list.joined(separator: "\n").utf8))
            }
        case ("GET", "/plexlink"):
            // Open a title in the running Plex HTPC by its Plex ID (e.g. plex://episode/...), then fix its window.
            guard let id = req.query["id"], id.hasPrefix("plex://"), let link = URL(string: id) else { return reply(conn, 400, "id=plex://...") }
            target.debugPlexLink(link) { [weak self] report in self?.replyJSON(conn, ["result": report]) }
        case ("GET", "/hid"):
            // Raw HID pads and their last presses (usage numbers), to check a layout.
            send(conn, 200, "text/plain; charset=utf-8", Data(target.debugHID().utf8))
        case ("GET", "/homehold"):
            // source=remote (default: TV button, ⌘⌫), controller (Home button) or menu (Menu held).
            guard let source = HomeSource(rawValue: req.query["source"] ?? "remote") else { return reply(conn, 400, "unknown source") }
            target.homeRequested(source)
            replyJSON(conn, target.debugState())
        case ("GET", "/play"):
            guard target.debugPlay(consoleId: req.query["console"] ?? "", fileName: req.query["game"] ?? "") else {
                return reply(conn, 404, "unknown console or game")
            }
            replyJSON(conn, target.debugState())
        case ("GET", "/intent"):
            guard let intent = Self.intent(req.query["i"] ?? "") else { return reply(conn, 400, "unknown intent") }
            target.handle(intent)
            replyJSON(conn, target.debugState())
        case ("GET", "/open"):
            guard target.debugOpen(serviceId: req.query["service"] ?? "") else { return reply(conn, 404, "unknown service") }
            replyJSON(conn, target.debugState())
        case ("GET", "/stream"):
            guard req.query["sample"] == "1" else { return reply(conn, 400, "sample=1 required") }
            guard target.debugStream(serviceId: req.query["service"] ?? "") else { return reply(conn, 404, "unknown service") }
            replyJSON(conn, target.debugState())
        case ("GET", "/screen"):
            // The real screen (any app in front). Needs Screen Recording permission.
            guard ScreenCapture.ensurePermission() else {
                return reply(conn, 403, "Screen Recording permission needed: allow CouchMode in System Settings > Privacy & Security > Screen Recording")
            }
            let display = target.displayID
            Task { @MainActor [weak self] in
                do {
                    let png = try await ScreenCapture.png(displayID: display)
                    self?.send(conn, 200, "image/png", png)
                } catch {
                    self?.reply(conn, 500, "capture failed: \(error)")
                }
            }
        case ("GET", "/snapshot"):
            target.debugSnapshot { [weak self] png in
                guard let png else { self?.reply(conn, 500, "snapshot failed"); return }
                self?.send(conn, 200, "image/png", png)
            }
        case ("POST", "/eval"):
            target.debugEval(String(decoding: req.body, as: UTF8.self)) { [weak self] result in
                self?.send(conn, 200, "application/json", Data(result.utf8))
            }
        case ("GET", "/media"):
            // WebKit's media state for a service's page; suspend=1|0 changes it first.
            let suspend = req.query["suspend"].map { $0 == "1" }
            target.debugMedia(serviceId: req.query["service"] ?? "", suspend: suspend) { [weak self] state in
                self?.replyJSON(conn, ["media": state])
            }
        case ("POST", "/peek"):
            // A service's own page even while a stream screen covers it (its reader's view).
            target.debugPeek(serviceId: req.query["service"] ?? "", String(decoding: req.body, as: UTF8.self)) { [weak self] result in
                self?.send(conn, 200, "application/json", Data(result.utf8))
            }
        default:
            reply(conn, 404, "not found")
        }
    }

    private static func intent(_ s: String) -> ShellIntent? {
        switch s {
        case "up": return .move(.up)
        case "down": return .move(.down)
        case "left": return .move(.left)
        case "right": return .move(.right)
        case "select": return .select
        case "back": return .back
        case "home": return .home
        case "info": return .info
        default: return nil
        }
    }

    private func replyJSON(_ conn: NWConnection, _ obj: [String: String]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        send(conn, 200, "application/json", data)
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ text: String) {
        send(conn, status, "text/plain", Data((text + "\n").utf8))
    }

    private func send(_ conn: NWConnection, _ status: Int, _ type: String, _ body: Data) {
        var head = "HTTP/1.0 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 200 { head = head.replacingOccurrences(of: " X\r\n", with: " OK\r\n") }
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

