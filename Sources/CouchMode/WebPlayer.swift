// Owns: one Safari-engine web view per streaming service (kept alive so a
// service resumes where it was), and pressing real keys inside them.
// Logins persist in the app's default website data store.

import AppKit
import WebKit
import os
import CouchModeCore

@MainActor
final class WebPlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var views: [String: WKWebView] = [:]
    private(set) var activeService: Service?
    private let log = Logger(subsystem: "local.brad.htpcshell", category: "player")
    /// Called with the service id the first time its page finishes loading.
    var onFirstLoad: ((String) -> Void)?
    private var loaded: Set<String> = []
    func hasLoaded(_ service: Service) -> Bool { loaded.contains(service.id) }

    /// Called when the page asks for play/pause (Enter during playback).
    var onPlayPauseRequested: (() -> Void)?

    func view(for service: Service) -> WKWebView {
        if let v = views[service.id] { return v }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        // Sign-in buttons (e.g. "Continue with Google") open a pop-up window.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let content = config.userContentController
        content.add(WeakHandler(self), name: PageScripts.messageHandler)
        installScripts(for: service, in: content)
        let v = WKWebView(frame: .zero, configuration: config)
        v.customUserAgent = service.userAgent
        v.navigationDelegate = self
        v.uiDelegate = self
        v.load(URLRequest(url: service.url))
        views[service.id] = v
        log.info("created view service=\(service.id, privacy: .public)")
        return v
    }

    /// The scripts every page of a service gets. The media probe and the
    /// debug experiments are added only while the debug channel is on.
    private func installScripts(for service: Service, in content: WKUserContentController) {
        content.addUserScript(WKUserScript(source: PageScripts.hideGamepads, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if DebugFlags.isOn(.mediaprobe) {
            content.addUserScript(WKUserScript(source: MediaProbeScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if DebugServer.isEnabled {
            if service.id == "netflix", DebugFlags.isOn(.netflix51) {
                content.addUserScript(WKUserScript(source: MediaProbeScript.netflix51, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        if !service.hasTVInterface {
            content.addUserScript(WKUserScript(source: PageScripts.spatialNavigation(skip: service.navigationSkip),
                                                 injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if service.id == "plex" {
            content.addUserScript(WKUserScript(source: PageScripts.plexHelper, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    /// Debug only: re-installs a service's scripts after a debug flag changed, then reloads it.
    func reinstallDebugScripts(for service: Service) {
        guard let v = views[service.id] else { return }
        v.configuration.userContentController.removeAllUserScripts()
        installScripts(for: service, in: v.configuration.userContentController)
        v.reload()
    }

    func activate(_ service: Service) { activeService = service }

    /// Runs a script in a service's page (creating the view if needed).
    func evaluate(_ js: String, in service: Service, done: (@MainActor (Any?) -> Void)? = nil) {
        view(for: service).evaluateJavaScript(js) { value, _ in MainActor.assumeIsolated { done?(value) } }
    }

    /// Loads a specific page (e.g. a Plex title) in a service's view.
    func load(_ url: URL, in service: Service) { view(for: service).load(URLRequest(url: url)) }

    /// Reads one localStorage value (or, with a "js:" prefix, the string
    /// result of an expression) from a service's page, creating and
    /// loading that page off-screen if needed. Nil if absent or not loaded
    /// within the time limit.
    func readLocalStorage(_ key: String, in service: Service, timeout: TimeInterval = 15,
                          done: @escaping @MainActor (String?) -> Void) {
        let v = view(for: service)
        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            v.evaluateJavaScript(key.hasPrefix("js:") ? String(key.dropFirst(3)) : "localStorage.getItem(\(Self.jsString(key)))") { value, _ in
                MainActor.assumeIsolated {
                    if let s = value as? String, !s.isEmpty { return done(s) }
                    // The page may still be loading: retry once a second until the deadline.
                    guard Date() < deadline else { return done(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attempt() }
                }
            }
        }
        attempt()
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "''"
    }

    var activeView: WKWebView? { activeService.flatMap { views[$0.id] } }

    func deactivate() {
        guard let s = activeService, let v = views[s.id] else { return }
        v.evaluateJavaScript(PageScripts.pauseAllMedia)
        activeService = nil
    }

    /// Returns false when there is no earlier page (caller decides what then).
    func goBack() -> Bool {
        guard let s = activeService, let v = views[s.id], v.canGoBack else { return false }
        v.goBack()
        return true
    }

    func press(_ key: Key) {
        guard let s = activeService, let v = views[s.id], let window = v.window else { return }
        window.makeFirstResponder(v)
        let (code, chars) = KeyCodes.of(key)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(e)
        }
    }

    // MARK: Pop-up windows (sign-in)

    private var popups: [NSWindow] = []

    /// Shows a page's pop-up (window.open) in its own window above the shell.
    /// It shares the opener's configuration, so the sign-in result reaches the page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 720), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popup
        window.level = .floating            // above the full-screen shell window
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        log.info("opened pop-up for \(navigationAction.request.url?.host ?? "", privacy: .public)")
        return popup
    }

    /// The pop-up closed itself (sign-in finished): close its window, return focus.
    func webViewDidClose(_ webView: WKWebView) {
        guard let i = popups.firstIndex(where: { $0.contentView === webView }) else { return }
        let window = popups.remove(at: i)
        window.orderOut(nil)
        window.contentView = nil
        if let s = activeService, let v = views[s.id] { v.window?.makeKeyAndOrderFront(nil); v.window?.makeFirstResponder(v) }
    }

    // MARK: WKScriptMessageHandler / WKNavigationDelegate

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "playpause" { onPlayPauseRequested?() }
    }

    /// Last navigation milestone, for diagnosing pages that never appear.
    private(set) var lastNavigationEvent = ""

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { note("start \(w.url?.host ?? "")") }
    func webView(_ w: WKWebView, didReceiveServerRedirectForProvisionalNavigation n: WKNavigation!) { note("redirect \(w.url?.absoluteString ?? "")") }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { note("commit \(w.url?.absoluteString ?? "")") }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        note("finish \(w.url?.absoluteString ?? "")")
        if let id = views.first(where: { $0.value === w })?.key, !loaded.contains(id) {
            loaded.insert(id)
            onFirstLoad?(id)
        }
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { note("content process terminated"); w.reload() }

    private func note(_ event: String) {
        lastNavigationEvent = event
        log.notice("nav \(event, privacy: .public)")
    }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { logFailure(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { logFailure(e) }

    private func logFailure(_ e: Error) {
        // -999 = a navigation replaced by another one; normal on single-page sites.
        if (e as NSError).code == NSURLErrorCancelled { return }
        lastNavigationEvent = "fail \((e as NSError).domain) \((e as NSError).code): \(e.localizedDescription)"
        log.error("navigation failed: \(e.localizedDescription, privacy: .public)")
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

enum KeyCodes {
    // macOS virtual key codes (Carbon kVK_* values).
    static func of(_ key: Key) -> (UInt16, String) {
        switch key {
        case .left: return (123, scalar(NSLeftArrowFunctionKey))
        case .right: return (124, scalar(NSRightArrowFunctionKey))
        case .down: return (125, scalar(NSDownArrowFunctionKey))
        case .up: return (126, scalar(NSUpArrowFunctionKey))
        case .enter: return (36, "\r")
        case .space: return (49, " ")
        case .escape: return (53, "\u{1b}")
        }
    }
    private static func scalar(_ v: Int) -> String { String(Character(UnicodeScalar(v)!)) }
}
