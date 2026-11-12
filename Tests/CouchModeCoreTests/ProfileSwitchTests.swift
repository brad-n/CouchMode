import XCTest
@testable import CouchModeCore

final class ProfileSwitchTests: XCTestCase {
    func testABooleanAnswerMapsToSwitchedOrFailed() {
        XCTAssertEqual(ProfileSwitch(succeeded: true), .switched)
        XCTAssertEqual(ProfileSwitch(succeeded: false), .failed)
    }

    func testNoticesNameTheProfileOrTheService() {
        XCTAssertNil(ProfileSwitch.switched.notice(profileName: "Profile 2", serviceName: "Disney+"))
        XCTAssertEqual(ProfileSwitch.failed.notice(profileName: "Profile 2", serviceName: "Disney+"), "Couldn't switch to Profile 2")
        XCTAssertEqual(ProfileSwitch.needsPerson.notice(profileName: "Profile 2", serviceName: "Disney+"), "Finish this profile on Disney+")
        XCTAssertEqual(ProfileSwitch.needsPerson.notice(profileName: "Profile 2", serviceName: "Hulu"), "Finish this profile on Hulu")
    }

    func testOnlyNeedsPersonHandsOffToTheWebsite() {
        XCTAssertTrue(ProfileSwitch.needsPerson.handsOffToWebsite)
        XCTAssertFalse(ProfileSwitch.switched.handsOffToWebsite)
        XCTAssertFalse(ProfileSwitch.failed.handsOffToWebsite)
    }
}

final class UnfinishedSwitchTests: XCTestCase {
    func testOnTheFormWithARememberedProfileRestoresIt() {
        var s = UnfinishedSwitch()
        s.record(.needsPerson, from: "Profile 1")
        XCTAssertEqual(s.profileToRestore(onForm: true), "Profile 1")
    }

    func testNothingToRestoreOffTheFormOrWithoutAMemory() {
        var s = UnfinishedSwitch()
        XCTAssertNil(s.profileToRestore(onForm: true))
        s.record(.needsPerson, from: "Profile 1")
        XCTAssertNil(s.profileToRestore(onForm: false))
        var unknown = UnfinishedSwitch()
        unknown.record(.needsPerson, from: nil)
        XCTAssertNil(unknown.profileToRestore(onForm: true), "no known previous profile: keep today's behavior")
    }

    func testACompletedSwitchOrClearForgetsIt() {
        var s = UnfinishedSwitch()
        s.record(.needsPerson, from: "Profile 1")
        s.record(.switched, from: "Profile 2")
        XCTAssertNil(s.profileToRestore(onForm: true))
        s.record(.needsPerson, from: "Profile 1")
        s.clear()
        XCTAssertNil(s.profileToRestore(onForm: true))
    }

    func testAFailedSwitchChangesNothing() {
        var s = UnfinishedSwitch()
        s.record(.needsPerson, from: "Profile 1")
        s.record(.failed, from: "Profile 2")
        XCTAssertEqual(s.previous, "Profile 1")
    }

    func testASecondUnfinishedSwitchKeepsTheOriginalWhenTheStartIsUnknown() {
        var s = UnfinishedSwitch()
        s.record(.needsPerson, from: "Profile 1")
        s.record(.needsPerson, from: nil)
        XCTAssertEqual(s.previous, "Profile 1")
    }
}
