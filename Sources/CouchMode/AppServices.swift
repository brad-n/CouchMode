// Owns: the service list this app instance uses: the services in this Mac's
// config (AppConfigStore) with the Safari identity of the Safari actually
// installed (the system WebKit), read once at launch. Falls back to the core
// constant when it can't be read.

import Foundation
import os
import CouchModeCore

@MainActor
enum AppServices {
    private static let safariInfoPlist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
    private static let maxPlistBytes = 256 * 1024
    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "services")

    /// The Safari user agent for services that identify as Safari.
    static let safariUserAgent: String = {
        var version: String?
        if let handle = try? FileHandle(forReadingFrom: safariInfoPlist) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: maxPlistBytes) { version = SafariUserAgent.version(fromInfoPlist: data) }
        }
        let ua = SafariUserAgent.string(forVersion: version)
        if ua == UserAgents.safari { log.error("safari version unreadable, using fallback user agent") }
        else { log.info("safari user agent from installed version \(version ?? "", privacy: .public)") }
        return ua
    }()

    /// The streaming sites and native apps this Mac has added (and can show), in config order.
    static var all: [Service] { AppConfigStore.shared.services }
}
