// Owns: building the Safari user-agent string from the installed Safari's
// version, and the fallback when that version can't be trusted. Pure: reading
// the version off disk belongs to the app target.

import Foundation

public enum SafariUserAgent {
    /// `version` is `CFBundleShortVersionString` (for example "27.2"). Only
    /// plain dotted numbers are accepted; anything else gives the fallback.
    /// The platform and WebKit tokens are exactly what Safari itself sends.
    public static func string(forVersion version: String?) -> String {
        guard let v = version?.trimmingCharacters(in: .whitespacesAndNewlines), isPlainVersion(v) else {
            return UserAgents.safari
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v) Safari/605.1.15"
    }

    /// 1 to 3 dot-separated numbers of at most 3 digits each.
    static func isPlainVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
    }

    /// The version out of a Safari `Info.plist`'s bytes, if it has one.
    public static func version(fromInfoPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}
