// Owns: reading SwitchTV's catalog.json (written by TVPort's `backend.py
// switchtv build`: one entry per game with publisher, release date, players,
// genres, description and card/banner image paths) and the text the screens
// show from it. Mirrors switchtv/Shared/Catalog.swift. No disk access.

import Foundation

public struct CatalogGame: Codable, Equatable, Sendable {
    public let titleID: String
    public let name: String
    public let publisher: String?
    public let releaseDate: String?     // yyyy-MM-dd
    public let numberOfPlayers: Int?
    public let genres: [String]
    public let summary: String?
    public let intro: String?
    public let card: String             // image paths relative to the catalog folder
    public let banner: String
    public var screenshots: [String] = []   // https URLs (store screenshots)

    enum CodingKeys: String, CodingKey {
        case titleID, name, publisher, releaseDate, numberOfPlayers, genres, summary = "description", intro, card, banner, screenshots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleID = try c.decode(String.self, forKey: .titleID)
        name = try c.decode(String.self, forKey: .name)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        numberOfPlayers = try c.decodeIfPresent(Int.self, forKey: .numberOfPlayers)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        card = try c.decodeIfPresent(String.self, forKey: .card) ?? ""
        banner = try c.decodeIfPresent(String.self, forKey: .banner) ?? ""
        screenshots = (try c.decodeIfPresent([String].self, forKey: .screenshots) ?? []).filter { $0.hasPrefix("https://") }
    }

    /// The release date in words, e.g. "October 20, 2023".
    public var releaseText: String? {
        guard let releaseDate else { return nil }
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        parse.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parse.date(from: releaseDate) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    public var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4, releaseDate.prefix(4).allSatisfy(\.isNumber) else { return nil }
        return String(releaseDate.prefix(4))
    }

    public var playersText: String? {
        guard let n = numberOfPlayers, n > 0 else { return nil }
        return n == 1 ? "1 player" : "1-\(n) players"
    }

    /// Publisher • year • players, as under SwitchTV's title.
    public var metaText: String { [publisher, releaseYear, playersText].compactMap { $0 }.joined(separator: "  \u{2022}  ") }

    /// The shop's description (else its intro), without the store's footnote
    /// paragraph ("*This product can be upgraded…") at the top: when the
    /// text opens with "*", everything up to the first blank line goes.
    public var blurb: String? {
        guard let text = summary ?? intro else { return nil }
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first?.hasPrefix("*") == true {
            if let blank = lines.firstIndex(where: \.isEmpty) { lines.removeFirst(blank) } else { lines.removeAll() }
        }
        // A short section heading at the top ("- Story", "Features:") isn't prose.
        var body = Array(lines.drop(while: \.isEmpty))
        if let first = body.first, first.split(separator: " ").count <= 3,
           first.hasPrefix("-") || first.hasPrefix("•") || first.hasSuffix(":") {
            body.removeFirst()
        }
        let result = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

public struct SwitchCatalog: Codable, Sendable {
    public let games: [CatalogGame]

    public static func decode(_ data: Data) -> SwitchCatalog? { try? JSONDecoder().decode(SwitchCatalog.self, from: data) }

    public func game(_ titleID: String) -> CatalogGame? {
        games.first { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame }
    }
}

public enum GenreRows {
    /// Genres shared by at least two items, most items first then A-Z.
    /// `genres` maps each item to its genres.
    public static func build<T>(_ items: [T], genres: (T) -> [String]) -> [(genre: String, items: [T])] {
        var byGenre: [String: [T]] = [:]
        for item in items { for g in genres(item) { byGenre[g, default: []].append(item) } }
        return byGenre.filter { $0.value.count >= 2 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}
