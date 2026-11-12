// Owns: "more in a row" for Prime Video, as a proxy. Learned on a real Mac
// (2026-11-11): the home page's carousels that hold more carry
// paginationTargetId, paginationServiceToken, paginationStartIndex and
// estimatedTotal in the page's data, and when a person scrolls such a row to
// its end the page makes ONE same-origin request,
//   POST /api/paginateCollection   (form-encoded: pageType, pageId,
//   collectionType=Container, paginationTargetId, serviceToken, startIndex, and the
//   page's own scheme/feature parameters from its body.pagination.queryParameters)
// whose answer has entities (the same cards), hasMoreItems, and the next
// serviceToken (pagination.serviceToken) and startIndex. The home read notes,
// per row, the total and that cursor ("more"); this file turns that into a row
// total (so the shared screens know to ask), a per-row Cursor the reader keeps
// in memory only (a paging position, never logged or stored; cleared when the
// home is read again or the profile switches), the one request's script and its
// answer. The script runs in the home page and uses the page's own parameters
// and session cookie; no sign-in token is read. No I/O here.
//
// The more-script's answer, the shape titles(fromRead:cursor:) reads:
// {"items":[card], "hasMore": bool, "token": next serviceToken, "start": next startIndex}
// (card: see PrimeSite)

import Foundation

public enum PrimeMore {
    /// Where a row's next batch starts: the page's target for the row, the position token and the start index.
    public struct Cursor: Equatable {
        public let target: String
        public let token: String
        public let start: Int
        public init(target: String, token: String, start: Int) {
            self.target = target; self.token = token; self.start = start
        }
    }

    static let maxStart = 5_000
    static let maxTokenLength = 4_096

    /// JavaScript defining `moreNote(container)`: the total and cursor of a carousel the page holds more of; null otherwise.
    static let noteFunction = #"""
    const moreNote = (c, loaded) => {
      if (typeof c.paginationServiceToken !== "string" || typeof c.paginationTargetId !== "string") return null;
      if (!(c.estimatedTotal > loaded) || typeof c.paginationStartIndex !== "number") return null;
      return { total: c.estimatedTotal, target: c.paginationTargetId, token: c.paginationServiceToken, start: c.paginationStartIndex };
    };
    """#

    /// A row's total from the home read's "more" note; nil when the page holds nothing beyond the loaded titles.
    static func total(_ container: [String: Any], loaded: Int) -> Int? {
        guard let more = container["more"] as? [String: Any], let total = StreamJSON.int(more["total"]), total > loaded else { return nil }
        return total
    }

    /// The cursors the home read implies, by row id (as PrimeHome.parse names rows).
    public static func cursors(fromHome json: String) -> [String: Cursor] {
        var result: [String: Cursor] = [:]
        for container in StreamJSON.object(json)?["rows"] as? [[String: Any]] ?? [] {
            let loaded = (container["items"] as? [[String: Any]] ?? []).count
            guard let id = container["id"] as? String, (1...3).contains(id.count), id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  total(container, loaded: loaded) != nil, let more = container["more"] as? [String: Any],
                  let target = more["target"] as? String, let token = more["token"] as? String, let start = StreamJSON.int(more["start"]),
                  let cursor = Optional(Cursor(target: target, token: token, start: start)), valid(cursor) else { continue }
            result["prime-row-\(id)"] = cursor
        }
        return result
    }

    /// URL-safe base64 text, as the page's own targets and tokens are, so nothing can add a parameter.
    private static func valid(_ cursor: Cursor) -> Bool {
        func plain(_ text: String, max: Int) -> Bool {
            !text.isEmpty && text.count <= max && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-=".contains($0)) }
        }
        return plain(cursor.target, max: 512) && plain(cursor.token, max: maxTokenLength) && (0...maxStart).contains(cursor.start)
    }

    /// Function body for callAsyncJavaScript: the one paginateCollection request for the cursor, answered as the JSON above ("" on any failure).
    public static func script(for cursor: Cursor) -> String? {
        guard valid(cursor) else { return nil }
        return #"""
        try {
          \#(PrimeSite.hydration)
          \#(PrimeSite.cardFunction)
          const body = bodyOf();
          const q = body && body.pagination && body.pagination.queryParameters, sp = body && body.swiftPageParameters;
          if (!q || !sp || !Array.isArray(q.dynamicFeatures)) return "";
          const p = new URLSearchParams();
          p.set("pageType", sp.pageType); p.set("pageId", sp.pageId); p.set("collectionType", "Container");
          p.set("paginationTargetId", \#(StreamJSON.jsString(cursor.target))); p.set("serviceToken", \#(StreamJSON.jsString(cursor.token)));
          p.set("startIndex", "\#(cursor.start)");
          p.set("actionScheme", q.actionScheme); p.set("payloadScheme", "default");
          p.set("decorationScheme", q.decorationScheme); p.set("featureScheme", q.featureScheme);
          for (const f of q.dynamicFeatures.slice(0, 40)) p.append("dynamicFeatures", f);
          p.set("widgetScheme", q.widgetScheme); p.set("variant", "desktopOSX");
          const response = await fetch("/api/paginateCollection", {
            method: "POST", credentials: "same-origin",
            headers: { "x-requested-with": "XMLHttpRequest", "Content-Type": "application/x-www-form-urlencoded", "X-Amzn-Client-TTL-Seconds": "15" },
            body: p.toString()
          });
          if (!response.ok) return "";
          const page = await response.json();
          const next = page.pagination || {};
          const out = JSON.stringify({ items: (page.entities || []).slice(0, \#(StreamLimits.maxTitlesPerRow)).map(card).filter(Boolean),
                                       hasMore: page.hasMoreItems === true, token: typeof next.serviceToken === "string" ? next.serviceToken : null,
                                       start: typeof page.startIndex === "number" ? page.startIndex : null });
          return out.length > \#(PrimeSite.maxScriptBytes) ? "" : out;
        } catch (e) {
          return "";
        }
        """#
    }

    /// The batch and the cursor for the one after it (nil when the page has no more, or no usable next position); nil when unreadable.
    public static func titles(fromRead json: String, cursor: Cursor) -> (titles: [StreamTitle], cursor: Cursor?)? {
        guard let read = StreamJSON.object(json), let items = read["items"] as? [[String: Any]] else { return nil }
        let titles = items.compactMap(PrimeSite.title(fromCard:))
        guard read["hasMore"] as? Bool == true, let token = read["token"] as? String, let start = StreamJSON.int(read["start"]), start > cursor.start
        else { return (titles, nil) }
        let next = Cursor(target: cursor.target, token: token, start: start)
        return (titles, valid(next) ? next : nil)
    }
}
