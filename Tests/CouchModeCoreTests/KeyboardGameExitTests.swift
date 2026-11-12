import XCTest
@testable import CouchModeCore

final class KeyboardGameExitTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: Shortcut matching

    func testCommandDeleteIsHomeButPlainDeleteIsNot() {
        XCTAssertTrue(KeyboardHome.isHomeChord(keyCode: 51, command: true))
        XCTAssertFalse(KeyboardHome.isHomeChord(keyCode: 51, command: false))
        XCTAssertFalse(KeyboardHome.isHomeChord(keyCode: 53, command: true))
    }

    func testOnlyEscapeStartsTheHold() {
        XCTAssertTrue(KeyboardHome.isHoldKey(keyCode: 53))
        for code: UInt16 in [51, 36, 49, 7, 123] { XCTAssertFalse(KeyboardHome.isHoldKey(keyCode: code)) }
    }

    func testTheShortcutsApplyOnlyToGamesNotToOtherApps() {
        XCTAssertTrue(KeyboardHome.appliesTo(front: .switchGame))
        XCTAssertTrue(KeyboardHome.appliesTo(front: .retroArch))
        // ⌘⌫ is Move to Trash in Finder, and Escape is a dialog's Cancel.
        for front in [FrontApp.shell, .streamingApp, .other] { XCTAssertFalse(KeyboardHome.appliesTo(front: front)) }
    }

    // MARK: Hold to home

    func testHeldEscapeFiresOnceAfterTheHoldTime() {
        var hold = EscapeHold()
        hold.keyDown(now: t0)
        XCTAssertFalse(hold.poll(now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(hold.poll(now: t0.addingTimeInterval(EscapeHold.holdTime)))
        XCTAssertFalse(hold.poll(now: t0.addingTimeInterval(EscapeHold.holdTime + 1)), "fires once per hold")
    }

    func testReleasingBeforeTheHoldTimeCancels() {
        var hold = EscapeHold()
        hold.keyDown(now: t0)
        hold.keyUp()
        XCTAssertFalse(hold.poll(now: t0.addingTimeInterval(5)))
        XCTAssertFalse(hold.isDown)
    }

    func testKeyRepeatDoesNotRestartTheHold() {
        var hold = EscapeHold()
        hold.keyDown(now: t0)
        hold.keyDown(now: t0.addingTimeInterval(0.6))   // auto-repeat
        XCTAssertTrue(hold.poll(now: t0.addingTimeInterval(1.0)))
    }

    func testAHeldKeyDoesNotRefireAfterRepeatsButFiresAgainOnTheNextPress() {
        var hold = EscapeHold()
        hold.keyDown(now: t0)
        XCTAssertTrue(hold.poll(now: t0.addingTimeInterval(1.1)))
        hold.keyDown(now: t0.addingTimeInterval(1.2))
        XCTAssertFalse(hold.poll(now: t0.addingTimeInterval(3)))
        hold.keyUp()
        hold.keyDown(now: t0.addingTimeInterval(4))
        XCTAssertTrue(hold.poll(now: t0.addingTimeInterval(5.1)))
    }

    func testPollWithoutAPressDoesNothing() {
        var hold = EscapeHold()
        XCTAssertFalse(hold.poll(now: t0))
    }

    // MARK: Close Game on a tile

    func testCloseKeysAreXAndPlainDelete() {
        XCTAssertTrue(CloseGameFlow.isCloseKey(keyCode: 7, command: false))
        XCTAssertTrue(CloseGameFlow.isCloseKey(keyCode: 51, command: false))
        XCTAssertFalse(CloseGameFlow.isCloseKey(keyCode: 51, command: true), "⌘⌫ is Home")
        XCTAssertFalse(CloseGameFlow.isCloseKey(keyCode: 53, command: false))
    }

    func testClosingATileThatIsNotPausedDoesNothing() {
        var flow = CloseGameFlow()
        XCTAssertEqual(flow.press(game: "A.app", isPaused: false, now: t0), .nothing)
        XCTAssertEqual(flow.press(game: "A.app", isPaused: false, now: t0.addingTimeInterval(1)), .nothing)
    }

    func testFirstPressAsksAndSecondWithinTheWindowCloses() {
        var flow = CloseGameFlow()
        XCTAssertEqual(flow.press(game: "A.app", isPaused: true, now: t0), .askToConfirm)
        XCTAssertEqual(flow.pending(now: t0.addingTimeInterval(1)), "A.app")
        XCTAssertEqual(flow.press(game: "A.app", isPaused: true, now: t0.addingTimeInterval(2)), .close)
        XCTAssertNil(flow.pending(now: t0.addingTimeInterval(2)))
    }

    func testAPressAfterTheWindowAsksAgain() {
        var flow = CloseGameFlow()
        _ = flow.press(game: "A.app", isPaused: true, now: t0)
        XCTAssertEqual(flow.press(game: "A.app", isPaused: true, now: t0.addingTimeInterval(ConfirmGate.window + 1)), .askToConfirm)
    }

    func testAnotherGameOrAnotherActionDoesNotConfirm() {
        var flow = CloseGameFlow()
        _ = flow.press(game: "A.app", isPaused: true, now: t0)
        XCTAssertEqual(flow.press(game: "B.app", isPaused: true, now: t0.addingTimeInterval(1)), .askToConfirm)
    }

    func testMovingOffTheTileDisarms() {
        var flow = CloseGameFlow()
        _ = flow.press(game: "A.app", isPaused: true, now: t0)
        flow.disarm()
        XCTAssertEqual(flow.press(game: "A.app", isPaused: true, now: t0.addingTimeInterval(1)), .askToConfirm)
    }
}
