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
