// Owns: tests for AppVersion, the "0.2.0 (123, abc1234)" text shown in Settings.

import XCTest
@testable import CouchModeCore

final class AppVersionTests: XCTestCase {
    func testFullVersionShowsReleaseBuildCountAndSha() {
        XCTAssertEqual(AppVersion.text(short: "0.2.0", build: "123", sha: "abc1234"), "0.2.0 (123, abc1234)")
    }

    func testMissingShaIsLeftOut() {
        XCTAssertEqual(AppVersion.text(short: "0.2.0", build: "123", sha: nil), "0.2.0 (123)")
        XCTAssertEqual(AppVersion.text(short: "0.2.0", build: "123", sha: "  "), "0.2.0 (123)")
    }

    func testMissingPartsShowAQuestionMark() {
        XCTAssertEqual(AppVersion.text(short: nil, build: nil, sha: nil), "? (?)")
    }

    func testPrereleaseSuffixIsKept() {
        XCTAssertEqual(AppVersion.text(short: "0.2.0-rc1", build: "9", sha: "deadbee"), "0.2.0-rc1 (9, deadbee)")
    }

    func testReleaseVersionAcceptsPlainAndPrerelease() {
        for v in ["0.2.0", "1.0", "10.20.30", "0.2.0-rc1", "1.0.0-beta.2"] { XCTAssertTrue(AppVersion.isValidRelease(v), v) }
    }

    func testReleaseVersionRejectsJunk() {
        for v in ["", "v0.2.0", "0.2.", "a.b", "0.2.0 ", "0.2.0/../x", "0.2.0-", "1.2.3.4.5"] { XCTAssertFalse(AppVersion.isValidRelease(v), v) }
    }
}
