// Owns: the careful little readers every streaming site's parser uses on the
// JSON its page script hands back, and quoting text into a page script. One
// place, so a fix (a new shape of id, an image address to refuse) reaches
// every service at once. What each site's JSON means is that site's parser.

import Foundation

public enum StreamJSON {
    /// A JSON object from a script's answer; nil for anything else.
    public static func object(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    /// A JSON array of objects from a script's answer; empty for anything else.
    public static func objects(_ json: String) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
    }

    /// A whole number, also when it arrives as a JSON double.
    public static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double, d.isFinite, abs(d) < 1e15, d.rounded() == d { return Int(d) }
        return nil
    }

    /// Text with its ends trimmed; nil when empty.
    public static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A positive numeric id as text (sites send them as numbers or digit strings).
    public static func numericID(_ value: Any?) -> String? {
        if let n = int(value) { return n > 0 ? String(n) : nil }
        if let s = value as? String, (1...20).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }) { return s }
        return nil
    }

    /// An id made of letters, digits and dashes (uuids, guids), at most `maxLength` long.
    public static func token(_ value: Any?, maxLength: Int = 64) -> String? {
        guard let s = value as? String, (1...maxLength).contains(s.count),
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return s
    }

    /// An https address; anything else (plain http, junk) is refused.
    public static func httpsURL(_ value: Any?) -> URL? {
        guard let s = value as? String, let url = URL(string: s), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// `text` as a JavaScript string literal, safe to put in a page script.
    public static func jsString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
