// Owns: loading remote artwork (Plex posters) with a bounded in-memory cache.

import AppKit
import SwiftUI
import CouchModeCore

@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()
    private static let maxEntries = 120
    private var images: [URL: NSImage] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: [(NSImage?) -> Void]] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    func cached(_ url: URL) -> NSImage? { images[url] ?? DemoArtRenderer.image(for: url) }

    func load(_ url: URL, done: @escaping (NSImage?) -> Void) {
        if let hit = images[url] { return done(hit) }
        // Demo mode's generated art is drawn here, never fetched.
        if url.scheme == DemoArtSpec.scheme { return done(DemoArtRenderer.image(for: url)) }
        if inFlight[url] != nil { inFlight[url]?.append(done); return }
        inFlight[url] = [done]
        Task {
            let image = await fetch(url)
            if let image { store(url, image) }
            inFlight.removeValue(forKey: url)?.forEach { $0(image) }
        }
    }

    /// One fetch, retrying transient failures (ImageRetry decides); the
    /// waiters hear only the final result.
    private func fetch(_ url: URL) async -> NSImage? {
        var attempt = 0
        while true {
            var status: Int?
            var errorCode: Int?
            do {
                let (data, response) = try await session.data(from: url)
                status = (response as? HTTPURLResponse)?.statusCode
                if status.map({ (200..<300).contains($0) }) ?? true { return NSImage(data: data) }
            } catch {
                errorCode = (error as? URLError)?.code.rawValue
            }
            guard let wait = ImageRetry.delay(status: status, urlErrorCode: errorCode, attempt: attempt) else { return nil }
            try? await Task.sleep(for: wait)
            attempt += 1
        }
    }

    private func store(_ url: URL, _ image: NSImage) {
        images[url] = image
        order.append(url)
        if order.count > Self.maxEntries { images.removeValue(forKey: order.removeFirst()) }
    }
}

/// Shows a remote image, filling its frame; nothing until it arrives. With
/// `cover`, it is scaled to cover exactly that size (for full-screen art).
struct RemoteImage: View {
    let url: URL
    var cover: CGSize? = nil
    @State private var image: NSImage?
    /// The address `image` came from: a new one crossfades in.
    @State private var shownURL: URL?
    private static let crossfade = Animation.easeInOut(duration: 0.35)

    var body: some View {
        Group {
            if let image, let cover { CoverImage(image: image, size: cover).id(shownURL).transition(.opacity) }
            else if let image { Image(nsImage: image).resizable().scaledToFill().id(shownURL).transition(.opacity) }
            else { Color.clear }
        }
        // Loads again whenever the address changes (a backdrop following the
        // focused title), keeping the current picture until the new one arrives;
        // an answer for an address the view has since moved past is dropped.
        .task(id: url) {
            let wanted = url
            let loaded: NSImage?
            if let hit = RemoteImageCache.shared.cached(wanted) {
                loaded = hit
            } else {
                loaded = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
                    RemoteImageCache.shared.load(wanted) { done.resume(returning: $0) }
                }
            }
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(Self.crossfade) {
                image = loaded
                shownURL = wanted
            }
        }
    }
}
