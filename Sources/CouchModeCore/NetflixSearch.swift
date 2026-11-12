// Owns: reading Netflix's own search page for the shell's search screen, as
// a proxy: the page address for a query, the script that lists the page's
// result cards, and turning its answer into titles. Learned on a real Mac
// (2026-11-11): netflix.com/search?q=<query> draws each result as a link
// (data-uia="standard-card") whose "jbv" parameter is the title's id, whose
// aria-label is its name, with its tile image inside. No I/O here.

import Foundation

public enum NetflixSearch {
    /// The search page for a query (tidied by StreamSearch.normalized); nil when empty.
    public static func pageURL(query: String) -> URL? {
        guard let text = StreamSearch.normalized(query) else { return nil }
        var c = URLComponents(string: "https://www.netflix.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: text)]
        return c?.url
    }

    /// Function body for WKWebView.callAsyncJavaScript: true once the page
    /// shows result cards.
    public static let readyScript = #"return document.querySelectorAll('[data-uia="standard-card"]').length > 0;"#

    /// Function body for WKWebView.callAsyncJavaScript: the page's result
    /// cards as a JSON string, [{id, name, art}], at most maxSearchResults.
    public static let resultsScript = """
    const cards = Array.from(document.querySelectorAll('[data-uia="standard-card"]')).slice(0, \(StreamLimits.maxSearchResults));
    return JSON.stringify(cards.map(card => {
      const match = (card.getAttribute('href') || '').match(/[?&]jbv=([0-9]+)/);
      const image = card.querySelector('img');
      return { id: match ? match[1] : null, name: card.getAttribute('aria-label') || '', art: image ? image.getAttribute('src') : null };
    }));
    """

    /// Titles from resultsScript's answer: only cards with a numeric id and a
    /// name, each once, art only when it's https, at most maxSearchResults.
    /// `play`/`page` give the service's addresses for an id.
    public static func titles(fromResults json: String, play: (String) -> URL?, page: (String) -> URL?) -> [StreamTitle] {
        let cards = StreamJSON.objects(json)
        var seen = Set<String>()
        var titles: [StreamTitle] = []
        for card in cards {
            guard titles.count < StreamLimits.maxSearchResults,
                  let id = card["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let name = StreamJSON.string(card["name"]),
                  let playURL = play(id), seen.insert(id).inserted else { continue }
            let art = StreamJSON.httpsURL(card["art"])
            titles.append(StreamTitle(id: id, name: name, kind: .other, play: playURL, page: page(id), tileArt: art))
        }
        return titles
    }
}
