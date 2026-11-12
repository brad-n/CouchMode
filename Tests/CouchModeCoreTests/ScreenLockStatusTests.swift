import XCTest
@testable import CouchModeCore

final class ScreenLockStatusTests: XCTestCase {
    func testOffWithRealPrefix() {
        XCTAssertEqual(ScreenLockStatus.parse("2026-11-12 12:28:45.458 sysadminctl[63349:4625672] screenLock is off\n"), .off)
    }

    func testDelay() {
        XCTAssertEqual(ScreenLockStatus.parse("2026-11-12 12:28:45.458 sysadminctl[1:2] screenLock delay is 300 seconds\n"), .on(delaySeconds: 300))
        XCTAssertEqual(ScreenLockStatus.parse("screenLock delay is 5 seconds"), .on(delaySeconds: 5))
    }

    func testImmediate() {
        XCTAssertEqual(ScreenLockStatus.parse("2026-11-12 12:28:45.458 sysadminctl[1:2] screenLock is immediate"), .on(delaySeconds: 0))
    }

    func testUnknownOrEmptyIsNil() {
        XCTAssertNil(ScreenLockStatus.parse(""))
        XCTAssertNil(ScreenLockStatus.parse("sysadminctl: usage error"))
        XCTAssertNil(ScreenLockStatus.parse("screenLock delay is soon"))
    }

    func testOtherLinesAreSkipped() {
        XCTAssertEqual(ScreenLockStatus.parse("Some warning\n2026-11-12 sysadminctl[1:2] screenLock is off\n"), .off)
    }

    func testValueText() {
        XCTAssertEqual(ScreenLockStatus.off.valueText, "Off")
        XCTAssertEqual(ScreenLockStatus.on(delaySeconds: 0).valueText, "On (immediately)")
        XCTAssertEqual(ScreenLockStatus.on(delaySeconds: 300).valueText, "On (after 5 min)")
        XCTAssertEqual(ScreenLockStatus.on(delaySeconds: 5).valueText, "On (after 5 sec)")
        XCTAssertEqual(ScreenLockStatus.on(delaySeconds: 3600).valueText, "On (after 60 min)")
    }

    func testSetupNoteOnlyWhenOn() {
        XCTAssertNil(ScreenLockStatus.setupNote(.off))
        XCTAssertNil(ScreenLockStatus.setupNote(nil))
        XCTAssertEqual(ScreenLockStatus.setupNote(.on(delaySeconds: 60)), ScreenLockStatus.explanation)
        XCTAssertTrue(ScreenLockStatus.explanation.contains("sysadminctl -screenLock off"))
    }
}
