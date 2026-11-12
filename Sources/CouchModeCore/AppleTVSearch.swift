// Owns: Apple TV's own search for the shell's search screen, as a proxy.
// Learned on a real Mac (2026-11-12): the site's search page asks
//   search?searchTerm=<text>&userTerm=<text>
// and gets a canvas of shelves (top results, shows, movies), each item the same
// kind of item a home shelf holds. The reader makes that same request from the
// page (signed in, as the page does) and keeps the cards of movies and shows, each
// once. No I/O here.

import Foundation

public enum AppleTVSearch {
    /// Function body for callAsyncJavaScript: the matches for `query` as a JSON
    /// array of cards (see AppleTVSite), at most maxSearchResults; "" on any error.
    public static func script(query: String) -> String {
        #"""
        try {
          \#(AppleTVSite.helpers)
          \#(AppleTVSite.cardFunction)
          const text = \#(StreamJSON.jsString(query));
          const canvas = (await get("search", { searchTerm: text, userTerm: text })).data.canvas;
          const items = (canvas.shelves || []).flatMap(s => s.items || []);
          const cards = items.slice(0, \#(StreamLimits.maxSearchResults * 2)).map(card).filter(Boolean).slice(0, \#(StreamLimits.maxSearchResults));
          const out = JSON.stringify(cards);
          return out.length > \#(AppleTVSite.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// Titles from the script's answer: cards with a plain id and a name, each once,
    /// at most maxSearchResults.
    public static func titles(fromResults json: String) -> [StreamTitle] {
        var seen = Set<String>()
        var titles: [StreamTitle] = []
        for card in StreamJSON.objects(json) {
            guard titles.count < StreamLimits.maxSearchResults, let title = AppleTVSite.title(fromCard: card),
                  seen.insert(title.id).inserted else { continue }
            titles.append(title)
        }
        return titles
    }
}
