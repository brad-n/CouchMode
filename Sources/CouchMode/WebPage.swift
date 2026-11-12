// Owns: driving one service's page for a reader (a StreamSource), as the
// proxy behind the shell's own streaming screens: open an address and wait
// for it to load, wait for something to show up, run a script and await its
// answer. Every wait is bounded. It works on the service's own web view (the
// same one its player uses), whether or not that view is on screen. What to
// open and what to read is each reader's business.

import WebKit

@MainActor
enum WebPage {
    private enum Limits {
        static let poll: Duration = .milliseconds(250)
        static let script: Duration = .seconds(5)
    }

    /// Loads `url` and waits until the page has finished loading. (Keeping a
    /// backstage page's media quiet is the coordinator's job, tied to the
    /// page being backstage: a reader call finishing late must never quiet a
    /// page the player has since taken over.)
    static func open(_ url: URL, in view: WKWebView, timeout: Duration) async -> Bool {
        view.load(URLRequest(url: url))
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // isLoading turns on just after load(); give it a moment before trusting it.
        try? await Task.sleep(for: Limits.poll)
        while clock.now < deadline, !Task.isCancelled {
            if !view.isLoading { return true }
            try? await Task.sleep(for: Limits.poll)
        }
        return false
    }

    /// Runs a function body (callAsyncJavaScript, so it may `return` and
    /// `await`) in the page; its answer, or nil on error or timeout.
    static func run(_ body: String, in view: WKWebView, timeout: Duration = Limits.script) async -> Any? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            let finish: @MainActor (Any?) -> Void = { value in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                MainActor.assumeIsolated { finish(try? result.get()) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    /// The script's answer when it's a string (e.g. JSON a reader parses).
    static func text(_ body: String, in view: WKWebView, timeout: Duration = Limits.script) async -> String? {
        await run(body, in: view, timeout: timeout) as? String
    }

    /// Waits until `readyBody` (a function body returning a boolean) says
    /// yes, or the time runs out.
    static func waitFor(_ readyBody: String, in view: WKWebView, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !Task.isCancelled {
            if (await run(readyBody, in: view) as? Bool) == true { return true }
            try? await Task.sleep(for: Limits.poll)
        }
        return false
    }

    /// Resumes a continuation at most once (a script's answer or its timeout, whichever comes first).
    private final class Once { var done = false }
}
