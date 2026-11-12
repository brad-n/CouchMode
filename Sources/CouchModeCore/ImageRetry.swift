// Owns: whether a failed image fetch is worth retrying and the wait before
// it. Some image services answer 408 the first time an image size is
// requested and 200 on the next. Pure values: no I/O.

import Foundation

public enum ImageRetry {
    /// Waits before the first and second retry; no third retry.
    public static let backoff: [Duration] = [.milliseconds(400), .milliseconds(1200)]
    static let transientStatuses: Set<Int> = [408, 429, 500, 501, 502, 503, 504]
    static let transientURLErrors: Set<Int> = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost]

    /// How long to wait before retry number `attempt + 1` (`attempt` counts
    /// retries already made), or nil to give up.
    public static func delay(status: Int?, urlErrorCode: Int?, attempt: Int) -> Duration? {
        guard attempt >= 0, attempt < backoff.count else { return nil }
        if let status { return transientStatuses.contains(status) ? backoff[attempt] : nil }
        if let urlErrorCode, transientURLErrors.contains(urlErrorCode) { return backoff[attempt] }
        return nil
    }
}
