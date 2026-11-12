// Owns: tests for UpdateFlow (the in-app update screen's state machine),
// UpdateFailure (which Sparkle errors read as friendly lines), ReleaseNotes
// (appcast text shortened for a TV) and UpdateNotice (when Home shows the notice).

import XCTest
@testable import CouchModeCore

final class UpdateFlowTests: XCTestCase {
    private func checking() -> UpdateFlow {
        var f = UpdateFlow()
        f.apply(.checkStarted)
        return f
    }

    private func available() -> UpdateFlow {
        var f = checking()
        f.apply(.found(version: "0.3.0", notes: "Fixes", userInitiated: true))
        return f
    }

    func testStartsIdleWithNothingPending() {
        let f = UpdateFlow()
        XCTAssertEqual(f.phase, .idle)
        XCTAssertNil(f.pendingVersion)
        XCTAssertTrue(f.buttons.isEmpty)
    }

    func testCheckingHasNoButtonsAndBackCancels() {
        var f = checking()
        XCTAssertEqual(f.phase, .checking)
        XCTAssertTrue(f.buttons.isEmpty)
        XCTAssertEqual(f.press(.back), .cancel)
        XCTAssertEqual(f.phase, .idle)
    }

    func testFoundOffersInstallNowAndLaterWithInstallFocused() {
        let f = available()
        XCTAssertEqual(f.phase, .available(version: "0.3.0", notes: "Fixes"))
        XCTAssertEqual(f.buttons, [.installNow, .later])
        XCTAssertEqual(f.focused, .installNow)
        XCTAssertEqual(f.pendingVersion, "0.3.0")
    }

    func testLeftRightMoveBetweenButtonsAndStopAtEnds() {
        var f = available()
        XCTAssertEqual(f.press(.move(.right)), .none)
        XCTAssertEqual(f.focused, .later)
        XCTAssertEqual(f.press(.move(.right)), .none)
        XCTAssertEqual(f.focused, .later)
        XCTAssertEqual(f.press(.move(.left)), .none)
        XCTAssertEqual(f.focused, .installNow)
        XCTAssertEqual(f.press(.move(.left)), .none)
        XCTAssertEqual(f.focused, .installNow)
    }

    func testUpAndDownDoNothing() {
        var f = available()
        XCTAssertEqual(f.press(.move(.up)), .none)
        XCTAssertEqual(f.press(.move(.down)), .none)
        XCTAssertEqual(f.focused, .installNow)
    }

    func testSelectOnInstallNowInstallsAndStartsDownloading() {
        var f = available()
        XCTAssertEqual(f.press(.select), .install)
        XCTAssertEqual(f.phase, .downloading(fraction: nil))
        XCTAssertNil(f.pendingVersion)
    }

    func testSelectOnLaterDismissesAndKeepsTheNotice() {
        var f = available()
        _ = f.press(.move(.right))
        XCTAssertEqual(f.press(.select), .later)
        XCTAssertEqual(f.phase, .idle)
        XCTAssertEqual(f.pendingVersion, "0.3.0")
    }

    func testBackIsLater() {
        var f = available()
        XCTAssertEqual(f.press(.back), .later)
        XCTAssertEqual(f.phase, .idle)
        XCTAssertEqual(f.pendingVersion, "0.3.0")
    }

    func testAutomaticFindOnlySetsTheNoticeAndNeverTakesTheScreen() {
        var f = UpdateFlow()
        f.apply(.found(version: "0.3.0", notes: "x", userInitiated: false))
        XCTAssertEqual(f.phase, .idle)
        XCTAssertEqual(f.pendingVersion, "0.3.0")
    }

    func testAutomaticNotFoundAndErrorsAreSilent() {
        var f = UpdateFlow()
        f.apply(.notFound)
        XCTAssertEqual(f.phase, .idle)
        f.apply(.failed(.unreachable))
        XCTAssertEqual(f.phase, .idle)
    }

    func testNotFoundShowsUpToDateAndClearsTheNotice() {
        var f = UpdateFlow()
        f.apply(.found(version: "0.3.0", notes: "", userInitiated: false))
        f.apply(.checkStarted)
        f.apply(.notFound)
        XCTAssertEqual(f.phase, .upToDate)
        XCTAssertNil(f.pendingVersion)
        XCTAssertEqual(f.buttons, [.ok])
    }

    func testOkAndBackBothAcknowledgeAndClose() {
        var f = checking()
        f.apply(.notFound)
        XCTAssertEqual(f.press(.select), .acknowledge)
        XCTAssertEqual(f.phase, .idle)
        f.apply(.checkStarted)
        f.apply(.failed(.unreachable))
        XCTAssertEqual(f.press(.back), .acknowledge)
        XCTAssertEqual(f.phase, .idle)
    }

    func testUnreachableKeepsAnExistingNotice() {
        var f = UpdateFlow()
        f.apply(.found(version: "0.3.0", notes: "", userInitiated: false))
        f.apply(.checkStarted)
        f.apply(.failed(.unreachable))
        XCTAssertEqual(f.phase, .unreachable)
        XCTAssertEqual(f.pendingVersion, "0.3.0")
    }

    func testFailureShowsAnErrorLine() {
        var f = checking()
        f.apply(.failed(.other("The update could not be unpacked.")))
        XCTAssertEqual(f.phase, .failed("The update could not be unpacked."))
    }

    func testDownloadProgressIsAFractionAndNeverExceedsOne() {
        var f = available()
        _ = f.press(.select)
        f.apply(.expectedLength(1000))
        f.apply(.received(250))
        XCTAssertEqual(f.phase, .downloading(fraction: 0.25))
        f.apply(.received(2000))
        XCTAssertEqual(f.phase, .downloading(fraction: 1))
    }

    func testDownloadWithUnknownLengthStaysIndeterminate() {
        var f = available()
        _ = f.press(.select)
        f.apply(.received(500))
        XCTAssertEqual(f.phase, .downloading(fraction: nil))
    }

    func testBackWhileDownloadingCancels() {
        var f = available()
        _ = f.press(.select)
        XCTAssertEqual(f.press(.back), .cancel)
        XCTAssertEqual(f.phase, .idle)
    }

    func testInstallingIgnoresEveryPress() {
        var f = available()
        _ = f.press(.select)
        f.apply(.installing)
        XCTAssertEqual(f.phase, .installing)
        for i in [ShellIntent.back, .select, .move(.left), .home] { XCTAssertEqual(f.press(i), .none) }
        XCTAssertEqual(f.phase, .installing)
    }

    func testExtractionMovesToInstalling() {
        var f = available()
        _ = f.press(.select)
        f.apply(.extracting)
        XCTAssertEqual(f.phase, .installing)
    }

    func testDismissEndsAnythingButInstalling() {
        var f = checking()
        f.apply(.dismissed)
        XCTAssertEqual(f.phase, .idle)
        var g = available()
        _ = g.press(.select)
        g.apply(.installing)
        g.apply(.dismissed)
        XCTAssertEqual(g.phase, .installing)
    }

    func testHomeButtonActsLikeBack() {
        var f = available()
        XCTAssertEqual(f.press(.home), .later)
    }

    func testLateEventsAfterCancelAreIgnored() {
        var f = checking()
        _ = f.press(.back)
        f.apply(.received(10))
        f.apply(.notFound)
        XCTAssertEqual(f.phase, .idle)
    }

    func testTitlesAreShortPlainLines() {
        XCTAssertEqual(UpdateFlow.Phase.checking.title, "Checking\u{2026}")
        XCTAssertEqual(UpdateFlow.Phase.available(version: "0.3.0", notes: "").title, "Update available: 0.3.0")
        XCTAssertEqual(UpdateFlow.Phase.downloading(fraction: nil).title, "Downloading\u{2026}")
        XCTAssertEqual(UpdateFlow.Phase.installing.title, "Installing\u{2026}")
        XCTAssertEqual(UpdateFlow.Phase.installing.subtitle, "CouchMode will restart")
        XCTAssertEqual(UpdateFlow.Phase.upToDate.title, "You\u{2019}re up to date")
        XCTAssertEqual(UpdateFlow.Phase.unreachable.title, "Can\u{2019}t reach updates")
        XCTAssertEqual(UpdateFlow.Phase.failed("Oops").subtitle, "Oops")
    }
}

final class UpdateFailureTests: XCTestCase {
    func testMissingFeedAndNetworkErrorsAreUnreachable() {
        XCTAssertEqual(UpdateFailure.classify(domain: "SUSparkleErrorDomain", code: 1002, message: "x"), .unreachable)
        XCTAssertEqual(UpdateFailure.classify(domain: "SUSparkleErrorDomain", code: 2001, message: "x"), .unreachable)
        XCTAssertEqual(UpdateFailure.classify(domain: "SUSparkleErrorDomain", code: 1000, message: "x"), .unreachable)
        XCTAssertEqual(UpdateFailure.classify(domain: "NSURLErrorDomain", code: -1009, message: "offline"), .unreachable)
        XCTAssertEqual(UpdateFailure.classify(domain: "NSURLErrorDomain", code: -1001, message: "timeout"), .unreachable)
    }

    func testOtherErrorsKeepAShortMessage() {
        let long = String(repeating: "word ", count: 100)
        guard case .other(let m) = UpdateFailure.classify(domain: "SUSparkleErrorDomain", code: 3001, message: long) else {
            return XCTFail("expected other")
        }
        XCTAssertLessThanOrEqual(m.count, UpdateFailure.maxMessage)
        XCTAssertFalse(m.isEmpty)
    }

    func testEmptyMessageGetsAGenericLine() {
        XCTAssertEqual(UpdateFailure.classify(domain: "X", code: 1, message: "  "), .other("The update didn\u{2019}t finish."))
    }
}

final class ReleaseNotesTests: XCTestCase {
    func testStripsTagsAndKeepsListItemsAsLines() {
        let html = "<h2>What&#39;s new</h2><ul><li>Faster Home</li><li>Fix &amp; polish</li></ul>"
        XCTAssertEqual(ReleaseNotes.summary(html: html, maxLines: 4, maxChars: 200), "What's new\nFaster Home\nFix & polish")
    }

    func testDropsScriptAndStyleBlocks() {
        XCTAssertEqual(ReleaseNotes.summary(html: "<style>p{}</style><script>x()</script><p>Hi</p>", maxLines: 4, maxChars: 50), "Hi")
    }

    func testLimitsLinesAndCharacters() {
        let text = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ReleaseNotes.summary(html: text, maxLines: 3, maxChars: 500), "Line 1\nLine 2\nLine 3")
        XCTAssertEqual(ReleaseNotes.summary(html: "abcdefghij", maxLines: 3, maxChars: 5), "abcd\u{2026}")
    }

    func testEmptyAndNilGiveEmpty() {
        XCTAssertEqual(ReleaseNotes.summary(html: nil, maxLines: 3, maxChars: 50), "")
        XCTAssertEqual(ReleaseNotes.summary(html: "<p> </p>", maxLines: 3, maxChars: 50), "")
    }

    func testHugeInputIsBounded() {
        let big = String(repeating: "<p>x</p>", count: 100_000)
        XCTAssertLessThanOrEqual(ReleaseNotes.summary(html: big, maxLines: 5, maxChars: 100).count, 100)
    }
}

final class UpdateNoticeTests: XCTestCase {
    func testShowsOnlyOnHomeWithAPendingUpdate() {
        XCTAssertEqual(UpdateNotice.line(pending: "0.3.0", context: .home), "Update available \u{2014} open Settings to install")
        XCTAssertNil(UpdateNotice.line(pending: nil, context: .home))
    }

    func testNeverShowsOverPlaybackGamesOrOtherScreens() {
        for c in [UpdateNotice.Context.playback, .game, .otherScreen, .updateScreen] {
            XCTAssertNil(UpdateNotice.line(pending: "0.3.0", context: c), "\(c)")
        }
    }

    func testContextFromState() {
        XCTAssertEqual(UpdateNotice.context(onHome: true, gameRunning: false, servicePlaying: false, updateScreenOpen: false), .home)
        XCTAssertEqual(UpdateNotice.context(onHome: true, gameRunning: true, servicePlaying: false, updateScreenOpen: false), .game)
        XCTAssertEqual(UpdateNotice.context(onHome: false, gameRunning: false, servicePlaying: true, updateScreenOpen: false), .playback)
        XCTAssertEqual(UpdateNotice.context(onHome: false, gameRunning: false, servicePlaying: false, updateScreenOpen: false), .otherScreen)
        XCTAssertEqual(UpdateNotice.context(onHome: false, gameRunning: false, servicePlaying: false, updateScreenOpen: true), .updateScreen)
    }

    func testAutomaticChecksNeverOpenAScreen() {
        XCTAssertFalse(UpdateNotice.mayOpenScreen(userInitiated: false))
        XCTAssertTrue(UpdateNotice.mayOpenScreen(userInitiated: true))
    }
}
