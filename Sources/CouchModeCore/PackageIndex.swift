// Owns: the published package index (`apps/index.json` in the repo) as pure
// data: parsing it strictly, checking a package's downloaded files against
// the hashes it lists, comparing package versions, deciding whether a
// published package should be downloaded, and choosing between a downloaded
// and a bundled copy. Does no I/O and no networking (PackageUpdater does).
// Hashes guard against corruption and truncation, not against a hostile
// repo: the index itself is not signed (see agents/release.md).

import Foundation
import CryptoKit

/// A dotted numeric version such as `1.2.0`: up to six parts, compared part by part (a missing part is 0).
public struct PackageVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...6).contains(pieces.count) else { return nil }
        var out: [Int] = []
        for p in pieces {
            guard (1...9).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        parts = out
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: PackageVersion, b: PackageVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: PackageVersion, b: PackageVersion) -> Bool { !(a < b) && !(b < a) }

    /// True when `candidate` is a readable version newer than `current`; with no readable current, any readable candidate is.
    public static func isNewer(_ candidate: String, than current: String?) -> Bool {
        guard let c = PackageVersion(candidate) else { return false }
        guard let current, let cur = PackageVersion(current) else { return true }
        return c > cur
    }
}

public enum PackageIndexError: Error, Equatable, CustomStringConvertible {
    case tooLarge, malformed(String), unsupportedVersion(Int), invalid(String)
    public var description: String {
        switch self {
        case .tooLarge: return "index too large"
        case .malformed(let s): return "index is not the expected shape: \(s)"
        case .unsupportedVersion(let v): return "unsupported index version \(v)"
        case .invalid(let s): return "index entry invalid: \(s)"
        }
    }
}

public struct PackageIndex: Equatable, Sendable {
    public static let supportedVersion = 1
    public static let maxBytes = 256 * 1024
    public static let maxPackages = 200
    public static let maxFilesPerPackage = 8

    public struct File: Equatable, Sendable {
        public let name: String
        public let sha256: String
        public init(name: String, sha256: String) { self.name = name; self.sha256 = sha256 }
    }

    public enum Verification: Equatable, Sendable { case ok, missing(String), mismatch(String) }

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let version: String
        public let readerAPI: Int
        public let files: [File]

        public init(id: String, version: String, readerAPI: Int, files: [File]) {
            self.id = id; self.version = version; self.readerAPI = readerAPI; self.files = files
        }

        /// Every listed file must be present and hash to the listed value; one miss means none can be used.
        public func verify(_ contents: [String: Data]) -> Verification {
            for file in files {
                guard let data = contents[file.name] else { return .missing(file.name) }
                if PackageIndex.sha256Hex(data) != file.sha256 { return .mismatch(file.name) }
            }
            return .ok
        }
    }

    public let version: Int
    public let packages: [Entry]

    public func entry(id: String) -> Entry? { packages.first { $0.id == id } }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A package id or file name: plain ASCII letters, digits, dash, dot and underscore; never a path, never hidden.
    static func isPlainName(_ s: String, allowDot: Bool) -> Bool {
        guard (1...64).contains(s.count), s.first != "." else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || (allowDot && $0 == ".")) }
    }

    public static func parse(_ data: Data) throws -> PackageIndex {
        guard data.count <= maxBytes else { throw PackageIndexError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PackageIndexError.malformed("not an object") }
        guard let version = root["version"] as? Int else { throw PackageIndexError.malformed("version") }
        guard version == supportedVersion else { throw PackageIndexError.unsupportedVersion(version) }
        guard let raw = root["packages"] as? [[String: Any]], raw.count <= maxPackages else { throw PackageIndexError.malformed("packages") }
        var seen = Set<String>(), entries: [Entry] = []
        for item in raw {
            guard let id = item["id"] as? String, isPlainName(id, allowDot: false) else { throw PackageIndexError.invalid("id") }
            guard seen.insert(id).inserted else { throw PackageIndexError.invalid("duplicate \(id)") }
            guard let ver = item["version"] as? String, PackageVersion(ver) != nil else { throw PackageIndexError.invalid("\(id): version") }
            guard let api = item["readerAPI"] as? Int else { throw PackageIndexError.invalid("\(id): readerAPI") }
            guard let rawFiles = item["files"] as? [[String: Any]], (1...maxFilesPerPackage).contains(rawFiles.count) else {
                throw PackageIndexError.invalid("\(id): files")
            }
            var names = Set<String>(), files: [File] = []
            for f in rawFiles {
                guard let name = f["name"] as? String, isPlainName(name, allowDot: true), names.insert(name).inserted else { throw PackageIndexError.invalid("\(id): file name") }
                guard let sha = f["sha256"] as? String, sha.count == 64, sha.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else {
                    throw PackageIndexError.invalid("\(id): sha256 of \(name)")
                }
                files.append(File(name: name, sha256: sha))
            }
            entries.append(Entry(id: id, version: ver, readerAPI: api, files: files))
        }
        return PackageIndex(version: version, packages: entries)
    }
}

// MARK: - Deciding

public enum PackageUpdateDecision: Equatable, Sendable {
    case download
    case upToDate
    /// Published for a reader API this app does not speak.
    case unsupportedAPI(Int)
}

public enum PackageSourceChoice: Equatable, Sendable { case downloaded, bundled, none }

public enum PackagePolicy {
    /// Download only a package this app can run (its reader API is supported) and that is newer than the best copy it has.
    public static func decide(_ entry: PackageIndex.Entry, installed: String?, supportedAPI: Int) -> PackageUpdateDecision {
        guard entry.readerAPI == supportedAPI else { return .unsupportedAPI(entry.readerAPI) }
        return PackageVersion.isNewer(entry.version, than: installed) ? .download : .upToDate
    }

    /// The newer of two optional versions (the one to compare a published package against).
    public static func newest(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case (nil, _): return b
        case (_, nil): return a
        case (let x?, let y?): return PackageVersion.isNewer(y, than: x) ? y : x
        }
    }

    /// A verified downloaded copy first, then the bundled one; but an app that ships a newer bundled copy than the
    /// stale download it finds uses the bundled one. Versions are those of copies that are present and usable.
    public static func choose(downloaded: String?, bundled: String?) -> PackageSourceChoice {
        switch (downloaded, bundled) {
        case (nil, nil): return .none
        case (_?, nil): return .downloaded
        case (nil, _?): return .bundled
        case (let d?, let b?): return PackageVersion.isNewer(b, than: d) ? .bundled : .downloaded
        }
    }
}

public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    /// An automatic check is due when none ran yet, a day has passed, or the last time is in the future (a clock change).
    public static func isDue(last: Date?, now: Date, interval: TimeInterval = UpdateSchedule.interval) -> Bool {
        guard let last else { return true }
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

// MARK: - Addresses

public enum PackageSource {
    public static let defaultRef = "main"
    public static let host = "raw.githubusercontent.com"
    public static let repo = "brad-n/CouchMode"

    /// A branch, tag or commit name that is safe to put in an address.
    public static func validRef(_ ref: String) -> Bool {
        guard (1...100).contains(ref.count), !ref.contains(".."), ref.first != "/", ref.first != "-", ref.last != "/" else { return false }
        return ref.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }
    }

    /// `https://raw.githubusercontent.com/brad-n/CouchMode/<ref>/apps/<path>`; nil for an odd ref or path.
    public static func url(ref: String?, path: String) -> URL? {
        let ref = ref ?? defaultRef
        guard validRef(ref) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ PackageIndex.isPlainName($0, allowDot: true) }) else { return nil }
        return URL(string: "https://\(host)/\(repo)/\(ref)/apps/\(path)")
    }
}

// MARK: - Result line

public struct PackageUpdateReport: Equatable, Sendable {
    public enum Index: Equatable, Sendable { case read, missing, unreachable, unusable }
    public var index: Index
    public var installed: [String]
    public var failed: [String]
    public var unsupported: [String]

    public init(index: Index, installed: [String] = [], failed: [String] = [], unsupported: [String] = []) {
        self.index = index; self.installed = installed; self.failed = failed; self.unsupported = unsupported
    }

    /// The short line Settings shows.
    public var line: String {
        switch index {
        case .missing: return "No app updates are published yet."
        case .unreachable: return "Couldn't reach GitHub. Your apps are unchanged."
        case .unusable: return "The update list wasn't usable. Your apps are unchanged."
        case .read:
            if !installed.isEmpty {
                let text = "Updated " + installed.joined(separator: ", ") + "."
                return failed.isEmpty ? text : text + " Couldn't update " + failed.joined(separator: ", ") + "."
            }
            if !failed.isEmpty { return "Couldn't update " + failed.joined(separator: ", ") + ". Your apps are unchanged." }
            return "App packages are up to date."
        }
    }
}
