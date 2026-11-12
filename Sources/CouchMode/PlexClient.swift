// Owns: talking to Plex for the Continue Watching row. Its token comes from
// Plex Web's own sign-in inside the shell (read from that page's local
// storage) and is kept in this Mac's Keychain; it never leaves the machine
// except in requests to Plex itself. Never logged.

import Foundation
import Security
import os
import CouchModeCore

/// One Continue Watching item with its card art, full-screen art and links.
struct ContinueEntry {
    let item: ContinueItem
    let image: URL?
    let backdrop: URL?
    let details: URL?
    /// Plex HTPC's address for the library copy (PlexInspector.sourceURI).
    let source: String?
}

@MainActor
final class PlexClient {
    private enum Limits {
        static let requestTimeout: TimeInterval = 10
        static let maxItems = 20
    }
    private static let keychainService = "local.brad.htpcshell.plex"
    private static let clientIdentifier = "htpc-shell-" + (Host.current().localizedName ?? "mac")

    private let log = Logger(subsystem: "local.brad.htpcshell", category: "plex")
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Limits.requestTimeout
        c.timeoutIntervalForResource = Limits.requestTimeout * 2
        return URLSession(configuration: c)
    }()
    private(set) var servers: [PlexServer] = []
    /// The token that reaches the servers (its Plex Home profile is the one
    /// Plex Web should use).
    private(set) var workingToken: String?
    /// Where the last refresh got to, for diagnostics. Never contains a token.
    private(set) var status = "not started"

    /// Asks the page for Plex Web's sign-in tokens as a JSON array string;
    /// installed by the coordinator.
    var tokenFromPlexWeb: ((@escaping @MainActor (String?) -> Void) -> Void)?

    /// Continue Watching from every reachable server, merged (most recent
    /// first), each with its image and Plex Web URL. Empty when signed out.
    func continueWatching() async -> [ContinueEntry] {
        if servers.isEmpty { servers = await connect() }
        var lists: [[(ContinueItem, ContinueEntry)]] = []
        var notes: [String] = []
        for server in servers {
            for path in ["hubs/continueWatching", "library/onDeck"] {
                guard let data = await get(server.baseURL.appendingPathComponent(path), token: server.accessToken) else { continue }
                let items = PlexParsing.continueItems(from: data, limit: Limits.maxItems)
                // Older servers fill On Deck but not the continueWatching hub.
                if items.isEmpty && path == "hubs/continueWatching" { continue }
                notes.append("\(server.name): \(items.count)")
                lists.append(items.map { item in
                    (item, ContinueEntry(
                        item: item,
                        image: item.imagePath.flatMap { PlexParsing.imageURL(server: server, path: $0, width: 800, height: 450) },
                        backdrop: item.backdropPath.flatMap { PlexParsing.imageURL(server: server, path: $0, width: 1920, height: 1080) },
                        details: PlexParsing.webDetailsURL(server: server, ratingKey: item.ratingKey),
                        source: PlexInspector.sourceURI(machineIdentifier: server.machineIdentifier, ratingKey: item.ratingKey)))
                })
                break
            }
        }
        if !servers.isEmpty { status = "continue watching from " + notes.joined(separator: ", ") }
        return PlexParsing.merged(lists, limit: Limits.maxItems).map(\.1)
    }

    // MARK: token

    /// Finds a server with the saved token, else tries every token Plex Web
    /// holds (account + Plex Home users) and saves the first that works.
    private func connect() async -> [PlexServer] {
        if let saved = Self.readKeychain() {
            let found = await findServers(token: saved)
            if !found.isEmpty { workingToken = saved; return found }
        }
        guard let ask = tokenFromPlexWeb else { status = "no token source"; return [] }
        let raw: String? = await withCheckedContinuation { cont in ask { cont.resume(returning: $0) } }
        let tokens = raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
        guard !tokens.isEmpty else { status = "no token (sign in on the Plex tile)"; return [] }
        var tried: [String] = []
        for (i, t) in Set(tokens).sorted().enumerated() {
            let found = await findServers(token: t)
            if !found.isEmpty { Self.writeKeychain(t); workingToken = t; return found }
            tried.append("user\(i + 1): \(status)")
        }
        status = "no server for \(tokens.count) signed-in users [\(tried.joined(separator: " | "))]"
        return []
    }

    /// Every server on the account that answers from this Mac.
    private func findServers(token: String) async -> [PlexServer] {
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1"),
              let data = await get(url, token: token) else { return [] }
        let all = PlexParsing.servers(fromResources: data)
        var reachable: [PlexServer] = []
        var notes: [String] = []
        for found in all.prefix(6) {
            if let r = await firstReachable(found) { reachable.append(r) }
            else { notes.append("\(found.name): none of \(found.candidateURLs.count) answered") }
        }
        if reachable.isEmpty { status = all.isEmpty ? "resources: 0 servers" : notes.joined(separator: ", ") }
        return reachable
    }

    /// Probes the server's addresses in order (short timeout each) and
    /// returns the server pointed at the first that answers /identity.
    private func firstReachable(_ server: PlexServer) async -> PlexServer? {
        for url in server.candidateURLs.prefix(6) {
            var req = URLRequest(url: url.appendingPathComponent("identity"), timeoutInterval: 4)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (_, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                return server.using(url)
            }
        }
        return nil
    }

    private func get(_ url: URL, token: String) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue("CouchMode", forHTTPHeaderField: "X-Plex-Product")
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { Self.deleteKeychain(); servers = [] }   // token revoked: sign in again
            guard (200..<300).contains(status) else {
                log.error("Plex \(url.path, privacy: .public) -> \(status)")
                self.status = "\(url.host ?? "")\(url.path) -> HTTP \(status)"
                return nil
            }
            return data
        } catch {
            log.error("Plex \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.status = "\(url.host ?? "")\(url.path) failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Keychain

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "plex-token"]
    }

    private static func readKeychain() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func writeKeychain(_ token: String) {
        deleteKeychain()
        var q = query()
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func deleteKeychain() { SecItemDelete(query() as CFDictionary) }
}
