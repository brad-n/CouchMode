// Owns: the pure parts of opening a title in Plex HTPC with the app's own
// "open this title" navigation (the one its plex:// links end in), reached
// through its web inspector: Chrome's DevTools protocol, which Plex HTPC
// serves on 127.0.0.1 only when plex.ini's [debug] webInspectorPort is set.
// Why not a link: Plex HTPC hands every plex:// link to its web layer as a
// catalog ID, which it looks up in Plex's online catalog, and a movie there
// resolves to the catalog's page, not the library's copy (an episode does
// resolve to the library's show page). Given the library copy's own address,
// the same navigation opens that copy's page with Resume focused (seen on
// a real Mac, Plex HTPC 1.71.1). No I/O here; the app's PlexInspectorClient talks
// to Plex and PlexHTPC decides when.

import Foundation

public enum PlexInspector {
    /// The inspector's port (Chrome's own default is 9222; one up avoids it).
    public static let port = 9223
    static let inspectorKey = "webInspectorPort"
    /// Plex HTPC 1.71.1's module holding the app's service container; other
    /// versions are looked for by the container module's shape instead.
    static let knownContainerModule = "72861"
    /// How long the script waits for the app to say it got there.
    static let navigationTimeoutMs = 10_000

    /// What happened when the shell asked the app to open a title.
    public enum Outcome: Equatable, Sendable {
        /// The app opened it, on this screen (PreplayScreen, ShowTabbedScreen...).
        case opened(String)
        /// Nothing was asked of the app: the inspector or the app's internals
        /// weren't there (another Plex version?). Opening it another way is safe.
        case unavailable(String)
        /// The app was asked and didn't get there; don't press on with keys.
        case failed(String)
    }

    // MARK: the title's address

    /// The app's address for one title in one server's library.
    public static func sourceURI(machineIdentifier: String, ratingKey: String) -> String? {
        guard (1...64).contains(machineIdentifier.count), machineIdentifier.allSatisfy(isPlainIDCharacter),
              (1...12).contains(ratingKey.count), ratingKey.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"
    }

    private static func isPlainIDCharacter(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    // MARK: plex.ini

    /// plex.ini's text with the inspector on `port` (read when the app
    /// starts), or nil when it already is. Other lines are left as they are.
    public static func enablingInspector(in ini: String, port: Int = port) -> String? {
        let setting = "\(inspectorKey)=\(port)"
        var lines = ini.components(separatedBy: "\n")
        var inDebug = false
        var debugHeader: Int?
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inDebug = line == "[debug]"
                if inDebug && debugHeader == nil { debugHeader = i }
                continue
            }
            guard inDebug, line.hasPrefix(inspectorKey + "=") else { continue }
            if line == setting { return nil }
            lines[i] = setting
            return lines.joined(separator: "\n")
        }
        if let debugHeader {
            lines.insert(setting, at: debugHeader + 1)
            return lines.joined(separator: "\n")
        }
        if ini.isEmpty { return "[debug]\n\(setting)\n" }
        return (ini.hasSuffix("\n") ? ini : ini + "\n") + "\n[debug]\n\(setting)\n"
    }

    // MARK: the inspector's page list and messages

    /// The app's page socket from the inspector's /json list, on this Mac only.
    public static func pageSocket(fromTargets data: Data) -> URL? {
        guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let pages = targets.filter { $0["type"] as? String == "page" }
        let ordered = pages.filter { ($0["url"] as? String ?? "").contains("/web-client/") } + pages
        return ordered.lazy.compactMap { ($0["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) }
            .first { $0.scheme == "ws" && ($0.host == "127.0.0.1" || $0.host == "localhost") }
    }

    /// The DevTools request that runs `expression` and waits for its answer.
    public static func evaluateRequest(id: Int, expression: String) -> String {
        let message: [String: Any] = [
            "id": id, "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true, "returnByValue": true],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The script's report in the reply to request `id`; nil for any other
    /// message (the inspector also sends events).
    public static func outcome(fromReply text: String, id: Int) -> Outcome? {
        guard let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (reply["id"] as? NSNumber)?.intValue == id else { return nil }
        if let error = reply["error"] as? [String: Any] {
            return .unavailable("inspector error: \(error["message"] as? String ?? "unknown")")
        }
        let result = reply["result"] as? [String: Any] ?? [:]
        if let exception = result["exceptionDetails"] as? [String: Any] {
            // The script catches its own errors, so this is one that never ran.
            let detail = (exception["exception"] as? [String: Any])?["description"] as? String
            return .unavailable("script error: \(detail ?? exception["text"] as? String ?? "unknown")")
        }
        let value = (result["result"] as? [String: Any])?["value"] as? String ?? ""
        for (prefix, outcome) in [("opened: ", Outcome.opened), ("unavailable: ", Outcome.unavailable), ("failed: ", Outcome.failed)]
            where value.hasPrefix(prefix) {
            return outcome(String(value.dropFirst(prefix.count)))
        }
        return .failed("unexpected reply: \(value)")
    }

    // MARK: the script

    /// The script that asks the app to open `sourceURI` (from sourceURI(...))
    /// with its own deep-link navigation and reports "opened: <screen>",
    /// "unavailable: <why>" (nothing asked) or "failed: <why>".
    public static func openScript(sourceURI: String) -> String {
        let quoted = StreamJSON.jsString(sourceURI)
        return """
        (async () => {
          const source = \(quoted);
          let asked = false;
          try {
            // The app's modules, through webpack's own loader.
            const chunks = self.webpackChunk_plex_client_qt;
            if (!Array.isArray(chunks)) return "unavailable: no app bundle";
            let load = null;
            chunks.push([["htpc-shell-" + Date.now()], {}, r => { load = r; }]);
            if (typeof load !== "function") return "unavailable: no module loader";
            const controllerIn = id => {
              try {
                const container = load(id).Z;
                const app = container && typeof container.resolve === "function" ? container.resolve("appController") : null;
                return app && typeof app.processDeepLink === "function" && typeof app.on === "function" ? app : null;
              } catch (e) { return null; }
            };
            let app = controllerIn("\(knownContainerModule)");
            // Another Plex version: its container module is one line that makes the container.
            for (const id of app ? [] : Object.keys(load.m || {})) {
              const code = String(load.m[id]);
              if (code.length < 160 && code.includes("=new(") && code.includes(".W)") && (app = controllerIn(id))) break;
            }
            if (!app) return "unavailable: no app controller";
            const opened = new Promise(resolve => {
              const done = ok => { app.off("navigatedToDeepLink", onOpened); resolve(ok); };
              const onOpened = () => done(true);
              app.on("navigatedToDeepLink", onOpened);
              setTimeout(() => done(false), \(navigationTimeoutMs));
            });
            asked = true;
            await app.processDeepLink({ metadataSourceUri: source });
            const ok = await opened;
            const screen = (app._navigation && app._navigation.currentName) || "an unknown screen";
            return (ok ? "opened: " : "failed: still on ") + screen;
          } catch (e) {
            return (asked ? "failed: " : "unavailable: ") + String((e && e.message) || e);
          }
        })()
        """
    }
}
