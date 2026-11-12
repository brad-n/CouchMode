// Owns: capturing the real screen (whatever app is in front) for the opt-in
// debug channel. Needs macOS's Screen Recording permission for this app,
// asked for once; without it, capture fails and the caller is told why.

import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCapture {
    enum Failure: Error { case noPermission, noDisplay, encode }

    /// Asks macOS for Screen Recording permission if not yet granted.
    /// Returns whether it is granted now (the first answer may need a relaunch).
    static func ensurePermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    /// PNG of the display the shell is on, scaled to at most `maxWidth` pixels wide.
    static func png(displayID: CGDirectDisplayID?, maxWidth: Int = 1920) async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else { throw Failure.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        let config = SCStreamConfiguration()
        let scale = min(1, Double(maxWidth) / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                               configuration: config)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encode }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return out as Data
    }
}
