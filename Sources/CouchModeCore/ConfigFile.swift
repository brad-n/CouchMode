// Owns: the config file's life on disk inside one directory it is given:
// loading it, creating it on first run, setting a corrupt one aside, and
// writing it atomically. The one Core file that touches disk: the directory
// and the clock are passed in, so a test uses a temp folder and a fixed date.
// What the config means is AppConfig's.

import Foundation

public struct ConfigFile {
    public static let fileName = "config.json"

    public enum Outcome: Equatable {
        case loaded(AppConfig)
        /// There was no file; defaults were written.
        case created(AppConfig)
        /// The file was unreadable as a config; it was renamed to `backup` and defaults were written.
        case replacedCorrupt(AppConfig, backup: URL, reason: String)
        /// The disk could not be written (or read); defaults are used this run, in memory.
        case unusable(AppConfig, reason: String)

        public var config: AppConfig {
            switch self {
            case .loaded(let c), .created(let c), .replacedCorrupt(let c, _, _), .unusable(let c, _): return c
            }
        }
    }

    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) { self.directory = directory }

    public func load(defaults: () -> AppConfig, now: Date) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return writeFresh(defaults()) { .created($0) } }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: AppConfig.maxBytes + 1) ?? Data()
        } catch {
            return .unusable(defaults(), reason: "cannot read config: \(error.localizedDescription)")
        }
        do { return .loaded(try AppConfig.parse(data)) }
        catch {
            let backup = backupURL(now: now)
            do { try fm.moveItem(at: url, to: backup) }
            catch { return .unusable(defaults(), reason: "corrupt config could not be renamed: \(error.localizedDescription)") }
            return writeFresh(defaults()) { .replacedCorrupt($0, backup: backup, reason: String(describing: error)) }
        }
    }

    /// Atomic: the bytes go to a temporary file that replaces config.json in one step.
    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.encoded().write(to: url, options: .atomic)
    }

    private func writeFresh(_ config: AppConfig, _ outcome: (AppConfig) -> Outcome) -> Outcome {
        do { try save(config); return outcome(config) }
        catch { return .unusable(config, reason: "cannot write config: \(error.localizedDescription)") }
    }

    /// config.json.bad-<UTC time>, with a counter if that name is taken.
    func backupURL(now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = "\(Self.fileName).bad-\(f.string(from: now))"
        var candidate = directory.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), n < 100 {
            candidate = directory.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }
}
