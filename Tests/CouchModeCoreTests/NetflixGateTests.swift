import XCTest
@testable import CouchModeCore

final class NetflixGateTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/netflix-gate-read", withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testGateReadIsAHomeThatAsksWhoIsWatching() throws {
        let home = try XCTUnwrap(NetflixGate.parse(try fixture()))
        XCTAssertEqual(home.serviceID, "netflix")
        XCTAssertTrue(home.asksWhoIsWatching)
        XCTAssertTrue(home.rows.isEmpty)
        XCTAssertNil(home.hero)
        XCTAssertNil(home.currentProfileID)
    }

    func testProfilesKeepOrderLockAndHttpsAvatarsOnly() throws {
        let profiles = try XCTUnwrap(NetflixGate.parse(try fixture())).profiles
        // The bad id and the repeated id are dropped; order is the gate's own.
        XCTAssertEqual(profiles.map(\.name), ["Profile 1", "Profile 2", "Profile 3", "Profile 5"])
        XCTAssertEqual(profiles.map(\.isLocked), [false, true, false, false])
        XCTAssertEqual(profiles[0].avatar?.absoluteString, "https://example.invalid/avatar/1.png")
        XCTAssertNil(profiles[2].avatar)
    }

    func testNotAGateReadIsNil() {
        XCTAssertNil(NetflixGate.parse(""))
        XCTAssertNil(NetflixGate.parse("{}"))
        XCTAssertNil(NetflixGate.parse(#"{"gate":[]}"#))
        XCTAssertNil(NetflixGate.parse(#"{"ROOT_QUERY":{}}"#))
        XCTAssertNil(NetflixGate.parse(#"{"gate":[{"id":"bad id!","name":"Profile 1"}]}"#))
    }

    func testProfilesAreBounded() {
        let many = (1...30).map { #"{"id":"SYNTH\#($0)","name":"Profile \#($0)"}"# }.joined(separator: ",")
        let home = NetflixGate.parse(#"{"gate":[\#(many)]}"#)
        XCTAssertEqual(home?.profiles.count, StreamLimits.maxProfiles)
    }

    func testChooseScriptQuotesTheIdAndNeverTypes() {
        let script = NetflixGate.chooseScript(profileID: "SYNTHPROFILE1")
        XCTAssertTrue(script.contains(#""SYNTHPROFILE1""#))
        XCTAssertEqual(NetflixGate.chooseScript(profileID: #"x"; alert(1); ""#), "return false;")
        XCTAssertFalse(script.contains(".value"))
        XCTAssertFalse(script.contains("KeyboardEvent"))
    }

    func testGateProfileSwitchUsesTheNetflixAddressRules() {
        XCTAssertNil(NetflixGate.chooseScript(profileID: "bad id!").range(of: "bad id!"))
    }

    func testStreamHomeMarkerKeepsBoundedEmpty() {
        let row = StreamRow(id: "r", title: "Row", kind: .standard, titles: [])
        var home = StreamHome(serviceID: "netflix", profiles: [StreamProfile(id: "a", name: "Profile 1")], rows: [row])
        home.asksWhoIsWatching = true
        XCTAssertTrue(home.bounded.asksWhoIsWatching)
        XCTAssertTrue(home.bounded.rows.isEmpty)
    }
}
