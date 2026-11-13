// Owns: tests for the games-folder state rules: error classification, the
// timeout decision, cache-then-update ordering and the player-facing text.

import XCTest
@testable import CouchModeCore

final class GamesFolderScanTests: XCTestCase {
    private func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    private func cocoa(_ code: Int, underlying: NSError? = nil) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }
    private let one = FolderListing(names: ["A.app"])
    private let two = FolderListing(names: ["A.app", "B.app"])

    // MARK: Classification

    func testMissingFolderIsNotFound() {
        XCTAssertEqual(FolderClassifier.state(errno: ENOENT), .notFound)
        XCTAssertEqual(FolderClassifier.state(for: cocoa(NSFileReadNoSuchFileError, underlying: posix(ENOENT))), .notFound)
        XCTAssertEqual(FolderClassifier.state(for: cocoa(NSFileReadNoSuchFileError)), .notFound)
    }

    func testPermissionErrorsAreDenied() {
        XCTAssertEqual(FolderClassifier.state(errno: EPERM), .permissionDenied)
        XCTAssertEqual(FolderClassifier.state(errno: EACCES), .permissionDenied)
        XCTAssertEqual(FolderClassifier.state(for: cocoa(NSFileReadNoPermissionError, underlying: posix(EPERM))), .permissionDenied)
        XCTAssertEqual(FolderClassifier.state(for: cocoa(NSFileReadNoPermissionError)), .permissionDenied)
    }

    func testStalledDriveErrorsAreTimedOut() {
        XCTAssertEqual(FolderClassifier.state(errno: EIO), .timedOut)
        XCTAssertEqual(FolderClassifier.state(errno: ETIMEDOUT), .timedOut)
        XCTAssertEqual(FolderClassifier.state(for: cocoa(NSFileReadUnknownError, underlying: posix(EIO))), .timedOut)
        XCTAssertEqual(FolderClassifier.state(for: cocoa(NSFileReadUnknownError)), .timedOut)
    }

    // MARK: Timeout

    func testTimeoutDecision() {
        XCTAssertFalse(FolderClassifier.hasTimedOut(elapsed: 2.9))
        XCTAssertTrue(FolderClassifier.hasTimedOut(elapsed: 3))
        XCTAssertTrue(FolderClassifier.hasTimedOut(elapsed: 10))
        XCTAssertTrue(FolderClassifier.hasTimedOut(elapsed: 1, limit: 1))
    }

    // MARK: Cache, then update

    func testFirstScanDrawsLoadingThenTheListing() {
        var store = FolderScanStore()
        guard case .start(let g, let shown) = store.begin("switch") else { return XCTFail() }
        XCTAssertEqual(shown, ConsoleFolderSnapshot(state: .loading, listing: nil))
        let done = store.finish("switch", generation: g, result: .listed(one))
        XCTAssertEqual(done, ConsoleFolderSnapshot(state: .ready, listing: one))
    }

    func testRescanDrawsTheCacheAtOnceThenTheFreshListing() {
        var store = FolderScanStore()
        guard case .start(let g1, _) = store.begin("nes") else { return XCTFail() }
        _ = store.finish("nes", generation: g1, result: .listed(one))
        guard case .start(let g2, let shown) = store.begin("nes") else { return XCTFail() }
        XCTAssertEqual(shown, ConsoleFolderSnapshot(state: .ready, listing: one))
        XCTAssertEqual(store.finish("nes", generation: g2, result: .listed(two))?.listing, two)
    }

    func testSlowReadKeepsTheCacheAndSaysTimedOutThenRecovers() {
        var store = FolderScanStore()
        guard case .start(let g1, _) = store.begin("nes") else { return XCTFail() }
        _ = store.finish("nes", generation: g1, result: .listed(one))
        guard case .start(let g2, _) = store.begin("nes") else { return XCTFail() }
        XCTAssertEqual(store.timedOut("nes", generation: g2), ConsoleFolderSnapshot(state: .timedOut, listing: one))
        // The blocked read finally answers (the prompt was allowed): the screen updates.
        XCTAssertEqual(store.finish("nes", generation: g2, result: .listed(two)), ConsoleFolderSnapshot(state: .ready, listing: two))
    }

    func testTimeoutAfterTheReadFinishedChangesNothing() {
        var store = FolderScanStore()
        guard case .start(let g, _) = store.begin("nes") else { return XCTFail() }
        _ = store.finish("nes", generation: g, result: .listed(one))
        XCTAssertNil(store.timedOut("nes", generation: g))
        XCTAssertEqual(store.snapshot("nes").state, .ready)
    }

    func testMissingFolderShowsNoStaleGames() {
        var store = FolderScanStore()
        guard case .start(let g1, _) = store.begin("switch") else { return XCTFail() }
        _ = store.finish("switch", generation: g1, result: .listed(one))
        guard case .start(let g2, _) = store.begin("switch") else { return XCTFail() }
        let snap = store.finish("switch", generation: g2, result: .failed(.notFound))
        XCTAssertEqual(snap, ConsoleFolderSnapshot(state: .notFound, listing: nil))
        // Plugged back in: listed again.
        guard case .start(let g3, _) = store.begin("switch") else { return XCTFail() }
        XCTAssertEqual(store.finish("switch", generation: g3, result: .listed(two))?.state, .ready)
    }

    func testOlderResultNeverOverwritesANewerOne() {
        var store = FolderScanStore()
        guard case .start(let g1, _) = store.begin("nes"), case .start(let g2, _) = store.begin("nes") else { return XCTFail() }
        XCTAssertEqual(store.finish("nes", generation: g2, result: .listed(two))?.listing, two)
        XCTAssertNil(store.finish("nes", generation: g1, result: .listed(one)))
        XCTAssertEqual(store.snapshot("nes").listing, two)
    }

    func testStuckReadsAreBounded() {
        var store = FolderScanStore()
        for _ in 0..<FolderLimits.maxReadsInFlight {
            guard case .start = store.begin("switch") else { return XCTFail() }
        }
        guard case .skipped(let snap) = store.begin("switch") else { return XCTFail("a third stuck read must not start") }
        XCTAssertEqual(snap.state, .loading)
    }

    func testCacheIsBoundedByConsoleCount() {
        var store = FolderScanStore()
        for i in 0..<(FolderLimits.maxCachedConsoles + 5) {
            guard case .start(let g, _) = store.begin("c\(i)") else { return XCTFail() }
            _ = store.finish("c\(i)", generation: g, result: .listed(one))
        }
        XCTAssertEqual(store.snapshot("c0").state, .loading)   // evicted
        XCTAssertEqual(store.snapshot("c\(FolderLimits.maxCachedConsoles + 4)").state, .ready)
    }

    // MARK: Text

    func testPermissionTextNamesTheDrive() {
        let text = FolderMessages.text(for: .permissionDenied, path: "/Volumes/Storage/Games/switch")
        XCTAssertEqual(text, "Allow CouchMode to use the Storage drive: System Settings \u{203A} Privacy & Security \u{203A} Files and Folders \u{203A} CouchMode \u{203A} Removable Volumes")
    }

    func testOtherStatesText() {
        XCTAssertEqual(FolderMessages.text(for: .timedOut, path: "/x"), "The drive isn't responding")
        XCTAssertTrue(FolderMessages.text(for: .notFound, path: "/Volumes/Storage/g")!.contains("unplugged"))
        XCTAssertNil(FolderMessages.text(for: .ready, path: "/x"))
        XCTAssertEqual(FolderMessages.volumeName(forPath: "/Volumes/Storage/Games"), "Storage")
        XCTAssertNil(FolderMessages.volumeName(forPath: "/Users/me/Games"))
    }
}
