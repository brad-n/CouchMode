// Owns: tests for the Netflix 5.1 setting decision, output text and script inclusion.

import XCTest
@testable import CouchModeCore

final class Netflix51Tests: XCTestCase {
    func testAutoFollowsChannelCount() {
        XCTAssertFalse(Netflix51.auto.effective(channels: 2))
        XCTAssertFalse(Netflix51.auto.effective(channels: 5))
        XCTAssertTrue(Netflix51.auto.effective(channels: 6))
        XCTAssertTrue(Netflix51.auto.effective(channels: 8))
        XCTAssertFalse(Netflix51.auto.effective(channels: nil))
    }

    func testOnAndOffIgnoreChannels() {
        XCTAssertTrue(Netflix51.on.effective(channels: 2))
        XCTAssertTrue(Netflix51.on.effective(channels: nil))
        XCTAssertFalse(Netflix51.off.effective(channels: 8))
    }

    func testStoredValueDefaultsToAuto() {
        XCTAssertEqual(Netflix51(stored: nil), .auto)
        XCTAssertEqual(Netflix51(stored: "bogus"), .auto)
        XCTAssertEqual(Netflix51(stored: "on"), .on)
        XCTAssertEqual(Netflix51(stored: "off"), .off)
    }

    func testSummaryShowsWhatAutoDecided() {
        XCTAssertEqual(Netflix51.auto.summary(channels: 2), "Auto (off)")
        XCTAssertEqual(Netflix51.auto.summary(channels: 6), "Auto (on)")
        XCTAssertEqual(Netflix51.on.summary(channels: 2), "On")
    }

    func testOutputDescription() {
        XCTAssertEqual(Netflix51.describeOutput(name: "Speakers", channels: 2), "Speakers \u{00B7} 2 channels")
        XCTAssertEqual(Netflix51.describeOutput(name: "Mono", channels: 1), "Mono \u{00B7} 1 channel")
        XCTAssertEqual(Netflix51.describeOutput(name: "Speakers", channels: nil), "Speakers")
        XCTAssertEqual(Netflix51.describeOutput(name: "Speakers", channels: 0), "Speakers")
    }

    func testScriptOnlyForNetflixWhenOn() {
        XCTAssertNotNil(Netflix51.script(forService: "netflix", enabled: true))
        XCTAssertNil(Netflix51.script(forService: "netflix", enabled: false))
        for id in ["hulu", "prime", "disney", "plex"] {
            XCTAssertNil(Netflix51.script(forService: id, enabled: true))
        }
    }

    func testScriptIsGuardedAndOnlyAddsTheProfile() {
        let s = Netflix51.source
        XCTAssertTrue(s.contains("ddplus-5.1-dash"))
        XCTAssertTrue(s.hasPrefix("try {"))
        XCTAssertTrue(s.contains("catch (e)"))
    }
}
