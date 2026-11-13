// Owns: the pure rules for listing a games folder without ever waiting on it:
// what state a folder is in (from the error a read failed with), when a read
// counts as too slow, the last good listing per console, and the order in which
// the screen hears about a scan (cache first, fresh listing when it arrives).
// Does not touch the disk; the app runs the read off the main thread and
// feeds the outcome in.

import Foundation

/// What the person should be told about a console's games folder.
public enum FolderState: Equatable, Sendable {
    /// Nothing cached yet and the first read is still running.
    case loading
    case ready
    /// The drive is unplugged or the folder is missing.
    case notFound
    /// macOS has not allowed CouchMode to read the folder (EPERM / EACCES).
    case permissionDenied
    /// The read is blocked or failed in a way that looks like a stalled drive.
    case timedOut
}

public enum FolderLimits {
    /// How long a listing may take before the screen stops waiting for it.
    public static let readTimeout: TimeInterval = 3
    /// Most file names read from one folder.
    public static let maxNames = 20_000
    /// Most consoles whose listing is cached.
    public static let maxCachedConsoles = 64
    /// Most reads of one console allowed to be stuck at the same time.
    public static let maxReadsInFlight = 2
}

public enum FolderClassifier {
    /// The state for a failed read, from the POSIX error number.
    public static func state(errno code: Int32) -> FolderState {
        switch code {
        case ENOENT, ENOTDIR: return .notFound
        case EPERM, EACCES: return .permissionDenied
        default: return .timedOut   // ETIMEDOUT, EIO, ENXIO, EBUSY, network errors: the drive is not answering
        }
    }

    /// The state for an error thrown by FileManager (a Cocoa error, usually with a POSIX error underneath).
    public static func state(for error: Error) -> FolderState {
        let ns = error as NSError
        if let posix = posixCode(ns) { return state(errno: posix) }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
            case NSFileReadNoPermissionError: return .permissionDenied
            default: break
            }
        }
        return .timedOut
    }

    private static func posixCode(_ error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain { return Int32(truncatingIfNeeded: error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return posixCode(underlying) }
        return nil
    }

    /// Whether a read that has not answered yet is now too slow to wait for.
    public static func hasTimedOut(elapsed: TimeInterval, limit: TimeInterval = FolderLimits.readTimeout) -> Bool {
        elapsed >= limit
    }
}

/// What the player reads when a folder is not in the ready state.
public enum FolderMessages {
    public static let filesAndFoldersPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    /// The pane's address on newer macOS, tried when the first does not open.
    public static let filesAndFoldersPaneNewer = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"

    /// "Storage" for /Volumes/Storage/Games/switch; nil for a folder on the startup disk.
    public static func volumeName(forPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return String(parts[1])
    }

    public static func text(for state: FolderState, path: String) -> String? {
        switch state {
        case .loading, .ready: return nil
        case .notFound:
            return "Games folder not found. The drive is unplugged or the folder is missing: \(path)"
        case .permissionDenied:
            let drive = volumeName(forPath: path).map { "the \($0) drive" } ?? "this folder"
            let pane = "System Settings \u{203A} Privacy & Security \u{203A} Files and Folders \u{203A} CouchMode"
            let suffix = volumeName(forPath: path) == nil ? "" : " \u{203A} Removable Volumes"
            return "Allow CouchMode to use \(drive): \(pane)\(suffix)"
        case .timedOut:
            return "The drive isn't responding"
        }
    }

    /// A short line for a tile.
    public static func tileLine(for state: FolderState) -> String? {
        switch state {
        case .loading: return "Loading games\u{2026}"
        case .ready: return nil
        case .notFound: return "Folder not found"
        case .permissionDenied: return "Needs permission"
        case .timedOut: return "Drive isn't responding"
        }
    }
}

/// One read of a games folder: file names (bounded) and the sizes of those that are plain files.
public struct FolderListing: Equatable, Sendable {
    public var names: [String]
    public var sizes: [String: Int64]
    public init(names: [String], sizes: [String: Int64] = [:]) {
        self.names = names
        self.sizes = sizes
    }
}

public enum FolderReadResult: Equatable, Sendable {
    case listed(FolderListing)
    case failed(FolderState)
}

/// What a screen shows for one console right now.
public struct ConsoleFolderSnapshot: Equatable, Sendable {
    public var state: FolderState
    /// The listing to draw: the last good one, shown at once and replaced when a fresh one arrives.
    public var listing: FolderListing?
    public init(state: FolderState, listing: FolderListing?) {
        self.state = state
        self.listing = listing
    }
}

/// The last good listing and the current state per console; decides what each scan event means for the screen.
public struct FolderScanStore: Sendable {
    public enum Begin: Equatable, Sendable {
        /// Start a read; `generation` identifies it. `snapshot` is what to draw now (the cache, or loading).
        case start(generation: Int, snapshot: ConsoleFolderSnapshot)
        /// Enough reads are already stuck on this console: draw `snapshot`, start nothing.
        case skipped(ConsoleFolderSnapshot)
    }

    private struct Entry: Sendable {
        var cached: FolderListing?
        var state: FolderState = .loading
        var issued = 0
        var applied = 0
        var inFlight: Set<Int> = []
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    /// What to draw for a console without waiting for anything.
    public func snapshot(_ console: String) -> ConsoleFolderSnapshot {
        Self.snapshot(of: entries[console] ?? Entry())
    }

    private static func snapshot(of e: Entry) -> ConsoleFolderSnapshot {
        switch e.state {
        case .loading: return ConsoleFolderSnapshot(state: e.cached == nil ? .loading : .ready, listing: e.cached)
        case .ready: return ConsoleFolderSnapshot(state: .ready, listing: e.cached)
        case .timedOut: return ConsoleFolderSnapshot(state: .timedOut, listing: e.cached)
        case .notFound, .permissionDenied: return ConsoleFolderSnapshot(state: e.state, listing: nil)
        }
    }

    /// A scan is wanted: cache first, then the read starts.
    public mutating func begin(_ console: String) -> Begin {
        var e = entries[console] ?? Entry()
        guard e.inFlight.count < FolderLimits.maxReadsInFlight else { return .skipped(Self.snapshot(of: e)) }
        e.issued += 1
        e.inFlight.insert(e.issued)
        let generation = e.issued
        let shown = Self.snapshot(of: e)
        store(e, for: console)
        return .start(generation: generation, snapshot: shown)
    }

    /// The read has taken too long. Returns the snapshot to draw, or nil when nothing changes
    /// (it already finished, or a newer result is showing).
    public mutating func timedOut(_ console: String, generation: Int) -> ConsoleFolderSnapshot? {
        guard var e = entries[console], e.inFlight.contains(generation), generation > e.applied else { return nil }
        e.state = .timedOut
        store(e, for: console)
        return Self.snapshot(of: e)
    }

    /// A read finished (maybe long after it timed out). Returns the snapshot to draw, or nil when a
    /// newer read's result is already showing.
    public mutating func finish(_ console: String, generation: Int, result: FolderReadResult) -> ConsoleFolderSnapshot? {
        guard var e = entries[console] else { return nil }
        e.inFlight.remove(generation)
        guard generation > e.applied else { store(e, for: console); return nil }
        e.applied = generation
        switch result {
        case .listed(let listing): e.cached = listing; e.state = .ready
        case .failed(let state): e.state = state
        }
        store(e, for: console)
        return Self.snapshot(of: e)
    }

    private mutating func store(_ entry: Entry, for console: String) {
        if entries[console] == nil {
            order.append(console)
            if order.count > FolderLimits.maxCachedConsoles { entries[order.removeFirst()] = nil }
        }
        entries[console] = entry
    }
}
