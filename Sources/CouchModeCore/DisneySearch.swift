// Owns: Disney+'s own search for the shell's search screen, as a proxy.
// Learned on a real Mac (2026-11-11): the site's search page asks the explore
// API for  search?query=<text>  and gets one page whose single set lists every
// match as the same kind of item a home row holds (a browse action to
// entity-<uuid>). The reader makes that same request from the page (signed in,
// as the page does) and keeps the cards. No I/O here.

import Foundation

public enum DisneySearch {
    /// Function body for callAsyncJavaScript: the matches for `query` as a JSON
    /// array of cards (see DisneyExplore), at most maxSearchResults; "" on any error.
    public static func script(query: String) -> String {
        #"""
        try {
          \#(DisneyExplore.helpers)
          \#(DisneyExplore.cardFunction)
          const page = (await get("search?query=" + encodeURIComponent(\#(StreamJSON.jsString(query))))).data.page;
          const items = (page.containers || []).flatMap(c => c.items || []);
          const cards = items.slice(0, \#(StreamLimits.maxSearchResults * 2)).map(card).filter(Boolean).slice(0, \#(StreamLimits.maxSearchResults));
          const out = JSON.stringify(cards);
          return out.length > \#(DisneyExplore.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// Titles from the script's answer: cards with a plain id and a name,
    /// each once, at most maxSearchResults. Their player address is found when
    /// their details are read.
    public static func titles(fromResults json: String) -> [StreamTitle] {
        var seen = Set<String>()
        var titles: [StreamTitle] = []
        for card in StreamJSON.objects(json) {
            guard titles.count < StreamLimits.maxSearchResults, let title = DisneyExplore.title(fromCard: card),
                  seen.insert(title.id).inserted else { continue }
            titles.append(title)
        }
        return titles
    }
}
