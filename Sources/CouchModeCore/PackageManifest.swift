// Owns: a reader package's manifest (`apps/<id>/manifest.json`): which service
// it reads, which reader API it speaks, the pages each action opens and the
// script function that says each page is ready, its time limits, and the
// hosts its addresses and images may use. Parsing is strict and bounded; an
// address a page template makes is built here and refused unless it is https
// on the service's own hosts. Pure: bytes in, values out (PackageStore loads
// the files).

import Foundation

public enum PackageError: Error, Equatable { case tooLarge, malformed(String), unsupportedAPI(Int), badID }

public struct PackageManifest: Equatable, Sendable {
    /// The reader API this app speaks: the function names and JSON shapes in agents/add-a-streaming-service.md.
    public static let supportedAPI = 1
    public static let maxBytes = 64 * 1024

    /// The site actions a package can open a page for, one per user action.
    public enum PageKind: String, CaseIterable, Sendable { case home, details, season, search, more, profile }

    public struct Page: Equatable, Sendable {
        /// An https address, or a template using {title.page}, {season.id} or {query}.
        public let open: String
        /// The name of the reader function that says the page is ready.
        public let ready: String
        /// False where never being ready is an answer (a search with no results).
        public let readyRequired: Bool
        public let readyTimeout: Duration?
        /// profile: how long to wait for the chosen profile to show.
        public let confirmTimeout: Duration?
        /// more: keep the page as it is when it is already this page.
        public let reuseIfOpen: Bool
    }

    public let id: String
    public let version: String
    public let siteHosts: [String]
    public let imageHosts: [String]
    public let loadTimeout: Duration
    public let readyTimeout: Duration
    public let readTimeout: Duration
    public let pages: [PageKind: Page]
    /// The reader defines `playerShown()`.
    public let definesPlayerShown: Bool

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> PackageManifest {
        guard data.count <= maxBytes else { throw PackageError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PackageError.malformed("not an object") }
        guard let id = root["id"] as? String, isID(id) else { throw PackageError.badID }
        guard let api = StreamJSON.int(root["readerAPI"]) else { throw PackageError.malformed("readerAPI") }
        guard api == supportedAPI else { throw PackageError.unsupportedAPI(api) }
        guard let version = StreamJSON.string(root["version"]), version.count <= 32 else { throw PackageError.malformed("version") }
        let site = root["site"] as? [String: Any] ?? [:]
        let hosts = hostList(site["hosts"])
        guard !hosts.isEmpty else { throw PackageError.malformed("site.hosts") }
        let timeouts = root["timeouts"] as? [String: Any] ?? [:]
        func seconds(_ key: String, _ fallback: Int) -> Duration { duration(timeouts[key]) ?? .seconds(fallback) }
        var pages: [PageKind: Page] = [:]
        let raw = root["pages"] as? [String: Any] ?? [:]
        for kind in PageKind.allCases {
            guard let entry = raw[kind.rawValue] as? [String: Any] else { continue }
            guard let open = entry["open"] as? String, validTemplate(open), let ready = entry["ready"] as? String, isFunctionName(ready) else {
                throw PackageError.malformed("pages.\(kind.rawValue)")
            }
            pages[kind] = Page(open: open, ready: ready, readyRequired: entry["readyRequired"] as? Bool ?? true,
                               readyTimeout: duration(entry["readyTimeout"]), confirmTimeout: duration(entry["confirmTimeout"]),
                               reuseIfOpen: entry["reuseIfOpen"] as? Bool ?? false)
        }
        guard pages[.home] != nil else { throw PackageError.malformed("pages.home") }
        return PackageManifest(id: id, version: version, siteHosts: hosts, imageHosts: hostList(site["imageHosts"]),
                               loadTimeout: seconds("load", 20), readyTimeout: seconds("ready", 10), readTimeout: seconds("read", 8),
                               pages: pages, definesPlayerShown: root["playerShown"] as? Bool ?? false)
    }

    private static let placeholders = ["{title.page}", "{season.id}", "{query}"]

    private static func isID(_ text: String) -> Bool {
        (1...32).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isFunctionName(_ text: String) -> Bool {
        (1...48).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && text.first?.isLetter == true
    }

    private static func hostList(_ value: Any?) -> [String] {
        guard let list = value as? [String], list.count <= 16 else { return [] }
        let hosts = list.map { $0.lowercased() }
        return hosts.allSatisfy { (3...100).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") } } ? hosts : []
    }

    /// Whole seconds between 1 and 60, as a Duration; nil for anything else.
    private static func duration(_ value: Any?) -> Duration? {
        guard let s = StreamJSON.int(value), (1...60).contains(s) else { return nil }
        return .seconds(s)
    }

    private static func validTemplate(_ text: String) -> Bool {
        guard text.count <= 512 else { return false }
        if text == "{title.page}" { return true }
        var rest = text
        for p in placeholders { rest = rest.replacingOccurrences(of: p, with: "") }
        return text.hasPrefix("https://") && !rest.contains("{") && !rest.contains("}") && !rest.contains(where: \.isWhitespace)
    }

    // MARK: Addresses

    public func hostAllowed(_ host: String?) -> Bool { Self.host(host, within: siteHosts) }

    static func host(_ host: String?, within allowed: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// What a page template needs filled in.
    public struct Fill: Sendable {
        public var titlePage: URL?
        public var seasonID: String?
        public var query: String?
        public init(titlePage: URL? = nil, seasonID: String? = nil, query: String? = nil) {
            self.titlePage = titlePage; self.seasonID = seasonID; self.query = query
        }
    }

    private static let queryAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// The page an action opens: its template filled in, https on the service's own hosts; nil when the
    /// page isn't offered, a value is missing or odd, or the result leaves the service's hosts.
    public func url(for kind: PageKind, _ fill: Fill = Fill()) -> URL? {
        guard let page = pages[kind] else { return nil }
        var text = page.open
        if text == "{title.page}" {
            guard let url = fill.titlePage else { return nil }
            text = url.absoluteString
        }
        if text.contains("{season.id}") {
            guard let id = fill.seasonID, (1...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            text = text.replacingOccurrences(of: "{season.id}", with: id)
        }
        if text.contains("{query}") {
            guard let query = fill.query.flatMap(StreamSearch.normalized),
                  let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) else { return nil }
            text = text.replacingOccurrences(of: "{query}", with: encoded)
        }
        guard let url = URL(string: text), url.scheme == "https", hostAllowed(url.host) else { return nil }
        return url
    }
}
