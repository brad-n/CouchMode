// Owns: "more in a row" for Disney+, as a proxy. Learned on a real Mac
// (2026-11-11): every container of the home page carries
// pagination {hasMore, currentOffset, totalCount}, and the page's own paging
// request for the rest of a row is the explore set request
//   set/<container id>?limit=N&offset=K&<the container's params as a query>
// (without the params the site answers 404 or an empty set). The home read
// notes, per row that hasMore, its total, the next offset and the params
// query ("more"); this file turns that into a row total (so the shared screens
// know to ask), a per-row Cursor the reader keeps (cleared when the home is
// read again or the profile switches), the one request's script and its
// answer. One request per reach of a row's end; the request is made from the
// page with the page's own session, so no token appears here. No I/O.
//
// The more-script's answer, the shape titles(fromRead:cursor:) reads:
// {"items":[card], "count": items the site sent, "hasMore": bool}  (card: see DisneyExplore)

import Foundation

public enum DisneyMore {
    /// Where a row's next batch starts: the set to ask, the page's params for it and the offset.
    public struct Cursor: Equatable {
        public let setID: String
        public let query: String
        public let next: Int
        public init(setID: String, query: String, next: Int) {
            self.setID = setID; self.query = query; self.next = next
        }
    }

    static let maxOffset = 5_000
    static let maxQueryLength = 800

    /// JavaScript defining `moreNote(container)`: the total, the next offset and the params query of a
    /// container the site holds more of (the params the page's own set request carries).
    static let noteFunction = #"""
    const moreNote = c => {
      const p = c.pagination || {}, params = c.params || {}, q = new URLSearchParams();
      for (const k of Object.keys(params).slice(0, 12)) if (typeof params[k] === "string") q.set(k, params[k]);
      return { total: p.totalCount, next: (p.currentOffset || 0) + (c.items || []).slice(0, \#(DisneyHome.maxItems)).length, q: q.toString() };
    };
    """#

    /// A row's total from the home read's "more" note; nil when the site holds nothing beyond the loaded titles.
    static func total(_ container: [String: Any], loaded: Int) -> Int? {
        guard let more = container["more"] as? [String: Any], let total = StreamJSON.int(more["total"]), total > loaded else { return nil }
        return total
    }

    /// The cursors the home read implies, by row id (as DisneyHome.parse names rows).
    public static func cursors(fromHome json: String) -> [String: Cursor] {
        var result: [String: Cursor] = [:]
        for container in StreamJSON.object(json)?["rows"] as? [[String: Any]] ?? [] {
            let loaded = (container["items"] as? [[String: Any]] ?? []).count
            guard let id = StreamJSON.token(container["id"]), total(container, loaded: loaded) != nil,
                  let more = container["more"] as? [String: Any], let next = StreamJSON.int(more["next"]),
                  let query = more["q"] as? String, validQuery(query), (0...maxOffset).contains(next) else { continue }
            result["disney-row-\(id)"] = Cursor(setID: id, query: query, next: next)
        }
        return result
    }

    private static func validQuery(_ query: String) -> Bool {
        !query.isEmpty && query.count <= maxQueryLength
            && query.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "=&_-.".contains($0)) }
    }

    /// Function body for callAsyncJavaScript: the one set request at the cursor, answered as the JSON above ("" on any failure).
    public static func script(for cursor: Cursor) -> String? {
        guard let id = StreamJSON.token(cursor.setID), validQuery(cursor.query), (0...maxOffset).contains(cursor.next) else { return nil }
        return #"""
        try {
          \#(DisneyExplore.helpers)
          \#(DisneyExplore.cardFunction)
          const set = (await get("set/" + \#(StreamJSON.jsString(id)) + "?limit=\#(DisneyHome.maxItems)&offset=\#(cursor.next)&" + \#(StreamJSON.jsString(cursor.query)))).data.set;
          const sent = (set.items || []).slice(0, \#(DisneyHome.maxItems));
          const out = JSON.stringify({ items: sent.map(card).filter(Boolean), count: sent.length, hasMore: !!(set.pagination && set.pagination.hasMore) });
          return out.length > \#(DisneyExplore.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// The batch and the cursor for the one after it (nil when the site has no more, or sent nothing); nil when unreadable.
    public static func titles(fromRead json: String, cursor: Cursor) -> (titles: [StreamTitle], cursor: Cursor?)? {
        guard let read = StreamJSON.object(json), let items = read["items"] as? [[String: Any]] else { return nil }
        let titles = items.compactMap(DisneyExplore.title(fromCard:))
        let sent = StreamJSON.int(read["count"]) ?? items.count
        let hasMore = read["hasMore"] as? Bool == true && sent > 0
        let next = cursor.next + sent
        return (titles, hasMore && next <= maxOffset ? Cursor(setID: cursor.setID, query: cursor.query, next: next) : nil)
    }
}
