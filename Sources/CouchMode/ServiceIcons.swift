// Owns: each streaming service's own icon on this Mac: reading the icon the
// service's site declares, fetching it once over https, keeping it in
// Application Support, and refreshing it at most weekly. No icon file ships
// with the app or the repo. Which icon is chosen, and when a cached one is
// stale, are Core's SiteIcons and IconCacheRule; the tile drawing is HomeView's.

import AppKit
import SwiftUI
import CouchModeCore
import os

@MainActor
final class ServiceIcons: ObservableObject {
    static let shared = ServiceIcons()

    private enum Limits {
        static let page = 4_000_000
        static let manifest = 300_000
        static let icon = 4_000_000
        static let timeout: TimeInterval = 10
    }

    private let log = Logger(subsystem: "local.brad.htpcshell", category: "icons")
    private var images: [String: NSImage] = [:]
    private var attempted: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Limits.timeout
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    private var directory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let id = Bundle.main.bundleIdentifier ?? "local.brad.htpcshell"
        return support.appendingPathComponent(id).appendingPathComponent("icons")
    }

    private func file(_ id: String) -> URL? { directory?.appendingPathComponent("\(id).png") }

    /// The cached icon for a service, or nil (the tile keeps its symbol).
    func image(for id: String) -> NSImage? {
        if DemoMode.isOn { return nil }
        if let hit = images[id] { return hit }
        guard let url = file(id), let image = NSImage(contentsOf: url), usable(image) else { return nil }
        images[id] = image
        return image
    }

    /// Fetches the icons that are missing or older than a week: one service at
    /// a time, each at most once per launch.
    func refreshIfNeeded(_ services: [Service]) {
        guard !DemoMode.isOn else { return }
        Task { [weak self] in
            for s in services { await self?.refresh(s) }
        }
    }

    private func refresh(_ service: Service) async {
        guard !attempted.contains(service.id), let dest = file(service.id) else { return }
        attempted.insert(service.id)
        let modified = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate]) as? Date
        if IconCacheRule.isFresh(fetchedAt: modified, now: Date()), image(for: service.id) != nil { return }
        guard var parts = URLComponents(url: service.url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        guard let start = parts.url, start.scheme == "https", let fetched = await get(start, limit: Limits.page) else {
            return log.info("icon: home page unavailable service=\(service.id, privacy: .public)")
        }
        let home = fetched.url
        let page = SiteIcons.parsePage(String(decoding: fetched.data, as: UTF8.self))
        var candidates = page.icons
        if SiteIcons.best(candidates, relativeTo: home) == nil || candidates.allSatisfy({ ($0.size ?? 0) < 512 }),
           let href = page.manifest, let manifestURL = URL(string: href, relativeTo: home)?.absoluteURL, manifestURL.scheme == "https",
           let manifest = await get(manifestURL, limit: Limits.manifest) {
            candidates += SiteIcons.parseManifest(manifest.data).map { c in
                // A manifest's own relative addresses are relative to the manifest.
                guard let abs = URL(string: c.href, relativeTo: manifestURL)?.absoluteString else { return c }
                return IconCandidate(href: abs, size: c.size, type: c.type, kind: c.kind)
            }
        }
        guard let iconURL = SiteIcons.best(candidates, relativeTo: home), let icon = await get(iconURL, limit: Limits.icon),
              let image = NSImage(data: icon.data), usable(image) else {
            return log.info("icon: none usable service=\(service.id, privacy: .public)")
        }
        guard let dir = directory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try icon.data.write(to: dest, options: .atomic)
        } catch {
            return log.error("icon: could not save service=\(service.id, privacy: .public)")
        }
        images[service.id] = image
        objectWillChange.send()
        log.info("icon: saved service=\(service.id, privacy: .public)")
    }

    private func usable(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first else { return false }
        return SiteIcons.isUsable(pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh)
    }

    /// One GET with a browser identity, refused if larger than `limit`; nil on
    /// any failure. Gives the final address too (a service may redirect to its
    /// own other domain), which relative links are read against.
    private func get(_ url: URL, limit: Int) async -> (data: Data, url: URL)? {
        var request = URLRequest(url: url)
        request.setValue(UserAgents.safari, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= limit else { return nil }
        return (data, http.url ?? url)
    }
}
