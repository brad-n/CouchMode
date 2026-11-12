// Owns: formatting the app's version for Settings > About, and deciding what
// counts as a release version string. Pure: reading the bundle belongs to the
// app target, and scripts/release.sh applies the same rule to its argument.

import Foundation

public enum AppVersion {
    /// "0.2.0 (123, abc1234)": release version, build count, short commit.
    /// A missing part shows "?" (version, build) or is left out (commit).
    public static func text(short: String?, build: String?, sha: String?) -> String {
        let trimmedSha = sha?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = [build ?? "?", trimmedSha].filter { !$0.isEmpty }.joined(separator: ", ")
        return "\(short ?? "?") (\(detail))"
    }

    /// 1 to 3 dotted numbers, optionally followed by "-" and a dotted
    /// alphanumeric pre-release tag ("0.2.0", "0.2.0-rc1").
    public static func isValidRelease(_ s: String) -> Bool {
        let halves = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = halves.first, halves.count <= 2 else { return false }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(nums.count), nums.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) else { return false }
        if halves.count == 2 {
            let tags = halves[1].split(separator: ".", omittingEmptySubsequences: false)
            return tags.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        }
        return true
    }
}
