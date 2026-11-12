// Owns: which of a game's catalog screenshots the details page may show:
// the usable addresses (secure, well-formed, no repeats, a bounded few) and,
// of those, the ones whose picture has actually arrived. The page draws only
// those, so a screenshot that never loads leaves no empty box and a game with
// none shows no pane at all. No loading here.

import Foundation

public enum GameScreenshots {
    public static let limit = 8

    /// The addresses worth trying, in catalog order.
    public static func usable(_ raw: [String], limit: Int = GameScreenshots.limit) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for text in raw {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                  seen.insert(url).inserted else { continue }
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }

    /// The usable addresses whose picture has loaded, in catalog order.
    public static func shown(_ urls: [URL], loaded: Set<URL>) -> [URL] {
        urls.filter { loaded.contains($0) }
    }
}
