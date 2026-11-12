// Owns: each streaming service's own art on this Mac: its tvOS app icon from
// Apple's public catalog (first choice) or else the icon its site declares,
// fetched over https, kept in Application Support, refreshed at most weekly.
// No art file ships with the app or the repo. Which art is chosen, and when a
// cached file is stale, are Core's TVArt, SiteIcons and IconCacheRule; the
// tile drawing is AppTileView's.

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
        static let lookup = TVArt.maxLookupBytes
        static let timeout: TimeInterval = 10
        /// The side, in pixels, of the copy an icon is analysed at.
        static let analysis = 256
        /// The side of the copy an icon's edge colors are sampled from.
        static let band = 64
    }

    private let log = Logger(subsystem: "local.brad.htpcshell", category: "icons")
    private var images: [String: NSImage] = [:]
    private var tileImages: [String: NSImage] = [:]
    private var edgeBands: [String: (top: RGB, bottom: RGB)] = [:]
    private var glyphs: [String: GlyphCrop] = [:]
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

    // ".site" marks icons chosen with the padded-manifest rule; older "<id>.png" files are not read.
    private func file(_ id: String) -> URL? { directory?.appendingPathComponent("\(id).site.png") }
    private func tileFile(_ id: String) -> URL? { directory?.appendingPathComponent("\(id).tv.jpg") }

    /// The service's tvOS landscape app icon, or nil (the tile falls back to its logo).
    func tileArt(for id: String) -> NSImage? {
        if DemoMode.isOn { return nil }
        if let hit = tileImages[id] { return hit }
        guard let url = tileFile(id), let image = NSImage(contentsOf: url), usableTile(image) else { return nil }
        tileImages[id] = image
        return image
    }

    /// The icon's own color along its top and bottom edges, the ends of the full-bleed background gradient.
    func edgeBand(for id: String) -> (top: RGB, bottom: RGB)? {
        if let hit = edgeBands[id] { return hit }
        guard let image = image(for: id), let band = Self.sampleBand(image) else { return nil }
        edgeBands[id] = band
        return band
    }

    /// The icon cropped to its glyph (its own padding, border and rounded-square frame removed), with a
    /// soft margin of background left around it for the tile to feather; `tight` is the glyph's own size in pixels.
    struct GlyphCrop {
        let image: NSImage
        let tight: CGSize
        /// The crop's size in real pixels (an NSImage's own representation can report double).
        let pixels: CGSize
    }

    /// Nil when there is nothing to trim; the tile then uses the whole icon.
    func glyph(for id: String) -> GlyphCrop? {
        if let hit = glyphs[id] { return hit }
        guard let image = image(for: id), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let (tight, margin) = Self.glyphRects(of: cg), let cropped = cg.cropping(to: margin) else { return nil }
        let out = GlyphCrop(image: NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)), tight: tight.size,
                            pixels: CGSize(width: cropped.width, height: cropped.height))
        glyphs[id] = out
        return out
    }

    /// The glyph's box, and that box plus a margin, in the image's own pixels. Found on a copy of at most
    /// `Limits.analysis` pixels a side.
    private static func glyphRects(of cg: CGImage) -> (tight: CGRect, margin: CGRect)? {
        let longest = max(cg.width, cg.height)
        guard longest > 0 else { return nil }
        let k = min(1, Double(Limits.analysis) / Double(longest))
        let w = max(1, Int((Double(cg.width) * k).rounded())), h = max(1, Int((Double(cg.height) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        guard let box = LogoTrim.glyphBounds(rgba: bytes, width: w, height: h) else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let sx = Double(cg.width) / Double(w), sy = Double(cg.height) / Double(h)
        // One analysis pixel each way so soft edges are not clipped.
        let tight = CGRect(x: Double(box.x - 1) * sx, y: Double(box.y - 1) * sy,
                           width: Double(box.w + 2) * sx, height: Double(box.h + 2) * sy).integral.intersection(full)
        guard !tight.isNull, tight.width > 0, tight.height > 0 else { return nil }
        let m = Double(TileLayout.glyphFeather) * min(tight.width, tight.height)
        return (tight, tight.insetBy(dx: -m, dy: -m).integral.intersection(full))
    }

    private static func sampleBand(_ image: NSImage) -> (top: RGB, bottom: RGB)? {
        let side = Limits.band
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data, count: side * side * 4))
        let rows = 3
        func band(_ y: Int) -> RGB? {
            EdgeColor.dominantSolid(rgba: bytes, width: side, height: side, region: PixelRect(x: 0, y: y, w: side, h: rows), border: 1)?.color
        }
        guard let top = band(0), let bottom = band(side - rows) else { return nil }
        return (top, bottom)
    }

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
        if isFresh(tileFile(service.id)), tileArt(for: service.id) != nil { return }
        if let appStoreId = AppConfigStore.shared.catalog.app(id: service.id)?.appStoreId, await refreshTileArt(service.id, appStoreId: appStoreId) { return }
        if isFresh(dest), image(for: service.id) != nil { return }
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
                return IconCandidate(href: abs, size: c.size, type: c.type, kind: c.kind, padded: c.padded)
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

    private func isFresh(_ url: URL?) -> Bool {
        guard let url else { return false }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return IconCacheRule.isFresh(fetchedAt: modified, now: Date())
    }

    /// Apple's catalog entry for the app, then its landscape tvOS art. False
    /// (logged once) when there is none, e.g. an app that ships inside tvOS.
    private func refreshTileArt(_ id: String, appStoreId: Int) async -> Bool {
        guard let lookupURL = TVArt.lookupURL(appStoreId: appStoreId), let dest = tileFile(id),
              let lookup = await get(lookupURL, limit: Limits.lookup),
              let artURL = TVArt.pickArtwork(fromLookup: lookup.data), let art = await get(artURL, limit: Limits.icon),
              TVArt.isAllowedArtURL(art.url), let image = NSImage(data: art.data), usableTile(image), let dir = directory else {
            log.info("icon: no tvOS art service=\(id, privacy: .public)")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try art.data.write(to: dest, options: .atomic)
        } catch {
            log.error("icon: could not save tvOS art service=\(id, privacy: .public)")
            return false
        }
        tileImages[id] = image
        objectWillChange.send()
        log.info("icon: saved tvOS art service=\(id, privacy: .public)")
        return true
    }

    private func usableTile(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first else { return false }
        return TVArt.isUsableTile(pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh)
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
