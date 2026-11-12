// Owns: tests for the shared screen header's rules: how the clock is
// written, and which header each screen gets.

import XCTest
@testable import CouchModeCore

final class ScreenChromeTests: XCTestCase {
    // 2026-11-11 20:57:00 UTC, a Wednesday.
    private let evening = Date(timeIntervalSince1970: 1_794_430_620)
    private let utc = TimeZone(identifier: "UTC")!

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testTimeUsesTheLocalesHourCycle() {
        XCTAssertEqual(plain(ClockText.time(evening, locale: Locale(identifier: "en_US"), timeZone: utc)), "8:57 PM")
        XCTAssertEqual(ClockText.time(evening, locale: Locale(identifier: "en_GB"), timeZone: utc), "20:57")
    }

    func testTimeFollowsTheTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ClockText.time(evening, locale: Locale(identifier: "en_GB"), timeZone: tokyo), "05:57")
    }

    func testTimeHasNoLeadingZeroForOneDigitHoursInUS() {
        let morning = Date(timeIntervalSince1970: 1_794_430_620 - 12 * 3600 - 3 * 60) // 08:54 UTC
        XCTAssertEqual(plain(ClockText.time(morning, locale: Locale(identifier: "en_US"), timeZone: utc)), "8:54 AM")
    }

    func testDateIsWeekdayMonthDay() {
        XCTAssertEqual(ClockText.date(evening, locale: Locale(identifier: "en_US"), timeZone: utc), "Wednesday, Nov 11")
    }

    func testOnlyHomeShowsTheDateAndDevices() {
        for kind in ScreenKind.allCases {
            XCTAssertEqual(ScreenHeaderPolicy.style(for: kind), kind == .home ? .timeDateAndDevices : .timeOnly, "\(kind)")
        }
    }

    func testEveryScreenGetsAHeaderWithTheClock() {
        // The loading and launch states are screens too: none may go without a clock.
        XCTAssertTrue(ScreenKind.allCases.contains(.streamLoading))
        for kind in ScreenKind.allCases {
            XCTAssertTrue(ScreenHeaderPolicy.style(for: kind).showsTime, "\(kind)")
        }
    }

    func testOnlyStreamHomeCarriesSearchAndProfileChips() {
        for kind in ScreenKind.allCases {
            XCTAssertEqual(ScreenHeaderPolicy.hasChips(kind), kind == .streamHome, "\(kind)")
        }
    }
}
