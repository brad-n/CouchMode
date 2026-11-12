// Owns: tests for ImageRetry, which decides whether a failed image fetch is
// worth another try and how long to wait first.

import XCTest
@testable import CouchModeCore

final class ImageRetryTests: XCTestCase {
    func testTransientStatusesRetryWithGrowingBackoff() {
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(ImageRetry.delay(status: status, urlErrorCode: nil, attempt: 0), .milliseconds(400), "\(status)")
            XCTAssertEqual(ImageRetry.delay(status: status, urlErrorCode: nil, attempt: 1), .milliseconds(1200), "\(status)")
        }
    }

    func testStopsAfterTwoRetries() {
        XCTAssertNil(ImageRetry.delay(status: 408, urlErrorCode: nil, attempt: 2))
        XCTAssertNil(ImageRetry.delay(status: 408, urlErrorCode: nil, attempt: 99))
    }

    func testPermanentFailuresDoNotRetry() {
        for status in [200, 301, 400, 401, 403, 404, 410, 505] {
            XCTAssertNil(ImageRetry.delay(status: status, urlErrorCode: nil, attempt: 0), "\(status)")
        }
    }

    func testTransientURLErrorsRetry() {
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost] {
            XCTAssertEqual(ImageRetry.delay(status: nil, urlErrorCode: code, attempt: 0), .milliseconds(400))
        }
        XCTAssertNil(ImageRetry.delay(status: nil, urlErrorCode: NSURLErrorCancelled, attempt: 0))
        XCTAssertNil(ImageRetry.delay(status: nil, urlErrorCode: NSURLErrorBadURL, attempt: 0))
    }

    func testNoStatusAndNoErrorDoesNotRetry() {
        XCTAssertNil(ImageRetry.delay(status: nil, urlErrorCode: nil, attempt: 0))
        XCTAssertNil(ImageRetry.delay(status: nil, urlErrorCode: nil, attempt: -1))
    }
}
