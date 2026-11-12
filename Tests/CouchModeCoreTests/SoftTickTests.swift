// Owns: tests of the soft interface-sound synthesis (lengths, level, edges, rate limit).

import XCTest
@testable import CouchModeCore

final class SoftTickTests: XCTestCase {
    func testSampleCountsMatchDuration() {
        for kind in SoftTick.Kind.allCases {
            let s = SoftTick.spec(kind)
            XCTAssertEqual(SoftTick.samples(kind).count, Int((s.seconds * SoftTick.sampleRate).rounded()))
            XCTAssertTrue((0.008...0.020).contains(s.seconds), "\(kind) length")
        }
    }

    func testPeakMatchesSpecAndNeverClips() {
        for kind in SoftTick.Kind.allCases {
            let peak = SoftTick.samples(kind).map { abs($0) }.max() ?? 0
            XCTAssertEqual(peak, SoftTick.spec(kind).peak, accuracy: 0.002)
            XCTAssertLessThan(peak, 0.1)
        }
    }

    func testMoveIsQuietestAndSelectFullest() {
        let p = { (k: SoftTick.Kind) in SoftTick.spec(k).peak }
        XCTAssertLessThan(p(.move), p(.back))
        XCTAssertLessThan(p(.back), p(.select))
        XCTAssertLessThan(SoftTick.spec(.back).centerHz, SoftTick.spec(.select).centerHz)
        XCTAssertLessThan(SoftTick.spec(.limit).centerHz, 800)
    }

    func testEdgesStartAndEndAtZero() {
        for kind in SoftTick.Kind.allCases {
            let s = SoftTick.samples(kind)
            XCTAssertEqual(s.first, 0, "\(kind) start")
            XCTAssertEqual(s.last, 0, "\(kind) end")
        }
    }

    func testEnvelopeDecaysToZero() {
        let n = 530
        XCTAssertEqual(SoftTick.envelope(index: n - 1, count: n, decaySeconds: 0.003), 0)
        XCTAssertEqual(SoftTick.envelope(index: 0, count: n, decaySeconds: 0.003), 0)
        XCTAssertGreaterThan(SoftTick.envelope(index: 40, count: n, decaySeconds: 0.003),
                             SoftTick.envelope(index: 200, count: n, decaySeconds: 0.003))
        XCTAssertEqual(SoftTick.envelope(index: -1, count: n, decaySeconds: 0.003), 0)
    }

    func testDeterministicAndNearZeroDC() {
        XCTAssertEqual(SoftTick.samples(.move), SoftTick.samples(.move))
        for kind in SoftTick.Kind.allCases {
            let s = SoftTick.samples(kind)
            let mean = s.reduce(0, +) / Float(s.count)
            XCTAssertLessThan(abs(mean), SoftTick.spec(kind).peak * 0.1)
        }
    }

    func testRateLimiterDropsFastRepeatsPerKind() {
        var r = SoftTick.RateLimiter()
        XCTAssertTrue(r.allow(.move, now: 1.000))
        XCTAssertFalse(r.allow(.move, now: 1.010))
        XCTAssertTrue(r.allow(.select, now: 1.010))
        XCTAssertTrue(r.allow(.move, now: 1.050))
    }
}
