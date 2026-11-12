// Owns: Prime Video's own search for the shell's search screen, as a proxy.
// Learned on a real Mac (2026-11-11): the site's search page
// (/search/?phrase=<text>) carries its results in the page's own state (see
// PrimeSite) as containers: a "Grid" of top results, then similar and "more to
// explore" shelves, each entity the same kind of item a home row holds. The
// reader opens that page for the query and keeps the grids' items. No I/O here.

import Foundation

public enum PrimeSearch {
    /// Prime's search page for a query; nil when it is empty.
    public static func pageURL(query: String) -> URL? {
        guard let text = StreamSearch.normalized(query) else { return nil }
        var components = URLComponents(string: "\(PrimeSite.origin)/search/")
        components?.queryItems = [URLQueryItem(name: "phrase", value: text)]
        return components?.url
    }

    /// Function body for callAsyncJavaScript: true once the search page's data is there.
    public static let readyScript = #"""
    try {
      \#(PrimeSite.hydration)
      const d = hydration();
      return !!d && d.init.route.name === "search" && Array.isArray(d.init.preparations.body.containers);
    } catch (e) {
      return false;
    }
    """#

    /// Function body for callAsyncJavaScript: the matches as a JSON array of cards
    /// (see PrimeSite), at most maxSearchResults; "" on any error.
    public static let resultsScript = #"""
    try {
      \#(PrimeSite.hydration)
      \#(PrimeSite.cardFunction)
      const body = bodyOf();
      if (!body || !Array.isArray(body.containers)) return "";
      const items = body.containers.filter(c => c.containerType === "Grid").flatMap(c => c.entities || []);
      const cards = items.slice(0, \#(StreamLimits.maxSearchResults * 2)).map(card).filter(Boolean).slice(0, \#(StreamLimits.maxSearchResults));
      const out = JSON.stringify(cards);
      return out.length > \#(PrimeSite.maxScriptBytes) ? "" : out;
    } catch (e) {
      return "";
    }
    """#

    /// Titles from the script's answer: cards with a plain id and a name, each once,
    /// at most maxSearchResults.
    public static func titles(fromResults json: String) -> [StreamTitle] {
        var seen = Set<String>()
        var titles: [StreamTitle] = []
        for card in StreamJSON.objects(json) {
            guard titles.count < StreamLimits.maxSearchResults, let title = PrimeSite.title(fromCard: card),
                  seen.insert(title.id).inserted else { continue }
            titles.append(title)
        }
        return titles
    }
}
