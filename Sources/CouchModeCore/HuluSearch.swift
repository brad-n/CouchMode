// Owns: Hulu's own search for the shell's search screen, as a proxy: open
// hulu.com/search, type the query into the page's own search box, and read
// the results the page lists under it. Learned on a real Mac (2026-11-11): the
// page ignores a ?q= address (it asks discover with an empty search_query);
// typing in the box (data-testid "search-bar-input") makes the page request
// discover's search/entity and list each match as a link
// (data-testid "instant-search-item-link") to /series/<id>, /movie/<id>, an
// account page or a network, with its name (list-item-content-title) and
// artwork. Only the series and movie links are titles. No I/O here.

import Foundation

public enum HuluSearch {
    /// Hulu's search page.
    public static let pageURL = URL(string: "https://www.hulu.com/search")!

    /// Function body for callAsyncJavaScript: true once the page's search box
    /// is there and the page's own code is attached to it (typing before that
    /// would go unheard).
    public static let readyScript = #"""
    const box = document.querySelector('[data-testid="search-bar-input"]');
    return !!box && Object.keys(box).some(k => k.startsWith("__reactProps"));
    """#

    /// Function body for callAsyncJavaScript: types `query` into the page's
    /// search box the way a keyboard would (the page's own handlers run);
    /// true when typed.
    public static func typeScript(query: String) -> String {
        #"""
        const box = document.querySelector('[data-testid="search-bar-input"]');
        if (!box) return false;
        box.focus();
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(box, \#(StreamJSON.jsString(query)));
        box.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
        """#
    }

    /// Function body for callAsyncJavaScript: true once the page lists series or movies.
    public static let resultsReadyScript = #"return !!document.querySelector('[data-testid="instant-search-item-link"][href^="/series/"], [data-testid="instant-search-item-link"][href^="/movie/"]');"#

    /// Function body for callAsyncJavaScript: the listed series and movies as
    /// a JSON string, [{href, name, art}], at most maxSearchResults, once the
    /// list has stopped growing (the page fills it in as answers arrive).
    public static let resultsScript = #"""
    const links = () => Array.from(document.querySelectorAll('[data-testid="instant-search-item-link"]'))
      .filter(a => /^\/(series|movie)\//.test(a.getAttribute("href") || ""));
    let count = -1;
    for (let i = 0; i < 6 && links().length !== count; i++) { count = links().length; await new Promise(r => setTimeout(r, 300)); }
    return JSON.stringify(links().slice(0, \#(StreamLimits.maxSearchResults)).map(a => {
      const name = a.querySelector('[data-testid="list-item-content-title"]');
      const image = a.querySelector("img.ListItem__artwork__image");
      return { href: a.getAttribute("href"), name: name ? name.textContent : "", art: image ? image.getAttribute("src") : null };
    }));
    """#

    /// Titles from resultsScript's answer: only /series/<id> and /movie/<id>
    /// links with a name, each once, art only from Hulu over https, at most
    /// maxSearchResults. A series's own player address is its page's id; the
    /// details screen finds the episode to continue.
    public static func titles(fromResults json: String) -> [StreamTitle] {
        var seen = Set<String>()
        var titles: [StreamTitle] = []
        for card in StreamJSON.objects(json) {
            guard titles.count < StreamLimits.maxSearchResults,
                  let href = card["href"] as? String, let (kind, id) = parse(href: href),
                  let name = StreamJSON.string(card["name"]),
                  let play = HuluHome.playURL(id: id), seen.insert(id).inserted else { continue }
            titles.append(StreamTitle(id: id, name: name, kind: kind, play: play, page: HuluHome.pageURL(kind: kind, id: id),
                                      tileArt: HuluHome.imageURL(card["art"] as? String, width: 640, height: 360)))
        }
        return titles
    }

    private static func parse(href: String) -> (StreamTitle.Kind, String)? {
        let parts = href.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, let id = StreamJSON.token(parts[1]) else { return nil }
        switch parts[0] {
        case "series": return (.show, id)
        case "movie": return (.movie, id)
        default: return nil
        }
    }
}
