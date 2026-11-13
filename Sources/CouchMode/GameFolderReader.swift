// Owns: the one blocking read of a games folder (its file names and sizes).
// Runs only on a background thread: the first read of a removable or network
// volume can wait for a macOS permission prompt or a slow disk. Turns what
// happens into a FolderReadResult; deciding what it means is Core's job.

import Foundation
import CouchModeCore

enum GameFolderReader {
    /// Games per folder text for first-run setup, read on background threads and given up on after the read
    /// timeout: a folder that is missing, blocked or stalled is absent from the answer. Never waits longer.
    nonisolated static func counts(_ folders: [String: [String]], timeout: TimeInterval = FolderLimits.readTimeout) async -> [String: Int] {
        guard !folders.isEmpty else { return [:] }
        let gather = Gather(expected: folders.count)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Int], Never>) in
            gather.onDone = { continuation.resume(returning: $0) }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for (folder, extensions) in folders {
                DispatchQueue.global(qos: .userInitiated).async {
                    var count: Int?
                    if case .listed(let listing) = read(path: PathText.expandingTilde(folder, home: home), withSizes: false) {
                        count = listing.names.filter { !$0.hasPrefix(".") && extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.count
                    }
                    gather.add(folder, count)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gather.finish() }
        }
    }

    /// Collects the answers and reports once: when all are in, or when the time is up with whatever has arrived.
    private final class Gather: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var answered = 0
        private var finished = false
        let expected: Int
        var onDone: (([String: Int]) -> Void)?
        init(expected: Int) { self.expected = expected }

        func add(_ folder: String, _ count: Int?) {
            lock.lock()
            if let count { counts[folder] = count }
            answered += 1
            let done = answered == expected
            lock.unlock()
            if done { finish() }
        }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let result = counts
            lock.unlock()
            onDone?(result)
        }
    }

    /// Lists `path`. Blocks for as long as the disk does: never call it on the main thread.
    nonisolated static func read(path: String, withSizes: Bool) -> FolderReadResult {
        do {
            let names = Array(try FileManager.default.contentsOfDirectory(atPath: path).prefix(FolderLimits.maxNames))
            var sizes: [String: Int64] = [:]
            if withSizes {
                for n in names where !n.hasPrefix(".") {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: (path as NSString).appendingPathComponent(n))
                    if let size = attrs?[.size] as? NSNumber { sizes[n] = size.int64Value }
                }
            }
            return .listed(FolderListing(names: names, sizes: sizes))
        } catch {
            return .failed(FolderClassifier.state(for: error))
        }
    }
}
